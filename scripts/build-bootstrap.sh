#!/bin/bash
# build-bootstrap.sh -- build a CUSTOM-PREFIX Termux bootstrap for one
# emacshell flavor, using the official termux-packages Docker builder.
#
# WHY this script must exist at all:
#
#   Every Termux package hardcodes the prefix
#   /data/data/com.termux/files/usr at build time.  emacshell installs
#   under tech.khalidrafi.emacshell.{termux,distro}, so the OFFICIAL
#   bootstrap zip would unpack a prefix full of binaries that all point
#   at (and exec from) another app's data directory -- which Android
#   forbids and SELinux enforces.  The fix is to rebuild the bootstrap
#   from termux-packages with the applicationId exported as
#   TERMUX_APP__PACKAGE_NAME (upstream's current variable name; the
#   old TERMUX_APP_PACKAGE is exported too -- see the patch step
#   below); this is the approach sanctioned by the termux-packages
#   maintainers in issue #24396.
#
# WHAT it does:
#
#   1. Verifies that the release tag pinned in pins/termux-packages.txt
#      still resolves to the pinned commit (termux-packages release
#      discipline, Owner order 2026-11-18: bootstrap-YYYY.MM.DD-rN tags
#      only, never raw master), then clones it into
#      build/termux-packages.
#   2. Patches the pinned tree for two upstream drifts (see the patch
#      step below), then runs the upstream docker builder
#      (scripts/run-docker.sh -> scripts/build-bootstraps.sh) with the
#      flavor's applicationId (read from gradle.properties) exported
#      into the container.
#      The distro flavor additionally adds proot and proot-distro to
#      the bootstrap so `M-x emacshell-distro-login' works offline.
#   3. Moves the resulting bootstrap-aarch64.zip to
#      bootstrap/<flavor>/bootstrap-aarch64.zip and prints its sha256.
#
# THEN, by hand (pins are committed deliberately, never silently):
#
#   4. Review the output, then write the printed sha256 into
#      pins/bootstrap-<flavor>.sha256 (replacing the PLACEHOLDER).
#   5. Re-run the Gradle build; app/build.gradle verifies the pin and
#      embeds the zip into libtermux-bootstrap.so.
#
# Usage:
#   scripts/build-bootstrap.sh <termux|disto> [--source DIR]
#
#   --source DIR   reuse an existing termux-packages checkout instead
#                  of cloning (its HEAD must match the pin).
#
# Requirements: docker, curl, git.  Needs network access and roughly
# 1-2 hours per flavor on a fast machine (it builds ~100 packages).
#
# Idempotent: re-running rebuilds into the same output paths.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

readonly ARCH="aarch64"   # must match abiFilters in app/build.gradle

# --- arguments ---------------------------------------------------------------
flavor="${1:-}"
if [ "${flavor}" != "termux" ] && [ "${flavor}" != "distro" ]; then
    echo "usage: $0 <termux|distro> [--source DIR]" >&2
    exit 2
fi
shift || true

src=""
if [ "${1:-}" = "--source" ] && [ -n "${2:-}" ]; then
    src="${2}"
elif [ -n "${1:-}" ]; then
    echo "usage: $0 <termux|distro> [--source DIR]" >&2
    exit 2
fi

# --- the flavor's applicationId, from the single source of truth --------------
# gradle.properties defines applicationIdTermux / applicationIdDistro.
cap_flavor="$(printf '%s' "${flavor}" | sed 's/^./\U&/')"
app_id="$(sed -n "s/^applicationId${cap_flavor}=//p" gradle.properties | tr -d '[:space:]')"
if [ -z "${app_id}" ]; then
    echo "error: could not read applicationId${cap_flavor} from gradle.properties" >&2
    exit 1
fi
case "${app_id}" in
    tech.khalidrafi.emacshell."${flavor}") ;; # expected form
    *) echo "error: unexpected applicationId '${app_id}' for flavor '${flavor}'" >&2; exit 1 ;;
esac

# --- locate the pinned termux-packages checkout -------------------------------
pin_file="pins/termux-packages.txt"
tp_repo="$(sed -n 's/^repo=//p' "${pin_file}")"
tp_tag="$(sed -n 's/^tag=//p' "${pin_file}")"
tp_commit="$(sed -n 's/^commit=//p' "${pin_file}")"
if [ -z "${tp_repo}" ] || [ -z "${tp_tag}" ] || [ -z "${tp_commit}" ]; then
    echo "error: ${pin_file} is malformed (need repo=, tag= and commit=)" >&2
    exit 1
