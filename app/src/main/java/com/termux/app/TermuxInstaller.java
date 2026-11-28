package com.termux.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.ProgressDialog;
import android.content.Context;
import android.os.Environment;
import android.system.Os;
import android.util.Pair;
import android.view.WindowManager;

import com.termux.R;
import com.termux.app.utils.CrashUtils;
import com.termux.shared.file.FileUtils;
import com.termux.shared.file.TermuxFileUtils;
import com.termux.shared.interact.MessageDialogUtils;
import com.termux.shared.logger.Logger;
import com.termux.shared.markdown.MarkdownUtils;
import com.termux.shared.models.ExecutionCommand;
import com.termux.shared.models.errors.Error;
import com.termux.shared.packages.PackageUtils;
import com.termux.shared.shell.TermuxShellEnvironmentClient;
import com.termux.shared.shell.TermuxTask;
import com.termux.shared.termux.TermuxConstants;
import com.termux.shared.termux.TermuxUtils;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import static com.termux.shared.termux.TermuxConstants.TERMUX_PREFIX_DIR;
import static com.termux.shared.termux.TermuxConstants.TERMUX_PREFIX_DIR_PATH;
import static com.termux.shared.termux.TermuxConstants.TERMUX_STAGING_PREFIX_DIR;
import static com.termux.shared.termux.TermuxConstants.TERMUX_STAGING_PREFIX_DIR_PATH;

/**
 * Install the Termux bootstrap packages if necessary by following the below steps:
 * <p/>
 * (1) If $PREFIX already exist, assume that it is correct and be done. Note that this relies on that we do not create a
 * broken $PREFIX directory below.
 * <p/>
 * (2) A progress dialog is shown with "Installing..." message and a spinner.
 * <p/>
 * (3) A staging directory, $STAGING_PREFIX, is cleared if left over from broken installation below.
 * <p/>
 * (4) The zip file is loaded from a shared library.
 * <p/>
 * (5) The zip, containing entries relative to the $PREFIX, is is downloaded and extracted by a zip input stream
 * continuously encountering zip file entries:
 * <p/>
 * (5.1) If the zip entry encountered is SYMLINKS.txt, go through it and remember all symlinks to setup.
 * <p/>
 * (5.2) For every other zip entry, extract it into $STAGING_PREFIX and set execute permissions if necessary.
 */
/* Emacshell: opened up from package-private so that
   tech.khalidrafi.emacshell.EmacshellApplication can start the
   bootstrap installation when the first EmacsActivity resumes. */
public final class TermuxInstaller {

    private static final String LOG_TAG = "TermuxInstaller";
    private static final AtomicBoolean sPrefixHealthChecked = new AtomicBoolean(false);
    private static final Object sPrefixHealthLock = new Object();

