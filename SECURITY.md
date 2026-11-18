# Security policy and supply chain

emacshell's entire value proposition is "run code from this APK";
that makes the APK's provenance the security boundary.  This document
describes what enters the build, from where, and how it is verified.

## Trust roots

| Input | Source | Verification |
|---|---|---|
| GNU Emacs native libraries + assets | official GNU APK `emacs-31.1-29-arm64-v8a.apk` | detached OpenPGP signature (GNU Emacs release key, committed at `keys/emacs-release-key.asc`, primary fingerprint `6B67 8974 F883 1317 51B2 B1A0 9EF0 C7D0 EDB0 AF5A` "Po Lu <luangruo@yahoo.com>"), verified in CI **before** the APK is unpacked; plus a sha256 pin (`pins/gnu-apk.sha256`) checked by `scripts/extract-gnu-apk.sh` |
| Emacs Java layer | `emacs-31.1.tar.xz` source tarball | patched by `scripts/patch-emacs-java.py`, an exact-match, assertion-checked series of replacements; the committed result is re-verified by `scripts/check.sh` |
| Termux app sources | `github.com/termux/termux-app` tag `v0.118.3` | commit sha pinned in `pins/termux-app.txt`; patches in `patches/termux/` are applied without fuzz and the vendored result is committed for review |
| termux-packages builder tree | `github.com/termux/termux-packages` release tag `bootstrap-2026.11.15-r1+apt.android-7` (Owner order 2026-11-18: release tags only, never raw master) | tag + commit sha pinned in `pins/termux-packages.txt`; `scripts/build-bootstrap.sh` verifies with `git ls-remote` that the tag resolves to the pinned commit before building, and `scripts/check.sh` enforces the tag's shape.  Two fail-loud post-clone patches cover known upstream drifts (REVIEW.org "Bootstrap upstream patches") |
| Termux bootstrap binaries | built by us in the termux-packages Docker builder | sha256 pinned in `pins/bootstrap-<flavor>.sha256`, filled in **by a human** after reviewing the CI artifact; the Gradle build refuses to embed anything else |
| Alpine minirootfs | `dl-cdn.alpinelinux.org` | sha256 pinned in `pins/alpine-rootfs-aarch64.sha256` (recorded from Alpine's own `.sha256` file), re-verified at fetch and at build |
| Android/JDK/AGP/Gradle | upstream distros | pinned versions in `gradle.properties`, root `build.gradle` and the Gradle wrapper properties |

Two rules follow from the table:

1. **Every downloaded artifact has a pin in this repository, and every
   pin change is a deliberate, reviewable commit.**  PLACEHOLDER
   bootstrap pins fail the build; a wrong-prefix bootstrap can never
   ship silently.
2. **The GPG verification of the GNU APK fails the CI build if the key
   cannot be imported.**  The committed key is preferred; a fallback
   fetch from `https://ftp.gnu.org/gnu/emacs/emacs-release-key.asc`
   exists, but if both fail the step aborts — an unverified Emacs
   binary must never enter an APK.

## What we deliberately do NOT trust

- The `ghcr.io/termux/package-builder` Docker image is a moving tag.
  The termux-packages *scripts* are pinned; the image is not yet
  digest-pinned (tracked in REVIEW.org).  Consequence: the bootstrap
  artifact is treated as build output to review, not as a given —
  which is exactly why its pin is filled in manually.
- Any network at *device* first boot: the bootstrap and (distro) the
  Alpine rootfs are embedded in the APK.  Nothing is fetched or
  executed from the network before the user runs `apt update`
  themselves.

## Keystore handling

- No keystore, password or certificate is ever committed.  CI signs
  with `EMACSHELL_KEYSTORE_B64` / `EMACSHELL_KEYSTORE_PASSWORD`
  repository secrets; when absent, artifacts are uploaded **unsigned
  with a warning** rather than self-signed with a fake key.
- The release key should be generated offline
  (`keytool -genkeypair -keystore emacshell-release.jks -keyalg RSA
  -keysize 4096 -validity 10000`), never stored in CI logs, and its
  certificate fingerprint published in the README at release time.
- `scripts/check.sh` fails if any `*.jks`/`*.keystore`/`*.p12`/`*.pem`
  file or `PRIVATE KEY` block appears in the tree.

## Runtime security posture

- The app runs as its own UID with its own data directory; no
  `sharedUserId` (that attribute is both a collision risk with
  upstream Termux and a known update trap).
- The embedded tar extractor (`TarExtractor`) treats every tar entry
  path as untrusted: canonical-path containment (zip-slip guard), no
  device/fifo creation, no setuid bits (mode masked to 0777).
- Upstream permission sets (Emacs's "let arbitrary lisp work" list,
  Termux's notification/storage list) are carried over intentionally;
  none of them is auto-granted.  `WRITE_SECURE_SETTINGS`, `DUMP`,
  `READ_LOGS` etc. are requested-but-not-granted, as in both upstream
  apps.

## Reporting a vulnerability

Open a private security advisory on this repository, or contact the
maintainer (Khalid Rafi) directly.  Please include the commit hash and
the pin files' contents at the time of the finding.