fi

# --- release-tag discipline (Owner order 2026-11-18) ---------------------------
# termux-packages tags every tree that produced an official bootstrap
# (bootstrap-YYYY.MM.DD-rN+apt.android-N); those tags are the only
# blessed inputs for bootstrap production -- master moves hourly and
# its middle states are nobody's release.  Fail BEFORE the two-hour
# docker build if the tag does not resolve to the pinned commit
# (annotated tags resolve through the peeled ^{} ref; the bootstrap
# tags are lightweight, where the ref itself is the commit).
tag_commit="$(git ls-remote "${tp_repo}" "refs/tags/${tp_tag}^{}" | awk '{print $1}')"
if [ -z "${tag_commit}" ]; then
    tag_commit="$(git ls-remote "${tp_repo}" "refs/tags/${tp_tag}" | awk '{print $1}')"
fi
if [ "${tag_commit}" != "${tp_commit}" ]; then
    echo "error: ${pin_file}: tag ${tp_tag} resolves to ${tag_commit:-nothing}, but commit= is ${tp_commit}" >&2
    echo "       move tag= and commit= together, to a termux-packages RELEASE tag" >&2
    exit 1
fi

echo "Pinned termux-packages release: ${tp_tag} (${tp_commit:0:12})"

if [ -z "${src}" ]; then
    cached="build/termux-packages"
    if [ -d "${cached}/.git" ] && [ "$(git -C "${cached}" rev-parse HEAD)" = "${tp_commit}" ]; then
        src="${cached}"
    else
        echo "Cloning ${tp_repo} at ${tp_tag} (${tp_commit}) into ${cached}"
        rm -rf "${cached}"
        mkdir -p "$(dirname "${cached}")"
        git clone --quiet "${tp_repo}" "${cached}"
        git -C "${cached}" checkout --quiet --detach "${tp_commit}"
        src="${cached}"
    fi
fi
actual="$(git -C "${src}" rev-parse HEAD 2>/dev/null || echo not-a-git-tree)"
if [ "${actual}" != "${tp_commit}" ]; then
    echo "error: ${src} is at ${actual}, pin expects ${tp_commit}" >&2
    exit 1
fi
echo "Building the '${flavor}' bootstrap (TERMUX_APP__PACKAGE_NAME=${app_id}) from ${src}"

# --- patch the pinned tree for emacshell (idempotent, fail-loud) ---------------
# SEVEN deliberate deviations from the pinned tree, re-applied on every
# clone.  A future pin bump that changes these lines FAILS here,
# forcing a deliberate re-review instead of silently shipping (see
# REVIEW.org 'Bootstrap upstream patches').
#
#   1. scripts/properties.sh hard-assigns TERMUX_APP__PACKAGE_NAME=
#      "com.termux", and EVERY prefix variable derives from it
#      (TERMUX_APP__DATA_DIR, TERMUX__ROOTFS, TERMUX__PREFIX, and the
#      deprecated TERMUX_APP_PACKAGE alias is only a shadow of it).
#      Since the upstream variable rename, exporting the old
#      TERMUX_APP_PACKAGE name is silently discarded -- run
#      44305581362 built every package under
#      /data/data/com.termux/files/usr despite our env.  Make the
#      default env-overridable so the flavor's applicationId lands.
#
#   2. scripts/build-bootstraps.sh still lists "bzip2", but upstream
#      removed packages/bzip2 -- the libbz2 package now ships the
#      bzip2/bunzip2/bzcat binaries itself (and is
#      TERMUX_PKG_ESSENTIAL).  Upstream's own bootstrap builder
#      breaks with "ERROR: No package bzip2 found" until this is
#      fixed there; swap the entry to libbz2 (functionally identical).
#
#   3. scripts/build-bootstraps.sh moves the finished zip into
#      $TERMUX_PACKAGES_DIRECTORY (the repo root of the bind mount).
#      run-docker.sh loads upstream's RESTRICTED AppArmor profile on
#      the container, which denies writes there except under paths
#      starting with 'o':
#          deny /home/builder/termux-packages/[^o]** wlk,
#          allow /home/builder/termux-packages/output/** rw,
#      So the final `mv` fails with "Permission denied" REGARDLESS of
#      unix permissions (AppArmor is mandatory access control; a
#      chmod cannot override it -- proven by run 44366062598, where
#      the chmod fix still died at the same mv).  Redirect the zip
#      into $TERMUX_BUILT_DEBS_DIRECTORY (output/), the path upstream
#      explicitly allows for build artifacts.
properties_file="${src}/scripts/properties.sh"
bootstraps_file="${src}/scripts/build-bootstraps.sh"
if grep -qE '^TERMUX_APP__PACKAGE_NAME=' "${properties_file}"; then
    sed -i 's|^TERMUX_APP__PACKAGE_NAME="com.termux"$|# emacshell patch: env-overridable default (upstream hard-assigns; see REVIEW.org Bootstrap upstream patches)\n: "${TERMUX_APP__PACKAGE_NAME:=com.termux}"|' "${properties_file}"
