;;; org-apple-reminders.el --- Bidirectional org-mode ↔ Apple Reminders sync via JXA  -*- lexical-binding: t -*-

;; Copyright (C) 2025 Denis Butic

;; Author: Denis Butic <d.e.n.o@gmx.net>
;; Assisted-by: Claude:claude-opus-4-8
;; Version: 1.15
;; Package-Requires: ((emacs "27.1") (org "9.3"))
;; Keywords: org, outlines, apple, reminders, tools, macos
;; URL: https://github.com/deno1011/org-apple-reminders
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; org-apple-reminders provides bidirectional sync between an Org-mode file
;; and macOS Apple Reminders, using JavaScript for Automation (JXA) via
;; osascript.  No third-party CLI tools are required.
;;
;; See the README for features, requirements and quick start.  The source is
;; organised as a layered stack (L1 config → L6 business logic); see the
;; Architecture section of the literate .org for the layer rule.

;;; Code:

;; Forward declarations for the byte-compiler.  These functions and
;; variables come from libraries listed in `Package-Requires' (org-agenda
;; and org-capture ship with org) and are loaded lazily by
;; `org-apple-reminders-setup'; `org-state' is the dynamic variable bound
;; by `org-after-todo-state-change-hook'.
(declare-function org-agenda-redo "org-agenda" (&optional all))
(defvar org-state)
(defvar org-capture-templates)
(defvar org-agenda-custom-commands)
(defvar org-agenda-finalize-hook)

(require 'cl-lib)
(require 'org)
(require 'json)

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
  "Separate auto-generated org file for `org-agenda' integration.
nil (default) means use `org-apple-reminders-sync-file' for the agenda.
Set to a file path only if you want a separate read-only agenda file."
  :type '(choice (const :tag "Use sync file (default)" nil) file)
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-included-lists nil
  "Apple Reminders lists to include in bidirectional sync.
nil (the default) means all lists are synced.
Set to a list of list-name strings to limit sync to those lists only:

  (setq org-apple-reminders-included-lists \\='(\"Work\" \"Personal\"))

This is the *config-declared* value.  The interactive command
`org-apple-reminders-set-included-lists' saves its choice separately in
`org-apple-reminders-saved-included-lists' instead; which of the two is
live is decided by `org-apple-reminders-included-lists-prefer-config'.

Items already present in the org file are always kept in sync regardless
of this setting; the filter only prevents NEW Apple items from being
pulled into lists that are not included."
  :type '(choice (const  :tag "All lists" nil)
                 (repeat :tag "Specific lists" string))
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-included-lists-prefer-config nil
  "Whether the config-declared included-lists value is authoritative.
When non-nil, `org-apple-reminders-included-lists' always wins and the
value saved by `org-apple-reminders-set-included-lists' is ignored.
When nil (the default), the saved value wins once it exists, falling
back to the config value otherwise.  The choice is explicit, so it does
not depend on Emacs file-load order."
  :type 'boolean
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-saved-included-lists 'unset
  "Included-lists value saved by `org-apple-reminders-set-included-lists'.
Persisted to `custom-file'.  The sentinel `unset' means the command has
never run; nil means \"all lists\"; a list of strings means those lists.
Do not edit by hand — use `org-apple-reminders-set-included-lists'."
  :type '(choice (const :tag "Never saved" unset)
                 (const :tag "All lists" nil)
                 (repeat :tag "Specific lists" string))
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-extra-files nil
  "Additional org files scanned for linked Apple Reminders headings.
These files may contain REMINDER_ID headings alongside arbitrary content
\(Babel blocks, LaTeX, prose, etc.).  Together with `org-agenda-files'
they form the full search space for existing reminder links.

New Apple items that are not linked in any known file are pulled into
`org-apple-reminders-sync-file' only.  Extra files are not extended with
new headings by Apple -> org pulls and their outline structure does not create
Apple lists.  Headings in these files sync only when already linked or when
they carry an explicit REMINDER_LIST, such as after
`org-apple-reminders-push-heading'."
  :type '(repeat file)
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-keymap-prefix "C-c r"
  "Prefix key sequence for `org-apple-reminders-command-map'.
`org-apple-reminders-setup' binds the command map under this prefix.
Set to nil to bind no prefix and wire up the keymap yourself, e.g.:

  (keymap-global-set \"C-c a\" org-apple-reminders-command-map)"
  :type '(choice (key-sequence :tag "Prefix key")
                 (const :tag "Do not bind" nil))
  :group 'org-apple-reminders)

(defcustom org-apple-reminders-delete-mark-prefix "[DELETE FROM APPLE] "
  "Visible prefix shown for headings marked REMINDER_DELETE=t.
The prefix is display-only: it is not written into the org heading, does
not create an org tag, and does not affect TODO/GTD state.  The
REMINDER_DELETE property remains the source of truth for batch deletion."
  :type 'string
  :group 'org-apple-reminders)

(defface org-apple-reminders-delete-mark-face
  '((t :inherit warning :weight bold))
  "Face applied to headings and agenda lines marked for Apple deletion."
  :group 'org-apple-reminders)

(defface org-apple-reminders-delete-mark-prefix-face
  '((t :inherit error :weight bold))
  "Face used for the display-only delete-mark prefix."
  :group 'org-apple-reminders)


(defvar org-apple-reminders--syncing nil
  "Non-nil while a sync is in progress; prevents recursive save-hook calls.")

(defvar org-apple-reminders--cache nil
  "Last fetched Reminders data; used by push logic to detect changed fields.")

(defvar org-apple-reminders--sync-timer nil
  "Timer handle for periodic background pulls.")

(defconst org-apple-reminders--sync-file-template
  "#+TITLE: Reminders\n#+STARTUP: overview\n#+TODO: TODO NEXT WAITING | DONE CANCELLED\n\n"
  "Preamble written when the sync file is created on demand.")

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

(defconst org-apple-reminders--fetch-script
  "var app=Application('Reminders'),out=[];
app.lists().forEach(function(l){
  var lid=null;
  try{lid=String(l.id());}catch(e){}
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
  out.push({list:l.name(),listId:lid,items:items});
});
JSON.stringify(out);"
  "JXA script returning all Reminders as JSON.
Uses batch property fetch for speed.")

;; -- Clearing a dueDate ------------------------------------------------------
;;
;; JXA's `r.dueDate = null' raises -1700 "Types cannot be converted" and
;; AppleScript's `set due date to missing value' fails similarly.  The only
;; reachable clear-date path is EventKit's `dueDateComponents = nil' (which
;; in JXA is `$()' — the ObjC nil marker).  This requires only the legacy
;; Reminders access (write-only on macOS 14+, which is what we need here),
;; so no signed helper or Full Disk Access is required.

(defconst org-apple-reminders--clear-due-template
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false;
var result={};
var doClear=function(){
  var r=store.calendarItemWithIdentifier(%s);
  if(!r){done=true;return;}
  try{
    r.dueDateComponents=$();
    var err=Ref();
    if(store.saveReminderCommitError(r,true,err)){
      var m=r.lastModifiedDate;
      result.modDate=(m&&m.isKindOfClass($.NSDate))?ObjC.unwrap(m.descriptionWithLocale($())):null;
      result.ok=true;
    }
  }catch(e){result.err=String(e);}
  done=true;
};
store.requestAccessToEntityTypeCompletion($.EKEntityTypeReminder,function(g){
  if(g){doClear();}else{done=true;}
});
var iter=0;
while(!done&&iter<100){
  $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
  iter++;
}
JSON.stringify(result);"
  "EventKit-via-JXA template for clearing a reminder's dueDate.
One `%s' placeholder: JSON-encoded raw reminder UUID (without the
`x-apple-reminder://' prefix — EventKit's
`calendarItemWithIdentifier:' wants the bare UUID).  Returns a JSON
object with `ok' (boolean) and optionally `modDate' (ISO-ish date
string from EventKit) or `err' on failure.")

(defun org-apple-reminders--strip-id-prefix (id)
  "Strip the `x-apple-reminder://' prefix from ID if present."
  (if (and (stringp id) (string-prefix-p "x-apple-reminder://" id))
      (substring id (length "x-apple-reminder://"))
    id))

