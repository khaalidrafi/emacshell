# HANDOFF — EmacShell (2026-11-26)

> Written by the departing Lead/DoE seat at the Owner's request, as the
> closing artifact of this repo work. Incoming owner of this repo:
> **Gemini 4 Hydrogen — Senior Android Developer for EmacShell**
> (Owner assignment, 2026-11-26). This file is repo-focused: what just
> shipped, what is on fire, how the machine is built, and what is queued.

## 0. READ FIRST — v0.1.5 crashes on the Owner's device (P0)

The Owner reports that v0.1.5 CRASHES on their device (2026-11-26). No
logcat or repro details were captured yet. This is the top priority;
everything else in this file waits behind it.

What the departing seat could verify from the sandbox (2026-11-26):

- **Build**: run 45769328775 (workflow_dispatch, bootstrap_run_id=
  44869748375) GREEN on 9f0b9ad; all four matrix jobs (termux/distro x
  api29/api21). Release v0.1.5 (id 459054445): 4 APKs (190.8-203.6 MB)
  + 4 sha256 sidecars; v2/v3 signing blocks present.
- **Signing**: same release key as v0.1.4 — SHA-256 certificate
  fingerprint 50:A2:AA:2F:BF:52:80:DC:67:74:F6:53:77:C6:DA:C3:99:2D:
  CA:72:1F:80:43:0B:34:9E:57:45:B3:BB:C7:AC, verified on both the
  v0.1.4 and v0.1.5 termux/api29 APKs. An in-place upgrade is not
  signature-blocked.
- **Bootstrap**: byte-identical pin to v0.1.4 (pins/bootstrap-termux.
  sha256 = 9229ef36df7a23451ca37c3f8d513fcec84d650ccc121a0bf713f2deb559ccc5,
  from bootstrap run 44869748375 of 2026-11-21, commit 22fc34b1).
  The libtermux-bootstrap.so in the v0.1.5 APK is the same size as
  v0.1.4's; the embedded zip integrity-checks clean (18499 entries).
  NOTE: it still carries an UPSTREAM sources.list — patch 7 has never
  been in a shipped bootstrap (see section 2).
- **APK-level delta** (both termux/api29 APKs unzipped and compared):
  exactly two NEW entries — `assets/emacshell/emacshell/emacshell.el`
  and `assets/emacshell/emacshell/site-start.el`; eservo assets
  updated; classes.dex +1.5 KB, classes2.dex +24 bytes; bootstrap .so
  unchanged; nothing removed.
- **Source delta** (v0.1.4 tag 550acd8 → 9f0b9ad): 11 commits, 15
  files. The significant ones for the crash hunt:
  1. the **site-lisp mechanism is NEW in v0.1.5** —
     `EmacshellApplication` now vendors the `emacshell` package
     (VENDORED_PACKAGES gained "emacshell"), copies it into
     `files/.emacs.d/site-lisp/emacshell/` on every boot and prepends
     all site-lisp dirs to `EMACSLOADPATH` (trailing empty element =
     default load-path kept). v0.1.4 shipped NO emacshell/ site-lisp
     assets at all, so **site-start.el loading at every Emacs start is
     a first-release behavior**.
  2. `TermuxInstaller.fixAptSourcesList` — first shipped in this range;
     9f0b9ad makes it UNCONDITIONAL (creates `etc/apt` + sources.list
     when missing, after bootstrap extraction, on the worker thread).
  3. `packages.yml`, `patches/termux/0004`, `TODOS.org` board,
     `scripts/build-bootstrap.sh` patches 5/6/7, eservo re-vendor.
