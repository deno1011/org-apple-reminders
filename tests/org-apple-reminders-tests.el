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
          (org-apple-reminders--cache nil))
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
    (should (string-match-p "DEADLINE: <2026-06-20"
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

;;; org-apple-reminders-tests.el ends here
