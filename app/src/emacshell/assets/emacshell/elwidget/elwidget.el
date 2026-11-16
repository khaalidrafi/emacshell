;;; elwidget.el --- Widget maker: Elisp-defined Android home-screen widgets -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: GLM 5.3 <glm-5.3@z.ai>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: widgets, android, tools

;;; Commentary:

;; A widget maker for Emacs on Android: users define home-screen
;; widgets IN ELISP, elwidget renders them to JSON spec files, and the
;; emacshell app (tech.khalidrafi.emacshell) draws them as real
;; Android AppWidgets on the home screen.  Taps arrive back in Emacs
;; as events.  On a plain desktop Emacs the same specs are still
;; written -- they are just files -- so the package loads anywhere.
;;
;; Quick start (full story in README.org):
;;
;;     (elwidget-define "hello" :size [4 1]
;;       :render (lambda ()
;;         (list :text "Hello from Elisp!"
;;               :button "Open Emacs" :action "open" :arg "hello")))
;;     (elwidget-refresh)
;;
;; Then add the "Emacs Widget 4x1" widget on the home screen and pick
;; the "hello" spec in the configuration screen.
;;
;; Widget trees are plists of nodes; each node is a plist whose first
;; key names the node type:
;;
;;   (:text "..." :size 16 :bold t :color "#RRGGBB" :align left|center|right)
;;   (:column CHILD...)            vertical stack (implicit at the root)
;;   (:row CHILD...)               horizontal row
;;   (:check STATE :action "toggle" :arg "id" :label "..." :color "#RRGGBB")
;;           STATE is t (checked), off, skip or q; big tap target
;;   (:button "Label" :action "..." :arg "...")
;;   (:progress :value 3 :max 8 :label "3/8" :color "#RRGGBB")
;;   (:bar :height 2 :color "#RRGGBB")    thin colored rule
;;   (:gap :height 8)
;;
;; Colors are "#RRGGBB" strings; omitted colors inherit the spec's
;; default foreground.  Rendering targets Android RemoteViews, so the
;; node set is deliberately small (see README, "Why not arbitrary
;; layouts").

;;; Code:

(require 'json)
(require 'cl-lib)

;;; --- Customization ---------------------------------------------------------

(defgroup elwidget nil
  "Elisp-defined Android home-screen widgets."
  :group 'tools)

(defcustom elwidget-dir
  (expand-file-name "elwidget/" user-emacs-directory)
  "Directory shared with the Android widget provider.
The emacshell app watches this tree: specs/ holds rendered widgets,
bindings.json maps Android widget ids to spec names, state.json is
the instant-toggle shadow state, and events.jsonl is the tap queue
Emacs drains.  Must live under `user-emacs-directory' for the app's
FileObserver to see it (the app owns files under its home)."
  :type 'directory)

(defcustom elwidget-refresh-interval 900
  "Seconds between automatic widget re-renders.
Android itself re-draws widgets at most every 30 minutes; this timer
only refreshes the SPEC files Emacs controls."
  :type 'natnum)

(defcustom elwidget-poll-interval 15
  "Seconds between drains of the widget tap-event queue."
  :type 'natnum)

(defcustom elwidget-foreground "#cdd6f4"
  "Default foreground color for specs that do not set one."
  :type 'string)

(defcustom elwidget-background "#1e1e2e"
  "Default background color for specs that do not set one."
  :type 'string)

;;; --- Registry --------------------------------------------------------------

(cl-defstruct (elwidget-spec
               (:constructor elwidget-spec-create))
  "One defined widget."
  name                                  ; string, also the file name
  (size [4 2])                          ; [width height] in home cells
  render                                ; fn () -> node tree
  (on-event nil)                        ; fn (action arg) -> refresh-p
  (state nil)                           ; fn () -> alist ((arg . value))
  (title nil))                          ; shown in the picker

(defvar elwidget-registry nil
  "Alist of (NAME . `elwidget-spec' structs, in definition order.")

(defun elwidget-define (name &rest props)
  "Define (or redefine) widget NAME with PROPERTIES.
PROPERTIES: :render (required) fn returning a node tree; :size [W H];
:on-event fn (ACTION ARG); :state fn returning an alist for the
instant-toggle shadow; :title for the Android picker.
Redefinition re-renders immediately."
  (when (or (null name) (not (stringp name)) (string-empty-p name))
    (error "elwidget: widget name must be a non-empty string"))
  (let* ((render (plist-get props :render))
         (size (or (plist-get props :size) [4 2]))
         (title (or (plist-get props :title) name)))
    (unless (functionp render)
      (error "elwidget: %s needs a :render function" name))
    (unless (vectorp size)
      (error "elwidget: %s :size must be a vector [W H]" name))
    (let ((spec (elwidget-spec-create
                 :name name :size size :render render :title title
                 :on-event (plist-get props :on-event)
                 :state (plist-get props :state))))
      (setq elwidget-registry
            (cons (cons name spec)
                  (assq-delete-all name elwidget-registry)))
      spec)))

(defun elwidget-get (name)
  "Return the `elwidget-spec' named NAME, or nil."
  (cdr (assoc name elwidget-registry)))

(defun elwidget-undefine (name)
  "Remove widget NAME from the registry (files stay until pruned)."
  (setq elwidget-registry (assq-delete-all name elwidget-registry)))

;;; --- Files -----------------------------------------------------------------

(defun elwidget--file (relative)
  "Expand RELATIVE under `elwidget-dir', creating the directory."
  (make-directory elwidget-dir t)
  (expand-file-name relative elwidget-dir))

(defun elwidget--specs-dir ()
  "Return (and create) the specs directory."
  (make-directory (expand-file-name "specs" elwidget-dir) t)
  (expand-file-name "specs" elwidget-dir))

(defun elwidget-spec-file (name)
  "File NAME's rendered spec is written to."
  (expand-file-name (concat (file-name-nondirectory name) ".json")
                    (elwidget--specs-dir)))

(defun elwidget-spec-names-on-disk ()
  "Specs that exist on disk (may include ones not currently defined)."
  (when (file-directory-p (elwidget--specs-dir))
    (mapcar (lambda (f) (file-name-sans-extension (file-name-nondirectory f)))
            (directory-files (elwidget--specs-dir) nil "\\.json\\'"))))

(defun elwidget--write-json (object file)
  "Write OBJECT as JSON to FILE, atomically."
  (let ((tmp (concat file ".tmp"))
        (coding-system-for-write 'utf-8)
        (json-encoding-pretty-print t))
    (with-temp-file tmp
      (insert (json-encode object)))
    (rename-file tmp file t)))

;;; --- Tree -> JSON ----------------------------------------------------------

(defun elwidget--node-type (node)
  "Return the node-type keyword of NODE."
  (if (keywordp (car node)) (car node)
    (error "elwidget: bad node %S (starts with a non-keyword)" node)))

(defun elwidget--text-node (node)
  "Render (:text ...) NODE to a JSON-ready alist."
  (let ((text (nth 1 node))
        (rest (cddr node)))
    (unless (stringp text)
      (error "elwidget: :text node needs a string"))
    `((type . "text")
      (text . ,text)
      ,@(elwidget--opt rest :size 'number)
      ,@(elwidget--opt rest :bold 'bool)
      ,@(elwidget--opt rest :color 'string)
      (align . ,(elwidget--align (plist-get rest :align))))))

(defun elwidget--align (align)
  "Normalize ALIGN to a JSON string."
  (cond
   ((member align '(left "left" nil)) "left")
   ((member align '(center "center")) "center")
   ((member align '(right "right")) "right")
   (t (error "elwidget: bad :align %S" align))))

(defun elwidget--opt (plist key kind)
  "Return a 1-element alist for optional KEY in PLIST, else nil."
  (let ((v (plist-get plist key)))
    (cond
     ((null v) nil)
     ((eq kind 'number)
      (unless (numberp v) (error "elwidget: %s must be a number" key))
      `((,(cl-subseq (symbol-name key) 1) . ,v)))
     ((eq kind 'bool)
      `((,(cl-subseq (symbol-name key) 1) . ,(if v t :false))))
     (t
      (unless (stringp v) (error "elwidget: %s must be a string" key))
      `((,(cl-subseq (symbol-name key) 1) . ,v))))))

(defun elwidget--children (node)
  "The child nodes of a container NODE (everything after the keyword)."
  (cdr node))

(defun elwidget--container-node (node)
  "Render (:column ...)/(:row ...) NODE."
  `((type . ,(if (eq :row (elwidget--node-type node)) "row" "column"))
    (children . ,(mapcar #'elwidget--tree-to-json
                         (elwidget--children node)))))

(defun elwidget--check-node (node)
  "Render (:check STATE ...) NODE; STATE is t/off/skip/q."
  (let* ((state (nth 1 node))
         (rest (cddr node))
         (glyph (cond
                 ((memq state '(t on yes)) "on")
                 ((memq state '(nil off no)) "off")
                 ((memq state '(skip skipped)) "skip")
                 ((memq state '(q unknown)) "unknown")
                 (t (error "elwidget: check state must be t, off, skip or q, not %S" state)))))
    `((type . "check")
      (state . ,glyph)
      ,@(elwidget--opt rest :label 'string)
      ,@(elwidget--opt rest :color 'string)
      (action . ,(elwidget--action rest))
      (arg . ,(elwidget--action-arg rest)))))

(defun elwidget--action (rest)
  "The action string of a tap node's property list REST."
  (let ((a (plist-get rest :action)))
    (cond
     ((stringp a) a)
     ((eq a 'open) "open")
     (t (error "elwidget: tap nodes need :action (string or 'open)")))))

(defun elwidget--action-arg (rest)
  "The action argument of a tap node's property list REST."
  (let ((a (plist-get rest :arg)))
    (cond ((stringp a) a)
          ((null a) "")
          (t (format "%s" a)))))

(defun elwidget--button-node (node)
  "Render (:button ...) NODE."
  (let* ((label (nth 1 node))
         (rest (cddr node)))
    (unless (stringp label)
      (error "elwidget: :button node needs a label string"))
    `((type . "button")
      (label . ,label)
      ,@(elwidget--opt rest :color 'string)
      (action . ,(elwidget--action rest))
      (arg . ,(elwidget--action-arg rest)))))

(defun elwidget--progress-node (node)
  "Render (:progress ...) NODE."
  (let* ((rest (cdr node))
         (value (plist-get rest :value))
         (max (plist-get rest :max)))
    (unless (and (numberp value) (numberp max))
      (error "elwidget: :progress needs :value and :max numbers"))
    `((type . "progress")
      (value . ,value)
      (max . ,max)
      ,@(elwidget--opt rest :label 'string)
      ,@(elwidget--opt rest :color 'string))))

(defun elwidget--bar-node (node)
  "Render (:bar ...) NODE."
  `((type . "bar")
    ,@(elwidget--opt (cdr node) :height 'number)
    ,@(elwidget--opt (cdr node) :color 'string)))

(defun elwidget--gap-node (node)
  "Render (:gap ...) NODE."
  `((type . "gap")
    ,@(elwidget--opt (cdr node) :height 'number)))

(defun elwidget--tree-to-json (node)
  "Convert one NODE plist into a JSON-ready alist."
  (pcase (elwidget--node-type node)
    (:text (elwidget--text-node node))
    (:column (elwidget--container-node node))
    (:row (elwidget--container-node node))
    (:check (elwidget--check-node node))
    (:button (elwidget--button-node node))
    (:progress (elwidget--progress-node node))
    (:bar (elwidget--bar-node node))
    (:gap (elwidget--gap-node node))
    (other (error "elwidget: unknown node type %S" other))))

;;; --- Rendering -------------------------------------------------------------

(defun elwidget-render (name)
  "Render widget NAME to its spec file.  Return the file."
  (let* ((spec (elwidget-get name))
         (tree (condition-case err
                   (funcall (elwidget-spec-render spec))
                 (error
                  (error "elwidget: %s :render failed: %s" name
                         (error-message-string err)))))
         (children (if (and (listp tree) (keywordp (car tree)))
                       (list tree)    ; single node -> wrap
                     (mapcar (lambda (n)
                               (unless (and (listp n) (keywordp (car n)))
                                 (error "elwidget: %s: bad child %S" name n))
                               n)
                             tree)))
         (doc `((version . 1)
                (spec . ,name)
                (title . ,(or (elwidget-spec-title spec) name))
                (size . ,(append (elwidget-spec-size spec) nil))
                (fg . ,elwidget-foreground)
                (bg . ,elwidget-background)
                (children . ,(mapcar #'elwidget--tree-to-json children)))))
    (elwidget--write-json doc (elwidget-spec-file name))
    (elwidget-write-state)
    (elwidget-spec-file name)))

(defun elwidget-refresh (&optional name)
  "Render all defined widgets, or just NAME."
  (dolist (entry elwidget-registry)
    (when (or (null name) (equal (car entry) name))
      (elwidget-render (car entry)))))

(defun elwidget-write-state ()
  "Write the shadow state for every widget's :state function.
The Android provider flips these values instantly on tap; Emacs
rewrites the file authoritatively after every render/sync."
  (let ((state nil))
    (dolist (entry elwidget-registry)
      (let ((fn (elwidget-spec-state (cdr entry))))
        (when fn
          (let ((alist (funcall fn)))
            (dolist (cell alist)
              (push `(,(format "%s" (car cell))
                      . ,(elwidget--state-value (cdr cell)))
                    state))))))
    (elwidget--write-json (or state json-null)
                          (elwidget--file "state.json"))))

(defun elwidget--state-value (v)
  "Encode shadow-state value V."
  (cond ((numberp v) v)
        ((memq v '(t yes on)) 1)
        ((memq v '(nil no off)) 0)
        ((eq v 'skip) "skip")
        (t (format "%s" v))))

;;; --- Events ----------------------------------------------------------------

(defvar elwidget--event-cursor nil
  "Last event id drained from events.jsonl.")

(defun elwidget--events-file ()
  (elwidget--file "events.jsonl"))

(defun elwidget--event-cursor-file ()
  (elwidget--file "cursor.json"))

(defun elwidget--load-cursor ()
  "Restore the event cursor (survives Emacs restarts)."
  (let ((f (elwidget--event-cursor-file)))
    (when (file-exists-p f)
      (ignore-errors
        (setq elwidget--event-cursor
              (cdr (assq 'id (json-read-file f))))))))

(defun elwidget--save-cursor ()
  (elwidget--write-json `((id . ,(or elwidget--event-cursor 0)))
                        (elwidget--event-cursor-file)))

(defun elwidget-read-events ()
  "Drain new tap events and dispatch them.  Return events processed.
An event {\"action\":A,\"arg\":G,\"id\":N} is delivered to the handler
of the widget it belongs to (events carry the spec name since v1);
:action \"open\" just means the user tapped an open-target -- the
handler decides what to do (the app has already foregrounded Emacs)."
  (let ((file (elwidget--events-file))
        (processed 0)
        (refresh nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents-literally file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (when (and (not (string-empty-p line))
                       (string-prefix-p "{" line))
              (let* ((json-object-type 'alist)
                     (ev (condition-case nil (json-read-from-string line)
                           (error nil))))
                (when ev
                  (let ((id (cdr (assq 'id ev))))
                    (when (and (numberp id)
                               (or (null elwidget--event-cursor)
                                   (> id (or elwidget--event-cursor 0))))
                      (setq elwidget--event-cursor id)
                      (setq processed (1+ processed))
                      (when (elwidget--dispatch ev)
                        (setq refresh t)))))))
            (forward-line 1))))
    (when (> processed 0) (elwidget--save-cursor))
    (when refresh (elwidget-refresh))
    processed)))

(defun elwidget--dispatch (event)
  "Deliver EVENT to its widget handler.  Non-nil when a refresh is due."
  (let* ((spec-name (cdr (assq 'spec event)))
         (action (cdr (assq 'action event)))
         (arg (cdr (assq 'arg event)))
         (handler (when (stringp spec-name)
                    (elwidget-spec-on-event (elwidget-get spec-name)))))
    (if handler
        (condition-case err
            (funcall handler action arg)
          (error
           (message "elwidget: %s handler failed on %s/%s: %s"
                    spec-name action arg (error-message-string err))
           nil))
      ;; No handler (or unknown spec): default semantics for "toggle".
      (equal action "toggle"))))

;;; --- Timers ----------------------------------------------------------------

(defvar elwidget--timers nil
  "Active elwidget timers.")

;;;###autoload
(defun elwidget-start ()
  "Start the event poller and the periodic refresh."
  (interactive)
  (elwidget-stop)
  (elwidget--load-cursor)
  (push (run-at-time t elwidget-poll-interval #'elwidget-read-events)
        elwidget--timers)
  (push (run-at-time t elwidget-refresh-interval #'elwidget-refresh)
        elwidget--timers)
  (message "elwidget: started (poll %ss, refresh %ss)"
           elwidget-poll-interval elwidget-refresh-interval))

;;;###autoload
(defun elwidget-stop ()
  "Stop the timers."
  (interactive)
  (mapc #'cancel-timer elwidget--timers)
  (setq elwidget--timers nil))

;;;###autoload
(defun elwidget-sync ()
  "Full round: drain events, then re-render everything.
Also a good thing to call from `focus-in-hook' on a phone, where
Emacs is frozen in the background most of the time."
  (interactive)
  (elwidget-read-events)
  (elwidget-refresh))

;;;###autoload
(defun elwidget-bind ()
  "Interactively bind an Android widget slot to a spec.
Writes bindings.json, the same table the Android picker maintains."
  (interactive)
  (let* ((names (append (mapcar #'car elwidget-registry)
                        (elwidget-spec-names-on-disk)))
         (name (completing-read "Widget spec: " names nil t))
         (file (elwidget--file "bindings.json"))
         (bindings
          (if (file-exists-p file)
              (let ((json-object-type 'alist)
                    (json-array-type 'list))
                (condition-case nil
                    (cdr (assq 'bindings (json-read-file file)))
                  (error nil)))
            nil))
         (id (read-number "Android widget id (from the picker): " 1))
         (pair (list id name)))
    (setq bindings (cons pair
                         (cl-remove-if (lambda (b) (equal (car b) id))
                                       bindings)))
    (elwidget--write-json `((bindings . ,bindings)) file)
    (message "elwidget: widget %d -> %s (re-add the widget to apply)"
             id name)))

(provide 'elwidget)
;;; elwidget.el ends here
