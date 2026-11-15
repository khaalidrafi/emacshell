package tech.khalidrafi.emacshell;

import android.system.ErrnoException;
import android.system.Os;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Minimal streaming tar reader used to unpack the bundled Alpine
 * minirootfs (see DistroRootfsStager).  Android ships no tar library,
 * and adding a dependency (commons-compress et al.) for one
 * well-defined input format would drag in more attack surface than
 * these ~200 lines of ustar parsing.
 *
 * Supported entry types: regular files ('0' and '\0'), directories
 * ('5'), symlinks ('2'), GNU long names ('L') and PAX extended headers
 * with a "path=" record ('x'/'g').  Hard links, devices and fifos are
 * skipped: none of them occur in an Alpine minirootfs, and creating
 * them would require privileges the app does not have anyway.  Modes
 * are applied with Os.chmod/Os.symlink; ownership is left to the
 * filesystem (the app user), which is what proot-distro's own
 * extraction does as well.
 *
 * Security: every entry path is resolved against the destination
 * directory and rejected if it escapes it (zip-slip guard).
 */
final class TarExtractor {

    private static final int BLOCK = 512;

    private TarExtractor() {
    }

    /** Extract the ustar stream `tar' into `dstDir' (created if absent). */
    static void extract(InputStream tar, File dstDir) throws IOException {
        if (!dstDir.isDirectory() && !dstDir.mkdirs())
            throw new IOException("Cannot create " + dstDir);
        String canonicalDst = dstDir.getCanonicalPath() + File.separator;

        byte[] header = new byte[BLOCK];
        String pendingLongName = null;   /* from the previous 'L' entry */
        String pendingPaxPath = null;    /* from the previous 'x' entry */
        String name = null;

        while (readFully(tar, header)) {
            long size = parseOctal(header, 124, 12);
            char type = typeFlag(header);
            String linkName = string(header, 157, 100);
            String prefix = string(header, 345, 155);

            if (isAllZero(header)) {
                /* Two zero blocks mark the end; be lenient about one. */
                skip(tar, size);
                continue;
            }

            /* Entry name: prefix field (ustar) + name, possibly
               overridden by a GNU long name or PAX path record. */
            String base = string(header, 0, 100);
            name = base;
            if (!prefix.isEmpty())
                name = prefix + "/" + base;
            if (pendingLongName != null) {
                name = pendingLongName;
                pendingLongName = null;
            }
            if (pendingPaxPath != null) {
                name = pendingPaxPath;
                pendingPaxPath = null;
            }
            if (name.isEmpty() || name.equals("./"))
                name = ".";

            File target = resolveWithin(canonicalDst, dstDir, name);

            switch (type) {
                case 'L': /* GNU long name: data block holds the name. */
                    pendingLongName = readString(tar, size);
                    break;

                case 'x':
                case 'g': /* PAX header: look for a path= record. */
                    pendingPaxPath = paxPath(readBytes(tar, size));
                    break;

                case '5':
                    if (!target.isDirectory() && !target.mkdirs())
                        throw new IOException("Cannot create dir " + target);
                    applyMode(target, header, true);
                    skip(tar, size);
                    break;

                case '2':
                    /* Remove a previous entry at the same path (a tar can
                       legitimately contain dir-then-symlink). */
                    if (target.exists())
                        delete(target);
                    try {
                        Os.symlink(linkName, target.getAbsolutePath());
                    } catch (ErrnoException e) {
                        throw new IOException("symlink " + name + " -> "
                                + linkName + ": " + e.getMessage());
                    }
                    skip(tar, size);
                    break;

                case '0':
                case '\0':
                    writeFile(tar, target, size);
                    applyMode(target, header, false);
                    break;

                default:
                    /* Hard links, devices, fifos: skip payload. */
                    skip(tar, size);
                    break;
            }
        }
    }

    /* ------------------------------------------------------------------ */

