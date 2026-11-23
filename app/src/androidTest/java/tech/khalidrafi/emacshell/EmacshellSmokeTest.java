package tech.khalidrafi.emacshell;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Emulator/device smoke tests for emacshell ("running and using the
 * app via emulation").
 *
 * The tests run INSIDE the application's own process (am instrument
 * with no target override), so they exercise exactly the SELinux
 * domain, UID and file layout the real app has: if the app cannot
 * exec() a binary from its data directory, or Emacs dies on boot, or
 * the usage bridge refuses the shared secret, these tests fail on the
 * emulator -- the same failure an end user would see as a crash or a
 * dead feature.
 *
 * Coverage (one test per user-visible capability):
 *
 *   emacsServiceComesUpAndStaysUp   EmacsActivity resumes and the
 *                                   process stays out of crash state;
 *                                   EmacsService (the native Emacs
 *                                   thread host) comes up.
 *   bootstrapInstallsBash           first-boot Termux bootstrap
 *                                   unpacks and files/usr/bin/bash
 *                                   appears.
 *   execBashFromAppData             exec() of a bootstrap binary FROM
 *                                   THE APP PROCESS works -- the
 *                                   "can Emacshell run binaries"
 *                                   question, answered by the OS.
 *   coreutilsAreExecutableFrom...   uname -m through the same exec
 *                                   path returns aarch64.
 *   initFilesInstalledWithExec...   early-init.el/init.el landed with
 *                                   the exec-path wiring.
 *   usageBridgeAnswersPing          the token-gated loopback bridge
 *                                   accepts PING with the
 *                                   boot-generated secret.
 *
 * Ordering: JUnit4 method order is not guaranteed, so every test
 * calls the launchMainActivity()/ensureBootstrap() helpers, which are
 * idempotent and process-wide.
 */
@RunWith(AndroidJUnit4.class)
public class EmacshellSmokeTest {

    /** Hard cap on the first-boot bootstrap extraction (emulator-safe:
        generous because CI may run under ARM ABI translation). */
    private static final long BOOTSTRAP_TIMEOUT_MS = TimeUnit.MINUTES.toMillis(15);

    /** How long to wait for the Emacs native thread host to appear
        (generous under ABI translation). */
    private static final long EMACS_UP_TIMEOUT_MS = TimeUnit.MINUTES.toMillis(6);

    private static boolean sLaunched;
    private static boolean sBootstrapDone;

    private Context target() {
        return InstrumentationRegistry.getInstrumentation().getTargetContext();
    }

    /** Prefix bin dir: files/usr (the app data dir IS HOME/files). */
    private File prefixBin() {
        return new File(target().getFilesDir(), "usr/bin");
    }

    private File emacsD() {
        return new File(target().getFilesDir(), ".emacs.d");
    }

    /**
     * Launch EmacsActivity (the single launcher of both flavors).
     * The first resume also triggers the first-boot bootstrap
     * extraction via EmacshellApplication.onActivityResumed().
     *
     * Deliberately NOT Instrumentation.startActivitySync: androidx's
     * MonitoringInstrumentation FINISHES activities it started that
     * way when a test ends ("MonitoringInstr: Finishing activity"),
     * and GNU Emacs kills the whole process when its last frame
     * closes -- which took the instrumentation process down with it
     * between tests (run 45269604538: clean exit 0 right after
     * "Finishing activity: org.gnu.emacs.EmacsActivity").  A plain
     * context.startActivity keeps the activity untracked, so it
     * survives for the whole suite like it does for a real user.
     */
    @Before
    public void launchMainActivity() throws Exception {
        if (sLaunched)
            return;
        Context ctx = target();
        PackageManager pm = ctx.getPackageManager();
        Intent launcher = pm.getLaunchIntentForPackage(ctx.getPackageName());
        assertNotNull("launcher intent for own package must resolve", launcher);
        launcher.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(launcher);
        // Give the activity a moment to come up; the assertions below
        // all wait on real signals (files, services), not on this.
        Thread.sleep(2000);
        sLaunched = true;
    }