(defun org-apple-reminders--clear-due-in-apple (id)
  "Clear the dueDate on Apple reminder ID via EventKit.
Returns Apple's new modificationDate as an ISO-8601 UTC string on
success, or nil on failure.  Falls back to fetching modDate via JXA
since EventKit's `lastModifiedDate' formatting is locale-dependent."
  (let* ((bare-id (org-apple-reminders--strip-id-prefix id))
         (script  (format org-apple-reminders--clear-due-template
                          (json-encode bare-id))))
    (condition-case nil
        (let ((parsed (json-parse-string
                       (org-apple-reminders--jxa-run script)
                       :object-type 'alist :null-object nil)))
          (when (alist-get 'ok parsed)
            ;; Pull a fresh ISO modDate via JXA since the EventKit one was
            ;; locale-dependent (its description format varies by user
            ;; locale).  JXA's modificationDate.toISOString() is stable.
            (let* ((mod-script
                    (format "var r=Application('Reminders').reminders.byId(%s);var m=r.modificationDate();JSON.stringify((m&&m instanceof Date)?m.toISOString():null);"
                            (json-encode id))))
              (condition-case nil
                  (json-parse-string (org-apple-reminders--jxa-run mod-script))
                (error nil)))))
      (error nil))))

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

(defun org-apple-reminders--delete-list-in-apple (list-name &optional callback)
  "Delete Apple Reminders list LIST-NAME asynchronously."
  (org-apple-reminders--jxa-async
   (format "Application('Reminders').lists.byName(%s).delete();"
           (json-encode list-name))
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
Without CALLBACK: synchronous; returns Apple's modificationDate after the
push, or nil.
With CALLBACK: async; CALLBACK receives the modificationDate string.
A nil/empty `due' in VALS clears Apple's dueDate via EventKit (see
`org-apple-reminders--clear-due-in-apple') since JXA's `r.dueDate=null'
errors with -1700."
  (let* ((title      (alist-get 'title    vals ""))
         (notes      (alist-get 'notes    vals ""))
         (prio       (alist-get 'priority vals 0))
         (due        (alist-get 'due      vals))
         (flagged    (alist-get 'flagged  vals))
         (clear-due  (or (null due) (and (stringp due) (string-empty-p due))))
         ;; When clearing, omit any due-line from the JXA script entirely —
         ;; EventKit handles the clear in a second step.
         (due-line   (if clear-due ""
                       (format "r.dueDate=new Date(%s);"
                               (json-encode (concat due (if (string-match "T" due)
                                                            ":00" "T00:00:00"))))))
         (script
          (format
           "var r=Application('Reminders').lists.byName(%s).reminders.byId(%s);
r.name=%s;r.body=%s;r.priority=%d;r.flagged=%s;%s
var md=r.modificationDate();JSON.stringify((md&&md instanceof Date)?md.toISOString():null);"
           (json-encode list-name) (json-encode id)
           (json-encode title) (json-encode notes) prio
           (if flagged "true" "false")
           due-line))
         ;; When clearing, do EventKit clear FIRST.  If we clear after the
         ;; JXA write, EventKit's `calendarItemWithIdentifier:' holds a
         ;; stale snapshot whose save races with the JXA-bumped modDate
         ;; and ends up leaving the original dueDate in place.  Clearing
         ;; first means JXA's subsequent write doesn't touch dueDate
         ;; (`due-line' is empty), so the cleared state survives.
         )
    (when clear-due
      (org-apple-reminders--clear-due-in-apple id))
    (if callback
        (org-apple-reminders--jxa-async
         script
         (lambda (raw)
           (funcall callback
                    (condition-case nil (json-parse-string raw) (error nil)))))
      (condition-case nil
          (json-parse-string (org-apple-reminders--jxa-run script))
        (error nil)))))

(defun org-apple-reminders--ensure-list (list-name)
  "Ensure an Apple Reminders list named LIST-NAME exists, creating it if absent.
Return parsed list metadata on success."
  (let ((script
         (format "var app=Application('Reminders'),name=%s;
if(app.lists.name().indexOf(name)<0){app.lists.push(app.List({name:name}));}
var l=app.lists.byName(name),lid=null;
try{lid=String(l.id());}catch(e){}
JSON.stringify({ok:true,list:name,listId:lid});"
                 (json-encode list-name))))
    (condition-case nil
        (json-parse-string (org-apple-reminders--jxa-run script)
                           :object-type 'alist :null-object nil)
      (error nil))))

(defun org-apple-reminders-lists ()
  "Return a list of Apple Reminders list names."
  (let ((raw (org-apple-reminders--jxa-run
              "JSON.stringify(Application('Reminders').lists.name())")))
    (condition-case nil
        (append (json-parse-string raw :array-type 'vector) nil)
      (error nil))))

(cl-defstruct (org-apple-reminders--counts
               (:constructor org-apple-reminders--counts-create))
  (deleted 0) (done 0) (lists-done 0)
  (pushed 0) (pulled 0) (updated 0) (pruned 0))

(defun org-apple-reminders--report-counts (counts)
  "Echo the per-category tally in COUNTS for a finished sync run."
  (message
   "Reminders: %d deleted  %d←DONE  %d lists→DONE  %d→Apple  %d←Apple  %d updated  %d pruned"
   (org-apple-reminders--counts-deleted counts)
   (org-apple-reminders--counts-done counts)
   (org-apple-reminders--counts-lists-done counts)
   (org-apple-reminders--counts-pushed counts)
   (org-apple-reminders--counts-pulled counts)
   (org-apple-reminders--counts-updated counts)
   (org-apple-reminders--counts-pruned counts)))

(cl-defstruct (org-apple-reminders--snapshot
               (:constructor org-apple-reminders--make-snapshot)
               (:copier nil))
  data by-id list-names list-ids id-index previous-lists)

;; -- list filter --

(defun org-apple-reminders--effective-included-lists ()
  "Return the included-lists value currently in effect.
Picks between the config value and the saved value according to
`org-apple-reminders-included-lists-prefer-config'.  nil means all
lists are included."
  (if (or org-apple-reminders-included-lists-prefer-config
          (eq org-apple-reminders-saved-included-lists 'unset))
      org-apple-reminders-included-lists
    org-apple-reminders-saved-included-lists))

(defun org-apple-reminders--list-included-p (list-name)
  "Return non-nil if LIST-NAME should participate in sync.
Always true when the effective included-lists value is nil."
  (let ((lists (org-apple-reminders--effective-included-lists)))
    (or (null lists) (member list-name lists))))

;; -- list-name model --

(defun org-apple-reminders--cached-list-names ()
  "Return list names from the in-memory cache, or nil if cache is empty."
  (when org-apple-reminders--cache
    (mapcar (lambda (entry) (alist-get 'list entry))
            org-apple-reminders--cache)))

(defun org-apple-reminders--default-list ()
  "Return `org-apple-reminders-default-list', auto-detecting if nil."
  (or org-apple-reminders-default-list
      (car (or (org-apple-reminders--cached-list-names)
               (ignore-errors (org-apple-reminders-lists))))))

;; -- pure Apple-data accessors --

(defun org-apple-reminders--list-info-id (info)
  "Return the list id from parsed Apple list INFO, or nil."
  (and (listp info)
       (let ((id (alist-get 'listId info)))
         (and (stringp id) (not (string-empty-p id)) id))))

;; -- org<->Apple field mapping (some read/write the entry at point) --

(defun org-apple-reminders--extract-notes ()
  "Extract body text from org heading at point.
Strips LOGBOOK drawers and per-line leading whitespace."
  (save-excursion
    (org-back-to-heading t)
    (let* ((start (save-excursion (org-end-of-meta-data t) (point)))
           (end   (save-excursion (org-end-of-subtree t) (point)))
           (raw   (buffer-substring-no-properties start end))
           (no-logbook (string-trim
                        (replace-regexp-in-string
                         ":LOGBOOK:\\(?:.\\|\n\\)*?:END:\n?" "" raw))))
      (if (string-empty-p no-logbook)
          ""
        (string-join
         (mapcar (lambda (line)
                   (replace-regexp-in-string "^[[:space:]]+" "" line))
                 (split-string no-logbook "\n"))
         "\n")))))

(defun org-apple-reminders--set-org-notes (notes)
  "Replace body text of the org entry at point with NOTES string."
  (save-excursion
    (org-back-to-heading t)
    (let ((start (save-excursion (org-end-of-meta-data t) (point)))
          (end   (save-excursion (org-end-of-subtree t) (point))))
      (delete-region start end)
      (goto-char start)
      (unless (or (null notes) (string-empty-p notes))
        (dolist (line (split-string notes "\n"))
          (insert (format "   %s\n" line)))))))

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


;; -- conflict resolution --

(defun org-apple-reminders--nonempty-string (value)
  "Return VALUE when it is a non-empty string, otherwise nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun org-apple-reminders--todo-open-p (state)
  "Return non-nil when TODO STATE is an active reminder state."
  (member state '("TODO" "NEXT" "WAITING")))

(defun org-apple-reminders--active-heading-state-p (state)
  "Return non-nil when TODO STATE represents an open reminder heading.
Plain headings with no TODO keyword are active reminders in contexts that
explicitly allow reminder creation."
  (or (null state)
      (org-apple-reminders--todo-open-p state)))

(defun org-apple-reminders--todo-done-p (state)
  "Return non-nil when TODO STATE is a terminal reminder state."
  (equal state "DONE"))

(defun org-apple-reminders--todo-cancelled-p (state)
  "Return non-nil when TODO STATE requests destructive reminder deletion."
  (equal state "CANCELLED"))

(defun org-apple-reminders--apple-item-mod-date (item)
  "Return ITEM's Apple modification date, or nil when missing."
  (org-apple-reminders--nonempty-string (alist-get 'modDate item)))

(defun org-apple-reminders--apple-item-due (item)
  "Return ITEM's Apple due value, or nil when missing."
  (org-apple-reminders--nonempty-string (alist-get 'due item)))

(defun org-apple-reminders--apple-item-completed-p (item)
  "Return non-nil when Apple ITEM is completed."
  (eq (alist-get 'completed item) t))

(defun org-apple-reminders--apple-list-names (data)
  "Return Apple list names from fetched DATA."
  (mapcar (lambda (entry) (alist-get 'list entry)) data))

(defun org-apple-reminders--apple-list-ids (data)
  "Return non-nil Apple list ids from fetched DATA."
  (delq nil
        (mapcar (lambda (entry)
                  (org-apple-reminders--list-info-id entry))
                data)))

(defun org-apple-reminders--apple-items-by-id (data)
  "Return hash table mapping reminder ids to Apple items in DATA."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry data)
      (dolist (item (alist-get 'items entry))
        (puthash (alist-get 'id item) item table)))
    table))

(defun org-apple-reminders--org-priority-value ()
  "Return the Apple priority value represented by the org heading at point."
  (pcase (nth 3 (org-heading-components))
    (?A 1)
    (?B 5)
    (?C 9)
    (_ 0)))

(defun org-apple-reminders--org-deadline-value ()
  "Return the date portion of the org DEADLINE at point, or nil."
  (when-let ((deadline (org-entry-get nil "DEADLINE")))
    (when (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" deadline)
      (match-string 1 deadline))))

(defun org-apple-reminders--org-title-value ()
  "Return the reminder title represented by the org heading at point."
  (replace-regexp-in-string "^★ " "" (org-get-heading t t t t)))

(defun org-apple-reminders--org-flagged-p ()
  "Return non-nil when the org heading at point is tagged flagged."
  (not (null (member "flagged" (org-get-tags nil t)))))

(defun org-apple-reminders--current-org-field-values ()
  "Return tracked org field values for the heading at point."
  `((title . ,(org-apple-reminders--org-title-value))
    (due . ,(org-apple-reminders--org-deadline-value))
    (priority . ,(org-apple-reminders--org-priority-value))
    (flagged . ,(org-apple-reminders--org-flagged-p))
    (notes . ,(org-apple-reminders--extract-notes))))

(defun org-apple-reminders--apple-field-values (item)
  "Return tracked Apple field values from ITEM."
  `((title . ,(or (alist-get 'title item) ""))
    (due . ,(org-apple-reminders--apple-item-due item))
    (priority . ,(or (alist-get 'priority item) 0))
    (flagged . ,(eq (alist-get 'flagged item) t))
    (notes . ,(or (alist-get 'notes item) ""))
    (mod-date . ,(org-apple-reminders--apple-item-mod-date item))))

(defun org-apple-reminders--field-values-differ-p (apple-values org-values)
  "Return non-nil when APPLE-VALUES and ORG-VALUES disagree."
  (or (not (equal (alist-get 'title apple-values)
                  (alist-get 'title org-values)))
      (not (equal (alist-get 'due apple-values)
                  (alist-get 'due org-values)))
      (not (= (alist-get 'priority apple-values)
              (alist-get 'priority org-values)))
      (not (eq (alist-get 'flagged apple-values)
               (alist-get 'flagged org-values)))
      (not (equal (alist-get 'notes apple-values)
                  (alist-get 'notes org-values)))))

(defun org-apple-reminders--org-push-needed-p (org-values apple-values include-empty)
  "Return non-nil when ORG-VALUES should be pushed over APPLE-VALUES.
When INCLUDE-EMPTY is non-nil, nil and empty org values are meaningful and
clear Apple fields.  Otherwise only non-empty org due/notes/priority values
are allowed to overwrite Apple; title and flagged state still remain explicit."
  (let ((org-title (or (alist-get 'title org-values) ""))
        (org-notes (alist-get 'notes org-values))
        (org-prio  (or (alist-get 'priority org-values) 0))
        (org-due   (alist-get 'due org-values))
        (org-flag  (alist-get 'flagged org-values))
        (apple-title (or (alist-get 'title apple-values) ""))
        (apple-notes (or (alist-get 'notes apple-values) ""))
        (apple-prio  (or (alist-get 'priority apple-values) 0))
        (apple-due   (alist-get 'due apple-values))
        (apple-flag  (alist-get 'flagged apple-values)))
    (or (not (equal org-title apple-title))
        (if include-empty
            (not (equal (or org-notes "") apple-notes))
          (and org-notes
               (not (string-empty-p org-notes))
               (not (equal org-notes apple-notes))))
        (if include-empty
            (not (= org-prio apple-prio))
          (and (> org-prio 0) (not (= org-prio apple-prio))))
        (if include-empty
            (not (equal org-due apple-due))
          (and org-due (not (equal org-due apple-due))))
        (not (eq org-flag apple-flag)))))

(defun org-apple-reminders--apply-apple-field-values (apple-values)
  "Apply APPLE-VALUES to the org heading at point."
  (let ((apple-title (alist-get 'title apple-values))
        (apple-prio  (alist-get 'priority apple-values))
        (apple-due   (alist-get 'due apple-values))
        (apple-flag  (alist-get 'flagged apple-values))
        (apple-notes (alist-get 'notes apple-values))
        (apple-mod   (alist-get 'mod-date apple-values))
        (org-values  (org-apple-reminders--current-org-field-values)))
    (unless (equal apple-title (alist-get 'title org-values))
      (org-back-to-heading t)
      (when (looking-at org-complex-heading-regexp)
        (let ((beg (match-beginning 4))
              (end (match-end 4)))
          (when beg
            (delete-region beg end)
            (goto-char beg)
            (insert apple-title)))))
    (unless (= apple-prio (alist-get 'priority org-values))
      (org-priority (cond ((= apple-prio 1) ?A)
                          ((= apple-prio 5) ?B)
                          ((= apple-prio 9) ?C)
                          (t 'remove))))
    (unless (equal apple-due (alist-get 'due org-values))
      (if apple-due
          (org-add-planning-info 'deadline
                                 (org-apple-reminders--format-due apple-due))
        (org-add-planning-info nil nil 'deadline)))
    (unless (eq apple-flag (alist-get 'flagged org-values))
      (org-toggle-tag "flagged" (if apple-flag 'on 'off)))
    (unless (equal apple-notes (alist-get 'notes org-values))
      (org-apple-reminders--set-org-notes apple-notes))
    (when (stringp apple-mod)
      (org-set-property "REMINDER_APPLE_MOD" apple-mod))))

(defun org-apple-reminders--backfill-from-apple (apple-values)
  "Backfill missing org fields from APPLE-VALUES.
Return non-nil when the org heading was changed."
  (let ((org-values (org-apple-reminders--org-item-values))
        (changed nil))
    (when (and (alist-get 'due apple-values)
               (null (alist-get 'due org-values)))
      (org-add-planning-info
       'deadline
       (org-apple-reminders--format-due (alist-get 'due apple-values)))
      (setq changed t))
    (when (and (org-apple-reminders--nonempty-string
                (alist-get 'notes apple-values))
               (string-empty-p (or (alist-get 'notes org-values) "")))
      (org-apple-reminders--set-org-notes (alist-get 'notes apple-values))
      (setq changed t))
    (when (and (> (or (alist-get 'priority apple-values) 0) 0)
               (= (or (alist-get 'priority org-values) 0) 0))
      (org-priority (cond ((= (alist-get 'priority apple-values) 1) ?A)
                          ((= (alist-get 'priority apple-values) 5) ?B)
                          ((= (alist-get 'priority apple-values) 9) ?C)
                          (t 'remove)))
      (setq changed t))
    (when (and (alist-get 'flagged apple-values)
               (not (alist-get 'flagged org-values)))
      (org-toggle-tag "flagged" 'on)
      (setq changed t))
    changed))

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

;; -- snapshot builders (consume the accessors above) --

(defun org-apple-reminders--snapshot-build (data previous-lists)
  "Build a snapshot from DATA and PREVIOUS-LISTS, refreshing the cache."
  (setq org-apple-reminders--cache data)
  (org-apple-reminders--make-snapshot
   :data data
   :by-id (org-apple-reminders--apple-items-by-id data)
   :list-names (org-apple-reminders--apple-list-names data)
   :list-ids (org-apple-reminders--apple-list-ids data)
   :id-index (org-apple-reminders--build-id-index)
   :previous-lists previous-lists))

(defun org-apple-reminders--fetch-snapshot ()
  "Synchronously fetch Apple state into a snapshot; create the sync file if absent."
  (let ((sync-file (expand-file-name org-apple-reminders-sync-file))
        (previous-lists (org-apple-reminders--cached-list-names)))
    (unless (file-exists-p sync-file)
      (with-temp-file sync-file
        (insert org-apple-reminders--sync-file-template)))
    (let* ((raw (org-apple-reminders--jxa-run org-apple-reminders--fetch-script))
           (data (condition-case nil
                     (json-parse-string raw :object-type 'alist :array-type 'list)
                   (error (user-error "Reminders sync: fetch failed — %s" raw)))))
      (org-apple-reminders--snapshot-build data previous-lists))))

(defun org-apple-reminders--snapshot-from-json (raw)
  "Build a snapshot from already-fetched JSON RAW (async pull path)."
  (org-apple-reminders--snapshot-build
   (json-parse-string raw :object-type 'alist :array-type 'list)
   (org-apple-reminders--cached-list-names)))

(defvar org-apple-reminders--known-files-cache :unset
  "Dynamically bound cache for `org-apple-reminders--known-files'.")

(defvar org-apple-reminders--reminder-files-cache :unset
  "Dynamically bound cache for files whose headings define reminder structure.")

(defun org-apple-reminders--normalize-file-list (files)
  "Return expanded, deduplicated existing path strings from FILES."
  (delete-dups
   (delq nil
         (mapcar (lambda (file)
                   (and (stringp file)
                        (not (string-empty-p file))
                        (expand-file-name file)))
                 files))))

(defun org-apple-reminders--compute-reminder-files ()
  "Return files whose headings define Apple Reminders structure.
Only `org-apple-reminders-sync-file' is structure-authoritative: level-1
headings are Apple lists and level-2 headings may become Apple reminders.
Other known files may host linked reminders, but they do not create lists or
auto-create reminders from their outline structure."
  (org-apple-reminders--normalize-file-list
   (list org-apple-reminders-sync-file)))

(defun org-apple-reminders--reminder-files ()
  "Return cached reminder-structure files when available."
  (if (eq org-apple-reminders--reminder-files-cache :unset)
      (org-apple-reminders--compute-reminder-files)
    org-apple-reminders--reminder-files-cache))

(defun org-apple-reminders--compute-known-files ()
  "Deduped list of all org files that may contain REMINDER_ID headings.
Includes `org-apple-reminders-sync-file', `org-apple-reminders-extra-files',
.org files from `org-agenda-files', and any currently open org buffer that
already contains at least one REMINDER_ID (so files linked via
`org-apple-reminders-push-heading' are picked up without manual config)."
  (org-apple-reminders--normalize-file-list
   (append (org-apple-reminders--compute-reminder-files)
           org-apple-reminders-extra-files
           (cl-remove-if-not
            (lambda (f) (and (stringp f) (string-match-p "\\.org\\'" f)))
            org-agenda-files)
           (delq nil
                 (mapcar (lambda (buf)
                           (with-current-buffer buf
                             (and (buffer-file-name)
                                  (derived-mode-p 'org-mode)
                                  (org-apple-reminders--buffer-has-reminders-p)
                                  (buffer-file-name))))
                         (buffer-list))))))

(defun org-apple-reminders--known-files ()
  "Return cached known files when available, otherwise compute them."
  (if (eq org-apple-reminders--known-files-cache :unset)
      (org-apple-reminders--compute-known-files)
    org-apple-reminders--known-files-cache))

(defmacro org-apple-reminders--with-known-files-cache (&rest body)
  "Run BODY with `org-apple-reminders--known-files' computed once."
  (declare (indent 0) (debug t))
  `(let* ((org-apple-reminders--reminder-files-cache
           (org-apple-reminders--compute-reminder-files))
          (org-apple-reminders--known-files-cache
           (org-apple-reminders--compute-known-files)))
     ,@body))

(defun org-apple-reminders--build-id-index ()
  "Scan all known org files; return hash REMINDER_ID → expanded file path."
  (let ((ht (make-hash-table :test #'equal)))
    (dolist (file (org-apple-reminders--known-files))
      (when (file-exists-p file)
        (with-current-buffer (find-file-noselect file)
          (org-map-entries
           (lambda ()
             (when-let (id (org-entry-get nil "REMINDER_ID"))
               (puthash id (expand-file-name file) ht)))
           nil nil))))
    ht))

(defun org-apple-reminders--buffer-has-reminders-p ()
  "Return non-nil if any REMINDER_ID heading is present in this buffer."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward ":REMINDER_ID:" nil t)))

(defun org-apple-reminders--register-current-file ()
  "Register the current buffer's file in `org-apple-reminders-extra-files'.
Return the file name when it was newly registered, nil otherwise (including
when the buffer visits no file or the file is already known)."
  (when (buffer-file-name)
    (let ((this-file (expand-file-name (buffer-file-name))))
      (unless (member this-file (org-apple-reminders--known-files))
        (customize-save-variable
         'org-apple-reminders-extra-files
         (cons (buffer-file-name) org-apple-reminders-extra-files))
        (buffer-file-name)))))

(defun org-apple-reminders--push-heading-1 (target)
  "Push the heading at point to Apple list TARGET, without relocating it.

Do the Apple-side work and stamp the org properties only.  Return a cons
\(STATUS . RELOCATE): STATUS is `created', `updated', `moved' or `failed';
RELOCATE is non-nil when the heading's subtree should be placed under
TARGET's section — i.e. it was newly created or it changed list.  Call with
point inside the heading's entry and `org-apple-reminders--syncing' bound
non-nil."
  (let* ((old-id   (org-entry-get nil "REMINDER_ID"))
         (old-list (org-entry-get nil "REMINDER_LIST"))
         (vals     (org-apple-reminders--org-item-values)))
    (cond
     ;; Linked, same list — update in place.
     ((and old-id old-list (string= old-list target))
      (org-apple-reminders--update-in-apple old-list old-id vals)
      (cons 'updated nil))
     ;; Linked, different list — move (delete old, recreate in TARGET).
     ((and old-id old-list)
      (let ((new-id (org-apple-reminders--create-in-apple target vals)))
        (if (not new-id)
            (cons 'failed nil)
          (org-apple-reminders--delete-in-apple old-list old-id)
          (when (member (org-get-todo-state) '("DONE" "CANCELLED"))
            (org-apple-reminders--complete-in-apple target new-id))
          (org-set-property "REMINDER_ID"   new-id)
          (org-set-property "REMINDER_LIST" target)
          ;; The recreated reminder has fresh timestamps; drop the stale ones.
          (org-entry-delete nil "REMINDER_APPLE_MOD")
          (org-entry-delete nil "REMINDER_ORG_MOD")
          (cons 'moved t))))
     ;; Unlinked — fresh push.
     (t
      (let ((new-id (org-apple-reminders--create-in-apple target vals)))
        (if (not new-id)
            (cons 'failed nil)
          (org-set-property "REMINDER_ID"   new-id)
          (org-set-property "REMINDER_LIST" target)
          (org-entry-delete nil "REMINDER_NOSYNC")
          ;; A new reminder belongs under its list section too (sync file).
          (cons 'created t)))))))

(defun org-apple-reminders--push-region (beg end target)
  "Push every reminder heading between BEG and END to Apple list TARGET.

Unlinked TODO/NEXT/WAITING headings are created in TARGET; linked headings
already in TARGET are updated; linked headings in another list are moved.
Headings that are neither linked reminders nor open tasks are skipped.
TARGET must already exist in Apple.  Moved subtrees are relocated under
TARGET's `* ' heading when the buffer visits `org-apple-reminders-sync-file'.

Return a plist with counts :created :updated :moved :skipped :failed and
:registered (a newly registered file path, or nil)."
  (let ((in-sync (org-apple-reminders--in-sync-file-p))
        (markers nil) (relocate nil) (registered nil)
        (created 0) (updated 0) (moved 0) (skipped 0) (failed 0))
    ;; Pass 1 — collect linked reminders and open tasks inside the region.
    (save-excursion
      (goto-char beg)
      (if (org-before-first-heading-p)
          (outline-next-heading)
        (org-back-to-heading t))
      (while (and (not (eobp)) (<= (point) end))
        (if (or (org-entry-get nil "REMINDER_ID")
                (member (org-get-todo-state) '("TODO" "NEXT" "WAITING")))
            (push (point-marker) markers)
          (setq skipped (1+ skipped)))
        (outline-next-heading)))
    (setq markers (nreverse markers))
    (let ((org-apple-reminders--syncing t))
      ;; Pass 2 — Apple side + property stamping (no structural moves).
      (dolist (m markers)
        (let (relocate-this)
          (save-excursion
            (goto-char m)
            (org-back-to-heading t)
            (let* ((res    (org-apple-reminders--push-heading-1 target))
                   (status (car res)))
              (setq relocate-this (cdr res))
              (pcase status
                ('created (setq created (1+ created))
                          (unless registered
                            (setq registered
                                  (org-apple-reminders--register-current-file))))
                ('updated (setq updated (1+ updated)))
                ('moved   (setq moved (1+ moved)))
                ('failed  (setq failed (1+ failed))))))
          (if relocate-this
              (push m relocate)
            (set-marker m nil))))
      (setq relocate (nreverse relocate))
      ;; Pass 3 — relocate created/moved subtrees in one batch (sync file
      ;; only).  Cut every subtree first, then paste them under TARGET's
      ;; heading, forced to level 2 so any heading level is normalised.
      (when (and in-sync relocate)
        (let ((trees nil))
          (dolist (m relocate)
            (when (marker-buffer m)
              (save-excursion
                (goto-char m)
                (org-back-to-heading t)
                (let ((s (point))
                      (e (save-excursion (org-end-of-subtree t t) (point))))
                  (push (buffer-substring s e) trees)
                  (delete-region s e)))))
          (save-excursion
            (dolist (tree (nreverse trees))
              (kill-new tree)
              (org-apple-reminders--goto-list-heading target)
              (org-paste-subtree 2)))
          (ignore-errors (org-update-statistics-cookies t))))
      (dolist (m relocate) (set-marker m nil))
      (when (and (buffer-file-name) (buffer-modified-p)) (save-buffer)))
    (list :created created :updated updated :moved moved
          :skipped skipped :failed failed :registered registered)))

(defun org-apple-reminders--unlink-apple-at-point ()
  "Delete the Apple reminder for the heading at point and drop it from cache.
Return the (LIST . ID) cons, or nil when the heading carries no REMINDER_ID."
  (let ((loc (org-apple-reminders--loc-at-point)))
    (when loc
      (org-apple-reminders--delete-in-apple (car loc) (cdr loc))
      (when-let (entry (cl-find (car loc) org-apple-reminders--cache
                                :key (lambda (e) (alist-get 'list e))
                                :test #'string=))
        (let ((cell (assq 'items entry)))
          (when cell
            (setcdr cell (cl-remove (cdr loc) (cdr cell)
                                    :key (lambda (e) (alist-get 'id e))
                                    :test #'string=)))))
      loc)))

(defun org-apple-reminders--strip-link-properties ()
  "Remove the REMINDER_* link properties from the heading at point.
Also set REMINDER_NOSYNC so the heading is never pushed back to Apple."
  (save-excursion
    (org-back-to-heading t)
    (dolist (prop '("REMINDER_ID" "REMINDER_LIST"
                    "REMINDER_APPLE_MOD" "REMINDER_ORG_MOD"
                    "REMINDER_DELETE"))
      (org-entry-delete nil prop))
    (org-set-property "REMINDER_NOSYNC" "t")))

(defun org-apple-reminders--delete-org-subtree-at-point ()
  "Delete the org subtree at point and leave surrounding spacing tidy."
  (save-excursion
    (org-back-to-heading t)
    (let ((beg (point))
          (end (save-excursion (org-end-of-subtree t t) (point))))
      (delete-region beg end)
      (when (and (not (bobp))
                 (not (eobp))
                 (looking-at-p "\n")
                 (save-excursion
                   (forward-line -1)
                   (looking-at-p "[ \t]*$")))
        (delete-char 1)))))

(defun org-apple-reminders--markers-deepest-first (markers)
  "Return live MARKERS sorted from later buffer positions to earlier ones."
  (sort (cl-remove-if-not #'marker-position markers)
        (lambda (a b) (> (marker-position a) (marker-position b)))))

(defun org-apple-reminders--cancelled-list-heading-p ()
  "Return non-nil when point is a CANCELLED list heading in the sync file."
  (and (org-apple-reminders--in-sync-file-p)
       (= (or (org-apple-reminders--heading-line-level) 0) 1)
       (org-apple-reminders--todo-cancelled-p
        (org-apple-reminders--heading-line-todo-state))))

(defun org-apple-reminders--finalize-cancelled-at-point ()
  "Propagate CANCELLED heading at point to Apple deletion, then remove it.
In `org-apple-reminders-sync-file', a CANCELLED level-1 heading deletes the
Apple list.  Linked reminder headings delete their Apple reminder.  Unlinked
child headings in the sync file are simply removed locally."
  (save-excursion
    (org-back-to-heading t)
    (cond
     ((org-apple-reminders--cancelled-list-heading-p)
      (org-apple-reminders--delete-list-in-apple
       (org-apple-reminders--heading-line-title))
      (org-apple-reminders--delete-org-subtree-at-point)
      'list)
     ((let ((id (org-entry-get nil "REMINDER_ID"))
            (rlist (org-entry-get nil "REMINDER_LIST")))
        (when (and id rlist)
          (org-apple-reminders--delete-in-apple rlist id)
          (org-apple-reminders--delete-org-subtree-at-point)
          'reminder)))
     ((and (org-apple-reminders--in-sync-file-p)
           (> (or (org-apple-reminders--heading-line-level) 0) 1))
      (org-apple-reminders--delete-org-subtree-at-point)
      'local))))

(defun org-apple-reminders--region-reminder-markers (beg end)
  "Return markers for every heading between BEG and END that has a REMINDER_ID."
  (let (markers)
    (save-excursion
      (goto-char beg)
      (if (org-before-first-heading-p)
          (outline-next-heading)
        (org-back-to-heading t))
      (while (and (not (eobp)) (<= (point) end))
        (when (org-entry-get nil "REMINDER_ID")
          (push (point-marker) markers))
        (outline-next-heading)))
    (nreverse markers)))

(defun org-apple-reminders--mark-done-at-point ()
  "Mark the heading at point as DONE.
No-op when the heading is already DONE or CANCELLED.  The caller must
bind `org-apple-reminders--syncing' to suppress the
`org-after-todo-state-change-hook' callback that would otherwise push
the completion to Apple."
  (save-excursion
    (org-back-to-heading t)
    (unless (member (org-get-todo-state) '("DONE" "CANCELLED"))
      (org-todo "DONE"))))

(defun org-apple-reminders--mark-done-in-other-known-files (ids)
  "Mark each REMINDER_ID in IDS as DONE wherever it appears in known files.
Skips the current buffer (the caller handles it directly).  Also strips
the link properties and sets `REMINDER_NOSYNC' so the orphaned heading
is never pushed back to Apple.  Saves each modified buffer.  Caller must
bind `org-apple-reminders--syncing'."
  (when ids
    (let ((current (and (buffer-file-name)
                        (expand-file-name (buffer-file-name)))))
      (dolist (file (org-apple-reminders--known-files))
        (unless (and current (string= file current))
          (when (file-exists-p file)
            (with-current-buffer (find-file-noselect file)
              (let (changed)
                (dolist (id ids)
                  (when-let ((pos (org-find-property "REMINDER_ID" id)))
                    (save-excursion
                      (goto-char pos)
                      (org-back-to-heading t)
                      (org-apple-reminders--mark-done-at-point)
                      (org-apple-reminders--strip-link-properties)
                      (setq changed t))))
                (when (and changed (buffer-modified-p))
                  (save-buffer))))))))))

(defun org-apple-reminders--delete-marked-reminders (apple-by-id)
  "Delete headings marked REMINDER_DELETE from Apple and finalize them in org.
APPLE-BY-ID is the fetched Apple reminder hash for the current full sync.
Return the number of marked headings finalized in org.  Callers must bind
`org-apple-reminders--syncing'."
  (let ((n 0)
        (ids nil))
    (dolist (file (org-apple-reminders--known-files))
      (when (file-exists-p file)
        (with-current-buffer (find-file-noselect file)
          (let (changed)
            (org-map-entries
             (lambda ()
               (when (org-entry-get nil "REMINDER_DELETE")
                 (let ((id (org-entry-get nil "REMINDER_ID"))
                       (rlist (org-entry-get nil "REMINDER_LIST")))
                   (when id
                     (push id ids)
                     (when (and rlist (gethash id apple-by-id))
                       (org-apple-reminders--delete-in-apple rlist id)))
                   (org-apple-reminders--mark-done-at-point)
                   (org-apple-reminders--strip-link-properties)
                   (setq changed t
                         n (1+ n)))))
             nil nil)
            (when (and changed (buffer-modified-p))
              (org-apple-reminders-refresh-delete-mark-visibility)
              (save-buffer))))))
    (org-apple-reminders--wait-for-async-jxa)
    (org-apple-reminders--mark-done-in-other-known-files (delete-dups ids))
    n))

;;;###autoload

(defun org-apple-reminders--goto-list-heading (list-name)
  "Move point to end of LIST-NAME's subtree, creating the * heading if absent."
  (goto-char (point-min))
  (if (re-search-forward (format "^\\* %s\\(?:[[:space:]]\\|$\\)" (regexp-quote list-name)) nil t)
      (org-end-of-subtree t t)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    ;; Keep one blank line between the previous section and the new heading.
    (unless (or (bobp)
                (save-excursion (forward-line -1) (looking-at-p "[ \t]*$")))
      (insert "\n"))
    (insert (format "* %s [/]\n" list-name)))
  (unless (bolp) (insert "\n")))

(defun org-apple-reminders--ensure-list-cookies ()
  "Give every level-1 list heading a [/] progress cookie, then recompute them."
  (org-map-entries
   (lambda ()
     (unless (save-excursion (beginning-of-line)
                             (looking-at "[^\n]*\\[[0-9]*/[0-9]*\\]"))
       (end-of-line) (insert " [/]"))
     (org-update-statistics-cookies nil))
   "LEVEL=1" nil))

(defun org-apple-reminders--normalize-list-spacing ()
  "Ensure a blank line precedes every `* ' list heading except the first one.
Tidies sections that earlier versions inserted flush against each other."
  (save-excursion
    (goto-char (point-min))
    (let ((first t))
      (while (re-search-forward "^\\* " nil t)
        (forward-line 0)
        (if first
            (setq first nil)
          (unless (save-excursion (forward-line -1) (looking-at-p "[ \t]*$"))
            (insert "\n")))
        (forward-line 1)))))

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
    (insert "   :PROPERTIES:\n")
    (insert (format "   :REMINDER_ID:   %s\n" id))
    (insert (format "   :REMINDER_LIST: %s\n" list-name))
    (insert "   :END:\n")
    (when (and (stringp notes) (not (string-empty-p notes)))
      (dolist (line (split-string notes "\n"))
        (insert (format "   %s\n" line))))))

(defun org-apple-reminders--list-section-p ()
  "Return non-nil if the level-1 heading at point is a pure reminders list.
True when the section is empty or every heading beneath it carries a
REMINDER_ID — hand-written content under a level-1 heading makes it false."
  (save-excursion
    (org-back-to-heading t)
    (let ((end  (save-excursion (org-end-of-subtree t t) (point)))
          (pure t))
      (while (and pure (outline-next-heading) (< (point) end))
        (unless (org-entry-get nil "REMINDER_ID")
          (setq pure nil)))
      pure)))

(defun org-apple-reminders--prune-excluded-lists ()
  "Delete `* List' sections in the current buffer whose list is excluded.
A section is removed when its name is not in the effective included-lists
set AND it is a pure reminders list (see `org-apple-reminders--list-section-p',
so hand-written content is never touched).  No-op when all lists are
included.  Return the number of sections removed."
  (let ((included (org-apple-reminders--effective-included-lists))
        (removed 0))
    (when included
      (let ((org-apple-reminders--syncing t)
            (markers nil))
        (save-excursion
          (org-map-entries
           (lambda ()
             (let ((name (string-trim
                          (replace-regexp-in-string
                           "\\[[0-9]*/[0-9]*\\][ \t]*$" ""
                           (org-get-heading t t t t)))))
               (when (and (not (member name included))
                          (org-apple-reminders--list-section-p))
                 (push (point-marker) markers))))
           "LEVEL=1"))
        (dolist (m markers)
          (when (marker-buffer m)
            (goto-char m)
            (org-back-to-heading t)
            (delete-region (point)
                           (save-excursion (org-end-of-subtree t t) (point)))
            (setq removed (1+ removed)))
          (set-marker m nil))))
    removed))

(defun org-apple-reminders--in-sync-file-p ()
  "Return non-nil if the current buffer visits `org-apple-reminders-sync-file'."
  (and (buffer-file-name)
       (string= (expand-file-name (buffer-file-name))
                (expand-file-name org-apple-reminders-sync-file))))

(defun org-apple-reminders--in-known-file-p ()
  "Return non-nil if the current buffer visits a known reminder org file."
  (and (buffer-file-name)
       (member (expand-file-name (buffer-file-name))
               (org-apple-reminders--known-files))))

(defun org-apple-reminders--in-reminder-file-p ()
  "Return non-nil if current buffer's headings may define reminder structure."
  (and (buffer-file-name)
       (member (expand-file-name (buffer-file-name))
               (org-apple-reminders--reminder-files))))

(defun org-apple-reminders--clean-list-heading (heading)
  "Return Apple list name represented by level-1 HEADING."
  (string-trim
   (replace-regexp-in-string
    "\\[[0-9]*/[0-9]*\\][ \t]*$" ""
    heading)))

(defun org-apple-reminders--done-list-heading-p ()
  "Return non-nil when point is at a completed list-section heading."
  (member (org-get-todo-state) '("DONE" "CANCELLED")))

(defun org-apple-reminders--heading-line-level ()
  "Return heading level at beginning of current line, or nil."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "\\(\\*+\\)\\(?:[ \t]+\\|$\\)")
      (length (match-string 1)))))

(defun org-apple-reminders--goto-current-heading-line ()
  "Move to the current heading line without using Org element parsing."
  (or (org-apple-reminders--heading-line-level)
      (re-search-backward "^\\*+\\(?:[ \t]+\\|$\\)" nil t)))

(defun org-apple-reminders--heading-line-title ()
  "Return current heading title without TODO keyword, priority, tags, or cookies."
  (save-excursion
    (beginning-of-line)
    (let* ((line (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position)))
           (text (replace-regexp-in-string
                  "^\\*+[ \t]*" "" line))
           (todos (and (boundp 'org-todo-keywords-1)
                       org-todo-keywords-1)))
      (when todos
        (setq text
              (replace-regexp-in-string
               (format "^\\(?:%s\\)[ \t]+"
                       (regexp-opt todos))
               "" text)))
      (setq text (replace-regexp-in-string
                  "^#\\[[A-Z]\\][ \t]*" "" text))
      (setq text (replace-regexp-in-string
                  "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*$" "" text))
      (org-apple-reminders--clean-list-heading text))))

(defun org-apple-reminders--heading-line-todo-state ()
  "Return TODO keyword at beginning of current heading line, or nil."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "\\*+[ \t]+\\([^ \t\n]+\\)")
      (let ((word (match-string 1)))
        (and (boundp 'org-todo-keywords-1)
             (member word org-todo-keywords-1)
             word)))))

(defun org-apple-reminders--level-1-heading-has-children-p ()
  "Return non-nil when the current level-1 heading has child headings."
  (save-excursion
    (forward-line 1)
    (catch 'child
      (while (not (eobp))
        (cond
         ((looking-at "^\\*\\(?:[ \t]+\\|$\\)")
          (throw 'child nil))
         ((looking-at "^\\*\\{2,\\}\\(?:[ \t]+\\|$\\)")
          (throw 'child t)))
        (forward-line 1))
      nil)))

(defun org-apple-reminders--known-file-list-section-p (&optional include-done)
  "Return non-nil when point is at a list section in a known file.
Only `org-apple-reminders-sync-file' is structure-authoritative.  Every
non-empty level-1 heading there is an Apple list, with or without an Org TODO
keyword.  The TODO keyword is local Org metadata and is not pushed as an Apple
reminder.
When INCLUDE-DONE is non-nil, completed list sections are also matched."
  (and (org-apple-reminders--in-sync-file-p)
       (= (or (org-apple-reminders--heading-line-level) 0) 1)
       (let ((name (org-apple-reminders--heading-line-title))
             (todo (org-apple-reminders--heading-line-todo-state)))
         (and (not (string-empty-p name))
              (or include-done
                  (not (member todo '("DONE" "CANCELLED"))))))))

(defun org-apple-reminders--done-list-section-exists-p (list-name)
  "Return non-nil when the current buffer has a DONE section for LIST-NAME."
  (catch 'found
    (save-excursion
      (org-map-entries
       (lambda ()
         (let ((name (org-apple-reminders--clean-list-heading
                      (org-get-heading t t t t))))
           (when (and (string= name list-name)
                      (org-apple-reminders--done-list-heading-p))
             (throw 'found t))))
       "LEVEL=1" 'file))
    nil))

(defun org-apple-reminders--stamp-list-section (list-name &optional info)
  "Stamp the current level-1 list section with Apple list metadata."
  (when (and (org-apple-reminders--known-file-list-heading-p)
             (not (org-apple-reminders--done-list-heading-p)))
    (org-set-property "REMINDER_LIST_SYNCED" "t")
    (org-set-property "REMINDER_LIST_NAME" list-name)
    (when-let ((id (org-apple-reminders--list-info-id info)))
      (org-set-property "REMINDER_LIST_ID" id))))

(defun org-apple-reminders--apple-list-known-p (name id apple-list-names apple-list-ids)
  "Return non-nil if NAME or ID exists in current Apple list metadata."
  (or (and (stringp id)
           (not (string-empty-p id))
           (member id apple-list-ids))
      (member name apple-list-names)))

(defun org-apple-reminders--known-file-list-at-point ()
  "Return nearest level-1 list name at point in a known file, or nil."
  (when (org-apple-reminders--in-sync-file-p)
    (save-excursion
      (ignore-errors
        (org-apple-reminders--goto-current-heading-line)
        (unless (= (or (org-apple-reminders--heading-line-level) 0) 1)
          (re-search-backward "^\\*\\(?:[ \t]+\\|$\\)" nil t))
        (when (org-apple-reminders--known-file-list-section-p)
          (org-apple-reminders--heading-line-title))))))

(defun org-apple-reminders--in-done-known-file-list-p ()
  "Return non-nil when point is inside a DONE known-file list section."
  (when (org-apple-reminders--in-sync-file-p)
    (save-excursion
      (ignore-errors
        (org-apple-reminders--goto-current-heading-line)
        (unless (= (or (org-apple-reminders--heading-line-level) 0) 1)
          (re-search-backward "^\\*\\(?:[ \t]+\\|$\\)" nil t))
        (and (org-apple-reminders--known-file-list-section-p t)
             (member (org-apple-reminders--heading-line-todo-state)
                     '("DONE" "CANCELLED")))))))

(defun org-apple-reminders--known-file-list-heading-p ()
  "Return non-nil when point is at a level-1 list heading in a known file."
  (org-apple-reminders--known-file-list-section-p))

(defun org-apple-reminders--auto-create-reminder-heading-p (state)
  "Return non-nil when the current heading may create an Apple reminder.
The managed sync file maps level 1 to Apple lists and level 2 to reminders.
Level 3 is reserved for future real subtask support and is not flattened into
an ordinary Apple reminder.  Other known files may create reminders only when
the heading has an explicit target such as REMINDER_LIST."
  (and (org-apple-reminders--active-heading-state-p state)
       (not (org-apple-reminders--known-file-list-heading-p))
       (not (org-entry-get nil "REMINDER_NOSYNC"))
       (not (string-empty-p (org-apple-reminders--org-title-value)))
       (or (not (org-apple-reminders--in-sync-file-p))
           (= (or (org-apple-reminders--heading-line-level) 0) 2))))

(defun org-apple-reminders--ensure-known-file-lists ()
  "Ensure known-file list sections exist as Apple lists.
Return the number of lists that were successfully ensured.  Plain level-1
headings are list sections.  Level-1 TODO headings are list sections too;
their TODO keyword is local Org metadata, not an Apple reminder."
  (let ((n 0))
    (dolist (file (org-apple-reminders--reminder-files))
      (when (file-exists-p file)
        (with-current-buffer (find-file-noselect file)
          (org-with-wide-buffer
           (org-map-entries
            (lambda ()
              (let ((name (org-apple-reminders--clean-list-heading
                           (org-get-heading t t t t))))
                (when (and (org-apple-reminders--known-file-list-heading-p)
                           (org-apple-reminders--list-included-p name))
                  (when-let ((info (org-apple-reminders--ensure-list name)))
                    (org-apple-reminders--stamp-list-section name info)
                    (setq n (1+ n))))))
            "LEVEL=1" 'file)))))
    n))

(defun org-apple-reminders--mark-missing-apple-lists-done (previous-list-names
                                                          apple-list-names
                                                          &optional apple-list-ids)
  "Mark sync-file list sections DONE when their Apple list is missing.
PREVIOUS-LIST-NAMES is the list names from the previous Apple fetch, and
APPLE-LIST-NAMES is the list names returned by Apple now.  APPLE-LIST-IDS is
the optional current list id set.  DONE list sections are the marker that the
list should not be recreated by later syncs.  Return the number of sections
newly marked DONE."
  (let ((n 0)
        (org-apple-reminders--syncing t))
    (org-map-entries
     (lambda ()
       (let* ((name (org-apple-reminders--clean-list-heading
                     (org-get-heading t t t t)))
              (id (org-entry-get nil "REMINDER_LIST_ID"))
              (synced (org-entry-get nil "REMINDER_LIST_SYNCED")))
         (when (and (not (string-empty-p name))
                    (or synced (member name previous-list-names))
                    (not (org-apple-reminders--apple-list-known-p
                          name id apple-list-names apple-list-ids))
                    (not (org-apple-reminders--done-list-heading-p)))
           (org-todo "DONE")
           (setq n (1+ n)))))
     "LEVEL=1" 'file)
    n))

(defun org-apple-reminders--delete-missing-done-list-sections (previous-list-names
                                                              apple-list-names
                                                              &optional apple-list-ids)
  "Delete DONE sync-file list sections whose Apple list is still missing.
This is the second phase of Apple-side list deletion: the first full sync marks
the list DONE, and a later full sync removes the remaining Org section."
  (let ((n 0)
        (markers nil)
        (org-apple-reminders--syncing t))
    (org-map-entries
     (lambda ()
       (let* ((name (org-apple-reminders--clean-list-heading
                     (org-get-heading t t t t)))
              (id (org-entry-get nil "REMINDER_LIST_ID"))
              (synced (org-entry-get nil "REMINDER_LIST_SYNCED")))
         (when (and (not (string-empty-p name))
                    (or synced (member name previous-list-names))
                    (org-apple-reminders--done-list-heading-p)
                    (not (org-apple-reminders--apple-list-known-p
                          name id apple-list-names apple-list-ids)))
           (push (point-marker) markers))))
     "LEVEL=1" 'file)
    (dolist (m (org-apple-reminders--markers-deepest-first markers))
      (when (marker-position m)
        (goto-char m)
        (org-apple-reminders--delete-org-subtree-at-point)
        (setq n (1+ n)))
      (set-marker m nil))
    n))

(defun org-apple-reminders--target-list-at-point (&optional default-list)
  "Return the Apple list for creating/updating the heading at point.
Precedence: explicit REMINDER_LIST property, nearest level-1 list section
in a reminder-structure file, then DEFAULT-LIST only in a reminder-structure
file."
  (unless (org-apple-reminders--in-done-known-file-list-p)
    (let ((target (or (org-entry-get nil "REMINDER_LIST")
                      (org-apple-reminders--known-file-list-at-point)
                      (and (org-apple-reminders--in-reminder-file-p)
                           default-list))))
      (and (stringp target)
           (not (string-empty-p target))
           target))))

(defun org-apple-reminders--relocate-subtree-to-list (list-name)
  "Relocate the heading subtree at point under LIST-NAME's `* ' heading.
Used inside `org-apple-reminders-sync-file' when a reminder moves to a
different Apple list.  Saves the buffer and refreshes the `[/]' progress
cookies on the affected list headings."
  (let ((org-apple-reminders--syncing t))
    (org-back-to-heading t)
    (org-cut-subtree)
    (org-apple-reminders--goto-list-heading list-name)
    (org-paste-subtree 2)
    (ignore-errors (org-update-statistics-cookies t))
    (when (buffer-file-name) (save-buffer))))

(defun org-apple-reminders--sync-reconcile-list-sections (snapshot counts)
  "Reconcile the sync file's list sections against SNAPSHOT; tally into COUNTS."
  (let ((sync-file (expand-file-name org-apple-reminders-sync-file))
        (previous-list-names (org-apple-reminders--snapshot-previous-lists snapshot))
        (apple-list-names (org-apple-reminders--snapshot-list-names snapshot))
        (apple-list-ids (org-apple-reminders--snapshot-list-ids snapshot))
        (n-deleted 0) (n-lists-done 0))
    (when (file-exists-p sync-file)
      (with-current-buffer (find-file-noselect sync-file)
        (org-save-outline-visibility t
          (setq n-deleted
                (+ n-deleted
                   (org-apple-reminders--delete-missing-done-list-sections
                    previous-list-names apple-list-names apple-list-ids)))
          (setq n-lists-done
                (org-apple-reminders--mark-missing-apple-lists-done
                 previous-list-names apple-list-names apple-list-ids))
          (when (buffer-modified-p)
            (save-buffer)))))
    (cl-incf (org-apple-reminders--counts-deleted counts) n-deleted)
    (setf (org-apple-reminders--counts-lists-done counts) n-lists-done)))

(defun org-apple-reminders--sync-delete-marked (snapshot counts)
  "Delete reminders flagged REMINDER_DELETE; record the count in COUNTS."
  (setf (org-apple-reminders--counts-deleted counts)
        (org-apple-reminders--delete-marked-reminders
         (org-apple-reminders--snapshot-by-id snapshot))))

(defun org-apple-reminders--sync-reconcile-file (file snapshot counts)
  "Phase 1: reconcile linked headings in FILE against SNAPSHOT; tally into COUNTS."
  (let ((sync-file (expand-file-name org-apple-reminders-sync-file))
        (default-list (org-apple-reminders--default-list))
        (apple-by-id (org-apple-reminders--snapshot-by-id snapshot))
        (id-index (org-apple-reminders--snapshot-id-index snapshot))
        (n-done 0) (n-pushed 0) (n-updated 0) (n-deleted 0))
          (let ((is-sync-file (string= (expand-file-name file) sync-file)))
            (with-current-buffer (find-file-noselect file)
              (org-save-outline-visibility t
                (let (done-pts delete-org-pts cancel-pts new-pts apple-updates
                                changed-positions)
                  (org-map-entries
                   (lambda ()
                     (let* ((id    (org-entry-get nil "REMINDER_ID"))
                            (rlist (org-apple-reminders--target-list-at-point default-list))
                            (state (org-get-todo-state)))
                       (cond
                        ((org-apple-reminders--todo-cancelled-p state)
                         (push (point-marker) cancel-pts))
                        ((and (null id) rlist
                              (org-apple-reminders--auto-create-reminder-heading-p state))
                         (push (point-marker) new-pts))
                        (id
                         (let ((apple (gethash id apple-by-id)))
                           (cond
                            ((and (org-apple-reminders--todo-done-p state)
                                  (null apple))
                             (push (point-marker) delete-org-pts))
                            ((and (org-apple-reminders--todo-done-p state)
                                  apple
                                  (not (org-apple-reminders--apple-item-completed-p apple)))
                             (org-apple-reminders--complete-in-apple rlist id))
                            ((and (org-apple-reminders--active-heading-state-p state)
                                  (or (null apple)
                                      (org-apple-reminders--apple-item-completed-p apple)))
                             (push (point-marker) done-pts))
                            ((org-apple-reminders--active-heading-state-p state)
                             (let* ((a-mod       (org-apple-reminders--apple-item-mod-date apple))
                                    (last-known  (org-apple-reminders--last-known-mod))
                                    (apple-changed (and a-mod
                                                        (or (null last-known)
                                                            (string> a-mod last-known)))))
                               (if apple-changed
                                   (let* ((apple-values (org-apple-reminders--apple-field-values apple))
                                          (org-values (org-apple-reminders--current-org-field-values))
                                          (changed (org-apple-reminders--field-values-differ-p
                                                    apple-values org-values)))
                                     (if changed
                                         (push (list (point-marker) apple-values) apple-updates)
                                       ;; Apple's modDate advanced but every tracked
                                       ;; field already matches org — record that this
                                       ;; modDate is reconciled so org edits can win later.
                                       (when (stringp a-mod)
                                         (org-set-property "REMINDER_APPLE_MOD" a-mod))))
                                 ;; Apple not "changed".  Split into two
                                 ;; sub-cases:
                                 ;;   org-changed: org pushed something since
                                 ;;     Apple was last seen — push including
                                 ;;     nils (clears Apple's field).
                                 ;;   neither:    BACKFILL missing org fields
                                 ;;     from Apple; for fields where org has
                                 ;;     non-nil content that differs, still
                                 ;;     push (preserves user content) but
                                 ;;     never push nil from org.
                                 (let* ((vals      (org-apple-reminders--org-item-values))
                                        (apple-mod-prop (org-entry-get nil "REMINDER_APPLE_MOD"))
                                        (org-mod-prop   (org-entry-get nil "REMINDER_ORG_MOD"))
                                        (org-changed   (and org-mod-prop apple-mod-prop
                                                            (string> org-mod-prop apple-mod-prop)))
                                        (apple-values (org-apple-reminders--apple-field-values apple)))
                                   (if org-changed
                                       ;; ORG-WINS: push all diffs including
                                       ;; nils (Bug-1 fix means clearing Apple's
                                       ;; dueDate via EventKit now works).
                                       (let ((needs-push
                                              (org-apple-reminders--org-push-needed-p
                                               vals apple-values t)))
                                         (when needs-push
                                           (let ((new-mod (org-apple-reminders--update-in-apple rlist id vals)))
                                             (when (stringp new-mod)
                                               (org-set-property "REMINDER_ORG_MOD" new-mod)))
                                           (setq n-updated (1+ n-updated))))
                                     ;; NEITHER NEWER: backfill missing org
                                     ;; fields, push non-nil org diffs only.
                                     (let* ((did-bf (org-apple-reminders--backfill-from-apple apple-values)))
                                       ;; Recompute vals after backfills, then
                                       ;; check for any non-nil push needs.
                                       (let* ((vals2 (if did-bf
                                                         (org-apple-reminders--org-item-values)
                                                       vals))
                                              (needs-push
                                               (org-apple-reminders--org-push-needed-p
                                                vals2 apple-values nil)))
                                         (when needs-push
                                           (let ((new-mod (org-apple-reminders--update-in-apple
                                                           rlist id vals2)))
                                             (when (stringp new-mod)
                                               (org-set-property "REMINDER_ORG_MOD" new-mod))))
                                         (when (or did-bf needs-push)
                                           (when (stringp a-mod)
                                             (org-set-property "REMINDER_APPLE_MOD" a-mod))
                                           (setq n-updated (1+ n-updated))))))))))))))))
                   nil nil)
                  (dolist (m (org-apple-reminders--markers-deepest-first cancel-pts))
                    (when (marker-position m)
                      (goto-char m)
                      (let ((kind (org-apple-reminders--finalize-cancelled-at-point)))
                        (when kind
                          (setq n-deleted (1+ n-deleted)))))
                    (set-marker m nil))
                  (dolist (m (org-apple-reminders--markers-deepest-first delete-org-pts))
                    (when (marker-position m)
                      (goto-char m)
                      (org-apple-reminders--delete-org-subtree-at-point)
                      (setq n-deleted (1+ n-deleted)))
                    (set-marker m nil))
                  (dolist (m (nreverse done-pts))
                    (goto-char m) (push (point-marker) changed-positions)
                    (org-todo "DONE") (set-marker m nil)
                    (setq n-done (1+ n-done)))
                  (dolist (m (nreverse new-pts))
                    (goto-char m) (push (point-marker) changed-positions)
                    (let ((rlist (org-apple-reminders--target-list-at-point default-list)))
                      (when (and rlist
                                 (org-apple-reminders--list-included-p rlist)
                                 (org-apple-reminders--ensure-list rlist))
                        (let ((new-id (org-apple-reminders--create-in-apple
                                       rlist (org-apple-reminders--org-item-values))))
                          (when new-id
                            (org-set-property "REMINDER_ID"   new-id)
                            (org-set-property "REMINDER_LIST" rlist)
                            (puthash new-id (or (buffer-file-name) sync-file) id-index)
                            (setq n-pushed (1+ n-pushed)))))))
                  (dolist (upd (nreverse apple-updates))
                    (cl-destructuring-bind (m apple-values) upd
                      (goto-char m) (push (point-marker) changed-positions)
                      (org-apple-reminders--apply-apple-field-values apple-values)
                      (setq n-updated (1+ n-updated))
                      (set-marker m nil)))
                  ;; Progress cookies only in sync-file (uses * ListName structure)
                  (when is-sync-file
                    (org-apple-reminders--ensure-list-cookies))
                  (save-buffer)
                  (dolist (m (nreverse changed-positions))
                    (when (marker-position m)
                      (goto-char m) (org-reveal) (set-marker m nil)))))))
    (cl-incf (org-apple-reminders--counts-done counts) n-done)
    (cl-incf (org-apple-reminders--counts-pushed counts) n-pushed)
    (cl-incf (org-apple-reminders--counts-updated counts) n-updated)
    (cl-incf (org-apple-reminders--counts-deleted counts) n-deleted)))

(defun org-apple-reminders--sync-pull-new (snapshot counts)
  "Phase 2: prune excluded lists and pull new Apple items into the sync file."
  (let ((sync-file (expand-file-name org-apple-reminders-sync-file))
        (data (org-apple-reminders--snapshot-data snapshot))
        (id-index (org-apple-reminders--snapshot-id-index snapshot))
        (n-pruned 0) (n-deleted 0) (n-pulled 0))
      (with-current-buffer (find-file-noselect sync-file)
        (org-save-outline-visibility t
          (let (changed-positions)
            ;; Drop sections for lists removed from the included-lists set
            ;; so reminders.org keeps mirroring the current selection.
            (setq n-pruned (org-apple-reminders--prune-excluded-lists))
            ;; Ensure active local list sections exist in Apple.  This runs
            ;; after deletion detection so Apple-side deletions become DONE
            ;; markers instead of being immediately recreated.
            (org-apple-reminders--ensure-known-file-lists)
            ;; Ensure every explicitly-included list has a `* List' section,
            ;; even when it is empty, so the selection is mirrored exactly.
            (let ((included (org-apple-reminders--effective-included-lists)))
              (when included
                (dolist (lname included)
                  (unless (org-apple-reminders--done-list-section-exists-p lname)
                    (save-excursion
                      (org-apple-reminders--goto-list-heading lname))))))
            (dolist (entry data)
              (let ((lname (alist-get 'list  entry))
                    (items (alist-get 'items entry)))
                (when (org-apple-reminders--list-included-p lname)
                  (dolist (item items)
                    (let ((id (alist-get 'id item)))
                      (when (not (gethash id id-index))
                        (if (org-apple-reminders--apple-item-completed-p item)
                            (progn
                              (org-apple-reminders--delete-in-apple lname id)
                              (setq n-deleted (1+ n-deleted)))
                          (org-apple-reminders--goto-list-heading lname)
                          (org-apple-reminders--stamp-list-section lname entry)
                          (push (point-marker) changed-positions)
                          (org-apple-reminders--insert-org-heading item lname)
                          (save-excursion
                            (org-back-to-heading t)
                            (let ((md (alist-get 'modDate item)))
                              (when (stringp md)
                                (org-set-property "REMINDER_APPLE_MOD" md))))
                          (puthash id sync-file id-index)
                          (setq n-pulled (1+ n-pulled)))))))))
            ;; Keep a blank line before every list heading, then recalculate
            ;; the [N/M] progress cookies — freshly pulled items (and new
            ;; list headings) leave them stale until now.
            (org-apple-reminders--normalize-list-spacing)
            (ignore-errors (org-update-statistics-cookies t))
            (when (buffer-modified-p)
              (save-buffer)
              (dolist (m (nreverse changed-positions))
                (when (marker-position m)
                  (goto-char m) (org-reveal) (set-marker m nil)))))))
    (setf (org-apple-reminders--counts-pruned counts) n-pruned)
    (cl-incf (org-apple-reminders--counts-deleted counts) n-deleted)
    (cl-incf (org-apple-reminders--counts-pulled counts) n-pulled)))

(defun org-apple-reminders--pull-reconcile-file (file snapshot)
  "Background-pull reconciliation for FILE against SNAPSHOT (non-destructive)."
  (let ((sync-file (expand-file-name org-apple-reminders-sync-file))
        (apple-by-id (org-apple-reminders--snapshot-by-id snapshot))
        (data (org-apple-reminders--snapshot-data snapshot))
        (id-index (org-apple-reminders--snapshot-id-index snapshot))
        (previous-list-names (org-apple-reminders--snapshot-previous-lists snapshot))
        (apple-list-names (org-apple-reminders--snapshot-list-names snapshot))
        (apple-list-ids (org-apple-reminders--snapshot-list-ids snapshot)))
                   (let ((is-sync-file (string= (expand-file-name file) sync-file)))
                     (with-current-buffer (find-file-noselect file)
                       (org-save-outline-visibility t
                         (let (done-pts field-updates)
                           (when is-sync-file
                             (org-apple-reminders--mark-missing-apple-lists-done
                              previous-list-names apple-list-names apple-list-ids))
                           (org-map-entries
                            (lambda ()
                              (let* ((id (org-entry-get nil "REMINDER_ID"))
                                     (state (org-get-todo-state))
                                     (apple (and id (gethash id apple-by-id))))
                                (when (and id
                                           (not (org-entry-get nil "REMINDER_DELETE"))
                                           (org-apple-reminders--active-heading-state-p state)
                                           (or (null apple)
                                               (org-apple-reminders--apple-item-completed-p apple)))
                                  (push (point-marker) done-pts))))
                            nil nil)
                           (dolist (m (nreverse done-pts))
                             (goto-char m)
                             (org-todo "DONE")
                             (set-marker m nil))
                           (org-map-entries
                            (lambda ()
                              (let* ((id (org-entry-get nil "REMINDER_ID"))
                                     (item (and id (gethash id apple-by-id))))
                                (when (and item
                                           (not (org-entry-get nil "REMINDER_DELETE"))
                                           (not (org-apple-reminders--apple-item-completed-p item))
                                           (org-apple-reminders--active-heading-state-p
                                            (org-get-todo-state)))
                                  (let* ((apple-values (org-apple-reminders--apple-field-values item))
                                         (org-values (org-apple-reminders--current-org-field-values))
                                         (a-mod (alist-get 'mod-date apple-values))
                                         (last-known (org-apple-reminders--last-known-mod))
                                         (apple-changed
                                          (and a-mod
                                               (or (null last-known)
                                                   (string> a-mod last-known)))))
                                    (when apple-changed
                                      (if (org-apple-reminders--field-values-differ-p
                                           apple-values org-values)
                                          (push (list (point-marker) apple-values) field-updates)
                                        (org-set-property "REMINDER_APPLE_MOD" a-mod)))))))
                            nil nil)
                           (dolist (update (nreverse field-updates))
                             (cl-destructuring-bind (marker apple-values) update
                               (goto-char marker)
                               (org-apple-reminders--apply-apple-field-values apple-values)
                               (set-marker marker nil)))
                           (when is-sync-file
                             (dolist (entry data)
                               (let ((list-name (alist-get 'list entry))
                                     (items (alist-get 'items entry)))
                                 (when (org-apple-reminders--list-included-p list-name)
                                   (dolist (item items)
                                     (let ((id (alist-get 'id item)))
                                       (when (and (not (gethash id id-index))
                                                  (not (org-apple-reminders--apple-item-completed-p item)))
                                         (org-apple-reminders--goto-list-heading list-name)
                                         (org-apple-reminders--stamp-list-section list-name entry)
                                         (org-apple-reminders--insert-org-heading item list-name)
                                         (save-excursion
                                           (org-back-to-heading t)
                                           (when-let ((mod-date (alist-get 'modDate item)))
                                             (when (stringp mod-date)
                                               (org-set-property "REMINDER_APPLE_MOD" mod-date))))
                                         (puthash id sync-file id-index))))))))
                           (when is-sync-file
                             (org-apple-reminders--ensure-list-cookies))
                           (save-buffer)))))))

(defun org-apple-reminders--redo-agenda-buffers ()
  "Redisplay any live org-agenda buffers after a background pull."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'org-agenda-mode)
          (let ((inhibit-message t))
            (ignore-errors (org-agenda-redo))))))))

(defun org-apple-reminders--push-update-linked-entries (counts)
  "Update changed linked entries in the current buffer; return new-item markers.
Tally updates into COUNTS."
  (let ((n-updated 0) new-pts)
      (org-map-entries
       (lambda ()
         (let* ((id     (org-entry-get nil "REMINDER_ID"))
                (rlist  (org-apple-reminders--target-list-at-point))
                (state  (org-get-todo-state))
                (cached (and id (org-apple-reminders--find-in-cache id))))
           (cond
            ((org-entry-get nil "REMINDER_DELETE")
             nil)
            ((and (null id) rlist
                  (org-apple-reminders--auto-create-reminder-heading-p state))
             (push (point-marker) new-pts))
            ((and id rlist (org-apple-reminders--todo-done-p state))
             (when (and cached
                        (not (org-apple-reminders--apple-item-completed-p cached)))
               (org-apple-reminders--complete-in-apple rlist id)))
            ((and id rlist (org-apple-reminders--active-heading-state-p state))
             (let* ((vals (org-apple-reminders--org-item-values))
                    (cached-values (and cached
                                        (org-apple-reminders--apple-field-values cached)))
                    (needs-push
                     (or (null cached)
                         (org-apple-reminders--org-push-needed-p
                          vals cached-values t))))
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
    (cl-incf (org-apple-reminders--counts-updated counts) n-updated)
    new-pts))

(defun org-apple-reminders--push-create-new-entries (new-pts counts)
  "Create Apple reminders for NEW-PTS markers; tally into COUNTS."
  (let ((n-new 0))
      (when new-pts
        (let ((default-list (or org-apple-reminders-sync-list
                                (org-apple-reminders--default-list))))
          (dolist (m (nreverse new-pts))
            (goto-char m)
            (let ((list-name (org-apple-reminders--target-list-at-point default-list)))
              (when (and list-name (not (org-apple-reminders--list-included-p list-name)))
                (setq list-name nil))
              (when list-name
                (when (org-apple-reminders--ensure-list list-name)
                  (when-let (new-id (org-apple-reminders--create-in-apple
                                     list-name (org-apple-reminders--org-item-values)))
                    (org-set-property "REMINDER_ID"   new-id)
                    (org-set-property "REMINDER_LIST" list-name)
                    (setq n-new (1+ n-new)))))))))
    (cl-incf (org-apple-reminders--counts-pushed counts) n-new)))

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

(defun org-apple-reminders--autosave-known-buffers ()
  "Save any modified buffer that visits a known reminder file.
Saving triggers `after-save-hook' → `--on-save' → `--push-to-apple',
which runs asynchronous JXA pushes for pending edits.  Callers should
follow this with `--wait-for-async-jxa' before reading Apple state."
  (dolist (file (org-apple-reminders--known-files))
    (when (file-exists-p file)
      (let ((buf (find-buffer-visiting file)))
        (when (and buf (buffer-modified-p buf))
          (with-current-buffer buf
            (save-buffer)))))))

(defun org-apple-reminders--wait-for-async-jxa (&optional max-seconds)
  "Block until every in-flight JXA process spawned by this package finishes.
MAX-SECONDS bounds the wait (default 10).  Processes are matched by
the `org-ar-jxa' prefix that `--jxa-async' uses for `make-process'."
  (let ((deadline (+ (float-time) (or max-seconds 10))))
    (while (and (< (float-time) deadline)
                (cl-some (lambda (proc)
                           (string-prefix-p "org-ar-jxa" (process-name proc)))
                         (process-list)))
      (accept-process-output nil 0.1))))

;;; Diagnostics

(defun org-apple-reminders--source-directory ()
  "Return the package source directory for the loaded file when possible."
  (when-let* ((file (or load-file-name
                        (locate-library "org-apple-reminders")))
              (dir (file-name-directory (file-truename file))))
    (if-let* ((builds-dir (file-name-directory (directory-file-name dir)))
              ((string= (file-name-nondirectory (directory-file-name dir))
                        "org-apple-reminders"))
              ((string= (file-name-nondirectory (directory-file-name builds-dir))
                        "builds")))
        (let ((source-dir (expand-file-name
                           "../sources/org-apple-reminders/"
                           builds-dir)))
          (if (file-directory-p source-dir) source-dir dir))
      dir)))

(defun org-apple-reminders--git-description (directory)
  "Return \"branch commit\" for DIRECTORY, or nil when unavailable."
  (when (and directory (executable-find "git"))
    (let* ((default-directory directory)
           (branch (string-trim
                    (or (ignore-errors
                          (shell-command-to-string
                           "git branch --show-current 2>/dev/null"))
                        "")))
           (commit (string-trim
                    (or (ignore-errors
                          (shell-command-to-string
                           "git rev-parse --short HEAD 2>/dev/null"))
                        ""))))
      (unless (or (string-empty-p branch)
                  (string-empty-p commit))
        (format "%s %s" branch commit)))))

(defun org-apple-reminders--loaded-message ()
  "Log the loaded org-apple-reminders source and Git revision when available."
  (let* ((source-dir (org-apple-reminders--source-directory))
         (git-desc (org-apple-reminders--git-description source-dir)))
    (message "org-apple-reminders loaded from %s%s"
             (or source-dir "unknown location")
             (if git-desc
                 (format " (%s)" git-desc)
               ""))))

;;;###autoload

(defun org-apple-reminders--loc-at-point ()
  "Return (list-name . reminder-id) for reminder heading at point, or nil."
  (ignore-errors
    (save-excursion
      (org-back-to-heading t)
      (let ((id   (org-entry-get nil "REMINDER_ID"))
            (list (org-entry-get nil "REMINDER_LIST")))
        (when (and id list) (cons list id))))))


(defvar-local org-apple-reminders--delete-mark-overlays nil
  "Display overlays showing REMINDER_DELETE headings in the current buffer.")

(defun org-apple-reminders--clear-delete-mark-overlays ()
  "Remove all delete-mark visibility overlays from the current buffer."
  (mapc #'delete-overlay org-apple-reminders--delete-mark-overlays)
  (setq org-apple-reminders--delete-mark-overlays nil))

(defun org-apple-reminders--delete-prefix-string ()
  "Return the propertized display-only delete marker prefix."
  (propertize org-apple-reminders-delete-mark-prefix
              'face 'org-apple-reminders-delete-mark-prefix-face))

(defun org-apple-reminders--add-delete-mark-overlay (beg end)
  "Add a visible delete marker overlay from BEG to END."
  (let ((ov (make-overlay beg end nil nil t)))
    (overlay-put ov 'org-apple-reminders-delete-mark t)
    (overlay-put ov 'face 'org-apple-reminders-delete-mark-face)
    (overlay-put ov 'before-string
                 (org-apple-reminders--delete-prefix-string))
    (push ov org-apple-reminders--delete-mark-overlays)))

(defun org-apple-reminders--entry-delete-marked-p (&optional marker)
  "Return non-nil when MARKER or point is on a REMINDER_DELETE heading."
  (if marker
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (ignore-errors
            (org-back-to-heading t)
            (org-entry-get nil "REMINDER_DELETE"))))
    (save-excursion
      (ignore-errors
        (org-back-to-heading t)
        (org-entry-get nil "REMINDER_DELETE")))))

(defun org-apple-reminders-refresh-delete-mark-visibility ()
  "Refresh display-only markers for headings marked REMINDER_DELETE=t.
In org buffers this marks the heading line itself.  In org-agenda buffers
this marks agenda rows whose source heading carries REMINDER_DELETE=t."
  (interactive)
  (org-apple-reminders--clear-delete-mark-overlays)
  (cond
   ((derived-mode-p 'org-mode)
    (org-with-wide-buffer
     (save-excursion
       (goto-char (point-min))
       (while (re-search-forward org-heading-regexp nil t)
         (let ((line-beg (line-beginning-position))
               (line-end (line-end-position)))
           (goto-char line-beg)
           (when (org-entry-get nil "REMINDER_DELETE")
             (org-apple-reminders--add-delete-mark-overlay line-beg line-end))
           (forward-line 1))))))
   ((derived-mode-p 'org-agenda-mode)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((line-beg (line-beginning-position))
               (line-end (line-end-position))
               (marker (or (get-text-property line-beg 'org-marker)
                           (get-text-property line-beg 'org-hd-marker))))
          (when (and (markerp marker)
                     (marker-buffer marker)
                     (with-current-buffer (marker-buffer marker)
                       (org-apple-reminders--entry-delete-marked-p marker)))
            (org-apple-reminders--add-delete-mark-overlay line-beg line-end)))
        (forward-line 1))))))

(defun org-apple-reminders--refresh-delete-mark-visibility-maybe ()
  "Refresh delete-mark overlays when the current buffer is Org or agenda."
  (when (derived-mode-p 'org-mode 'org-agenda-mode)
    (org-apple-reminders-refresh-delete-mark-visibility)))


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
              (insert org-apple-reminders--sync-file-template)))
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


(defvar org-apple-reminders-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "R") #'org-apple-reminders-sync)
    (define-key map (kbd "f") #'org-apple-reminders-open-file)
    (define-key map (kbd "l") #'org-apple-reminders-show-lists)
    (define-key map (kbd "L") #'org-apple-reminders-create-list)
    (define-key map (kbd "X") #'org-apple-reminders-delete-list)
    (define-key map (kbd "i") #'org-apple-reminders-set-included-lists)
    (define-key map (kbd "p") #'org-apple-reminders-push-heading)
    ;; `m' is kept as an alias for `p' — push handles single headings and
    ;; regions, so a separate "move" command is no longer needed.
    (define-key map (kbd "m") #'org-apple-reminders-push-heading)
    (define-key map (kbd "x") #'org-apple-reminders-mark-for-delete)
    (define-key map (kbd "u") #'org-apple-reminders-unmark-delete)
    (define-key map (kbd "d") #'org-apple-reminders-remove-from-apple)
    (define-key map (kbd "D") #'org-apple-reminders-delete-reminder)
    map)
  "Keymap for `org-apple-reminders' commands.
`org-apple-reminders-setup' binds this under
`org-apple-reminders-keymap-prefix' (default \"C-c r\").  Keys
`p' and `m' both run `org-apple-reminders-push-heading' (single
heading or active region).  The heading commands (p/m/x/u/d/D)
`user-error' when there is nothing to act on, so the whole map is
safe to bind globally.")
;; Allow the variable to be used directly as a prefix key.
(fset 'org-apple-reminders-command-map org-apple-reminders-command-map)


(defun org-apple-reminders--on-todo-state-change ()
  "Instantly sync org TODO state change to Apple Reminders via REMINDER_ID."
  (unless org-apple-reminders--syncing
    (let ((id   (org-entry-get nil "REMINDER_ID"))
          (list (org-entry-get nil "REMINDER_LIST")))
      (when (and id list)
        (cond
         ((equal org-state "DONE")
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

(defun org-apple-reminders-delete-list (name)
  "Delete the Apple Reminders list NAME and mark its sync section DONE.
All reminders in the list are removed from Apple.  The matching
`* NAME' section in `org-apple-reminders-sync-file' is kept and marked
DONE so the next sync does not recreate the list."
  (interactive
   (list (completing-read "Delete which list: "
                          (or (org-apple-reminders--cached-list-names)
                              (org-apple-reminders-lists))
                          nil t)))
  (when (string-empty-p (string-trim name))
    (user-error "List name cannot be empty"))
  (unless (yes-or-no-p
           (format "Delete list \"%s\" and ALL its reminders from Apple and org? "
                   name))
    (user-error "Aborted"))
  (org-apple-reminders--jxa-run
   (format "Application('Reminders').lists.byName(%s).delete();"
           (json-encode name)))
  (setq org-apple-reminders--cache
        (cl-remove name org-apple-reminders--cache
                   :key (lambda (e) (alist-get 'list e))
                   :test #'string=))
  (let ((file (expand-file-name org-apple-reminders-sync-file)))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (let ((org-apple-reminders--syncing t))
          (save-excursion
            (org-map-entries
             (lambda ()
               (let ((section-name (org-apple-reminders--clean-list-heading
                                    (org-get-heading t t t t))))
                 (when (string= section-name name)
                   (unless (member (org-get-todo-state) '("DONE" "CANCELLED"))
                     (org-todo "DONE")))))
             "LEVEL=1" 'file)
            (save-buffer))))))
  (message "Deleted list: %s" name))

(defun org-apple-reminders-set-included-lists ()
  "Choose which Apple lists sync into org and save the choice permanently.
Multi-select: every list you pick is included; the rest are excluded.
Pick none to include all lists.  The choice is stored in `custom-file'
via `org-apple-reminders-saved-included-lists', so it survives restarts.

When `org-apple-reminders-included-lists-prefer-config' is non-nil the
config value stays authoritative — the choice is still saved but does
not take effect until that option is set back to nil."
  (interactive)
  ;; Query Apple for the live list names — the cache can be stale and would
  ;; then hide lists created since the last sync (so they could never be
  ;; picked).  Fall back to the cache only if the query fails.
  (let* ((all     (or (org-apple-reminders-lists)
                      (org-apple-reminders--cached-list-names)))
         (current (let ((e (org-apple-reminders--effective-included-lists)))
                    (and (listp e) e)))
         (picked  (delete "" (completing-read-multiple
                              "Sync these lists (empty = all): "
                              all nil t
                              (and current
                                   (mapconcat #'identity current ",")))))
         (value   (if (or (null picked)
                          (null (cl-set-difference all picked :test #'string=)))
                      nil
                    picked)))
    (customize-save-variable 'org-apple-reminders-saved-included-lists value)
    (if org-apple-reminders-included-lists-prefer-config
        (message
         "Saved %s — but prefer-config is on, so the config list stays live."
         (if value (string-join value ", ") "all lists"))
      (message "Now syncing: %s"
               (if value (string-join value ", ") "all lists")))))

;;;###autoload

(defun org-apple-reminders-open-file ()
  "Open `org-apple-reminders-sync-file' in the current window."
  (interactive)
  (find-file (expand-file-name org-apple-reminders-sync-file)))

;;; Field helpers

(defun org-apple-reminders-push-heading (&optional list-name beg end)
  "Push the org heading at point to Apple Reminders in the chosen list.

With an active region, every heading in the region is pushed instead of
just the one at point.

For each heading: an unlinked heading gets a new reminder created; a heading
already linked to the chosen list is updated in place; a heading linked to a
different list is MOVED — the old Apple reminder is deleted and recreated in
the new list, never duplicated.

When a moved heading lives in `org-apple-reminders-sync-file' its subtree is
relocated under the new `* List' heading; in any other org file the heading
keeps its place and only its properties change, so the surrounding document
structure is left intact.

In a region, only linked reminders and open TODO/NEXT/WAITING tasks are
processed; other headings are skipped.  The chosen list is created in Apple
Reminders if it does not exist yet.

Non-interactively, LIST-NAME is the target Apple Reminders list; BEG and END
delimit the region to process (both nil ⇒ act on the heading at point)."
  (interactive
   (let ((lists (or (org-apple-reminders--cached-list-names)
                    (org-apple-reminders-lists))))
     ;; Capture the region bounds now — they must not depend on the mark
     ;; still being active after the `completing-read' prompt.
     (list (completing-read "List: " lists nil nil)
           (and (use-region-p) (region-beginning))
           (and (use-region-p) (region-end)))))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let ((target (string-trim (or list-name
                                 (org-apple-reminders--default-list)
                                 ""))))
    (when (string-empty-p target)
      (user-error "List name cannot be empty"))
    (unless (org-apple-reminders--ensure-list target)
      (user-error "Could not create or find Apple list \"%s\"" target))
    (if (and beg end)
        ;; --- Multiple headings in the selected region ---
        (let* ((r   (org-apple-reminders--push-region beg end target))
               (reg (plist-get r :registered)))
          (message "Pushed to [%s]: %d created, %d updated, %d moved%s%s%s"
                   target
                   (plist-get r :created) (plist-get r :updated)
                   (plist-get r :moved)
                   (let ((s (plist-get r :skipped)))
                     (if (> s 0) (format "; %d skipped" s) ""))
                   (let ((f (plist-get r :failed)))
                     (if (> f 0) (format "; %d failed" f) ""))
                   (if reg (format "  [registered %s]" reg) "")))
      ;; --- Single heading at point ---
      (let* ((org-apple-reminders--syncing t)
             (in-sync (org-apple-reminders--in-sync-file-p))
             (title   (org-get-heading t t t t))
             (res     (org-apple-reminders--push-heading-1 target))
             (status  (car res))
             (reloc   (cdr res))
             (reg     (and (eq status 'created)
                           (org-apple-reminders--register-current-file))))
        (when (eq status 'failed)
          (user-error "Could not push \"%s\" to list \"%s\"" title target))
        (if (and reloc in-sync)
            (org-apple-reminders--relocate-subtree-to-list target)
          (when (and (buffer-file-name) (buffer-modified-p)) (save-buffer)))
        (message "%s [%s]: %s%s"
                 (pcase status
                   ('created "Pushed to Apple Reminders")
                   ('updated "Updated in Apple Reminders")
                   ('moved   (if in-sync "Moved in Apple + reminders.org"
                               "Moved in Apple (heading kept in place)")))
                 target title
                 (if reg (format "  [registered %s]" reg) ""))))))

(defun org-apple-reminders-mark-for-delete (&optional beg end)
  "Mark reminder heading(s) for deletion on the next full sync.
Set REMINDER_DELETE=t on the linked reminder at point, or on every linked
reminder in the active region.  The next `org-apple-reminders-sync' (`C-c r R')
deletes those Apple reminders in a batch, marks the org headings DONE, strips
their REMINDER_* link properties, and leaves REMINDER_NOSYNC=t so they are not
created again."
  (interactive
   (list (and (use-region-p) (region-beginning))
         (and (use-region-p) (region-end))))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let ((markers (if (and beg end)
                     (org-apple-reminders--region-reminder-markers beg end)
                   (save-excursion
                     (org-back-to-heading t)
                     (when (org-entry-get nil "REMINDER_ID")
                       (list (point-marker)))))))
    (unless markers
      (user-error "No linked reminders to mark"))
    (dolist (m markers)
      (when (marker-buffer m)
        (with-current-buffer (marker-buffer m)
          (save-excursion
            (goto-char m)
            (org-set-property "REMINDER_DELETE" "t"))))
      (set-marker m nil))
    (org-apple-reminders-refresh-delete-mark-visibility)
    (when (and (buffer-file-name) (buffer-modified-p))
      (save-buffer))
    (message "Marked %d reminder%s for deletion on next C-c r R"
             (length markers) (if (= (length markers) 1) "" "s"))))

;;;###autoload

(defun org-apple-reminders-unmark-delete (&optional beg end)
  "Remove REMINDER_DELETE from reminder heading(s).
With an active region, unmark every linked reminder in the region.  Without a
region, unmark the linked reminder at point."
  (interactive
   (list (and (use-region-p) (region-beginning))
         (and (use-region-p) (region-end))))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let ((markers (if (and beg end)
                     (org-apple-reminders--region-reminder-markers beg end)
                   (save-excursion
                     (org-back-to-heading t)
                     (when (org-entry-get nil "REMINDER_ID")
                       (list (point-marker)))))))
    (unless markers
      (user-error "No linked reminders to unmark"))
    (dolist (m markers)
      (when (marker-buffer m)
        (with-current-buffer (marker-buffer m)
          (save-excursion
            (goto-char m)
            (org-entry-delete nil "REMINDER_DELETE"))))
      (set-marker m nil))
    (org-apple-reminders-refresh-delete-mark-visibility)
    (when (and (buffer-file-name) (buffer-modified-p))
      (save-buffer))
    (message "Removed delete mark from %d reminder%s"
             (length markers) (if (= (length markers) 1) "" "s"))))

;;;###autoload

(defun org-apple-reminders-delete-reminder (&optional beg end)
  "Delete the reminder(s) from Apple and mark the linked org heading(s) DONE.

The Apple reminder is removed permanently from Apple Reminders.  The
linked org heading is kept and marked DONE — both at point and in any
other known org file (`org-apple-reminders-sync-file',
`org-apple-reminders-extra-files', any `org-agenda-files') that contains
the same REMINDER_ID.  The heading's `REMINDER_*' link properties are
stripped and `REMINDER_NOSYNC' is set, so the heading is never pushed
back to Apple.  You can delete the DONE heading manually later if you
want.

This is the destructive-Apple, gentle-org command.  The sibling
`org-apple-reminders-remove-from-apple' is identical on the Apple side
but leaves the org heading as a plain TODO instead of marking it DONE.

With an active region, every linked reminder in the region is processed.
Without a region, only the heading at point.

Non-interactively, BEG and END delimit the region to act on (both nil ⇒
act on the heading at point)."
  (interactive
   (list (and (use-region-p) (region-beginning))
         (and (use-region-p) (region-end))))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (if (and beg end)
      ;; --- Region: every selected reminder ---
      (let ((markers (org-apple-reminders--region-reminder-markers beg end)))
        (unless markers
          (user-error "No reminders in the selected region"))
        (unless (yes-or-no-p
                 (format
                  "Delete %d reminder%s from Apple and mark org DONE? "
                  (length markers)
                  (if (= (length markers) 1) "" "s")))
          (user-error "Aborted"))
        (let ((org-apple-reminders--syncing t)
              (ids nil) (n 0))
          (dolist (m markers)
            (when (marker-buffer m)
              (save-excursion
                (goto-char m)
                (when-let ((loc (org-apple-reminders--unlink-apple-at-point)))
                  (push (cdr loc) ids)
                  (org-apple-reminders--mark-done-at-point)
                  (org-apple-reminders--strip-link-properties)
                  (setq n (1+ n)))))
            (set-marker m nil))
          (org-apple-reminders--mark-done-in-other-known-files ids)
          (when (and (buffer-file-name) (buffer-modified-p)) (save-buffer))
          (message "Deleted %d from Apple, marked DONE in org%s"
                   n (if (= n (length markers)) ""
                       (format " (%d failed)"
                               (- (length markers) n))))))
    ;; --- Single heading ---
    (let ((loc (org-apple-reminders--loc-at-point)))
      (unless loc (user-error "No reminder at point"))
      (let ((title (save-excursion (org-back-to-heading t)
                                   (org-get-heading t t t t))))
        (unless (yes-or-no-p
                 (format "Delete \"%s\" from Apple, mark org DONE? " title))
          (user-error "Aborted"))
        (let ((org-apple-reminders--syncing t))
          (when (org-apple-reminders--unlink-apple-at-point)
            (org-apple-reminders--mark-done-at-point)
            (org-apple-reminders--strip-link-properties)
            (org-apple-reminders--mark-done-in-other-known-files
             (list (cdr loc))))
          (when (and (buffer-file-name) (buffer-modified-p)) (save-buffer)))
        (message "Deleted from Apple, marked DONE in org: %s" title)))))

;;;###autoload

(defun org-apple-reminders-remove-from-apple (&optional beg end)
  "Delete the reminder at point from Apple Reminders but keep the org heading.

With an active region, do this for every reminder in the region instead.
Each heading stays in the org file as an ordinary TODO; its REMINDER_ID,
REMINDER_LIST and modification-timestamp properties are removed and a
REMINDER_NOSYNC property is set so it is never pushed back to Apple.  Use
this to stop syncing a task without losing it.  Re-link it later with
`org-apple-reminders-push-heading'.

Non-interactively, BEG and END delimit the region to act on (both nil ⇒ act
on the heading at point)."
  (interactive
   (list (and (use-region-p) (region-beginning))
         (and (use-region-p) (region-end))))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (if (and beg end)
      ;; --- Region: unlink every selected reminder ---
      (let ((markers (org-apple-reminders--region-reminder-markers beg end)))
        (unless markers
          (user-error "No reminders in the selected region"))
        (unless (yes-or-no-p
                 (format
                  "Remove %d reminder%s from Apple Reminders (keep org headings)? "
                  (length markers)
                  (if (= (length markers) 1) "" "s")))
          (user-error "Aborted"))
        (let ((org-apple-reminders--syncing t) (n 0))
          (dolist (m markers)
            (when (marker-buffer m)
              (save-excursion
                (goto-char m)
                (when (org-apple-reminders--unlink-apple-at-point)
                  (org-apple-reminders--strip-link-properties)
                  (setq n (1+ n)))))
            (set-marker m nil))
          (when (and (buffer-file-name) (buffer-modified-p)) (save-buffer))
          (message "Removed %d reminder%s from Apple, kept in org"
                   n (if (= n 1) "" "s"))))
    ;; --- Single heading ---
    (let ((loc (org-apple-reminders--loc-at-point)))
      (unless loc (user-error "No reminder at point"))
      (let ((title (save-excursion (org-back-to-heading t)
                                   (org-get-heading t t t t))))
        (unless (yes-or-no-p
                 (format "Remove \"%s\" from Apple Reminders (keep org heading)? "
                         title))
          (user-error "Aborted"))
        (org-apple-reminders--unlink-apple-at-point)
        (let ((org-apple-reminders--syncing t))
          (org-apple-reminders--strip-link-properties)
          (when (buffer-file-name) (save-buffer)))
        (message "Removed from Apple, kept in org: %s" title)))))

;;; Live hooks: TODO state, priority, deadline, tags

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

;;; Keymap

;;;###autoload
(defun org-apple-reminders-sync ()
  "Full bidirectional sync across all known org files ↔ Apple Reminders.

Known files: `org-apple-reminders-sync-file', `org-apple-reminders-extra-files',
and .org files in `org-agenda-files'.  See the attic implementation's docstring
for the full per-heading conflict-resolution table; the resolution itself now
lives in the model layer (`org-apple-reminders--conflict-direction')."
  (interactive)
  (message "Reminders: syncing…")
  (org-apple-reminders--with-known-files-cache
    (org-apple-reminders--autosave-known-buffers)
    (org-apple-reminders--wait-for-async-jxa)
    (let ((snapshot (org-apple-reminders--fetch-snapshot))
          (counts   (org-apple-reminders--counts-create)))
      (org-apple-reminders--sync-reconcile-list-sections snapshot counts)
      (let ((org-apple-reminders--syncing t))
        (org-apple-reminders--sync-delete-marked snapshot counts)
        (dolist (file (org-apple-reminders--known-files))
          (when (file-exists-p file)
            (org-apple-reminders--sync-reconcile-file file snapshot counts)))
        (org-apple-reminders--sync-pull-new snapshot counts))
      (when (> (org-apple-reminders--counts-deleted counts) 0)
        (org-apple-reminders--wait-for-async-jxa))
      (org-apple-reminders--report-counts counts))))

(defun org-apple-reminders--background-pull ()
  "Async pull: refresh cache and all known org files from Apple Reminders."
  (unless org-apple-reminders--syncing
    (org-apple-reminders--jxa-async
     org-apple-reminders--fetch-script
     (lambda (raw)
       (ignore-errors
         (org-apple-reminders--with-known-files-cache
           (let ((snapshot (org-apple-reminders--snapshot-from-json raw)))
             (org-apple-reminders--write-agenda-file
              (org-apple-reminders--snapshot-data snapshot))
             (let ((org-apple-reminders--syncing t))
               (dolist (file (org-apple-reminders--known-files))
                 (when (file-exists-p file)
                   (org-apple-reminders--pull-reconcile-file file snapshot)))
               (org-apple-reminders--redo-agenda-buffers)))))))))

(defun org-apple-reminders--push-to-apple ()
  "Push changed org entries to Apple.  New items get REMINDER_ID stamped back."
  (org-apple-reminders--with-known-files-cache
    (when (org-apple-reminders--in-known-file-p)
      (org-apple-reminders--ensure-known-file-lists))
    (let* ((counts  (org-apple-reminders--counts-create))
           (new-pts (org-apple-reminders--push-update-linked-entries counts)))
      (org-apple-reminders--push-create-new-entries new-pts counts)
      (when (or (> (org-apple-reminders--counts-pushed counts) 0)
                (> (org-apple-reminders--counts-updated counts) 0))
        (message "Reminders push: %d new, %d updated."
                 (org-apple-reminders--counts-pushed counts)
                 (org-apple-reminders--counts-updated counts))))))

(defun org-apple-reminders--on-save ()
  "Push pending edits to Apple for any known org file with REMINDER_ID entries."
  (when (and (buffer-file-name)
             (not org-apple-reminders--syncing)
             (derived-mode-p 'org-mode)
             (member (expand-file-name (buffer-file-name))
                     (org-apple-reminders--known-files))
             (org-apple-reminders--buffer-has-reminders-p))
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

(defun org-apple-reminders--start-sync-timer ()
  "Start the periodic background pull timer if not already running."
  (when (and (> org-apple-reminders-auto-sync-interval 0)
             (null org-apple-reminders--sync-timer))
    (setq org-apple-reminders--sync-timer
          (run-with-timer org-apple-reminders-auto-sync-interval
                          org-apple-reminders-auto-sync-interval
                          #'org-apple-reminders--background-pull))))

;;;###autoload
(defun org-apple-reminders-setup ()
  "Activate org-apple-reminders: key map, background timer, capture, agenda.

Call this once from your init file after setting
`org-apple-reminders-sync-file' (and optionally
`org-apple-reminders-auto-sync-interval').

Binds `org-apple-reminders-command-map' under
`org-apple-reminders-keymap-prefix' (default \"C-c r\")."
  (org-apple-reminders--loaded-message)
  (when org-apple-reminders-keymap-prefix
    (global-set-key (kbd org-apple-reminders-keymap-prefix)
                    org-apple-reminders-command-map))
  ;; Eagerly load org-agenda and org-capture (both ship with org, which is
  ;; already a Package-Requires dependency).
  (require 'org-agenda)
  (require 'org-capture)
  (org-apple-reminders--ensure-agenda-files)
  (add-hook 'org-agenda-mode-hook #'org-apple-reminders--ensure-agenda-files)
  (add-hook 'org-mode-hook
            #'org-apple-reminders--refresh-delete-mark-visibility-maybe)
  (add-hook 'org-agenda-finalize-hook
            #'org-apple-reminders--refresh-delete-mark-visibility-maybe)
  (org-apple-reminders--setup-capture)
  (org-apple-reminders--start-sync-timer)
  (run-with-idle-timer 3 nil #'org-apple-reminders--background-pull))