    private static void writeFile(InputStream in, File target, long size)
            throws IOException {
        File parent = target.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs())
            throw new IOException("Cannot create " + parent);
        try (OutputStream out = new FileOutputStream(target)) {
            byte[] buffer = new byte[1 << 15];
            long remaining = size;
            int n;
            while (remaining > 0 && (n = in.read(buffer, 0,
                    (int) Math.min(buffer.length, remaining))) > 0) {
                out.write(buffer, 0, n);
                remaining -= n;
            }
            if (remaining != 0)
                throw new IOException("Truncated tar: " + target);
        }
        /* Skip padding to the next 512-byte boundary. */
        long pad = (-size) & (BLOCK - 1);
        skip(in, pad);
    }

    private static void applyMode(File target, byte[] header, boolean isDir)
            throws IOException {
        int mode = (int) parseOctal(header, 100, 8) & 0777;
        if (mode == 0)
            return;
        try {
            Os.chmod(target.getAbsolutePath(), mode);
        } catch (ErrnoException e) {
            throw new IOException("chmod " + target + " to "
                    + Integer.toOctalString(mode) + ": " + e.getMessage());
        }
    }

    private static File resolveWithin(String canonicalDst, File dstDir,
                                      String name) throws IOException {
        File resolved = new File(dstDir, name);
        String canonical = resolved.getCanonicalPath();
        if (!(canonical + File.separator).startsWith(canonicalDst))
            throw new IOException("tar entry escapes destination: " + name);
        return resolved;
    }

    private static void delete(File file) {
        File[] children = file.listFiles();
        if (children != null)
            for (File child : children)
                delete(child);
        file.delete();
    }

    private static void skip(InputStream in, long n) throws IOException {
        long remaining = n;
        while (remaining > 0) {
            long skipped = in.skip(remaining);
            if (skipped <= 0) {
                if (in.read() == -1)
                    return; /* EOF; truncated tar is reported by callers. */
                remaining--;
            } else {
                remaining -= skipped;
            }
        }
    }

    private static boolean readFully(InputStream in, byte[] buffer)
            throws IOException {
        int off = 0;
        while (off < buffer.length) {
            int n = in.read(buffer, off, buffer.length - off);
            if (n < 0)
                return off == 0; /* clean EOF between entries */
            off += n;
        }
        return true;
    }

    private static byte[] readBytes(InputStream in, long size)
            throws IOException {
        if (size > (100 << 20))
            throw new IOException("Oversized tar metadata block: " + size);
        byte[] data = new byte[(int) size];
        int off = 0;
        while (off < data.length) {
            int n = in.read(data, off, data.length - off);
            if (n < 0)
                throw new IOException("Truncated tar metadata block");
            off += n;
        }
        skip(in, (-size) & (BLOCK - 1));
        return data;
    }

    private static String readString(InputStream in, long size)
            throws IOException {
        return new String(readBytes(in, size), StandardCharsets.UTF_8)
                .split("\0", 2)[0];
    }

    /**
     * Extract the "path=" record from a PAX extended header, if any.
     * Records are "<length> key=value\n" sequences.
     */
    private static String paxPath(byte[] data) {
        String text = new String(data, StandardCharsets.UTF_8);
        for (String line : text.split("\n")) {
            int space = line.indexOf(' ');
            if (space < 0)
                continue;
            String record = line.substring(space + 1);
            if (record.startsWith("path="))
                return record.substring("path=".length());
        }
        return null;
    }

    private static char typeFlag(byte[] header) {
        byte t = header[156];
        return t == 0 ? '\0' : (char) t;
    }

    private static String string(byte[] header, int off, int len) {
        int end = off;
        int limit = Math.min(off + len, header.length);
        while (end < limit && header[end] != 0)
            end++;
        return new String(header, off, end - off, StandardCharsets.UTF_8)
                .trim();
    }

    private static long parseOctal(byte[] header, int off, int len) {
        long value = 0;
        boolean any = false;
        for (int i = off; i < off + len && i < header.length; i++) {
            byte b = header[i];
            if (b == 0 || b == ' ')
                continue; /* skip NUL/space padding on both sides */
            if (b < '0' || b > '7')
                break;
            value = (value << 3) | (b - '0');
            any = true;
        }
        return any ? value : 0;
    }

    private static boolean isAllZero(byte[] header) {
        for (byte b : header)
            if (b != 0)
                return false;
        return true;
    }
}
