;;; org-apple-reminders-tests.el --- Offline tests for org-apple-reminders -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'cl-lib)
(require 'json)

(load-file (expand-file-name "../org-apple-reminders.el"
                             (file-name-directory (or load-file-name
                                                      buffer-file-name))))

(defun org-apple-reminders-test--write (file text)
  "Write TEXT to FILE and return FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert text))
  file)

(defun org-apple-reminders-test--read (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun org-apple-reminders-test--item (id title &optional completed list)
  "Build a fake Apple reminder alist."
  `((id . ,id)
    (title . ,title)
    (completed . ,(if completed t :json-false))
    (notes . "")
    (due . nil)
    (priority . 0)
    (flagged . :json-false)
    (modDate . "2026-06-11T10:00:00Z")
    (list . ,(or list "Work"))))

(defun org-apple-reminders-test--list (name &rest items)
  "Build a fake Apple list alist."
  `((list . ,name)
    (listId . ,(concat "list-" name))
    (items . ,(vconcat items))))

(defmacro org-apple-reminders-test--with-env (sync-text apple-data &rest body)
  "Run BODY with temp org files and fake Apple DATA.
Within BODY, `sync-file', `extra-file' and `actions' are bound."
  (declare (indent 2) (debug t))
  `(let* ((tmpdir (make-temp-file "org-apple-reminders-test-" t))
          (sync-file (expand-file-name "reminders.org" tmpdir))
          (extra-file (expand-file-name "ordinary.org" tmpdir))
          (actions nil)
          (org-apple-reminders-sync-file sync-file)
          (org-apple-reminders-extra-files nil)
          (org-agenda-files nil)
          (org-apple-reminders-sync-list "Inbox")
          (org-apple-reminders-included-lists nil)
          (org-apple-reminders-saved-included-lists 'unset)
          (org-todo-keywords '((sequence "TODO" "NEXT" "WAITING" "|" "DONE" "CANCELLED")))
          (org-todo-keywords-1 '("TODO" "NEXT" "WAITING" "DONE" "CANCELLED"))
          (org-apple-reminders--cache nil)
          (org-apple-reminders--file-metadata-cache (make-hash-table :test #'equal)))
     (org-apple-reminders-test--write sync-file ,sync-text)
     (cl-letf (((symbol-function 'org-apple-reminders--jxa-run)
                (lambda (&rest _) (json-encode (vconcat (or ,apple-data nil)))))
               ((symbol-function 'org-apple-reminders--jxa-async)
                (lambda (_script callback) (when callback (funcall callback ""))))
               ((symbol-function 'org-apple-reminders--autosave-known-buffers)
                (lambda () nil))
               ((symbol-function 'org-apple-reminders--wait-for-async-jxa)
                (lambda (&optional _) nil))
               ((symbol-function 'org-apple-reminders--ensure-list)
                (lambda (name)
                  (push (list :ensure-list name) actions)
                  `((ok . t) (list . ,name) (listId . ,(concat "list-" name)))))
               ((symbol-function 'org-apple-reminders--create-in-apple)
                (lambda (list-name vals)
                  (let ((id (format "created-%d" (1+ (cl-count-if
                                                      (lambda (a) (eq (car a) :create))
                                                      actions)))))
                    (push (list :create list-name (alist-get 'title vals) id) actions)
                    id)))
               ((symbol-function 'org-apple-reminders--update-in-apple)
                (lambda (list-name id vals &optional callback)
                  (push (list :update list-name id (alist-get 'title vals)) actions)
                  (when callback (funcall callback "2026-06-11T11:00:00Z"))
                  "2026-06-11T11:00:00Z"))
               ((symbol-function 'org-apple-reminders--complete-in-apple)
                (lambda (list-name id)
                  (push (list :complete list-name id) actions)
                  t))
               ((symbol-function 'org-apple-reminders--delete-in-apple)
                (lambda (list-name id)
                  (push (list :delete list-name id) actions)
                  t))
               ((symbol-function 'org-apple-reminders--delete-list-in-apple)
                (lambda (list-name)
                  (push (list :delete-list list-name) actions)
                  t)))
       (unwind-protect
           (progn ,@body)
         (dolist (buf (buffer-list))
           (when-let ((file (buffer-file-name buf)))
             (when (string-prefix-p tmpdir file)
               (kill-buffer buf))))))))

(ert-deftest org-apple-reminders-test-sync-file-levels-are-list-task-and-local-subtask ()
  (org-apple-reminders-test--with-env
      "* TODO Work\n** Plain parent\n** TODO Todo parent\n*** TODO Child is local until real subtask support exists\n* Personal\n"
      (list (org-apple-reminders-test--list "Work")
            (org-apple-reminders-test--list "Personal"))
    (org-apple-reminders-sync)
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should (string-match-p "^\\* TODO Work" text))
      (should (string-match-p "^\\* Personal" text))
      (should (= 2 (cl-count-if (lambda (a) (eq (car a) :create)) actions)))
      (should (member '(:create "Work" "Plain parent" "created-1") actions))
      (should (member '(:create "Work" "Todo parent" "created-2") actions))
      (should-not (cl-find "Child is local until real subtask support exists"
                           actions
                           :key (lambda (action) (nth 2 action))
                           :test #'equal))
      (should-not (string-match-p
                   "Child is local until real subtask support exists\\(.\\|\n\\)*:REMINDER_ID:"
                   text))
      (should-not (cl-find "Work"
                           actions
                           :key (lambda (action) (nth 2 action))
                           :test #'equal)))))

(ert-deftest org-apple-reminders-test-nested-list-container-is-not-reminder ()
  "A malformed nested list container must not be pushed as a reminder."
  (org-apple-reminders-test--with-env
      "* Einkaufsliste [0/0]\n:PROPERTIES:\n:REMINDER_LIST_NAME: Einkaufsliste\n:REMINDER_LIST_SYNCED: t\n:REMINDER_LIST_ID: list-groceries\n:END:\n** Einkaufsliste [0/0]\n:PROPERTIES:\n:REMINDER_LIST_NAME: Einkaufsliste\n:REMINDER_LIST_SYNCED: t\n:REMINDER_LIST_ID: list-groceries\n:REMINDER_LIST: Einkaufsliste\n:END:\n** TODO babyspinat\n"
      (list (org-apple-reminders-test--list "Einkaufsliste"))
    (org-apple-reminders-sync)
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should (= 1 (cl-count-if (lambda (a) (eq (car a) :create)) actions)))
      (should (member '(:create "Einkaufsliste" "babyspinat" "created-1")
                      actions))
      (should-not (cl-find "Einkaufsliste [0/0]"
                           actions
                           :key (lambda (action) (nth 2 action))
                           :test #'equal))
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (re-search-forward "^\\*\\* Einkaufsliste \\[0/0\\]")
        (let ((container-end (save-excursion
                               (outline-next-heading)
                               (point))))
          (should-not (save-excursion
                        (re-search-forward ":REMINDER_ID:" container-end t))))))))

(ert-deftest org-apple-reminders-test-extra-file-is-update-only-with-explicit-list ()
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list "Work"))
    (setq org-apple-reminders-extra-files (list extra-file))
    (org-apple-reminders-test--write
     extra-file
     "* TODO Ordinary top\n** TODO Ordinary child\n* Project\n** Explicit plain heading\n:PROPERTIES:\n:REMINDER_LIST: Work\n:END:\n")
    (org-apple-reminders-sync)
    (should (= 1 (cl-count-if (lambda (a) (eq (car a) :create)) actions)))
    (should (member '(:create "Work" "Explicit plain heading" "created-1") actions))
    (let* ((text (org-apple-reminders-test--read extra-file))
           (ordinary-section (substring text 0 (string-match "^\\* Project" text))))
      (should-not (string-match-p ":REMINDER_ID:" ordinary-section))
      (should (string-match-p "Explicit plain heading\\(.\\|\n\\)*:REMINDER_ID:" text)))))

(ert-deftest org-apple-reminders-test-extra-file-linked-item-prevents-sync-duplicate ()
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "a1" "Linked in ordinary" nil "Work")))
    (setq org-apple-reminders-extra-files (list extra-file))
    (org-apple-reminders-test--write
     extra-file
     "* Project\n** TODO Linked in ordinary\n:PROPERTIES:\n:REMINDER_ID: a1\n:REMINDER_LIST: Work\n:END:\n")
    (org-apple-reminders-sync)
    (let ((sync-text (org-apple-reminders-test--read sync-file)))
      (should-not (string-match-p "Linked in ordinary" sync-text)))
    (should-not (cl-find :create actions :key #'car))))

(ert-deftest org-apple-reminders-test-sync-moves-linked-item-when-apple-list-differs ()
  "A full sync propagates local list moves for already-linked reminders."
  (org-apple-reminders-test--with-env
      "* Inbox\n* Einkaufsliste\n** TODO babyspinat\n:PROPERTIES:\n:REMINDER_ID: old-spinach\n:REMINDER_LIST: Einkaufsliste\n:END:\n"
      (list (org-apple-reminders-test--list
             "Inbox"
             (org-apple-reminders-test--item "old-spinach" "babyspinat" nil "Inbox"))
            (org-apple-reminders-test--list "Einkaufsliste"))
    (org-apple-reminders-sync)
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should (member '(:ensure-list "Einkaufsliste") actions))
      (should (member '(:create "Einkaufsliste" "babyspinat" "created-1") actions))
      (should (member '(:delete "Inbox" "old-spinach") actions))
      (should-not (string-match-p ":REMINDER_ID:[ \t]+old-spinach" text))
      (should (string-match-p ":REMINDER_ID:[ \t]+created-1" text))
      (with-temp-buffer
        (insert text)
        (should (= 1 (how-many "^\\*\\* TODO babyspinat" (point-min) (point-max))))))))

(ert-deftest org-apple-reminders-test-open-apple-item-missing-from-ordinary-file-reappears-in-sync-file ()
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "a1" "Reappears" nil "Work")))
    (setq org-apple-reminders-extra-files (list extra-file))
    (org-apple-reminders-test--write extra-file "* Project\n")
    (org-apple-reminders-sync)
    (let ((sync-text (org-apple-reminders-test--read sync-file)))
      (should (string-match-p "\\*\\* TODO Reappears" sync-text))
      (should (string-match-p ":REMINDER_ID:[ \t]+a1" sync-text)))))

(ert-deftest org-apple-reminders-test-open-org-missing-in-apple-becomes-done-then-deleted ()
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Missing\n:PROPERTIES:\n:REMINDER_ID: gone\n:REMINDER_LIST: Work\n:END:\n"
      (list (org-apple-reminders-test--list "Work"))
    (org-apple-reminders-sync)
    (should (string-match-p "\\*\\* DONE Missing"
                            (org-apple-reminders-test--read sync-file)))
    (org-apple-reminders-sync)
    (should-not (string-match-p "Missing"
                                (org-apple-reminders-test--read sync-file)))))

(ert-deftest org-apple-reminders-test-org-done-completes-apple-and-apple-done-marks-org-done ()
  (org-apple-reminders-test--with-env
      "* Work\n** DONE Complete Apple\n:PROPERTIES:\n:REMINDER_ID: open-a\n:REMINDER_LIST: Work\n:END:\n** TODO Apple Done\n:PROPERTIES:\n:REMINDER_ID: done-a\n:REMINDER_LIST: Work\n:END:\n"
      (list (org-apple-reminders-test--list
             "Work"
             (org-apple-reminders-test--item "open-a" "Complete Apple" nil "Work")
             (org-apple-reminders-test--item "done-a" "Apple Done" t "Work")))
    (org-apple-reminders-sync)
    (should (member '(:complete "Work" "open-a") actions))
    (should (string-match-p "\\*\\* DONE Apple Done"
                            (org-apple-reminders-test--read sync-file)))))

(ert-deftest org-apple-reminders-test-completed-apple-item-missing-in-org-is-deleted ()
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "done-a" "Done in Apple" t "Work")))
    (org-apple-reminders-sync)
    (should (member '(:delete "Work" "done-a") actions))
    (should-not (string-match-p "Done in Apple"
                                (org-apple-reminders-test--read sync-file)))))

(ert-deftest org-apple-reminders-test-cancelled-task-and-list-delete-apple-and-org ()
  (org-apple-reminders-test--with-env
      "* Work\n** CANCELLED Cancel task\n:PROPERTIES:\n:REMINDER_ID: c1\n:REMINDER_LIST: Work\n:END:\n* CANCELLED Old List\n:PROPERTIES:\n:REMINDER_LIST_SYNCED: t\n:REMINDER_LIST_ID: list-Old List\n:END:\n** TODO Child\n:PROPERTIES:\n:REMINDER_ID: c2\n:REMINDER_LIST: Old List\n:END:\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "c1" "Cancel task" nil "Work"))
            (org-apple-reminders-test--list
             "Old List" (org-apple-reminders-test--item "c2" "Child" nil "Old List")))
    (org-apple-reminders-sync)
    (should (member '(:delete "Work" "c1") actions))
    (should (member '(:delete-list "Old List") actions))
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should-not (string-match-p "Cancel task" text))
      (should-not (string-match-p "Old List" text)))))

(ert-deftest org-apple-reminders-test-missing-apple-list-becomes-done-then-deleted ()
  (org-apple-reminders-test--with-env
      "* Work\n:PROPERTIES:\n:REMINDER_LIST_SYNCED: t\n:REMINDER_LIST_ID: list-Work\n:END:\n** TODO Child\n:PROPERTIES:\n:REMINDER_ID: c1\n:REMINDER_LIST: Work\n:END:\n"
      nil
    (setq org-apple-reminders--cache (list (org-apple-reminders-test--list "Work")))
    (org-apple-reminders-sync)
    (should (string-match-p "^\\* DONE Work"
                            (org-apple-reminders-test--read sync-file)))
    (setq org-apple-reminders--cache (list (org-apple-reminders-test--list "Work")))
    (org-apple-reminders-sync)
    (should-not (string-match-p "Work"
                                (org-apple-reminders-test--read sync-file)))))

(ert-deftest org-apple-reminders-test-known-files-include-extra-files ()
  (org-apple-reminders-test--with-env
      "* Work\n"
      nil
    (setq org-apple-reminders-extra-files (list extra-file))
    (org-apple-reminders-test--write extra-file "* TODO Host\n")
    (should (member (expand-file-name extra-file)
                    (org-apple-reminders--known-files)))))

(ert-deftest org-apple-reminders-test-agenda-files-without-reminder-metadata-are-skipped ()
  "Agenda files without reminder metadata are not opened as known files."
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list "Work"))
    (let* ((agenda-file (expand-file-name "agenda.org" (file-name-directory sync-file)))
           (opened nil)
           (original-find-file-noselect (symbol-function 'find-file-noselect)))
      (org-apple-reminders-test--write agenda-file "* TODO Plain agenda task\n")
      (setq org-agenda-files (list agenda-file))
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (file &rest args)
                   (when (equal (expand-file-name file)
                                (expand-file-name agenda-file))
                     (setq opened t))
                   (apply original-find-file-noselect file args))))
        (org-apple-reminders-sync))
      (should-not opened)
      (should-not (member (expand-file-name agenda-file)
                          (org-apple-reminders--known-files))))))

(ert-deftest org-apple-reminders-test-agenda-file-linked-item-prevents-sync-duplicate ()
  "A REMINDER_ID in an agenda file is discovered without explicit extra-files."
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "a1" "Linked in agenda" nil "Work")))
    (let ((agenda-file (expand-file-name "agenda.org" (file-name-directory sync-file))))
      (org-apple-reminders-test--write
       agenda-file
       "* Project\n** TODO Linked in agenda\n:PROPERTIES:\n:REMINDER_ID: a1\n:REMINDER_LIST: Work\n:END:\n")
      (setq org-agenda-files (list agenda-file))
      (org-apple-reminders-sync)
      (should (member (expand-file-name agenda-file)
                      (org-apple-reminders--known-files)))
      (should-not (string-match-p "Linked in agenda"
                                  (org-apple-reminders-test--read sync-file)))
      (should-not (cl-find :create actions :key #'car)))))

(ert-deftest org-apple-reminders-test-agenda-file-explicit-list-can-create-reminder ()
  "A REMINDER_LIST in an agenda file still opts that file into sync."
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list "Work"))
    (let ((agenda-file (expand-file-name "agenda.org" (file-name-directory sync-file))))
      (org-apple-reminders-test--write
       agenda-file
       "* Project\n** TODO Agenda create\n:PROPERTIES:\n:REMINDER_LIST: Work\n:END:\n")
      (setq org-agenda-files (list agenda-file))
      (org-apple-reminders-sync)
      (should (member (expand-file-name agenda-file)
                      (org-apple-reminders--known-files)))
      (should (member '(:create "Work" "Agenda create" "created-1") actions)))))

;;; Conflict-resolution branches (guard rails for the --conflict-direction refactor)

(ert-deftest org-apple-reminders-test-conflict-apple-wins-pulls-fields ()
  "Apple modDate newer than last-known → Apple wins; org fields are pulled."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Title old\n:PROPERTIES:\n:REMINDER_ID: w1\n:REMINDER_LIST: Work\n:REMINDER_APPLE_MOD: 2026-06-11T09:00:00Z\n:REMINDER_ORG_MOD: 2026-06-11T09:00:00Z\n:END:\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "w1" "Title new" nil "Work")))
    (org-apple-reminders-sync)
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should (string-match-p "\\*\\* TODO Title new" text))
      (should-not (string-match-p "Title old" text)))
    ;; Apple wins → nothing pushed to Apple.
    (should-not (cl-find :update actions :key #'car))
    (should-not (cl-find :create actions :key #'car))))

(ert-deftest org-apple-reminders-test-conflict-org-wins-pushes-update ()
  "REMINDER_ORG_MOD > REMINDER_APPLE_MOD and Apple not newer → org wins; push."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Locally edited\n:PROPERTIES:\n:REMINDER_ID: w1\n:REMINDER_LIST: Work\n:REMINDER_APPLE_MOD: 2026-06-11T09:00:00Z\n:REMINDER_ORG_MOD: 2026-06-11T12:00:00Z\n:END:\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "w1" "Old apple title" nil "Work")))
    (org-apple-reminders-sync)
    (should (member '(:update "Work" "w1" "Locally edited") actions))
    (should (string-match-p "\\*\\* TODO Locally edited"
                            (org-apple-reminders-test--read sync-file)))))

(ert-deftest org-apple-reminders-test-conflict-neither-newer-backfills-missing-field ()
  "Neither side newer → backfill a missing org field from Apple, without pushing."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Backfill me\n:PROPERTIES:\n:REMINDER_ID: w1\n:REMINDER_LIST: Work\n:REMINDER_APPLE_MOD: 2026-06-11T10:00:00Z\n:REMINDER_ORG_MOD: 2026-06-11T10:00:00Z\n:END:\n"
      (list `((list . "Work") (listId . "list-Work")
              (items . [((id . "w1") (title . "Backfill me")
                         (completed . :json-false) (notes . "")
                         (due . "2026-06-20") (priority . 0)
                         (flagged . :json-false)
                         (modDate . "2026-06-11T10:00:00Z") (list . "Work"))])))
    (org-apple-reminders-sync)
    (should (string-match-p "SCHEDULED: <2026-06-20"
                            (org-apple-reminders-test--read sync-file)))
    (should-not (cl-find :update actions :key #'car))))

(ert-deftest org-apple-reminders-test-background-pull-marks-completed-done ()
  "Background pull marks a heading DONE when its Apple item is completed."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Will complete\n:PROPERTIES:\n:REMINDER_ID: w1\n:REMINDER_LIST: Work\n:END:\n"
      nil
    (let ((data (list (org-apple-reminders-test--list
                       "Work" (org-apple-reminders-test--item
                               "w1" "Will complete" t "Work")))))
      (cl-letf (((symbol-function 'org-apple-reminders--jxa-async)
                 (lambda (_script callback)
                   (funcall callback (json-encode (vconcat data))))))
        (org-apple-reminders--background-pull)))
    (should (string-match-p "\\*\\* DONE Will complete"
                            (org-apple-reminders-test--read sync-file)))))

(ert-deftest org-apple-reminders-test-background-pull-pulls-new-open-item ()
  "Background pull inserts a new open Apple item into the sync file."
  (org-apple-reminders-test--with-env
      "* Work\n"
      nil
    (let ((data (list (org-apple-reminders-test--list
                       "Work" (org-apple-reminders-test--item
                               "w9" "Fresh from apple" nil "Work")))))
      (cl-letf (((symbol-function 'org-apple-reminders--jxa-async)
                 (lambda (_script callback)
                   (funcall callback (json-encode (vconcat data))))))
        (org-apple-reminders--background-pull)))
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should (string-match-p "\\*\\* TODO Fresh from apple" text))
      (should (string-match-p ":REMINDER_ID:[ \t]+w9" text)))))

;;; --- List lifecycle ---------------------------------------------------------

(ert-deftest org-apple-reminders-test-new-list-section-creates-apple-list ()
  "A new `* List' section in the sync file creates the Apple list and its items."
  (org-apple-reminders-test--with-env
      "* Work\n* Groceries\n** TODO Milk\n"
      (list (org-apple-reminders-test--list "Work"))
    (org-apple-reminders-sync)
    (should (member '(:ensure-list "Groceries") actions))
    (should (member '(:create "Groceries" "Milk" "created-1") actions))))

(ert-deftest org-apple-reminders-test-excluded-list-section-is-pruned ()
  "A pure list section not in `included-lists' is removed from the sync file."
  (org-apple-reminders-test--with-env
      "* Work\n* Personal\n"
      (list (org-apple-reminders-test--list "Work")
            (org-apple-reminders-test--list "Personal"))
    (setq org-apple-reminders-included-lists '("Work"))
    (org-apple-reminders-sync)
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should (string-match-p "^\\* Work" text))
      (should-not (string-match-p "Personal" text)))))

(ert-deftest org-apple-reminders-test-excluded-list-apple-item-not-pulled ()
  "An open Apple item in a non-included list is not pulled into the sync file."
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "w1" "Keep" nil "Work"))
            (org-apple-reminders-test--list
             "Personal" (org-apple-reminders-test--item "p1" "Drop" nil "Personal")))
    (setq org-apple-reminders-included-lists '("Work"))
    (org-apple-reminders-sync)
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should (string-match-p "Keep" text))
      (should-not (string-match-p "Drop" text)))))

;;; --- Multi-file / moving reminders ------------------------------------------

(ert-deftest org-apple-reminders-test-reminder-moved-to-other-file-not-reduplicated ()
  "A reminder moved out of the sync file into another file stays there only."
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "m1" "Moved" nil "Work")))
    (setq org-apple-reminders-extra-files (list extra-file))
    (org-apple-reminders-test--write
     extra-file
     "* Project notes\n** TODO Moved\n:PROPERTIES:\n:REMINDER_ID: m1\n:REMINDER_LIST: Work\n:END:\n")
    (org-apple-reminders-sync)
    (should-not (string-match-p "Moved" (org-apple-reminders-test--read sync-file)))
    (should (string-match-p "Moved" (org-apple-reminders-test--read extra-file)))
    (should-not (cl-find :create actions :key #'car))
    (should-not (cl-find :delete actions :key #'car))))

(ert-deftest org-apple-reminders-test-edit-linked-reminder-in-extra-file-pushes ()
  "Editing a linked reminder in an extra file (org newer) pushes the update."
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "m1" "Old title" nil "Work")))
    (setq org-apple-reminders-extra-files (list extra-file))
    (org-apple-reminders-test--write
     extra-file
     "* Project\n** TODO New title\n:PROPERTIES:\n:REMINDER_ID: m1\n:REMINDER_LIST: Work\n:REMINDER_APPLE_MOD: 2026-06-11T09:00:00Z\n:REMINDER_ORG_MOD: 2026-06-11T12:00:00Z\n:END:\n")
    (org-apple-reminders-sync)
    (should (member '(:update "Work" "m1" "New title") actions))))

(ert-deftest org-apple-reminders-test-apple-completed-marks-extra-file-done ()
  "An Apple-completed item marks its linked heading DONE in an extra file."
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "m1" "Finish me" t "Work")))
    (setq org-apple-reminders-extra-files (list extra-file))
    (org-apple-reminders-test--write
     extra-file
     "* Project\n** TODO Finish me\n:PROPERTIES:\n:REMINDER_ID: m1\n:REMINDER_LIST: Work\n:END:\n")
    (org-apple-reminders-sync)
    (should (string-match-p "\\*\\* DONE Finish me"
                            (org-apple-reminders-test--read extra-file)))))

;;; --- Structure / subitems ---------------------------------------------------

(ert-deftest org-apple-reminders-test-level3-subitem-never-creates-reminder ()
  "Level-3 headings under a reminder never become Apple reminders."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Parent\n*** TODO Child subtask\n"
      (list (org-apple-reminders-test--list "Work"))
    (org-apple-reminders-sync)
    (should (member '(:create "Work" "Parent" "created-1") actions))
    (should-not (cl-find "Child subtask" actions
                         :key (lambda (a) (nth 2 a)) :test #'equal))
    (should-not (string-match-p
                 "Child subtask\\(.\\|\n\\)*:REMINDER_ID:"
                 (org-apple-reminders-test--read sync-file)))))

(ert-deftest org-apple-reminders-test-plain-level2-heading-creates-reminder ()
  "A plain (no TODO keyword) level-2 heading under a list is created."
  (org-apple-reminders-test--with-env
      "* Work\n** Plain heading\n"
      (list (org-apple-reminders-test--list "Work"))
    (org-apple-reminders-sync)
    (should (member '(:create "Work" "Plain heading" "created-1") actions))))

(ert-deftest org-apple-reminders-test-reminder-nosync-skips-creation ()
  "A heading tagged REMINDER_NOSYNC is never pushed to Apple."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Skip me\n:PROPERTIES:\n:REMINDER_NOSYNC: t\n:END:\n"
      (list (org-apple-reminders-test--list "Work"))
    (org-apple-reminders-sync)
    (should-not (cl-find "Skip me" actions
                         :key (lambda (a) (nth 2 a)) :test #'equal))
    (should-not (string-match-p
                 "Skip me\\(.\\|\n\\)*:REMINDER_ID:"
                 (org-apple-reminders-test--read sync-file)))))

;;; --- Delete marking ---------------------------------------------------------

(ert-deftest org-apple-reminders-test-reminder-delete-mark-removes-and-finalizes ()
  "A REMINDER_DELETE heading is deleted from Apple, marked DONE, and unlinked."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Kill it\n:PROPERTIES:\n:REMINDER_ID: k1\n:REMINDER_LIST: Work\n:REMINDER_DELETE: t\n:END:\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "k1" "Kill it" nil "Work")))
    (org-apple-reminders-sync)
    (should (member '(:delete "Work" "k1") actions))
    (let ((text (org-apple-reminders-test--read sync-file)))
      (should (string-match-p "\\*\\* DONE Kill it" text))
      (should-not (string-match-p ":REMINDER_ID:[ \t]+k1" text)))))

;;; --- Idempotency ------------------------------------------------------------

(ert-deftest org-apple-reminders-test-sync-twice-is-idempotent ()
  "A second sync with unchanged state makes no changes and no duplicates."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Stable\n:PROPERTIES:\n:REMINDER_ID: s1\n:REMINDER_LIST: Work\n:REMINDER_APPLE_MOD: 2026-06-11T10:00:00Z\n:REMINDER_ORG_MOD: 2026-06-11T10:00:00Z\n:END:\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "s1" "Stable" nil "Work")))
    (org-apple-reminders-sync)
    (let ((after-first (org-apple-reminders-test--read sync-file)))
      (setq actions nil)
      (org-apple-reminders-sync)
      (let ((after-second (org-apple-reminders-test--read sync-file)))
        (should (equal after-first after-second))
        (should-not (cl-find :create actions :key #'car))
        (should-not (cl-find :update actions :key #'car))
        (should (= 1 (cl-count "Stable" (split-string after-second "\n")
                               :test (lambda (a b) (string-match-p a b)))))))))

;;; --- Field mapping ----------------------------------------------------------

(ert-deftest org-apple-reminders-test-org-item-values-maps-all-fields ()
  "`--org-item-values' maps title, priority, flag, scheduled date and notes."
  (with-temp-buffer
    (let ((org-todo-keywords '((sequence "TODO" "|" "DONE"))))
      (org-mode)
      (insert "* TODO [#A] Task title :flagged:\n")
      (insert "SCHEDULED: <2026-09-01 Tue 14:30>\n")
      (insert "the body text\n")
      (goto-char (point-min))
      (let ((vals (org-apple-reminders--org-item-values)))
        (should (equal (alist-get 'title vals) "Task title"))
        (should (= (alist-get 'priority vals) 1))
        (should (eq (alist-get 'flagged vals) t))
        (should (equal (alist-get 'due vals) "2026-09-01T14:30"))
        (should (string-match-p "the body text" (alist-get 'notes vals)))))))

(ert-deftest org-apple-reminders-test-deadline-with-time-pulled-from-apple ()
  "A pulled Apple item with a timed due date becomes a timed org SCHEDULED."
  (org-apple-reminders-test--with-env
      "* Work\n"
      (list `((list . "Work") (listId . "list-Work")
              (items . [((id . "t1") (title . "Timed") (completed . :json-false)
                         (notes . "") (due . "2026-09-01T14:30") (priority . 0)
                         (flagged . :json-false)
                         (modDate . "2026-06-11T10:00:00Z") (list . "Work"))])))
    (org-apple-reminders-sync)
    (should (string-match-p "SCHEDULED: <2026-09-01[^>]*14:30"
                            (org-apple-reminders-test--read sync-file)))))

(ert-deftest org-apple-reminders-test-move-reminder-between-lists-in-sync-file ()
  "Pushing a linked reminder to another list moves it (no duplicate) and
relocates its subtree under the new list section in the sync file."
  (org-apple-reminders-test--with-env
      "* Work\n** TODO Task\n:PROPERTIES:\n:REMINDER_ID: w1\n:REMINDER_LIST: Work\n:END:\n* Personal\n"
      (list (org-apple-reminders-test--list
             "Work" (org-apple-reminders-test--item "w1" "Task" nil "Work"))
            (org-apple-reminders-test--list "Personal"))
    (with-current-buffer (find-file-noselect sync-file)
      (goto-char (point-min))
      (re-search-forward "^\\*\\* TODO Task")
      (org-apple-reminders-push-heading "Personal"))
    ;; Apple side: recreated in Personal, removed from Work — never duplicated.
    (should (member '(:create "Personal" "Task" "created-1") actions))
    (should (member '(:delete "Work" "w1") actions))
    (let* ((text (org-apple-reminders-test--read sync-file))
           (personal-pos (string-match "^\\* Personal" text))
           (task-pos (string-match "TODO Task" text)))
      ;; Now in the Personal list, not Work.
      (should (string-match-p ":REMINDER_LIST: Personal" text))
      (should-not (string-match-p ":REMINDER_LIST: Work" text))
      ;; Subtree relocated below the Personal heading.
      (should (and personal-pos task-pos (> task-pos personal-pos)))
      ;; Exactly one Task heading — no duplicate left under Work.
      (should (= 1 (cl-count-if (lambda (l) (string-match-p "TODO Task" l))
                                (split-string text "\n")))))))

;;; --- Capture template -------------------------------------------------------

(ert-deftest org-apple-reminders-test-capture-template-is-well-formed ()
  "`--setup-capture' registers a level-2 TODO template targeting the sync file."
  (require 'org-capture)
  (let ((org-capture-templates nil)
        (org-apple-reminders-default-list "Inbox")
        (org-apple-reminders-sync-file "/tmp/oar-test-reminders.org"))
    (org-apple-reminders--setup-capture)
    (let ((tpl (assoc "A" org-capture-templates)))
      (should tpl)
      (should (equal (nth 1 tpl) "Apple Reminder"))
      (should (eq (nth 2 tpl) 'entry))
      (let ((target (nth 3 tpl)))
        (should (eq (car target) 'file+headline))
        (should (equal (nth 2 target) "Inbox")))
      (let ((body (nth 4 tpl)))
        (should (string-match-p "\\*\\* TODO %\\?" body))
        (should (string-match-p ":REMINDER_LIST: Inbox" body))))))

;;; --- Notes pull direction ---------------------------------------------------

(ert-deftest org-apple-reminders-test-apply-apple-values-writes-multiline-notes ()
  "Applying Apple field values writes multi-line notes into the org body and
stamps REMINDER_APPLE_MOD."
  (with-temp-buffer
    (let ((org-todo-keywords '((sequence "TODO" "|" "DONE"))))
      (org-mode)
      (insert "* TODO Task\n:PROPERTIES:\n:REMINDER_ID: x1\n:REMINDER_LIST: Work\n:END:\n")
      (goto-char (point-min))
      (org-apple-reminders--apply-apple-field-values
       '((title . "Task") (priority . 0) (due . nil) (flagged . nil)
         (notes . "line one\nline two") (mod-date . "2026-06-11T10:00:00Z")))
      (let ((text (buffer-string)))
        (should (string-match-p "line one" text))
        (should (string-match-p "line two" text))
        (should (string-match-p ":REMINDER_APPLE_MOD: 2026-06-11T10:00:00Z" text))))))

;;; --- Package hygiene --------------------------------------------------------

(ert-deftest org-apple-reminders-test-package-provides-feature ()
  "The file must (provide 'org-apple-reminders) so require / use-package work."
  (should (featurep 'org-apple-reminders)))

(ert-deftest org-apple-reminders-test-checkdoc-baseline ()
  "Hold checkdoc to its accepted baseline so new nits fail the suite.
The 9 long-standing \"within reason\" findings are:
  - 2 `C-c' keycode references in user-facing docstrings (intentional — the
    setup/visibility commands document their key bindings);
  - 7 arguments not restated in their docstrings: callback, list-name,
    apple-list-names, state, previous-list-names, and beg (in two commands).
A different count is a regression (e.g. a new function whose docstring omits an
argument, as the layered rebuild briefly did with SNAPSHOT).  Run
`M-x checkdoc-file' on the .el to see what changed, then fix the docstring or,
if the change is intended, update this baseline with a note.

Checkdoc is run in a clean `emacs -Q' subprocess — the canonical environment
the MELPA checks use — because checkdoc's findings depend on which symbols are
bound (a loaded session flags extra `org-agenda-files' references)."
  (let* ((src (or (let ((f (symbol-file 'org-apple-reminders-sync 'defun)))
                    (and f (concat (file-name-sans-extension f) ".el")))
                  (expand-file-name "org-apple-reminders.el")))
         (emacs (expand-file-name invocation-name invocation-directory))
         (errfile (make-temp-file "oar-checkdoc")))
    (should (and src (file-exists-p src)))
    (unwind-protect
        (progn
          (call-process emacs nil (list nil errfile) nil
                        "-Q" "--batch"
                        "--eval" (format "(progn (require 'checkdoc) (checkdoc-file %S))"
                                         src))
          (let ((count (with-temp-buffer
                         (insert-file-contents errfile)
                         (how-many ":[0-9]+: " (point-min) (point-max)))))
            (should (= count 9))))
      (delete-file errfile))))

;;; org-apple-reminders-tests.el ends here
