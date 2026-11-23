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
