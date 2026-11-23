#!/usr/bin/env python3
"""gen-emacs-config.py -- generate EmacsConfig.java for the :emacs module.

GNU's Android build generates org/gnu/emacs/EmacsConfig.java after the
NDK libraries are built (emacs java/Makefile.in, cf-stamp-1 target): the
array EMACS_SHARED_LIBRARIES lists every application-provided shared
library, dependencies first, so the static block in EmacsNative can
System.loadLibrary() each of them on old Android releases whose linker
misconfigures the application library search path.

emacshell does not run GNU's build system: the libraries come from the
official, sha256-pinned GNU Emacs APK, unpacked into :emacs jniLibs by
scripts/extract-gnu-apk.sh.  This script recomputes the same list from
those .so files: it parses DT_NEEDED edges out of each ELF and walks
the DEPENDENCY CLOSURE OF libemacs.so depth-first (dependencies before
dependents, deduplicated), which yields exactly the set GNU's
readelf-driven resolution produces -- the executables and helper
programs the APK also carries under lib/*.so names (libloader.so,
libexec1.so, libetags.so, ...) are never DT_NEEDED entries of libemacs
and so never enter the list.  The baked array of the pinned GNU APK
(classes.dex) was decompiled and compared to verify this equivalence.

Usage:
  gen-emacs-config.py <jniLibs-dir> <output-file>
"""
import os
import struct
import sys

SHT_DYNAMIC = 6
DT_NEEDED = 1
DT_NULL = 0
ET_DYN = 3  # ELF shared object (2 = ET_EXEC: an executable, not loadable)


def is_loadable_elf(path):
    """True when PATH is an ELF *shared object* (ET_DYN), not an executable.
    GNU's APK ships helper programs (libloader.so, libexec1.so,
    libmovemail.so, libhexl.so, libetags.so, libebrowse.so,
    libemacsclient.so) and even scripts (librcs2log.so) under lib/*.so
    names, because Android only extracts lib/*.so -- they must be
    installed, never loadLibrary'd.  Run 45255178990 crashed exactly
    there: dlopen "libloader.so" -> 'unexpected e_type: 2'."""
    with open(path, 'rb') as fh:
        ident = fh.read(18)
    if len(ident) < 18 or ident[:4] != b'\x7fELF':
        return False
    if ident[4] != 2 or ident[5] != 1:      # not ELF64 LE
        return False
    return struct.unpack_from('<H', ident, 16)[0] == ET_DYN


def read_needed(path):
    """Return the DT_NEEDED library names of an ELF64 little-endian .so."""
    with open(path, 'rb') as fh:
        data = fh.read()
    if data[:4] != b'\x7fELF':
        raise ValueError('%s: not an ELF file' % path)
    if data[4] != 2:
        raise ValueError('%s: not ELF64' % path)
    if data[5] != 1:
        raise ValueError('%s: not little-endian' % path)
    e_shoff, = struct.unpack_from('<Q', data, 0x28)
    e_shentsize, e_shnum = struct.unpack_from('<HH', data, 0x3a)
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_type, = struct.unpack_from('<I', data, off + 4)
        sh_offset, sh_size = struct.unpack_from('<QQ', data, off + 0x18)
        sh_link, = struct.unpack_from('<I', data, off + 0x28)
        sections.append((sh_type, sh_offset, sh_size, sh_link))
    dynamic = next(((o, s, l) for (t, o, s, l) in sections if t == SHT_DYNAMIC),
                   None)
    if dynamic is None:
        return []
    _, dyn_size, str_idx = dynamic
    st_type, str_offset, str_size, _ = sections[str_idx]
    dynstr = data[str_offset:str_offset + str_size]
    dyn_offset, _, _ = dynamic
    needed = []
    for i in range(0, dyn_size, 16):
        d_tag, d_val = struct.unpack_from('<qQ', data, dyn_offset + i)
        if d_tag == DT_NULL:
            break
        if d_tag == DT_NEEDED:
            end = dynstr.find(b'\x00', d_val)
            needed.append(dynstr[d_val:end].decode())
    return needed


