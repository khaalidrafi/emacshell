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

# Pre-grant the dangerous permissions the merged manifest requests, so
# no runtime permission dialog can appear over the activity under test
# (run 45255178990: a GrantPermissionsActivity raced the suite and the
# HWUI teardown).  pm grant fails for permissions the target SDK makes
# implicit -- that failure is expected and ignored.
PKG="tech.khalidrafi.emacshell.termux"
for perm in android.permission.WRITE_EXTERNAL_STORAGE \
            android.permission.READ_EXTERNAL_STORAGE \
            android.permission.POST_NOTIFICATIONS \
            android.permission.READ_CONTACTS \
            android.permission.CAMERA \
            android.permission.RECORD_AUDIO; do
  adb shell pm grant "${PKG}" "${perm}" 2>/dev/null || true
done

# am instrument -w streams until the suite finishes; capture the log
# for the artifact upload.  Its exit code ALONE is not a verdict:
# run 45253125133 proved `am instrument -w` can exit 0 after the app
# process crashed before any test ran ("Process crashed before
# executing the test(s)", INSTRUMENTATION_CODE: 0) -- a false green
# that hid the launch crash for a whole run.  So the log itself is
# checked: a crash marker fails the suite, and a successful ERT-style
# "OK (N tests)" line is REQUIRED for a pass.
adb shell am instrument -w \
  tech.khalidrafi.emacshell.termux.test/androidx.test.runner.AndroidJUnitRunner \
  > instrumentation.log 2>&1
RC=$?

# Always leave a logcat behind for crash diagnosis, even on success.
adb logcat -d > emacshell-logcat.txt || true

cat instrumentation.log
echo "instrument exit code: ${RC}"

if grep -q 'Process crashed' instrumentation.log; then
  echo "::error::the app process crashed before/during the tests (see logcat artifact)"
  exit 1
fi
if ! grep -q 'OK ([0-9]* test' instrumentation.log; then
  echo "::error::no successful test-run summary in instrumentation.log; treating as failure"
  exit 1
fi
exit "${RC}"
