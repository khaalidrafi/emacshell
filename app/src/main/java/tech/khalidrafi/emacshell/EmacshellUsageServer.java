package tech.khalidrafi.emacshell;

import android.app.AppOpsManager;
import android.app.usage.UsageEvents;
import android.app.usage.UsageStats;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Process;
import android.util.Log;

import com.termux.shared.logger.Logger;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Map;

/**
 * The usage bridge: a token-gated loopback server exposing Android's
 * Usage Access to the Emacs running inside this app (org-activity's
 * Android module is the client; see that package's NATIVE-USAGE.org).
 *
 * Why a bridge and not an Emacs primitive: the app's law is "No Emacs
 * C rebuild, ever" (DESIGN.org), and the Emacs Android port exposes
 * no generic Java interop.  But the app itself may hold any code it
 * wants, and its manifest already declares
 * android.permission.PACKAGE_USAGE_STATS (inherited from termux-app).
 * So the app queries UsageStatsManager and Emacs talks to it over a
 * socket it could never open itself.
 *
 * Why loopback + a shared secret and not a plain socket: loopback on
 * Android is shared by every app on the device.  The port file and
 * the secret file live in the app's private files directory -- which
 * is HOME for the Emacs Android port, so Elisp reads them as
 * ~/emacshell-usage-port and ~/emacshell-usage-secret with zero
 * configuration -- while no other app can read them (different UID).
 * The secret is regenerated on every boot: a stale Emacs holding an
 * old secret is simply refused, and the client falls back; it can
 * never be used to proxy usage data off the device.
 *
 * Protocol (one request per connection, both sides ASCII):
 *
 *   request:  "CMD SECRET [BEGIN-MS END-MS]\n"
 *   response: one line of JSON + "\n", then the server closes.
 *
 * Commands:
 *   PING                      -> {"ok":true,"granted":BOOL}
 *   STATS  BEGIN-MS END-MS    -> per-app aggregates for the window:
 *        {"granted":BOOL,"apps":[{"package":...,"label":...,
 *                                  "lastUsedMs":N,"foregroundMs":N}]}
 *        (queryAndAggregateUsageStats; fg<=0 rows omitted.)
 *   EVENTS BEGIN-MS END-MS    -> the filtered event stream:
 *        {"granted":BOOL,"events":[{"package":...,"type":...,
 *                                    "tsMs":N}]}
 *        with type one of resume, pause, screen_on, screen_off,
 *        keyguard_shown, keyguard_hidden, notification_seen.
 *        Everything else (CONFIGURATION_CHANGE, USER_INTERACTION,
 *        ...) is dropped server-side to keep the payload small.
 *
 * Not granted responses carry a hint instead of data; the client
 * surfaces it.  Screen/keyguard events need Android 11 (API 30) and
 * notification_seen Android 10 (API 29); on older devices those
 * event types simply never occur -- documented honestly in
 * org-activity, not hidden here.
 *
 * Failure discipline: the server thread never crashes the app.  Any
 * exception per connection is logged and the connection dropped; a
 * failure to bind is logged once and the bridge simply does not
 * exist that boot.
 */
public final class EmacshellUsageServer {

    private static final String LOG_TAG = "EmacshellUsageServer";

    /** File names inside getFilesDir() (= HOME for the Emacs port). */
    private static final String PORT_FILE = "emacshell-usage-port";
    private static final String SECRET_FILE = "emacshell-usage-secret";

    /** Length of the hex-encoded shared secret, in bytes. */
    private static final int SECRET_BYTES = 24;

    /** Per-connection read timeout: a stuck client must not pile up. */
    private static final int SO_TIMEOUT_MS = 10_000;

    private static volatile boolean sStarted = false;

    private EmacshellUsageServer() {
        /* Static helper; never instantiated. */
    }

