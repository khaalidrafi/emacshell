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
  away (`M-x emacshell-open-terminal`).

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
3. the Termux terminal stays available as `M-x emacshell-open-terminal`
   for the things that genuinely need a pty.

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

Grab the right APK from the [build workflow
artifacts](../../actions/workflows/build.yml) (or build it, below) and
install it with `adb install` or your file manager.

**Which APK?** Two axes matter:

| Your Android | APK | Why |
|---|---|---|
| 10 or newer | `...-api29.apk` | The number in GNU's Emacs APK names is the *minimum* API level the build supports; `-29` is the default |
| 9 or older | `...-api21.apk` | Same rule: `-21` runs down to Android 5; emacshell lifts the floor to 7 (Termux v0.118.3) |
| Low RAM (1-3 GB, e.g. Redmi 8A) | the **termux** flavor | proot's syscall translation plus a second userland costs memory you do not have; `pkg install` anything you need into the prefix instead |
| You need a full musl distro | the **distro** flavor | Bundled Alpine + `apk`, at a RAM cost |

Installing an api21 build over an api29 build of the same applicationId
(or vice versa) is a versionCode switch between variants — it works as
an upgrade in the 9-to-10 direction; in the other direction uninstall
first. On first launch:

1. Emacs starts immediately;
2. a progress dialog unpacks the bootstrap into the app's private
   storage (no storage permission needed);
3. **Emacshell (Distro) only**: the bundled Alpine rootfs is staged
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

## Repository layout

| Path | What |
|---|---|
| `app/` | application module: vendored Termux app sources + emacshell glue (`EmacshellApplication`, first-boot init files, icons) |
| `emacs/` | `:emacs` library: patched GNU Emacs Java layer, res, and (generated) native libs + assets |
| `termux-shared/`, `terminal-emulator/`, `terminal-view/` | vendored Termux modules |
| `scripts/` | build pipeline (sync, patch, extract, bootstrap, rootfs, checks) |
| `pins/` | sha256/commit commitments for everything downloaded |
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
the app. The terminal is one `M-x` away and stays running behind it.

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). emacshell combines GNU
Emacs (GPLv3+) and Termux (GPLv3) derived work; the combined work is
distributable under GPLv3.