fi
if grep -qE '^TERMUX_APP__PACKAGE_NAME=' "${properties_file}"; then
    echo "error: ${properties_file} still hard-assigns TERMUX_APP__PACKAGE_NAME; the pinned tree changed -- re-derive the emacshell patches (REVIEW.org 'Bootstrap upstream patches')" >&2
    exit 1
fi
sed -i 's|^\(\s*\)PACKAGES+=("bzip2")$|\1PACKAGES+=("libbz2")|' "${bootstraps_file}"
if grep -q '"bzip2"' "${bootstraps_file}"; then
    echo "error: ${bootstraps_file} still references the removed 'bzip2' package; the pinned tree changed -- re-derive the emacshell patches (REVIEW.org 'Bootstrap upstream patches')" >&2
    exit 1
fi
# Patch 4: skip the dpkg-perl subpackage during bootstrap extraction.
#   Upstream declares dpkg-perl's runtime deps as "perl, clang, make"
#   (packages/dpkg/dpkg-perl.subpackage.sh) -- a whole toolchain that
#   is NOT in the bootstrap package set.  Extracting dpkg-perl anyway
#   (extract_debs takes every deb from output/) records
#   "Status: install ok installed" with unmet Depends, so the FIRST
#   `pkg upgrade` on a fresh device dies on unmet dependencies and,
#   pointed at the upstream repo, tries to install clang -- a
#   com.termux-prefixed package that cannot unpack under this
#   applicationId (the v0.1.4 field report).  dpkg-perl stays
#   available from the emacshell apt repo (packages.yml) for anyone
#   who actually builds debs on the phone.
sed -i 's@if \[\[ "$current_package_name" == \*"-static" \]\]; then@if [[ "$current_package_name" == *"-static" ]] || [[ "$current_package_name" == "dpkg-perl" ]]; then@' "${bootstraps_file}"
if ! grep -q '"dpkg-perl"' "${bootstraps_file}"; then
    echo "error: ${bootstraps_file} still extracts dpkg-perl; the pinned tree changed -- re-derive the emacshell patches (REVIEW.org 'Bootstrap upstream patches')" >&2
    exit 1
fi

# Patch 3: land the zip in output/ (AppArmor-allowed) instead of the
# repo root (AppArmor-denied).  mkdir -p in case no deb was produced
# yet (the dir normally exists because every package build drops its
# .debs there).
sed -i 's|^\tmv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" "\$TERMUX_PACKAGES_DIRECTORY/"$|\tmkdir -p "${TERMUX_BUILT_DEBS_DIRECTORY}"\n\tmv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" "${TERMUX_BUILT_DEBS_DIRECTORY}/"|' "${bootstraps_file}"
if ! grep -q 'mv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" "${TERMUX_BUILT_DEBS_DIRECTORY}/"' "${bootstraps_file}"; then
    echo "error: ${bootstraps_file} still moves the zip into the AppArmor-denied repo root; the pinned tree changed -- re-derive the emacshell patches (REVIEW.org 'Bootstrap upstream patches')" >&2
    exit 1
fi

# Patch 5: stretch termux_download's outer retry envelope.
#   Upstream's downloader (scripts/build/termux_download.sh) already
#   retries hard INSIDE curl (--retry 5, --retry-max-time 120) but its
#   outer loop is only retry=2 rounds with delay=60 -- about 5 minutes
#   total.  Run 45321600509 lost BOTH flavors to a mirrors.kernel.org
#   stall that lasted 20+ minutes: every round of make-4.4.1.tar.gz
#   and libunistring-1.5.tar.xz timed out on connect, and apt's build
#   died on different runners at 04:09Z and 04:23Z (the previous run,
#   45308285110, sailed through the same step an hour earlier).
#   retry=6 with delay=90 rides out a ~20-minute mirror outage;
#   everything else about the download logic stays upstream.
download_file="${src}/scripts/build/termux_download.sh"
sed -i 's|local retry=2|local retry=6|; s|local delay=60|local delay=90|' "${download_file}"
if ! grep -q 'local retry=6' "${download_file}"; then
    echo "error: ${download_file} retry envelope not stretched; the pinned tree changed -- re-derive the emacshell patches (REVIEW.org 'Bootstrap upstream patches')" >&2
    exit 1
