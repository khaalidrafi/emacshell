# AGENTS.md — khaalidrafi/emacshell

Local law for agents working in this repo. Global owner rules apply on
top (Guix-first machine, simple code, tests before implementation,
commit early/often, never procrastinate).

## Identity & commits (HARD LAW)

- Author every commit as your model identity: `MODEL <model@provider>`
  (e.g. `GLM 5.3 <glm-5.3@z.ai>`).
- End every commit message with BOTH trailers:

        Co-authored-by: <agent/harness> <agent@harness>
        Co-authored-by: Khalid Rafi <khaalidrafi@gmail.com>

  Canonical owner email is `khaalidrafi@gmail.com` — no variants.
- One model per commit. Never mix agents' work in one commit.
- Never commit directly to `main`. Branch `ai/main` is the working
  default; feature work on `ai/<topic>`.
- Descriptive subjects; put what comments can't hold in the body.

## This repo

- emacshell — one APK: GNU Emacs plus a real Unix environment on
  Android (README.md; architecture in DESIGN.org; pipeline in
  BUILD.org; open review queue in REVIEW.org).

## PKG-specific Android patches (Owner law, 2026-11-23)

"PKG specific Android patches should be stored in their corresponding
repos as well."

- Android support for a PACKAGE (elwidget, eservo, org-activity,
  loophabits, org-learn, lark-org, ...) — widgets, notifications,
  Termux installers, usage bridges, Android detection — is implemented
  and stored IN THAT PACKAGE'S REPO, not here.  The corresponding
  repos are the source of truth; this app only consumes.
- This repo VENDORS such packages clean: byte-identical `.el` copies
  at a pinned commit under `app/src/emacshell/assets/emacshell/<pkg>/`
  with `pins/<pkg>.txt` + `pins/<pkg>.sha256`; no local edits.  Audit
  2026-11-23: elwidget@9429f94 and eservo@ai/main both verified
  byte-identical to their repos.  Moving a pin = copy the files at the
  new commit, regenerate the package's autoloads, update the sha256
  list, re-run `scripts/check.sh` — never hand-edit a vendored file.
- `patches/` is ONLY for upstream code this project does not control
  (GNU Emacs, termux-app) — numbered, applied by scripts, re-verified
  on every bump.  If a family package ever DOES need a patch carried
  here, the same patch file must also land in that package's repo
  (same path, same content) so the repo remains self-contained.
- "Avoid patching, use EL as much as possible" (Owner): prefer an
  Elisp-side feature or a documented file contract over any Java/native
  patch.  External applications reach Emacs only through the serve
  wire (127.0.0.1:8642, OpenAI-compatible) or documented file
  contracts (`~/.emacs.d/elwidget/`, the usage-bridge port/secret
  files) — never ad-hoc IPC.

## Gates

- Before any push: `scripts/check.sh` (static consistency, pin
  verification, side-by-side installability law).
- Local assembly needs the bootstrap pins in place — see BUILD.org;
  CI is the honest lane when they are PLACEHOLDER.
- Record anything the owner should personally review in REVIEW.org;
  never delete a row without recording the resolution.

## GNU Emacs on Android — Grounding (Emacs 31.1 / Manuals / Sources)

Verified against `(emacs)Android`, `(elisp)Subprocess Creation` &
`Library Search`, `(org)Protocols` & `Org Mobile`, GNU's Android
`README`, and GNU Emacs 31 sources (`src/android.c`, `androidvfs.c`,
`lread.c`, `emacs.c`, `lisp/startup.el`, `term/android-win.el`,
`java/INSTALL`, `java/org/gnu/emacs/*.java`):

