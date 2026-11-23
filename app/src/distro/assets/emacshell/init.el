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

(defgroup emacshell nil
  "Emacshell: GNU Emacs plus a Unix environment on Android."
  :group 'tools)

;; The proot distro is a CHOICE (Owner order 2026-11-23: "make proot
;; distro variable so that users can choose which distro to use").
;; "alpine" is the one bundled in the APK (staged offline on first
;; boot); every other alias proot-distro knows installs over the
;; network with `emacshell-distro-install' and then logs in the same
;; way.  `emacshell-distro-list' shows exactly what your build of
;; proot-distro supports.
(defcustom emacshell-distro-name "alpine"
  "The proot-distro rootfs `emacshell-distro-login' enters.
\"alpine\" is bundled in the APK (offline).  Any other alias known
to proot-distro works after `emacshell-distro-install' fetches it."
  :type '(choice (const "alpine") (const "debian") (const "ubuntu")
                 (const "arch") (const "archlinux") (const "fedora")
                 (const "opensuse") (const "kali") (string :tag "alias"))
  :group 'emacshell)

(defun emacshell--proot-distro ()
  "Return the proot-distro binary path, or signal a helpful error."
  (let ((pd (expand-file-name "bin/proot-distro" (emacshell-prefix))))
    (unless (file-executable-p pd)
      (user-error "proot-distro is not installed in %s (bootstrap still running?)"
                  (emacshell-prefix)))
    pd))

(defun emacshell-distro-installed-p (distro)
  "Non-nil when DISTRO's rootfs is staged (its bin/sh exists)."
  (file-exists-p
   (expand-file-name
    "bin/sh"
    (expand-file-name
     (concat "var/lib/proot-distro/installed-rootfs/" distro)
     (emacshell-prefix)))))

(defun emacshell-distro-list ()
  "List the distros this proot-distro knows (installed + installable)."
  (interactive)
  (let ((pd (emacshell--proot-distro)))
    (with-current-buffer (get-buffer-create "*emacshell-distros*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "$ proot-distro list\n\n"))
      (start-process "emacshell-distro-list" (current-buffer)
                     pd "list")
      (special-mode)
      (pop-to-buffer (current-buffer)))))

(defun emacshell-distro-install (distro)
  "Install DISTRO's rootfs with proot-distro (needs the network).
Output streams into the *emacshell-distro-install* buffer; when it
finishes, `emacshell-distro-login' enters the new rootfs.  Run
`emacshell-distro-list' to see the exact aliases your build supports
(common ones: alpine, debian, ubuntu, arch, fedora, opensuse, kali)."
  (interactive
   (list (completing-read
          "Install distro (proot-distro alias): "
          '("debian" "ubuntu" "arch" "archlinux" "fedora"
            "opensuse" "kali" "alpine")
          nil nil "debian")))
  (let ((pd (emacshell--proot-distro))
        (buffer (get-buffer-create "*emacshell-distro-install*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "$ proot-distro install " distro "\n\n"))
      (goto-char (point-max))
      (start-process "emacshell-distro-install" buffer
                     pd "install" distro)
      (pop-to-buffer buffer))))

(defun emacshell-distro-login (&optional distro)
  "Open a term buffer logged into DISTRO via proot-distro.
DISTRO defaults to `emacshell-distro-name'; interactively, choose
among the installed rootfs.  The bundled \"alpine\" works offline
(its rootfs is unpacked from the APK on first boot); anything else
needs `emacshell-distro-install' first."
  (interactive
   (let* ((default (or emacshell-distro-name "alpine"))
            (installed
             (mapcar #'file-name-nondirectory
                     (ignore-errors
                       (directory-files
                        (expand-file-name
                         "var/lib/proot-distro/installed-rootfs"
                         (emacshell-prefix))
                        nil "^[^.]")))))
       (unless installed
         (user-error "No rootfs installed yet; M-x emacshell-distro-install"))
       (list (completing-read (format "Distro (default %s): " default)
                              installed nil t nil nil default))))
  (let* ((distro (or distro emacshell-distro-name "alpine"))
         (pd (emacshell--proot-distro)))
    (unless (emacshell-distro-installed-p distro)
      (user-error
       "%s rootfs is not installed; M-x emacshell-distro-install RET %s"
       distro distro))
    (let ((buffer (make-term (format "emacshell-distro-%s" distro) pd
                             nil "login" distro)))
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

