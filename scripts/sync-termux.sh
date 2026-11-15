#!/bin/bash
# sync-termux.sh -- vendor the pinned termux-app sources into this
# repository and apply the emacshell patch series.
#
# Why vendoring (copying in) instead of a git submodule or srcDir
# pointer: emacshell is a fork of the termux app's Java/UI layer, not a
# consumer of it.  Committing the (patched) sources makes every clone
# buildable offline and makes our patches visible in `git log` of THIS
# repository.  The upstream pin lives in pins/termux-app.txt.
#
# The vendored result is COMMITTED; this script is only re-run when
# moving to a newer upstream tag (see pins/termux-app.txt), at which
# point patches/termux/*.patch are re-applied (and, if they fail to
# apply, must be reworked first -- the script never fuzzz-matches).
#
# Ownership map (these subtrees are WIPED and re-created by this script;
# nothing else is touched):
#   app/src/main/AndroidManifest.xml   from upstream, then patched
#   app/src/main/java/com/             upstream app java
#   app/src/main/res/                  upstream app res
#   app/src/main/cpp/                  upstream ndkBuild glue (3 files;
#                                      bootstrap zips stay gitignored)
#   termux-shared/src/main/java/       upstream java
#   termux-shared/src/main/res/        upstream res
#   terminal-emulator/src/main/java/   upstream java
#   terminal-emulator/src/main/jni/    upstream native sources
#   terminal-view/src/main/java/       upstream java
#   terminal-view/src/main/res/        upstream res
#
# Deliberately NOT vendored:
#   - upstream Gradle files (emacshell has its own modern build)
#   - upstream module AndroidManifest.xml files (they only carry
#     package= attributes that AGP 8 rejects; namespaces live in our
#     build.gradle files; termux-shared's VIBRATE permission is
#     re-declared in our own minimal manifest)
#   - upstream dev_keystore.jks and its committed passwords
#
# Usage:
#   scripts/sync-termux.sh [--source DIR]
#
#   --source DIR   use an existing termux-app checkout (at the pinned
#                  commit) instead of fetching one.
#
# Without --source, an existing build/termux-app checkout is reused when
# its HEAD matches the pin; otherwise the pinned commit is fetched into
# build/termux-app (shallow).
#
# Idempotent: re-running against the same pin reproduces the same tree.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# --- read the pin ---------------------------------------------------------
pin_file="pins/termux-app.txt"
tag="$(sed -n 's/^tag=//p' "${pin_file}")"
commit="$(sed -n 's/^commit=//p' "${pin_file}")"
repo="$(sed -n 's/^repo=//p' "${pin_file}")"
if [ -z "${tag}" ] || [ -z "${commit}" ] || [ -z "${repo}" ]; then
    echo "error: ${pin_file} is malformed (need tag=, commit=, repo=)" >&2
    exit 1
fi

# --- locate or fetch the upstream clone -----------------------------------
src=""
if [ "${1:-}" = "--source" ] && [ -n "${2:-}" ]; then
    src="${2}"
elif [ -n "${1:-}" ]; then
    echo "usage: $0 [--source DIR]" >&2
    exit 2
fi

if [ -z "${src}" ]; then
    cached="build/termux-app"
    if [ -d "${cached}/.git" ] && [ "$(git -C "${cached}" rev-parse HEAD)" = "${commit}" ]; then
        src="${cached}"
    else
        echo "Fetching ${repo} at ${tag} (${commit}) into ${cached}"
        rm -rf "${cached}"
        mkdir -p "$(dirname "${cached}")"
        git clone --quiet --depth 1 --branch "${tag}" "${repo}" "${cached}"
        actual="$(git -C "${cached}" rev-parse HEAD)"
        if [ "${actual}" != "${commit}" ]; then
            echo "error: ${repo} ${tag} is now at ${actual}, pin expects ${commit}." >&2
            echo "       If upstream moved the tag, update pins/termux-app.txt and" >&2
            echo "       re-verify patches/termux/*.patch still apply." >&2
            exit 1
        fi
        src="${cached}"
    fi