    /** Performs bootstrap setup if necessary. */
    public static void setupBootstrapIfNeeded(final Activity activity, final Runnable whenDone) {
        String bootstrapErrorMessage;
        Error filesDirectoryAccessibleError;

        // This will also call Context.getFilesDir(), which should ensure that termux files directory
        // is created if it does not already exist
        filesDirectoryAccessibleError = TermuxFileUtils.isTermuxFilesDirectoryAccessible(activity, true, true);
        boolean isFilesDirectoryAccessible = filesDirectoryAccessibleError == null;

        // Termux can only be run as the primary user (device owner) since only that
        // account has the expected file system paths. Verify that:
        if (!PackageUtils.isCurrentUserThePrimaryUser(activity)) {
            bootstrapErrorMessage = activity.getString(R.string.bootstrap_error_not_primary_user_message, MarkdownUtils.getMarkdownCodeForString(TERMUX_PREFIX_DIR_PATH, false));
            Logger.logError(LOG_TAG, "isFilesDirectoryAccessible: " + isFilesDirectoryAccessible);
            Logger.logError(LOG_TAG, bootstrapErrorMessage);
            sendBootstrapCrashReportNotification(activity, bootstrapErrorMessage);
            MessageDialogUtils.exitAppWithErrorMessage(activity,
                activity.getString(R.string.bootstrap_error_title),
                bootstrapErrorMessage);
            return;
        }

        if (!isFilesDirectoryAccessible) {
            bootstrapErrorMessage = Error.getMinimalErrorString(filesDirectoryAccessibleError) + "\nTERMUX_FILES_DIR: " + MarkdownUtils.getMarkdownCodeForString(TermuxConstants.TERMUX_FILES_DIR_PATH, false);
            Logger.logError(LOG_TAG, bootstrapErrorMessage);
            sendBootstrapCrashReportNotification(activity, bootstrapErrorMessage);
            MessageDialogUtils.showMessage(activity,
                activity.getString(R.string.bootstrap_error_title),
                bootstrapErrorMessage, null);
            return;
        }

        // If prefix directory exists, even if its a symlink to a valid directory and symlink is not broken/dangling
        if (FileUtils.directoryFileExists(TERMUX_PREFIX_DIR_PATH, true)) {
            File[] PREFIX_FILE_LIST =  TERMUX_PREFIX_DIR.listFiles();
            // If prefix directory is empty or only contains the tmp directory
            if(PREFIX_FILE_LIST == null || PREFIX_FILE_LIST.length == 0 || (PREFIX_FILE_LIST.length == 1 && TermuxConstants.TERMUX_TMP_PREFIX_DIR_PATH.equals(PREFIX_FILE_LIST[0].getAbsolutePath()))) {
                Logger.logInfo(LOG_TAG, "The termux prefix directory \"" + TERMUX_PREFIX_DIR_PATH + "\" exists but is empty or only contains the tmp directory.");
            } else {
                ensureExistingPrefixHealthyAsync(activity.getApplicationContext());
                whenDone.run();
                return;
            }
        } else if (FileUtils.fileExists(TERMUX_PREFIX_DIR_PATH, false)) {
            Logger.logInfo(LOG_TAG, "The termux prefix directory \"" + TERMUX_PREFIX_DIR_PATH + "\" does not exist but another file exists at its destination.");
        }

        final ProgressDialog progress = ProgressDialog.show(activity, null, activity.getString(R.string.bootstrap_installer_body), true, false);
        new Thread() {
            @Override
            public void run() {
                try {
                    Logger.logInfo(LOG_TAG, "Installing " + TermuxConstants.TERMUX_APP_NAME + " bootstrap packages.");

                    Error error;

                    // Delete prefix staging directory or any file at its destination
                    error = FileUtils.deleteFile("termux prefix staging directory", TERMUX_STAGING_PREFIX_DIR_PATH, true);
                    if (error != null) {
                        showBootstrapErrorDialog(activity, whenDone, Error.getErrorMarkdownString(error));
                        return;
                    }

                    // Delete prefix directory or any file at its destination
                    error = FileUtils.deleteFile("termux prefix directory", TERMUX_PREFIX_DIR_PATH, true);
                    if (error != null) {
                        showBootstrapErrorDialog(activity, whenDone, Error.getErrorMarkdownString(error));
                        return;
                    }

                    // Create prefix staging directory if it does not already exist and set required permissions
                    error = TermuxFileUtils.isTermuxPrefixStagingDirectoryAccessible(true, true);
                    if (error != null) {
                        showBootstrapErrorDialog(activity, whenDone, Error.getErrorMarkdownString(error));
                        return;
                    }

                    // Create prefix directory if it does not already exist and set required permissions
                    error = TermuxFileUtils.isTermuxPrefixDirectoryAccessible(true, true);
                    if (error != null) {
                        showBootstrapErrorDialog(activity, whenDone, Error.getErrorMarkdownString(error));
                        return;
                    }

                    Logger.logInfo(LOG_TAG, "Extracting bootstrap zip to prefix staging directory \"" + TERMUX_STAGING_PREFIX_DIR_PATH + "\".");

                    final byte[] buffer = new byte[8096];
                    final List<Pair<String, String>> symlinks = new ArrayList<>(50);

                    // Stream the bootstrap zip straight off the shared
                    // library's .rodata via a direct ByteBuffer.  The
                    // v0.1.5 heap-copy of the whole zip (~100 MB byte[])
                    // is what exhausted the heap on low-RAM devices
                    // (Redmi 8A class) during first-boot extraction.
                    final ByteBuffer zipBytes = loadZipBytes();
                    try (ZipInputStream zipInput = new ZipInputStream(new ByteBufferInputStream(zipBytes))) {
                        ZipEntry zipEntry;
                        while ((zipEntry = zipInput.getNextEntry()) != null) {
                            if (zipEntry.getName().equals("SYMLINKS.txt")) {
                                BufferedReader symlinksReader = new BufferedReader(new InputStreamReader(zipInput));
                                String line;
                                while ((line = symlinksReader.readLine()) != null) {
                                    String[] parts = line.split("←");
                                    if (parts.length != 2)
                                        throw new RuntimeException("Malformed symlink line: " + line);
                                    String oldPath = parts[0];
                                    String newPath = TERMUX_STAGING_PREFIX_DIR_PATH + "/" + parts[1];
                                    symlinks.add(Pair.create(oldPath, newPath));

                                    error = ensureDirectoryExists(new File(newPath).getParentFile());
                                    if (error != null) {
                                        showBootstrapErrorDialog(activity, whenDone, Error.getErrorMarkdownString(error));
                                        return;
                                    }
                                }
                            } else {
                                String zipEntryName = zipEntry.getName();
                                File targetFile = new File(TERMUX_STAGING_PREFIX_DIR_PATH, zipEntryName);
                                boolean isDirectory = zipEntry.isDirectory();

                                error = ensureDirectoryExists(isDirectory ? targetFile : targetFile.getParentFile());
                                if (error != null) {
                                    showBootstrapErrorDialog(activity, whenDone, Error.getErrorMarkdownString(error));
                                    return;
                                }

                                if (!isDirectory) {
                                    try (FileOutputStream outStream = new FileOutputStream(targetFile)) {
                                        int readBytes;
                                        while ((readBytes = zipInput.read(buffer)) != -1)
                                            outStream.write(buffer, 0, readBytes);
                                    }
                                    if (zipEntryName.startsWith("bin/") || zipEntryName.startsWith("libexec") ||
                                        zipEntryName.startsWith("lib/apt/apt-helper") || zipEntryName.startsWith("lib/apt/methods") ||
                                        zipEntryName.equals("etc/termux/bootstrap/termux-bootstrap-second-stage.sh")) {
                                        //noinspection OctalInteger
                                        Os.chmod(targetFile.getAbsolutePath(), 0700);
                                    }
                                }
                            }
                        }
                    }

                    if (symlinks.isEmpty())
                        throw new RuntimeException("No SYMLINKS.txt encountered");
                    for (Pair<String, String> symlink : symlinks) {
                        Os.symlink(symlink.first, symlink.second);
                    }

                    Logger.logInfo(LOG_TAG, "Moving termux prefix staging to prefix directory.");

                    if (!TERMUX_STAGING_PREFIX_DIR.renameTo(TERMUX_PREFIX_DIR)) {
                        throw new RuntimeException("Moving termux prefix staging to prefix directory failed");
                    }

                    // Emacshell: point apt at the app's own custom-prefix
                    // repository -- UNCONDITIONALLY, so a fresh install
                    // is ready to `pkg install' the moment the prefix
                    // lands (Owner order 2026-11-26).  The bootstrap's
                    // apt package ships a sources.list naming the
                    // UPSTREAM termux-main repo, whose packages are
                    // com.termux-prefixed and cannot be unpacked under
                    // this applicationId (dpkg dies with "error
                    // creating directory './data/data/com.termux':
                    // Permission denied").  packages.yml in the
                    // emacshell repo publishes the same packages
                    // rebuilt for this prefix under the
                    // emacshell-packages release tags (the
                    // apt-<flavor>-v1 tags were retired 2026-11-25).
                    fixAptSourcesList();

                    // Run Termux bootstrap second stage.
                    String termuxBootstrapSecondStageFile = TERMUX_PREFIX_DIR_PATH + "/etc/termux/bootstrap/termux-bootstrap-second-stage.sh";
                    if (!FileUtils.fileExists(termuxBootstrapSecondStageFile, false)) {
                        Logger.logInfo(LOG_TAG, "Not running Termux bootstrap second stage since script not found at \"" + termuxBootstrapSecondStageFile + "\" path.");
                    } else {
                        if (!FileUtils.fileExists(TermuxConstants.TERMUX_BIN_PREFIX_DIR_PATH + "/bash", true)) {
                            Logger.logInfo(LOG_TAG, "Not running Termux bootstrap second stage since bash not found.");
                        }
                        Logger.logInfo(LOG_TAG, "Running Termux bootstrap second stage.");

                        ExecutionCommand executionCommand = new ExecutionCommand(-1,
                            termuxBootstrapSecondStageFile, null, null,
                            null, true, false);
                        executionCommand.commandLabel = "Termux Bootstrap Second Stage Command";
                        executionCommand.backgroundCustomLogLevel = Logger.LOG_LEVEL_NORMAL;
                        TermuxTask termuxTask = TermuxTask.execute(activity, executionCommand, null, new TermuxShellEnvironmentClient(), true);
                        if (termuxTask == null || !executionCommand.isSuccessful() || executionCommand.resultData.exitCode != 0) {
                            // Generate debug report before deleting broken prefix directory to get `stat` info at time of failure.
                            showBootstrapErrorDialog(activity, whenDone, MarkdownUtils.getMarkdownCodeForString(executionCommand.toString(), true));

                            // Delete prefix directory as otherwise when app is restarted, the broken prefix directory would be used and logged into.
                            error = FileUtils.deleteFile("termux prefix directory", TERMUX_PREFIX_DIR_PATH, true);
                            if (error != null)
                                Logger.logErrorExtended(LOG_TAG, error.toString());
                            return;
                        }
                    }

                    // Clean up dpkg-perl if an older bootstrap left it in
                    // the status database (fresh bootstraps skip it via
                    // build-bootstrap.sh patch 4; this is defense-in-depth).
                    purgePoisonedDpkgPerl(activity.getApplicationContext());

                    Logger.logInfo(LOG_TAG, "Bootstrap packages installed successfully.");
                    activity.runOnUiThread(whenDone);

                } catch (final Exception e) {
                    showBootstrapErrorDialog(activity, whenDone, Logger.getStackTracesMarkdownString(null, Logger.getStackTracesStringArray(e)));

                } finally {
                    activity.runOnUiThread(() -> {
                        try {
                            progress.dismiss();
                        } catch (RuntimeException e) {
                            // Activity already dismissed - ignore.
                        }
                    });
                }
            }
        }.start();
    }

