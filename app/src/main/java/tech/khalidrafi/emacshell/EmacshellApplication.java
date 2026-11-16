package tech.khalidrafi.emacshell;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.system.Os;
import android.util.Log;

import com.termux.app.TermuxInstaller;
import com.termux.shared.crash.TermuxCrashUtils;
import com.termux.shared.logger.Logger;
import com.termux.shared.settings.preferences.TermuxAppSharedPreferences;

import org.gnu.emacs.EmacsApplication;
import org.gnu.emacs.EmacsNative;

import tech.khalidrafi.emacshell.elwidget.ElwidgetWatcher;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Emacshell's merged Application class.
 *
 * One APK hosts two formerly separate apps: GNU Emacs (upstream
 * org.gnu.emacs.EmacsApplication) and Termux (upstream
 * com.termux.app.TermuxApplication).  Android allows exactly one
 * android:name per application, and neither upstream class can be
 * extended (EmacsApplication is final, and TermuxApplication's duties
 * alone would leave Emacs unstarted), so this class replicates both
 * onCreate() bodies verbatim in the order documented below.
 *
 * Ordering contract (mirrors both upstream classes):
 *
 *   1. Termux crash handler FIRST, so that any later failure produces a
 *      Termux-style crash report instead of a bare logcat line.
 *   2. Termux log level (from shared preferences).
 *   3. Emacs native thread setup, APK file name and dump file location,
 *      exactly as EmacsApplication.onCreate() does them; EmacsActivity
 *      relies on all three being done before it starts Emacs.
 *   4. First-boot init files, before any activity exists (Emacs loads
 *      ~/.emacs.d/init.el during startup and must not race us).
 *   5. Bootstrap + (distro flavor) Alpine rootfs staging, deferred until
 *      the first activity resumes; see onActivityResumed.
 */
