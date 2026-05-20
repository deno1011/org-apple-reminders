# Roadmap

Planned features and improvements for `org-apple-reminders`.
Items are roughly ordered by priority.

## In Progress

_(nothing in active development)_

## Done

- **URL field via signed Swift helper** (v1.12) — finishes what v1.10 / v1.11
  / v1.11.1 couldn't through `osascript` alone: a tiny (~80 line) Swift
  helper is shipped as embedded source inside `org-apple-reminders.el`
  itself, and on first use the new interactive command

      M-x org-apple-reminders-install-helper

  writes the source + Info.plist to a temp dir, calls `swiftc` with
  `-Xlinker -sectcreate __TEXT __info_plist <plist>` so the Info.plist
  is linked into the binary's `__TEXT,__info_plist` section, ad-hoc-signs
  the binary so macOS TCC honors the bound Info.plist, and caches the
  result under `user-emacs-directory`.  The bound Info.plist carries
  both `NSRemindersUsageDescription` (legacy macOS) and
  `NSRemindersFullAccessUsageDescription` (macOS 14+), the latter being
  what makes `EKEventStore.requestFullAccessToReminders` actually fire
  its completion callback and grant full read access.

  Wire-in:
  - `--fetch-urls` shells out to `<binary> fetch-urls` → JSON map.
  - `--set-url-in-apple` shells out to `<binary> set-url ID URL`.
  - `--merge-urls` injects the map into `org-apple-reminders-sync` and
    `--background-pull` results.
  - `--create-in-apple` / `--update-in-apple` push URLs after the JXA
    field update.
  - Every step no-ops gracefully when the binary is absent, so URL sync
    is opt-in: skip `install-helper` and the package behaves exactly
    like v1.9 (no URL sync, no lag).

  Requires Xcode Command Line Tools.  `install-helper` offers to run
  `xcode-select --install` if `swiftc` is missing.  Pure-Lisp from a
  MELPA perspective: the Swift source and Info.plist live as string
  defconsts in the `.el` file, so no recipe changes are needed.
  ✓ Merged to `main` (v1.12).

- **URL field sync disabled** (v1.11.1) — empirical testing on macOS 14+
  showed v1.11's EventKit approach can't work through `/usr/bin/osascript`:
  the binary's Info.plist declares neither
  `NSRemindersFullAccessUsageDescription` nor any Reminders entitlement,
  so `requestFullAccessToRemindersWithCompletion:` silently never fires
  its callback (adding ~30 s per sync waiting for the runloop timeout),
  and the legacy `requestAccessToEntityType:` grants WRITE-ONLY access
  on macOS 14+ — `r.URL` reads as `null` for every reminder.  This
  release stops calling EventKit in `org-apple-reminders-sync`,
  `--background-pull`, `--create-in-apple`, and `--update-in-apple`,
  restoring sub-second sync.  The `--fetch-urls-script`,
  `--set-url-template`, `--fetch-urls`, `--set-url-in-apple`, and
  `--merge-urls` defuns are kept in the file (dead code) so a future
  helper-binary path can re-enable them.  URL field sync is now a
  known limitation — see "Planned → URL field via signed helper".
  ✓ Merged to `main` (v1.11.1).

- **URL field via EventKit** (v1.11) — v1.10 read/wrote the URL field
  through Apple's scripting dictionary (`r.URL` in JXA), which actually
  fails on modern macOS: the dictionary advertises the property but its
  value is not marshallable to JS (and AppleScript hits "can't be read"
  too).  The URL is reachable only via the **EventKit** framework.

  This release switches both directions of URL sync to EventKit while
  keeping every other field on the existing fast JXA path:
  - `--fetch-urls-script` uses `ObjC.import('EventKit')`,
    `[EKEventStore fetchRemindersMatchingPredicate:completion:]` and
    returns a JSON id → URL map.  Merged into the main fetch result
    inside `org-apple-reminders-sync` and the background pull.
  - `--set-url-template` uses `[EKEventStore calendarItemWithIdentifier:]`
    and `[EKEventStore saveReminder:commit:error:]` to write URLs back.
    Called from `--create-in-apple` after a new reminder is created and
    from `--update-in-apple` alongside every JXA field update.

  EventKit access needs a separate **"Full Access to Reminders"** macOS
  permission, distinct from the Automation permission JXA uses; the
  first sync after upgrading pops a one-time dialog.  Granting persists
  for the calling process identity.  The script polls for the async
  permission/fetch via `NSRunLoop` with a ~30 s timeout, so a denied
  permission or a stuck system fails gracefully instead of hanging.

  Replaces the v1.10/v1.10.1 JXA-based URL handling, which was a silent
  no-op on this user's macOS.  ✓ Merged to `main` (v1.11).

- **URL backfill on sync** (v1.10.1) — `org-apple-reminders-sync`
  (`C-c r R`) now backfills `REMINDER_URL` for already-linked headings
  whose Apple reminder has a URL but whose org heading does not.  The
  backfill runs outside the modDate-gated conflict-resolution so URLs
  added in Apple *before* v1.10 was loaded are picked up on the next
  sync, instead of waiting forever for Apple to bump its modDate.  The
  backfill only sets, never overrides — once the property has a value,
  normal conflict resolution takes over.  ✓ Merged to `main` (v1.10.1).

- **URL field sync** (v1.10) — Apple Reminders' dedicated **URL field** (the
  globe/link icon attachment, distinct from URLs you type into the notes
  body) now round-trips with org. On pull, the URL is stored as a new
  `REMINDER_URL` property next to `REMINDER_ID` / `REMINDER_LIST` in the
  heading's properties drawer. On push, the property's value is written
  back to Apple. Old Reminders versions that don't expose the URL field
  via JXA degrade silently (the property simply isn't created). Conflict
  resolution compares URLs the same way it compares title/due/notes. ✓
  Merged to `main` (v1.10).

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
