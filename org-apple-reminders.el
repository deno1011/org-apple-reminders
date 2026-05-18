;;; org-apple-reminders.el --- Bidirectional org-mode ↔ Apple Reminders sync via JXA  -*- lexical-binding: t -*-

;; Copyright (C) 2025 Denis Butic

;; Author: Denis Butic <d.e.n.o@gmx.net>
;; Version: 1.6
;; Package-Requires: ((emacs "27.1") (org "9.3") (cl-lib "0.5"))
;; Keywords: org, outlines, apple, reminders, tools, macos
;; URL: https://github.com/deno1011/org-apple-reminders
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; org-apple-reminders provides bidirectional sync between an Org-mode file
;; and macOS Apple Reminders, using JavaScript for Automation (JXA) via
;; osascript.  No third-party CLI tools are required.
;;
;; Features:
;;   - Full bidirectional sync (org <-> Apple Reminders)
;;   - Conflict resolution via dual timestamps
;;     (REMINDER_APPLE_MOD vs REMINDER_ORG_MOD)
;;   - Fields synced: title, due date + time, priority (A/B/C <-> 1/5/9),
;;     flagged/starred, notes
;;   - Selective list sync via `org-apple-reminders-included-lists'
;;   - Progress cookies [N/M] on list headings
;;   - Org-agenda integration
;;   - Org-capture template
;;   - Automatic background pull (configurable interval)
;;
;; Requirements:
;;   - macOS 10.14+ (Mojave or later; JXA support required)
;;   - Emacs 27.1+
;;   - org-mode 9.3+
;;
;; Quick Start:
;;
;;   (require 'org-apple-reminders)
;;   (setq org-apple-reminders-sync-file "~/org/reminders.org")
;;   (org-apple-reminders-setup)
;;
;; Then press C-c r R to run a full sync.
;; See the README for full installation instructions and key bindings.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'json)

;;; Customisation

(defgroup org-apple-reminders nil
  "Integration between Emacs/Org and macOS Apple Reminders."
  :group 'org
  :prefix "org-apple-reminders-"
  :link '(url-link "https://github.com/deno1011/org-apple-reminders"))

(defcustom org-apple-reminders-default-list nil
  "Name of the Apple Reminders list used for Org-synced items.
nil means use the first list returned by Apple Reminders."
  :type '(choice (const :tag "Auto-detect first list" nil) string)
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-sync-list nil
  "Apple Reminders list used for bidirectional sync.
nil means use the first list returned by Apple Reminders."
  :type '(choice (const :tag "Auto-detect first list" nil) string)
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-sync-file "~/org/reminders.org"
  "Org file mirrored bidirectionally with `org-apple-reminders-sync-list'."
  :type 'string
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-auto-sync-interval 300
  "Seconds between background Apple -> org pulls.  0 to disable."
  :type 'integer
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-agenda-file nil
  "Separate auto-generated org file for org-agenda integration.
nil (default) means use `org-apple-reminders-sync-file' for the agenda.
Set to a file path only if you want a separate read-only agenda file."
  :type '(choice (const :tag "Use sync file (default)" nil) file)
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-included-lists nil
  "Apple Reminders lists to include in bidirectional sync.
nil (the default) means all lists are synced.
Set to a list of list-name strings to limit sync to those lists only:

  (setq org-apple-reminders-included-lists \\='(\"Work\" \"Personal\"))

Items already present in the org file are always kept in sync regardless
of this setting; the filter only prevents NEW Apple items from being
pulled into lists that are not included."
  :type '(choice (const  :tag "All lists" nil)
                 (repeat :tag "Specific lists" string))
  :group 'org-apple-reminders)

;;; List filter

(defun org-apple-reminders--list-included-p (list-name)
  "Return non-nil if LIST-NAME should participate in sync.
Always true when `org-apple-reminders-included-lists' is nil."
  (or (null org-apple-reminders-included-lists)
      (member list-name org-apple-reminders-included-lists)))

;;; Internal state

(defvar org-apple-reminders--syncing nil
  "Non-nil while a sync is in progress; prevents recursive save-hook calls.")

(defvar org-apple-reminders--cache nil
  "Last fetched Reminders data; used by push logic to detect changed fields.")

(defvar org-apple-reminders--sync-timer nil
  "Timer handle for periodic background pulls.")

;;; JXA helpers

(defun org-apple-reminders--jxa-run (script)
  "Run JXA SCRIPT synchronously via osascript.  Return stdout string."
  (string-trim (shell-command-to-string
                (concat "osascript -l JavaScript -e "
                        (shell-quote-argument script)))))

(defun org-apple-reminders--jxa-async (script &optional callback)
  "Run JXA SCRIPT via osascript asynchronously.
CALLBACK receives the stdout string when the process exits."
  (let ((buf (generate-new-buffer " *org-ar-jxa*")))
    (make-process
     :name "org-ar-jxa"
     :buffer buf
     :command (list "osascript" "-l" "JavaScript" "-e" script)
     :sentinel (lambda (proc _event)
                 (unless (process-live-p proc)
                   (let ((out (with-current-buffer buf
                                (string-trim (buffer-string)))))
                     (kill-buffer buf)
                     (when callback (funcall callback out))))))))

;;; List management

(defun org-apple-reminders--default-list ()
  "Return `org-apple-reminders-default-list', auto-detecting if nil."
  (or org-apple-reminders-default-list
      (car (ignore-errors (org-apple-reminders-lists)))))

(defun org-apple-reminders-lists ()
  "Return a list of Apple Reminders list names."
  (split-string
   (org-apple-reminders--jxa-run
    "JSON.stringify(Application('Reminders').lists.name())")
   nil t "[\"\n\\[\\],]"))

(defun org-apple-reminders-show-lists ()
  "Display all Apple Reminders lists in the echo area."
  (interactive)
  (message "Reminders lists:\n%s"
           (mapconcat (lambda (l) (concat "  • " l))
                      (org-apple-reminders-lists) "\n")))

