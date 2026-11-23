#!/bin/sh
# Emacshell emulator smoke suite (invoked by .github/workflows/emulator.yml).
#
# WHY this file exists (run 45244076439): the android-emulator-runner
# action's parseScript() splits the `script:` input on newlines and runs
# EVERY line as its own `sh -c <line>` process -- so variables set on
# one line (APP_APK, TEST_APK, RC) are EMPTY on the lines that use
# them, and the suite died with "no app APK produced" although the
# assemble step had just succeeded.  Keeping the whole suite in this
# committed script and the `script:` input to the single line
#     sh scripts/emulator-smoke.sh
# gives every step below one process and one shell state.
#
# POSIX sh (dash) only: no `set -o pipefail`, no PIPESTATUS, no bash
# arrays (run 45193434006 died on exactly `set -o pipefail`).
set -eux

APP_APK="$(find app/build/outputs/apk -name '*.apk' ! -name '*androidTest*' | head -n1)"
TEST_APK="$(find app/build/outputs/apk -name '*androidTest*.apk' | head -n1)"
[ -n "${APP_APK}" ] || { echo "::error::no app APK produced"; exit 1; }
[ -n "${TEST_APK}" ] || { echo "::error::no androidTest APK produced"; exit 1; }

adb install -r "${APP_APK}"
adb install -r "${TEST_APK}"

# am instrument -w streams until the suite finishes; capture the log
# for the artifact upload and let the exit code speak for the verdict.
adb shell am instrument -w \
  tech.khalidrafi.emacshell.termux.test/androidx.test.runner.AndroidJUnitRunner \
  > instrumentation.log 2>&1
RC=$?

# Always leave a logcat behind for crash diagnosis, even on success.
adb logcat -d > emacshell-logcat.txt || true

cat instrumentation.log
echo "instrument exit code: ${RC}"
exit "${RC}"
