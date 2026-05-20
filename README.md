# org-apple-reminders

Bidirectional sync between Emacs [org-mode](https://orgmode.org) and macOS Apple Reminders via JavaScript for Automation (JXA). No third-party CLI tools required.

## Features

- Full bidirectional sync: org ↔ Apple Reminders
- Conflict resolution via dual timestamps (`REMINDER_APPLE_MOD` / `REMINDER_ORG_MOD`)
- Fields synced: title, due date + time, priority (A/B/C ↔ 1/5/9), flagged/starred, notes; URL field opt-in via a tiny signed Swift helper (see [URL field](#url-field-optional))
- Selective list sync — choose which Apple lists appear in org
- Push any org heading — or a whole region of headings — to Apple; move reminders between lists
- Progress cookies `[N/M]` on list headings
- Org-agenda and org-capture integration
- Automatic background pull (configurable interval)

## Requirements

- macOS 10.14 (Mojave) or later — JXA support required
- Emacs 27.1+
- org-mode 9.3+
- **Optional:** Xcode Command Line Tools (`xcode-select --install`) — only if you want URL-field sync; see [URL field](#url-field-optional)

## URL field (optional)

Apple's scripting dictionary does not expose the URL field of a reminder
(the dedicated link attachment shown as a globe in the Reminders app).
The field is only reachable via EventKit, and on macOS 14+ EventKit
requires the calling binary to declare `NSRemindersFullAccessUsageDescription`
in its Info.plist **and** be code-signed. `/usr/bin/osascript` satisfies
neither requirement, so URL sync is opt-in via a tiny Swift helper that
this package ships as embedded source and compiles on demand.

Install it once:

```
M-x org-apple-reminders-install-helper
```

This:

1. Checks for `swiftc`; if missing, offers to run `xcode-select --install`.
2. Writes the embedded Swift source and `Info.plist` to a temp dir.
3. Calls `swiftc -O -Xlinker -sectcreate __TEXT __info_plist <plist> …` so
   the `Info.plist` is linked into the binary's `__TEXT,__info_plist`
   section.
4. Ad-hoc-signs the binary with `codesign -s - --force` so macOS TCC
   honors the bound Info.plist.
5. Caches the binary under `user-emacs-directory`.

The next sync (`C-c r R`) pops a one-time macOS dialog asking for
**"Full Access to Reminders"**. Click *Allow*. From then on, URLs
round-trip into the `REMINDER_URL` property and back to Apple. Sub-second
sync performance is preserved.

If you skip this step, URL sync silently no-ops and the package behaves
as if the URL field didn't exist — no errors, no lag, just no URL data.

## Installation

### Via MELPA

```emacs-lisp
(use-package org-apple-reminders
  :ensure t
  :after org
  :config
  (setq org-apple-reminders-sync-file "~/org/reminders.org")
  ;; Optional: limit which Apple lists are pulled into org.
  ;; Run M-x org-apple-reminders-show-lists to see your list names.
  ;; (setq org-apple-reminders-included-lists '("Work" "Personal"))
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
| `org-apple-reminders-auto-sync-interval` | `300` | Seconds between background pulls (0 = off) |
| `org-apple-reminders-agenda-file` | `nil` | Optional separate read-only agenda file |
| `org-apple-reminders-included-lists` | `nil` (all) | Config-declared lists to sync; nil means all lists |
| `org-apple-reminders-included-lists-prefer-config` | `nil` | If non-nil, the config list always wins over the saved one |
| `org-apple-reminders-saved-included-lists` | `unset` | Set by `C-c r i`, persisted to `custom-file` — don't edit by hand |
| `org-apple-reminders-extra-files` | `nil` | Extra org files scanned for linked reminder headings |
| `org-apple-reminders-keymap-prefix` | `"C-c r"` | Prefix key for the command map; `nil` to not bind |

Set `org-apple-reminders-included-lists` to restrict which Apple Reminders lists are pulled into org:

```emacs-lisp
(setq org-apple-reminders-included-lists '("Work" "Personal"))
```

Items already in the org file are always kept in sync; the filter only prevents new Apple items from being pulled into org.

#### Choosing synced lists interactively

`C-c r i` (`org-apple-reminders-set-included-lists`) opens a multi-select over
your Apple lists — pick the ones to sync, deselect to drop them, pick none for
"all lists". The choice is saved to `custom-file` so it survives restarts.

There are two values and a switch:

- `org-apple-reminders-included-lists` — what you declare in your init/config.
- `org-apple-reminders-saved-included-lists` — what `C-c r i` saves.
- `org-apple-reminders-included-lists-prefer-config` — the switch: `t` → the
  config value always wins (the saved value is ignored); `nil` (default) → the
  saved value wins once `C-c r i` has run, with the config value as fallback.

The package picks between them explicitly, so precedence never depends on
Emacs file-load order.

### Key bindings

`org-apple-reminders-setup` installs a command keymap automatically under
the `C-c r` prefix — no manual `define-key` calls required.

| Key | Command |
|---|---|
| `C-c r R` | `org-apple-reminders-sync` |
| `C-c r f` | `org-apple-reminders-open-file` |
| `C-c r l` | `org-apple-reminders-show-lists` |
| `C-c r L` | `org-apple-reminders-create-list` |
| `C-c r X` | `org-apple-reminders-delete-list` |
| `C-c r i` | `org-apple-reminders-set-included-lists` |
| `C-c r p` | `org-apple-reminders-push-heading` |
| `C-c r m` | `org-apple-reminders-push-heading` (alias of `C-c r p`) |
| `C-c r d` | `org-apple-reminders-remove-from-apple` |
| `C-c r D` | `org-apple-reminders-delete-reminder` |

To use a different prefix, set `org-apple-reminders-keymap-prefix` before
calling `org-apple-reminders-setup`:

```emacs-lisp
(setq org-apple-reminders-keymap-prefix "C-c a")
```

Set it to `nil` to bind no prefix and wire up the keymap yourself:

```emacs-lisp
(setq org-apple-reminders-keymap-prefix nil)
(keymap-global-set "C-c a" org-apple-reminders-command-map)
```

## Usage

### Sync

`M-x org-apple-reminders-sync` (suggested: `C-c r R`)

Full bidirectional sync between `org-apple-reminders-sync-file` and all your Apple Reminders lists. The sync file is created automatically on first run.

Background pulls happen automatically every `org-apple-reminders-auto-sync-interval` seconds and whenever Emacs is idle for 3 seconds after startup.

### Capture

After `(org-apple-reminders-setup)`, a capture template is registered under key `A`:

```
C-c c A   → Apple Reminder
```

The new entry is pushed to Apple on the next save of `reminders.org`.

### Interactive commands

| Command | Description |
|---|---|
| `org-apple-reminders-sync` | Full bidirectional sync (`C-c r R`) |
| `org-apple-reminders-open-file` | Open `reminders.org` directly (`C-c r f`) |
| `org-apple-reminders-push-heading` | Push the heading at point — or every heading in the active region — to Apple, from any org file (`C-c r p`, also `C-c r m`) |
| `org-apple-reminders-remove-from-apple` | Delete the Apple reminder but keep the org heading — point, or every reminder in the region (`C-c r d`) |
| `org-apple-reminders-delete-reminder` | Delete reminder from Apple **and** org — point, or every reminder in the region (`C-c r D`) |
| `org-apple-reminders-show-lists` | List all Apple Reminders lists (`C-c r l`) |
| `org-apple-reminders-create-list` | Create a new Apple Reminders list (`C-c r L`) |
| `org-apple-reminders-delete-list` | Delete a whole Apple list **and** its `* ListName` section (`C-c r X`) |
| `org-apple-reminders-set-included-lists` | Multi-select which lists sync; saved permanently (`C-c r i`) |
| `org-apple-reminders-migrate-flat-headings` | One-time migration from flat layout |

### Pushing headings to Apple

`org-apple-reminders-push-heading` (`C-c r p`, also bound to `C-c r m`)
links org headings to Apple Reminders. It works in **any** org buffer — not
only `reminders.org`.

- **One heading** — point at a heading, press `C-c r p`, choose a list.
- **Several at once** — mark a region covering multiple headings and press
  `C-c r p`; every heading in the selection is processed in one step.

What happens to each heading depends on its current state:

| Heading | Result |
|---|---|
| Unlinked `TODO` / `NEXT` / `WAITING` | A new Apple reminder is created in the chosen list |
| Already linked to that list | The Apple reminder is updated |
| Linked to a **different** list | **Moved** — the old Apple reminder is deleted and recreated in the chosen list (never duplicated) |
| Not a task (e.g. a `* List` heading) | Skipped — region mode only |

The chosen list is **created in Apple** automatically if it does not exist.

Where the org heading ends up after a push:

- **In `reminders.org`** — a created or moved heading's subtree is placed
  under the target `* List` heading, so the file keeps mirroring Apple.
- **In any other org file** — the heading stays exactly where it is; only
  its `REMINDER_*` properties change. A heading living in a project or notes
  file is never torn out of its document.

When you push from a file other than `reminders.org`, that file is
registered in `org-apple-reminders-extra-files` so future syncs keep it up
to date. `C-c r m` is a convenience alias for `C-c r p`.

`org-apple-reminders-remove-from-apple` (`C-c r d`) is the inverse of a
push: it deletes the Apple-side reminder, removes the `REMINDER_*` link
properties, and sets `REMINDER_NOSYNC: t` on the heading so it stays in the
org file as a plain TODO and is never pushed back. Re-link it later with
`C-c r p`.

### Deleting reminders

Two commands remove reminders, both with a confirmation prompt:

- **`org-apple-reminders-delete-reminder`** (`C-c r D`) — deletes the
  reminder from Apple Reminders **and** removes the org heading.
- **`org-apple-reminders-remove-from-apple`** (`C-c r d`) — deletes only the
  Apple reminder; the org heading stays as a plain TODO (see above).

Both act on the reminder at point, or — with an **active region** — on
*every* reminder in the selection at once. Mark a block of headings, press
`C-c r D` (or `C-c r d`), confirm the count, and they are all removed in one
step. Headings in the region without a `REMINDER_ID` are ignored.

### Selective list sync

By default every Apple Reminders list is mirrored into org. If you have
shopping lists, cleaning schedules, or OmniFocus mirrors that you never want
in org-agenda, restrict the sync to specific lists.

**Interactively (recommended)** — press `C-c r i` and multi-select the lists
to sync. The picker queries Apple live, so lists created since the last sync
are offered too. The choice is saved to `custom-file` and survives restarts.
See [Choosing synced lists interactively](#choosing-synced-lists-interactively).

**In your config** — set the variable directly:

```emacs-lisp
(setq org-apple-reminders-included-lists '("Work" "Personal"))
```

`reminders.org` mirrors exactly the included lists. On the next full sync
(`C-c r R`):

- items from included lists are pulled in;
- a list **removed** from the set has its whole `* List` section deleted
  from `reminders.org` (only if every heading under it is a linked
  reminder — hand-written content is never touched). The Apple list itself
  is untouched; re-include the list to pull it back.

Reminders linked from **other** org files keep syncing bidirectionally
regardless of this setting — selective sync only governs the `reminders.org`
mirror.

Set to `nil` (the default) to sync all lists.

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
| `REMINDER_NOSYNC` | `remove-from-apple` | When set, the heading is never pushed to Apple |

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