fi

actual="$(git -C "${src}" rev-parse HEAD 2>/dev/null || echo not-a-git-tree)"
if [ "${actual}" != "${commit}" ]; then
    echo "error: source ${src} is at ${actual}, pin expects ${commit}" >&2
    exit 1
fi
echo "Vendoring from ${src} (${commit}, ${tag})"

# --- wipe and re-copy owned subtrees ---------------------------------------
wipe_and_copy() {
    local src_dir="$1" dst_dir="$2"
    rm -rf "${dst_dir}"
    mkdir -p "$(dirname "${dst_dir}")"
    cp -a "${src_dir}" "${dst_dir}"
}

wipe_and_copy "${src}/app/src/main/java/com"                 "app/src/main/java/com"
wipe_and_copy "${src}/app/src/main/res"                      "app/src/main/res"
wipe_and_copy "${src}/termux-shared/src/main/java"           "termux-shared/src/main/java"
wipe_and_copy "${src}/termux-shared/src/main/res"            "termux-shared/src/main/res"
wipe_and_copy "${src}/terminal-emulator/src/main/java"       "terminal-emulator/src/main/java"
wipe_and_copy "${src}/terminal-emulator/src/main/jni"        "terminal-emulator/src/main/jni"
wipe_and_copy "${src}/terminal-view/src/main/java"           "terminal-view/src/main/java"
wipe_and_copy "${src}/terminal-view/src/main/res"            "terminal-view/src/main/res"

cp -a "${src}/app/src/main/AndroidManifest.xml"              "app/src/main/AndroidManifest.xml"

# Only the three ndkBuild glue files; bootstrap zips are build outputs.
mkdir -p app/src/main/cpp
for f in Android.mk termux-bootstrap-zip.S termux-bootstrap.c; do
    cp -a "${src}/app/src/main/cpp/${f}" "app/src/main/cpp/${f}"
done
# Drop any bootstrap zips left over from a previous build so a stale or
# wrong-prefix zip can never be picked up accidentally.
rm -f app/src/main/cpp/bootstrap-*.zip

# --- apply the patch series -------------------------------------------------
# patch(1) must apply cleanly (--forward refuses fuzz); a failing patch
# means upstream drifted and the series must be reworked by hand.
shopt -s nullglob
patch_files=(patches/termux/*.patch)
shopt -u nullglob
if [ "${#patch_files[@]}" -eq 0 ]; then
    echo "error: no patches found under patches/termux/" >&2
    exit 1
fi
for p in "${patch_files[@]}"; do
    echo "Applying ${p}"
    patch --batch --forward -p1 < "${p}"
done

# --- sanity checks ----------------------------------------------------------
# Note: grep for the attribute form (with '='), not the bare word, since
# the explanatory comments in the vendored manifest mention it by name.
if grep -rn 'android:sharedUserId=' app/src/main/AndroidManifest.xml; then
    echo "error: sharedUserId attribute survived the patch series" >&2
    exit 1
fi
# The package= attribute may only appear on the <manifest> element; check
# that element specifically (the header comments mention package="com.termux"
# by name, so a naive grep would false-positive).
if sed -n '/<manifest/,/>/p' app/src/main/AndroidManifest.xml | grep -q 'package='; then
    echo "error: package= attribute survived the patch series (AGP 8 rejects it)" >&2
    exit 1
fi
if ! grep -q 'tech.khalidrafi.emacshell.EmacshellApplication' app/src/main/AndroidManifest.xml; then
    echo "error: EmacshellApplication not wired into the manifest" >&2
    exit 1
fi

java_files="$(find app/src/main/java/com termux-shared/src/main/java \
                   terminal-emulator/src/main/java terminal-view/src/main/java \
                   -name '*.java' | wc -l)"
echo "Done: vendored ${java_files} java files + patch series applied."
echo "Remember to review 'git diff' before committing a re-sync."
