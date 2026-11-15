#!/usr/bin/env python3
"""patch-emacs-java.py -- vendor GNU Emacs Android Java sources into the
:emacs Gradle module and apply the emacshell re-packaging patches.

GNU Emacs's Android Java layer hardcodes the package name
"org.gnu.emacs" in a handful of places.  emacshell ships under different
applicationIds (tech.khalidrafi.emacshell.termux / .distro) so it can be
installed side by side with upstream GNU Emacs, which means every
package-name lookup must be resolved dynamically instead.

This script:

  1. Copies the pristine org/gnu/emacs/*.java and res/ tree from the
     Emacs source tarball (java/ directory) into emacs/src/main/.
  2. Applies an exact, asserted series of string replacements (below in
     PATCHES) that replace the hardcoded package name with either
     getPackageName() (when a Context is in scope) or the per-flavor
     BuildConfig constant EMACSHELL_PACKAGE_NAME (only for
     EmacsNoninteractive, which runs before any Context exists).

Every replacement must occur the exact expected number of times or the
script fails loudly; a silent miss would break the app at runtime in
ways that are hard to debug (e.g. documents provider URIs pointing at
an app that is not installed).

Usage:
  patch-emacs-java.py [--tarball PATH | --java-src DIR] [--out DIR] [--check]

    --tarball     Path to emacs-31.1.tar.xz (source of java/ and java/res).
    --java-src    Path to an already-extracted java/ directory instead.
    --out         Output module source dir (default: emacs/src/main).
    --check       Do not write anything; verify that the files already in
                  --out contain all patched forms and none of the raw ones.

Sources of the tarball: https://ftp.gnu.org/gnu/emacs/emacs-31.1.tar.xz
(or any GNU mirror).  The Android Java layer lives in the top-level
java/ directory of the tarball.

Idempotent: the copy is always performed from the pristine source, so
running twice produces the same result.
"""

import argparse
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# The patch series.  Each entry: (file, old, new, expected_count).
#
# Site references are line numbers in the pristine emacs-31.1 java/
# sources; they are documentation for reviewers, the matching itself is
# exact-string.
#
# Deliberately NOT patched (documented decisions):
#
#   EmacsActivity.java:100  EXTRA_STARTUP_ARGUMENTS = "org.gnu.emacs.STARTUP_ARGUMENTS"
#     An intent-extra key, not a package lookup.  Extra keys are not
#     globally registered; keeping it identical to upstream preserves
#     compat with any external tooling that starts EmacsActivity.
#
#   EmacsDesktopNotification.java:58  NOTIFICATION_DISMISSED = "org.gnu.emacs.DISMISSED"
#     A broadcast action string used with setPackage(<our package>) and a
#     non-exported receiver; not a global namespace.  The manifest
#     declares the same literal, so sender and receiver stay in sync.
#
#   EmacsNoninteractive.java:214  loadClass ("org.gnu.emacs.EmacsNoninteractive")
#     This is a JAVA CLASS name, not an applicationId lookup.  emacshell
#     keeps the org.gnu.emacs java package for the Emacs classes, so this
#     string is correct as-is; patching it would break class loading.
# ---------------------------------------------------------------------------

PATCHES = [
    (
        "EmacsApplication.java",
        'info = manager.getApplicationInfo ("org.gnu.emacs", 0);',
        'info = manager.getApplicationInfo (getPackageName (), 0);',
        1,
    ),
    (
        "EmacsApplication.java",
        'info = manager.getApplicationInfo ("org.gnu.emacs",\n'
        "\t\t\t\t\t     ApplicationInfoFlags.of (0));",
        'info = manager.getApplicationInfo (getPackageName (),\n'
        "\t\t\t\t\t     ApplicationInfoFlags.of (0));",
        1,
    ),
    (
        "EmacsDesktopNotification.java",
        '= new RemoteViews ("org.gnu.emacs",',
        "= new RemoteViews (context.getPackageName (),",
        1,
    ),
    (
        "EmacsDesktopNotification.java",
        'intent.setPackage ("org.gnu.emacs");',
        "intent.setPackage (context.getPackageName ());",
        1,
    ),
    (
        # Lines 136, 153 and 170; the line-170 form is the same prefix
        # with ", file)" appended, so a single prefix replacement covers
        # all three sites.
        "EmacsDocumentsProvider.java",
        '= buildChildDocumentsUri ("org.gnu.emacs",',
        "= buildChildDocumentsUri (getContext ().getPackageName (),",
        3,
    ),
    (
        "EmacsNoninteractive.java",
        'loadedApk = method.invoke (activityThread, "org.gnu.emacs",\n'
        "\t\t\t\t       (Context.CONTEXT_INCLUDE_CODE",
        "loadedApk = method.invoke (activityThread,\n"
        "\t\t\t\t       BuildConfig.EMACSHELL_PACKAGE_NAME,\n"
        "\t\t\t\t       (Context.CONTEXT_INCLUDE_CODE",
        1,
    ),
    (
        "EmacsNoninteractive.java",
        'loadedApk = method.invoke (activityThread, "org.gnu.emacs",\n'
        "\t\t\t\t       null, (Context.CONTEXT_INCLUDE_CODE",
        "loadedApk = method.invoke (activityThread,\n"
        "\t\t\t\t       BuildConfig.EMACSHELL_PACKAGE_NAME,\n"
        "\t\t\t\t       null, (Context.CONTEXT_INCLUDE_CODE",
        1,
    ),
    (
        "EmacsNoninteractive.java",
        'context = (Context) method.invoke (context, "org.gnu.emacs",\n'
        "\t\t\t\t\t       0);",
        "context = (Context) method.invoke (context,\n"
        "\t\t\t\t\t       BuildConfig.EMACSHELL_PACKAGE_NAME, 0);",
        1,
    ),
    (
        "EmacsService.java",
        '= DocumentsContract.buildDocumentUri ("org.gnu.emacs",',
        "= DocumentsContract.buildDocumentUri (getPackageName (),",
        1,
    ),
    (
        "EmacsService.java",
        'Uri.parse ("package:org.gnu.emacs")',
        'Uri.parse ("package:" + getPackageName ())',
        1,
    ),
]

