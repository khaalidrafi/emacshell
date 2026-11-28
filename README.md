# emacshell

**One APK. GNU Emacs plus a real Unix environment on Android.**

emacshell repackages the official [GNU Emacs Android
build](https://www.gnu.org/software/emacs/) together with the
[Termux](https://termux.dev) application layer and bootstrap, so that
installing *one* app gives you Emacs *and* a working shell, package
manager and userland — no rooting, no termux/ directory dance, no
second app.

- Two variants, both installable **side by side with upstream Emacs
  and upstream Termux** (and with each other):
  - **Emacshell (Termux)** — `tech.khalidrafi.emacshell.termux`:
    Emacs + a custom-prefix Termux bootstrap (`apt`, `bash`, ...).
  - **Emacshell (Distro)** — `tech.khalidrafi.emacshell.distro`:
    the same, plus `proot`/`proot-distro` and a bundled Alpine
    minirootfs (`apk`, full musl userland) staged on first boot.
- Emacs itself is **not rebuilt**: the native libraries and the
  complete lisp/etc asset tree are extracted from the official
  GNU-built APK (Emacs 31.1), verified by detached GPG signature and
  sha256 pin, and re-packaged as-is.
- The Termux application/UI layer is vendored from termux-app
  `v0.118.3` and adapted (see `patches/termux/`): no `sharedUserId`,
  no second launcher — Emacs is the app; the terminal is one keystroke
  away (`M-x termux`).

## Why a single APK?

The current state of "Emacs on Android" is a multi-app ritual:
install GNU Emacs from F-Droid, install Termux, start Termux, run
`pkg install emacs` — which builds a *different*, terminal-only Emacs
inside the Termux prefix — or follow the GNU Emacs Android README's
instructions for copying Termux's toolchain into the Emacs app's home
directory so that the GUI Emacs can spawn subprocesses. The result is
two Emacsen, fragile manual PATH surgery, and a support burden
documented from the user's side in
[Install Emacs on Android](https://blog.khalidrafi.tech/en/install-emacs-on-android).

emacshell does that surgery once, in the build system:

1. the Termux bootstrap is *compiled for the emacshell
   applicationId*, so the GUI Emacs and the shell share one prefix
   (`/data/data/<applicationId>/files/usr`) with zero copying;
2. `early-init.el` ships inside the APK and prepends that prefix to
   `PATH`/`exec-path`, so `M-x shell`, `compile`, `grep`, TRAMP —
   everything — simply works;
3. the Termux terminal stays available as `M-x termux` (inside Emacs)
   or `M-x termux-activity` (separate Android window) for the things
   that genuinely need a pty.

## Side-by-side installability

This is project law, enforced by `scripts/check.sh` and CI:

- emacshell uses its own applicationIds
  (`tech.khalidrafi.emacshell.termux` / `tech.khalidrafi.emacshell.distro`),
  which differ from `org.gnu.emacs` and `com.termux` and from each
  other;
- **no `android:sharedUserId` anywhere** — that attribute is what
  makes apps with different signatures collide, and it is the root of
  the classic "Termux cannot be updated" trap;
- every provider authority, permission and intent action is derived
  from the per-flavor applicationId via manifest placeholders;
- the bootstrap binaries are compiled for *this* app's data directory,
  so nothing ever reaches into another app's files.

Consequence: installing or uninstalling emacshell never requires —
and never performs — anything to upstream GNU Emacs or Termux. All
three (plus both emacshell flavors) can be installed at once.

## Installing

Grab the right APK from the [releases page](../../releases)
(v0.1.0 and later ship **signed** APKs; the artifacts on the [build
workflow](../../actions/workflows/build.yml) are signed too) and
install it with `adb install` or your file manager.

**Release key.** All v0.1.0+ artifacts are signed with the emacshell
release key:

```
SHA-256: 50:A2:AA:2F:BF:52:80:DC:67:74:F6:53:77:C6:DA:C3:99:2D:CA:72:1F:80:43:0B:34:9E:57:45:B3:BB:C7:AC
```

(Verify with `apksigner verify --print-certs app.apk`.)

**Which APK?** Two axes matter:

| Your Android | APK | Why |
|---|---|---|
| 10 or newer | `...-android10+-arm64-v8a.apk` | Built against GNU Emacs's API-29 build (the default for Android 10+) |
| 9 or older | `...-android7--arm64-v8a.apk` | Built against GNU Emacs's API-21 build (emacshell lifts the floor to Android 7 for Termux v0.118.3) |
| Low RAM (1-3 GB, e.g. Redmi 8A) | the **termux** flavor | proot's syscall translation plus a second userland costs memory you do not have; `pkg install` anything you need into the prefix instead |
| You need a full distro | the **distro** flavor | Bundled Alpine (`apk`) offline — or `M-x emacshell-distro-install` for debian/ubuntu/arch/fedora/opensuse/kali; `emacshell-distro-name` is the default |

Installing an `android7-` build over an `android10+` build of the same
applicationId (or vice versa) is a versionCode switch between variants
— it works as an upgrade in the 9-to-10 direction; in the other
direction uninstall first. On first launch:

1. Emacs starts immediately;
2. a progress dialog unpacks the bootstrap into the app's private
   storage (no storage permission needed);
3. `pkg`/`apt` are ready the moment the unpack finishes — the
   emacshell-packages repository is written into
   `$PREFIX/etc/apt/sources.list` at install time (v0.1.5+; no manual
   fix-repo step);
4. **Emacshell (Distro) only**: the bundled Alpine rootfs is staged
   for proot-distro in the background; `M-x emacshell-distro-login`
   becomes available when it finishes.

**MIUI / aggressive battery managers** (Redmi/Xiaomi phones): lock
emacshell in Recents and/or disable battery optimization for it, or
MIUI will kill the Emacs process (and any running terminal session)
in the background — the same advice Termux and GNU Emacs give.

Release APKs are signed with the project key; CI artifacts without
configured signing secrets are unsigned and need
`adb install --bypass-low-target-sdk-block` on Android 14+ (the app
targets SDK 28, like upstream Termux and GNU Emacs do, to keep the
background-shell semantics they rely on — see REVIEW.org).

## The terminal — `M-x termux`

`M-x termux` opens a full Termux shell **inside Emacs** (a `term`
buffer): the bootstrap's bash runs as a login shell with the exact
session environment a TermuxActivity terminal gives it (`PREFIX`,
`PATH=$PREFIX/bin`, `TMPDIR`, `TERMUX__*` — see
`termux-session-environment`), so `pkg`, `apt` and every other prefix
tool work exactly as in a standalone Termux. `M-x termux-activity`
(alias `emacshell-open-terminal`) opens the vendored TermuxActivity
in a separate Android window instead — same app, same UID, same
files — for the things that want a real Android-side pty (ssh agent,
adb, android tools).

**One home.** Termux sessions and the Emacs process share the same
`HOME` (the app's `files` directory): a file written in the term
buffer is instantly visible in Emacs's `~` and vice versa, and
`~/.termux/termux.properties` / `~/.config/termux` live where both
sides see them. (Installs that predate the unified home keep their
old `files/home` directory; move its contents into `~` once by
hand.)

**Storage.** `M-x termux-setup-storage` is the Emacs-side twin of
the `termux-setup-storage` shell command; both create the same
`~/storage/{shared,downloads,dcim,pictures,music,movies}` symlinks
in the shared home. If storage access has not been granted yet, the
command opens the app's Android settings page — grant "Storage" /
"All files access" and run it again. The shell command works from
anywhere now, including inside Emacs: its broadcast is answered by a
process-lifetime receiver in `EmacshellApplication`, not only by a
visible TermuxActivity (the upstream design, which silently no-oped
whenever the terminal activity was not on screen).

Both commands ship as **app code** (`site-lisp/emacshell/`, with a
`site-start.el` that loads it for every Emacs the app starts), so
they appear on installs whose first-boot `init.el` predates them —
unlike `init.el` itself, which is user-owned after first boot and is
never rewritten.

User-visible branding is "Emacshell" throughout — launcher, Recents,
notifications, documents provider, preferences screens.

## pkg / apt — the custom-prefix repository

Every Termux package hardcodes the prefix
`/data/data/com.termux/files/usr` at build time. emacshell installs
under its own applicationId, so the *upstream* Termux repositories
cannot be used: dpkg dies with
`error creating directory './data/data/com.termux': Permission denied`.
The bootstrap in the APK is therefore built from termux-packages with
the emacshell prefix (see `scripts/build-bootstrap.sh`), and the
**[packages workflow](../../actions/workflows/packages.yml)**
publishes the same package set as an apt repository on GitHub
Releases:

```
deb [trusted=yes] https://github.com/khaalidrafi/emacshell/releases/download/emacshell-packages-v1 ./
```

(the distro flavor uses `emacshell-packages-distro-v1`; the
`apt-<flavor>-v1` tags were retired 2026-11-25, and installs that
still name them are migrated automatically). The repo release also
carries the current APKs — one release is everything a flavor needs.

**Ready on install** (v0.1.7, Owner order 2026-11-26: the apt
repository and dpkg status must be healthy automatically, with no
manual repair step and no Emacs startup hook). Both layers are baked
into the build and the Android app: the bootstrap zip itself is built
without upstream's unshipped-dependency `dpkg-perl` and
`dpkg-scanpackages` subpackages (patch 4 in `scripts/build-bootstrap.sh`)
and pointing at `emacshell-packages` (patch 7), and on launch
`TermuxInstaller` (`ensureExistingPrefixHealthyAsync`) automatically
updates `sources.list` and purges any leftover `dpkg-scanpackages` /
`dpkg-perl` from existing installs in the background (`M-x termux-fix-repo`
and `M-x termux-repair` remain available for manual one-shot repair).

Scope: the repository serves the bootstrap package set (the ~100
essentials). Anything beyond it can be added by re-running the
workflow with its `extra_packages` input; the roadmap is a full
mirror. `pkg install` of an unserved package will say so, plainly.

## eservo — the embedded browser-automation package

emacshell vendors [eservo](https://github.com/khaalidrafi/eservo)
(`M-x eservo-goto`, `eservo-snapshot`, `eservo-click`, `eservo-script-run`,
`eservo-agent-brief`, ...): Emacs-driven web automation with zero AI in the
loop unless you hand the command brief to an agent. It ships in the APK as
plain Elisp (`app/src/emacshell/assets/emacshell/eservo/`, pinned by
`pins/eservo.txt` + `pins/eservo.sha256`), is re-installed by the app on every
boot under `~/.emacs.d/site-lisp/eservo/`, and is put on the `load-path` by
the app itself (`EMACSLOADPATH`) — first-boot `init.el` templates additionally
load its autoloads, so startup cost is zero and `M-x eservo-*` works on first
use.

Backends from the app: `embedded` — the servo engine loaded INTO the
Emacs process as `libeservo.so` — is the end state for this app (no
separate browser app, no devtools port); its packaging plan
(cargo-ndk arm64-v8a into `jniLibs`, Phase 2 of the
[eservo design doc](https://github.com/khaalidrafi/eservo/blob/ai/main/docs/EMBEDDED-SERVO.org))
is tracked in REVIEW.org until the eservo servo-pin lane goes green on
desktop first. Until the module ships, eservo's default `auto` backend
picks the first backend that can actually run where you are — `cdp`
(a Chromium-based browser's DevTools port, on-device via the terminal's
loopback or a desktop browser over the LAN) or `adb` (a paired phone's
browser via `pkg install android-tools`) — and when nothing works the
error lists *why* each backend was rejected instead of blaming a missing
chromium binary on a machine that never had one. Commands that need a
browser also start one automatically now (`eservo-auto-start`, default
t): `M-x eservo-goto` just works; `M-x eservo-start` is only needed to
pin a specific backend.

Existing installs whose first-boot `init.el` predates eservo: add

```elisp
(load (expand-file-name "site-lisp/eservo/eservo-autoloads.el"
                        user-emacs-directory)
      nil t)
```

to your `init.el` (or uninstall + reinstall for a fresh first boot).

## Widgets — home-screen widgets in Elisp

emacshell ships [elwidget](https://github.com/khaalidrafi/elwidget), a
widget maker: you define Android home-screen widgets in Elisp, the app
renders them as real AppWidgets, and taps flow back into Emacs.

Long-press the home screen, pick **Emacs Widget 4x1 / 4x2 / 4x3**, and
choose one of the specs Emacs has written under
`~/.emacs.d/elwidget/specs/` (the built-in Org widgets are
`org-agenda`, `org-tasks`, `org-habits`, `org-clock`, `org-table`;
define your own with `M-x elwidget-define` — see the
[elwidget README](https://github.com/khaalidrafi/elwidget)).

The basic Org operations work right from the home screen:

- **`org-clock`** — clocking: while a clock runs the widget shows the
  task and duration plus a **Clock out** button; when idle it lists
  the recently clocked tasks as **clock-in** buttons (the top one
  resumes the last task). Both run Org's own `org-clock-in` /
  `org-clock-out`, so the LOGBOOK and clock tables stay authoritative.
- **`org-tasks`** — basic Org tasks: tap a check to cycle the entry's
  TODO state (`org-todo`).
- **`org-habits`** — habit updating: tap to check a habit; with the
  personal `loophabits` package habits become fully updatable from
  the home screen — checks tick instantly, and measurable habits
  (pages read, glasses of water, ...) get **-** and **+** steppers
  plus a tappable bar (+1) whose number moves the moment you tap
  (`loophabits-progress` spec; one tap is
  `loophabits-widget-step`). Without loophabits, Org's own
  `STYLE=habit` entries render and "done today" comes from the
  consistency graph's logbook reading.

On Android 12+ each node (check, button, progress bar) is its own tap
target; on Android 9–11 the widget renders identically but the whole
surface is a single open-Emacs tap (`RemoteViews.addView` does not
exist there). Check marks flip and stepper numbers bump instantly via
the shadow state file; Emacs is authoritative again on the next sync
(the first-boot `init.el` wires `focus-in-hook` + a 15 s poller).

## org-activity — native Usage Access (the usage bridge)

emacshell is the native Android home for
[org-activity](https://github.com/khaalidrafi/org-activity) (a
StayFree / ActivityWatch-parity tracker that journals into plain
Org). The app runs a token-gated loopback server
(`EmacshellUsageServer`, started at boot) that exposes
`UsageStatsManager` to the Emacs inside this app: per-app screen
time, opens, screen unlocks, notification counts and the
hour-of-day timeline — no export step, no third-party app, and no
Emacs rebuild (see DESIGN.org, "The usage bridge").

Setup: grant emacshell **Usage access** once (Android Settings →
Special app access → Usage access), then from Emacs:

```elisp
(require 'org-activity-android)
M-x org-activity-android-refresh     ;; bridge -> journal
M-x org-activity-android-report      ;; StayFree-style report
```

The port and the per-boot secret are auto-discovered via
`~/emacshell-usage-port` / `~/emacshell-usage-secret` (the app's
private files dir, which is HOME for the Emacs Android port). On
stock org.gnu.emacs or Termux Emacs builds the files are unreadable
by design, and org-activity falls back to its export-file path.

## Personal configuration

The APK ships **no personal configuration**: only what the APK itself
provides (the vendored `eservo` and `elwidget` packages, the Termux
prefix, the terminal escape hatch) is wired into the first-boot
`init.el` (Owner order 2026-11-18).

Habit tracking ([loophabits](https://github.com/khaalidrafi/loophabits),
feeding the `org-habits` widget above), mail (**notmuch over IMAP**,
not Gnus — synced with mbsync) and the rest of the phone setup live in
the personal Android config repo,
[emacs-android](https://github.com/khaalidrafi/emacs-android), which
installs them as ordinary `:vc` packages on top of this APK.

## Building from source

Requirements: JDK 17, Android SDK (platform 35, build-tools 35.0.0,
NDK 27.0.12077973), and network access on the first run.

```sh
scripts/check.sh                     # static consistency checks
scripts/extract-gnu-apk.sh 29 arm64-v8a   # fetch+verify+unpack the GNU APK
./gradlew assembleTermuxRelease      # or assembleDistroRelease
# Android 9 or older device? Use the -21 GNU build instead:
scripts/extract-gnu-apk.sh 21 arm64-v8a
./gradlew assembleTermuxRelease -PgnuApkApi=21
```

The api level passed to `extract-gnu-apk.sh` and `-PgnuApkApi` must
agree — the build cross-checks the extraction's provenance marker and
fails loudly on a mismatch (an APK labelled api21 must never contain
api29 libraries).

The **bootstrap pins start as `PLACEHOLDER`**: a fresh clone cannot
produce an installable APK until the custom-prefix bootstrap has been
built (`scripts/build-bootstrap.sh`, needs Docker, or the `bootstrap`
CI workflow) and its sha256 pinned — deliberately, by a human. This is
on purpose: the official Termux bootstrap is compiled for
`/data/data/com.termux` and would install a shell that cannot run.
See `pins/bootstrap-README.md` and BUILD.org for the full story.

## Emulator tests — running and using the app under emulation

`app/src/androidTest` holds an instrumented smoke suite
(`EmacshellSmokeTest`) that runs INSIDE the app's own process on an
emulator or device, so it exercises the exact UID, SELinux domain and
file layout users get. One test per user-visible capability:

| Test | Answers |
|---|---|
| `emacsServiceComesUpAndStaysUp` | Does the app launch, stay out of crash state, and does the native Emacs thread (`EmacsService`) come up? |
| `bootstrapInstallsBash` | Does the first-boot bootstrap extract `files/usr/bin/bash`? |
| `execBashFromAppData` | Can the app exec() a binary from its data directory? (The W^X question: emacshell targets API 28, so this must pass on every Android version.) |
| `coreutilsAreExecutableFromThePrefix` | Same, through `uname -m` (must print `aarch64`). |
| `initFilesInstalledWithExecPathWiring` | Did `early-init.el`/`init.el` land with the `exec-path` wiring? |
| `usageBridgeAnswersPing` | Does the token-gated loopback usage bridge accept `PING` with the per-boot secret? |

Run it on any booted emulator/device (arm64 — the APK is arm64-only):

```sh
scripts/extract-gnu-apk.sh 29 arm64-v8a
./gradlew assembleTermuxDebug assembleTermuxDebugAndroidTest
./gradlew connectedTermuxDebugAndroidTest
```

CI runs the whole lane automatically: the `emulator` workflow builds
the termux debug APK + androidTest APK, boots an emulator, installs
both APKs, runs `am instrument`, and always uploads `logcat` +
`instrumentation.log` as artifacts. When a user reports a crash on
their device, reproduce and diagnose here first — the artifacts hold
the crash trace.

One detail worth knowing: the emulator lane runs on a Linux runner
with an **API 35 google_apis x86_64 image using ABI translation** —
hosted macOS runners cannot run emulators (no hypervisor;
android-emulator-runner issue #458), and API 35 x86_64 images are the
documented way to run arm64-only APKs on GitHub Actions. The exec and
SELinux rules under test key on the app's targetSdk, not the image
version, so the lane is still representative; `uname -m` inside the
emulator reports `x86_64` (the translated kernel) rather than
`aarch64`, which the suite accepts.

## Repository layout

| Path | What |
|---|---|
| `app/` | application module: vendored Termux app sources + emacshell glue (`EmacshellApplication`, first-boot init files, icons) |
| `emacs/` | `:emacs` library: patched GNU Emacs Java layer, res, and (generated) native libs + assets |
| `termux-shared/`, `terminal-emulator/`, `terminal-view/` | vendored Termux modules |
| `scripts/` | build pipeline (sync, patch, extract, bootstrap, rootfs, checks) |
| `pins/` | sha256/commit commitments for everything downloaded (GNU APK, bootstrap, termux-app, eservo, Alpine rootfs) |
| `app/src/emacshell/assets/emacshell/eservo/` | vendored eservo Elisp package (browser automation), re-installed every boot |
| `patches/termux/` | the exact diffs applied to the vendored termux-app |
| `keys/emacs-release-key.asc` | public GNU Emacs release key (for APK signature verification) |

Documentation: [BUILD.org](BUILD.org) (pipeline and rationale),
[DESIGN.org](DESIGN.org) (architecture), [REVIEW.org](REVIEW.org)
(open review queue), [SECURITY.md](SECURITY.md) (supply chain).

## FAQ

**Why targetSdk 28?** Upstream Termux and GNU Emacs both target SDK 28
on purpose: newer targets restrict background processes and exec from
app data in ways that break the "app that is also a workstation"
model. emacshell inherits that trade-off and documents it in
REVIEW.org.

**Is this an Emacs fork?** No. Not one line of Emacs C is rebuilt; the
Java layer carries a small, asserted patch set
(`scripts/patch-emacs-java.py`) that replaces hard-coded package-name
lookups with runtime ones — exactly what running under a different
applicationId requires.

**Can I use my own init.el?** Yes. On first boot emacshell writes
`.emacs.d/early-init.el` and `.emacs.d/init.el` into the app's home
directory; from then on they are yours. Delete them and Emacs starts
bare.

**Where is the Termux app icon?** There is none, by design: Emacs is
the app. The terminal is one `M-x termux` away and stays running
behind it.

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). emacshell combines GNU
Emacs (GPLv3+) and Termux (GPLv3) derived work; the combined work is
distributable under GPLv3.
