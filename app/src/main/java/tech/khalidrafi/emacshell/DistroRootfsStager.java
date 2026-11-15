package tech.khalidrafi.emacshell;

import android.content.Context;

import com.termux.shared.logger.Logger;
import com.termux.shared.termux.TermuxConstants;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.zip.GZIPInputStream;

/**
 * Stages the Alpine minirootfs bundled as an APK asset (distro flavor)
 * into the location proot-distro expects:
 *
 *   $PREFIX/var/lib/proot-distro/installed-rootfs/alpine/
 *
 * Why manual extraction instead of calling `proot-distro install`:
 * the distro bootstrap ships proot-distro as a shell script whose
 * install path downloads from the network; feeding it a local tarball
 * would both depend on undocumented CLI details and require executing
 * prefix binaries that may not have settled yet.  Laying the rootfs out
 * by hand is exactly what the install command ends up doing (unpack a
 * tarball under installed-rootfs/<alias>/), works fully offline, and is
 * verified against the build-time sha256 pin before it ever enters the
 * APK (see scripts/prepare-distro-rootfs.sh and app/build.gradle).
 */
final class DistroRootfsStager {

    private static final String LOG_TAG = "EmacshellRootfs";

    /** APK-internal asset path (see app/src/distro/assets). */
    private static final String ROOTFS_ASSET = "emacshell/alpine-rootfs.tar.gz";

    /** proot-distro's alias for the bundled distribution. */
    private static final String DISTRO_ALIAS = "alpine";

    private DistroRootfsStager() {
    }

    /**
     * Idempotent: does nothing when the rootfs is already staged.
     * Extracts into a sibling staging directory first and renames on
     * success so a killed process can never leave a half-installed
     * rootfs under the final name.
     */
    static void stage(Context context) throws IOException {
        File prefix = TermuxConstants.TERMUX_PREFIX_DIR; /* files/usr */
        if (!prefix.isDirectory()) {
            /* The bootstrap failed or has not run; nothing we can do
               from here except report and let the user retry. */
            Logger.logError(LOG_TAG, "Termux prefix missing; cannot stage rootfs");
            return;
        }

        File installedRootfs = new File(prefix,
                "var/lib/proot-distro/installed-rootfs");
        File alpine = new File(installedRootfs, DISTRO_ALIAS);
        /* bin is a symlink to usr/bin in modern Alpine minirootfs, and
           File.exists() follows symlinks, so this is the right "fully
           staged" test. */
        if (new File(alpine, "bin/sh").exists()) {
            Logger.logInfo(LOG_TAG, "Alpine rootfs already staged");
            return;
        }

        if (!installedRootfs.isDirectory() && !installedRootfs.mkdirs())
            throw new IOException("Cannot create " + installedRootfs);

        File staging = new File(installedRootfs, DISTRO_ALIAS + "-staging");
        deleteRecursive(staging);
        if (!staging.mkdirs())
            throw new IOException("Cannot create " + staging);

        Logger.logInfo(LOG_TAG, "Extracting bundled Alpine rootfs to " + staging);
        try (InputStream in = context.getAssets().open(ROOTFS_ASSET)) {
            TarExtractor.extract(
                    new GZIPInputStream(new BufferedInputStream(in, 1 << 16)),
                    staging);
        } catch (IOException e) {
            deleteRecursive(staging);
            throw e;
        }

        if (!new File(staging, "bin/sh").exists())
            throw new IOException("rootfs asset did not contain bin/sh; "
                    + "refusing to activate (broken or wrong tarball?)");

        if (!staging.renameTo(alpine))
            throw new IOException("rename " + staging + " -> " + alpine
                    + " failed");

        Logger.logInfo(LOG_TAG, "Alpine rootfs staged at " + alpine
                + "; M-x emacshell-distro-login is now available");
    }

    private static void deleteRecursive(File file) {
        File[] children = file.listFiles();
        if (children != null)
            for (File child : children)
                deleteRecursive(child);
        file.delete();
    }
}