fi

# Patch 6: teach termux-am's gradle to ride out Maven Central 429s.
#   Run 45332393627 (the patch-5 re-run) died deep inside the apt
#   build chain: apt depends on termux-am, whose build.sh downloads
#   gradle 8.10.2 and resolves the whole Android Gradle Plugin
#   classpath from repo.maven.apache.org -- which 429'd ("Too Many
#   Requests") every POM fetch for the full resolution window.
#   Gradle DOES retry 429s by itself (NetworkOperationBackOffAndRetry
#   treats SC_TOO_MANY_REQUESTS as transient), but its defaults are
#   max 3 attempts with a 1s initial backoff -- seconds against a
#   minutes-long rate-limit burst on shared runner IPs.  Raise both
#   through Gradle's own system properties: 8 attempts doubling from
#   5s ride out ~10.5 minutes.  build.sh hard-exports GRADLE_OPTS, so
#   the knobs must ride INSIDE that export (an env var from the
#   workflow would be silently clobbered).
termux_am_build="${src}/packages/termux-am/build.sh"
sed -i 's|-Dorg.gradle.java.home=/usr/lib/jvm/java-1.17.0-openjdk-amd64"|-Dorg.gradle.java.home=/usr/lib/jvm/java-1.17.0-openjdk-amd64 -Dorg.gradle.internal.network.retry.max.attempts=8 -Dorg.gradle.internal.network.retry.initial.backOff=5000"|' "${termux_am_build}"
if ! grep -q 'org.gradle.internal.network.retry.max.attempts=8' "${termux_am_build}"; then
    echo "error: ${termux_am_build} gradle network-retry knobs not applied; the pinned tree changed -- re-derive the emacshell patches (REVIEW.org 'Bootstrap upstream patches')" >&2
    exit 1