# Forbidden leftovers that would indicate an unpatched or wrongly patched
# tree (excluding the intentionally-kept literals listed above).
FORBIDDEN_RAW = [
    '"org.gnu.emacs",',
    '"org.gnu.emacs")',
    'parse ("package:org.gnu.emacs")',
]


def extract_java_dir(tarball: Path, tmpdir: Path) -> Path:
    """Extract <tarball>/emacs-<ver>/java into tmpdir, return java/ path."""
    with tarfile.open(tarball, "r:xz") as tar:
        members = [m for m in tar.getmembers() if m.name.count("/") >= 1]
        top = members[0].name.split("/")[0]
        java_members = [m for m in members if m.name.startswith(top + "/java/")]
        if not java_members:
            raise SystemExit(f"error: no java/ directory found inside {tarball}")
        tar.extractall(tmpdir, members=java_members, filter="data")
    return tmpdir / top / "java"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tarball", type=Path, default=None,
                    help="path to emacs-31.1.tar.xz")
    ap.add_argument("--java-src", type=Path, default=None,
                    help="path to already-extracted java/ directory")
    ap.add_argument("--out", type=Path,
                    default=Path(__file__).resolve().parent.parent / "emacs" / "src" / "main",
                    help="output module source directory")
    ap.add_argument("--check", action="store_true",
                    help="verify existing output instead of regenerating")
    args = ap.parse_args()

    if args.check:
        return check_only(args.out)

    if not args.tarball and not args.java_src:
        # Fall back to the research cache if present, else to the default
        # tarball name next to the script's build/ dir.
        default_src = Path(__file__).resolve().parent.parent / "build" / "emacs-31.1" / "java"
        default_tar = Path(__file__).resolve().parent.parent / "build" / "emacs-31.1.tar.xz"
        if default_src.is_dir():
            args.java_src = default_src
        elif default_tar.is_file():
            args.tarball = default_tar
        else:
            ap.error("need --tarball or --java-src (no build/emacs-31.1 cache found)")

    tmpdir = None
    if args.tarball:
        import tempfile
        tmpdir = Path(tempfile.mkdtemp(prefix="emacshell-emacs-java-"))
        java_src = extract_java_dir(args.tarball, tmpdir)
    else:
        java_src = args.java_src

    if not (java_src / "org" / "gnu" / "emacs").is_dir():
        print(f"error: {java_src} does not look like the Emacs java/ directory",
              file=sys.stderr)
        return 1

    java_out = args.out / "java" / "org" / "gnu" / "emacs"
    res_out = args.out / "res"

    # Wipe and re-copy so the operation is idempotent and never merges a
    # stale tree with a new one.
    shutil.rmtree(java_out, ignore_errors=True)
    shutil.rmtree(res_out, ignore_errors=True)
    java_out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(java_src / "org" / "gnu" / "emacs", java_out)
    shutil.copytree(java_src / "res", res_out)

    total_changed_lines = 0
    for filename, old, new, expected in PATCHES:
        path = java_out / filename
        text = path.read_text()
        count = text.count(old)
        if count != expected:
            print(f"error: {filename}: expected {expected} occurrence(s) of the "
                  f"upstream text, found {count}; refusing to produce a "
                  f"half-patched tree", file=sys.stderr)
            print("  upstream text was:\n" + old, file=sys.stderr)
            return 1
        patched = text.replace(old, new)
        path.write_text(patched)
        total_changed_lines += expected
        print(f"patched {filename}: {expected} site(s)")

    # Post-condition: no obviously unpatched lookup remains.
    failures = 0
    for filename, _, _, _ in PATCHES:
        text = (java_out / filename).read_text()
        for bad in FORBIDDEN_RAW:
            if bad in text:
                print(f"error: {filename} still contains raw form {bad!r}",
                      file=sys.stderr)
                failures += 1
    if failures:
        return 1

    print(f"OK: {len(PATCHES)} patch rules, {total_changed_lines} sites, "
          f"{len(list(java_out.glob('*.java')))} java files, res/ copied")
    if tmpdir:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return 0


def check_only(out: Path) -> int:
    """Verify that the tree under `out` is in the patched state."""
    java_out = out / "java" / "org" / "gnu" / "emacs"
    if not java_out.is_dir():
        print(f"error: {java_out} does not exist (run without --check first)",
              file=sys.stderr)
        return 1
    ok = True
    for filename, old, new, expected in PATCHES:
        text = (java_out / filename).read_text()
        have_new = text.count(new)
        have_old = text.count(old)
        if have_new < expected or have_old > 0:
            print(f"FAIL {filename}: {have_new}/{expected} patched forms, "
                  f"{have_old} raw upstream forms remain", file=sys.stderr)
            ok = False
        else:
            print(f"ok   {filename}: {have_new} patched site(s)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