    /**
     * Emacshell: make $PREFIX/etc/apt/sources.list point at the app's
     * own repository (the emacshell-packages release) at the moment
     * the prefix lands.  The bootstrap's apt package ships a
     * sources.list naming the UPSTREAM termux-main repo, whose
     * packages are com.termux-prefixed and cannot be unpacked under
     * this applicationId (dpkg dies with "error creating directory
     * './data/data/com.termux': Permission denied").  packages.yml in
     * the emacshell repo publishes the same packages rebuilt for this
     * prefix under the emacshell-packages release tags (the
     * apt-<flavor>-v1 tags were retired 2026-11-25).
     *
     * Owner order 2026-11-26 (ready on install, no manual repair
     * step): the emacshell repository line is
     * written UNCONDITIONALLY -- a fresh install must be able to
     * `pkg install` immediately, with no manual repair step.  Retired
     * lines (upstream or pre-rename emacshell tags) are commented out
     * and preserved; a missing or empty sources.list is created;
     * idempotent.  The Elisp side (site-lisp emacshell package,
     * `termux-fix-repo', run from site-start.el at every interactive
     * startup) keeps doing the same for installs whose bootstrap
     * predates this fix.
     */
    private static void fixAptSourcesList() {
        try {
            File sources = new File(TERMUX_PREFIX_DIR_PATH, "etc/apt/sources.list");
            String flavor = TermuxConstants.TERMUX_PACKAGE_NAME.endsWith(".distro") ? "distro" : "termux";
            // The repository is named emacshell-packages; the termux
            // flavor owns the bare tag, other flavors append theirs.
            String repoTag = "termux".equals(flavor)
                ? "emacshell-packages-v1"
                : "emacshell-packages-" + flavor + "-v1";
            String repoLine = "deb [trusted=yes] https://github.com/khaalidrafi/emacshell/releases/download/"
                + repoTag + " ./";
            StringBuilder out = new StringBuilder();
            boolean staleReplaced = false;
            boolean repoLinePresent = false;
            if (sources.isFile()) {
                // BufferedReader over an InputStreamReader (not
                // java.nio.file.Files.newBufferedReader, which is API 26+;
                // the api-21 variant floor is API 24 and the raised
                // NoSuchMethodError is an Error, so the try/catch below
                // would NOT stop it from killing the bootstrap thread).
                try (BufferedReader reader = new BufferedReader(
                        new InputStreamReader(new FileInputStream(sources), "UTF-8"))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        if (line.startsWith("deb ")
                            && (line.contains("packages.termux.dev")
                                || line.contains("packages-cf.termux.dev")
                                // the retired pre-rename repo tags
                                || line.contains("/releases/download/apt-"))) {
                            out.append("# emacshell: retired repository line (upstream packages are com.termux-prefixed; the apt-* tags were renamed)\n");
                            out.append("# ").append(line).append('\n');
                            staleReplaced = true;
                        } else {
                            if (line.equals(repoLine))
                                repoLinePresent = true;
                            out.append(line).append('\n');
                        }
                    }
                }
            }
            if (!repoLinePresent) {
                if (!staleReplaced)
                    out.append("# emacshell: this app's own repository, ready on install (upstream repos are com.termux-prefixed)\n");
                out.append(repoLine).append('\n');
            }
            if (staleReplaced || !repoLinePresent) {
                Error error = FileUtils.createDirectoryFile(sources.getParentFile().getAbsolutePath());
                if (error == null) {
                    try (FileOutputStream fos = new FileOutputStream(sources)) {
                        fos.write(out.toString().getBytes("UTF-8"));
                    }
                    Logger.logInfo(LOG_TAG, "Wrote apt sources.list pointing at the emacshell repository");
                }
            }
        } catch (final Exception e) {
            // Never block the bootstrap over the repo fix.
            Logger.logWarnExtended(LOG_TAG, "Failed to fix apt sources.list: " + e.getMessage());
        }
    }

    /**
     * Emacshell: run prefix health checks (apt repository + dpkg-perl
     * cleanup) once per process in the background when a prefix already
     * exists on disk (e.g. upgrades from earlier APKs).
     */
    public static void ensureExistingPrefixHealthyAsync(final Context context) {
        if (!sPrefixHealthChecked.compareAndSet(false, true))
            return;
        final Context appContext = context.getApplicationContext();
        new Thread(() -> {
            if (!FileUtils.directoryFileExists(TERMUX_PREFIX_DIR_PATH, true))
                return;
            File[] files = TERMUX_PREFIX_DIR.listFiles();
            if (files == null || files.length == 0
                    || (files.length == 1 && TermuxConstants.TERMUX_TMP_PREFIX_DIR_PATH.equals(files[0].getAbsolutePath()))
                    || !new File(TERMUX_PREFIX_DIR_PATH, "bin").isDirectory())
                return;
            synchronized (sPrefixHealthLock) {
                fixAptSourcesList();
                purgePoisonedDpkgPerl(appContext);
            }
        }, "emacshell-prefix-health").start();
    }

    /**
     * Emacshell: upstream termux-packages builds dpkg-perl with
     * Depends: perl, clang, make -- a toolchain not shipped in the
     * bootstrap.  Bootstraps built before patch 4 recorded dpkg-perl as
     * installed, breaking `pkg upgrade'.  Purge it once from the
     * Android app layer when present in var/lib/dpkg/status.
     */
    private static void purgePoisonedDpkgPerl(final Context context) {
        try {
            File statusFile = new File(TERMUX_PREFIX_DIR_PATH, "var/lib/dpkg/status");
            if (!statusFile.isFile())
                return;

            boolean inDpkgPerl = false;
            boolean needsPurge = false;
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(new FileInputStream(statusFile), "UTF-8"))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    if (line.trim().isEmpty()) {
                        inDpkgPerl = false;
                    } else if ("Package: dpkg-perl".equals(line)) {
                        inDpkgPerl = true;
                    } else if (inDpkgPerl && line.startsWith("Status:")) {
                        if (!line.contains("not-installed")) {
                            needsPurge = true;
                            break;
                        }
                    }
                }
            }
            if (!needsPurge)
                return;

            File dpkg = new File(TERMUX_PREFIX_DIR_PATH, "bin/dpkg");
            if (!dpkg.canExecute()) {
                Logger.logWarn(LOG_TAG, "Cannot purge dpkg-perl: " + dpkg + " is not executable");
                return;
            }

            ExecutionCommand cmd = new ExecutionCommand(
                -1,
                dpkg.getAbsolutePath(),
                new String[]{"--purge", "--force-remove-reinstreq", "dpkg-perl"},
                null,
                null,
                true,
                false);
            cmd.commandLabel = "Purge dpkg-perl";
            cmd.backgroundCustomLogLevel = Logger.LOG_LEVEL_NORMAL;
            TermuxTask task = TermuxTask.execute(context, cmd, null, new TermuxShellEnvironmentClient(), true);
            if (task != null && cmd.isSuccessful() && cmd.resultData.exitCode == 0) {
                Logger.logInfo(LOG_TAG, "Purged poisoned dpkg-perl from existing prefix");
            } else {
                Logger.logWarnExtended(LOG_TAG, "dpkg --purge dpkg-perl did not succeed: " + cmd.toString());
            }
        } catch (final Exception e) {
            Logger.logWarnExtended(LOG_TAG, "Failed to check/purge dpkg-perl: " + e.getMessage());
        }
    }

    public static void showBootstrapErrorDialog(Activity activity, Runnable whenDone, String message) {
        Logger.logErrorExtended(LOG_TAG, "Bootstrap Error:\n" + message);

        // Send a notification with the exception so that the user knows why bootstrap setup failed
        sendBootstrapCrashReportNotification(activity, message);

        activity.runOnUiThread(() -> {
            try {
                new AlertDialog.Builder(activity).setTitle(R.string.bootstrap_error_title).setMessage(R.string.bootstrap_error_body)
                    .setNegativeButton(R.string.bootstrap_error_abort, (dialog, which) -> {
                        dialog.dismiss();
                        activity.finish();
                    })
                    .setPositiveButton(R.string.bootstrap_error_try_again, (dialog, which) -> {
                        dialog.dismiss();
                        FileUtils.deleteFile("termux prefix directory", TERMUX_PREFIX_DIR_PATH, true);
                        TermuxInstaller.setupBootstrapIfNeeded(activity, whenDone);
                    }).show();
            } catch (WindowManager.BadTokenException e1) {
                // Activity already dismissed - ignore.
            }
        });
    }

    private static void sendBootstrapCrashReportNotification(Activity activity, String message) {
        CrashUtils.sendCrashReportNotification(activity, LOG_TAG,
            "## Bootstrap Error\n\n" + message + "\n\n" +
                TermuxUtils.getTermuxDebugMarkdownString(activity),
            true, true);
    }

    /* Emacshell: public (upstream: package-private).  The storage
       symlink setup must also be triggerable from outside
       com.termux.app: EmacshellApplication's process-lifetime receiver
       handles `termux-setup-storage' broadcasts when TermuxActivity is
       not running (the normal case in emacshell, where the user lives
       in Emacs and TermuxActivity may never have been opened). */
    public static void setupStorageSymlinks(final Context context) {
        final String LOG_TAG = "termux-storage";

        Logger.logInfo(LOG_TAG, "Setting up storage symlinks.");

        new Thread() {
            public void run() {
                try {
                    Error error;
                    File storageDir = TermuxConstants.TERMUX_STORAGE_HOME_DIR;

                    error = FileUtils.clearDirectory("~/storage", storageDir.getAbsolutePath());
                    if (error != null) {
                        Logger.logErrorAndShowToast(context, LOG_TAG, error.getMessage());
                        Logger.logErrorExtended(LOG_TAG, "Setup Storage Error\n" + error.toString());
                        CrashUtils.sendCrashReportNotification(context, LOG_TAG, "## Setup Storage Error\n\n" + Error.getErrorMarkdownString(error), true, true);
                        return;
                    }

                    Logger.logInfo(LOG_TAG, "Setting up storage symlinks at ~/storage/shared, ~/storage/downloads, ~/storage/dcim, ~/storage/pictures, ~/storage/music and ~/storage/movies for directories in \"" + Environment.getExternalStorageDirectory().getAbsolutePath() + "\".");

                    File sharedDir = Environment.getExternalStorageDirectory();
                    Os.symlink(sharedDir.getAbsolutePath(), new File(storageDir, "shared").getAbsolutePath());

                    File downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
                    Os.symlink(downloadsDir.getAbsolutePath(), new File(storageDir, "downloads").getAbsolutePath());

                    File dcimDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM);
                    Os.symlink(dcimDir.getAbsolutePath(), new File(storageDir, "dcim").getAbsolutePath());

                    File picturesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES);
                    Os.symlink(picturesDir.getAbsolutePath(), new File(storageDir, "pictures").getAbsolutePath());

                    File musicDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC);
                    Os.symlink(musicDir.getAbsolutePath(), new File(storageDir, "music").getAbsolutePath());

                    File moviesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES);
                    Os.symlink(moviesDir.getAbsolutePath(), new File(storageDir, "movies").getAbsolutePath());

                    final File[] dirs = context.getExternalFilesDirs(null);
                    if (dirs != null && dirs.length > 1) {
                        for (int i = 1; i < dirs.length; i++) {
                            File dir = dirs[i];
                            if (dir == null) continue;
                            String symlinkName = "external-" + i;
                            Logger.logInfo(LOG_TAG, "Setting up storage symlinks at ~/storage/" + symlinkName + " for \"" + dir.getAbsolutePath() + "\".");
                            Os.symlink(dir.getAbsolutePath(), new File(storageDir, symlinkName).getAbsolutePath());
                        }
                    }

                    Logger.logInfo(LOG_TAG, "Storage symlinks created successfully.");
                } catch (Exception e) {
                    Logger.logErrorAndShowToast(context, LOG_TAG, e.getMessage());
                    Logger.logStackTraceWithMessage(LOG_TAG, "Setup Storage Error: Error setting up link", e);
                    CrashUtils.sendCrashReportNotification(context, LOG_TAG, "## Setup Storage Error\n\n" + Logger.getStackTracesMarkdownString(null, Logger.getStackTracesStringArray(e)), true, true);
                }
            }
        }.start();
    }

    private static Error ensureDirectoryExists(File directory) {
        return FileUtils.createDirectoryFile(directory.getAbsolutePath());
    }

    public static ByteBuffer loadZipBytes() {
        // Only load the shared library when necessary to save memory usage.
        System.loadLibrary("termux-bootstrap");
        return getZip();
    }

    public static native ByteBuffer getZip();

    /**
     * Streams a read-only direct ByteBuffer (the .rodata bootstrap zip)
     * without ever copying it onto the Java heap.  ZipInputStream only
     * reads, never writes, the buffer.
     */
    private static class ByteBufferInputStream extends InputStream {
        private final ByteBuffer byteBuffer;

        ByteBufferInputStream(ByteBuffer byteBuffer) {
            this.byteBuffer = byteBuffer;
        }

        @Override
        public int read() {
            if (!byteBuffer.hasRemaining())
                return -1;
            return byteBuffer.get() & 0xFF;
        }

        @Override
        public int read(byte[] buffer, int offset, int length) {
            if (!byteBuffer.hasRemaining())
                return -1;
            int readLength = Math.min(length, byteBuffer.remaining());
            byteBuffer.get(buffer, offset, readLength);
            return readLength;
        }
    }

}
