# org-apple-reminders

Bidirectional sync between Emacs [org-mode](https://orgmode.org) and macOS Apple Reminders via JavaScript for Automation (JXA). No third-party CLI tools required.

## Features

- Full bidirectional sync: org ↔ Apple Reminders
- Conflict resolution via dual timestamps (`REMINDER_APPLE_MOD` / `REMINDER_ORG_MOD`)
- Fields synced: title, due date, priority (A/B/C ↔ 1/5/9), flagged/starred, notes
- Progress cookies `[N/M]` on list headings
- Live dashboard in `*Apple Reminders*` buffer
- Org-agenda and org-capture integration
- Automatic background pull (configurable interval)

## Requirements

- macOS 10.14 (Mojave) or later — JXA support required
- Emacs 27.1+
- org-mode 9.3+

## Installation

### Via MELPA

```emacs-lisp
(use-package org-apple-reminders
  :ensure t
  :after org
  :config
  (setq org-apple-reminders-sync-file "~/org/reminders.org")
  (org-apple-reminders-setup))
```

Or with `package-install`:

```
M-x package-install RET org-apple-reminders RET
```

### Manual

Clone this repository and add it to your load path:

```emacs-lisp
(add-to-list 'load-path "/path/to/org-apple-reminders")
(require 'org-apple-reminders)
(setq org-apple-reminders-sync-file "~/org/reminders.org")
(org-apple-reminders-setup)
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `org-apple-reminders-sync-file` | `"~/org/reminders.org"` | Org file mirrored with Apple Reminders |
| `org-apple-reminders-sync-list` | `nil` (auto) | Default Apple list for new org items |
| `org-apple-reminders-default-list` | `nil` (auto) | Fallback list for interactive commands |
| `org-apple-reminders-auto-sync-interval` | `300` | Seconds between background pulls (0 = off) |
| `org-apple-reminders-agenda-file` | `nil` | Optional separate read-only agenda file |

### Suggested key bindings

Add to your init file after `(org-apple-reminders-setup)`:

```emacs-lisp
(global-set-key (kbd "C-c r d") #'org-apple-reminders-dashboard)
(global-set-key (kbd "C-c r R") #'org-apple-reminders-sync)
(global-set-key (kbd "C-c r a") #'org-apple-reminders-add)
(global-set-key (kbd "C-c r l") #'org-apple-reminders-show-lists)
(global-set-key (kbd "C-c r L") #'org-apple-reminders-create-list)

(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c r p") #'org-apple-reminders-push-heading)
  (define-key org-mode-map (kbd "C-c r D") #'org-apple-reminders-delete-reminder))
```

## Usage

### Sync

`M-x org-apple-reminders-sync` (suggested: `C-c r R`)

Full bidirectional sync between `org-apple-reminders-sync-file` and all your Apple Reminders lists. The sync file is created automatically on first run.

Background pulls happen automatically every `org-apple-reminders-auto-sync-interval` seconds and whenever Emacs is idle for 3 seconds after startup.

### Dashboard

`M-x org-apple-reminders-dashboard` (suggested: `C-c r d`)

Opens the `*Apple Reminders*` buffer showing all lists and items. Dashboard key bindings:

| Key | Action |
|---|---|
| `g` | Refresh from Apple |
| `t` / `C-c C-t` | Complete reminder at point |
| `d` | Delete reminder from Apple and org |
| `e` | Jump to heading in reminders.org |
| `h` | Toggle visibility of completed items |
| `q` | Quit window |

### Capture

After `(org-apple-reminders-setup)`, a capture template is registered under key `A`:

```
C-c c A   → Apple Reminder
```

The new entry is pushed to Apple on the next save of `reminders.org`.

### Interactive commands

| Command | Description |
|---|---|
| `org-apple-reminders-sync` | Full bidirectional sync |
| `org-apple-reminders-dashboard` | Open dashboard buffer |
| `org-apple-reminders-dashboard-refresh` | Fetch fresh data and re-render |
| `org-apple-reminders-add` | Add a new reminder interactively |
| `org-apple-reminders-push-heading` | Push org heading at point to Apple (`C-c r p` in org) |
| `org-apple-reminders-delete-reminder` | Delete reminder from Apple and org (`d` in dashboard, `C-c r D` in org) |
| `org-apple-reminders-show-lists` | List all Apple Reminders lists |
| `org-apple-reminders-create-list` | Create a new Apple Reminders list |
| `org-apple-reminders-migrate-flat-headings` | One-time migration from flat layout |

### Live editing in reminders.org

Changes to `reminders.org` push to Apple automatically:

- **Save**: all changed entries pushed to Apple
- **`C-c ,`** (priority): pushed immediately via advice
- **`C-c C-d`** (deadline): pushed immediately via advice
- **`C-c C-q`** (tags): pushed immediately via advice
- **TODO state change**: pushed immediately via hook

## Sync file structure

```org
#+TITLE: Reminders
#+STARTUP: overview
#+TODO: TODO NEXT WAITING | DONE CANCELLED

* Work [2/5]
** TODO [#A] Prepare Q3 report
   DEADLINE: <2025-09-30>
   :PROPERTIES:
   :REMINDER_ID:   x-apple-reminder://...
   :REMINDER_LIST: Work
   :REMINDER_APPLE_MOD: 2025-09-01T10:00:00Z
   :END:

* Personal [0/1]
** TODO Buy groceries
   :PROPERTIES:
   :REMINDER_ID:   x-apple-reminder://...
   :REMINDER_LIST: Personal
   :END:
```

Items are nested under `* ListName [N/M]` headings. The `[N/M]` cookie shows completed/total counts and updates on every sync.

### Property reference

| Property | Set by | Meaning |
|---|---|---|
| `REMINDER_ID` | Package | Apple's unique reminder ID |
| `REMINDER_LIST` | Package | Apple list name |
| `REMINDER_APPLE_MOD` | Package | Apple's `modificationDate` when last pulled |
| `REMINDER_ORG_MOD` | Package | Apple's `modificationDate` right after org pushed |

## Field mapping

| Org | Apple Reminders |
|---|---|
| Heading title | Reminder name |
| `DEADLINE` | Due date |
| Priority `[#A]` / `[#B]` / `[#C]` | Priority 1 / 5 / 9 |
| Tag `:flagged:` | Flagged (starred) |
| Body text (below heading, excl. LOGBOOK) | Notes |
| `DONE` / `CANCELLED` state | Completed |

Progress cookies `[N/M]` on list headings are computed locally and never sent to Apple.

## Implementation

### Architecture

The package uses **JavaScript for Automation (JXA)** via `osascript -l JavaScript` to talk directly to Apple Reminders — no CLI tools, no AppleScript parsing. All Apple calls are either:

- **Async** (`org-apple-reminders--jxa-async`): `make-process` with a sentinel callback — used for fire-and-forget writes (complete, create) and background pulls.
- **Sync** (`org-apple-reminders--jxa-run`): `shell-command-to-string` — used only in `org-apple-reminders-sync` where we need the result before proceeding.

### Conflict resolution (two-timestamp model)

The core challenge is knowing who changed what since the last sync. The package avoids content hashing and instead tracks two Apple `modificationDate` timestamps per entry:

- **`REMINDER_APPLE_MOD`**: Apple's `modificationDate` at the moment we last applied Apple's data to org (background pull, Apple-wins branch of sync, or new item pulled from Apple).
- **`REMINDER_ORG_MOD`**: Apple's `modificationDate` immediately after we last pushed org data to Apple (save hook, org-wins branch of sync).

On each sync, for an entry with Apple `modDate = A`:

```
last-known = max(REMINDER_APPLE_MOD, REMINDER_ORG_MOD)
apple-changed = A > last-known
```

- **`apple-changed` = true** → Apple wins: pull priority/due/flagged from Apple, stamp `REMINDER_APPLE_MOD = A`.
- **`apple-changed` = false** → org wins: compare org fields against Apple's fetched state; push only if different, stamp `REMINDER_ORG_MOD` = Apple's post-push `modificationDate`.

Both timestamps are Apple ISO 8601 UTC strings, so `string>` comparison works directly without parsing.

### Batch JXA fetch

The fetch script reads all lists and items in a single JXA call using batch property accessors (`rs.name()`, `rs.dueDate()`, etc.) rather than item-by-item iteration. This avoids the Apple Events round-trip overhead and keeps sync fast even with hundreds of reminders.

Due dates are reconstructed as local `YYYY-MM-DD` strings from the `Date` object components to avoid UTC offset issues. `modificationDate` is converted to ISO 8601 UTC via `.toISOString()` for consistent `string>` comparison.

### Save hook and cache

The save hook (`after-save-hook`) avoids fetching from Apple on every save. Instead it compares the current org entry values against the **in-memory cache** (`org-apple-reminders--cache`) populated by the last background pull or full sync. Only entries that differ from the cache are pushed. This makes saves instant.

### Progress cookies

Before each `save-buffer`, `org-map-entries` runs over all level-1 headings (list headings). If a heading lacks an `[N/M]` cookie, one is inserted as `[/]`. Then `org-update-statistics-cookies` recomputes it from the TODO states of child headings.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

## Author

Denis Butic &lt;d.e.n.o@gmx.net&gt;
