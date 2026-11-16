;;; elwidget-org.el --- Built-in Org widgets for elwidget -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: GLM 5.3 <glm-5.3@z.ai>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org "9.3"))
;; Keywords: widgets, org, android

;;; Commentary:

;; Built-in widgets that render Org data to the home screen, shipped
;; with the widget maker itself (Owner order 2026-11-15):
;;
;;   org-agenda  -- today's schedule (times + headings)
;;   org-tasks   -- next TODO entries, tappable to DONE
;;   org-habits  -- the habit list (needs the loophabits package)
;;   org-clock   -- what is clocked right now + duration
;;   org-table   -- a named org table, rendered as rows
;;
;; Everything renders OFFLINE from the files; no network, no fancy
;; parsing.  `(elwidget-org-register-widgets)' defines all of them.

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-clock)
(require 'org-id)
(require 'elwidget)
(require 'cl-lib)

(declare-function loophabits-toggle "loophabits" (id))
(declare-function loophabits-elwidget-tree "loophabits" ())

(defgroup elwidget-org nil
  "Org-built widgets for the elwidget widget maker."
  :group 'elwidget)

(defcustom elwidget-org-agenda-files nil
  "Agenda files for the widgets; defaults to `org-agenda-files'."
  :type '(repeat file))

(defcustom elwidget-org-task-count 7
  "How many TODO rows the org-tasks widget shows."
  :type 'natnum)

(defcustom elwidget-org-agenda-count 10
  "How many rows the org-agenda widget shows."
  :type 'natnum)

(defcustom elwidget-org-accent "#89b4fa"
  "Accent color for times and counters."
  :type 'string)

(defcustom elwidget-org-done-color "#a6e3a1"
  "Color for done marks."
  :type 'string)

(defun elwidget-org--files ()
  "Files to scan."
  (or elwidget-org-agenda-files (org-agenda-files)))

;;; --- org-agenda ------------------------------------------------------------

(defun elwidget-org--timestamp-today-p (ts)
  "Non-nil when timestamp element TS starts today."
  (let ((now (decode-time)))
    (and (org-element-property :year-start ts)
         (= (org-element-property :year-start ts) (nth 5 now))
         (= (org-element-property :month-start ts) (nth 4 now))
         (= (org-element-property :day-start ts) (nth 3 now)))))

(defun elwidget-org--entries-for-today ()
  "Today's scheduled/deadline entries: ((TIME TITLE)...) sorted."
  (let (entries)
    (dolist (file (elwidget-org--files))
      (when (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (org-mode)
          (org-element-map (org-element-parse-buffer) 'headline
            (lambda (h)
              (let ((ts (or (org-element-property :scheduled h)
                            (org-element-property :deadline h))))
                (when (and ts
                           (eq 'active
                               (org-element-property :type ts))
                           (elwidget-org--timestamp-today-p ts))
                  (let ((hour (org-element-property :hour-start ts))
                        (min (org-element-property :minute-start ts)))
                    (push (list (if hour
                                    (format "%02d:%02d" hour (or min 0))
                                  "----")
                                (org-element-property :raw-value h))
                          entries)))))))))
    (sort entries (lambda (a b) (string< (car a) (car b))))))

(defun elwidget-org--agenda-render ()
  "Render the org-agenda widget tree (a LIST of nodes)."
  (let* ((rows (elwidget-org--entries-for-today))
         (shown (seq-take rows elwidget-org-agenda-count))
         (more (- (length rows) (length shown)))
         (nodes (list `(:text ,(format-time-string "%A, %e %b")
                              :size 16 :bold t
                              :color ,elwidget-org-accent))))
    (dolist (row shown)
      (nconc nodes
             (list `(:row
                     (:text ,(car row) :size 13
                            :color ,elwidget-org-accent :bold t)
                     (:text ,(nth 1 row) :size 13)))))
    (when (> more 0)
      (nconc nodes (list `(:text ,(format "+%d more" more) :size 11))))
    (unless rows
      (nconc nodes (list '(:text "Nothing scheduled today" :size 13))))
    nodes))

;;; --- org-tasks -------------------------------------------------------------

(defun elwidget-org--todo-entries ()
  "Open TODO entries as (TITLE KEYWORD FILE), file by file."
  (let ((out nil))
    (dolist (file (elwidget-org--files))
      (when (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (org-mode)
          (org-element-map (org-element-parse-buffer) 'headline
            (lambda (h)
              (when (eq 'todo (org-element-property :todo-type h))
                (push (list (org-element-property :raw-value h)
                            (org-element-property :todo-keyword h)
                            file)
                      out)))))))
    (nreverse out)))

(defun elwidget-org--ensure-id (file title)
  "Return a stable org-id for FILE's heading TITLE, creating one.
The id persists in the file so widget taps keep working across
process restarts.  The buffer is saved only when an id was created."
  (let ((id nil)
        (patterns nil))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (widen)
          ;; Match "* KEYWORD Title" first, then plain "* Title".
          (setq patterns
                (list (concat "^[*]+[ \t]+[^ \t]+[ \t]+"
                             (regexp-quote title) "[ \t]*$")
                      (concat "^[*]+[ \t]+"
                             (regexp-quote title) "[ \t]*$")))
          (while (and patterns (null id))
            (goto-char (point-min))
            (when (re-search-forward (car patterns) nil t)
              (setq id (org-entry-get (point) "ID"))
              (unless id
                (setq id (org-id-get-create))
                (save-buffer)))
            (setq patterns (cdr patterns)))))
      id)))

(defun elwidget-org--tasks-render ()
  "Render the org-tasks widget tree (a LIST of nodes)."
  (let* ((entries (elwidget-org--todo-entries))
         (shown (seq-take entries elwidget-org-task-count))
         (nodes (list `(:text "Tasks" :size 16 :bold t
                               :color ,elwidget-org-accent))))
    (dolist (e shown)
      (let* ((title (nth 0 e))
             (kw (nth 1 e))
             (file (nth 2 e))
             (id (elwidget-org--ensure-id file title)))
        (when id
          (nconc nodes
                 (list
                  `(:row (:check off :action "org-todo" :arg ,id
                                 :color ,elwidget-org-done-color)
                         (:text ,(truncate-string-to-width
                                  (concat (when kw (concat kw " ")) title)
                                  34 nil nil "...")
                                :size 13)))))))
    (unless entries
      (nconc nodes (list '(:text "No open tasks" :size 13))))
    nodes))

(defun elwidget-org--tasks-on-event (action arg)
  "Handle org-tasks taps: ACTION org-todo toggles heading id ARG."
  (when (equal action "org-todo")
    (let ((m (ignore-errors (org-id-find arg 'marker))))
      (when (and m (marker-buffer m))
        (with-current-buffer (marker-buffer m)
          (save-excursion
            (save-restriction
              (widen)
              (goto-char m)
              (org-todo)
              t)))))))

;;; --- org-habits ------------------------------------------------------------

(defun elwidget-org--habits-render ()
  "Render the org-habits widget tree (needs the loophabits package)."
  (if (require 'loophabits nil t)
      (loophabits-elwidget-tree)
    '(:text "Install the loophabits package" :size 12)))

(defun elwidget-org--habits-on-event (action arg)
  "Forward habit widget taps to loophabits."
  (when (and (require 'loophabits nil t)
             (equal action "toggle"))
    (loophabits-toggle arg)
    t))

;;; --- org-clock -------------------------------------------------------------

(defun elwidget-org--clock-render ()
  "Render the org-clock widget tree."
  (if (and (bound-and-true-p org-clock-hd-marker)
           (marker-buffer org-clock-hd-marker)
           (bound-and-true-p org-clock-start-time))
      (let* ((duration (/ (float-time
                          (time-subtract (current-time)
                                         org-clock-start-time))
                         60.0))
             (hours (floor (/ duration 60)))
             (mins (floor (mod duration 60))))
        `(:text ,(if (stringp org-clock-heading)
                     (truncate-string-to-width org-clock-heading 36 nil nil "…")
                   "Clocked in")
                :size 14 :bold t
                :row (:text ,(format "%dh %02dm" hours mins)
                            :size 22 :color ,elwidget-org-accent)
                :bar :height 2 :color "#45475a"))
    '(:text "Not clocked in" :size 14)))

;;; --- org-table -------------------------------------------------------------

(defun elwidget-org--table-rows (file name &optional max-rows)
  "Rows of the #+NAME: NAME table in FILE, as lists of strings."
  (let ((rows nil)
        (in-table nil)
        (want (regexp-quote name)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (cond
           ((and (looking-at (concat "#\\+NAME:[ \t]+" want "[ \t]*$")))
            (setq in-table 'waiting))
           ((and (eq in-table 'waiting)
                 (looking-at "[ \t]*|"))
            (setq in-table t))
           ((and (eq in-table t) (not (looking-at "[ \t]*|")))
            (setq in-table nil)))
          (when (and (eq in-table t)
                     (not (looking-at "[ \t]*|[ \t]*[-:]"))
                     (or (null max-rows) (< (length rows) max-rows)))
            (let ((cells (split-string
                          (buffer-substring-no-properties
                           (line-beginning-position)
                           (line-end-position))
                          "|" t "[ \t]+")))
              (push (mapcar (lambda (c)
                              (replace-regexp-in-string
                               "^[ \t]+\\|[ \t]+$" "" c))
                            cells)
                    rows)))
          (forward-line 1))))
    (nreverse rows)))

(defun elwidget-org--table-render (file name)
  "Render the org table NAME in FILE as widget rows."
  (let ((rows (elwidget-org--table-rows file name)))
    (if rows
        (append '(:column)
                (mapcar (lambda (r)
                          (append '(:row)
                                  (mapcar (lambda (cell)
                                            `(:text ,cell :size 12))
                                          r)))
                        rows))
      `(:text ,(format "No table %s" name) :size 12))))

;;; --- Registration ----------------------------------------------------------

;;;###autoload
(defun elwidget-org-register-widgets ()
  "Define all built-in Org widgets."
  (interactive)
  (elwidget-define "org-agenda"
    :title "Org agenda (today)" :size [4 2]
    :render #'elwidget-org--agenda-render)
  (elwidget-define "org-tasks"
    :title "Org tasks (tap to close)" :size [4 2]
    :render #'elwidget-org--tasks-render
    :on-event #'elwidget-org--tasks-on-event)
  (elwidget-define "org-habits"
    :title "Habit list (tap to check)" :size [4 3]
    :render #'elwidget-org--habits-render
    :on-event #'elwidget-org--habits-on-event)
  (elwidget-define "org-clock"
    :title "Current clock" :size [4 1]
    :render #'elwidget-org--clock-render)
  (elwidget-define "org-table"
    :title "Org table" :size [4 2]
    :render (lambda ()
              (elwidget-org--table-render
               (or (car (elwidget-org--files)) "README.org")
               "elwidget-demo"))))

(provide 'elwidget-org)
;;; elwidget-org.el ends here
