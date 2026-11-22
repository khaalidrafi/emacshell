;;; elwidget-org.el --- Built-in Org widgets for elwidget -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: GLM 5.3 <glm-5.3@z.ai>
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1") (org "9.3"))
;; Keywords: widgets, org, android

;;; Commentary:

;; Built-in widgets that render Org data to the home screen, shipped
;; with the widget maker itself (Owner order 2026-11-15):
;;
;;   org-agenda  -- today's schedule (times + headings)
;;   org-tasks   -- next TODO entries, tappable to DONE
;;   org-habits  -- the habit list (loophabits when installed, else
;;                  Org's own STYLE=habit entries)
;;   org-clock   -- clock in / clock out / what is clocked right now
;;   org-table   -- a named org table, rendered as rows
;;
;; Everything renders OFFLINE from the files; no network.  The
;; widgets reuse existing Org features instead of reimplementing
;; them (Owner order 2026-11-18): entry collection goes through
;; `org-map-entries' (the agenda's own scanner, archived subtrees
;; skipped like the agenda does); "is this timestamp due today" is
;; delegated to `org-time-string-to-absolute' and `org-today', so
;; cyclic timestamps (repeaters) land on their next occurrence
;; instead of only on their start date; TODO state, doneness and
;; headings come from `org-entry-is-todo-p', `org-entry-is-done-p'
;; and `org-get-heading'; stable tap ids are minted by
;; `org-id-get-create' AT the collected entry (no heading-text
;; matching); habit "done today" is `org-habit-parse-todo' (the
;; consistency graph's own parser) checked against `org-today';
;; the clock widget's recents are `org-clock-history' and the
;; in/out commands are `org-clock-in'/`org-clock-out' themselves;
;; and table rows are split by `org-table-to-lisp' once
;; `org-element' has located the named table.
;;
;; Tap feedback: check nodes use the "toggle" action so the app's
;; shadow state flips them instantly (Owner order 2026-11-23:
;; "Add some widgets to the Emacshell for clocking, habit updating
;; etc. basic Org tasks"); Emacs re-renders authoritatively on the
;; next sync (the 15 s poller / `focus-in-hook').
;;
;; `(elwidget-org-register-widgets)' defines all of them.

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-clock)
(require 'org-id)
(require 'elwidget)
(require 'cl-lib)

(declare-function loophabits-toggle "loophabits" (id))
(declare-function loophabits-elwidget-tree "loophabits" ())
(declare-function loophabits-elwidget-state "loophabits" ())
(declare-function org-is-habit-p "org-habit" (&optional epom))
(declare-function org-habit-parse-todo "org-habit" (&optional epom))
(declare-function org-habit-done-dates "org-habit" (habit))

(defgroup elwidget-org nil
  "Org-built widgets for the elwidget widget maker."
  :group 'elwidget)

(defcustom elwidget-org-agenda-files nil
  "Agenda files for the widgets; defaults to `org-agenda-files'."
  :type '(repeat file))

(defcustom elwidget-org-task-count 7
  "How many TODO rows the org-tasks widget shows."
  :type 'natnum)

(defcustom elwidget-org-habit-count 7
  "How many rows the built-in org-habits fallback shows."
  :type 'natnum)

(defcustom elwidget-org-agenda-count 10
  "How many rows the org-agenda widget shows."
  :type 'natnum)

(defcustom elwidget-org-clock-recent-count 4
  "How many recent entries the org-clock widget offers to clock in."
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

;;; --- entry collection --------------------------------------------------------

(defun elwidget-org--collect (predicate &optional done-fn)
  "Collect (TITLE KEYWORD DONE ID) for entries where PREDICATE holds.
PREDICATE runs with point at the headline, `org-map-entries'
style, so it can call `org-entry-get', `org-is-habit-p' and
friends directly.  DONE is what DONE-FN returns when given,
`org-entry-is-done-p' otherwise -- the habit list passes its own
reading there.  Collection itself is Org's scanner:
`org-map-entries' walks each file (archived subtrees skipped,
like the agenda), `org-get-heading' and `org-get-todo-state'
produce the title and keyword, and `org-id-get-create' mints the
stable tap id AT the entry -- no heading-text matching.  A file
is saved only when an id was actually minted in it."
  (let (out)
    (dolist (file (elwidget-org--files))
      (when (file-exists-p file)
        (with-current-buffer (find-file-noselect file)
          (let ((minted nil))
            (dolist (entry (org-map-entries
                            (lambda ()
                              (when (funcall predicate)
                                (unless (org-entry-get (point) "ID")
                                  (setq minted t))
                                (list (org-get-heading t t)
                                      (org-get-todo-state)
                                      (funcall (or done-fn
                                                   #'org-entry-is-done-p))
                                      (org-id-get-create))))
                            nil 'file 'archive))
              (when entry (push entry out)))
            (when minted (save-buffer))))))
    (nreverse out)))

;;; --- org-agenda --------------------------------------------------------------

(defun elwidget-org--timestamp-due-today-p (ts)
  "Non-nil when timestamp element TS is due today.
The date arithmetic is Org's own: for a cyclic timestamp
`org-time-string-to-absolute' returns the occurrence closest to
the day number given as second argument, so an exact match with
`org-today' means today IS an occurrence -- repeaters land on
their next occurrence, not only their start date.  Diary sexp
timestamps that do not match today are skipped: the conversion
signals `org-diary-sexp-no-match' for them."
  (and (eq 'active (org-element-property :type ts))
       (condition-case nil
           (= (org-time-string-to-absolute
               (org-element-property :raw-value ts)
               (org-today))
              (org-today))
         (org-diary-sexp-no-match nil))))

(defun elwidget-org--entries-for-today ()
  "Today's scheduled/deadline entries: ((TIME TITLE)...) sorted.
Collection mirrors the agenda's own approach: `org-element'
parses each file and keeps active SCHEDULED/DEADLINE timestamps
that are due today (see `elwidget-org--timestamp-due-today-p')."
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
                           (elwidget-org--timestamp-due-today-p ts))
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

;;; --- org-tasks ---------------------------------------------------------------

(defun elwidget-org--todo-entries ()
  "Open TODO entries as (TITLE KEYWORD DONE ID), file by file.
Openness is decided by `org-entry-is-todo-p'; collection and id
minting happen in `elwidget-org--collect'."
  (elwidget-org--collect #'org-entry-is-todo-p))

(defun elwidget-org--tasks-render ()
  "Render the org-tasks widget tree (a LIST of nodes)."
  (let* ((entries (elwidget-org--todo-entries))
         (shown (seq-take entries elwidget-org-task-count))
         (nodes (list `(:text "Tasks" :size 16 :bold t
                               :color ,elwidget-org-accent))))
    (dolist (e shown)
      (let* ((title (nth 0 e))
             (kw (nth 1 e))
             (id (nth 3 e)))
        (nconc nodes
               (list
                `(:row (:check off :action "toggle" :arg ,id
                               :color ,elwidget-org-done-color)
                       (:text ,(truncate-string-to-width
                                (concat (when kw (concat kw " ")) title)
                                34 nil nil "...")
                              :size 13))))))
    (unless entries
      (nconc nodes (list '(:text "No open tasks" :size 13))))
    nodes))

(defun elwidget-org--tasks-state ()
  "Shadow state for org-tasks: every open task's id starts unchecked."
  (mapcar (lambda (e) (cons (nth 3 e) 0))
          (elwidget-org--todo-entries)))

(defun elwidget-org--todo-on-event (action arg)
  "Handle an org-tasks tap: cycle the entry with org-id ARG.
`org-id-find' locates the heading (ids are minted at collection
time), then `org-todo' does the actual state change -- including
Org's habit semantics when the entry carries a repeater.  The
action is \"toggle\" (the shadow-state word, so the app flips the
check instantly) or the older \"org-todo\" spelling from specs
rendered before v0.3.0."
  (when (member action '("toggle" "org-todo"))
    (let ((m (ignore-errors (org-id-find arg 'marker))))
      (when (and m (marker-buffer m))
        (with-current-buffer (marker-buffer m)
          (save-excursion
            (save-restriction
              (widen)
              (goto-char m)
              (org-todo)
              t)))))))

;;; --- org-habits --------------------------------------------------------------

(defun elwidget-org--habit-done-today-p ()
  "Non-nil when the habit at point was done today.
Org's own reading, not a reimplementation: `org-habit-parse-todo'
(the parser behind the consistency graph) returns the done-dates
and `org-today' is today's day number.  A habit whose schedule or
repeater is missing or malformed (parse-todo errors) falls back
to the TODO state, and so does a stock Org without org-habit."
  (if (require 'org-habit nil t)
      (let ((habit (ignore-errors (org-habit-parse-todo))))
        (if habit
            (and (member (org-today) (org-habit-done-dates habit)) t)
          (org-entry-is-done-p)))
    (org-entry-is-done-p)))

(defun elwidget-org--habit-entries ()
  "STYLE=habit entries as (TITLE KEYWORD DONE-TODAY ID)."
  (elwidget-org--collect #'org-is-habit-p
                         #'elwidget-org--habit-done-today-p))

(defun elwidget-org--habits-render ()
  "Render the org-habits widget tree.
With the personal loophabits package installed, delegate to it
(shadow state, instant flips).  Otherwise render Org's own habit
convention -- STYLE=habit entries, as understood by the built-in
org-habit library -- instead of demanding an external package:
reuse over reimplementation (Owner order 2026-11-18).  The check
state is \"done today\" per the consistency graph's own parser."
  (if (require 'lophabits nil t)
      (loophabits-elwidget-tree)
    (if (require 'org-habit nil t)
        (let* ((entries (elwidget-org--habit-entries))
               (shown (seq-take entries elwidget-org-habit-count)))
          (if (null entries)
              '(:text "No STYLE=habit entries" :size 13)
            (append
             (list `(:text "Habits" :size 16 :bold t
                           :color ,elwidget-org-accent))
             (mapcar
              (lambda (e)
                `(:row (:check ,(if (nth 2 e) t 'off)
                               :action "toggle" :arg ,(nth 3 e)
                               :color ,elwidget-org-done-color)
                       (:text ,(truncate-string-to-width
                                (nth 0 e) 30 nil nil "...")
                              :size 13)))
              shown))))
      '(:text "org-habit is not available" :size 13))))

(defun elwidget-org--habits-state ()
  "Shadow state for org-habits (id -> done-today 0/1).
loophabits owns its own state function when it is installed."
  (if (require 'lophabits nil t)
      (loophabits-elwidget-state)
    (mapcar (lambda (e) (cons (nth 3 e) (if (nth 2 e) 1 0)))
            (elwidget-org--habit-entries))))

(defun elwidget-org--habits-on-event (action arg)
  "Handle habit taps.
\"toggle\" goes to loophabits when it is installed; the built-in
habit list reuses the org-tasks tap (`elwidget-org--todo-on-event')
-- `org-todo' on a repeater habit logs today's done date and
advances the schedule, exactly what the consistency graph reads."
  (cond ((and (require 'lophabits nil t)
              (equal action "toggle"))
         (loophabits-toggle arg)
         t)
        ((member action '("toggle" "org-todo"))
         (elwidget-org--todo-on-event action arg))))

;;; --- org-clock ---------------------------------------------------------------

(defun elwidget-org--clock-running-p ()
  "Non-nil when Org has a live clock right now."
  (and (bound-and-true-p org-clock-hd-marker)
       (marker-buffer org-clock-hd-marker)
       (bound-and-true-p org-clock-start-time)))

(defun elwidget-org--clock-recent-entries ()
  "Recently clocked entries ((TITLE ID)...), most recent first.
The list IS `org-clock-history' -- Org's own recency record of
clocked headings (markers, newest first) -- filtered to live
markers and deduplicated.  ids are minted AT each entry, so a tap
keeps working across renders and history rotation."
  (let ((seen nil) (out))
    (dolist (m (and (listp org-clock-history) org-clock-history))
      (when (and (markerp m) (marker-buffer m))
        (let ((key (list (marker-buffer m) (marker-position m))))
          (unless (member key seen)
            (push key seen)
            (with-current-buffer (marker-buffer m)
              (save-excursion
                (save-restriction
                  (widen)
                  (goto-char m)
                  (let ((title (org-get-heading t t)))
                    (when (and (stringp title) (not (string= title "")))
                      (let ((had-id (org-entry-get (point) "ID"))
                            (id (org-id-get-create)))
                        (unless had-id (save-buffer))
                        (when id (push (list title id) out))))))))))))
    (nreverse out)))

(defun elwidget-org--clock-render ()
  "Render the org-clock widget tree (a LIST of nodes).
Running: heading, live duration, a CLOCK OUT button.  Idle: the
recent-clock list (Org's own `org-clock-history') as CLOCK IN
buttons -- most recent first, so the top row resumes the last
task."
  (if (elwidget-org--clock-running-p)
      (let* ((duration (/ (float-time
                          (time-subtract (current-time)
                                         org-clock-start-time))
                         60.0))
             (hours (floor (/ duration 60)))
             (mins (floor (mod duration 60))))
        (list
         `(:text ,(if (stringp org-clock-heading)
                      (truncate-string-to-width org-clock-heading 34 nil nil "…")
                    "Clocked in")
                 :size 14 :bold t)
         `(:row (:text ,(format "%dh %02dm" hours mins)
                       :size 22 :color ,elwidget-org-accent)
                (:button "Clock out" :action "clock-out" :arg "now"))
         '(:bar :height 2 :color "#45475a")))
    (let ((recent (seq-take (elwidget-org--clock-recent-entries)
                            elwidget-org-clock-recent-count)))
      (if (null recent)
          (list '(:text "Not clocked in" :size 14))
        (append
         (list '(:text "Not clocked in" :size 14))
         (mapcar
          (lambda (e)
            `(:button ,(truncate-string-to-width (nth 0 e) 28 nil nil "…")
                      :action "clock-in" :arg ,(nth 1 e)))
          recent))))))

(defun elwidget-org--clock-on-event (action arg)
  "Handle org-clock widget taps.
\"clock-out\" stops the running clock; \"clock-in\" starts one at
the entry whose org id is in the tap.  Both are Org's own
commands (`org-clock-out', `org-clock-in'), so the LOGBOOK, the
clock table and `org-clock-history' all see them."
  (cond
   ((equal action "clock-out")
    (ignore-errors (org-clock-out))
    t)
   ((equal action "clock-in")
    (let ((m (ignore-errors (org-id-find arg 'marker))))
      (when (and m (marker-buffer m))
        (with-current-buffer (marker-buffer m)
          (save-excursion
            (save-restriction
              (widen)
              (goto-char m)
              (ignore-errors (org-clock-in)))))
        t)))))

;;; --- org-table ---------------------------------------------------------------

(defun elwidget-org--table-rows (file name &optional max-rows)
  "Rows of the #+NAME (or legacy #+TBLNAME) table NAME in FILE.
Both halves are Org's: `org-element' locates the named table
(affiliated keywords handled exactly as Org handles them), and
`org-table-to-lisp' splits it into rows of cell strings.  Its
`hline' separator rows are dropped.  Return at most MAX-ROWS
rows, as lists of strings."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (let ((tbl nil))
        (org-element-map (org-element-parse-buffer) 'table
          (lambda (node)
            (when (and (null tbl)
                       (equal (org-element-property :name node) name))
              (setq tbl node))))
        (when tbl
          (let ((rows (org-table-to-lisp
                       (buffer-substring-no-properties
                        (org-element-property :contents-begin tbl)
                        (org-element-property :contents-end tbl)))))
            (seq-take (seq-remove (lambda (r) (eq r 'hline)) rows)
                      (or max-rows (length rows)))))))))

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
    :on-event #'elwidget-org--todo-on-event
    :state #'elwidget-org--tasks-state)
  (elwidget-define "org-habits"
    :title "Habit list (tap to check)" :size [4 3]
    :render #'elwidget-org--habits-render
    :on-event #'elwidget-org--habits-on-event
    :state #'elwidget-org--habits-state)
  (elwidget-define "org-clock"
    :title "Org clock (in/out + recents)" :size [4 2]
    :render #'elwidget-org--clock-render
    :on-event #'elwidget-org--clock-on-event)
  (elwidget-define "org-table"
    :title "Org table" :size [4 2]
    :render (lambda ()
              (elwidget-org--table-render
               (or (car (elwidget-org--files)) "README.org")
               "elwidget-demo"))))

(provide 'elwidget-org)
;;; elwidget-org.el ends here
