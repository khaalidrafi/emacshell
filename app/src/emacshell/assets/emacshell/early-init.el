;;; early-init.el --- Emacshell early initialization  -*- lexical-binding: t; -*-

;; Installed by EmacshellApplication on first boot; from then on this
;; file belongs to the user and is never overwritten by an upgrade.
;;
;; Purpose: make the bundled Termux prefix visible to every subprocess
;; feature of Emacs.  This must happen in early-init.el because PATH
;; handling influences things that run before user init, and because
;; package initialization and the GUI startup happen after this file.

;;; Code:

(let* ((home (or (getenv "HOME")
                 ;; The Android port of Emacs always sets HOME to the
                 ;; app's files directory; expand-file-name is a
                 ;; defensive fallback for exotic builds only.
                 (expand-file-name "~/")))
       (prefix (expand-file-name "usr" home))
       (bin (expand-file-name "bin" prefix)))
  ;; TERMUX applets and the shell read $PREFIX; Termux sessions set it
  ;; themselves, but the Emacs process is started by zygote, so export
  ;; it here unless something already did.
  (unless (getenv "PREFIX")
    (setenv "PREFIX" prefix))

  ;; Prepend <prefix>/bin to PATH and exec-path, idempotently, so that
  ;; M-x shell, compile, grep, ... find bash, coreutils and the rest of
  ;; the bootstrap before any Android system binary.  Subprocesses run
  ;; through the Android port's executable loader (see the "Subprocess
  ;; Creation" section of the Emacs Android manual), which is why
  ;; binaries inside the app data directory work at all.
  (let ((path (getenv "PATH")))
    (unless (and path (string-prefix-p (concat bin ":") path))
      (setenv "PATH"
              (concat bin
                      (if (and path (not (string= path "")))
                          (concat ":" path)
                        "")))))
  (unless (member bin exec-path)
    (setq exec-path (cons bin exec-path)))

  ;; Prefer the bootstrap's bash for M-x shell when it exists (it is
  ;; unpacked slightly later on the very first boot, in which case the
  ;; system shell is used until the next restart).  init.el re-runs
  ;; this once the prefix is definitely present.
  (let ((bash (concat bin "/bash")))
    (when (file-executable-p bash)
      (setq shell-file-name bash)
      (setenv "SHELL" bash))))

;;; early-init.el ends here
