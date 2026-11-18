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
#   1. Clones termux-packages at the commit pinned in
#      pins/termux-packages.txt into build/termux-packages.
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
tp_commit="$(sed -n 's/^commit=//p' "${pin_file}")"
if [ -z "${tp_repo}" ] || [ -z "${tp_commit}" ]; then
    echo "error: ${pin_file} is malformed (need repo= and commit=)" >&2
    exit 1
fi

if [ -z "${src}" ]; then
    cached="build/termux-packages"
    if [ -d "${cached}/.git" ] && [ "$(git -C "${cached}" rev-parse HEAD)" = "${tp_commit}" ]; then
        src="${cached}"
    else
        echo "Cloning ${tp_repo} at ${tp_commit} into ${cached}"
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
# Two deliberate deviations from the pinned tree, re-applied on every
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