    /**
     * Start the bridge once per process, from
     * EmacshellApplication.onCreate().  Cheap when unused: the thread
     * parks in accept() on loopback, which costs no battery worth
     * measuring, and no query happens unless Emacs asks.
     */
    public static void start(final Context context) {
        if (sStarted)
            return;
        sStarted = true;

        final Context app = context.getApplicationContext();
        Thread thread = new Thread(() -> {
            try {
                byte[] token = new byte[SECRET_BYTES];
                new SecureRandom().nextBytes(token);
                String secret = hex(token);

                ServerSocket server = new ServerSocket();
                /* Loopback only: the bridge is for the Emacs inside
                   this process, never the network. */
                server.bind(new InetSocketAddress(
                        InetAddress.getByName("127.0.0.1"), 0));
                writeSmallFile(new File(app.getFilesDir(), PORT_FILE),
                        String.valueOf(server.getLocalPort()));
                writeSmallFile(new File(app.getFilesDir(), SECRET_FILE),
                        secret);
                Logger.logInfo(LOG_TAG, "Usage bridge listening on 127.0.0.1:"
                        + server.getLocalPort());

                while (true) {
                    Socket client = server.accept();
                    try {
                        client.setSoTimeout(SO_TIMEOUT_MS);
                        serveClient(app, secret, client);
                    } catch (Exception e) {
                        Logger.logWarn(LOG_TAG,
                                "Usage bridge client failed: " + e.getMessage());
                    } finally {
                        try {
                            client.close();
                        } catch (IOException ignored) {
                            /* Already gone. */
                        }
                    }
                }
            } catch (Exception e) {
                Logger.logErrorExtended(LOG_TAG,
                        "Usage bridge failed to start: "
                                + Log.getStackTraceString(e));
            }
        }, "emacshell-usage");
        thread.setDaemon(true);
        thread.start();
    }

    /* ------------------------------------------------------------------ */
    /* One connection.                                                     */
    /* ------------------------------------------------------------------ */

