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
;;   M-x termux-setup-storage
;;                       ~/storage symlinks to Android shared storage
;;                       (the Emacs twin of the shell command)
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

(defun emacshell-am ()
  "Return the best available Android `am' executable, or signal.
`termux-am' from the bootstrap's termux-tools is preferred over
/system/bin/am because some Android 12+ builds deny plain apps the
ability to execute the system am wrapper."
  (or (let ((termux-am (expand-file-name "termux-am"
                                         (expand-file-name "bin" (emacshell-prefix)))))
        (and (file-executable-p termux-am) termux-am))
      (and (file-executable-p "/system/bin/am") "/system/bin/am")
      (user-error "No `am' executable found; is the bootstrap installed?")))

;;; ------------------------------------------------- in-Emacs termux shell

(defun termux-session-environment ()
  "Return the Termux session environment as a list of \"NAME=VALUE\".
Mirrors TermuxShellUtils.buildEnvironment (the non-failsafe branch)
from the vendored termux-shared sources, so a `termux' buffer gets
exactly the environment a TermuxActivity terminal session gets --
including the HOME shared with the Emacs process itself, which is
what keeps Termux and Emacs in sync: every file either side writes
to ~ is instantly visible to the other."
  (let* ((home (emacshell-home))
         (prefix (emacshell-prefix))
         (bin (expand-file-name "bin" prefix)))
    (list
     (concat "HOME=" home)
     (concat "TERMUX__HOME=" home)
     (concat "PREFIX=" prefix)
     (concat "TERMUX__PREFIX=" prefix)
     (concat "PATH=" bin)
     (concat "TMPDIR=" (expand-file-name "tmp" prefix))
     (concat "SHELL=" (expand-file-name "bash" bin))
     "LANG=en_US.UTF-8"
     "COLORTERM=truecolor")))

;;;###autoload
(defun termux (&optional command)
  "Start an interactive Termux shell INSIDE Emacs (a `term' buffer).

The bootstrap's bash runs as a login shell with the full Termux
session environment (PREFIX, PATH, TMPDIR, TERMUX__* variables --
see `termux-session-environment'), so pkg/apt and every other
prefix tool work exactly as they do in the TermuxActivity, and the
HOME is the one shared with Emacs, so files written here are
instantly visible to Emacs (and vice versa).  This is the answer to
\"how do I get a terminal inside the Emacshell app\" -- no separate
activity, no widget, just C-x b *termux*.

COMMAND (optional) is a shell command line to run instead of an
interactive shell."
  (interactive)
  (let* ((prefix (emacshell-prefix))
         (bash (expand-file-name "bin/bash" prefix))
         (prog (if (file-executable-p bash)
                   bash
                 (or shell-file-name "/system/bin/sh")))
         (process-environment
          (append (termux-session-environment)
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
shares this app's UID and therefore the same files, sockets and
prefix.  Use it for anything needing a full Android-side pty
(ssh agent, adb, android tools), or when `M-x termux' is not
enough."
  (interactive)
  (let ((component (format "%s/com.termux.app.TermuxActivity"
                           (emacshell-package-name))))
    (start-process "termux-activity" nil (emacshell-am)
                   "start" "-n" component)
    (message "Started %s" component)))

;;;###autoload
(defalias 'emacshell-open-terminal 'termux-activity)

;;; ------------------------------------------------- storage setup (Emacs)

(defconst termux-storage-links
  '(("shared"    . "/storage/emulated/0")
    ("downloads" . "/storage/emulated/0/Download")
    ("dcim"      . "/storage/emulated/0/DCIM")
    ("pictures"  . "/storage/emulated/0/Pictures")
    ("music"     . "/storage/emulated/0/Music")
    ("movies"    . "/storage/emulated/0/Movies"))
  "The ~/storage symlinks, mirroring TermuxInstaller.setupStorageSymlinks.
The Android side creates these when `termux-setup-storage' (shell)
runs and the app answers its broadcast; this table lets the Emacs
side create (or refresh) the same set without shelling out.")

;;;###autoload
(defun termux-setup-storage ()
  "Set up ~/storage symlinks to Android shared storage, from Emacs.

The Emacs-side equivalent of the `termux-setup-storage' shell
command.  Both create the same symlinks in the same shared HOME,
so it does not matter which one runs first.

If shared storage is not readable yet, this opens the Emacshell
page in Android Settings so storage access can be granted (the
exact toggle differs by Android version: \"Storage\"/\"Files and
media\" on older versions, \"All files access\" on Android 11+),
and asks you to run the command again afterwards."
  (interactive)
  (let ((shared "/storage/emulated/0"))
    (if (file-readable-p shared)
        (let ((dir (expand-file-name "storage" (emacshell-home)))
              (created 0))
          (make-directory dir t)
          (dolist (link termux-storage-links)
            (let ((name (expand-file-name (car link) dir)))
              (cond
               ((file-symlink-p name)        ; refresh stale targets
                (delete-file name)
                (make-symbolic-link (cdr link) name)
                (setq created (1+ created)))
               ((file-exists-p name)
                (message "termux-setup-storage: %s exists and is not a symlink; leaving it alone" name))
               (t
                (make-symbolic-link (cdr link) name)
                (setq created (1+ created))))))
          (message "Storage ready: ~/storage/{shared,downloads,dcim,pictures,music,movies} (%d symlinks)" created))
      (progn
        (start-process "termux-setup-storage" nil (emacshell-am)
                       "start" "-a" "android.settings.APPLICATION_DETAILS_SETTINGS"
                       "-d" (concat "package:" (emacshell-package-name)))
        (user-error
         "Shared storage is not readable yet.  Grant storage access (on Android 11+: \"All files access\") in the Emacshell settings page that just opened, then run M-x termux-setup-storage again")))))

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

Touches sources.list only when it names an upstream or retired
repository, or when the emacshell repository line is missing
entirely (ready-on-install contract, Owner order 2026-11-26:
no manual repair step); idempotent; the original line is preserved
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
              ;; a stale repo line present, or our line absent
              ;; (every install must end up with a working `pkg':
              ;; the ready-on-install contract, Owner order 2026-11-26)
              (or (cl-some #'emacshell--stale-repo-p lines)
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
                  (insert line "\n")))
              ;; No stale line carried the replacement and the
              ;; emacshell repo line is absent entirely: append it,
              ;; so every install ends up with a working `pkg'.
              (unless (or inserted (member repo-line lines))
                (insert "# emacshell: this app's own repository (added by termux-fix-repo)\n")
                (insert repo-line "\n")
                (setq changed t))))
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

(defun emacshell-maybe-purge-dpkg-perl ()
  "Startup hook: drop dpkg-perl when its unshipped deps poison apt.
Upstream's dpkg-perl subpackage declares Depends: perl, clang, make
-- a toolchain the bootstrap never ships -- so any install whose
dpkg status database still lists it (upgrades from v0.1.4-era
bootstraps) dies on every `pkg upgrade' with `dpkg-perl: Depends:
clang but it is not installed' until the subpackage is removed.
Fresh installs are immune (build-bootstrap patch 4 never packs it).
Called from site-start.el for every interactive Emacs; a no-op --
one status-DB read -- once the install is clean."
  (unless (or noninteractive
              (string= (emacshell-package-name) "com.termux"))
    (ignore-errors
      (let ((status (expand-file-name "var/lib/dpkg/status"
                                      (emacshell-prefix)))
            (dpkg (expand-file-name "bin/dpkg" (emacshell-prefix))))
        (when (and (file-readable-p status)
                   (file-executable-p dpkg)
                   (with-temp-buffer
                     (insert-file-contents-literally status)
                     (goto-char (point-min))
                     (re-search-forward "^Package: dpkg-perl$" nil t)))
          (when (eq 0 (call-process dpkg nil nil nil
                                    "--remove" "dpkg-perl"))
            (message "emacshell: removed dpkg-perl (its toolchain \
deps are not shipped); pkg upgrade works again")))))))

(defun emacshell-maybe-fix-repo ()
  "Startup hook: make sure apt points at the emacshell repository.
Called from site-start.el for every interactive Emacs the app
starts; batch Emacs is left alone.  Cheap (one file read) and fully
idempotent -- the emacshell repository line is ensured on every
install (ready-on-install contract, Owner order
2026-11-26), stale
upstream/retired lines are rewritten (preserved as comments), and
a user who deliberately re-adds an upstream line is not fought
with beyond the exact default lines."
  (unless (or noninteractive
              (string= (emacshell-package-name) "com.termux"))
    (ignore-errors
      (when (termux-fix-repo t)
        (message "emacshell: apt sources switched to the emacshell repo \
(run M-x termux-repair if pkg still misbehaves)")))))

(provide 'emacshell)
;;; emacshell.el ends here