- **Static review of the entire delta found no unconditional
  crasher**: the Java paths sit inside try/catch (Exception), the
  Elisp startup path (`site-start` → `emacshell-maybe-fix-repo` →
  `termux-fix-repo`) is inside `ignore-errors` and skipped in batch
  mode. So the crash is most likely native/runtime-level, or in a
  path interaction static review cannot see. Prime suspects, in
  order: (1) the brand-new site-start load on the Emacs startup path
  (first time this ever runs on a device); (2) the fresh-install
  path (uninstall 0.1.4, install 0.1.5): bootstrap extraction →
  unconditional sources.list write; (3) the upgrade path (0.1.4
  prefix kept): first site-start run rewrites the upstream
  sources.list at the first Emacs start.

First data to collect on device (nothing captured yet):

- which APK (flavor + api level) and Android version; fresh install
  or upgrade over v0.1.4; crash moment (launcher tap / first-boot
  unpack dialog / Emacs drawing / M-x termux);
- `adb logcat` around the crash — the app installs the Termux crash
  handler (`TermuxCrashUtils`), which writes a crash report; pull it;
- whether v0.1.4 still launches on the same device (isolates the
  delta).

The sandbox has no Android runtime; repro is device-side. TODOS.org
carries this as the new P0 row (DEADLINE 2026-11-27 23:59 -6h).

## 1. What v0.1.5 shipped (and why)

Purpose: the apt repository is configured at install time — no manual
repository-fix step on a fresh install (Owner order 2026-11-26). Three
layers were made to agree:

1. `TermuxInstaller.fixAptSourcesList` writes the `emacshell-packages`
   line into `$PREFIX/etc/apt/sources.list` unconditionally at
   bootstrap-install time (missing/empty sources.list is created;
   retired upstream/apt-* lines are commented and preserved).
2. `termux-fix-repo` / `site-start.el` keep it fixed on the Elisp side
   at every interactive Emacs start (`M-x termux-fix-repo` is the
   manual form; `M-x termux-repair` is the one-shot dpkg-state fix).
3. `scripts/build-bootstrap.sh` patch 7 rewrites `etc/apt/sources.list`
   inside the PRODUCED bootstrap zip — NOT yet in any shipped
   bootstrap (the v0.1.5 APKs embed the 2026-11-21 bootstrap, whose
   sources.list still names upstream; layer 1 covers it at install
   time). The next bootstrap rebuild needs a fresh pin by design (the
   zip hash changes).

Also in the release: `patches/termux/0004` regenerated (it had drifted
from the vendored TermuxInstaller since b7459ad); the packages.yml
epoch-colon guard (a086658 — apt-ftparchive renders `1:2.3` versions
with a colon while termux-packages names artifacts with a dot; the sed
normalizes so Filename URLs do not 404); emacshell-packages-v1 /
emacshell-packages-distro-v1 release tags refreshed with the 0.1.5
APKs (0.1.4 APK assets retired there).

## 2. How this repo is built (orientation map)

- **Two flavors x two API levels**: `termux` (pkg prefix at
  `files/usr`) and `distro` (proot; Alpine rootfs staged at first
  bootstrap by `DistroRootfsStager`); `api29` (Android 10+) and
  `api21` (5-9). `versionCode = apiLevel*100 + releaseN`
  (0.1.5 = +6), so updates stay monotonic within a variant.
- **One Application class**: `EmacshellApplication` replicates
  TermuxApplication + EmacsApplication onCreate bodies (both upstream
  classes are final / non-extensible) in a documented order: Termux
  crash handler → log level → Emacs native setup → first-boot init
  files (user-owned after first boot, never rewritten) → vendored
  site-lisp (re-installed every boot, EMACSLOADPATH) → elwidget
  watcher → usage bridge server → bootstrap on first activity resume.
- **The prefix problem** (the reason this repo exists as a fork):
  every Termux package hardcodes `/data/data/com.termux/files/usr`.
  This app installs under its own applicationId, so the upstream repo
  and upstream bootstrap are unusable; `scripts/build-bootstrap.sh`
  rebuilds the ~100-package bootstrap set with
  `TERMUX_APP_PACKAGE=tech.khalidrafi.emacshell.<flavor>`, and
  `packages.yml` publishes the custom-prefix debs as a flat apt repo
  on GitHub Releases (absolute-URL Filename entries — the
  release-asset trick).
