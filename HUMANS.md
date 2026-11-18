# HUMANS.md — emacshell

A guide for humans navigating and developing this codebase. Written
2026-11-18 per the org-wide rule that every agent-developed repo
carries one. Read this together with README.md (product pitch),
DESIGN.org (runtime architecture and reasoning) and BUILD.org (build
pipeline); this file is the map that ties them together.

## What this is

One Android APK containing GNU Emacs AND a real Unix environment:
the official GNU-built Emacs 31.1 APK's native libraries and asset
tree (GPG-verified, sha256-pinned, not rebuilt) re-packaged together
with the Termux application layer and bootstrap, under emacshell's own
applicationIds. Two variants, side-by-side installable with upstream
Emacs and Termux:

- **Emacshell (Termux)** — `tech.khalidrafi.emacshell.termux`:
  Emacs + custom-prefix Termux bootstrap (apt, bash, ...).
- **Emacshell (Distro)** — `tech.khalidrafi.emacshell.distro`:
  the same plus proot/proot-distro and a bundled Alpine minirootfs
  staged on first boot.

The point (README "Why a single APK?"): the current Emacs-on-Android
ritual needs two apps and manual PATH surgery. emacshell does the
surgery once, in the build system — the Termux bootstrap is compiled
for the emacshell applicationId so GUI Emacs and the shell share one
prefix, and a shipped `early-init.el` prepends that prefix to
`PATH`/`exec-path` so `M-x shell`, `compile`, `grep`, TRAMP just
work. The terminal stays one keystroke away (`M-x
emacshell-open-terminal`).

Scope law (Owner order 2026-11-18): the APK carries only what the APK
itself requires — eservo (browser automation) and elwidget (the
AppWidget host) are the vendored packages. Personal configuration
(loophabits, notmuch+IMAP mail) lives in `khaalidrafi/emacs-android`,
NOT here.

## Mental model — one application, two provenances

An APK has one Application class; GNU Emacs and Termux each ship
their own with required init. `EmacshellApplication` extends
`android.app.Application` directly and replicates both bodies
verbatim in an order that keeps every upstream invariant (crash
handler first, Emacs system thread + dump-file logic, user init
files, bootstrap trigger). Emacs is the launcher; TermuxActivity
loses its launcher filters but stays exported, reachable by explicit
intent.

Gradle modules:

| Module | What it is |
|---|---|
| `app/` | The product: merged manifest, `EmacshellApplication`, EmacsActivity wiring, the vendored package assets (`app/src/emacshell/assets/emacshell/`), the bootstrap machinery. |
| `emacs/` | The GNU Emacs Java/Android layer, vendored from the GNU APK tree and patched by `scripts/patch-emacs-java.py` (placeholders instead of hard-coded `org.gnu.emacs` names). |
| `terminal-emulator/`, `terminal-view/`, `termux-shared/` | Termux v0.118.3 vendored, adapted under `patches/termux/` (no sharedUserId, no second launcher). |

The native/lisp Emacs payload is NOT in git: `scripts/extract-gnu-apk.sh`
pulls the pinned GNU APK, verifies the detached GPG signature +
sha256 (`pins/gnu-apk.sha256`), and extracts into the build; a
provenance marker (`build/gnu-apk-extracted`) is cross-checked by
Gradle so a mislabeled APK cannot be assembled.

## Code map (beyond the modules)

| Path | Role |
|---|---|
| `scripts/check.sh` | The invariant gate (see below); CI runs it first. |
| `scripts/extract-gnu-apk.sh` | GPG-verify + extract the pinned GNU APK, write the provenance marker. |
| `scripts/build-bootstrap.sh` | Docker bootstrap build for the custom applicationId (manual `bootstrap.yml` dispatch, artifacts reviewed before pinning). |
| `scripts/prepare-distro-rootfs.sh` | Stages the Alpine minirootfs (Distro flavor). |
| `scripts/sync-termux.sh` | Re-vendor termux-app; the patch series under `patches/termux/` is reworked deliberately. |
| `scripts/patch-emacs-java.py` | Applies the placeholder rewrite to the vendored Emacs Java tree; `--check` fails loudly on upstream drift. |
| `patches/emacs/0001-android-usage-stats.patch` | The `android-usage-stats` primitive (BEGIN-MS END-MS) for org-activity: Java `EmacsService.queryUsageStats` + C-side DEFUN in `androidfns.c`, following the `queryBattery` service pattern. Manifest already declares PACKAGE_USAGE_STATS. |
| `patches/emacs/0002-android-start-activity.patch` | The `android-start-activity` primitive eservo's on-device lane calls. |
| `patches/termux/` | The termux-app adaptation series. |
| `pins/` | Every external input, pinned with sha256 + provenance notes: GNU APK (both API levels), bootstraps, Alpine rootfs, eservo, elwidget, termux-app, termux-packages. |
| `BUILD.org` / `DESIGN.org` / `REVIEW.org` | The three project documents: pipeline, runtime reasoning, and the open-risk queue (read REVIEW.org before changing anything listed there). |
| `.github/workflows/build.yml`, `bootstrap.yml` | check.sh -> GPG-verify + extract -> prepare pinned inputs -> assemble<Flavor>Release -> sign (secrets) or upload unsigned; bootstrap is manual dispatch. |

## The release build vs the patch series (read before touching)

The release build consumes GNU's PREBUILT native libraries, so the C
side of `patches/emacs/` cannot ship in it — that is why the patches
exist as a series, generated from and dry-run verified against the
pristine emacs-31.1 tarball, and why a from-source lane (BUILD.org
section 2b) is the tracked open decision. On stock builds,
org-activity's usage pull and eservo's `android-start-activity` lane
degrade gracefully; the import/export lanes work everywhere.

## Invariants (enforced by scripts/check.sh + CI)

- No `android:sharedUserId` in any committed manifest (that attribute
  is what makes differently-signed apps collide).
- The two applicationIds are exactly
  `tech.khalidrafi.emacshell.{termux,distro}`; authorities/actions
  derive from manifest placeholders, never hard-coded upstream names.
- Exactly one LAUNCHER (EmacsActivity) across the merged manifest set.
- The committed Emacs Java tree is in the patched state.
- Every pin file exists and is well-formed; no private key material
  anywhere in the tree.
- API-level flavors: GNU APK pins for API 21 and 29
  (`-PgnuApkApi`), versionCode = api*100 + base, minSdk follows the
  api; CI builds all four flavor x api combinations.

## Developing

```sh
./scripts/check.sh                        # the invariant gate, run first
./gradlew assembleTermuxRelease           # app/build/outputs/apk/termux/release/
./gradlew assembleDistroRelease
```

Signing happens in CI with `apksigner` and repository secrets (never
a committed keystore); unsigned artifacts upload with a warning when
secrets are absent (see SECURITY.md).

Branch law: work lands on `ai/main` (the default branch). API pin
changes, flavor changes and pin moves are deliberate commits that
touch `pins/` and re-run `check.sh`.
