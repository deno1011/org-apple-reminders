# Test Plan

Manual test plan for `org-apple-reminders`. Run after any change before
merging `main` → `stable`.

Prerequisites: macOS, Emacs 27.1+, org-mode 9.3+, at least one Apple
Reminders list with a few items.

---

## Setup

```emacs-lisp
(require 'org-apple-reminders)
(setq org-apple-reminders-sync-file "~/org/reminders-test.org")
(org-apple-reminders-setup)
```

Use a dedicated test sync file so existing reminders.org is not affected.
Delete `~/org/reminders-test.org` after each test run to start fresh.

---

## 1. Installation

| # | Step | Expected |
|---|------|----------|
| 1.1 | `M-x load-file RET org-apple-reminders.el` | No errors in `*Messages*` |
| 1.2 | `M-x org-apple-reminders-show-lists` | Echo area shows your Apple Reminders lists |
| 1.3 | Open `M-x customize-group RET org-apple-reminders` | Group appears with all custom variables |

---

## 2. Full Sync (`C-c r R`)

### 2.1 First sync — pull from Apple

| # | Step | Expected |
|---|------|----------|
| 2.1.1 | Delete `reminders-test.org` if it exists | — |
| 2.1.2 | `C-c r R` | File created; `* ListName [N/M]` headings appear; open reminders appear as `** TODO` |
| 2.1.3 | Check properties | Each heading has `REMINDER_ID`, `REMINDER_LIST`, `REMINDER_APPLE_MOD` |
| 2.1.4 | Check cookies | `[N/M]` on each list heading reflects correct counts |

### 2.2 Org → Apple (org wins)

| # | Step | Expected |
|---|------|----------|
| 2.2.1 | Edit a title in reminders-test.org, save | Save hook message: "Reminders push: 0 new, 1 updated." |
| 2.2.2 | Open Apple Reminders app | Title changed there too |
| 2.2.3 | Add priority `[#A]` to a heading, `C-c ,` | Apple shows priority High immediately (live hook) |
| 2.2.4 | Add `DEADLINE: <2025-12-31>`, `C-c C-d` | Apple shows due date Dec 31 immediately |
| 2.2.5 | Add `:flagged:` tag, `C-c C-q` | Apple shows item as flagged (starred) immediately |
| 2.2.6 | Add notes below heading, save file | `C-c r R` → notes appear in Apple |

### 2.3 Apple → org (Apple wins)

| # | Step | Expected |
|---|------|----------|
| 2.3.1 | Change a reminder's title in Apple Reminders app | `C-c r R` → org title updated |
| 2.3.2 | Change priority in Apple | `C-c r R` → org priority updated |
| 2.3.3 | Add a due date in Apple | `C-c r R` → `DEADLINE` added to org heading |
| 2.3.4 | Remove the due date in Apple | `C-c r R` → `DEADLINE` removed from org heading |
| 2.3.5 | Flag a reminder in Apple | `C-c r R` → `:flagged:` tag added |

### 2.4 New items

| # | Step | Expected |
|---|------|----------|
| 2.4.1 | Add `** TODO My new task` under a list heading in org, save | `REMINDER_ID` and `REMINDER_LIST` stamped; appears in Apple |
| 2.4.2 | Add a new reminder in Apple app | `C-c r R` → appears in org under correct list heading |

### 2.5 Completion

| # | Step | Expected |
|---|------|----------|
| 2.5.1 | Mark org heading `DONE`, `C-c r R` | Apple shows reminder as completed |
| 2.5.2 | Complete a reminder in Apple app | `C-c r R` → org heading marked `DONE` |
| 2.5.3 | Complete in Apple, then `C-c r R` | Heading moves to `DONE`; `[N/M]` cookie decrements |

### 2.6 Conflict resolution

| # | Step | Expected |
|---|------|----------|
| 2.6.1 | Edit title in org AND in Apple before syncing | `C-c r R` → Apple wins (newer modDate); org title overwritten with Apple's |
| 2.6.2 | Save org (push to Apple), immediately edit title in Apple | Next `C-c r R` → Apple wins again (modDate after our push) |
| 2.6.3 | Edit only in org, do not touch Apple | `C-c r R` → org wins; Apple updated |

