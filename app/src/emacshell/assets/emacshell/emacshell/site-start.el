;;; site-start.el --- load the app-shipped emacshell commands -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Emacs loads `site-start' from any directory on `load-path' before
;; user init, unless started with -Q / --no-site-file.  Emacshell-
;; Application puts this directory on EMACSLOADPATH for EVERY Emacs
;; the app starts, which is how app-shipped commands reach installs
;; whose first-boot init.el predates them (init.el is user-owned and
;; is never rewritten).
;;
;; Keep this file minimal: it must stay cheap and side-effect-free in
;; batch mode (scripts run `emacs --batch' with the same environment).
;; The startup fixups only run interactively, are idempotent, and the
;; repo fixup only ever rewrites upstream-default sources.list lines
;; (preserving them as comments); the dpkg-perl purge only acts when
;; the status DB still lists the subpackage whose unshipped toolchain
;; deps break `pkg upgrade' on pre-v0.1.5 installs.

;;; Code:

(require 'emacshell nil t)

(unless noninteractive
  (emacshell-maybe-fix-repo)
  (emacshell-maybe-purge-dpkg-perl))

;;; site-start.el ends here