def compute_order(libs):
    """Dependency closure of libemacs.so, dependencies first.

    This mirrors GNU's own generation (java/Makefile.in, cf-stamp-1:
    readelf-driven recursive resolution of the ndk-build shared
    modules): the array lists what libemacs itself needs, so that
    EmacsNative can pre-load it on old Android releases whose linker
    misconfigures the application library search path.  Verified
    against the pinned GNU APK itself (its dex carries the baked
    array): 28 app libraries + the four system libs the Java side
    skips -- and crucially NO executables (libloader.so, libexec1.so,
    ...) and NO libandroid-emacs.so, none of which libemacs NEEDs.
    Starting from "every .so in the dir" instead is what crashed
    runs 45253125133 (.so.so names) and 45255178990 (dlopen of the
    ET_EXEC libloader.so).
    """
    if 'libemacs.so' not in libs:
        raise SystemExit('error: libemacs.so not found under the jniLibs '
                         'dir -- cannot derive the load order')
    order = []
    seen = set()

    def visit(name):
        if name in seen:
            return
        seen.add(name)
        for dep in sorted(libs.get(name, ())):
            if dep in libs and dep != name:
                visit(dep)
        order.append(name)

    visit('libemacs.so')
    return order


def main():
    if len(sys.argv) < 3:
        raise SystemExit('usage: gen-emacs-config.py <jniLibs-dir> '
                         '<output-file>')
    jni_dir, out_path = sys.argv[1], sys.argv[2]
    libs = {}
    skipped = []
    for fn in sorted(os.listdir(jni_dir)):
        path = os.path.join(jni_dir, fn)
        if fn.endswith('.so') and os.path.isfile(path) \
                and not os.path.islink(path):
            # Only real loadable ELF shared objects (ET_DYN) belong in
            # EMACS_SHARED_LIBRARIES; executables and scripts disguised
            # as lib*.so are skipped (see is_loadable_elf).
            if not is_loadable_elf(path):
                skipped.append(fn)
                continue
            libs[fn] = set(read_needed(path))
    if skipped:
        print('skipped non-loadable lib*.so payloads (GNU executables'
              ' and scripts): ' + ', '.join(skipped))
    if not libs:
        raise SystemExit('error: no ELF .so libraries under %s' % jni_dir)
    order = compute_order(libs)
    # EmacsNative's static block strips a leading "lib" from each entry
    # and hands the rest to System.loadLibrary, which itself appends
    # ".so" (and re-adds "lib") when resolving.  GNU's own EmacsConfig
    # therefore carries BARE names ("pixman_emacs", not
    # "libpixman_emacs.so"): emitting filenames here made every launch
    # die with UnsatisfiedLinkError: dlopen "libandroid-emacs.so.so"
    # (emulator run 45253125133, the Owner's api29 crash).  libemacs
    # itself is excluded: EmacsNative loads it explicitly after the
    # loop, exactly as GNU's array does.
    entries = ', '.join('"%s"' % n[:-3]
                        for n in order if n != 'libemacs.so')
    content = (
        'package org.gnu.emacs;\n'
        '\n'
        '/** This is a generated file.  Do not edit!\n'
        ' *\n'
        ' *  Regenerated by scripts/gen-emacs-config.py (invoked by\n'
        ' *  scripts/extract-gnu-apk.sh) from the sha256-pinned GNU Emacs\n'
        ' *  APK native libraries unpacked into :emacs jniLibs.  Mirrors\n'
        ' *  GNU\'s own EmacsConfig generation (java/Makefile.in,\n'
        ' *  cf-stamp-1): every application-provided shared library,\n'
        ' *  dependencies first, deduplicated, so EmacsNative can preload\n'
        ' *  them on old Android releases.\n'
        ' */\n'
        'public class EmacsConfig\n'
        '{\n'
        'public static final String[] EMACS_SHARED_LIBRARIES\n'
        '= {%s,};\n'
        '}\n' % entries)
    with open(out_path, 'w') as fh:
        fh.write(content)
    unresolved = set()
    for deps in libs.values():
        unresolved.update(d for d in deps if d not in libs)
    print('EmacsConfig.java: %d preload libraries (+ libemacs loaded'
          ' separately); system deps skipped: %s'
          % (len(order) - 1, ', '.join(sorted(unresolved)) or 'none'))
    print('order: %s' % ', '.join(n[:-3] for n in order))


if __name__ == '__main__':
    main()