    /**
     * Wait for the bootstrap extraction to complete, as signaled by
     * files/usr/bin/bash existing.  Idempotent across tests.
     */
    private void ensureBootstrap() throws Exception {
        if (sBootstrapDone)
            return;
        File bash = new File(prefixBin(), "bash");
        long deadline = System.currentTimeMillis() + BOOTSTRAP_TIMEOUT_MS;
        while (!bash.exists() && System.currentTimeMillis() < deadline) {
            assertFalse("process crashed while waiting for the bootstrap",
                    inCrashState());
            Thread.sleep(3000);
        }
        assertTrue("bootstrap did not install " + bash + " within "
                        + BOOTSTRAP_TIMEOUT_MS + " ms; first-boot extraction failed "
                        + "(see the logcat artifact for the progress/error dialog)",
                bash.exists());
        sBootstrapDone = true;
    }

    /** True when one of OUR processes is in crash/error state. */
    private boolean inCrashState() {
        ActivityManager am = (ActivityManager)
                target().getSystemService(Context.ACTIVITY_SERVICE);
        if (am == null)
            return false;
        List<ActivityManager.ProcessErrorStateInfo> bad =
                am.getProcessesInErrorState();
        if (bad == null)
            return false;
        for (ActivityManager.ProcessErrorStateInfo info : bad) {
            if (target().getPackageName().equals(info.processName))
                return true;
        }
        return false;
    }

    /** Non-null when a service with the given class name is running. */
    private String findRunningService(String className) {
        ActivityManager am = (ActivityManager)
                target().getSystemService(Context.ACTIVITY_SERVICE);
        if (am == null)
            return null;
        // getRunningServices() is deprecated but -- since Android O --
        // still returns the CALLER's own services, which is exactly
        // what this check needs (and all it ever gets).
        List<ActivityManager.RunningServiceInfo> services =
                am.getRunningServices(100);
        if (services == null)
            return null;
        for (ActivityManager.RunningServiceInfo info : services) {
            if (className.equals(info.service.getClassName()))
                return info.service.getClassName();
        }
        return null;
    }

    /* ------------------------------------------------------------------ */
    /* 1. The app runs                                                     */
    /* ------------------------------------------------------------------ */

    @Test
    public void emacsServiceComesUpAndStaysUp() throws Exception {
        launchMainActivity();
        long deadline = System.currentTimeMillis() + EMACS_UP_TIMEOUT_MS;
        String svc = null;
        while (svc == null && System.currentTimeMillis() < deadline) {
            assertFalse("app process entered crash state while Emacs booted",
                    inCrashState());
            svc = findRunningService("org.gnu.emacs.EmacsService");
            if (svc == null)
                Thread.sleep(5000);
        }
        assertNotNull("org.gnu.emacs.EmacsService did not come up within "
                        + EMACS_UP_TIMEOUT_MS + " ms; the native Emacs thread "
                        + "never started (check the logcat artifact)",
                svc);
        // And it survives: 30 quiet seconds without entering crash state.
        Thread.sleep(30000);
        assertFalse("app process entered crash state after Emacs booted",
                inCrashState());
        assertNotNull("EmacsService died within 30 s of starting",
                findRunningService("org.gnu.emacs.EmacsService"));
    }

    /* ------------------------------------------------------------------ */
    /* 2. The environment installs itself                                  */
    /* ------------------------------------------------------------------ */

    @Test
    public void bootstrapInstallsBash() throws Exception {
        launchMainActivity();
        ensureBootstrap();
        File bash = new File(prefixBin(), "bash");
        assertTrue("bash must be executable after extraction",
                bash.canExecute());
        assertTrue("the prefix etc dir is missing; extraction was partial",
                new File(target().getFilesDir(), "usr/etc").isDirectory());
    }

    /* ------------------------------------------------------------------ */
    /* 3. Executing binaries (the report that motivated these tests)       */
    /* ------------------------------------------------------------------ */

