#!/bin/bash
# check.sh -- static consistency checks ("laws") for the emacshell repo.
#
# Everything here runs offline in seconds: shell syntax, XML/YAML
# well-formedness, the patched state of the vendored Emacs Java
# sources, pin file integrity, and the greppable invariants that keep
# emacshell installable side by side with upstream Emacs and Termux.
# CI runs this on every push (see .github/workflows/build.yml); run it
# locally before committing anything that touches the build.
#
# Usage: scripts/check.sh
# Exits non-zero if any check fails; all checks always run.

set -uo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PYTHON3="${PYTHON3:-python3}"
failures=0
total=0

ok()   { total=$((total+1)); printf 'ok   %s\n' "$1"; }
bad()  { total=$((total+1)); failures=$((failures+1)); printf 'FAIL %s\n' "$1"; }

# Committed source roots (build/ is research material and never checked).
src_roots=(app emacs termux-shared terminal-emulator terminal-view)

# --- 1. shell syntax ----------------------------------------------------------
for script in scripts/*.sh; do
    if bash -n "${script}" 2>/dev/null; then
        ok "bash -n ${script}"
    else
        bash -n "${script}" || true  # show the error
        bad "bash -n ${script}"
    fi
done

# --- 2. python syntax ---------------------------------------------------------
if "${PYTHON3}" -m py_compile scripts/patch-emacs-java.py 2>/dev/null; then
    ok "py_compile scripts/patch-emacs-java.py"
else
    bad "py_compile scripts/patch-emacs-java.py (run without 2>/dev/null to see the error)"
fi

# --- 3. XML well-formedness (every committed manifest/resource/icon) ----------
xml_failed=()
while IFS= read -r -d '' xml; do
    if ! "${PYTHON3}" - "${xml}" <<'EOF' 2>/dev/null
import sys, xml.sax
xml.sax.parse(sys.argv[1], xml.sax.ContentHandler())
EOF
    then
        xml_failed+=("${xml}")
    fi
done < <(find "${src_roots[@]}" -name '*.xml' -print0)
if [ "${#xml_failed[@]}" -eq 0 ]; then
    ok "all committed XML is well-formed"
else
    printf '     malformed: %s\n' "${xml_failed[@]}"
    bad "XML well-formedness (${#xml_failed[@]} file(s))"
fi

# --- 4. workflow YAML well-formedness -----------------------------------------
if "${PYTHON3}" -c 'import yaml' 2>/dev/null; then
    yml_failed=0
    for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
        [ -f "${wf}" ] || continue
        "${PYTHON3}" -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "${wf}" \
            || yml_failed=$((yml_failed+1))
    done
    [ "${yml_failed}" -eq 0 ] && ok "workflow YAML parses" || bad "workflow YAML parses (${yml_failed} file(s))"
else
    echo 'skip workflow YAML check (PyYAML not installed)'
fi

# --- 5. side-by-side laws ------------------------------------------------------
# Law: never a sharedUserId (the root cause of Termux prefix conflicts
# and an install-time collision with upstream Termux).
shared="$(find "${src_roots[@]}" -name '*.xml' -exec grep -l 'android:sharedUserId=' {} + 2>/dev/null || true)"
if [ -z "${shared}" ]; then
    ok "no android:sharedUserId in committed XML"
else
    printf '     found in: %s\n' "${shared}"
    bad "no android:sharedUserId in committed XML"
fi

# Law: the two applicationIds are exactly these, and they differ from
# each other and from the upstream package names.
if grep -q '^applicationIdTermux=tech\.khalidrafi\.emacshell\.termux$' gradle.properties \
   && grep -q '^applicationIdDistro=tech\.khalidrafi\.emacshell\.distro$' gradle.properties; then
    ok "applicationIds pinned in gradle.properties"
else
    bad "applicationIds pinned in gradle.properties"
fi

# Helper: print a manifest with its <!-- ... --> comments removed, so
# that the greps below match real attributes only and explanatory
# comments cannot cause false positives.
manifest_body() {
    "${PYTHON3}" - "$1" <<'EOF'
import re, sys
print(re.sub(r"<!--.*?-->", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.S))
EOF
}

# Law: the app manifest uses our merged Application class and the
# placeholder-driven authority, never hard-coded upstream names.
if grep -q 'android:name="tech\.khalidrafi\.emacshell\.EmacshellApplication"' app/src/main/AndroidManifest.xml; then
    ok "EmacshellApplication wired in the app manifest"
else
    bad "EmacshellApplication wired in the app manifest"
fi
if manifest_body app/src/main/AndroidManifest.xml | grep -q '\${TERMUX_PACKAGE_NAME}' \
   && ! manifest_body app/src/main/AndroidManifest.xml | grep -qE '(android:(name|authorities|permission))="com\.termux|"package:com\.termux'; then
    ok "app manifest uses \${TERMUX_PACKAGE_NAME}, no hard-coded com.termux"
else
    bad "app manifest uses \${TERMUX_PACKAGE_NAME}, no hard-coded com.termux"
fi
if manifest_body emacs/src/main/AndroidManifest.xml | grep -q '\${EMACSHELL_APPLICATION_ID}' \
   && ! manifest_body emacs/src/main/AndroidManifest.xml | grep -q '"org\.gnu\.emacs"'; then
    ok "emacs manifest authority is placeholder-driven"
else
    bad "emacs manifest authority is placeholder-driven"
fi

# Law: exactly one LAUNCHER intent filter in the whole merged manifest
# set -- EmacsActivity.  TermuxActivity must stay reachable but not be
# a launcher.
launcher_count="$(grep -c 'android.intent.category.LAUNCHER' \
    app/src/main/AndroidManifest.xml emacs/src/main/AndroidManifest.xml \
    | awk -F: '{s+=$2} END {print s+0}')"
if [ "${launcher_count}" -eq 1 ]; then
    ok "exactly one LAUNCHER category across manifests (EmacsActivity)"
else
    bad "exactly one LAUNCHER category across manifests (found ${launcher_count}, want 1)"
fi

# --- 6. pin files --------------------------------------------------------------
if awk '$2 == 29 && $3 == "arm64-v8a" && $1 ~ /^[0-9a-f]{64}$/' pins/gnu-apk.sha256 | grep -q .; then
    ok "pins/gnu-apk.sha256 has a 29/arm64-v8a entry"
else
    bad "pins/gnu-apk.sha256 has a 29/arm64-v8a entry"
fi
if grep -q '^tag=v0\.118\.3$' pins/termux-app.txt \
   && grep -qE '^commit=[0-9a-f]{40}$' pins/termux-app.txt; then
    ok "pins/termux-app.txt is well-formed (tag v0.118.3 + commit)"
else
    bad "pins/termux-app.txt is well-formed"
fi
if grep -qE '^repo=https://github\.com/termux/termux-packages$' pins/termux-packages.txt \
   && grep -qE '^commit=[0-9a-f]{40}$' pins/termux-packages.txt; then
    ok "pins/termux-packages.txt is well-formed"
else
    bad "pins/termux-packages.txt is well-formed"
fi
if grep -qE '^url=https://.+/alpine-minirootfs-.+-aarch64\.tar\.gz$' pins/alpine-rootfs-aarch64.sha256 \
   && grep -qE '^sha256=[0-9a-f]{64}$' pins/alpine-rootfs-aarch64.sha256; then
    ok "pins/alpine-rootfs-aarch64.sha256 is well-formed"
else
    bad "pins/alpine-rootfs-aarch64.sha256 is well-formed"
fi
for flavor in termux distro; do
    pin="pins/bootstrap-${flavor}.sha256"
    if [ -f "${pin}" ] \
       && grep -qE '^([0-9a-f]{64}|PLACEHOLDER)$' <(grep -v '^\s*#' "${pin}" | grep -v '^\s*$' || true); then
        ok "${pin} exists (hash or explicit PLACEHOLDER)"
    else
        bad "${pin} exists (hash or explicit PLACEHOLDER)"
    fi
done

# --- 7. vendored Emacs java is in the patched state -----------------------------
if "${PYTHON3}" scripts/patch-emacs-java.py --check >/dev/null 2>&1; then
    ok "vendored Emacs java passes patch-emacs-java.py --check"
else
    bad "vendored Emacs java passes patch-emacs-java.py --check"
fi

# --- 8. first-boot assets --------------------------------------------------------
for f in app/src/emacshell/assets/emacshell/early-init.el \
         app/src/termux/assets/emacshell/init.el \
         app/src/distro/assets/emacshell/init.el; do
    if [ -s "${f}" ]; then
        ok "first-boot asset ${f}"
    else
        bad "first-boot asset ${f} (missing or empty)"
    fi
done
if ! cmp -s app/src/termux/assets/emacshell/init.el app/src/distro/assets/emacshell/init.el; then
    ok "flavor init.el files differ (termux vs distro)"
else
    bad "flavor init.el files differ (they are identical)"
fi
if grep -q 'Emacshell (Termux)' app/src/termux/res/values/strings.xml \
   && grep -q 'Emacshell (Distro)' app/src/distro/res/values/strings.xml; then
    ok "flavor labels present and distinct"
else
    bad "flavor labels present and distinct"
fi

# --- 9. gradle wrapper + build files ---------------------------------------------
for f in gradlew gradlew.bat gradle/wrapper/gradle-wrapper.jar \
         gradle/wrapper/gradle-wrapper.properties settings.gradle build.gradle; do
    if [ -s "${f}" ]; then ok "present ${f}"; else bad "present ${f} (missing or empty)"; fi
done
if grep -q "gradle-8" gradle/wrapper/gradle-wrapper.properties; then
    ok "wrapper pins a Gradle 8 distribution"
else
    bad "wrapper pins a Gradle 8 distribution"
fi

# --- 10. supply-chain hygiene -----------------------------------------------------
if [ -s keys/emacs-release-key.asc ] && ! grep -q 'PRIVATE KEY' keys/emacs-release-key.asc; then
    ok "GNU release key present (public part only)"
else
    bad "GNU release key present (public part only)"
fi
leaked="$(find . -path ./build -prune -o -type f \( -name '*.jks' -o -name '*.keystore' -o -name '*.p12' -o -name '*.pem' \) -print 2>/dev/null || true)"
if [ -z "${leaked}" ]; then
    ok "no keystore/PEM files outside build/"
else
    printf '     found: %s\n' "${leaked}"
    bad "no keystore/PEM files outside build/"
fi
if grep -RIl --exclude-dir=build --exclude-dir=.git --exclude='check.sh' 'BEGIN.*PRIVATE KEY' . >/dev/null 2>&1; then
    bad "no private key material committed"
else
    ok "no private key material committed"
fi
if grep -q '^build/' .gitignore && grep -q 'bootstrap/' .gitignore && grep -q 'distro-assets/' .gitignore; then
    ok ".gitignore covers build/, bootstrap/ and distro-assets/"
else
    bad ".gitignore covers build/, bootstrap/ and distro-assets/"
fi

# --- summary -----------------------------------------------------------------------
echo
if [ "${failures}" -eq 0 ]; then
    echo "check.sh: all ${total} checks passed"
    exit 0
else
    echo "check.sh: ${failures} of ${total} checks FAILED"
    exit 1
fi
