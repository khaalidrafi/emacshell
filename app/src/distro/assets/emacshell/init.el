;;; init.el --- Emacshell user init (distro flavor)  -*- lexical-binding: t; -*-

;; Installed by EmacshellApplication on first boot; from then on this
;; file belongs to the user and is never overwritten by an upgrade.
;; Everything below is plain Emacs Lisp: delete or edit freely.
;;
;; This flavor additionally bundles an Alpine minirootfs (staged into
;; $PREFIX/var/lib/proot-distro/installed-rootfs/alpine on first boot)
;; and a bootstrap that includes proot and proot-distro.

;;; Code:

(defun emacshell-home ()
  "Return the app home directory (the Android port's HOME)."
  (or (getenv "HOME") (expand-file-name "~/")))

(defun emacshell-prefix ()
  "Return the Termux prefix of this installation."
  (or (getenv "PREFIX")
      (expand-file-name "usr" (emacshell-home))))

(defun emacshell-package-name ()
  "Return the applicationId of this emacshell build.

Derived from HOME (/data/data/<applicationId>/files), which is set by
the Emacs Android port itself and therefore the most reliable runtime
source of the package name."
  (file-name-nondirectory
   (directory-file-name
    (file-name-directory
     (directory-file-name (emacshell-home))))))

;; Re-run the shell selection from early-init.el; by the time user init
;; runs, the bootstrap has normally been unpacked as well.
(let ((bash (expand-file-name "bin/bash" (emacshell-prefix))))
  (when (file-executable-p bash)
    (setq shell-file-name bash)
    (setenv "SHELL" bash)))

(defun emacshell-open-terminal ()
  "Open the bundled Termux terminal in a separate Android activity.

Emacs stays running; the terminal is the vendored TermuxActivity, which
shares this application's UID and therefore the same files, sockets and
prefix.  This is the \"open a real terminal next to Emacs\" escape hatch
for anything that needs a full pty (ssh, apk, proot administration).

Implementation note: Emacs 31.1 has no `android-start-activity' Lisp
primitive (the android-* APIs only cover clipboard, notifications and
directory access), so an Android `am start' is issued through
`start-process'.  `termux-am' from the bootstrap's termux-tools is
preferred over /system/bin/am because some Android 12+ builds deny
plain apps the ability to execute the system am wrapper."
  (interactive)
  (let* ((bin (expand-file-name "bin" (emacshell-prefix)))
         (termux-am (expand-file-name "termux-am" bin))
         (am (cond ((file-executable-p termux-am) termux-am)
                   ((file-executable-p "/system/bin/am") "/system/bin/am")
                   (t (user-error
                       "No `am' executable found; is the bootstrap installed?"))))
         (component (format "%s/com.termux.app.TermuxActivity"
                            (emacshell-package-name))))
    (start-process "emacshell-open-terminal" nil am
                   "start" "-n" component)
    (message "Started %s" component)))

(defun emacshell-distro-login ()
  "Open a term buffer logged into the bundled Alpine rootfs.

Runs `proot-distro login alpine' (from the distro bootstrap) inside an
Emacs `term' buffer, so the full Alpine userland is available with its
own apk package manager, in the same window system as Emacs.  The
rootfs is unpacked from the APK by EmacshellApplication after the
bootstrap installs; if this command complains, the bootstrap or the
staging is still in progress (or failed -- check the notification)."
  (interactive)
  (let* ((bin (expand-file-name "bin" (emacshell-prefix)))
         (proot-distro (expand-file-name "proot-distro" bin))
         (sh (expand-file-name
              "var/lib/proot-distro/installed-rootfs/alpine/bin/sh"
              (emacshell-prefix))))
    (unless (file-executable-p proot-distro)
      (user-error "proot-distro is not installed in %s" bin))
    (unless (file-exists-p sh)
      (user-error "Alpine rootfs is not staged yet (bootstrap still running?)"))
    (let ((buffer (make-term "emacshell-distro" proot-distro
                             nil "login" "alpine")))
      (unless (and buffer (bufferp buffer))
        (error "Could not create term buffer"))
      (switch-to-buffer buffer)
      (term-mode)
      (term-char-mode))))

;; eservo -- the embedded browser-automation package vendored by the
;; app (see README "eservo").  The directory itself is app-owned and
;; re-installed on every boot; these two lines are the only wiring the
;; user init needs.  Lazy autoloads keep startup cost at zero -- the
;; package loads on first use of any M-x eservo-* command.
(load (expand-file-name "site-lisp/eservo/eservo-autoloads.el"
                        user-emacs-directory)
      nil t)

;;; init.el ends here

