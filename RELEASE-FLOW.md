# Release flow

How to ship a fix or new release of `org-apple-reminders`. Designed to be
short, repeatable, and consistent with the conventions established for the
MELPA submission (PR
[#10016](https://github.com/melpa/melpa/pull/10016)).

This document complements [`MELPA-SUBMISSION.md`](MELPA-SUBMISSION.md),
which is a one-time record of the initial submission. This file is the
ongoing playbook.

## The general flow — six steps

Every release — bug fix, doc improvement, or new feature — follows the same
six steps. Once you've done it twice it takes about 5 minutes end-to-end.

### 1. Edit the `.org` literate source

Always edit `org-apple-reminders.org`, **never `.el` directly**. The `.el`
is tangled output and any direct edits get overwritten on the next tangle.

### 2. Re-tangle to update the `.el`

```sh
cd ~/.emacs.d/elpa/org-apple-reminders
emacs --batch -Q -l org \
  --eval '(setq org-confirm-babel-evaluate nil)' \
  --eval '(org-babel-tangle-file "org-apple-reminders.org")'
```

### 3. Run the QC triple

All three must come back clean. The same checks MELPA's CI runs on every
build.

```sh
rm -f org-apple-reminders.elc

# byte-compile — expect no output
emacs --batch -Q -l org -f batch-byte-compile org-apple-reminders.el

# package-lint — expect "clean"
emacs --batch -Q --eval '(progn
  (require (quote package))
  (setq package-archives (quote
    (("melpa" . "https://melpa.org/packages/")
     ("gnu"   . "https://elpa.gnu.org/packages/"))))
  (package-initialize)
  (unless (package-installed-p (quote package-lint))
    (package-refresh-contents)
    (package-install (quote package-lint)))
  (require (quote package-lint))
  (find-file "org-apple-reminders.el")
  (let ((errors (package-lint-buffer)))
    (if errors (dolist (e errors) (princ (format "%S\n" e)))
              (princ "clean\n"))))'

# checkdoc — expect only the one disclosed "C-c r" default-value nit (or no
# findings if that has since been rephrased)
emacs --batch -Q --eval '(progn
  (require (quote checkdoc))
  (find-file "org-apple-reminders.el")
  (let ((checkdoc-create-error-function
         (lambda (text start end &optional unfixable)
           (princ (format "line %s: %s\n"
                          (line-number-at-pos start) text)))))
    (checkdoc-current-buffer t)))'
```

If any of these surface a new finding, fix it before continuing — don't
ship with a regression.

### 4. Bump the version

Edit the `;; Version: X.Y.Z` line in `org-apple-reminders.org` (which
appears once in the package header block). Re-tangle (step 2) so the `.el`
picks it up. See **Versioning** below for what to bump.

### 5. Add a ROADMAP entry

In `ROADMAP.md`, prepend a new bullet under `## Done` in the same style as
the existing entries:

```markdown
- **One-line summary** — concise description of what changed and why.
  Implementation detail if relevant. ✓ Merged to `main` (v1.9.3).
```

### 6. Commit, tag, push

```sh
# Stage exactly the files that changed
git add org-apple-reminders.org org-apple-reminders.el ROADMAP.md

# Conventional commit message
git commit -F- <<'EOF'
fix: <one-line summary>     # or "feat:", "docs:", "refactor:", etc.

<paragraph explaining the change>

Co-Authored-By: Denis Butic <d.e.n.o@gmx.net>
EOF

# Annotated tag with release notes
git tag -a v1.9.3 HEAD -m "v1.9.3: <one-line summary>

- <bullet describing the change>
- <another bullet if needed>

Co-Authored-By: Denis Butic <d.e.n.o@gmx.net>"

# Push main + tag
git push origin main v1.9.3

# Promote to stable via explicit refspec (consistent habit;
# matches the workaround needed in the emacs-mac-setup repo)
git push origin main:refs/heads/stable
```

That's the loop.

## Versioning

What to bump is decided by what changed:

| Change type | Bump | Example |
|---|---|---|
| Pure bug fix (no behaviour change for correct usage) | **patch**: `1.9.2 → 1.9.3` | A JXA edge case fix; a typo in a docstring |
| Small new feature, backward-compatible | **minor**: `1.9.2 → 1.10` | A new opt-in command, a new defcustom, a new optional behaviour |
| Breaking change | **major**: `1.9.2 → 2.0` | Renaming a public command; changing a defcustom's default that users rely on |

### While the MELPA PR is pending

Until PR #10016 is merged, **stay in patch-bump territory unless something
genuinely new ships**. Reviewers prefer to see a candidate that's stable;
a flurry of `v1.10`, `v1.11`, `v1.12` between submission and merge looks
busy. Patch bumps are invisible to MELPA Stable until they're substantial
enough to warrant a re-ping.

### After MELPA acceptance

Same scheme. Patch for fixes, minor for additions, major for breaks.
Continue to ship via the same six-step flow; there's nothing
MELPA-specific to remember once the recipe is merged.

## What to do on the MELPA PR for each kind of change

| Situation | What to do on PR #10016 |
|---|---|
| Silent improvement (typo, small bug, refactor) | **Nothing.** Push the new tag. The recipe's `:branch "stable"` means MELPA rolling auto-picks up your latest stable commit on its next build; MELPA Stable picks up the new tag. |
| Fix addressing a **specific reviewer comment** | **Reply to that comment** mentioning the fix and the new tag: *"Fixed in `v1.9.3` — the literal `\"C-c r\"` in the keymap docstring is now …"*. Closes the loop without a separate re-ping. |
| The 1-month repo-age threshold is met (on or after **2026-06-17**) | **Re-ping with a one-line top-level comment**: *"1-month threshold met (repo public since 2026-05-17), ready for re-review when convenient. Currently at v1.9.X."* |
| Something major changes (new public command, behaviour change) | **Comment on the PR** explaining: *"Heads-up: shipped v1.10 with a new command X. Recipe is unchanged."* Reviewers want to know if the candidate has materially changed since they last looked. |
| Reviewer merges or comments | **Reply within a day** to keep the review loop tight. |

## How the MELPA recipe handles your fixes automatically

The recipe in the PR is:

```elisp
(org-apple-reminders :fetcher github :repo "deno1011/org-apple-reminders" :branch "stable")
```

That single `:branch "stable"` means:

- **Every commit you push to `stable`** becomes the new MELPA **rolling**
  release on the next MELPA build (multiple per day on MELPA's servers).
- **Every new annotated semver tag** (e.g. `v1.9.3`) becomes the new
  MELPA **Stable** release.

So you don't need to do anything special on the MELPA side for fixes to
propagate once the package is merged — `main` → `stable` and tag is the
whole story. Same for now while the PR is pending; the discipline of
pushing both is just useful habit.

## A concrete example — bug found, fix shipped

You discover a bug in the JXA fetch path. Total elapsed time, end to end:
~5 minutes.

```sh
cd ~/.emacs.d/elpa/org-apple-reminders

# 1. Open org-apple-reminders.org in Emacs, fix the bug in the relevant src
#    block.

# 2. Re-tangle
emacs --batch -Q -l org \
  --eval '(setq org-confirm-babel-evaluate nil)' \
  --eval '(org-babel-tangle-file "org-apple-reminders.org")'

# 3. QC triple — copy-paste all three commands from §1.3 above; expect
#    silence, "clean", and at most the one disclosed checkdoc nit.

# 4. Bump version 1.9.2 → 1.9.3 in the .org's `;; Version:` line, re-tangle.

# 5. Prepend a ROADMAP entry under `## Done`.

# 6. Commit + tag + push
git add org-apple-reminders.org org-apple-reminders.el ROADMAP.md
git commit -F- <<'EOF'
fix(fetch): handle reminders without modificationDate

Some legacy Apple reminders return a null modificationDate from JXA,
which crashed the JSON.stringify path. Guard with a null check.

Co-Authored-By: Denis Butic <d.e.n.o@gmx.net>
EOF
git tag -a v1.9.3 HEAD -m "v1.9.3: handle null modificationDate in fetch

- The JXA fetch script now treats a null modificationDate the same as a
  missing one. Legacy reminders with no recorded modification time no
  longer crash the sync.

Co-Authored-By: Denis Butic <d.e.n.o@gmx.net>"
git push origin main v1.9.3
git push origin main:refs/heads/stable
```

Done. PR #10016 untouched (the auto-propagation handles it). The bug is
fixed for any future user installing from MELPA.

## Three habits worth keeping

1. **Run the QC triple after every change.** It takes ~30 seconds combined
   and catches regressions immediately. Build the muscle memory now and
   you'll never ship a `package-lint` warning by accident.

2. **One change per release.** Don't bundle unrelated fixes into one tag.
   `v1.9.3 → v1.9.4 → v1.9.5` each as a small, reviewable, revertable unit
   is much better than one bloated `v1.9.3` that mixes a JXA fix, a doc
   typo, and a refactor. If you need to revert one, you can revert the
   whole tag.

3. **Update `MELPA-SUBMISSION.md` only when its content drifts.** That
   file is a point-in-time record of the original submission. If something
   in it becomes inaccurate (e.g. the `checkdoc` nit gets rephrased and
   the box is now fully clean), update the affected section. Otherwise
   leave it alone — it's the record, not a living spec.

## When **not** to follow this flow — feature branches

If you're experimenting — exploring a refactor that may not land, testing
a speculative idea, prototyping something on company time — do it on a
**feature branch**, not `main`:

```sh
git checkout -b feature/idea-name
# … hack …
git push origin feature/idea-name
```

Nothing on a feature branch affects MELPA. The recipe builds from
`stable`, and `stable` only receives merges from `main`, and `main`
only receives merges from feature branches when you're confident the
idea is real.

When the idea is solid, merge to `main` with `--no-ff` so the merge
commit survives:

```sh
git checkout main
git merge --no-ff feature/idea-name -m "merge: feature/idea-name → main (v1.10)"
```

…then follow the six-step release flow above (bump, ROADMAP, tag, push).

For pre-MELPA-merge fixes, the feature-branch step is usually skippable
(changes are small enough that a direct commit on `main` is fine). But
for anything you're not 100% sure about, branch.

## A two-command cheat sheet

The two `git push` lines that cover 90% of fixes once you've committed
and tagged locally:

```sh
git push origin main vX.Y.Z              # ship to MELPA rolling + tag
git push origin main:refs/heads/stable   # ship to MELPA Stable
```

Run them after every release, and the rest takes care of itself.
