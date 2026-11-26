#!/bin/sh
# Comprehensive crash reproduction & diagnostics on the API 35 KVM emulator.
# Runs on branch ai/debug-v015-crash--gh_google to diagnose the v0.1.5 P0 crash.
set -ux

DIAG="summary-diag.txt"
: > "${DIAG}"

log_diag() {
  printf '%s\n' "$1" | tee -a "${DIAG}"
}

check_pkg_alive() {
  pkg="$1"
  label="$2"
  logfile="$3"
  pid="$(adb shell pidof "${pkg}" 2>/dev/null | tr -d '\r\n' || true)"
  adb logcat -d > "${logfile}" || true
  log_diag "=== ${label}: pid='${pid}' ==="
  grep -E 'FATAL EXCEPTION|AndroidRuntime|SIGABRT|SIGSEGV|FORTIFY|Fatal signal|UnsatisfiedLinkError|NoClassDefFoundError|Bootstrap Error|Termux:Crash|android_run_debug_thread.*(Error|error|abort|Abort)|Process .* died' "${logfile}" | head -n 40 >> "${DIAG}" || true
  # Also inspect app files & any Termux crash log via run-as (for debug builds)
  adb shell "run-as ${pkg} ls -la files files/.emacs.d files/.emacs.d/site-lisp files/usr/etc/apt 2>/dev/null" >> "${DIAG}" 2>/dev/null || true
  adb shell "run-as ${pkg} cat files/usr/etc/apt/sources.list 2>/dev/null" >> "${DIAG}" 2>/dev/null || true
}

# 1. Standard first-boot smoke suite (termuxDebug)
SMOKE_RC=0
sh scripts/emulator-smoke.sh || SMOKE_RC=$?
log_diag "=== STEP 1 termuxDebug 1st-boot smoke RC=${SMOKE_RC} ==="
adb shell "run-as tech.khalidrafi.emacshell.termux ls -la files files/.emacs.d files/.emacs.d/site-lisp files/.emacs.d/site-lisp/emacshell 2>/dev/null" >> "${DIAG}" 2>/dev/null || true

# 2. termuxDebug 2nd boot (warm start with .pdmp + EMACSLOADPATH + site-start.el + ElwidgetWatcher)
PKG_T="tech.khalidrafi.emacshell.termux"
adb shell am force-stop "${PKG_T}" || true
sleep 2
adb logcat -c || true
adb shell am start -n "${PKG_T}/org.gnu.emacs.EmacsActivity" || true
sleep 40
check_pkg_alive "${PKG_T}" "STEP 2 termuxDebug 2nd-boot (warm start)" "debug-2nd-boot.log"

# Verify Emacs batch with EMACSLOADPATH simulating the app environment
adb shell "run-as ${PKG_T} sh -c 'HOME=/data/user/0/${PKG_T}/files EMACSLOADPATH=/data/user/0/${PKG_T}/files/.emacs.d/site-lisp/emacshell: ls -l /data/user/0/${PKG_T}/files/emacs-*.pdmp /data/user/0/${PKG_T}/files/.emacs.d/site-lisp/emacshell/'" >> "${DIAG}" 2>/dev/null || true

# 3. distroDebug 1st boot + Alpine rootfs staging + 2nd boot
adb uninstall "${PKG_T}" >/dev/null 2>&1 || true
adb uninstall "${PKG_T}.test" >/dev/null 2>&1 || true
DISTRO_DBG="$(find app/build/outputs/apk/distro/debug -name '*.apk' ! -name '*androidTest*' | head -n1 || true)"
PKG_D="tech.khalidrafi.emacshell.distro"
if [ -n "${DISTRO_DBG}" ]; then
  adb install -r "${DISTRO_DBG}"
  for perm in android.permission.WRITE_EXTERNAL_STORAGE android.permission.READ_EXTERNAL_STORAGE android.permission.POST_NOTIFICATIONS; do
    adb shell pm grant "${PKG_D}" "${perm}" 2>/dev/null || true
  done
  adb logcat -c || true
  adb shell am start -n "${PKG_D}/org.gnu.emacs.EmacsActivity" || true
  i=0
  while [ "$i" -lt 45 ]; do
    if adb shell "run-as ${PKG_D} test -e files/usr/var/lib/proot-distro/installed-rootfs/alpine/bin/sh" 2>/dev/null; then
      break
    fi
    sleep 3
    i=$((i + 1))
  done
  sleep 10
  check_pkg_alive "${PKG_D}" "STEP 3a distroDebug 1st-boot" "distro-debug-1st.log"
  adb shell "run-as ${PKG_D} ls -la files/usr/var/lib/proot-distro/installed-rootfs/alpine 2>/dev/null" >> "${DIAG}" 2>/dev/null || true

  adb shell am force-stop "${PKG_D}" || true
  sleep 2
  adb logcat -c || true
  adb shell am start -n "${PKG_D}/org.gnu.emacs.EmacsActivity" || true
  sleep 35
  check_pkg_alive "${PKG_D}" "STEP 3b distroDebug 2nd-boot" "distro-debug-2nd.log"
  adb uninstall "${PKG_D}" >/dev/null 2>&1 || true