---

## 3. Background Pull

| # | Step | Expected |
|---|------|----------|
| 3.1 | Wait 5 min (or set `auto-sync-interval` to 10 for testing) | reminders-test.org updated silently; `[N/M]` cookies refreshed |
| 3.2 | Complete a reminder in Apple, wait for background pull | Heading marked `DONE` without manual sync |
| 3.3 | Add reminder in Apple, wait | New heading appears in org |
| 3.4 | Emacs idle at startup (3 sec) | Background pull fires; cache populated |

---

## 4. Dashboard (`C-c r d`)

| # | Step | Expected |
|---|------|----------|
| 4.1 | `C-c r d` with empty cache | Fetches fresh data; `*Apple Reminders*` buffer opens |
| 4.2 | `C-c r d` with populated cache | Opens instantly without network call |
| 4.3 | Press `g` | Refreshes from Apple; done-items list reset |
| 4.4 | Press `t` on a reminder | Heading switches to `DONE`; item disappears from list |
| 4.5 | Press `h` | Completed items shown at bottom of each list |
| 4.6 | Press `h` again | Completed items hidden |
| 4.7 | Press `e` on a reminder | reminders-test.org opens at that heading |
| 4.8 | Press `q` | Dashboard buffer closes |

---

## 5. Delete Reminder (`org-apple-reminders-delete-reminder`)

### 5.1 From the dashboard

| # | Step | Expected |
|---|------|----------|
| 5.1.1 | `C-c r d`, navigate to a reminder heading | — |
| 5.1.2 | Press `d` | Confirmation prompt: `Delete "Title" from Apple Reminders and org?` |
| 5.1.3 | Answer `no` | Nothing happens; reminder stays |
| 5.1.4 | Press `d` again, answer `yes` | Reminder disappears from dashboard immediately |
| 5.1.5 | Check Apple Reminders app | Reminder gone from Apple |
| 5.1.6 | Check reminders-test.org | Heading removed; `[N/M]` cookie updated on next sync |

### 5.2 From reminders.org directly

| # | Step | Expected |
|---|------|----------|
| 5.2.1 | Open reminders-test.org, place point on a `** TODO` heading | — |
| 5.2.2 | `M-x org-apple-reminders-delete-reminder` | Confirmation prompt appears |
| 5.2.3 | Confirm | Heading and its property drawer deleted; file saved |
| 5.2.4 | Check Apple Reminders | Reminder gone |

### 5.3 Edge cases

| # | Step | Expected |
|---|------|----------|
| 5.3.1 | Call delete on a `* ListName` heading (no `REMINDER_ID`) | `user-error: No reminder at point` |
| 5.3.2 | Delete reminder that was already deleted in Apple | No error; org heading still removed |
| 5.3.3 | Delete last reminder in a list | List heading remains; `[0/0]` cookie |

---

## 6. Capture (`C-c c A`)

| # | Step | Expected |
|---|------|----------|
| 6.1 | `C-c c A`, fill in title, `C-c C-c` | Entry added to reminders-test.org under default list |
| 6.2 | Save reminders-test.org | Save hook pushes to Apple; `REMINDER_ID` stamped |

---

## 7. Org-agenda

| # | Step | Expected |
|---|------|----------|
| 7.1 | `M-x org-agenda`, press `A` | Shows all open reminders from reminders-test.org |
| 7.2 | Items with deadlines appear in agenda `d` view | Deadlines visible in standard agenda |

---

## 8. Regression checklist

Run after every feature addition:

- [ ] `C-c r R` completes without error message
- [ ] reminders-test.org paren/structure valid (`M-x org-lint`)
- [ ] `[N/M]` cookies correct after sync
- [ ] Dashboard renders without error
- [ ] Background pull does not freeze Emacs
- [ ] Save hook does not cause infinite save loop
- [ ] No duplicate `REMINDER_ID` entries in org file
- [ ] Fold state preserved after sync (headings not collapsed unexpectedly)
