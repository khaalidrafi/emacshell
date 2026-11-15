#!/bin/bash
# extract-gnu-apk.sh -- fetch a GNU-built Emacs Android APK and unpack its
# native libraries and assets into the :emacs Gradle module.
#
# Why this exists: emacshell does not rebuild Emacs.  It repackages the
# official GNU-built APK (verified by detached GPG signature in CI and by
# SHA256 pin here), which contains the prebuilt lib/<abi>/*.so set and the
# complete assets/ tree (lisp, etc, leim, ...) that Emacs on Android
# expects at those exact APK-internal paths.
#
# Usage:
#   scripts/extract-gnu-apk.sh [api] [abi]
#     api defaults to 29, abi defaults to arm64-v8a (must have a pin).
#
# Environment overrides:
#   EMACSHELL_GNU_MIRROR   GNU mirror root for /emacs/android/
#                          (default https://mirrors.kernel.org/gnu/emacs/android)
#   EMACSHELL_APK          use this local APK file instead of downloading
#                          (its sha256 must still match the pin).
#
# Output (all gitignored; never committed):
#   emacs/src/main/jniLibs/<abi>/*.so   from APK lib/<abi>/
#   emacs/src/main/assets/...           from APK assets/
#
# The assets land directly under the module assets root (assets/lisp/...,
# assets/etc/..., assets/directory-tree, ...) because Emacs's C runtime
# opens them through the Android AssetManager at exactly those paths;
# assets/directory-tree in particular is a pre-serialized tree of every
# asset entry that the C code walks instead of readdir(2).
#
# Idempotent: re-running replaces prior extraction output.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

api="${1:-29}"
abi="${2:-arm64-v8a}"
version="31.1"

mirror="${EMACSHELL_GNU_MIRROR:-https://mirrors.kernel.org/gnu/emacs/android}"
pins_file="${ROOT}/pins/gnu-apk.sha256"
cache_dir="${ROOT}/build/downloads"
emacs_module="${ROOT}/emacs"

pin="$(awk -v api="${api}" -v abi="${abi}" '$2 == api && $3 == abi {print $1}' "${pins_file}")"
if [ -z "${pin}" ]; then
    echo "error: no pin for api=${api} abi=${abi} in ${pins_file}" >&2
    exit 1
fi

apk_name="emacs-${version}-${api}-${abi}.apk"
expected_size_line="$(awk -v api="${api}" -v abi="${abi}" '$2 == api && $3 == abi {print $4}' "${pins_file}")"
# version column exists for documentation; sanity-check it parsed.
if [ -z "${expected_size_line}" ]; then
    echo "error: pin line for api=${api} abi=${abi} is malformed" >&2
    exit 1
fi

mkdir -p "${cache_dir}"

apk="${EMACSHELL_APK:-}"
if [ -z "${apk}" ]; then
    apk="${cache_dir}/${apk_name}"
    if [ ! -f "${apk}" ]; then
        url="${mirror}/${apk_name}"
        echo "Downloading ${url}"
        curl -fSL --retry 3 -o "${apk}" "${url}"
        # Fetch the detached signature too, for the CI GPG step and for
        # anyone who wants to verify locally with:
        #   gpg --verify <apk>.sig <apk>   (key: keys/emacs-release-key.asc)
        curl -fSL --retry 3 -o "${apk}.sig" "${url}.sig" || \
            echo "warning: could not fetch ${url}.sig (GPG verification skipped locally)" >&2
    fi
fi

echo "Verifying sha256 of ${apk}"
actual="$(sha256sum "${apk}" | awk '{print $1}')"
if [ "${actual}" != "${pin}" ]; then
    echo "error: sha256 mismatch for ${apk}" >&2
    echo "  expected: ${pin}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
fi

# --strip makes sure the extraction is redone cleanly rather than merged
# with a previous, possibly different, extraction.
jniLibs_dir="${emacs_module}/src/main/jniLibs/${abi}"
assets_dir="${emacs_module}/src/main/assets"

echo "Extracting lib/${abi}/ -> ${jniLibs_dir}"
rm -rf "${jniLibs_dir}"
mkdir -p "${jniLibs_dir}"
# -j (junk paths): the APK stores lib/<abi>/NAME, but AGP's jniLibs
# layout wants jniLibs/<abi>/NAME -- without -j unzip recreates the
# full lib/<abi>/ subtree under jniLibs/ and AGP finds nothing.
unzip -q -o -j "${apk}" "lib/${abi}/*" -d "${jniLibs_dir}"

echo "Extracting assets/ -> ${assets_dir}"
rm -rf "${assets_dir}"
mkdir -p "${assets_dir}"
# The APK-internal "assets/" prefix must be stripped: the Emacs C
# runtime opens AssetManager paths like "lisp/..." (the prefix is
# implicit in the APK format), and AGP packages src/main/assets/X as
# APK assets/X.  unzip cannot drop path components, so unpack into a
# scratch dir and move the subtree up.
scratch="${ROOT}/build/assets-unpack"
rm -rf "${scratch}"
mkdir -p "${scratch}"
unzip -q -o "${apk}" "assets/*" -d "${scratch}"
mv "${scratch}/assets/"* "${assets_dir}/"
rm -rf "${scratch}"

# The APK also contains res/, classes.dex and resources.arsc from GNU's own
# build; those are intentionally NOT extracted.  The Java layer is rebuilt
# from the Emacs source tarball (see scripts/patch-emacs-java.py) and the
# resource set is the one shipped in java/res of the same tarball, because
# APK-internal res/ is compiled binary XML that Gradle cannot consume.

so_count="$(find "${jniLibs_dir}" -name '*.so' | wc -l)"
asset_count="$(find "${assets_dir}" -type f | wc -l)"
echo "Done: ${so_count} native libraries, ${asset_count} asset files."
if [ "${so_count}" -lt 30 ] || [ "${asset_count}" -lt 4000 ]; then
    echo "error: extraction looks incomplete (expected >=30 libs and >=4000 assets)" >&2
    exit 1
fi

# Provenance marker for the Gradle build (gitignored, lives under
# build/): records WHICH pinned APK the current jniLibs/assets came
# from, so -PgnuApkApi can be cross-checked and an APK labelled
# "api21" can never silently contain api29 libraries (or vice versa).
marker="${ROOT}/build/gnu-apk-extracted"
mkdir -p "$(dirname "${marker}")"
printf '%s\n' "${pin} ${api} ${abi} ${version}" > "${marker}"
echo "Recorded extraction provenance: ${pin} ${api} ${abi} ${version}"
