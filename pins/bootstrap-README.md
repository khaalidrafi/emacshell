# How the custom-prefix bootstrap pins work
#
# (Companion to pins/bootstrap-termux.sha256 and
# pins/bootstrap-distro.sha256; read this before touching either.)

## The problem

Termux packages are built with their install prefix
`/data/data/com.termux/files/usr` compiled into the binaries (RPATH,
embedded paths in apt, shell scripts, the works).  emacshell installs
as `tech.khalidrafi.emacshell.termux` / `tech.khalidrafi.emacshell.distro`
(its whole reason to exist is side-by-side installability with upstream
Termux), so the official bootstrap would unpack a prefix whose binaries
all point into *another app's* data directory.  Android's SELinux policy
forbids that app from executing them, and `/data/data/com.termux` need
not even exist.  Result: a silently broken shell environment.

The same termux-app code that extracts the bootstrap zip
(`TermuxInstaller`) also derives every path from the *runtime*
applicationId, which is why the Java side needs no changes -- only the
zip contents do.

## The fix

Build our own bootstrap with the termux-packages Docker builder, with
the emacshell applicationId exported as `TERMUX_APP__PACKAGE_NAME`
(upstream's current variable name; the deprecated `TERMUX_APP_PACKAGE`
alias is exported too).  This is the approach the termux-packages
maintainers document for exactly this use case (termux/termux-packages#24396),
plus two post-clone patches to the pinned tree that
`scripts/build-bootstrap.sh` applies fail-loud on every run (upstream
removed packages/bzip2 while its bootstrap builder still lists it, and
its properties.sh hard-assigns the app package name so the prefix env
must be made overridable; see REVIEW.org "Bootstrap upstream patches").
`scripts/build-bootstrap.sh` automates it; `.github/workflows/bootstrap.yml`
runs it in CI.

The termux-packages tree itself is pinned to a **release tag**
(`pins/termux-packages.txt`: `bootstrap-YYYY.MM.DD-rN+apt.android-N`,
verified against `git ls-remote` on every build -- Owner order
2026-11-18, "You should use a release version"): those tags mark the
trees that produced official Termux bootstraps, while master moves
hourly and its middle states are nobody's release.

The distro flavor's bootstrap adds `proot` and `proot-distro`
(`--add proot --add proot-distro`) so `M-x emacshell-distro-login`
works on first boot without any network round-trip.

## The pins

`pins/bootstrap-<flavor>.sha256` holds the sha256 of the *expected*
`bootstrap/<flavor>/bootstrap-aarch64.zip`.  Until a bootstrap has been
built and reviewed, the file reads `PLACEHOLDER`, and the Gradle build
**fails** rather than embedding an official (wrong-prefix) bootstrap:
it is impossible to ship an APK that silently cannot run its shell.

Filling a pin in is always a human decision:

  1. Run `scripts/build-bootstrap.sh <flavor>` (Docker, ~1-2 h) or
     download the artifact from a `bootstrap.yml` workflow run.
  2. Place the zip at `bootstrap/<flavor>/bootstrap-aarch64.zip`
     (gitignored).
  3. Write the printed sha256 into `pins/bootstrap-<flavor>.sha256`,
     replacing `PLACEHOLDER`, and commit both the pin and (if vendoring
     the zip into the repo is ever desired) a deliberate decision in
     the commit message.

`app/build.gradle` re-verifies the pin on every build and copies the
zip into `app/src/main/cpp/`, where the vendored ndkBuild glue
(`termux-bootstrap-zip.S`) `.incbin`s it into
`libtermux-bootstrap.so`, from which `TermuxInstaller` extracts it to
`$PREFIX` on first boot.

`-PbootstrapZipOverride=/path/to/zip` bypasses the pin for local
experiments; it prints a loud warning and must never be used for
anything distributed.