public final class EmacshellApplication extends Application
        implements Application.ActivityLifecycleCallbacks {

    private static final String LOG_TAG = "EmacshellApplication";

    /** Set once the bootstrap kick-off happened for this process. */
    private boolean mBootstrapStarted;

    @Override
    public void onCreate() {
        super.onCreate();

        /* --- Termux half (mirrors com.termux.app.TermuxApplication) --- */
        TermuxCrashUtils.setCrashHandler(this);
        setLogLevel();

        /* --- Emacs half (mirrors org.gnu.emacs.EmacsApplication, which
              is final and cannot be extended; see the class comment) --- */
        EmacsNative.setupSystemThread();
        EmacsApplication.apkFileName = findApkFile();
        EmacsApplication.findDumpFile(this);

        /* --- Emacshell glue --- */
        installUserInitFiles();
        installVendoredPackages();

        /* elwidget home-screen widgets: watch the spec tree so bound
           widgets re-draw while this process (which also hosts Emacs)
           is alive.  No-op until Emacs has created the tree once. */
        ElwidgetWatcher.ensure(this);

        /* TermuxInstaller.setupBootstrapIfNeeded needs an Activity for
           its progress and error dialogs, so the bootstrap is started
           when the first activity resumes.  That is always EmacsActivity,
           the single launcher of both flavors. */
        registerActivityLifecycleCallbacks(this);
    }

    /**
     * Load the log level from shared preferences and apply it to the
     * Termux Logger, exactly as TermuxApplication.setLogLevel() does.
     */
    private void setLogLevel() {
        TermuxAppSharedPreferences preferences =
                TermuxAppSharedPreferences.build(getApplicationContext());
        if (preferences == null)
            return;
        preferences.setLogLevel(null, preferences.getLogLevel());
        Logger.logDebug("Starting Application");
    }

    /**
     * Replication of the private EmacsApplication.getApkFile(): the name
     * of the APK file backing this installation, or "" if it could not
     * be ascertained.  Uses getPackageName() rather than the upstream
     * hard-coded "org.gnu.emacs"; see scripts/patch-emacs-java.py for
     * the same change inside the Emacs sources themselves.
     */
    @SuppressWarnings("deprecation")
    private String findApkFile() {
        PackageManager manager;
        ApplicationInfo info;

        manager = getPackageManager();

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU)
                info = manager.getApplicationInfo(getPackageName(), 0);
            else
                info = manager.getApplicationInfo(getPackageName(),
                        PackageManager.ApplicationInfoFlags.of(0));

            /* Return an empty string upon failure, as upstream does. */
            if (info.sourceDir != null)
                return info.sourceDir;
        } catch (Exception e) {
            /* Fall through. */
        }
        return "";
    }

    /**
     * Write files/.emacs.d/{early-init,init}.el from the bundled assets
     * if (and only if) they are not present.  After the first boot these
     * files belong to the user and are never touched again, so upgrading
     * emacshell never clobbers user configuration.
     *
     * This runs synchronously in onCreate(): the files are a few KiB and
     * EmacsActivity would otherwise be able to start Emacs before the
     * init files land (it reads them during startup).
     */
    private void installUserInitFiles() {
        /* HOME on the Android port of Emacs is the app's files dir. */
        File emacsD = new File(getFilesDir(), ".emacs.d");
        if (!emacsD.isDirectory() && !emacsD.mkdirs()) {
            Logger.logError(LOG_TAG, "Cannot create " + emacsD
                    + "; first-boot init files not installed");
            return;
        }
        installAssetIfAbsent("emacshell/early-init.el",
                new File(emacsD, "early-init.el"));
        installAssetIfAbsent("emacshell/init.el",
                new File(emacsD, "init.el"));
    }

    /** Copy one asset to dst unless dst already exists (atomic rename). */
    private void installAssetIfAbsent(String asset, File dst) {
        if (dst.exists())
            return;
        File tmp = new File(dst.getParentFile(), dst.getName() + ".new");
        try (InputStream in = getAssets().open(asset);
             OutputStream out = new FileOutputStream(tmp)) {
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) > 0)
                out.write(buffer, 0, n);
            out.flush();
            if (!tmp.renameTo(dst))
                throw new IOException("rename of " + tmp + " failed");
            Logger.logInfo(LOG_TAG, "Installed " + dst);
        } catch (IOException e) {
            tmp.delete();
            Logger.logErrorExtended(LOG_TAG,
                    "Failed to install " + dst + ": " + e.getMessage());
        }
    }

    /* ------------------------------------------------------------------ */
    /* Vendored Elisp packages (site-lisp).                                */
    /* ------------------------------------------------------------------ */

    /**
     * Elisp packages shipped as app code (never user config): eservo
     * (browser automation), elwidget (the widget maker whose specs
     * the AppWidget host renders) and loophabits (the habit tracker
     * the org-habits widget reads).  Pinned by pins/<name>.txt +
     * pins/<name>.sha256.
     */
    private static final String[] VENDORED_PACKAGES =
            {"eservo", "elwidget", "loophabits"};

    /**
     * These packages are re-installed on every boot: upgrading
     * emacshell upgrades them.  User edits to these files have no
     * promise of survival; local customization goes into the
     * user-owned init.el instead (see README).
     *
     * Each directory is also put on EMACSLOADPATH so the packages are
     * loadable for EVERY install -- including installs whose
     * first-boot init.el predates a given package (those files are
     * user-owned and are never rewritten).  The trailing empty
     * element keeps Emacs's default load-path intact: an empty
     * element in EMACSLOADPATH stands for the default list.
     */
    private void installVendoredPackages() {
        File siteLisp = new File(new File(getFilesDir(), ".emacs.d"),
                "site-lisp");
        StringBuilder path = new StringBuilder();
        for (String name : VENDORED_PACKAGES) {
            File dir = new File(siteLisp, name);
            if (!dir.isDirectory() && !dir.mkdirs()) {
                Logger.logError(LOG_TAG, "Cannot create " + dir
                        + "; " + name + " not installed");
                continue;
            }
            installAssetDirRecursive("emacshell/" + name, dir);
            if (path.length() > 0)
                path.append(':');
            path.append(dir.getAbsolutePath());
        }
        if (path.length() == 0)
            return;
        String existing = System.getenv("EMACSLOADPATH");
        String loadpath = path + ":"
                + (existing == null ? "" : existing);
        try {
            Os.setenv("EMACSLOADPATH", loadpath, true);
        } catch (Exception e) {
            Logger.logError(LOG_TAG, "Cannot set EMACSLOADPATH: " + e);
        }
    }

    /** Recursively copy an asset directory to dst (plain overwrite). */
    private void installAssetDirRecursive(String assetDir, File dst) {
        try {
            String[] entries = getAssets().list(assetDir);
            if (entries == null)
                return;
            for (String entry : entries) {
                String childAsset = assetDir + "/" + entry;
                File childDst = new File(dst, entry);
                if (getAssets().list(childAsset).length == 0) {
                    /* Leaf file: copy verbatim (overwrite, app-owned). */
                    try (InputStream in = getAssets().open(childAsset);
                         OutputStream out = new FileOutputStream(childDst)) {
                        byte[] buffer = new byte[8192];
                        int n;
                        while ((n = in.read(buffer)) > 0)
                            out.write(buffer, 0, n);
                    }
                } else {
                    if (!childDst.isDirectory() && !childDst.mkdirs()) {
                        Logger.logError(LOG_TAG,
                                "Cannot create " + childDst);
                        continue;
                    }
                    installAssetDirRecursive(childAsset, childDst);
                }
            }
        } catch (IOException e) {
            Logger.logErrorExtended(LOG_TAG,
                    "Failed to install vendored package assets: "
                            + e.getMessage());
        }
    }

    /* ------------------------------------------------------------------ */
    /* Bootstrap and distro rootfs staging.                                */
    /* ------------------------------------------------------------------ */

    @Override
    public synchronized void onActivityResumed(Activity activity) {
        if (mBootstrapStarted)
            return;
        mBootstrapStarted = true;

        /* setupBootstrapIfNeeded itself spawns the worker thread that
           does the heavy extraction; the ProgressDialog it shows and the
           error dialogs run on this (UI) thread, which is why an
           Activity was required in the first place. */
        Logger.logInfo(LOG_TAG, "First activity resumed; starting bootstrap setup");
        TermuxInstaller.setupBootstrapIfNeeded(activity,
                this::onBootstrapInstalled);
    }

    /**
     * Runs on the UI thread once the Termux prefix is usable.  For the
     * distro flavor this is where the bundled Alpine rootfs gets staged
     * into the prefix for proot-distro; the termux flavor is done.
     */
    private void onBootstrapInstalled() {
        /* Flavor detection by applicationId suffix rather than
           BuildConfig: the id is the single source of truth that the
           bootstrap binaries themselves are compiled against, and it is
           what the distro/termux flavor split keys on everywhere else
           (manifest placeholders, TermuxConstants). */
        if (!getPackageName().endsWith(".distro"))
            return;

        new Thread(() -> {
            try {
                DistroRootfsStager.stage(EmacshellApplication.this);
            } catch (Exception e) {
                Logger.logErrorExtended(LOG_TAG,
                        "Failed to stage Alpine rootfs: " + Log.getStackTraceString(e));
            }
        }, "emacshell-rootfs").start();
    }

    /* Remaining ActivityLifecycleCallbacks: unused. */
    @Override public void onActivityCreated(Activity activity,
                                            android.os.Bundle savedInstanceState) { }
    @Override public void onActivityStarted(Activity activity) { }
    @Override public void onActivityPaused(Activity activity) { }
    @Override public void onActivityStopped(Activity activity) { }
    @Override public void onActivitySaveInstanceState(Activity activity,
                                                      android.os.Bundle outState) { }
    @Override public void onActivityDestroyed(Activity activity) { }
}