else
  log_diag "=== STEP 3 SKIPPED: no distroDebug APK found ==="
fi

# 4. Published release APKs (v0.1.4 -> v0.1.5 upgrade, v0.1.5 fresh termux, v0.1.5 fresh distro)
REL_T014="release-apks/emacshell-termux-0.1.4-api29.apk"
REL_T015="release-apks/emacshell-termux-0.1.5-api29.apk"
REL_D015="release-apks/emacshell-distro-0.1.5-api29.apk"

if [ -f "${REL_T014}" ] && [ -f "${REL_T015}" ]; then
  adb install -r "${REL_T014}"
  for perm in android.permission.WRITE_EXTERNAL_STORAGE android.permission.READ_EXTERNAL_STORAGE android.permission.POST_NOTIFICATIONS; do
    adb shell pm grant "${PKG_T}" "${perm}" 2>/dev/null || true
  done
  adb logcat -c || true
  adb shell am start -n "${PKG_T}/org.gnu.emacs.EmacsActivity" || true
  sleep 60
  check_pkg_alive "${PKG_T}" "STEP 4a release v0.1.4 termux-api29 1st-boot" "release-v014.log"

  adb install -r "${REL_T015}"
  adb logcat -c || true
  adb shell am start -n "${PKG_T}/org.gnu.emacs.EmacsActivity" || true
  sleep 45
  check_pkg_alive "${PKG_T}" "STEP 4b release v0.1.4->v0.1.5 termux-api29 upgrade" "release-v015-upgrade.log"

  adb uninstall "${PKG_T}" >/dev/null 2>&1 || true
  adb install "${REL_T015}"
  for perm in android.permission.WRITE_EXTERNAL_STORAGE android.permission.READ_EXTERNAL_STORAGE android.permission.POST_NOTIFICATIONS; do
    adb shell pm grant "${PKG_T}" "${perm}" 2>/dev/null || true
  done
  adb logcat -c || true
  adb shell am start -n "${PKG_T}/org.gnu.emacs.EmacsActivity" || true
  sleep 60
  check_pkg_alive "${PKG_T}" "STEP 4c release v0.1.5 termux-api29 fresh 1st-boot" "release-v015-fresh1.log"

  adb shell am force-stop "${PKG_T}" || true
  sleep 2
  adb logcat -c || true
  adb shell am start -n "${PKG_T}/org.gnu.emacs.EmacsActivity" || true
  sleep 45
  check_pkg_alive "${PKG_T}" "STEP 4d release v0.1.5 termux-api29 fresh 2nd-boot" "release-v015-fresh2.log"
  adb uninstall "${PKG_T}" >/dev/null 2>&1 || true
fi

if [ -f "${REL_D015}" ]; then
  adb install "${REL_D015}"
  for perm in android.permission.WRITE_EXTERNAL_STORAGE android.permission.READ_EXTERNAL_STORAGE android.permission.POST_NOTIFICATIONS; do
    adb shell pm grant "${PKG_D}" "${perm}" 2>/dev/null || true
  done
  adb logcat -c || true
  adb shell am start -n "${PKG_D}/org.gnu.emacs.EmacsActivity" || true
  sleep 60
  check_pkg_alive "${PKG_D}" "STEP 4e release v0.1.5 distro-api29 fresh 1st-boot" "release-v015-distro1.log"

  adb shell am force-stop "${PKG_D}" || true
  sleep 2
  adb logcat -c || true
  adb shell am start -n "${PKG_D}/org.gnu.emacs.EmacsActivity" || true
  sleep 45
  check_pkg_alive "${PKG_D}" "STEP 4f release v0.1.5 distro-api29 fresh 2nd-boot" "release-v015-distro2.log"
  adb uninstall "${PKG_D}" >/dev/null 2>&1 || true
fi

cat "${DIAG}"
exit "${SMOKE_RC}"
