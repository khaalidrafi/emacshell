;;; emacshell.el --- app-shipped commands for the Emacshell app -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is APP CODE, not user config: EmacshellApplication
;; re-installs the whole site-lisp/emacshell/ directory on every app
;; start and puts it on EMACSLOADPATH, and site-start.el (next to this
;; file) loads it for every Emacs the app starts.  That is what makes
;; these commands reach installs whose first-boot init.el predates
;; them -- init.el is user-owned and never rewritten, so new commands
;; can only ship through this package.
;;
;; Commands (all safe to call from any Emacs, degraded gracefully when
;; the bootstrap is not installed):
;;
;;   M-x termux          a full Termux shell INSIDE Emacs (term buffer)
;;   M-x termux-activity the vendored TermuxActivity in a separate
;;                       Android window (same app, same files)
;;   M-x termux-fix-repo point apt at the emacshell package repo
;;   M-x termux-repair   one-shot repair of a broken apt/dpkg state

;;; Code:

(require 'term)
(require 'cl-lib)

(defgroup emacshell nil
  "Commands shipped by the Emacshell app (termux integration, apt repair)."
  :prefix "emacshell-"
  :group 'applications)

;;; ------------------------------------------------------- paths & facts

(defun emacshell-home ()
  "Return the app home directory (the Android port's HOME)."
  (or (getenv "HOME") (expand-file-name "~/")))

(defun emacshell-prefix ()
  "Return this installation's Termux prefix ($PREFIX or HOME/usr)."
  (or (getenv "PREFIX")
      (expand-file-name "usr" (emacshell-home))))

(defun emacshell-package-name ()
  "Return the applicationId of this emacshell build.
Derived from HOME (/data/data/<applicationId>/files), which the
Emacs Android port sets itself -- the most reliable runtime source."
  (file-name-nondirectory
   (directory-file-name
    (file-name-directory
     (directory-file-name (emacshell-home))))))

(defun emacshell--flavor ()
  "Return the flavor tag used by the app's apt repo (termux or distro)."
  (if (string-suffix-p ".distro" (emacshell-package-name))
      "distro" "termux"))

;;; ------------------------------------------------- in-Emacs termux shell

;;;###autoload
(defun termux (&optional command)
  "Start an interactive Termux shell INSIDE Emacs (a `term' buffer).

The bootstrap's bash runs as a login shell with the Termux
environment (PREFIX, TMPDIR) set, so pkg/apt and every other prefix
tool work exactly as they do in the TermuxActivity.  This is the
answer to \"how do I get a terminal inside the Emacshell app\" --
no separate activity, no widget, just C-x b *termux*.

COMMAND (optional) is a shell command line to run instead of an
interactive shell."
  (interactive)
  (let* ((prefix (emacshell-prefix))
         (bash (expand-file-name "bin/bash" prefix))
         (prog (if (file-executable-p bash)
                   bash
                 (or shell-file-name "/system/bin/sh")))
         (process-environment
          (append (list (concat "PREFIX=" prefix)
                        (concat "TMPDIR=" (expand-file-name "tmp" prefix))
                        (concat "HOME=" (emacshell-home))
                        "TERM=xterm-256color")
                  process-environment)))
    (term (if (and command (not (string= command "")))
              (concat prog " -il -c " (shell-quote-argument command))
            ;; Login + interactive: the same shell a Termux session runs.
            (concat prog " -il")))
    ;; term names the buffer after the program; make it predictable.
    (ignore-errors
      (with-current-buffer (window-buffer (selected-window))
        (rename-buffer "*termux*" t)))))

;;;###autoload
(defalias 'emacshell-termux 'termux)

;;; --------------------------------------------- the TermuxActivity escape

;;;###autoload
(defun termux-activity ()
  "Open the bundled Termux terminal in a separate Android activity.
Emacs keeps running; the terminal is the vendored TermuxActivity,
which shares this app's UID and therefore the same files, sockets
and prefix.  Use it for anything needing a full Android-side pty
(ssh agent, adb, android tools).
`termux-am' from the bootstrap's termux-tools is preferred over
/system/bin/am because Android 12+ denies plain apps execution of
the system am wrapper."
  (interactive)
  (let* ((bin (expand-file-name "bin" (emacshell-prefix)))
         (termux-am (expand-file-name "termux-am" bin))
         (am (cond ((file-executable-p termux-am) termux-am)
                   ((file-executable-p "/system/bin/am") "/system/bin/am")
                   (t (user-error
                       "No `am' executable found; is the bootstrap installed?"))))
         (component (format "%s/com.termux.app.TermuxActivity"
                            (emacshell-package-name))))
    (start-process "termux-activity" nil am "start" "-n" component)
    (message "Started %s" component)))

;;;###autoload
(defalias 'emacshell-open-terminal 'termux-activity)

;;; --------------------------------------------------------- apt repo fix

(defconst emacshell-apt-repo-base
  "https://github.com/khaalidrafi/emacshell/releases/download"
  "Base URL of the app's package repositories (GitHub Releases).
Each flavor's repo lives under the emacshell-packages tags (see
`emacshell--apt-repo-tag'); the Packages index uses absolute asset
URLs, which is what makes a flat repo work off plain release
assets.")

(defun emacshell--apt-repo-tag ()
  "Release tag of this flavor's custom-prefix apt repository.
The repository is named emacshell-packages; the termux flavor owns
the bare tag, other flavors append theirs (the apt-<flavor>-v1
tags were retired 2026-11-25)."
  (if (string= (emacshell--flavor) "termux")
      "emacshell-packages-v1"
    (concat "emacshell-packages-" (emacshell--flavor) "-v1")))

(defun emacshell--apt-repo-url ()
  "Flat-repo URL of this flavor's custom-prefix apt repository."
  (concat emacshell-apt-repo-base "/" (emacshell--apt-repo-tag)))

(defun emacshell--apt-sources-file ()
  "Path of apt's sources.list inside this prefix."
  (expand-file-name "etc/apt/sources.list" (emacshell-prefix)))

(defun emacshell--stale-repo-p (line)
  "Non-nil when LINE names a repository that must be replaced.
That is either an UPSTREAM (com.termux-prefixed) repo or one of the
retired pre-rename emacshell tags (apt-<flavor>-v1, 2026-11-25)."
  (and (string-match-p "^deb\\b" line)
       (or (string-match-p "packages\\.termux\\.dev\\|packages-cf\\.termux\\.dev"
                           line)
           (string-match-p "/releases/download/apt-" line))))

(defun emacshell-apt-repo-line ()
  "The sources.list line for this flavor's emacshell repo."
  (format "deb [trusted=yes] %s ./" (emacshell--apt-repo-url)))

;;;###autoload
(defun termux-fix-repo (&optional quiet)
  "Point apt at the emacshell custom-prefix package repository.

WHY THIS EXISTS: every Termux package hardcodes the prefix
/data/data/com.termux/files/usr at build time.  Emacshell installs
under its own applicationId, so the OFFICIAL upstream repository is
unusable here -- `pkg upgrade' against it fails with
  error creating directory './data/data/com.termux': Permission denied
because dpkg is told to unpack into another app's data directory.
Emacshell's own repository serves the same packages rebuilt for
this prefix (GitHub Releases, absolute-URL flat repo; see
packages.yml in the emacshell repo).

Only touches sources.list when it currently points upstream or at
a retired repo tag; idempotent; the original line is preserved
(commented out) above the replacement.  Returns non-nil when the
file was changed."
  (interactive (list nil))
  (let* ((file (emacshell--apt-sources-file))
         (repo-line (emacshell-apt-repo-line)))
    (if (not (file-readable-p file))
        (unless quiet
          (message "termux-fix-repo: no %s (bootstrap installed?)"
                   file))
      (let* ((lines (with-temp-buffer
                      (insert-file-contents file)
                      (split-string (buffer-string) "\n" t)))
             (needs-fix
              ;; a stale repo line present, our line absent
              (and (cl-some #'emacshell--stale-repo-p lines)
                   (not (member repo-line lines))))
             (changed nil))
        (when (and (not (string= (emacshell-package-name) "com.termux"))
                   needs-fix)
          (with-temp-file file
            (let (inserted)
              (dolist (line lines)
                (if (emacshell--stale-repo-p line)
                    (progn
                      (insert "# emacshell: retired repo line (upstream is "
                              "com.termux-prefixed; the apt-* tags were renamed)\n")
                      (insert "# " line "\n")
                      (unless inserted
                        (insert repo-line "\n")
                        (setq inserted t))
                      (setq changed t))
                  (insert line "\n")))))
          (when changed
            (unless quiet
              (message "termux-fix-repo: %s now uses the emacshell repo"
                       file))))
        changed))))

;;; ------------------------------------------------------ one-shot repair

(defun emacshell--run-logged (buffer name program &rest args)
  "Run PROGRAM with ARGS, appending output to BUFFER; return exit code."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert "\n$ " name "\n")
    (let ((rc (apply #'call-process program nil t t args)))
      (goto-char (point-max))
      (insert (format "\n[%s exited %d]\n" name rc))
      rc)))

;;;###autoload
(defun termux-repair ()
  "Repair a broken apt/dpkg state and switch to the emacshell repo.

The classic breakage this fixes (reported on v0.1.4): `pkg upgrade'
pulled com.termux-prefixed packages from the upstream repo, dpkg
failed to unpack them (Permission denied under ./data/data/com.termux)
and left the package database half-configured, so every later apt
run dies on unmet dependencies.  Steps, all logged to *termux-repair*:

  1. `termux-fix-repo'      (point sources.list at the emacshell repo)
  2. purge the poisoned .debs from $PREFIX/var/cache/apt/archives
  3. apt-get update         (fresh, custom-prefix indexes)
  4. apt-get -f install     (fix-broken, downgrades allowed)

Each step's exit code is shown; a non-zero step stops the sequence
with an explanation in the buffer."
  (interactive)
  (let ((apt (expand-file-name "bin/apt" (emacshell-prefix)))
        (buf (get-buffer-create "*termux-repair*")))
    (unless (file-executable-p apt)
      (user-error "No apt in %s; is the bootstrap installed?"
                  (emacshell-prefix)))
    (with-current-buffer buf
      (erase-buffer)
      (insert (format ";; termux-repair on %s (prefix %s)\n"
                      (format-time-string "%Y-%m-%d %H:%M")
                      (emacshell-prefix))))
    (display-buffer buf)
    (let ((archives (expand-file-name "var/cache/apt/archives"
                                      (emacshell-prefix)))
          (rc 0))
      ;; 1. repo
      (with-current-buffer buf
        (goto-char (point-max))
        (insert "\n[1/4] fixing sources.list\n"))
      (if (termux-fix-repo t)
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "sources.list switched to the emacshell repo\n"))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "sources.list already fine (or no upstream line)\n")))
      ;; 2. purge poisoned cache
      (with-current-buffer buf
        (goto-char (point-max))
        (insert "\n[2/4] purging cached .debs\n"))
      (dolist (deb (and (file-directory-p archives)
                        (directory-files archives t "\\.deb\\'")))
        (ignore-errors (delete-file deb))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "removed " deb "\n")))
      ;; 3. update
      (with-current-buffer buf
        (goto-char (point-max))
        (insert "\n[3/4] apt-get update\n"))
      (setq rc (emacshell--run-logged buf "apt-get update" apt
                                      "update"))
      ;; 4. fix-broken (if it fails, dpkg-perl is the usual suspect:
      ;;    upstream gives it Depends: perl, clang, make -- a whole
      ;;    toolchain useless on a phone and NOT in the bootstrap set;
      ;;    drop the subpackage and retry)
      (if (eq rc 0)
          (progn
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "\n[4/4] apt-get -f install\n"))
            (setq rc (emacshell--run-logged
                      buf "apt-get -f install" apt
                      "-f" "install" "-y" "--allow-downgrades"))
            (unless (eq rc 0)
              (setq rc (emacshell--run-logged
                        buf "dpkg --remove dpkg-perl (toolchain deps not shipped)"
                        (expand-file-name "bin/dpkg" (emacshell-prefix))
                        "--remove" "dpkg-perl"))
              (setq rc (emacshell--run-logged
                        buf "apt-get -f install (retry)" apt
                        "-f" "install" "-y" "--allow-downgrades"))))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "\n[4/4] SKIPPED: update failed; see above\n")))
      (with-current-buffer buf
        (goto-char (point-max))
        (insert (format "\n== termux-repair %s ==\n"
                        (if (eq rc 0) "OK" "FAILED"))))
      (if (eq rc 0)
          (message "termux-repair: OK (details in *termux-repair*)")
        (message "termux-repair: FAILED (details in *termux-repair*)"))
      (eq 0 rc))))

(defun emacshell-maybe-fix-repo ()
  "Startup hook: fix sources.list when it still points upstream.
Called from site-start.el for every interactive Emacs the app
starts; batch Emacs is left alone.  Cheap (one file read) and fully
idempotent -- a user who deliberately re-adds an upstream line is
not fought with: only the exact upstream default lines are ever
rewritten, and they are preserved as comments."
  (unless (or noninteractive
              (string= (emacshell-package-name) "com.termux"))
    (ignore-errors
      (when (termux-fix-repo t)
        (message "emacshell: apt sources switched to the emacshell repo \
(run M-x termux-repair if pkg still misbehaves)")))))

(provide 'emacshell)
;;; emacshell.el ends here
