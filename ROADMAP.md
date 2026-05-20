# Roadmap

Planned features and improvements for `org-apple-reminders`.
Items are roughly ordered by priority.

## In Progress

_(nothing in active development)_

## Done

- **URL field sync removed** (v1.13) — Five attempts (v1.10, v1.10.1,
  v1.11, v1.11.1, v1.12) tried to round-trip Apple Reminders' "link"
  attachment (the globe icon shown on a reminder card).  Each attempt
  was technically clean but observationally broken:

  - **v1.10** read/wrote via JXA's `r.URL`.  On modern macOS the
    scripting dictionary advertises the property but refuses to marshal
    its value ("Types cannot be converted") and AppleScript hits
    `-1728 can't be read`.
  - **v1.10.1** added a backfill path so URLs visible in Apple before
    install would be picked up; same JXA failure.
  - **v1.11** moved to EventKit via the JXA→ObjC bridge.  On macOS 14+
    `requestFullAccessToReminders` silently never fires its callback
    because `/usr/bin/osascript` declares neither
    `NSRemindersFullAccessUsageDescription` nor a Reminders entitlement.
    Added ~30 s lag per sync from the runloop timeout.
  - **v1.11.1** disabled the EventKit calls in sync paths to restore
    sub-second performance while keeping the dead code in place.
  - **v1.12** shipped a compiled, ad-hoc-signed Swift helper with the
    correct Info.plist as embedded source.  `swiftc` + `codesign` ran
    cleanly; macOS TCC granted `fullAccess`; `fetchReminders` returned
    every reminder.  But `EKReminder.url` was `nil` on every reminder,
    including those the Reminders.app UI clearly showed as having a
    URL attachment.  Writing to `EKReminder.url` from EventKit
    succeeded silently — the value persisted in EventKit and survived
    a read — but **the Reminders.app did not display it**, and the
    user's original URL stayed visible alongside.  Verified by writing
    a distinctive marker URL and inspecting the app: both visible
    URLs were the user's; the marker was invisible.

  Conclusion: Apple stores user-added URLs in a private location
  outside any public scripting / EventKit interface.  `EKReminder.url`
  is a distinct field the Reminders app neither reads nor displays.
  There is no public path on current macOS, so v1.13 removes all URL
  handling — the `REMINDER_URL` property is no longer written, the
  helper command, the embedded Swift source, the EventKit defconsts,
  the JXA URL extraction, and every conflict-resolution branch that
  touched URLs are all gone.  Existing `REMINDER_URL` properties in
  user org files are left untouched (will not be deleted), they just
  stop syncing.

  Lesson learned: unproven feature work should live on
  `feature/<name>` branches and never touch `main` / `stable` until
  observation, not just compilation, confirms it works.  See
  `RELEASE-FLOW.md` § feature branches.
  ✓ Merged to `main` (v1.13).

- **Delete-reminder: mark DONE across all known files** (v1.9.3) — `C-c r D`
  no longer deletes the org heading.  It deletes the Apple reminder, marks
  the linked org heading as DONE, strips the `REMINDER_*` link properties,
  and sets `REMINDER_NOSYNC` — both at point and in any other known org
  file (`extra-files`, `org-agenda-files`) that contains the same
  `REMINDER_ID`.  The DONE heading is kept so an accidental delete can be
  recovered: change it back to TODO and `C-c r p` recreates a fresh Apple
  reminder.  `C-c r d` (`remove-from-apple`) is unchanged.  Defensive
  `--syncing` binding extended over the full operation in both commands.
  ✓ Merged to `main` (v1.9.3).

- **GPL boilerplate** (v1.9.2) — add the full short-form GNU GPL-3.0
  notice above `;;; Commentary`, as MELPA's CONTRIBUTING.org requires
  ("The license boilerplate should be applied above the `;;; Commentary`
  of each source file").  The `SPDX-License-Identifier` line stays as
  well.  No code changes. ✓ Merged to `main` (v1.9.2).

- **MELPA hygiene** (v1.9.1) — make the package land cleanly with MELPA's
  reviewers: drop the spurious `(cl-lib "0.5")` dependency (`cl-lib` is
  built-in on Emacs ≥ 24.3); replace `with-eval-after-load` in
  `org-apple-reminders-setup` with explicit `(require 'org-agenda)` and
  `(require 'org-capture)`; add `defvar`/`declare-function` forward
  declarations for free variables and `org-agenda-redo`; rewrap long
  docstrings and quote `` `org-agenda' `` per `checkdoc`; add the
  MELPA-required `Assisted-by: Claude:claude-opus-4-7` header line per
  MELPA's AI-attribution policy. Byte-compile and `package-lint` now both
  clean. ✓ Merged to `main` (v1.9.1).

- **Included-lists fully repopulate `reminders.org`** — `C-c r i` now queries
  Apple live, so lists created since the last sync can be picked. A full sync
  (`C-c r R`) makes `reminders.org` mirror exactly the current selection:
  sections for de-selected lists are pruned (pure-reminder sections only —
  hand-written content is left alone), and every included list gets a
  `* List` section even when it is empty. Progress cookies `[N/M]` are
  recalculated after the pull so freshly synced lists show correct counts
  immediately. ✓ Merged to `main` (v1.9).

- **Region delete / remove** — `org-apple-reminders-delete-reminder`
  (`C-c r D`) and `org-apple-reminders-remove-from-apple` (`C-c r d`) now act
  on every reminder in an active region, not just the one at point, behind a
  single confirmation prompt. The minibuffer-only `org-apple-reminders-add`
  command was removed — `push-heading` (`C-c r p`) and the capture template
  already cover quick-add. ✓ Merged to `main` (v1.9).

- **Push a selection of headings** — `org-apple-reminders-push-heading`
  (`C-c r p`, also `C-c r m`) now works on an active region: every heading in
  the selection is processed in one step — unlinked TODOs are created, linked
  ones already in the list are updated, and linked ones in another list are
  moved. Non-task headings in the region are skipped. The target list is
  created in Apple Reminders if it does not exist. A separate "move" command
  proved redundant — push is a superset — so `m` is an alias for `p`.
  ✓ Merged to `main` (v1.8).

- **Move on push** — `org-apple-reminders-push-heading` (`C-c r p`) no longer
  duplicates an already-linked task. Pushing it to its current list updates
  it in place; pushing it to a different list MOVES it — the old Apple
  reminder is deleted and recreated in the new list. Inside `reminders.org`
  the heading's subtree is relocated under the new `* List`; in any other org
  file the heading keeps its place and only its properties change. Unlinked
  headings are still created fresh and never moved. ✓ Merged to `main` (v1.7).

- **Delete reminder** (`org-apple-reminders-delete-reminder`) — removes a
  reminder from both Apple and reminders.org in one step. Works directly in
  reminders.org (`C-c r D`). ✓ Merged to `main`.

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

- **Dashboard interactive actions** — reopen, priority cycling, set/clear due
  date, TODO state cycling, all pushing to Apple immediately via JXA.
  ✓ Merged to `main` (v1.4–v1.5); entire dashboard removed in v1.6.

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

The dashboard (`*Apple Reminders*` buffer) was removed in v1.6. All planned
dashboard features below are no longer applicable.

- ~~**Inline rename**~~ — not applicable; dashboard removed.
- ~~**New reminder from dashboard**~~ — not applicable; use `org-apple-reminders-add` instead.
- ~~**Sort**~~ — not applicable; dashboard removed.
- ~~**Filter**~~ — not applicable; dashboard removed.

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