- **Process & Java/C lifecycle**: `libemacs.so` is loaded by
  `EmacsNative` inside the app JVM. `EmacsApplication` runs
  `EmacsNative.setupSystemThread()`, records `apkFileName`
  (`EMACS_CLASS_PATH`), and validates `emacs-<fingerprint>.pdmp` via
  `findDumpFile()` (deleted if older than the APK). `EmacsService`
  runs as a foreground service (`channel "emacs"`, `specialUse`) so
  Android does not kill background Emacs (even on Android 13+ without
  `POST_NOTIFICATIONS`, attempting the notification keeps it alive).
  `EmacsThread` calls `setEmacsParams()` (`android_site_load_path` =
  `files/site-lisp`, `LANG=en_US.utf8` on API >= 21,
  `android_create_lib_link()` symlinking `~/../lib -> nativeLibraryDir`,
  `android_vfs_init`) then `initEmacs()` (`HOME=filesDir`,
  `TMPDIR=cacheDir`, `SHELL=/system/bin/sh`, `android_emacs_init`).
  `EmacsActivity` (`singleInstance`) hosts the initial frame; closing
  the last frame exits the Emacs process.
- **Startup, `EMACSLOADPATH`, `site-start.el`, and `pdump`**:
  - On first boot without a valid `.pdmp`, `will_dump_p()` is true:
    `init_lread()` **ignores `EMACSLOADPATH` during dump** and runs
    `loadup.el` from `/assets/lisp/` + `files/site-lisp` to write the
    dump file; `normal-top-level` then finishes startup.
  - On normal/post-dump startup, `EMACSLOADPATH` overrides
    `load-path`; an empty element (leading/trailing `:` or `::`) is
    MANDATORY to splice in default `/assets/lisp` + `files/site-lisp`.
  - Exact `startup.el` order: `android-enumerate-fonts` -> `subdirs.el`
    / `leim-list.el` -> `android-locale-for-system-language` ->
    **`site-run-file` (`site-start.el`, runs BEFORE `early-init.el` and
    window-system init unless `-Q`/`--no-site-file`)** ->
    `early-init.el` -> `package-activate-all` -> `android-win` /
    frame creation -> `init.el` -> `android-before-splash-screen`.
  - Corrupted `.pdmp` or broken init crashes startup; upstream
    recovers via `EmacsPreferencesActivity` (`--quick`, `--debug-init`,
    erase `.pdmp`) and `EmacsDocumentsProvider`.
- **VFS & Subprocess rules (`androidvfs.c`, `android.c`)**:
  - `/assets` (APK `lisp/`, `etc/`, `info/`) is read-only via
    `AssetManager` (no `.` or `..`); `/content/storage/...` is SAF
    (`android-request-directory-access`); `/content/by-authority*`
    serves opened URIs. Subprocesses started with `default-directory`
    in `/assets` or `/content` fall back to `HOME`.
  - Ancillary executables ship in `jniLibs` as `lib*.so`
    (`libemacsclient.so`, `libmovemail.so`, `libloader.so`,
    `libexec1.so`, `libandroid-emacs.so` — Lisp must use
    `*-program-name` variables, not hardcode names).
  - Android 10+ blocks direct `execve()` from `app_data_file` when
    `targetSdk >= 29`. Emacshell keeps `targetSdk=28` so direct `exec`
    works cleanly (avoiding GNU's `libexec1.so` ptrace loader limits on
    `process-id` and `SIGSTOP`); on API 29+ with `targetSdk >= 29`,
    GNU uses `android-use-exec-loader`.
  - **NEVER export `LD_LIBRARY_PATH` globally** for Termux binaries
    (GNU Android README): Termux binaries carry `DT_RUNPATH`, and
    `LD_LIBRARY_PATH` collides system/Termux/Emacs shared libraries.
- **Windowing, Fonts, and Org**:
  - Android frames map 1:1 to Activities on Android 5+; background
    activities may be trimmed after ~4–6h; scrollbars and desktop frame
    params (`alpha`, `undecorated`, `title`, `wait-for-wm`, etc.) are
    unsupported.
  - `sfnt-android` loads TrueType `.ttf` only (no OpenType/color) from
    `/system/fonts`, `/product/fonts`, `~/fonts`.
  - `EmacsOpenActivity` handles `org-protocol://` and `mailto:` when
    Emacs server is running; Org provides `org-mobile-*`, Speed Keys,
    and TTY bindings for mobile/touch workflows.