(defun org-apple-reminders-create-list (name)
  "Create a new Apple Reminders list called NAME."
  (interactive "sNew list name: ")
  (when (string-empty-p (string-trim name))
    (user-error "List name cannot be empty"))
  (org-apple-reminders--jxa-async
   (format "Application('Reminders').lists.push(Application('Reminders').List({name:%s}));"
           (json-encode name))
   (lambda (_)
     (message "Apple Reminders: created list \"%s\"." name))))

;;;###autoload
(defun org-apple-reminders-open-file ()
  "Open `org-apple-reminders-sync-file' in the current window."
  (interactive)
  (find-file (expand-file-name org-apple-reminders-sync-file)))

;;; Field helpers

(defun org-apple-reminders--extract-notes ()
  "Extract body text from org heading, stripping LOGBOOK and org metadata."
  (save-excursion
    (org-back-to-heading t)
    (let* ((start (save-excursion (org-end-of-meta-data t) (point)))
           (end   (save-excursion (org-end-of-subtree t) (point)))
           (raw   (buffer-substring-no-properties start end)))
      (string-trim
       (replace-regexp-in-string ":LOGBOOK:\\(?:.\\|\n\\)*?:END:\n?" "" raw)))))

(defun org-apple-reminders--org-item-values ()
  "Return alist of org heading values that map to Apple Reminders fields."
  (save-excursion
    (org-back-to-heading t)
    (let* ((raw   (org-get-heading t t t t))
           (title (replace-regexp-in-string
                   "^\\(?:\\[#[ABC]\\] \\)?\\(?:★ \\)?" "" raw))
           (dl    (org-entry-get nil "DEADLINE"))
           (due   (when (and dl (string-match
                                 "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)\\(?:[^0-9]*\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)\\)?"
                                 dl))
                    (let ((date (match-string 1 dl))
                          (time (match-string 2 dl)))
                      (if time (concat date "T" time) date))))
           (prio-char (nth 3 (org-heading-components)))
           (prio  (cond ((eql prio-char ?A) 1)
                        ((eql prio-char ?B) 5)
                        ((eql prio-char ?C) 9)
                        (t 0)))
           (flagged (if (member "flagged" (org-get-tags nil t)) t nil))
           (notes   (org-apple-reminders--extract-notes)))
      `((title . ,title) (due . ,due) (priority . ,prio)
        (flagged . ,flagged) (notes . ,notes)))))

(defun org-apple-reminders--prio-label (p)
  "Return org priority prefix string for Apple priority integer P."
  (cond ((eql p 1) "[#A] ") ((eql p 5) "[#B] ") ((eql p 9) "[#C] ") (t "")))

(defun org-apple-reminders--format-due (due)
  "Format DUE string (YYYY-MM-DD or YYYY-MM-DDTHH:MM) as an org deadline timestamp."
  (let* ((has-time (string-match "T\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)" due))
         (time-str (when has-time (match-string 1 due)))
         (date-str (substring due 0 10))
         (time-obj (date-to-time (concat date-str (if has-time
                                                      (concat "T" time-str ":00")
                                                    "T12:00:00"))))
         (dow (format-time-string "%a" time-obj)))
    (if has-time
        (format "<%s %s %s>" date-str dow time-str)
      (format "<%s %s>" date-str dow))))

;;; Apple Reminders API (JXA)

(defconst org-apple-reminders--fetch-script
  "var app=Application('Reminders'),out=[];
app.lists().forEach(function(l){
  var rs=l.reminders;
  var names=rs.name(),ids=rs.id(),bodies=rs.body(),
      dates=rs.dueDate(),prios=rs.priority(),flags=rs.flagged(),compl=rs.completed(),
      mods=rs.modificationDate();
  var items=[];
  for(var i=0;i<names.length;i++){
    var d=dates[i],md=mods[i];
    items.push({id:ids[i],title:names[i],notes:bodies[i]||'',
                due:(d&&d instanceof Date&&!isNaN(d)&&d.getFullYear()>1970)?(function(){var ds=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');var h=d.getHours(),m=d.getMinutes();return(h||m)?ds+'T'+String(h).padStart(2,'0')+':'+String(m).padStart(2,'0'):ds;}()):null,
                priority:prios[i],flagged:flags[i],completed:!!compl[i],
                modDate:(md&&md instanceof Date&&!isNaN(md))?md.toISOString():null});
  }
  out.push({list:l.name(),items:items});
});
JSON.stringify(out);"
  "JXA script returning all Reminders as JSON.  Uses batch property fetch for speed.")

(defun org-apple-reminders--complete-in-apple (list-name id)
  "Mark Apple reminder ID in LIST-NAME as completed (async)."
  (org-apple-reminders--jxa-async
   (format "Application('Reminders').lists.byName(%s).reminders.byId(%s).completed=true;"
           (json-encode list-name) (json-encode id))))

(defun org-apple-reminders--delete-in-apple (list-name id &optional callback)
  "Delete Apple reminder ID from LIST-NAME asynchronously."
  (org-apple-reminders--jxa-async
   (format "Application('Reminders').lists.byName(%s).reminders.byId(%s).delete();"
           (json-encode list-name) (json-encode id))
   callback))

(defun org-apple-reminders--create-in-apple (list-name vals)
  "Create Apple reminder in LIST-NAME from VALS alist.
Return new ID string or nil."
  (let* ((title   (alist-get 'title    vals ""))
         (notes   (alist-get 'notes    vals ""))
         (prio    (alist-get 'priority vals 0))
         (due     (alist-get 'due      vals))
         (flagged (alist-get 'flagged  vals))
         (script
          (format
           "var app=Application('Reminders'),list=app.lists.byName(%s);
var prev=list.reminders.id();
list.reminders.push(app.Reminder({name:%s,body:%s,priority:%d,flagged:%s%s}));
var next=list.reminders.id(),newId=null;
for(var i=0;i<next.length;i++){if(prev.indexOf(next[i])<0){newId=next[i];break;}}
JSON.stringify(newId);"
           (json-encode list-name)
           (json-encode title) (json-encode notes) prio
           (if flagged "true" "false")
           (if due (format ",dueDate:new Date(%s)"
                           (json-encode (concat due (if (string-match "T" due) ":00" "T00:00:00")))) ""))))
    (condition-case nil
        (json-parse-string (org-apple-reminders--jxa-run script))
      (error nil))))

(defun org-apple-reminders--update-in-apple (list-name id vals &optional callback)
  "Push VALS alist to Apple reminder ID in LIST-NAME.
Without CALLBACK: synchronous; returns Apple's post-push modificationDate or nil.
With CALLBACK: async; CALLBACK receives the modificationDate string."
  (let* ((title   (alist-get 'title    vals ""))
         (notes   (alist-get 'notes    vals ""))
         (prio    (alist-get 'priority vals 0))
         (due     (alist-get 'due      vals))
         (flagged (alist-get 'flagged  vals))
         (script
          (format
           "var r=Application('Reminders').lists.byName(%s).reminders.byId(%s);
r.name=%s;r.body=%s;r.priority=%d;r.flagged=%s;%s
var md=r.modificationDate();JSON.stringify((md&&md instanceof Date)?md.toISOString():null);"
           (json-encode list-name) (json-encode id)
           (json-encode title) (json-encode notes) prio
           (if flagged "true" "false")
           (if due
               (format "r.dueDate=new Date(%s);"
                       (json-encode (concat due (if (string-match "T" due) ":00" "T00:00:00"))))
             "r.dueDate=null;"))))
    (if callback
        (org-apple-reminders--jxa-async
         script
         (lambda (raw)
           (funcall callback
                    (condition-case nil (json-parse-string raw) (error nil)))))
      (condition-case nil
          (json-parse-string (org-apple-reminders--jxa-run script))
        (error nil)))))

;;; Conflict resolution helpers

(defun org-apple-reminders--find-in-cache (id)
  "Return Apple cache item with REMINDER_ID = ID, or nil."
  (catch 'found
    (dolist (entry org-apple-reminders--cache)
      (dolist (item (alist-get 'items entry))
        (when (equal (alist-get 'id item) id)
          (throw 'found item))))))

(defun org-apple-reminders--last-known-mod ()
  "Return max(REMINDER_APPLE_MOD, REMINDER_ORG_MOD) for the entry at point, or nil."
  (let ((amod (org-entry-get nil "REMINDER_APPLE_MOD"))
        (omod (org-entry-get nil "REMINDER_ORG_MOD")))
    (cond
     ((and amod omod) (if (string> amod omod) amod omod))
     (amod amod)
     (omod omod)
     (t nil))))

;;; Interactive: add a reminder

(defun org-apple-reminders-add (title &optional list-name due-date notes)
  "Add a reminder TITLE to LIST-NAME with optional DUE-DATE and NOTES.
DUE-DATE is an ISO date string like \"2025-12-31\"."
  (interactive
   (list (read-string "Reminder: ")
         (completing-read "List: " (org-apple-reminders-lists) nil nil
                          (org-apple-reminders--default-list))
         (read-string "Due (optional, e.g. 2025-12-31): ")
         nil))
  (let* ((list (or list-name (org-apple-reminders--default-list)))
         (vals `((title . ,title) (notes . ,(or notes ""))
                 (priority . 0) (flagged . nil)
                 (due . ,(and due-date (not (string-empty-p due-date)) due-date)))))
    (org-apple-reminders--create-in-apple list vals)
    (message "Added to Apple Reminders [%s]: %s%s" list title
             (if (and due-date (not (string-empty-p due-date)))
                 (format " (due %s)" due-date) ""))))

