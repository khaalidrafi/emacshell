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
;; Prefix maintenance (sources.list and removing upstream's unshipped-dep
;; dpkg-perl subpackage) is handled at bootstrap build time and by
;; TermuxInstaller in the Android app layer, never on Emacs startup.

;;; Code:

(require 'emacshell nil t)

;;; site-start.el ends here
