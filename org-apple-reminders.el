;;; org-apple-reminders.el --- Bidirectional org-mode ↔ Apple Reminders sync via JXA  -*- lexical-binding: t -*-

;; Copyright (C) 2025 Denis Butic

;; Author: Denis Butic <d.e.n.o@gmx.net>
;; Assisted-by: Claude:claude-opus-4-7
;; Version: 1.11.1
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
;; Features:
;;   - Full bidirectional sync (org <-> Apple Reminders)
;;   - Conflict resolution via dual timestamps
;;     (REMINDER_APPLE_MOD vs REMINDER_ORG_MOD)
;;   - Fields synced: title, due date + time, priority (A/B/C <-> 1/5/9),
;;     flagged/starred, notes, URL (stored as REMINDER_URL property)
;;   - Selective list sync via `org-apple-reminders-included-lists'
;;   - Push any org heading, or a whole region of headings, to Apple;
;;     move reminders between lists without duplicating them
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

;; Forward declarations for the byte-compiler.  These functions and
;; variables come from libraries listed in `Package-Requires' (org-agenda
;; and org-capture ship with org) and are loaded lazily by
;; `org-apple-reminders-setup'; `org-state' is the dynamic variable bound
;; by `org-after-todo-state-change-hook'.
(declare-function org-agenda-redo "org-agenda" (&optional all))
(defvar org-state)
(defvar org-capture-templates)
(defvar org-agenda-custom-commands)

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

New Apple items that are not linked in any known file land in
`org-apple-reminders-sync-file' only — other files are never extended
with new headings by this package."
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

;;; List filter

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

;;; Multi-file helpers

(defun org-apple-reminders--known-files ()
  "Deduped list of all org files that may contain REMINDER_ID headings.
Includes `org-apple-reminders-sync-file', `org-apple-reminders-extra-files',
.org files from `org-agenda-files', and any currently open org buffer that
already contains at least one REMINDER_ID (so files linked via
`org-apple-reminders-push-heading' are picked up without manual config)."
  (delete-dups
   (mapcar #'expand-file-name
           (append (list org-apple-reminders-sync-file)
                   org-apple-reminders-extra-files
                   (cl-remove-if-not
                    (lambda (f) (string-match-p "\\.org\\'" f))
                    org-agenda-files)
                   (delq nil
                         (mapcar (lambda (buf)
                                   (with-current-buffer buf
                                     (and (buffer-file-name)
                                          (derived-mode-p 'org-mode)
                                          (org-apple-reminders--buffer-has-reminders-p)
                                          (buffer-file-name))))
                                 (buffer-list)))))))

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

(defun org-apple-reminders-lists ()
  "Return a list of Apple Reminders list names."
  (let ((raw (org-apple-reminders--jxa-run
              "JSON.stringify(Application('Reminders').lists.name())")))
    (condition-case nil
        (append (json-parse-string raw :array-type 'vector) nil)
      (error nil))))

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
  "Delete the Apple Reminders list NAME and its section from the sync file.
All reminders in the list are removed from Apple, and the matching
`* NAME' subtree (with every entry under it) is deleted from
`org-apple-reminders-sync-file'."
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
            (goto-char (point-min))
            (when (re-search-forward
                   (concat "^\\* " (regexp-quote name) "\\(?: \\|$\\)") nil t)
              (org-back-to-heading t)
              (delete-region (point)
                             (save-excursion (org-end-of-subtree t t) (point)))
              (save-buffer)))))))
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
           (notes   (org-apple-reminders--extract-notes))
           (url     (let ((u (org-entry-get nil "REMINDER_URL")))
                      (and (stringp u) (not (string-empty-p u)) u))))
      `((title . ,title) (due . ,due) (priority . ,prio)
        (flagged . ,flagged) (notes . ,notes) (url . ,url)))))

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
  var urls=null;
  try{urls=rs.URL();}catch(e){try{urls=rs.url();}catch(e2){urls=null;}}
  var items=[];
  for(var i=0;i<names.length;i++){
    var d=dates[i],md=mods[i],u=urls&&urls[i];
    items.push({id:ids[i],title:names[i],notes:bodies[i]||'',
                due:(d&&d instanceof Date&&!isNaN(d)&&d.getFullYear()>1970)?(function(){var ds=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');var h=d.getHours(),m=d.getMinutes();return(h||m)?ds+'T'+String(h).padStart(2,'0')+':'+String(m).padStart(2,'0'):ds;}()):null,
                priority:prios[i],flagged:flags[i],completed:!!compl[i],
                url:(typeof u==='string'&&u.length>0)?u:null,
                modDate:(md&&md instanceof Date&&!isNaN(md))?md.toISOString():null});
  }
  out.push({list:l.name(),items:items});
});
JSON.stringify(out);"
  "JXA script returning all Reminders as JSON.
Uses batch property fetch for speed.")

;; -- URL field via EventKit -------------------------------------------------
;;
;; Apple's scripting dictionary doesn't expose the URL field on a reminder
;; (the dedicated link attachment shown as a globe in the Reminders app).
;; Both JXA and AppleScript hit "Types cannot be converted" / "can't be read"
;; on `r.URL'.  The field IS reachable through the EventKit framework, so we
;; fall back to ObjC.import('EventKit') for read AND write of URL only;
;; everything else still goes through the fast JXA path above.
;;
;; First use will pop a one-time macOS permission dialog asking for "Full
;; Access to Reminders" — separate from the Automation permission that the
;; JXA path uses.  Once granted, persists for the calling process identity.