;;; Org heading → Apple push

(defun org-apple-reminders-push-heading (&optional list-name)
  "Push org heading at point to Apple Reminders.
With prefix arg, prompt for list name."
  (interactive
   (when current-prefix-arg
     (list (completing-read "List: " (org-apple-reminders-lists) nil nil
                            (org-apple-reminders--default-list)))))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let* ((list (or list-name (org-apple-reminders--default-list)))
         (vals (org-apple-reminders--org-item-values))
         (new-id (org-apple-reminders--create-in-apple list vals)))
    (when new-id
      (org-set-property "REMINDER_ID"   new-id)
      (org-set-property "REMINDER_LIST" list)
      (message "Pushed to Apple Reminders [%s]: %s" list (alist-get 'title vals)))))

;;;###autoload
(defun org-apple-reminders-delete-reminder ()
  "Delete the reminder at point from Apple Reminders and from reminders.org.
Works in reminders.org directly or from any org buffer with REMINDER_ID."
  (interactive)
  (let ((loc (org-apple-reminders--loc-at-point)))
    (unless loc (user-error "No reminder at point"))
    (let* ((lname (car loc))
           (id    (cdr loc))
           (title (save-excursion
                    (org-back-to-heading t)
                    (org-get-heading t t t t))))
      (unless (yes-or-no-p (format "Delete \"%s\" from Apple Reminders and org? " title))
        (user-error "Aborted"))
      (org-apple-reminders--delete-in-apple lname id)
      (when-let (entry (cl-find lname org-apple-reminders--cache
                                :key (lambda (e) (alist-get 'list e))
                                :test #'string=))
        (let ((cell (assq 'items entry)))
          (when cell
            (setcdr cell (cl-remove id (cdr cell)
                                    :key (lambda (e) (alist-get 'id e))
                                    :test #'string=)))))
      (let ((file (expand-file-name org-apple-reminders-sync-file)))
        (when (file-exists-p file)
          (with-current-buffer (find-file-noselect file)
            (let ((org-apple-reminders--syncing t))
              (when-let (pos (org-find-property "REMINDER_ID" id))
                (goto-char pos)
                (org-back-to-heading t)
                (let ((beg (point))
                      (end (save-excursion (org-end-of-subtree t t) (point))))
                  (delete-region beg end))
                (save-buffer))))))
      (message "Deleted: %s" title))))

;;; Live hooks: TODO state, priority, deadline, tags

(defun org-apple-reminders--on-todo-state-change ()
  "Instantly sync org TODO state change to Apple Reminders via REMINDER_ID."
  (unless org-apple-reminders--syncing
    (let ((id   (org-entry-get nil "REMINDER_ID"))
          (list (org-entry-get nil "REMINDER_LIST")))
      (when (and id list)
        (cond
         ((member org-state '("DONE" "CANCELLED"))
          (org-apple-reminders--jxa-async
           (format "Application('Reminders').lists.byName(%s).reminders.byId(%s).completed=true;"
                   (json-encode list) (json-encode id))))
         ((member org-state '("TODO" "NEXT" "WAITING"))
          (org-apple-reminders--jxa-async
           (format "Application('Reminders').lists.byName(%s).reminders.byId(%s).completed=false;"
                   (json-encode list) (json-encode id)))))))))

(add-hook 'org-after-todo-state-change-hook #'org-apple-reminders--on-todo-state-change)

(defun org-apple-reminders--maybe-push-heading (&rest _)
  "Push heading at point to Apple if it has a REMINDER_ID."
  (when (and (derived-mode-p 'org-mode)
             (not org-apple-reminders--syncing))
    (condition-case err
        (let* ((id   (org-entry-get nil "REMINDER_ID"))
               (list (org-entry-get nil "REMINDER_LIST"))
               (m    (when (and id list)
                       (save-excursion (org-back-to-heading t) (point-marker)))))
          (when m
            (org-apple-reminders--update-in-apple
             list id (org-apple-reminders--org-item-values)
             (lambda (new-mod)
               (when (marker-buffer m)
                 (with-current-buffer (marker-buffer m)
                   (save-excursion
                     (goto-char m)
                     (when (stringp new-mod)
                       (org-set-property "REMINDER_ORG_MOD" new-mod)))))
               (set-marker m nil)))))
      (error (message "org-apple-reminders push: %s" (error-message-string err))))))

(advice-add 'org-priority         :after #'org-apple-reminders--maybe-push-heading)
(advice-add 'org-deadline         :after #'org-apple-reminders--maybe-push-heading)
(advice-add 'org-set-tags-command :after #'org-apple-reminders--maybe-push-heading)

;;; Org file helpers

(defun org-apple-reminders--goto-list-heading (list-name)
  "Move point to end of LIST-NAME's subtree, creating the * heading if absent."
  (goto-char (point-min))
  (if (re-search-forward (format "^\\* %s\\(?:[[:space:]]\\|$\\)" (regexp-quote list-name)) nil t)
      (org-end-of-subtree t t)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "* %s [/]\n" list-name)))
  (unless (bolp) (insert "\n")))

(defun org-apple-reminders--insert-org-heading (item list-name)
  "Insert ** TODO org heading for Apple ITEM under LIST-NAME's section."
  (let* ((id      (alist-get 'id       item))
         (title   (alist-get 'title    item))
         (notes   (alist-get 'notes    item))
         (due     (alist-get 'due      item))
         (prio    (alist-get 'priority item))
         (flagged (alist-get 'flagged  item)))
    (unless (bolp) (insert "\n"))
    (insert (format "** TODO %s%s%s\n"
                    (org-apple-reminders--prio-label prio)
                    (if (eq flagged t) "★ " "")
                    title))
    (when (and due (not (eq due :null)))
      (insert (format "   DEADLINE: %s\n" (org-apple-reminders--format-due due))))
    (insert (format "   :PROPERTIES:\n   :REMINDER_ID:   %s\n   :REMINDER_LIST: %s\n   :END:\n"
                    id list-name))
    (when (and (stringp notes) (not (string-empty-p notes)))
      (dolist (line (split-string notes "\n"))
        (insert (format "   %s\n" line))))))

;;; Push-only (org → Apple): called from save hook

(defun org-apple-reminders--push-to-apple ()
  "Push changed org entries to Apple.  New items get REMINDER_ID stamped back."
  (let* ((n-new 0) (n-updated 0)
         new-pts)
    (org-map-entries
     (lambda ()
       (let* ((id     (org-entry-get nil "REMINDER_ID"))
              (rlist  (org-entry-get nil "REMINDER_LIST"))
              (state  (org-get-todo-state))
              (cached (and id (org-apple-reminders--find-in-cache id))))
         (cond
          ((and (null id) (member state '("TODO" "NEXT" "WAITING")))
           (push (point-marker) new-pts))
          ((and id rlist (member state '("DONE" "CANCELLED")))
           (when (and cached (not (eq (alist-get 'completed cached) t)))
             (org-apple-reminders--complete-in-apple rlist id)))
          ((and id rlist (member state '("TODO" "NEXT" "WAITING")))
           (let* ((vals (org-apple-reminders--org-item-values))
                  (needs-push
                   (or (null cached)
                       (not (equal (or (alist-get 'title   vals) "")
                                   (or (alist-get 'title   cached) "")))
                       (not (equal (or (alist-get 'notes   vals) "")
                                   (or (alist-get 'notes   cached) "")))
                       (not (= (or (alist-get 'priority vals) 0)
                               (or (alist-get 'priority cached) 0)))
                       (not (equal (alist-get 'due vals)
                                   (let ((d (alist-get 'due cached)))
                                     (and (stringp d) (not (string-empty-p d)) d))))
                       (not (eq (alist-get 'flagged vals)
                                (eq (alist-get 'flagged cached) t))))))
             (when needs-push
               ;; Async update — capture position for the callback to stamp REMINDER_ORG_MOD
               (let ((m (point-marker)))
                 (org-apple-reminders--update-in-apple
                  rlist id vals
                  (lambda (new-mod)
                    (when (and (stringp new-mod) (marker-buffer m))
                      (with-current-buffer (marker-buffer m)
                        (save-excursion
                          (goto-char m)
                          (org-set-property "REMINDER_ORG_MOD" new-mod))))
                    (set-marker m nil))))
               (setq n-updated (1+ n-updated))))))))
     nil nil)
    ;; Create new items (sync — need the Apple ID back to stamp REMINDER_ID).
    ;; Defer --default-list lookup until we know there are new items.
    (when new-pts
      (let ((list-name (or org-apple-reminders-sync-list (org-apple-reminders--default-list))))
        (dolist (m (nreverse new-pts))
          (goto-char m)
          (when-let (new-id (org-apple-reminders--create-in-apple
                             list-name (org-apple-reminders--org-item-values)))
            (org-set-property "REMINDER_ID"   new-id)
            (org-set-property "REMINDER_LIST" list-name)
            (setq n-new (1+ n-new))))))
    (when (or (> n-new 0) (> n-updated 0))
      (message "Reminders push: %d new, %d updated." n-new n-updated))))

;;; Full bidirectional sync

;;;###autoload
(defun org-apple-reminders-sync ()
  "Full bidirectional sync: `org-apple-reminders-sync-file' ↔ all Apple Reminders lists.

Conflict resolution:
- New org item (no REMINDER_ID) → created in Apple, ID stamped back.
- Apple modDate unchanged since last sync → org wins: push org fields if different.
- Apple modDate newer than last sync → Apple wins: pull priority/due/flagged.
- DONE/CANCELLED in org, open in Apple → Apple completed.
- Open in org, completed/gone in Apple → org marked DONE.
- Open in Apple, missing from org → pulled under its * ListName heading."
  (interactive)
  (message "Reminders: syncing…")
  (let* ((default-list (org-apple-reminders--default-list))
         (file (expand-file-name org-apple-reminders-sync-file))
         (raw  (org-apple-reminders--jxa-run org-apple-reminders--fetch-script))
         (data (condition-case nil
                   (json-parse-string raw :object-type 'alist :array-type 'list)
                 (error (user-error "Reminders sync: fetch failed — %s" raw))))
         (apple-by-id (let ((ht (make-hash-table :test #'equal)))
                        (dolist (entry data)
                          (dolist (item (alist-get 'items entry))
                            (puthash (alist-get 'id item) item ht)))
                        ht))
         (n-done 0) (n-pushed 0) (n-pulled 0) (n-updated 0) (n-reopened 0))
    (unless (file-exists-p file)
      (with-temp-file file
        (insert "#+TITLE: Reminders\n#+STARTUP: overview\n#+TODO: TODO NEXT WAITING | DONE CANCELLED\n\n")))
    (let ((org-apple-reminders--syncing t))
      (with-current-buffer (find-file-noselect file)
        (org-save-outline-visibility t
        (let (done-pts new-pts reopen-pts apple-updates changed-positions)
          (org-map-entries
           (lambda ()
             (let* ((id    (org-entry-get nil "REMINDER_ID"))
                    (rlist (or (org-entry-get nil "REMINDER_LIST") default-list))
                    (state (org-get-todo-state)))
               (cond
                ((and (null id) (member state '("TODO" "NEXT" "WAITING")))
                 (push (point-marker) new-pts))
                (id
                 (let ((apple (gethash id apple-by-id)))
                   (cond
                    ((and (member state '("DONE" "CANCELLED"))
                          apple (not (eq (alist-get 'completed apple) t)))
                     (let* ((a-mod (let ((m (alist-get 'modDate apple)))
                                     (and (stringp m) (not (string-empty-p m)) m)))
                            (last  (org-apple-reminders--last-known-mod)))
                       (if (and a-mod (or (null last) (string> a-mod last)))
                           (push (point-marker) reopen-pts)
                         (org-apple-reminders--complete-in-apple rlist id))))
                    ((and (member state '("TODO" "NEXT" "WAITING"))
                          (or (null apple) (eq (alist-get 'completed apple) t)))
                     (push (point-marker) done-pts))
                    ((member state '("TODO" "NEXT" "WAITING"))
                     (let* ((a-mod        (let ((m (alist-get 'modDate apple)))
                                            (and (stringp m) (not (string-empty-p m)) m)))
                            (last-known   (org-apple-reminders--last-known-mod))
                            (apple-changed (and a-mod
                                               (or (null last-known)
                                                   (string> a-mod last-known)))))
                       (if apple-changed
                           (let* ((a-prio    (or (alist-get 'priority apple) 0))
                                  (a-due     (let ((d (alist-get 'due apple)))
                                               (and (stringp d) (not (string-empty-p d)) d)))
                                  (a-flagged (eq (alist-get 'flagged apple) t))
                                  (p-char    (nth 3 (org-heading-components)))
                                  (o-prio    (cond ((eql p-char ?A) 1)
                                                   ((eql p-char ?B) 5)
                                                   ((eql p-char ?C) 9)
                                                   (t 0)))
                                  (o-due     (let ((dl (org-entry-get nil "DEADLINE")))
                                               (when (and dl (string-match
                                                             "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" dl))
                                                 (match-string 1 dl))))
                                  (o-flagged (not (null (member "flagged" (org-get-tags nil t)))))
                                  (changed   (or (/= a-prio o-prio)
                                                 (not (equal a-due o-due))
                                                 (not (eq a-flagged o-flagged)))))
                             (when changed
                               (push (list (point-marker) rlist
                                           a-prio o-prio a-due o-due a-flagged o-flagged a-mod)
                                     apple-updates)))
                         (let* ((vals (org-apple-reminders--org-item-values))
                                (needs-push
                                 (or (not (equal (or (alist-get 'title vals) "")
                                                 (or (alist-get 'title apple) "")))
                                     (not (equal (or (alist-get 'notes vals) "")
                                                 (or (alist-get 'notes apple) "")))
                                     (not (= (or (alist-get 'priority vals) 0)
                                             (or (alist-get 'priority apple) 0)))
                                     (not (equal (alist-get 'due vals)
                                                 (let ((d (alist-get 'due apple)))
                                                   (and (stringp d) (not (string-empty-p d)) d))))
                                     (not (eq (alist-get 'flagged vals)
                                              (eq (alist-get 'flagged apple) t))))))
                           (when needs-push
                             (let ((new-mod (org-apple-reminders--update-in-apple rlist id vals)))
                               (when (stringp new-mod)
                                 (org-set-property "REMINDER_ORG_MOD" new-mod)))
                             (setq n-updated (1+ n-updated)))))))))))))
           nil nil)
          (dolist (m (nreverse done-pts))
            (goto-char m)
            (push (point-marker) changed-positions)
            (org-todo "DONE") (set-marker m nil)
            (setq n-done (1+ n-done)))
          (dolist (m (nreverse new-pts))
            (goto-char m)
            (push (point-marker) changed-positions)
            (let* ((rlist (or (org-entry-get nil "REMINDER_LIST") default-list))
                   (new-id (org-apple-reminders--create-in-apple
                            rlist (org-apple-reminders--org-item-values))))
              (when new-id
                (org-set-property "REMINDER_ID"   new-id)
                (org-set-property "REMINDER_LIST" rlist)
                (setq n-pushed (1+ n-pushed)))))
          (dolist (upd (nreverse apple-updates))
            (cl-destructuring-bind (m _rlist a-prio o-prio a-due o-due a-flagged o-flagged a-mod) upd
              (goto-char m)
              (push (point-marker) changed-positions)
              (unless (= a-prio o-prio)
                (org-priority (cond ((= a-prio 1) ?A)
                                    ((= a-prio 5) ?B)
                                    ((= a-prio 9) ?C)
                                    (t 'remove))))
              (unless (equal a-due o-due)
                (if a-due
                    (org-add-planning-info 'deadline (org-apple-reminders--format-due a-due))
                  (org-add-planning-info nil nil 'deadline)))
              (unless (eq a-flagged o-flagged)
                (org-toggle-tag "flagged" (if a-flagged 'on 'off)))
              (when (stringp a-mod)
                (org-set-property "REMINDER_APPLE_MOD" a-mod))
              (setq n-updated (1+ n-updated))
              (set-marker m nil)))
          (dolist (m (nreverse reopen-pts))
            (goto-char m)
            (push (point-marker) changed-positions)
            (org-todo "TODO")
            (set-marker m nil)
            (setq n-reopened (1+ n-reopened)))
        (let ((known-ids (let (ids)
                           (org-map-entries
                            (lambda () (when-let (id (org-entry-get nil "REMINDER_ID"))
                                         (push id ids)))
                            nil nil)
                           ids)))
          (dolist (entry data)
            (let ((lname (alist-get 'list  entry))
                  (items (alist-get 'items entry)))
              (when (org-apple-reminders--list-included-p lname)
                (dolist (item items)
                  (when (and (not (member (alist-get 'id item) known-ids))
                             (not (eq (alist-get 'completed item) t)))
                    (org-apple-reminders--goto-list-heading lname)
                    (push (point-marker) changed-positions)
                    (org-apple-reminders--insert-org-heading item lname)
                    (setq n-pulled (1+ n-pulled))))))))
        (org-map-entries
         (lambda ()
           (when-let (id (org-entry-get nil "REMINDER_ID"))
             (let* ((a (gethash id apple-by-id))
                    (m (when a (alist-get 'modDate a))))
               (when (stringp m)
                 (org-set-property "REMINDER_APPLE_MOD" m)))))
         nil nil)
        (org-map-entries
         (lambda ()
           (unless (save-excursion (beginning-of-line)
                                   (looking-at "[^\n]*\\[[0-9]*/[0-9]*\\]"))
             (end-of-line) (insert " [/]"))
           (org-update-statistics-cookies nil))
         "LEVEL=1" nil)
        (save-buffer)
        (dolist (m (nreverse changed-positions))
          (when (marker-position m)
            (goto-char m)
            (org-reveal)
            (set-marker m nil)))))
        ))
    (message "Reminders: %d←DONE  %d↑reopened  %d→Apple  %d←Apple  %d updated"
             n-done n-reopened n-pushed n-pulled n-updated)))

;;; Background pull (Apple → org, async)

(defun org-apple-reminders--background-pull ()
  "Async pull: refresh cache and reminders.org from Apple Reminders."
  (unless org-apple-reminders--syncing
    (org-apple-reminders--jxa-async
     org-apple-reminders--fetch-script
     (lambda (raw)
       (condition-case nil
           (let* ((data (json-parse-string raw :object-type 'alist :array-type 'list))
                  (file (expand-file-name org-apple-reminders-sync-file))
                  (apple-by-id (let ((ht (make-hash-table :test #'equal)))
                                  (dolist (entry data)
                                    (dolist (item (alist-get 'items entry))
                                      (puthash (alist-get 'id item) item ht)))
                                  ht)))
             (setq org-apple-reminders--cache data)
             (org-apple-reminders--write-agenda-file data)
             (when (file-exists-p file)
               (let ((org-apple-reminders--syncing t))
                 (with-current-buffer (find-file-noselect file)
                   (org-save-outline-visibility t
                   (let (done-pts reopen-pts)
                     (org-map-entries
                      (lambda ()
                        (let* ((id    (org-entry-get nil "REMINDER_ID"))
                               (state (org-get-todo-state)))
                          (when id
                            (cond
                             ((and (member state '("TODO" "NEXT" "WAITING"))
                                   (let ((a (gethash id apple-by-id)))
                                     (or (null a) (eq (alist-get 'completed a) t))))
                              (push (point-marker) done-pts))
                             ((and (member state '("DONE" "CANCELLED"))
                                   (let ((a (gethash id apple-by-id)))
                                     (and a (not (eq (alist-get 'completed a) t)))))
                              (push (point-marker) reopen-pts))))))
                      nil nil)
                     (dolist (m (nreverse done-pts))
                       (goto-char m)
                       (org-todo "DONE")
                       (set-marker m nil))
                     (dolist (m (nreverse reopen-pts))
                       (goto-char m)
                       (org-todo "TODO")
                       (set-marker m nil)))
                   (let (field-updates)
                     (org-map-entries
                      (lambda ()
                        (let* ((id     (org-entry-get nil "REMINDER_ID"))
                               (aitem  (when id (gethash id apple-by-id))))
                          (when (and id aitem
                                     (not (eq (alist-get 'completed aitem) t))
                                     (member (org-get-todo-state) '("TODO" "NEXT" "WAITING")))
                            (let* ((a-prio      (or (alist-get 'priority aitem) 0))
                                   (a-due       (let ((d (alist-get 'due aitem)))
                                                  (and (stringp d) (not (string-empty-p d)) d)))
                                   (a-flagged   (eq (alist-get 'flagged aitem) t))
                                   (a-mod       (let ((m (alist-get 'modDate aitem)))
                                                  (and (stringp m) (not (string-empty-p m)) m)))
                                   (p-char      (nth 3 (org-heading-components)))
                                   (o-prio      (cond ((eql p-char ?A) 1)
                                                      ((eql p-char ?B) 5)
                                                      ((eql p-char ?C) 9)
                                                      (t 0)))
                                   (o-due       (let ((dl (org-entry-get nil "DEADLINE")))
                                                  (when (and dl (string-match
                                                                "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" dl))
                                                    (match-string 1 dl))))
                                   (o-flagged   (not (null (member "flagged" (org-get-tags nil t)))))
                                   (changed     (or (/= a-prio o-prio)
                                                    (not (equal a-due o-due))
                                                    (not (eq a-flagged o-flagged))))
                                   (last-known  (org-apple-reminders--last-known-mod))
                                   (apple-changed (and a-mod
                                                       (or (null last-known)
                                                           (string> a-mod last-known)))))
                              (when (and changed apple-changed)
                                (push (list (point-marker)
                                            a-prio o-prio a-due o-due a-flagged o-flagged a-mod)
                                      field-updates))))))
                      nil nil)
                     (dolist (upd (nreverse field-updates))
                       (cl-destructuring-bind (m a-prio o-prio a-due o-due a-flagged o-flagged a-mod) upd
                         (goto-char m)
                         (unless (= a-prio o-prio)
                           (org-priority (cond ((= a-prio 1) ?A)
                                               ((= a-prio 5) ?B)
                                               ((= a-prio 9) ?C)
                                               (t 'remove))))
                         (unless (equal a-due o-due)
                           (if a-due
                               (org-add-planning-info 'deadline (org-apple-reminders--format-due a-due))
                             (org-add-planning-info nil nil 'deadline)))
                         (unless (eq a-flagged o-flagged)
                           (org-toggle-tag "flagged" (if a-flagged 'on 'off)))
                         (when (stringp a-mod)
                           (org-set-property "REMINDER_APPLE_MOD" a-mod))
                         (set-marker m nil))))
                   (let ((known-ids (let (ids)
                                      (org-map-entries
                                       (lambda () (when-let (id (org-entry-get nil "REMINDER_ID"))
                                                    (push id ids)))
                                       nil nil)
                                      (dolist (buf (buffer-list))
                                        (with-current-buffer buf
                                          (when (and (derived-mode-p 'org-mode)
                                                     (buffer-file-name)
                                                     (not (string= (expand-file-name (buffer-file-name))
                                                                   (expand-file-name org-apple-reminders-sync-file))))
                                            (ignore-errors
                                              (org-map-entries
                                               (lambda () (when-let (id (org-entry-get nil "REMINDER_ID"))
                                                            (push id ids)))
                                               nil nil)))))
                                      ids)))
                     (dolist (entry data)
                       (let ((lname (alist-get 'list  entry))
                             (items (alist-get 'items entry)))
                         (when (org-apple-reminders--list-included-p lname)
                           (dolist (item items)
                             (when (and (not (member (alist-get 'id item) known-ids))
                                        (not (eq (alist-get 'completed item) t)))
                               (org-apple-reminders--goto-list-heading lname)
                               (org-apple-reminders--insert-org-heading item lname)
                               (save-excursion
                                 (org-back-to-heading t)
                                 (let ((md (alist-get 'modDate item)))
                                   (when (stringp md)
                                     (org-set-property "REMINDER_APPLE_MOD" md)))))))))
                   (org-map-entries
                    (lambda ()
                      (when-let (id (org-entry-get nil "REMINDER_ID"))
                        (let* ((a  (gethash id apple-by-id))
                               (md (when a (alist-get 'modDate a))))
                          (when (stringp md)
                            (org-set-property "REMINDER_APPLE_MOD" md)))))
                    nil nil)
                   (org-map-entries
                    (lambda ()
                      (unless (save-excursion (beginning-of-line)
                                              (looking-at "[^\n]*\\[[0-9]*/[0-9]*\\]"))
                        (end-of-line) (insert " [/]"))
                      (org-update-statistics-cookies nil))
                    "LEVEL=1" nil)
                   (save-buffer)
                   (dolist (buf (buffer-list))
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (when (derived-mode-p 'org-agenda-mode)
                           (let ((inhibit-message t))
                             (ignore-errors (org-agenda-redo)))))))))))))
         (error nil))))))

;;; Timer

(defun org-apple-reminders--start-sync-timer ()
  "Start the periodic background pull timer if not already running."
  (when (and (> org-apple-reminders-auto-sync-interval 0)
             (null org-apple-reminders--sync-timer))
    (setq org-apple-reminders--sync-timer
          (run-with-timer org-apple-reminders-auto-sync-interval
                          org-apple-reminders-auto-sync-interval
                          #'org-apple-reminders--background-pull))))

;;; Helpers

(defun org-apple-reminders--loc-at-point ()
  "Return (list-name . reminder-id) for reminder heading at point, or nil."
  (ignore-errors
    (save-excursion
      (org-back-to-heading t)
      (let ((id   (org-entry-get nil "REMINDER_ID"))
            (list (org-entry-get nil "REMINDER_LIST")))
        (when (and id list) (cons list id))))))


(defun org-apple-reminders--write-agenda-file (data)
  "Write open reminders from DATA to `org-apple-reminders-agenda-file'."
  (when org-apple-reminders-agenda-file
    (let ((file (expand-file-name org-apple-reminders-agenda-file)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert "#+TITLE: Apple Reminders (auto-generated — do not edit)\n")
        (insert "#+STARTUP: overview\n")
        (insert "#+TODO: TODO | DONE\n\n")
        (dolist (entry data)
          (let ((lname (alist-get 'list  entry))
                (items (alist-get 'items entry)))
            (dolist (item items)
              (let* ((title   (alist-get 'title    item))
                     (due     (alist-get 'due      item))
                     (prio    (alist-get 'priority item))
                     (flagged (alist-get 'flagged  item))
                     (id      (alist-get 'id       item)))
                (insert (format "* TODO %s%s%s\n"
                                (org-apple-reminders--prio-label prio)
                                (if (eq flagged t) "★ " "")
                                title))
                (when (and due (not (eq due :null)))
                  (insert (format "  DEADLINE: <%s>\n" due)))
                (insert (format "  :PROPERTIES:\n  :REMINDER_LIST: %s\n  :REMINDER_ID: %s\n  :END:\n"
                                lname id)))))))
      (add-to-list 'org-agenda-files file))))


;;; Save hook

(defun org-apple-reminders--on-save ()
  "When reminders.org is saved, push changes to Apple Reminders."
  (when (and (buffer-file-name)
             (not org-apple-reminders--syncing)
             (string= (expand-file-name (buffer-file-name))
                      (expand-file-name org-apple-reminders-sync-file)))
    (let ((org-apple-reminders--syncing t)
          (buf (current-buffer)))
      (org-apple-reminders--push-to-apple)
      (when (buffer-modified-p) (save-buffer))
      ;; Async update callbacks stamp REMINDER_ORG_MOD after this save returns.
      ;; Schedule a follow-up save so those changes are persisted to disk.
      (run-with-idle-timer
       2 nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (when (and (buffer-modified-p)
                        (not org-apple-reminders--syncing))
               (let ((org-apple-reminders--syncing t))
                 (save-buffer))))))))))

(add-hook 'after-save-hook #'org-apple-reminders--on-save)

;;; Org-capture integration

(defun org-apple-reminders--setup-capture ()
  "Add Apple Reminders capture template (key \"A\")."
  (add-to-list 'org-capture-templates
               `("A" "Apple Reminder" entry
                 (file+headline ,(expand-file-name org-apple-reminders-sync-file)
                                ,(or (org-apple-reminders--default-list) "Reminders"))
                 ,(concat "** TODO %?\n"
                          "   :PROPERTIES:\n"
                          "   :REMINDER_LIST: " (or (org-apple-reminders--default-list) "") "\n"
                          "   :END:\n")
                 :empty-lines 1)))

;;; Org-agenda integration

(defun org-apple-reminders--ensure-agenda-files ()
  "Register reminders.org in org-agenda-files and add a custom agenda command."
  (let* ((sync-file (expand-file-name org-apple-reminders-sync-file))
         (extra     (and org-apple-reminders-agenda-file
                         (expand-file-name org-apple-reminders-agenda-file)))
         (all-files (delq nil (list sync-file extra))))
    (unless (file-exists-p sync-file)
      (condition-case nil
          (progn
            (make-directory (file-name-directory sync-file) t)
            (with-temp-file sync-file
              (insert "#+TITLE: Reminders\n#+STARTUP: overview\n#+TODO: TODO NEXT WAITING | DONE CANCELLED\n\n")))
        (error nil)))
    (when (file-exists-p sync-file)
      (add-to-list 'org-agenda-files sync-file))
    (when (and extra (file-exists-p extra))
      (add-to-list 'org-agenda-files extra))
    (add-to-list 'org-agenda-custom-commands
                 `("A" "Apple Reminders" todo "TODO"
                   ((org-agenda-files
                     (cl-remove-if-not #'file-exists-p ',all-files))
                    (org-agenda-overriding-header "Apple Reminders"))))))

;;; Migration helper

(defun org-apple-reminders-migrate-flat-headings ()
  "One-time migration: move flat * TODO reminder entries under * ListName headings.
Run once after upgrading from a version that stored items at level 1."
  (interactive)
  (let* ((file (expand-file-name org-apple-reminders-sync-file))
         (buf  (find-file-noselect file))
         moves)
    (with-current-buffer buf
      (org-map-entries
       (lambda ()
         (when (and (= (org-current-level) 1)
                    (org-entry-get nil "REMINDER_LIST"))
           (let* ((beg   (point))
                  (end   (save-excursion (org-end-of-subtree t t) (point)))
                  (lname (org-entry-get nil "REMINDER_LIST"))
                  (text  (buffer-substring-no-properties beg end)))
             (push (list (copy-marker beg) (copy-marker end) lname text) moves))))
       nil nil)
      (dolist (m (sort (copy-sequence moves)
                       (lambda (a b) (> (marker-position (car a))
                                        (marker-position (car b))))))
        (delete-region (nth 0 m) (nth 1 m))
        (set-marker (nth 0 m) nil)
        (set-marker (nth 1 m) nil))
      (dolist (m (nreverse moves))
        (let* ((lname (nth 2 m))
               (text  (with-temp-buffer
                        (insert (nth 3 m))
                        (goto-char (point-min))
                        (while (re-search-forward "^\\*+" nil t)
                          (replace-match (concat (match-string 0) "*")))
                        (buffer-string))))
          (org-apple-reminders--goto-list-heading lname)
          (unless (bolp) (insert "\n"))
          (insert text)))
      (save-buffer))
    (message "Migrated %d entries under list headings." (length moves))))

;;; Setup entry point

;;;###autoload
(defun org-apple-reminders-setup ()
  "Activate org-apple-reminders: start background timer, set up capture and agenda.

Call this once from your init file after setting
`org-apple-reminders-sync-file' (and optionally
`org-apple-reminders-auto-sync-interval').

Suggested key bindings (add to your init file):

  (global-set-key (kbd \"C-c r R\") #\\='org-apple-reminders-sync)
  (global-set-key (kbd \"C-c r f\") #\\='org-apple-reminders-open-file)
  (global-set-key (kbd \"C-c r a\") #\\='org-apple-reminders-add)
  (global-set-key (kbd \"C-c r l\") #\\='org-apple-reminders-show-lists)
  (global-set-key (kbd \"C-c r L\") #\\='org-apple-reminders-create-list)
  ;; In org-mode buffers:
  (with-eval-after-load 'org
    (define-key org-mode-map (kbd \"C-c r p\") #\\='org-apple-reminders-push-heading)
    (define-key org-mode-map (kbd \"C-c r D\") #\\='org-apple-reminders-delete-reminder))"
  (org-apple-reminders--ensure-agenda-files)
  (with-eval-after-load 'org-agenda
    (org-apple-reminders--ensure-agenda-files))
  (add-hook 'org-agenda-mode-hook #'org-apple-reminders--ensure-agenda-files)
  (if (featurep 'org-capture)
      (org-apple-reminders--setup-capture)
    (with-eval-after-load 'org-capture (org-apple-reminders--setup-capture)))
  (org-apple-reminders--start-sync-timer)
  (run-with-idle-timer 3 nil #'org-apple-reminders--background-pull))

(provide 'org-apple-reminders)

;;; org-apple-reminders.el ends here