    @Test
    public void execBashFromAppData() throws Exception {
        launchMainActivity();
        ensureBootstrap();

        File bash = new File(prefixBin(), "bash");
        // Run from THIS process -- the app's own SELinux domain, the
        // same one Emacs's fork/exec runs under.  Android 10+ denies
        // exec of app-data files to apps TARGETING API 29+; emacshell
        // targets 28, so this must work on every Android version.
        ProcessBuilder pb = new ProcessBuilder(
                bash.getAbsolutePath(), "-c",
                "printf exec-ok-%s $((40 + 2))");
        Process proc = pb.start();

        StringBuilder out = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(
                proc.getInputStream(), StandardCharsets.UTF_8))) {
            int c;
            while ((c = r.read()) != -1)
                out.append((char) c);
        }
        int rc = proc.waitFor();
        assertEquals("bash exited non-zero; exec() of a bootstrap binary "
                        + "was refused (W^X/SELinux?) -- stdout: " + out,
                0, rc);
        assertEquals("bootstrap bash produced wrong output",
                "exec-ok-42", out.toString().trim());
    }

    @Test
    public void coreutilsAreExecutableFromThePrefix() throws Exception {
        launchMainActivity();
        ensureBootstrap();

        File uname = new File(prefixBin(), "uname");
        assertTrue("uname missing from the bootstrap", uname.exists());
        Process proc = new ProcessBuilder(
                uname.getAbsolutePath(), "-m").start();
        StringBuilder out = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(
                proc.getInputStream(), StandardCharsets.UTF_8))) {
            int c;
            while ((c = r.read()) != -1)
                out.append((char) c);
        }
        int rc = proc.waitFor();
        assertEquals("uname exited non-zero", 0, rc);
        // aarch64 on real arm64 devices; x86_64 when the CI emulator
        // runs the arm64 binaries through kernel-level ABI
        // translation (uname reports the emulated KERNEL's machine).
        String machine = out.toString().trim();
        assertTrue("uname -m must report aarch64 (arm64 device) or "
                        + "x86_64 (translated emulator), got: " + machine,
                machine.equals("aarch64") || machine.equals("x86_64"));
    }

    /* ------------------------------------------------------------------ */
    /* 4. The init files Emacs actually loads                              */
    /* ------------------------------------------------------------------ */

    @Test
    public void initFilesInstalledWithExecPathWiring() {
        launchMainActivity();
        File earlyInit = new File(emacsD(), "early-init.el");
        File initEl = new File(emacsD(), "init.el");
        assertTrue("early-init.el was not installed on first boot",
                earlyInit.isFile());
        assertTrue("init.el was not installed on first boot",
                initEl.isFile());

        String early = readAll(earlyInit);
        assertTrue("early-init.el must wire exec-path to the prefix",
                early.contains("exec-path"));
        assertTrue("early-init.el must export PREFIX",
                early.contains("PREFIX"));
    }

    private static String readAll(File f) {
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null)
                sb.append(line).append('\n');
            return sb.toString();
        } catch (Exception e) {
            throw new AssertionError("cannot read " + f, e);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 5. The usage bridge (org-activity's Android wire)                   */
    /* ------------------------------------------------------------------ */

    @Test
    public void usageBridgeAnswersPing() throws Exception {
        launchMainActivity();

        File portFile = new File(target().getFilesDir(),
                "emacshell-usage-port");
        File secretFile = new File(target().getFilesDir(),
                "emacshell-usage-secret");
        assertTrue("bridge port file missing; EmacshellUsageServer never "
                        + "started", portFile.isFile());
        assertTrue("bridge secret file missing", secretFile.isFile());

        int port = Integer.parseInt(readAll(portFile).trim());
        String secret = readAll(secretFile).trim();
        assertTrue("port file holds a bogus port: " + port,
                port > 1024 && port < 65536);

        try (Socket sock = new Socket()) {
            sock.connect(new InetSocketAddress(
                    InetAddress.getByName("127.0.0.1"), port), 5000);
            sock.setSoTimeout(10000);
            OutputStream out = sock.getOutputStream();
            out.write(("PING " + secret + "\n")
                    .getBytes(StandardCharsets.US_ASCII));
            out.flush();
            BufferedReader in = new BufferedReader(new InputStreamReader(
                    sock.getInputStream(), StandardCharsets.US_ASCII));
            String line = in.readLine();
            assertNotNull("bridge closed the connection without answering",
                    line);
            JSONObject json = new JSONObject(line);
            assertEquals("PING with the boot secret must be accepted",
                    true, json.optBoolean("ok", false));
        }
    }
}