- **Bootstrap pins**: `pins/bootstrap-{termux,distro}.sha256` (current
  termux 9229ef36…, distro d03d43a2…, both from run 44869748375).
  `build.yml` refuses to build on a PLACEHOLDER pin (wrong-prefix
  bootstrap can never ship silently). Rebuilding the bootstrap =
  `bootstrap` workflow dispatch, then `build` workflow dispatch with
  `bootstrap_run_id=<run>`, then deliberately update the pin.
- **termux-packages pin discipline**: release tags
  (`bootstrap-YYYY.MM.DD-rN+apt.android-N`) only, never master;
  `scripts/build-bootstrap.sh` verifies via `git ls-remote` before the
  ~2h docker build, then applies SEVEN deviations (see REVIEW.org
  "Bootstrap upstream patches" row for all seven and their fail-loud
  guards): bzip2→libbz2, env-overridable package name, zip lands in
  output/ (AppArmor MAC), skip dpkg-perl subpackage (unmet toolchain
  Depends poisoned every fresh install), download retry envelope,
  termux-am gradle/maven mirror hardening, and patch 7
  (sources.list in the produced zip).
- **Signing**: `EMACSHEL_KEYSTORE_B64`/`EMACSHEL_KEYSTORE_PASSWORD`
  repo secrets; release key fingerprint in section 0.
- **CI flakiness classes** (all hit historically, all hardened):
  Maven Central 429s (mirror-first + fallback), mirrors.kernel.org
  stalls (retry envelope), GH_REPO autodetection inside the
  termux-packages clone (pinned), gradle.properties read before cd,
  `gh run download` needs the run's artifacts.

## 3. Queued / open work (beyond the P0)

1. **P0 crash** (section 0) — owns the critical path.
2. **Owner on-device onboarding** (long-OPEN P0, board row "Owner
   on-device onboarding"): once the crash is fixed — sideload, wait
   for the first-boot unpack, `apt update && apt install less`.
   Nothing else; the repo line is written at install time.
3. **Bootstrap rebuild with patch 7** + fresh pins + the documented
   prefix re-verification (grep -r com.termux over extracted
   etc/apt/ must be empty) BEFORE filling the new pin.
4. **packages lane**: on any index rebuild, the epoch-colon guard
   (a086658) must keep running; `emacshell-packages-*` releases carry
   APKs + index now.
5. **Vendored upstream watches**: termux-app v0.118.3, Emacs 31.1
   (`patch-emacs-java.py --check` fails loudly on drift).
6. **libeservo embedded lane** (REVIEW.org row): blocked on eservo's
   servo 0.8.0 desktop lane; then cargo-ndk arm64 + jniLibs wiring.

## 4. Staffing

- **Senior Android Developer for EmacShell: Gemini 4 Hydrogen**
  (Owner assignment, 2026-11-26) — owns this repo from this handoff,
  starting with the P0 crash row.
- GLM 5.3 Flash holds the Director-of-Engineering seat (review,
  verification, repo hygiene) per the org-level handoff; Kilo/Cline
  free models serve as worker/verifier seats.

## 5. Pointers

- Org-level state: `khaalidrafi/agent-team-hq` (STATE.org, MEMBERS.org,
  TODOS.org, CONTROL.org). Every other repo in the org carries a
  HANDOFF.md with the same closing context.
- Boards follow the six-law time discipline (TODOS.org header):
  SCHEDULED/DEADLINE with warning leads, :EFFORT:, :LOGBOOK: clocking,
  append-only rows, re-read every workday 09:00 Asia/Dhaka.
- The v0.1.5 evidence trail (APK downloads, diff listings, cert
  checks) was produced in the departing sandbox on 2026-11-26 and is
  summarized in section 0; the release page and this repo's history
  hold the rest.