fi
#   Belt-and-suspenders, part 2 (the whole repo's doctrine, applied
#   inside the docker): Google's Maven Central mirror goes AHEAD of
#   mavenCentral() in TermuxAm's build.gradle via the package-dir patch
#   that termux_step_patch_package auto-applies.  Two laws learned the
#   hard way (run 45348312415, 'BUILD FAILED in 5s'):
#   (a) the URL must carry the /maven2 repository path -- the workflows
#       and settings.gradle all use ...googleapis.com/maven2; the bare
#       host 404s every artifact;
#   (b) mavenCentral() STAYS after the mirror as fallback -- replacing
#       it left no path to the artifacts when the mirror 404s; a mirror
#       miss falls through, and a mavenCentral 429 burst rides the
#       patch-6a knobs.  Re-derive against the TermuxAm tarball named by
#       packages/termux-am/build.sh TERMUX_PKG_SRCURL on any pin bump.
cat > "${src}/packages/termux-am/maven-central-mirror.patch" <<'EMACSHELL_EOF'
--- a/build.gradle
+++ b/build.gradle
@@ -1,6 +1,10 @@
 buildscript {
     repositories {
         google()
+        // emacshell: mirror ahead of mavenCentral() (the repo-wide
+        // MAVEN_CENTRAL_MIRROR doctrine, with the /maven2 path);
+        // mavenCentral() stays as the 429-riding fallback.
+        maven { url 'https://maven-central.storage-download.googleapis.com/maven2' }
         mavenCentral()
     }
     dependencies {
@@ -11,6 +15,10 @@
 allprojects {
     repositories {
         google()
+        // emacshell: mirror ahead of mavenCentral() (the repo-wide
+        // MAVEN_CENTRAL_MIRROR doctrine, with the /maven2 path);
+        // mavenCentral() stays as the 429-riding fallback.
+        maven { url 'https://maven-central.storage-download.googleapis.com/maven2' }
         mavenCentral()
     }
 }
EMACSHELL_EOF
if ! grep -q 'maven-central.storage-download.googleapis.com/maven2' "${src}/packages/termux-am/maven-central-mirror.patch"; then
    echo "error: the termux-am maven mirror patch was not written (or lost its /maven2 path); the pinned tree changed -- re-derive the emacshell patches (REVIEW.org 'Bootstrap upstream patches')" >&2
    exit 1
fi
if ! grep -q 'mavenCentral()' "${src}/packages/termux-am/maven-central-mirror.patch"; then
    echo "error: the termux-am patch dropped the mavenCentral() fallback; a mirror outage must not be fatal -- re-derive (REVIEW.org 'Bootstrap upstream patches')" >&2
    exit 1
fi

# --- run the upstream docker builder ------------------------------------------
# TERMUX_DOCKER_EXEC_EXTRA_ARGS is how run-docker.sh forwards environment
# into the container (it does not propagate the caller's env by itself).
build_args=(./scripts/build-bootstraps.sh --architectures "${ARCH}")
if [ "${flavor}" = "distro" ]; then
    # proot + proot-distro ride along in the distro bootstrap so that
    # `M-x emacshell-distro-login' needs no network round-trip on first
    # boot.  (--add appends one package per flag.)
    build_args+=(--add proot --add proot-distro)
fi

(
    cd "${src}"
    # The MODERN variable name is what properties.sh actually consumes
    # (the old name is a derived alias at the pinned tree); export both
    # so the invocation keeps working across pin bumps in either
    # direction.  Note the patch step above is still REQUIRED: even the
    # modern name is clobbered by the upstream hard assignment without
    # it.
    TERMUX_DOCKER_EXEC_EXTRA_ARGS="--env TERMUX_APP__PACKAGE_NAME=${app_id} --env TERMUX_APP_PACKAGE=${app_id}" \
        ./scripts/run-docker.sh "${build_args[@]}"
)

# --- collect the output --------------------------------------------------------
zip_path="$(find "${src}" -maxdepth 3 -name "bootstrap-${ARCH}.zip" -print -quit)"
if [ -z "${zip_path}" ]; then
    echo "error: no bootstrap-${ARCH}.zip produced under ${src}" >&2
    exit 1
fi

out_dir="bootstrap/${flavor}"
mkdir -p "${out_dir}"
cp -f "${zip_path}" "${out_dir}/bootstrap-${ARCH}.zip"

# Patch 7 (applied to the PRODUCT, not the tree): rewrite
# etc/apt/sources.list inside the produced bootstrap so the prefix is
# BORN pointing at the emacshell-packages repository.  The bootstrap's
# apt package ships the upstream termux-main line; on device,
# TermuxInstaller.fixAptSourcesList rewrites it at install time and
# site-start.el repairs older installs, but Owner order 2026-11-26
# (ready on install, no manual fix step)
# makes the bootstrap itself carry the right line from birth -- all
# three layers agree, and a future regression in any one still leaves
# the other two.  The zip entry is replaced in place; the sha256 below
# is computed AFTER the rewrite, so the pin commits the rewritten zip.
repo_tag="emacshell-packages-v1"
if [ "${flavor}" != "termux" ]; then
    repo_tag="emacshell-packages-${flavor}-v1"
fi
rewrite_dir="$(mktemp -d)"
mkdir -p "${rewrite_dir}/etc/apt"
{
    echo "# emacshell: this app's own repository (written into the bootstrap at build time; upstream repos are com.termux-prefixed)."
    echo "deb [trusted=yes] https://github.com/khaalidrafi/emacshell/releases/download/${repo_tag} ./"
} > "${rewrite_dir}/etc/apt/sources.list"
(
    cd "${rewrite_dir}"
    zip --quiet "${ROOT}/${out_dir}/bootstrap-${ARCH}.zip" etc/apt/sources.list
)
rm -rf "${rewrite_dir}"
# fail-loud: the entry must now carry the emacshell repository
if ! unzip -p "${out_dir}/bootstrap-${ARCH}.zip" etc/apt/sources.list \
        | grep -q "releases/download/${repo_tag}"; then
    echo "error: the bootstrap's etc/apt/sources.list does not name the ${repo_tag} repository (zip rewrite failed)" >&2
    exit 1
fi

hash="$(sha256sum "${out_dir}/bootstrap-${ARCH}.zip" | awk '{print $1}')"

echo
echo "Bootstrap for flavor '${flavor}' written to ${out_dir}/bootstrap-${ARCH}.zip"
echo "  sha256: ${hash}"
echo
echo "Next (pins are committed deliberately, never automatically):"
echo "  1. Review this build (it ran in a pinned docker image; see SECURITY.md)."
echo "  2. Write the sha256 above into pins/bootstrap-${flavor}.sha256,"
echo "     replacing the PLACEHOLDER line."
echo "  3. Re-run the Gradle build, which verifies the pin before embedding"
echo "     the zip into libtermux-bootstrap.so."
