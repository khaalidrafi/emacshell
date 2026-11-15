#!/bin/bash
# prepare-distro-rootfs.sh -- fetch and verify the pinned Alpine
# minirootfs for the distro flavor.
#
# The rootfs is NOT committed to git (~4 MB compressed, and keeping
# binary blobs out of the repo makes the supply chain reviewable);
# instead this script downloads the exact file named in
# pins/alpine-rootfs-aarch64.sha256, verifies it against the sha256
# recorded there (which was itself taken from the .sha256 file the
# Alpine project publishes next to the tarball), and leaves it in
# distro-assets/ (gitignored).  The Gradle build re-verifies the pin
# before installing it as an APK asset.
#
# Usage:
#   scripts/prepare-distro-rootfs.sh
#
# Environment overrides:
#   EMACSHELL_ALPINE_MIRROR   mirror root for /alpine/v3.22/releases/
#                             (default https://dl-cdn.alpinelinux.org)
#
# Idempotent: an existing file with the right hash is kept as-is.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

pin_file="pins/alpine-rootfs-aarch64.sha256"
url="$(sed -n 's/^url=//p' "${pin_file}" | tr -d '[:space:]')"
pin="$(sed -n 's/^sha256=//p' "${pin_file}" | tr -d '[:space:]')"
if [ -z "${url}" ] || [ -z "${pin}" ]; then
    echo "error: ${pin_file} is malformed (need url= and sha256=)" >&2
    exit 1
fi

# Rebuild the download URL from the mirror override + pinned path.
mirror="${EMACSHELL_ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org}"
path="${url#https://dl-cdn.alpinelinux.org}"
fetch_url="${mirror}${path}"
name="$(basename "${url}")"

out_dir="distro-assets"
mkdir -p "${out_dir}"
tarball="${out_dir}/${name}"

verify() {
    local actual
    actual="$(sha256sum "${tarball}" | awk '{print $1}')"
    if [ "${actual}" != "${pin}" ]; then
        echo "error: sha256 mismatch for ${tarball}" >&2
        echo "  expected: ${pin}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
}

if [ -f "${tarball}" ]; then
    echo "${tarball} exists; verifying pin"
    verify
else
    echo "Downloading ${fetch_url}"
    curl -fSL --retry 3 -o "${tarball}" "${fetch_url}"
    verify
    # Cross-check against the upstream-published .sha256 beside the
    # tarball as well; a mismatch here means our pin is stale, not that
    # the download is corrupt (verify() already established integrity).
    if curl -fsSL --retry 3 -o "${tarball}.upstream.sha256" "${fetch_url}.sha256"; then
        upstream="$(awk '{print $1}' "${tarball}.upstream.sha256")"
        rm -f "${tarball}.upstream.sha256"
        if [ "${upstream}" != "${pin}" ]; then
            echo "error: Alpine has published sha256 ${upstream} for ${name}," >&2
            echo "       but pins/alpine-rootfs-aarch64.sha256 records ${pin}." >&2
            echo "       Re-verify upstream and update the pin deliberately." >&2
            exit 1
        fi
    else
        echo "warning: could not fetch ${fetch_url}.sha256 for cross-check" >&2
    fi
fi

echo "OK: ${tarball} matches pin ${pin:0:16}..."
echo "The distro Gradle build will embed it as the emacshell/alpine-rootfs.tar.gz asset."
