;;; init.el --- Emacshell user init (Termux flavor)  -*- lexical-binding: t; -*-

;; Installed by EmacshellApplication on first boot; from then on this
;; file belongs to the user and is never overwritten by an upgrade.
;; Everything below is plain Emacs Lisp: delete or edit freely.

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
prefix.  This is the "open a real terminal next to Emacs" escape hatch
for anything that needs a full pty (ssh, apt/pkg, android tools).

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

;; eservo -- the embedded browser-automation package vendored by the
;; app (see README "eservo").  The directory itself is app-owned and
;; re-installed on every boot; these two lines are the only wiring the
;; user init needs.  Lazy autoloads keep startup cost at zero -- the
;; package loads on first use of any M-x eservo-* command.
(load (expand-file-name "site-lisp/eservo/eservo-autoloads.el"
                        user-emacs-directory)
      nil t)

;; elwidget -- home-screen widgets, vendored by the app the same way
;; eservo is (README "Widgets").  Lazy autoloads keep startup cost at
;; zero.
(load (expand-file-name "site-lisp/elwidget/elwidget-autoloads.el"
                        user-emacs-directory)
      nil t)

;; Widgets, wired for a phone: after 3 idle seconds register the
;; built-in Org widgets, render every spec and start the tap poller
;; (15 s).  A focus-in sync drains whatever taps happened while
;; Android had us frozen, then re-renders -- that is the whole trick
;; to widgets on a phone.  Habit tracking, mail and everything else
;; personal are NOT wired here: the APK ships no personal
;; configuration (Owner order 2026-11-18); the emacs-android config
;; repo carries it.
(run-with-idle-timer 3 nil
  (lambda ()
    (require 'elwidget-org)
    (elwidget-org-register-widgets)
    (elwidget-refresh)
    (elwidget-start)))
(add-hook 'focus-in-hook #'elwidget-sync)

;; Org files for the agenda/tasks widgets; defaults to ~/org/*.org
;; when that directory exists -- this is the widgets' data source,
;; not a personal preference.
(when (and (file-directory-p "~/org")
           (not (bound-and-true-p org-agenda-files)))
  (setq org-agenda-files
        (directory-files (expand-file-name "~/org") t "\\.org\\'" t)))

;;; init.el ends here

