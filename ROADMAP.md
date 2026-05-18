# Roadmap

Planned features and improvements for `org-apple-reminders`.
Items are roughly ordered by priority.

## In Progress

_(nothing in active development)_

## Done

- **Delete reminder** (`org-apple-reminders-delete-reminder`) — removes a
  reminder from both Apple and reminders.org in one step. Works from the
  dashboard (`d`) and directly in reminders.org. ✓ Merged to `main`.

- **Due time** — Apple's time component now round-trips: Apple `HH:MM` →
  org `<YYYY-MM-DD Dow HH:MM>` → Apple `HH:MM`. Date-only reminders are
  unaffected. ✓ Merged to `main` (v1.1).

- **Selective list sync** — `org-apple-reminders-included-lists`: set to a
  list of names to restrict which Apple lists are pulled into org. Items
  already in the org file are always kept in sync. ✓ Merged to `main` (v1.2).

- **Non-blocking save hook** — the `after-save-hook` no longer blocks Emacs
  while pushing to Apple. `--default-list` is now lazy (only called when new
  items exist); existing-item updates use async JXA with a marker callback.
  A 2-second idle timer persists `REMINDER_ORG_MOD` after async callbacks
  complete. ✓ Merged to `main` (v1.3).

## Planned

### Reminder management

- **Recurring reminders** — Apple has `recurrenceRule` (daily/weekly/monthly
  etc.); org has `SCHEDULED` with repeaters (`.+1w`, `++1m` etc.). Plan: map
  the most common recurrence patterns bidirectionally.

- **Subtasks** — Apple Reminders supports nested reminders (subtasks); org
  has child headings. Plan: sync one level of nesting — Apple subtasks become
  `*** TODO` headings under the parent `** TODO` heading.

- **Rename list** — rename an Apple Reminders list and update all
  `REMINDER_LIST` properties in the org file accordingly.

- **Delete list** — delete an entire Apple Reminders list and its
  corresponding `* ListName` section from the org file.

### Sync improvements

- **Re-link orphaned headings** — if `REMINDER_ID` is lost (e.g. after
  export/import), provide a command to match an existing org heading to an
  Apple reminder by title and re-stamp the ID.

- **Selective list sync** — ✓ done (v1.2). See `org-apple-reminders-included-lists`.

- **Conflict log** — when Apple wins a conflict, log the old org value and
  new Apple value to a `*org-apple-reminders conflicts*` buffer so the user
  can review what changed.

### Dashboard

- **Inline rename** — edit the reminder title directly in the dashboard
  buffer without jumping to reminders.org.

- **New reminder from dashboard** — press `n` in the dashboard to capture a
  new reminder without leaving the buffer.

- **Sort** — toggle sort by due date, priority, or list name (`s` key).

- **Filter** — show only due today, only high priority, or a specific list
  (`/` key).

### Infrastructure

- **MELPA release** — PR [#10016](https://github.com/melpa/melpa/pull/10016)
  open; `stable` branch is what MELPA builds from. Merge `main` → `stable`
  when a feature set is ready for release.

- **Test suite** — add ERT tests for conflict resolution logic, field
  extraction, and JXA script generation (with mocked `osascript`).

- **Emacs 29 `:vc` support** — once on MELPA, document `use-package` with
  `:vc` as an alternative install path for Emacs 29+.

## Ideas / Under Discussion

- **List colour/icon** — Apple stores a colour and icon per list; could be
  reflected as org tags or heading properties (read-only, display only).

- **Siri shortcuts integration** — trigger a sync via a Siri shortcut or
  macOS Automator action from outside Emacs.

- **beorg compatibility** — ensure the org file structure produced by this
  package is compatible with [beorg](https://beorgapp.com) for iPhone access.