(defconst org-apple-reminders--fetch-urls-script
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false;
var result={};
var doFetch=function(){
  var p=store.predicateForRemindersInCalendars(null);
  store.fetchRemindersMatchingPredicateCompletion(p,function(rs){
    if(!rs){done=true;return;}
    var n=rs.count;
    for(var i=0;i<n;i++){
      var r=rs.objectAtIndex(i);
      try{
        var u=r.URL;
        if(u){
          var s=u.absoluteString;
          if(s){
            var id=r.calendarItemExternalIdentifier;
            if(id){
              var idJS=String(id),sJS=String(s);
              if(idJS&&sJS&&sJS.length>0){result[idJS]=sJS;}
            }
          }
        }
      }catch(e){}
    }
    done=true;
  });
};
try{
  store.requestFullAccessToRemindersWithCompletion(function(g,e){if(g)doFetch();else done=true;});
}catch(e){
  try{
    store.requestAccessToEntityTypeCompletion($.EKEntityTypeReminder,function(g,e){if(g)doFetch();else done=true;});
  }catch(e2){done=true;}
}
var iter=0;
while(!done&&iter<300){
  $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
  iter++;
}
JSON.stringify(result);"
  "EventKit-based JXA script.
Returns a JSON object mapping reminder external identifier to URL string.
Used because Apple's scripting dictionary doesn't expose the URL field —
only EventKit does.  Spins a runloop for up to ~30s while EventKit's async
fetch completes.")

(defconst org-apple-reminders--set-url-template
  "ObjC.import('EventKit');
var store=$.EKEventStore.alloc.init;
var done=false;
var success=false;
var doSet=function(){
  var r=store.calendarItemWithIdentifier(%s);
  if(!r){done=true;return;}
  try{
    %s
    var err=Ref();
    success=store.saveReminderCommitError(r,true,err);
  }catch(e){}
  done=true;
};
try{
  store.requestFullAccessToRemindersWithCompletion(function(g,e){if(g)doSet();else done=true;});
}catch(e){
  try{
    store.requestAccessToEntityTypeCompletion($.EKEntityTypeReminder,function(g,e){if(g)doSet();else done=true;});
  }catch(e2){done=true;}
}
var iter=0;
while(!done&&iter<300){
  $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
  iter++;
}
JSON.stringify(success);"
  "EventKit-based JXA template for setting URL on a single reminder.
Two `%s' placeholders: JSON-encoded reminder ID, then the assignment
statement (e.g. `r.URL=$.NSURL.URLWithString(\"https://…\");' or
`r.URL=$();').  Saves via `[EKEventStore saveReminder:commit:error:]'.")

(defun org-apple-reminders--fetch-urls ()
  "Return hash table mapping Apple reminder ID to URL string (via EventKit).
Empty table when EventKit is unavailable, permission was denied, or no
reminder carries a URL.  Permission may prompt the user on first use;
once granted it persists for the calling process identity."
  (condition-case nil
      (json-parse-string
       (org-apple-reminders--jxa-run org-apple-reminders--fetch-urls-script)
       :object-type 'hash-table)
    (error (make-hash-table :test 'equal))))

(defun org-apple-reminders--set-url-in-apple (id url)
  "Set the URL field on Apple reminder ID via EventKit.
A nil or empty URL clears the field.  Return t on success, nil on failure
or denied permission.  Used by `org-apple-reminders--create-in-apple' and
`org-apple-reminders--update-in-apple' because Apple's scripting dictionary
doesn't expose the URL field on modern macOS."
  (let* ((set-form
          (if (and (stringp url) (not (string-empty-p url)))
              (format "r.URL=$.NSURL.URLWithString(%s);" (json-encode url))
            "r.URL=$();"))
         (script (format org-apple-reminders--set-url-template
                         (json-encode id) set-form)))
    (condition-case nil
        (eq t (json-parse-string (org-apple-reminders--jxa-run script)))
      (error nil))))

(defun org-apple-reminders--merge-urls (data)
  "Destructively merge EventKit URL data into DATA, the JXA fetch result.
For each item alist DATA contains, set (url . VAL) when EventKit reports
a URL for that REMINDER_ID.  Items without a URL are left untouched.
Returns DATA so callers can use it inside a `let*' binding."
  (let ((url-map (org-apple-reminders--fetch-urls)))
    (when (and url-map (> (hash-table-count url-map) 0))
      (dolist (entry data)
        (dolist (item (alist-get 'items entry))
          (let* ((id (alist-get 'id item))
                 (u  (gethash id url-map)))
            (when (stringp u)
              (setf (alist-get 'url item) u)))))))
  data)

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
Return new ID string or nil.
If VALS carries a non-empty URL, set it on the new reminder via EventKit
after the JXA create returns (the URL field isn't reachable via Apple's
scripting dictionary)."
  (let* ((title   (alist-get 'title    vals ""))
         (notes   (alist-get 'notes    vals ""))
         (prio    (alist-get 'priority vals 0))
         (due     (alist-get 'due      vals))
         (flagged (alist-get 'flagged  vals))
         (url     (alist-get 'url      vals))
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
                           (json-encode (concat due (if (string-match "T" due) ":00" "T00:00:00")))) "")))
         (new-id (condition-case nil
                     (json-parse-string (org-apple-reminders--jxa-run script))
                   (error nil))))
    ;; URL push via EventKit is disabled in v1.11.1 — see
    ;; `org-apple-reminders-sync' for the reasoning.
    (ignore url)
    new-id))

(defun org-apple-reminders--update-in-apple (list-name id vals &optional callback)
  "Push VALS alist to Apple reminder ID in LIST-NAME.
Without CALLBACK: synchronous; returns Apple's modificationDate after the
push, or nil.
With CALLBACK: async; CALLBACK receives the modificationDate string.
The URL field is not pushed — see `org-apple-reminders-sync' for why."
  (let* ((title   (alist-get 'title    vals ""))
         (notes   (alist-get 'notes    vals ""))
         (prio    (alist-get 'priority vals 0))
         (due     (alist-get 'due      vals))
         (flagged (alist-get 'flagged  vals))
         (url     (alist-get 'url      vals))
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
    ;; URL push via EventKit is disabled in v1.11.1 — see
    ;; `org-apple-reminders-sync' for the reasoning.
    (ignore url)
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
Return non-nil on success."
  (let ((script
         (format "var app=Application('Reminders');
if(app.lists.name().indexOf(%s)<0){app.lists.push(app.List({name:%s}));}
JSON.stringify(true);"
                 (json-encode list-name) (json-encode list-name))))
    (condition-case nil
        (eq t (json-parse-string (org-apple-reminders--jxa-run script)))
      (error nil))))

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

;;; Org heading → Apple push

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
                    "REMINDER_APPLE_MOD" "REMINDER_ORG_MOD"))
      (org-entry-delete nil prop))
    (org-set-property "REMINDER_NOSYNC" "t")))

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
    ;; Keep one blank line between the previous section and the new heading.
    (unless (or (bobp)
                (save-excursion (forward-line -1) (looking-at-p "[ \t]*$")))
      (insert "\n"))
    (insert (format "* %s [/]\n" list-name)))
  (unless (bolp) (insert "\n")))

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
         (flagged (alist-get 'flagged  item))
         (url     (let ((u (alist-get 'url item)))
                    (and (stringp u) (not (string-empty-p u)) u))))
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
    (when url
      (insert (format "   :REMINDER_URL:  %s\n" url)))
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

;;; Push-only (org → Apple): called from save hook

(defun org-apple-reminders--push-to-apple ()
  "Push changed org entries to Apple.  New items get REMINDER_ID stamped back.
Auto-creation from unlinked headings only happens in the value of
`org-apple-reminders-sync-file';
other linked files only push updates to already-stamped headings."
  (let* ((n-new 0) (n-updated 0)
         (is-sync-file
          (and (buffer-file-name)
               (string= (expand-file-name (buffer-file-name))
                        (expand-file-name org-apple-reminders-sync-file))))
         new-pts)
    (org-map-entries
     (lambda ()
       (let* ((id     (org-entry-get nil "REMINDER_ID"))
              (rlist  (org-entry-get nil "REMINDER_LIST"))
              (state  (org-get-todo-state))
              (cached (and id (org-apple-reminders--find-in-cache id))))
         (cond
          ((and (null id) is-sync-file (member state '("TODO" "NEXT" "WAITING"))
                (not (org-entry-get nil "REMINDER_NOSYNC")))
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
                                (eq (alist-get 'flagged cached) t)))
                       (not (equal (or (alist-get 'url vals) "")
                                   (let ((u (alist-get 'url cached)))
                                     (or (and (stringp u) u) "")))))))
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
  "Full bidirectional sync across all known org files ↔ Apple Reminders.

Known files: `org-apple-reminders-sync-file', `org-apple-reminders-extra-files',
and .org files in `org-agenda-files'.

Conflict resolution per linked heading:
- No REMINDER_ID (only in sync-file) → create in Apple, stamp ID back.
- Apple modDate unchanged → org wins: push fields if different.
- Apple modDate newer → Apple wins: pull priority/due/flagged.
- DONE in org, open in Apple → push completion to Apple.
- Open in org, done/gone in Apple → mark DONE in org.
New Apple items not linked in any known file → pulled into sync-file only."
  (interactive)
  (message "Reminders: syncing…")
  (let* ((default-list (org-apple-reminders--default-list))
         (sync-file    (expand-file-name org-apple-reminders-sync-file))
         (raw          (org-apple-reminders--jxa-run org-apple-reminders--fetch-script))
         (data         (condition-case nil
                           (json-parse-string raw :object-type 'alist :array-type 'list)
                         (error (user-error "Reminders sync: fetch failed — %s" raw))))
         (apple-by-id  (let ((ht (make-hash-table :test #'equal)))
                         (dolist (entry data)
                           (dolist (item (alist-get 'items entry))
                             (puthash (alist-get 'id item) item ht)))
                         ht))
         (id-index     (org-apple-reminders--build-id-index))
         (n-done 0) (n-pushed 0) (n-pulled 0) (n-updated 0) (n-reopened 0)
         (n-pruned 0))
    ;; URL field sync is currently DISABLED.  v1.11 tried to read URLs via
    ;; EventKit (since the Apple Events scripting dictionary advertises the
    ;; field but `r.URL' returns "Types cannot be converted" on macOS 14+).
    ;; That path is blocked too: `/usr/bin/osascript' does not declare
    ;; `NSRemindersFullAccessUsageDescription' in its Info.plist, so
    ;; `requestFullAccessToRemindersWithCompletion:' silently swallows the
    ;; callback (added ~30s per sync waiting for it to time out), and the
    ;; legacy `requestAccessToEntityType:' grants WRITE-ONLY access on
    ;; macOS 14+ -- `r.URL' reads as `null' for every reminder.  Reading
    ;; the URL field would require shipping a code-signed Swift helper
    ;; with the proper Info.plist; deferred to v1.12+.
    (setq org-apple-reminders--cache data)
    (unless (file-exists-p sync-file)
      (with-temp-file sync-file
        (insert "#+TITLE: Reminders\n#+STARTUP: overview\n#+TODO: TODO NEXT WAITING | DONE CANCELLED\n\n")))
    (let ((org-apple-reminders--syncing t))
      ;; Phase 1: update existing linked items across all known files
      (dolist (file (org-apple-reminders--known-files))
        (when (file-exists-p file)
          (let ((is-sync-file (string= (expand-file-name file) sync-file)))
            (with-current-buffer (find-file-noselect file)
              (org-save-outline-visibility t
                (let (done-pts new-pts reopen-pts apple-updates changed-positions)
                  (org-map-entries
                   (lambda ()
                     (let* ((id    (org-entry-get nil "REMINDER_ID"))
                            (rlist (or (org-entry-get nil "REMINDER_LIST") default-list))
                            (state (org-get-todo-state)))
                       (cond
                        ((and (null id) is-sync-file (member state '("TODO" "NEXT" "WAITING"))
                              (not (org-entry-get nil "REMINDER_NOSYNC")))
                         (push (point-marker) new-pts))
                        (id
                         (let ((apple (gethash id apple-by-id)))
                           ;; Backfill missing REMINDER_URL from Apple.  Runs
                           ;; outside the modDate gate because the URL field
                           ;; is newer than the conflict-resolution code: a
                           ;; URL added in Apple before v1.10 would otherwise
                           ;; never trigger an apple-wins pull and the
                           ;; property would stay missing forever.  The
                           ;; backfill only sets, never overrides — once the
                           ;; property exists, normal conflict resolution
                           ;; takes over.
                           (let ((a-url (and apple (alist-get 'url apple)))
                                 (o-url (org-entry-get nil "REMINDER_URL")))
                             (when (and (stringp a-url)
                                        (not (string-empty-p a-url))
                                        (or (null o-url)
                                            (string-empty-p o-url)))
                               (org-set-property "REMINDER_URL" a-url)))
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
                             (let* ((a-mod       (let ((m (alist-get 'modDate apple)))
                                                   (and (stringp m) (not (string-empty-p m)) m)))
                                    (last-known  (org-apple-reminders--last-known-mod))
                                    (apple-changed (and a-mod
                                                        (or (null last-known)
                                                            (string> a-mod last-known)))))
                               (if apple-changed
                                   (let* ((a-prio   (or (alist-get 'priority apple) 0))
                                          (a-due    (let ((d (alist-get 'due apple)))
                                                      (and (stringp d) (not (string-empty-p d)) d)))
                                          (a-flagged (eq (alist-get 'flagged apple) t))
                                          (a-title  (or (alist-get 'title apple) ""))
                                          (a-notes  (or (alist-get 'notes apple) ""))
                                          (a-url    (let ((u (alist-get 'url apple)))
                                                      (and (stringp u) (not (string-empty-p u)) u)))
                                          (p-char   (nth 3 (org-heading-components)))
                                          (o-prio   (cond ((eql p-char ?A) 1)
                                                          ((eql p-char ?B) 5)
                                                          ((eql p-char ?C) 9)
                                                          (t 0)))
                                          (o-due    (let ((dl (org-entry-get nil "DEADLINE")))
                                                      (when (and dl (string-match
                                                                    "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" dl))
                                                        (match-string 1 dl))))
                                          (o-flagged (not (null (member "flagged" (org-get-tags nil t)))))
                                          (o-title  (replace-regexp-in-string
                                                     "^★ " "" (org-get-heading t t t t)))
                                          (o-notes  (org-apple-reminders--extract-notes))
                                          (o-url    (let ((u (org-entry-get nil "REMINDER_URL")))
                                                      (and (stringp u) (not (string-empty-p u)) u)))
                                          (changed  (or (/= a-prio o-prio)
                                                        (not (equal a-due o-due))
                                                        (not (eq a-flagged o-flagged))
                                                        (not (equal a-title o-title))
                                                        (not (equal a-notes o-notes))
                                                        (not (equal a-url o-url)))))
                                     (if changed
                                         (push (list (point-marker) rlist
                                                     a-prio o-prio a-due o-due a-flagged o-flagged a-mod
                                                     a-title o-title a-notes o-notes a-url o-url)
                                               apple-updates)
                                       ;; Apple's modDate advanced but every tracked
                                       ;; field already matches org — record that this
                                       ;; modDate is reconciled so org edits can win later.
                                       (when (stringp a-mod)
                                         (org-set-property "REMINDER_APPLE_MOD" a-mod))))
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
                                                      (eq (alist-get 'flagged apple) t)))
                                             (not (equal (or (alist-get 'url vals) "")
                                                         (let ((u (alist-get 'url apple)))
                                                           (or (and (stringp u) u) "")))))))
                                   (when needs-push
                                     (let ((new-mod (org-apple-reminders--update-in-apple rlist id vals)))
                                       (when (stringp new-mod)
                                         (org-set-property "REMINDER_ORG_MOD" new-mod)))
                                     (setq n-updated (1+ n-updated)))))))))))))
                   nil nil)
                  (dolist (m (nreverse done-pts))
                    (goto-char m) (push (point-marker) changed-positions)
                    (org-todo "DONE") (set-marker m nil)
                    (setq n-done (1+ n-done)))
                  (when is-sync-file
                    (dolist (m (nreverse new-pts))
                      (goto-char m) (push (point-marker) changed-positions)
                      (let* ((rlist  (or (org-entry-get nil "REMINDER_LIST") default-list))
                             (new-id (org-apple-reminders--create-in-apple
                                      rlist (org-apple-reminders--org-item-values))))
                        (when new-id
                          (org-set-property "REMINDER_ID"   new-id)
                          (org-set-property "REMINDER_LIST" rlist)
                          (puthash new-id sync-file id-index)
                          (setq n-pushed (1+ n-pushed))))))
                  (dolist (upd (nreverse apple-updates))
                    (cl-destructuring-bind
                        (m _rlist a-prio o-prio a-due o-due a-flagged o-flagged a-mod
                           a-title o-title a-notes o-notes a-url o-url)
                        upd
                      (goto-char m) (push (point-marker) changed-positions)
                      (unless (equal a-title o-title)
                        (org-back-to-heading t)
                        (when (looking-at org-complex-heading-regexp)
                          (let ((beg (match-beginning 4))
                                (end (match-end 4)))
                            (when beg
                              (delete-region beg end)
                              (goto-char beg)
                              (insert a-title)))))
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
                      (unless (equal a-notes o-notes)
                        (org-apple-reminders--set-org-notes a-notes))
                      (unless (equal a-url o-url)
                        (if a-url
                            (org-set-property "REMINDER_URL" a-url)
                          (org-entry-delete nil "REMINDER_URL")))
                      (when (stringp a-mod) (org-set-property "REMINDER_APPLE_MOD" a-mod))
                      (setq n-updated (1+ n-updated))
                      (set-marker m nil)))
                  (dolist (m (nreverse reopen-pts))
                    (goto-char m) (push (point-marker) changed-positions)
                    (org-todo "TODO") (set-marker m nil)
                    (setq n-reopened (1+ n-reopened)))
                  ;; Progress cookies only in sync-file (uses * ListName structure)
                  (when is-sync-file
                    (org-map-entries
                     (lambda ()
                       (unless (save-excursion (beginning-of-line)
                                               (looking-at "[^\n]*\\[[0-9]*/[0-9]*\\]"))
                         (end-of-line) (insert " [/]"))
                       (org-update-statistics-cookies nil))
                     "LEVEL=1" nil))
                  (save-buffer)
                  (dolist (m (nreverse changed-positions))
                    (when (marker-position m)
                      (goto-char m) (org-reveal) (set-marker m nil)))))))))
      ;; Phase 2: prune excluded lists, then pull new Apple items
      (with-current-buffer (find-file-noselect sync-file)
        (org-save-outline-visibility t
          (let (changed-positions)
            ;; Drop sections for lists removed from the included-lists set
            ;; so reminders.org keeps mirroring the current selection.
            (setq n-pruned (org-apple-reminders--prune-excluded-lists))
            ;; Ensure every explicitly-included list has a `* List' section,
            ;; even when it is empty, so the selection is mirrored exactly.
            (let ((included (org-apple-reminders--effective-included-lists)))
              (when included
                (dolist (lname included)
                  (save-excursion
                    (org-apple-reminders--goto-list-heading lname)))))
            (dolist (entry data)
              (let ((lname (alist-get 'list  entry))
                    (items (alist-get 'items entry)))
                (when (org-apple-reminders--list-included-p lname)
                  (dolist (item items)
                    (let ((id (alist-get 'id item)))
                      (when (and (not (gethash id id-index))
                                 (not (eq (alist-get 'completed item) t)))
                        (org-apple-reminders--goto-list-heading lname)
                        (push (point-marker) changed-positions)
                        (org-apple-reminders--insert-org-heading item lname)
                        (save-excursion
                          (org-back-to-heading t)
                          (let ((md (alist-get 'modDate item)))
                            (when (stringp md)
                              (org-set-property "REMINDER_APPLE_MOD" md))))
                        (puthash id sync-file id-index)
                        (setq n-pulled (1+ n-pulled))))))))
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
    (message "Reminders: %d←DONE  %d↑reopened  %d→Apple  %d←Apple  %d updated  %d pruned"
             n-done n-reopened n-pushed n-pulled n-updated n-pruned))))

;;; Background pull (Apple → org, async)

(defun org-apple-reminders--background-pull ()
  "Async pull: refresh cache and all known org files from Apple Reminders."
  (unless org-apple-reminders--syncing
    (org-apple-reminders--jxa-async
     org-apple-reminders--fetch-script
     (lambda (raw)
       (condition-case nil
           (let* ((data         (json-parse-string raw :object-type 'alist :array-type 'list))
                  (sync-file    (expand-file-name org-apple-reminders-sync-file))
                  (apple-by-id  (let ((ht (make-hash-table :test #'equal)))
                                  (dolist (entry data)
                                    (dolist (item (alist-get 'items entry))
                                      (puthash (alist-get 'id item) item ht)))
                                  ht))
                  (id-index     (org-apple-reminders--build-id-index)))
             ;; URL field sync is disabled (see `org-apple-reminders-sync').
             (setq org-apple-reminders--cache data)
             (org-apple-reminders--write-agenda-file data)
             (let ((org-apple-reminders--syncing t))
               ;; Phase 1: update existing linked items across all known files
               (dolist (file (org-apple-reminders--known-files))
                 (when (file-exists-p file)
                   (let ((is-sync-file (string= (expand-file-name file) sync-file)))
                     (with-current-buffer (find-file-noselect file)
                       (org-save-outline-visibility t
                         (let (done-pts reopen-pts field-updates)
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
                             (goto-char m) (org-todo "DONE") (set-marker m nil))
                           (dolist (m (nreverse reopen-pts))
                             (goto-char m) (org-todo "TODO") (set-marker m nil))
                           ;; Field updates (priority / due / flagged) from Apple
                           (org-map-entries
                            (lambda ()
                              (let* ((id     (org-entry-get nil "REMINDER_ID"))
                                     (aitem  (when id (gethash id apple-by-id))))
                                (when (and id aitem
                                           (not (eq (alist-get 'completed aitem) t))
                                           (member (org-get-todo-state) '("TODO" "NEXT" "WAITING")))
                                  (let* ((a-prio    (or (alist-get 'priority aitem) 0))
                                         (a-due     (let ((d (alist-get 'due aitem)))
                                                      (and (stringp d) (not (string-empty-p d)) d)))
                                         (a-flagged (eq (alist-get 'flagged aitem) t))
                                         (a-mod     (let ((m (alist-get 'modDate aitem)))
                                                      (and (stringp m) (not (string-empty-p m)) m)))
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
                                         (a-title   (or (alist-get 'title aitem) ""))
                                         (a-notes   (or (alist-get 'notes aitem) ""))
                                         (o-title   (replace-regexp-in-string
                                                     "^★ " "" (org-get-heading t t t t)))
                                         (o-notes   (org-apple-reminders--extract-notes))
                                         (changed   (or (/= a-prio o-prio)
                                                        (not (equal a-due o-due))
                                                        (not (eq a-flagged o-flagged))
                                                        (not (equal a-title o-title))
                                                        (not (equal a-notes o-notes))))
                                         (last-known (org-apple-reminders--last-known-mod))
                                         (apple-changed (and a-mod (or (null last-known)
                                                                        (string> a-mod last-known)))))
                                    (when apple-changed
                                      (if changed
                                          (push (list (point-marker)
                                                      a-prio o-prio a-due o-due a-flagged o-flagged a-mod
                                                      a-title o-title a-notes o-notes)
                                                field-updates)
                                        ;; modDate advanced but fields already match —
                                        ;; record reconciliation so org edits can win.
                                        (when (stringp a-mod)
                                          (org-set-property "REMINDER_APPLE_MOD" a-mod))))))))
                            nil nil)
                           (dolist (upd (nreverse field-updates))
                             (cl-destructuring-bind (m a-prio o-prio a-due o-due a-flagged o-flagged a-mod a-title o-title a-notes o-notes) upd
                               (goto-char m)
                               (unless (equal a-title o-title)
                                 (org-back-to-heading t)
                                 (when (looking-at org-complex-heading-regexp)
                                   (let ((beg (match-beginning 4))
                                         (end (match-end 4)))
                                     (when beg
                                       (delete-region beg end)
                                       (goto-char beg)
                                       (insert a-title)))))
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
                               (unless (equal a-notes o-notes)
                                 (org-apple-reminders--set-org-notes a-notes))
                               (when (stringp a-mod)
                                 (org-set-property "REMINDER_APPLE_MOD" a-mod))
                               (set-marker m nil)))
                           ;; Pull new Apple items into sync-file only
                           (when is-sync-file
                             (dolist (entry data)
                               (let ((lname (alist-get 'list  entry))
                                     (items (alist-get 'items entry)))
                                 (when (org-apple-reminders--list-included-p lname)
                                   (dolist (item items)
                                     (let ((id (alist-get 'id item)))
                                       (when (and (not (gethash id id-index))
                                                  (not (eq (alist-get 'completed item) t)))
                                         (org-apple-reminders--goto-list-heading lname)
                                         (org-apple-reminders--insert-org-heading item lname)
                                         (save-excursion
                                           (org-back-to-heading t)
                                           (let ((md (alist-get 'modDate item)))
                                             (when (stringp md)
                                               (org-set-property "REMINDER_APPLE_MOD" md))))
                                         (puthash id sync-file id-index))))))))
                           ;; Cookies only in sync-file
                           (when is-sync-file
                             (org-map-entries
                              (lambda ()
                                (unless (save-excursion (beginning-of-line)
                                                        (looking-at "[^\n]*\\[[0-9]*/[0-9]*\\]"))
                                  (end-of-line) (insert " [/]"))
                                (org-update-statistics-cookies nil))
                              "LEVEL=1" nil))
                           (save-buffer)
                           (dolist (buf (buffer-list))
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (when (derived-mode-p 'org-agenda-mode)
                                   (let ((inhibit-message t))
                                     (ignore-errors (org-agenda-redo)))))))))))))))
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

;;; Keymap

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
    (define-key map (kbd "d") #'org-apple-reminders-remove-from-apple)
    (define-key map (kbd "D") #'org-apple-reminders-delete-reminder)
    map)
  "Keymap for `org-apple-reminders' commands.
`org-apple-reminders-setup' binds this under
`org-apple-reminders-keymap-prefix' (default \"C-c r\").  Keys
`p' and `m' both run `org-apple-reminders-push-heading' (single
heading or active region).  The heading commands (p/m/d/D)
`user-error' when there is nothing to act on, so the whole map is
safe to bind globally.")
;; Allow the variable to be used directly as a prefix key.
(fset 'org-apple-reminders-command-map org-apple-reminders-command-map)

;;; Setup entry point

;;;###autoload
(defun org-apple-reminders-setup ()
  "Activate org-apple-reminders: key map, background timer, capture, agenda.

Call this once from your init file after setting
`org-apple-reminders-sync-file' (and optionally
`org-apple-reminders-auto-sync-interval').

Binds `org-apple-reminders-command-map' under
`org-apple-reminders-keymap-prefix' (default \"C-c r\"):

  C-c r R   sync                C-c r a   add reminder
  C-c r f   open sync file      C-c r l   show lists
  C-c r L   create list         C-c r X   delete list
  C-c r i   choose synced lists C-c r p   push heading to Apple
  C-c r d   remove from Apple (keep org heading)
  C-c r D   delete reminder (Apple and org)"
  (when org-apple-reminders-keymap-prefix
    (global-set-key (kbd org-apple-reminders-keymap-prefix)
                    org-apple-reminders-command-map))
  ;; Eagerly load org-agenda and org-capture (both ship with org, which is
  ;; already a Package-Requires dependency).  Avoiding `with-eval-after-load'
  ;; keeps the package free of behaviour that should live in user config.
  (require 'org-agenda)
  (require 'org-capture)
  (org-apple-reminders--ensure-agenda-files)
  (add-hook 'org-agenda-mode-hook #'org-apple-reminders--ensure-agenda-files)
  (org-apple-reminders--setup-capture)
  (org-apple-reminders--start-sync-timer)
  (run-with-idle-timer 3 nil #'org-apple-reminders--background-pull))

(provide 'org-apple-reminders)

;;; org-apple-reminders.el ends here