    private static void serveClient(Context context, String secret,
                                    Socket client) throws IOException {
        BufferedReader in = new BufferedReader(
                new InputStreamReader(client.getInputStream(),
                                      StandardCharsets.UTF_8));
        String line = in.readLine();
        String response;
        if (line == null) {
            response = errorJson("empty request");
        } else {
            String[] parts = line.trim().split("\\s+");
            if (parts.length < 2 || !secret.equals(parts[1])) {
                response = errorJson("auth");
            } else if ("PING".equals(parts[0])) {
                response = pingResponse(context);
            } else if ((parts.length == 4)
                       && ("STATS".equals(parts[0])
                           || "EVENTS".equals(parts[0]))) {
                try {
                    long begin = Long.parseLong(parts[2]);
                    long end = Long.parseLong(parts[3]);
                    response = "STATS".equals(parts[0])
                            ? statsResponse(context, begin, end)
                            : eventsResponse(context, begin, end);
                } catch (NumberFormatException e) {
                    response = errorJson("bad window");
                }
            } else {
                response = errorJson("bad request");
            }
        }
        OutputStream out = client.getOutputStream();
        out.write((response + "\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
    }

    private static String pingResponse(Context context) {
        try {
            JSONObject root = new JSONObject();
            root.put("ok", true);
            root.put("granted", usageGranted(context));
            return root.toString();
        } catch (Exception e) {
            return errorJson("internal");
        }
    }

    /* ------------------------------------------------------------------ */
    /* STATS.                                                              */
    /* ------------------------------------------------------------------ */

    @SuppressWarnings("deprecation")
    private static String statsResponse(Context context,
                                        long begin, long end) {
        JSONObject root = new JSONObject();
        try {
            if (!usageGranted(context))
                return ungranted(root);
            UsageStatsManager usm =
                    (UsageStatsManager) context.getSystemService(
                            Context.USAGE_STATS_SERVICE);
            Map<String, UsageStats> aggregated =
                    usm.queryAndAggregateUsageStats(begin, end);
            PackageManager pm = context.getPackageManager();
            JSONArray apps = new JSONArray();
            for (UsageStats stats : aggregated.values()) {
                long fg = stats.getTotalTimeInForeground();
                if (fg <= 0)
                    continue;
                JSONObject o = new JSONObject();
                o.put("package", stats.getPackageName());
                o.put("label", appLabel(pm, stats.getPackageName()));
                o.put("lastUsedMs", stats.getLastTimeUsed());
                o.put("foregroundMs", fg);
                apps.put(o);
            }
            root.put("granted", true);
            root.put("apps", apps);
        } catch (Exception e) {
            return errorJson("internal");
        }
        return root.toString();
    }

    @SuppressWarnings("deprecation")
    private static String appLabel(PackageManager pm, String pkg) {
        try {
            ApplicationInfo info = pm.getApplicationInfo(pkg, 0);
            CharSequence label = pm.getApplicationLabel(info);
            return label != null ? label.toString() : null;
        } catch (Exception e) {
            return null;  /* JSONObject skips the key; client falls back. */
        }
    }

    /* ------------------------------------------------------------------ */
    /* EVENTS.                                                             */
    /* ------------------------------------------------------------------ */

    private static String eventsResponse(Context context,
                                         long begin, long end) {
        JSONObject root = new JSONObject();
        try {
            if (!usageGranted(context))
                return ungranted(root);
            UsageStatsManager usm =
                    (UsageStatsManager) context.getSystemService(
                            Context.USAGE_STATS_SERVICE);
            UsageEvents usageEvents = usm.queryEvents(begin, end);
            JSONArray out = new JSONArray();
            UsageEvents.Event event = new UsageEvents.Event();
            while (usageEvents.hasNextEvent()) {
                usageEvents.getNextEvent(event);
                String type = eventName(event.getEventType());
                if (type == null)
                    continue;
                JSONObject o = new JSONObject();
                String pkg = event.getPackageName();
                if (pkg != null)
                    o.put("package", pkg);
                o.put("type", type);
                o.put("tsMs", event.getTimestamp());
                out.put(o);
            }
            root.put("granted", true);
            root.put("events", out);
        } catch (Exception e) {
            return errorJson("internal");
        }
        return root.toString();
    }

    /**
     * Map the UsageEvents constants the client derives StayFree's
     * opens / unlocks / notifications / hourly timeline from.  The
     * numeric constants are compile-time inlined, so old devices
     * merely never produce the newer event types.
     */
    private static String eventName(int type) {
        switch (type) {
        case UsageEvents.Event.ACTIVITY_RESUMED:
            return "resume";
        case UsageEvents.Event.ACTIVITY_PAUSED:
            return "pause";
        case UsageEvents.Event.SCREEN_INTERACTIVE:
            return "screen_on";
        case UsageEvents.Event.SCREEN_NON_INTERACTIVE:
            return "screen_off";
        case UsageEvents.Event.KEYGUARD_SHOWN:
            return "keyguard_shown";
        case UsageEvents.Event.KEYGUARD_HIDDEN:
            return "keyguard_hidden";
        case UsageEvents.Event.NOTIFICATION_SEEN:
            return "notification_seen";
        default:
            return null;
        }
    }

    /* ------------------------------------------------------------------ */
    /* Permission state.                                                   */
    /* ------------------------------------------------------------------ */

    /**
     * Usage Access is a "special app access" grant, not a runtime
     * permission: there is no dialog to request, the user flips it in
     * Settings.  checkOpNoThrow mirrors how every usage-access app
     * detects the state (the newer unsafeCheckOpNoThrow needs API 29;
     * the old call keeps working and lint is silenced like elsewhere
     * in this app).
     */
    @SuppressWarnings("deprecation")
    private static boolean usageGranted(Context context) {
        try {
            AppOpsManager ops =
                    (AppOpsManager) context.getSystemService(
                            Context.APP_OPS_SERVICE);
            int mode = ops.checkOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    Process.myUid(), context.getPackageName());
            return mode == AppOpsManager.MODE_ALLOWED;
        } catch (Exception e) {
            return false;
        }
    }

    private static String ungranted(JSONObject root) {
        try {
            root.put("granted", false);
            root.put("hint", "Grant this app 'Usage access' in Android"
                    + " Settings (Special app access), then pull again.");
        } catch (Exception ignored) {
            /* JSONObject of strings never throws here. */
        }
        return root.toString();
    }

    private static String errorJson(String what) {
        try {
            return new JSONObject().put("error", what).toString();
        } catch (Exception e) {
            return "{\"error\":\"internal\"}";
        }
    }

    /* ------------------------------------------------------------------ */
    /* Small helpers.                                                      */
    /* ------------------------------------------------------------------ */

    private static String hex(byte[] bytes) {
        /* & 0xff: String.format("%02x", byte) sign-extends negative
           bytes into eight characters -- the classic trap. */
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes)
            sb.append(String.format("%02x", b & 0xff));
        return sb.toString();
    }

    /** Write a tiny file (port/secret) atomically enough: tmp + rename. */
    private static void writeSmallFile(File dst, String content)
            throws IOException {
        File tmp = new File(dst.getParentFile(), dst.getName() + ".new");
        try (OutputStream out = new FileOutputStream(tmp)) {
            out.write(content.getBytes(StandardCharsets.UTF_8));
            out.flush();
        }
        if (!tmp.renameTo(dst))
            throw new IOException("rename of " + tmp + " failed");
    }
}
