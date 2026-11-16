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

;; elwidget + loophabits -- home-screen widgets and the habit tracker,
;; vendored by the app the same way eservo is (README "Widgets" and
;; "Habit tracker").  Lazy autoloads keep startup cost at zero.
(load (expand-file-name "site-lisp/elwidget/elwidget-autoloads.el"
                        user-emacs-directory)
      nil t)
(load (expand-file-name "site-lisp/loophabits/loophabits-autoloads.el"
                        user-emacs-directory)
      nil t)

;; Habit tracker + widgets, wired for a phone (2026-11-15): after 3
;; idle seconds register the built-in Org widgets, render every spec,
;; start the tap poller (15 s) and the reminder checker (60 s).  A
;; focus-in sync drains whatever taps happened while Android had us
;; frozen, then re-renders -- that is the whole trick to widgets on a
;; phone.
(run-with-idle-timer 3 nil
  (lambda ()
    (require 'elwidget-org)
    (elwidget-org-register-widgets)
    (elwidget-refresh)
    (elwidget-start)
    (loophabits-start-reminders)))
(add-hook 'focus-in-hook #'elwidget-sync)

;; Org files for the agenda/tasks widgets; defaults to ~/org/*.org
;; when that directory exists (create habits with M-x loophabits --
;; they live in ~/org/habits.org by default, already inside this).
(when (and (file-directory-p "~/org")
           (not (bound-and-true-p org-agenda-files)))
  (setq org-agenda-files
        (directory-files (expand-file-name "~/org") t "\\.org\\'" t)))

;;; Mail (Gnus over IMAP + SMTP) -------------------------------------
;; Built into Emacs; nothing external to install on Android.  Put
;; your account in ~/.authinfo (chmod 600), one line per server:
;;
;;   machine imap.gmail.com login you@gmail.com port 993 password APP-PASSWORD
;;   machine smtp.gmail.com login you@gmail.com port 465 password APP-PASSWORD
;;
;; (Gmail needs an app password; most providers work with the normal
;; one.)  Then edit the two servers below if needed and run M-x gnus.
(defvar emacshell-mail-imap-server "imap.gmail.com"
  "IMAP server Gnus reads mail from (nnimap, SSL/993).")
(defvar emacshell-mail-smtp-server "smtp.gmail.com"
  "SMTP server Gnus sends mail through (SSL/465).")
(defvar emacshell-mail-smtp-service 465
  "SMTP port; 465 for implicit TLS.")

(with-eval-after-load 'gnus
  (setq gnus-select-method
        `(nnimap ""
                 (nnimap-address ,emacshell-mail-imap-server)
                 (nnimap-server-port 993)
                 (nnimap-stream ssl))
        ;; Phone niceties: no exit interrogation, keep summaries
        ;; small, single-level threads.
        gnus-interactive-exit nil
        gnus-large-newsgroup 200
        gnus-thread-hide-subtree t)
  (setq message-send-mail-function 'smtpmail-send-it
        smtpmail-smtp-server emacshell-mail-smtp-server
        smtpmail-smtp-service emacshell-mail-smtp-service
        smtpmail-stream-type 'ssl
        smtpmail-smtp-user nil)          ; from ~/.authinfo
  ;; Reading offline: the nnimap agent caches fetched articles.
  (setq gnus-agent t))

;;; init.el ends here

