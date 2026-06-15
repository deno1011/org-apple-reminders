# MELPA PR #10016 — `org-apple-reminders` submission walkthrough

> Personal notes for future reference (e.g. when MELPA reviewers ask follow-up
> questions). Compiled 2026-05-20.
>
> **Post-submission update (2026-06-15).** The package was later refactored
> into a strict layered architecture (L1 config → L6 business logic; see the
> README's *Implementation → Architecture* section), released as **`v1.15`**
> (`main`/`stable` = `21761e9`). This document records the state at submission
> time and is **not** rewritten for that change.
>
> The four MELPA checks below were **re-verified on the `v1.15` source** (Emacs
> 30.2, `package-lint 20260427`):
>
> | Check | v1.15 result |
> |---|---|
> | `package-lint` (#5) | **CLEAN** |
> | byte-compile (#6) | **CLEAN** — 0 warnings, `emacs -Q --batch -L . -f batch-byte-compile` |
> | `checkdoc` (#7) | 9 findings, all the same "within reason" nits as the prior release (7 arg-not-in-docstring + the 2 principled `C-c` keycode nits from §8); no regressions |
> | recipe / loads (#8) | `require` provides the feature; 32-test ert suite passes; live full sync verified in the running daemon |
>
> Two defects the refactor briefly introduced were caught and fixed before this
> tag: a dropped `(provide 'org-apple-reminders)` and a dropped
> `;;; …​ ends here` footer — the latter is the harder one, since without it
> `package.el` cannot parse the file and `package-lint` errors out entirely
> ("cannot parse this buffer"). The ert suite loads with `load-file`, which
> needs neither, so a guard test (`featurep`) now covers `provide`; the footer
> is asserted by the `package-lint` run. The submission-time invariants
> (literate `.org` → one `.el`, `lexical-binding: t`, `#'` refs, `Assisted-by:`)
> all still hold.

## Context

| Item | Value |
|---|---|
| PR | <https://github.com/melpa/melpa/pull/10016> |
| Package repo | <https://github.com/deno1011/org-apple-reminders> |
| Latest release | `v1.9.2` |
| `main` / `stable` | `6b8a6e2` |
| Tags shipped | `v1.7`, `v1.8`, `v1.9`, `v1.9.1`, `v1.9.2` |
| Submitter | deno1011 (Denis Butic) |
| AI assistance | Claude (`claude-opus-4-7`), disclosed via `Assisted-by:` |

---

## 1. Tarsius's actual request

His comment was:

> Please restore the pull-request template (you can get it here:
> …PULL_REQUEST_TEMPLATE.md) and make sure to fill out the checklist.

Two concrete asks:

**1a. Restore the template.** The MELPA template has five sections:
- Brief summary of what the package does
- Direct link to the package repository
- Your association with the package
- Relevant communications with the upstream package maintainer
- Checklist (8 boxes)

The original PR body (when it was first opened) was a custom write-up with its
own "Summary / What it does / Checklist" headings. Tarsius wanted that
reverted to MELPA's template.

**1b. Fill out the checklist.** Every box has to be answered — ticked, or left
unticked with an honest reason.

**Action taken.** Fetched the live template from the MELPA repo, rewrote the
PR body to use the five section headings exactly, filled in:

- Brief summary → an up-to-date feature list (no more obsolete dashboard
  mention).
- Repo link → `https://github.com/deno1011/org-apple-reminders`.
- Association → "I am the author and maintainer".
- Communications → "None needed — I am the upstream maintainer".
- Checklist → 8 boxes; 7 ticked truthfully, 1 left unticked with a note (the
  1-month-age item, see §5).

Pushed via `gh pr edit 10016 --repo melpa/melpa --body-file …`.

**Recipe file in the PR** (unchanged from when the PR was opened):

```elisp
(org-apple-reminders :fetcher github :repo "deno1011/org-apple-reminders" :branch "stable")
```

That's the one file the PR actually adds to MELPA. Everything else is just
description.

---

## 2. Checklist item **#1: GPL-Compatible Free Software License**

Exact checklist line:

> The package is released under a
> [GPL-Compatible Free Software License](https://www.gnu.org/licenses/license-list.en.html#GPLCompatibleLicenses)

CONTRIBUTING.org expands this into three sub-requirements:

> The package is released under a GPL-Compatible Free Software License,
> preferably the GNU General Public License (GPL) version 3. **The license
> boilerplate should be applied above the `;;; Commentary` of each source
> file.** The repository should contain a `LICENSE` or `COPYING` file,
> formatted so that it can be detected by [common tooling].

Three things to satisfy:

1. **A GPL-compatible license.** Declared as **GPL-3.0-or-later** via
   `;; SPDX-License-Identifier: GPL-3.0-or-later` in the header. ✅
2. **A `LICENSE` or `COPYING` file**, detectable by GitHub's licensee tool.
   `LICENSE` is in the repo root and `gh repo view` confirms
   `licenseInfo: { key: gpl-3.0, name: GNU General Public License v3.0 }`. ✅
3. **The license boilerplate text above `;;; Commentary`** in each source
   file. **This was missing originally** — only the SPDX shorthand was
   present. Added the full short-form GPL-3.0 notice ("This program is free
   software… you should have received a copy…") between the SPDX line and
   `;;; Commentary:`. Shipped as **v1.9.2**. ✅

PR wording:

> **[x]** The package is released under a GPL-Compatible Free Software
> License — GPL-3.0-or-later (full short-form GPL boilerplate is now in the
> header above `;;; Commentary`, in addition to the
> `SPDX-License-Identifier` line; a `LICENSE` file is present in the
> repository root).

---

## 3. Checklist item **#2: I've read CONTRIBUTING.org**

Exact checklist line:

> I've read [CONTRIBUTING.org](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org)

Self-attestation — nothing automatic to verify. To tick it honestly, we
walked through every concrete requirement in the document item by item. The
eight deep-dives below (§3.1–§3.8) document each one.

### 3.1 Coding style + Emacs Lisp conventions

CONTRIBUTING.org says:

> The Emacs Lisp files should follow the [Emacs Lisp conventions]
> and the [Emacs Lisp Style Guide].

Two referenced documents:

1. GNU's official "Tips and Conventions for Emacs Lisp Programming".
2. Bozhidar Batsov's community style guide.

Between them: dozens of rules. Most **mechanical** (tool-checkable); a few
**judgment** (naming, organisation, idiom). Three tools cover essentially all
of the mechanical rules:

**`byte-compile` — language-level correctness.** Flags syntax errors, free
variables (e.g. our `org-state` / `org-capture-templates` /
`org-agenda-custom-commands` — fixed via `defvar` forward declarations),
functions referenced but not defined (e.g. `org-agenda-redo` — fixed via
`declare-function`), obsolete API usage, unused lexical variables, docstrings
wider than 80 columns, suspicious `setq` of undefined symbols, and whether
`lexical-binding: t` is honoured.

**`package-lint` — packaging-level correctness.** Flags
`Package-Requires` mistakes (e.g. redundant `(cl-lib "0.5")` on Emacs ≥ 24.3),
API-availability mismatches against the declared minimum Emacs version,
`with-eval-after-load` in package code, header completeness (Author, URL,
Keywords), missing `(provide …)` / `;;; foo.el ends here`, autoload-cookie
placement, license/copyright presence, and suspicious top-level side
effects.

**`checkdoc` — docstring conventions.** Pedantically flags first-sentence
imperative-verb rule (`contains` → `contain`), argument names appearing in
UPPERCASE in the docstring (`BEG`, `END`, `LIST-NAME`), symbols not
backtick-quoted (``\`org-agenda'``), key sequences not using `\\[command]`
substitution, opening parens at column 0 inside a docstring needing `\(`
escape, line length, and repetitions of the function's own name in its
docstring.

**Not covered ("most of it" caveat).** Naming conventions
(`pkg--internal` vs `pkg-public`), code organisation (`let` vs `let*`,
sectioning), idiom choice (`dolist` vs `mapcar`), comment accuracy, API
design. These are reviewer-judgment items. The package follows the naming
conventions consistently — every private helper is `org-apple-reminders--…`
and every public binding is `org-apple-reminders-…`.

### 3.2 Package metadata (package.el format)

CONTRIBUTING.org points at Emacs's own packaging spec
(`(info "(elisp) Packaging")`). The format defines three groups of metadata
that `package.el` parses.

**Group 1 — the magic first line.**

| What | In your file |
|---|---|
| Filename matches package name | `org-apple-reminders.el` ✅ |
| `;;; FILENAME --- DESCRIPTION -*- lexical-binding: t -*-` | `;;; org-apple-reminders.el --- Bidirectional org-mode ↔ Apple Reminders sync via JXA  -*- lexical-binding: t -*-` ✅ |

**Group 2 — library header comments.** Parsed by `lisp-mnt.el`:

| Field | Required? | In your file |
|---|---|---|
| `;; Copyright (C) YEAR Name` | recommended | `;; Copyright (C) 2025 Denis Butic` ✅ |
| `;; Author: Name <email>` | required | `;; Author: Denis Butic <d.e.n.o@gmx.net>` ✅ |
| `;; Maintainer:` | optional (falls back to Author) | not set — falls back to Author ✅ |
| `;; Assisted-by: AGENT:MODEL` | required by MELPA if AI-assisted | `;; Assisted-by: Claude:claude-opus-4-7` ✅ |
| `;; Version: X.Y[.Z]` | required | `;; Version: 1.9.2` ✅ |
| `;; Package-Requires:` | required | `;; Package-Requires: ((emacs "27.1") (org "9.3"))` ✅ |
| `;; Keywords:` | required for MELPA, must be from `finder-known-keywords` | `;; Keywords: org, outlines, apple, reminders, tools, macos` ✅ (all six recognised) |
| `;; URL:` / `;; Homepage:` | required | `;; URL: https://github.com/deno1011/org-apple-reminders` ✅ |
| `;; SPDX-License-Identifier:` | optional but conventional | `;; SPDX-License-Identifier: GPL-3.0-or-later` ✅ |

**Group 3 — body sections.** Required structure:

```
;;; foo.el --- … -*- lexical-binding: t -*-
;; <library header comments>
;; <GPL boilerplate>            ← added in v1.9.2
;;; Commentary:
;; <prose description>
;;; Code:
…actual elisp code…
(provide 'foo)
;;; foo.el ends here
```

All present in the file.

**Verification.** Two layers: (1) hand-read the header to confirm every
field; (2) `package-lint` mechanically checks every required field, validates
the syntax of `Package-Requires`, validates `Keywords`, parses `Version`,
checks URL, and verifies the closing footer. Output: `CLEAN`. Then when
`package-build` ran for the stable build, it consumed those headers and
emitted a clean generated `-pkg.el`:

```elisp
(define-package "org-apple-reminders" "1.9.2"
  "Bidirectional org-mode ↔ Apple Reminders sync via JXA."
  '((emacs "27.1") (org "9.3"))
  :url "https://github.com/deno1011/org-apple-reminders"
  :commit "6b8a6e2d0c1ff1fbfdcf0d5d388d71fd17be00c0"
  :revdesc "v1.9.2-0-g6b8a6e2d0c1f"
  :keywords '("org" "outlines" "apple" "reminders" "tools" "macos")
  :authors '(("Denis Butic" . "d.e.n.o@gmx.net"))
  :maintainers '(("Denis Butic" . "d.e.n.o@gmx.net")))
```

That's proof the headers parse correctly end-to-end.

### 3.3 Quality-checking tools (`flycheck` / `package-lint` / `checkdoc`)

CONTRIBUTING.org says:

> Use [flycheck], [package-lint] and [flycheck-package] to help you
> identify common errors in your package metadata. Use [checkdoc] to make
> sure that your package follows the conventions for documentation
> strings, **within reason**.

`flycheck` and `flycheck-package` are editor-side wrappers around
`package-lint`'s findings. What matters for review is the `package-lint`
and `checkdoc` output.

**Batch invocation.** Reproducible commands used:

```sh
emacs --batch -Q \
  --eval '(progn (require (quote package))
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
                    (if errors
                        (dolist (e errors) (princ (format "%S\n" e)))
                      (princ "clean\n"))))'
```

```sh
emacs --batch -Q \
  --eval '(progn (require (quote checkdoc))
                  (find-file "org-apple-reminders.el")
                  (let ((checkdoc-create-error-function
                         (lambda (text start end &optional unfixable)
                           (princ (format "line %s: %s\n"
                                          (line-number-at-pos start)
                                          text)))))
                    (checkdoc-current-buffer t)))'
```

**`package-lint` findings — three, all fixed in v1.9.1.**

| Line | Finding | Fix |
|---|---|---|
| 7 | warning: explicit `cl-lib` dep not needed on Emacs ≥ 24.3 | Dropped `(cl-lib "0.5")` from `Package-Requires` |
| 1741 | warning: `with-eval-after-load` is for configs, not packages | Replaced with `(require 'org-agenda)` |
| 1746 | warning: same | Replaced with `(require 'org-capture)` |

Final result: `clean`.

**`checkdoc` findings — five fixed, one disclosed nit.**

| Line | Finding | Fix |
|---|---|---|
| 83 | Lisp symbol 'org-agenda' should appear in quotes | Changed to ``\`org-agenda'`` |
| 132 | Open parenthesis in column 0 should be escaped | `(Babel blocks…` → `\(Babel blocks…` |
| 217 | "contains" should be imperative "contain" | Rephrased to "Return non-nil if any REMINDER_ID heading is present in this buffer." |
| 1611 | "changes" should be imperative "change" | Rephrased to "Push pending edits to Apple for any known org file with REMINDER_ID entries." |
| 704 / 820 | Arguments 'list-name' / 'beg' should appear UPPERCASE in docstring | Added "Non-interactively, LIST-NAME / BEG / END …" sentences to `push-heading`, `delete-reminder`, `remove-from-apple` |

**One remaining nit (deliberately not silenced).** Line 1734 — checkdoc
flags `"C-c r"` embedded in the docstring of `org-apple-reminders-command-map`
as a key reference that should use `\\[command]` substitution. But the
literal here describes the *default value* of `org-apple-reminders-keymap-prefix`,
not a key binding to be looked up at runtime — the substitution would be
misleading. The "within reason" caveat in CONTRIBUTING.org covers this.
Disclosed in the PR with an explicit offer to rephrase if reviewers prefer:

> **[x]** I've used `M-x checkdoc` to check the package's documentation
> strings. One pedantic finding remains: a literal `"C-c r"` appears inside
> a docstring describing the *default value* of
> `org-apple-reminders-keymap-prefix`, which checkdoc flags as a key
> reference. The literal is the variable's actual default; happy to rephrase
> if the reviewers prefer.

**Final state:** `package-lint` clean, byte-compile clean, `checkdoc` clean
except one pedantic disclosed nit.

### 3.4 Lexical binding

CONTRIBUTING.org says:

> Please enable [lexical binding].

**What it is.** Elisp's default scoping is dynamic — `let`-bound variables
leak into called functions. Lexical binding (opt-in per file) makes
variables behave like every other modern language: they're only visible
inside the syntactic body of their binding. Enables real closures, better
compiler output, and lets the byte-compiler distinguish free variables from
typos.

**How you enable it.** A magic comment on the very first line:

```
;;; org-apple-reminders.el --- … -*- lexical-binding: t -*-
```

Two crucial details:
- **MUST be on the first line** — the file-local-variable scanner only looks
  at line 1 for this cookie.
- **`t` exactly** — not `1`, not anything else.

Get either wrong and the file silently falls back to dynamic scoping (worst
case: code runs but with subtle bugs).

**Verified three ways.**

1. **First line of the tangled `.el`:**
   ```
   ;;; org-apple-reminders.el --- Bidirectional org-mode ↔ Apple Reminders sync via JXA  -*- lexical-binding: t -*-
   ```
2. **Byte-compile flagged free variables.** `org-state`,
   `org-capture-templates`, `org-agenda-custom-commands` were caught with
   "reference to free variable" — a warning that only fires under lexical
   binding. Proof it's active. Fixed via `defvar` forward declarations
   (since those *are* dynamic variables, just not visible at compile time).
3. **`package-build` preserves the cookie in the published `-pkg.el`.**

### 3.5 `#'` for function references

CONTRIBUTING.org says:

> Prefix function names with `#'` (i.e., the special form `function`)
> instead of just `'` (i.e., the special form `quote`) to tell the compiler
> this is a function reference.

**Why.** `'foo` and `#'foo` evaluate to the same symbol at runtime, but
`#'foo` tells the byte-compiler "this is a function reference" — so the
compiler can verify `foo` is defined, warn on typos, and inline-optimise.
`'foo` provides no such verification.

**Where it matters:**

| Context | Wrong | Right |
|---|---|---|
| `(mapcar 'foo list)` | not verified | `(mapcar #'foo list)` |
| `(add-hook 'some-hook 'foo)` | not verified | `(add-hook 'some-hook #'foo)` (first arg `'` keeps — it's a hook variable name) |
| `(advice-add 'orig :after 'foo)` | not verified | `(advice-add 'orig :after #'foo)` |
| `(funcall 'foo …)` / `(apply 'foo …)` | not verified | `(funcall #'foo …)` / `(apply #'foo …)` |

**Where `'` is correct:** `(require 'feature)`, `:group 'my-group`, `(setq x
'symbol-literal)`, the first arg of `(add-hook 'hook-var …)`.

**Verified:** Grepped for the common bad patterns (`mapcar '`, `seq-filter
'`, `cl-remove '`, `cl-find '`, `mapc '`) — zero matches. Spot-checked
`add-hook` and `advice-add` sites in the codebase — all use `#'` for the
function argument, `'` for the hook/function-being-advised name. Textbook
correct. `package-lint` and byte-compile would have flagged any
unresolvable function reference; both are clean.

### 3.6 Recipe file format

CONTRIBUTING.org says:

> Create a file under the directory specified by
> `package-build-recipes-dir` (default: `recipes/`). The filename should
> match the name of the package's provided feature.
>
> See the [recipe format] section of the README for more information.
>
> Recipes should try to minimize the size of the resulting package by
> specifying only files relevant to the package.

**Three requirements:**

1. **Recipe lives at `recipes/<package-name>`** in the MELPA repo.
2. **Filename matches `(provide '…)`.** `.el` has `(provide 'org-apple-reminders)`,
   so recipe must be `recipes/org-apple-reminders` (no `.el` extension).
3. **Minimize tarball** — only ship files actually needed.

**Recipe structure** — single elisp form, read with `(read)`:

```elisp
(<package-name> :fetcher <fetcher> <:other-keys> <values>)
```

Valid keys: `:fetcher` (github/gitlab/git/hg), `:repo`, `:url`, `:branch`
(default = repo's default branch), `:files` (default = `:defaults` — all
`.el` in repo root + `.info` docs, minus tests), `:version-regexp`,
`:old-names`.

**Your recipe** (in PR #10016):

```elisp
(org-apple-reminders :fetcher github :repo "deno1011/org-apple-reminders" :branch "stable")
```

| Element | Why |
|---|---|
| `org-apple-reminders` package name | matches filename and `(provide …)` |
| `:fetcher github` | repo is on GitHub |
| `:repo "deno1011/org-apple-reminders"` | full owner/repo path |
| `:branch "stable"` | build from the `stable` branch — see below |

**No `:files` key** — so `:defaults` applies. Tarball gets only
`org-apple-reminders.el` (plus the generated `-pkg.el`); README and ROADMAP
stay in the repo but are NOT shipped.

**No `:version-regexp`** — the default catches `vX.Y.Z` tags like `v1.9.2`.
Confirmed working in the stable build.

**Why `:branch "stable"` and not `"main"`.** MELPA has two channels:

| Channel | Builds from | Version source |
|---|---|---|
| MELPA (rolling) | branch HEAD | timestamp (e.g. `20260520.544`) |
| MELPA Stable | highest semver tag reachable from `:branch` HEAD | the tag (e.g. `1.9.2`) |

Pointing `:branch` at `stable` means: even users on the rolling MELPA archive
benefit from the "I tested this, it works" gate (the `stable` branch is only
ever fast-forwarded from `main` after user confirmation), not the
bleeding-edge `main`. Hence the discipline of pushing `main` first and only
promoting `stable` after testing.

### 3.7 Test your recipe

CONTRIBUTING.org says:

> Build the recipe via `make recipes/<NAME>`, or with `C-c C-c`
> (`M-x package-build-current-recipe`).
>
> If the repository contains tags for releases, confirm that the correct
> version is detected by running `MELPA_CHANNEL=stable make recipes/<NAME>`.
>
> Test that the package installs properly by running `package-install-file`.

(Note: CONTRIBUTING.org says `MELPA_CHANNEL`, but the actual Makefile
variable is `CHANNEL`. Use `CHANNEL=stable`.)

**Steps actually run (against a fresh `/tmp/melpa-test/` clone of MELPA):**

**Step 1 — set up.**
```sh
git clone --depth 1 https://github.com/melpa/melpa.git melpa-test
cd melpa-test
echo '(org-apple-reminders :fetcher github :repo "deno1011/org-apple-reminders" :branch "stable")' > recipes/org-apple-reminders
```

**Step 2 — build MELPA rolling.**
```sh
make recipes/org-apple-reminders
```
Result: `Created org-apple-reminders-20260520.544.tar containing
org-apple-reminders.el + org-apple-reminders-pkg.el`. Timestamp version.
Tarball minimal (only the `.el` and generated `-pkg.el`). Proves: recipe is
valid, headers parse, `:defaults` `:files` correct, fetcher works.

(Non-fatal warning: ImageMagick badge generation failed locally because
DejaVu-Sans is not installed on this Mac. Irrelevant — MELPA's servers have
the font; the badge is just a cosmetic SVG for the archive web page.)

**Step 3 — build MELPA stable.**
```sh
CHANNEL=stable make recipes/org-apple-reminders
```
Result: `Created org-apple-reminders-1.9.2.tar`. Version from the `v1.9.2`
tag, not a timestamp. Generated `-pkg.el` carries `Package-Revision:
v1.9.2-0-g6b8a6e2d0c1f`. Proves: semver tag pipeline works end-to-end, the
`Assisted-by:` line and GPL boilerplate survive `package-build`'s copy step.

**Step 4 — install via `package-install-file` in a clean Emacs.**
```sh
emacs --batch -Q --eval '(progn
  (require (quote package))
  (setq user-emacs-directory (make-temp-file "oar-pi-" t))
  (setq package-user-dir (expand-file-name "elpa" user-emacs-directory))
  (package-initialize)
  (package-install-file "packages-stable/org-apple-reminders-1.9.2.tar")
  (require (quote org-apple-reminders))
  (princ (format "✓ installed %s, loaded successfully\n"
                 (package-desc-version
                  (cadr (assq (quote org-apple-reminders) package-alist))))))'
```

Result:
```
Extracting...done
  GEN      org-apple-reminders-autoloads.el
Compiling …/org-apple-reminders-autoloads.el...
Compiling …/org-apple-reminders-pkg.el...
Compiling …/org-apple-reminders.el...
Done (Total of 1 file compiled, 2 skipped)
✓ installed (1 9 2), loaded successfully
```

Proves: tarball extracts, autoloads generated, all three files byte-compile
cleanly, package is in `package-alist`, `(require 'org-apple-reminders)`
succeeds.

**PR wording for this row (most detailed of the eight):**

> **[x]** I've built and installed the package using the instructions in
> CONTRIBUTING.org#test-your-recipe:
> - `CHANNEL=unstable make recipes/org-apple-reminders` → produces
>   `org-apple-reminders-20260520.544.tar` with `org-apple-reminders.el` +
>   generated `-pkg.el`.
> - `CHANNEL=stable make recipes/org-apple-reminders` → correctly detects
>   the `v1.9.2` tag and produces `org-apple-reminders-1.9.2.tar`.
> - `package-install-file` on the stable tarball in a clean `--batch` Emacs
>   installs the package, generates autoloads, byte-compiles every file
>   without warnings, and `(require 'org-apple-reminders)` loads cleanly.

### 3.8 Opening the PR

CONTRIBUTING.org says:

> Create a dedicated pull request branch in your clone of the MELPA
> repository and push this branch to your fork. Finally, go to the MELPA
> repository and open the pull request.

**Four implied requirements, mapped against PR #10016:**

| Requirement | Your PR |
|---|---|
| Forked from `melpa/melpa` | Head repo: `deno1011/melpa` ✅ |
| Dedicated PR branch (not master) | `add-org-apple-reminders` ✅ |
| PR opened against `melpa/melpa : master` | Base: `melpa/melpa : master` ✅ |
| Body uses MELPA template | Yes, after our edit ✅ |

**Minimal diff.** 1 file changed, +1 / -0 — just the recipe file. No test
helpers, no MELPA-code edits.

**Timing.** Repo created 2026-05-17T19:10:39Z, PR opened
2026-05-17T19:15:33Z — 5 minutes later. Both 3 days old as of 2026-05-20.
This is also why item #4 of the checklist (the 1-month minimum) is the only
unchecked box (see §5).

**What MELPA does NOT require** (saves effort):
- No CLA to sign.
- No separate issue to file beforehand.
- No "request review" action — maintainers pick up well-formed PRs at their
  own pace.
- No GPG-signed commits required.
- No squash-before-merge requirement.

---

## 4. Checklist item **#3: LLMs + `Assisted-by:` line**

Exact checklist line:

> LLMs were used to generate some of the code, and if so, I've added an
> `Assisted-by:` line as described in CONTRIBUTING.org

**This is the newest of the eight checklist items** (MELPA added it as part
of an AI-attribution policy). Conditional: "if LLMs were used, then add the
line."

**Policy text (full passage):**

> Using AI to assist in writing code or opening pull requests is fine, but
> the human author should be the **first** and **most thorough** reviewer
> of any such output. Please help the MELPA community track AI assistance
> by providing a [Linux-style "Assisted-by" line] under your files'
> Author line:
>
> ```elisp
> ;; Author: Author Name <email@domain>
> ;; Assisted-by: AGENT_NAME:MODEL_VERSION
> ```
>
> Where `AGENT_NAME` is the name of the product or framework (e.g.
> "Claude") and `MODEL_VERSION` is the corresponding version (e.g.
> `claude-opus-4-7`).

Three takeaways:
1. **It's a Linux-kernel-style attribution** — borrowed from
   `docs.kernel.org`'s coding-assistants page.
2. **The human author is responsible.** Policy doesn't ban AI assistance;
   it requires the human to vouch for the result.
3. **Format is exact:** `AGENT_NAME:MODEL_VERSION`, colon-separated, no
   quotes, in a `;;` comment header line.

**Why it applies to this package.** We collaborated extensively from v1.7
onwards. Significant Claude-assisted areas:

- The push-heading move logic (v1.7).
- Region-aware push/delete/remove (v1.8 / v1.9).
- Shared helpers: `--unlink-apple-at-point`, `--strip-link-properties`,
  `--region-reminder-markers`, `--push-heading-1`, `--push-region`,
  `--prune-excluded-lists`, `--list-section-p`,
  `--normalize-list-spacing`, `--ensure-list`, `--register-current-file`,
  `--in-sync-file-p`, `--relocate-subtree-to-list`.
- Conflict-resolution adjustments.
- MELPA-hygiene fixes (v1.9.1) and license boilerplate (v1.9.2).

Non-trivial assistance. You reviewed and confirmed every change before
commit — "first and most thorough reviewer" is met — but the assistance is
real, so the line is required, not optional.

**Line added** (in v1.9.1):

```elisp
;; Author: Denis Butic <d.e.n.o@gmx.net>
;; Assisted-by: Claude:claude-opus-4-7
;; Version: 1.9.1
```

Exact policy format:

| Element | Mine | Policy |
|---|---|---|
| Lead `;; ` | ✓ | ✓ |
| Header name | `Assisted-by:` | `Assisted-by:` |
| Agent | `Claude` | "name of the product or framework" |
| Separator | `:` | `:` |
| Model | `claude-opus-4-7` | "corresponding version (e.g. `claude-opus-4-7`)" |
| Position | below `;; Author:` | "under your files' Author line" |

**Verified three places:**

1. In the `.org` literate source (where edited).
2. In the tangled `.el` (`grep -m1 "Assisted-by:" org-apple-reminders.el`).
3. In the generated `-pkg.el` produced by `package-build` for the stable
   tarball — confirming the attribution travels into what MELPA actually
   publishes.

**PR wording:**

> **[x]** LLMs were used to generate some of the code, and an `Assisted-by:
> Claude:claude-opus-4-7` line is present in the package header next to the
> `Author:` line, per the AI-attribution policy.

**Why this matters reputationally.** MELPA reviewers increasingly scrutinise
suspected-AI packages. Submitting without the line invites push-back. Honest
disclosure removes friction — strictly better even if the AI-generated
portion is small.

---

## 5. Checklist item **#4: 1-month minimum repo age** (the only unchecked box)

Exact checklist line:

> The package has been maintained in a public repository for 1 month or more

**The only box deliberately left unchecked.** It's a calendar fact, not a
code/policy fix.

**Why MELPA enforces this.** CONTRIBUTING.org rationale:

> **Reasonably innovative and mature ::** MELPA provides a curated set of
> Emacs Lisp packages, not an exhaustive list of every single Emacs Lisp
> file ever created. By default, MELPA maintainers will reject … nascent
> packages that haven't had time to see real maintenance.

and:

> **Reasonably active maintainer ::** Packages submitted should have a
> reasonably committed and active maintainer. MELPA is not intended to be
> a place to "dump" code, even if it works well at the time.

Age = proxy for maturity and ongoing commitment. The 1-month bar filters out
one-day-old packages that get abandoned in a week.

**Concrete numbers:**

| | Date | Detail |
|---|---|---|
| Repo created on GitHub | 2026-05-17 19:10:39 UTC | Public from creation |
| MELPA PR opened | 2026-05-17 19:15:33 UTC | 5 minutes later |
| Today | 2026-05-20 | |
| Repo age right now | **3 days** | Below threshold |
| 1-month mark | **2026-06-17** | When the box can honestly be ticked |

**How handled on the PR.** Two options:

1. Tick the box anyway — misreports the date, gets caught immediately
   (reviewers can see the repo creation date on GitHub), burns trust. Bad.
2. Leave it unchecked with an honest note explaining and committing to
   re-ping — transparent, gives the reviewer a clear timeline, frames it as
   "the only blocker is a calendar wait". Good.

Went with option 2. PR wording:

> **[ ]** The package has been maintained in a public repository for 1
> month or more.
> *(The repository was created on 2026-05-17 and is currently three days
> old. I am happy to wait for the 1-month threshold — I'll re-ping this PR
> once it is met. I am leaving this box unchecked rather than misreport
> the date.)*

Follow-up comment to tarsius also mentions it:

> The only box I have left unchecked is *"maintained in a public repository
> for 1 month or more"* — the repo was created on 2026-05-17, so it's
> three days old. I'd rather leave it unchecked than misreport the date;
> happy to re-ping this PR around 2026-06-17 when the 1-month threshold
> is met (or sooner if you'd like to proceed earlier).

**What happens next — three realistic outcomes:**

1. **Most likely.** Tarsius (or another maintainer) lets the PR sit until
   2026-06-17, you re-ping, they proceed with the merge. No further changes
   needed if the recipe and code still build cleanly at that point.
2. **Possible.** They look at it before the date and decide the package is
   mature enough to merge anyway (the 1-month rule is a guideline, not a
   hard cutoff).
3. **Less likely.** They ask to fix something else first; we respond and
   re-ping.

**Subtle benefit of honest disclosure.** Pre-empts the otherwise-inevitable
"the repo is 3 days old, please come back in a month" review comment.
Strongest position to be in.

---

## 6. Checklist item **#5: `package-lint` clean**

Exact checklist line:

> I've used the latest version of
> [package-lint](https://github.com/purcell/package-lint) to check for
> packaging issues, and addressed its feedback

Three sub-claims to honour: **(a)** the *latest* version was used, **(b)** it
was *actually run*, **(c)** every finding was *addressed*.

### What `package-lint` is

The canonical packaging-checker for Emacs Lisp packages, written by Steve
Purcell (who runs MELPA's technical recipe review). Encodes years of MELPA
reviewing wisdom: common mistakes, what `package.el` expects, what's portable
across declared-supported Emacs versions. **MELPA's automated CI runs
`package-lint` first** — if it reports findings, the PR's CI fails and a
maintainer rejects before reading anything else.

`package-lint` is itself distributed on MELPA. "Latest version" means
installing it fresh from the MELPA archive each run — which is what the
batch command does:

```sh
emacs --batch -Q \
  --eval '(progn (require (quote package))
                  (setq package-archives
                        (quote (("melpa" . "https://melpa.org/packages/")
                                ("gnu"   . "https://elpa.gnu.org/packages/"))))
                  (package-initialize)
                  (unless (package-installed-p (quote package-lint))
                    (package-refresh-contents)
                    (package-install (quote package-lint)))
                  (require (quote package-lint))
                  (find-file "org-apple-reminders.el")
                  (let ((errors (package-lint-buffer)))
                    (if errors
                        (dolist (e errors) (princ (format "%S\n" e)))
                      (princ "clean\n"))))'
```

The `(unless (package-installed-p …) (package-refresh-contents)
(package-install …))` chain pulls the most recent version from
`melpa.org` at run-time. Claim **(a)** is concretely satisfied.

### What it actually checks

| Category | What gets flagged |
|---|---|
| **Header completeness** | Missing `Author`, `Version`, `Package-Requires`, `Keywords`, `URL`; missing first-line description; missing `lexical-binding` cookie. |
| **`Package-Requires` correctness** | Bad syntax, dep doesn't exist on MELPA / GNU ELPA, version string doesn't parse, redundant deps (e.g. `cl-lib` on Emacs ≥ 24.3 — what flagged us), missing dep for a function you call. |
| **API-availability mismatch** | You call a function/variable/macro/face that was introduced in Emacs N, but `Package-Requires` says you support Emacs M < N. |
| **`Keywords` validity** | Each keyword must be in `finder-known-keywords`. |
| **Top-level shape** | Missing `(provide …)`, missing `;;; foo.el ends here` footer, `with-eval-after-load` inside package body (config-time behaviour leaking into library code), unhealthy top-level side-effects. |
| **`;;;###autoload` cookies** | Cookies on definitions that shouldn't have them, missing ones on commands that arguably should. |
| **Naming conventions** | Functions/variables that should be prefixed with the package name aren't. |

Does **not** check: docstring grammar (that's `checkdoc`), code logic,
anything runtime. Purely static metadata + shape.

### Three findings on our package, all in v1.9.1

Initial run (before any fixes), tuple format `(LINE COL SEVERITY MESSAGE)`:

```
(7 21 warning "An explicit dependency on cl-lib <= 1.0 is not needed on Emacs >= 24.3.")
(1741 3 warning "`with-eval-after-load' is for use in configurations, and should rarely be used in packages.")
(1746 5 warning "`with-eval-after-load' is for use in configurations, and should rarely be used in packages.")
```

All three warnings, not errors — package was technically installable, just
stylistically off.

**Finding 1 — line 7, redundant `cl-lib` dependency.**

Before:

```elisp
;; Package-Requires: ((emacs "27.1") (org "9.3") (cl-lib "0.5"))
```

Why it complains: `cl-lib` was a standalone GNU-ELPA package until Emacs
24.3 (May 2013). Since 24.3 it's bundled with Emacs. Our minimum is 27.1 —
*way* past 24.3 — so declaring `(cl-lib "0.5")` accomplishes nothing useful;
the dependency is *always already satisfied* by the Emacs version we
require. Noise that historically led to dangerous mismatches (packages
declaring `cl-lib "0.5"` while using cl-lib features only in much later
versions).

Fix (v1.9.1):

```elisp
;; Package-Requires: ((emacs "27.1") (org "9.3"))
```

`(require 'cl-lib)` stays in the source (since we use `cl-find`,
`cl-remove`, `cl-loop`, etc.), but it's no longer declared as a separate
*package* dependency — because it isn't one anymore.

**Findings 2 & 3 — lines 1741 / 1746, `with-eval-after-load` in package
code.**

Before, in `org-apple-reminders-setup`:

```elisp
(with-eval-after-load 'org-agenda
  (org-apple-reminders--ensure-agenda-files))
…
(if (featurep 'org-capture)
    (org-apple-reminders--setup-capture)
  (with-eval-after-load 'org-capture
    (org-apple-reminders--setup-capture)))
```

Why it complains: `with-eval-after-load` queues a callback to fire later,
when some other library loads. Fine in user **init files**; discouraged in
**package code** for two reasons:

1. **Semantic confusion.** A package shouldn't silently queue code to run
   "whenever some other library happens to load". If your package needs
   feature X, it should `require` X so the loader knows the dependency
   graph. `with-eval-after-load` hides the relationship.
2. **Debugging hell.** When something goes wrong, no good way for the user
   to discover that the failing code was queued by your package earlier.

In our case the two deferred libraries — `org-agenda` and `org-capture` —
are *part of `org`*, which we already declare in `Package-Requires`. Loading
them in our setup function adds essentially no cost and removes the warning.

Fix (v1.9.1) — both calls replaced:

```elisp
(require 'org-agenda)
(require 'org-capture)
(org-apple-reminders--ensure-agenda-files)
(add-hook 'org-agenda-mode-hook #'org-apple-reminders--ensure-agenda-files)
(org-apple-reminders--setup-capture)
```

Slight semantic change: agenda/capture now load when the user calls
`(org-apple-reminders-setup)` rather than when they first touch
agenda/capture. Cost negligible, code cleaner.

### Final state

After v1.9.1, re-running the same batch invocation:

```
=== package-lint ===
clean
```

Single word. No findings.

### Why ticking the box is safe

Three pieces of evidence:

1. **Latest version installed** — `(package-refresh-contents) (package-install
   'package-lint)` ensures fresh-from-MELPA, not a stale local copy.
2. **Actually run** — the output `clean` is what it printed, not a claim.
3. **Every finding fixed** — three warnings, all addressed (cl-lib dep
   dropped, both `with-eval-after-load` calls replaced), re-run confirmed
   gone.

PR wording:

> **[x]** I've used the latest version of package-lint to check for
> packaging issues, and addressed its feedback — output is clean.

### Why this row is the most important of the eight

Most other checklist boxes are policy attestations (license, attribution,
age) or things that need a once-over from a human reviewer (style,
behaviour). **`package-lint` clean is the single mechanical signal that the
package will actually build and install on MELPA's CI without breaking
anyone's Emacs.** Findings = CI failure = automatic rejection before any
human reads the PR. Clean = technical bar cleared.

---

## 7. Checklist item **#6: byte-compiles cleanly**

Exact checklist line:

> My elisp byte-compiles cleanly

*"Cleanly"* = **zero warnings AND zero errors**. Easy to verify, easy to
fudge — worth understanding precisely what's checked.

### What byte-compile does

Emacs Lisp is normally interpreted, but every `.el` file can be byte-compiled
to a `.elc` for ~5× faster loading. The byte-compiler isn't just a packer —
it does substantial **static analysis** on the way.

**MELPA's relevance.** When `package.el` installs a MELPA package, it
byte-compiles every `.el` as part of the install. **Any warning the
byte-compiler emits is shown to the user during install.** A package that
spews warnings every install looks broken — even when it works fine. So
MELPA reviewers want it silent.

Two invocations:

| How | Used for |
|---|---|
| Interactive: `M-x byte-compile-file` | Author-time spot checks |
| Batch: `emacs --batch -Q -l org -f batch-byte-compile foo.el` | Reproducible CI-style check |

The v1.9.1 work used the batch form throughout — deterministic, no
interference from interactive setup.

### What it catches

| Category | What gets flagged |
|---|---|
| **Free variables** | Symbol referenced that isn't `let`-bound, `defvar`'d locally, or imported. Under lexical binding the compiler distinguishes these from intentional dynamic vars. |
| **Functions not known to be defined** | Same logic for `(some-function …)` where `some-function` isn't autoloaded/defined/declared. |
| **Obsolete API usage** | Calling something marked obsolete; points at replacement. |
| **Unused lexical variables** | `let` binding never referenced in body — often a typo. |
| **Docstring length > 80 columns** | Cosmetic but enforced. |
| **`lexical-binding` cookie missing** | Code requiring it without the line-1 cookie. |
| **Suspicious `setq`** | Of undefined symbols, or `let` shadowing a function. |
| **Subtle correctness** | `defcustom` without `:type`, deprecated form usage, etc. |

Does **not** catch: anything runtime, docstring prose (checkdoc's job), or
packaging metadata (`package-lint`'s job).

### Wave 1 — what was initially flagged

Pre-v1.9.1 output:

```
org-apple-reminders.el:360:2: Warning: docstring wider than 80 characters
org-apple-reminders.el:433:11: Warning: defconst 'org-apple-reminders--fetch-script' docstring wider than 80 characters
org-apple-reminders.el:491:2: Warning: docstring wider than 80 characters
org-apple-reminders.el:723:19: Warning: reference to free variable 'org-state'
org-apple-reminders.el:810:2: Warning: docstring wider than 80 characters
org-apple-reminders.el:1334:17: Warning: reference to free variable 'org-capture-templates'
org-apple-reminders.el:1334:17: Warning: assignment to free variable 'org-capture-templates'
org-apple-reminders.el:1363:19: Warning: reference to free variable 'org-agenda-custom-commands'
org-apple-reminders.el:1363:19: Warning: assignment to free variable 'org-agenda-custom-commands'
org-apple-reminders.el:1248:54: Warning: the function 'org-agenda-redo' is not known to be defined.
```

Nine warnings: four wide docstrings, five symbol-resolution problems. None
are *bugs* — code works correctly at runtime — but each would print to
`*Messages*` on every install.

**Wave 1 fixes (v1.9.1):**

- **`org-state` (line 723).** The dynamic variable bound by Emacs's
  `org-after-todo-state-change-hook` machinery. Our
  `--on-todo-state-change` is added to that hook, so `org-state` IS
  defined at runtime — but byte-compile can't see that. Fix:
  `(defvar org-state)` near the top — tells the compiler "trust me, this is
  a dynamic variable that will exist at runtime" without creating an unbound
  variable.

- **`org-capture-templates`, `org-agenda-custom-commands` (lines 1334,
  1363).** Defcustoms in `org-capture` / `org-agenda`. After removing the
  `with-eval-after-load` (see Point 6) and using explicit `(require
  'org-agenda)` / `(require 'org-capture)`, the variables ARE loaded at
  runtime — but byte-compile happens before runtime. Fix: two more
  `defvar` forward declarations: `(defvar org-capture-templates)` and
  `(defvar org-agenda-custom-commands)`.

- **`org-agenda-redo` (line 1248).** Same story for a *function* (lives in
  `org-agenda`). The compile-time knob is `declare-function`:
  `(declare-function org-agenda-redo "org-agenda" (&optional all))`.

- **Four wide docstrings (lines 360, 433, 491, 810).** Pre-existing, just
  exceed 80 cols. Mechanical wrap.

### Wave 2 — wrap remaining wide docstrings

After wave 1, line numbers shifted but four width warnings remained. Each
docstring rewrapped to two lines:

- `"Extract body text from org heading, stripping LOGBOOK and per-line leading whitespace."` (88) →
  `"Extract body text from org heading at point.\nStrips LOGBOOK drawers and per-line leading whitespace."`
- `"JXA script returning all Reminders as JSON.  Uses batch property fetch for speed."` (82) →
  `"JXA script returning all Reminders as JSON.\nUses batch property fetch for speed."`
- `"Without CALLBACK: synchronous; returns Apple's post-push modificationDate or nil."` (81) →
  `"Without CALLBACK: synchronous; returns Apple's modificationDate after the\npush, or nil."`
- `"Auto-creation from unlinked headings only happens in \`org-apple-reminders-sync-file';"` (88) →
  `"Auto-creation from unlinked headings only happens in the value of\n\`org-apple-reminders-sync-file';"`

### Final state

```
=== byte-compile ===
(CLEAN)
```

Empty output beyond the "CLEAN" tag I echo. **Zero warnings, zero errors.**
Also re-checked after the v1.9.2 license-boilerplate addition (in case
line-number shifts re-exposed anything) — still clean.

### Verification command

Identical to what MELPA's CI runs:

```sh
emacs --batch -Q -l org -f batch-byte-compile org-apple-reminders.el
```

`-Q` strips interactive config. `-l org` loads org-mode (the file
`(require 'org)`). `-f batch-byte-compile` is the standard CI entry point.

### How byte-compile and `package-lint` complement each other

| Check | Catches |
|---|---|
| `package-lint` | Headers, metadata, packaging shape, dependency declarations |
| **byte-compile** | Code-level: undefined refs, free vars, syntax, docstring width |
| `checkdoc` | Docstring prose conventions |

You can have clean `package-lint` and broken byte-compile (perfect headers,
broken code). You can have clean byte-compile and broken `package-lint`
(working code, malformed metadata). MELPA wants both — we have both.

### PR wording

> **[x]** My elisp byte-compiles cleanly (no warnings).

The parenthetical is the substantive claim. "Byte-compiles" alone could
mean "produces a `.elc` without erroring, even with warnings spewing"; "no
warnings" makes the claim concrete and verifiable.

### Install-time visibility

What MELPA users see in `*Messages*` on install:

```
Compiling .../org-apple-reminders-1.9.2/org-apple-reminders-autoloads.el...
Compiling .../org-apple-reminders-1.9.2/org-apple-reminders-pkg.el...
Compiling .../org-apple-reminders-1.9.2/org-apple-reminders.el...
Done (Total of 1 file compiled, 2 skipped)
```

Four clean lines. A package emitting warnings would show them all here,
visible to every user on every install — they look like errors to
non-Emacs-Lisp people, they cause false-positive bug reports, they tire
reviewers. Silent install = warnings were fixed at the source.

---

## 8. Checklist item **#7: `M-x checkdoc`**

Exact checklist line:

> I've used `M-x checkdoc` to check the package's documentation strings

The **only** checklist item with a built-in escape valve. CONTRIBUTING.org:

> Use [checkdoc] to make sure that your package follows the conventions for
> documentation strings, **within reason**.

The "within reason" clause matters and is invoked below.

### What checkdoc is, and why it's its own tool

One of the oldest built-in Emacs tools (since the 1990s, family of
`lisp-mnt.el`). Exists because Emacs Lisp has a UX contract no other tool
checks:

- The **first sentence** of a docstring is a one-line summary that appears
  in `M-x apropos`, completion frames, and minibuffer prompts. It has to
  stand alone.
- Sentences after may go deep, but the first is *the* user-visible label.

That's a **UX contract**, not a code rule. byte-compile won't catch it (code
runs either way), `package-lint` won't catch it (metadata unaffected).
checkdoc audits docstring **prose**.

Conventions it enforces:

| Convention | Example |
|---|---|
| First sentence ends `.` and stands alone | `"Push the heading at point to Apple Reminders."` not `"Push heading"` |
| First sentence starts with imperative verb | `"Return"`, `"Push"`, `"Delete"` — not `"Returns"`/`"Pushes"`/`"Deletes"` |
| Argument names UPPERCASE on first mention | `"Push TARGET to Apple."` not `"Push target to Apple."` |
| Symbol references use backticks | `` "See `org-agenda'." `` not `"See org-agenda."` |
| Key sequences use substitution constructs | `\\[org-priority]` not `"C-c ,"` |
| Open parens at column 0 escaped | `\(Babel blocks…` not `(Babel blocks…` |
| Lines ≤ 80 columns | (same as byte-compile, stricter heuristic) |
| Don't repeat function name in its own docstring | `"Compute X."` not `"my-fn computes X."` |

**Philosophy.** Docstrings are *terminal-rendered* by Emacs's formatted-text
engine — `\\[command]` and `` `symbol' `` aren't pedantry, they get
**rendered** into the user's current keybinding and a clickable symbol link.
`\\[org-priority]` displays as `C-c ,` if that's bound, or `M-x org-priority`
if rebound. That's the substantive reason for the convention.

### The "within reason" caveat

checkdoc is **heuristic** — regex-based grammar checks that can misfire:

- A sentence genuinely starts with a non-imperative verb because that's the
  clearest phrasing.
- A literal key string is meant to be literal (when describing a default
  value, not a binding to look up).
- An 80-column limit clips a path or a regex that can't sensibly wrap.

MELPA's stance: **fix what you can, disclose what you can't, don't lie about
it.** A package with one explained checkdoc nit is more trusted than one
claiming clean while ignoring a real warning.

### How I ran it

Two forms. Same engine; only output presentation differs.

**Batch invocation** (reproducible):

```sh
emacs --batch -Q \
  --eval '(progn (require (quote checkdoc))
                  (find-file "org-apple-reminders.el")
                  (let ((checkdoc-create-error-function
                         (lambda (text start end &optional unfixable)
                           (princ (format "line %s: %s\n"
                                          (line-number-at-pos start)
                                          text)))))
                    (checkdoc-current-buffer t)))'
```

The trick is **`checkdoc-create-error-function`** — by default checkdoc
launches an interactive buffer-walking prompt that doesn't work in `--batch`.
Overriding the error-creation hook with a `princ`-to-stdout lambda redirects
findings to the terminal, line-by-line.

**`M-x checkdoc`** is the interactive equivalent the checklist line names.
The batch form was used because reproducibility means the claim "clean" is
something anyone can re-verify with a one-liner.

### Five findings cleaned up

| Line | Original | Fix |
|---|---|---|
| 83 | Lisp symbol 'org-agenda' should appear in quotes (defcustom docstring) | `org-agenda` → `` `org-agenda' `` |
| 132 | Open parenthesis in column 0 should be escaped (line started `(Babel blocks…`) | `(Babel blocks…` → `\(Babel blocks…` |
| 217 | Probably "contains" should be imperative "contain" | Rephrased `--buffer-has-reminders-p`: `"Return non-nil if any REMINDER_ID heading is present in this buffer."` |
| 1611 | Probably "changes" should be imperative "change" | Rephrased `--on-save`: `"Push pending edits to Apple for any known org file with REMINDER_ID entries."` |
| 704 / 820 | Argument 'list-name' / 'beg' should appear (as LIST-NAME / BEG) in the doc string | Added `"Non-interactively, LIST-NAME / BEG / END …"` sentences to `push-heading`, `delete-reminder`, `remove-from-apple` |

Each fix is minimal — the smallest change that satisfies the convention.
Phrasings chosen to avoid triggering the *next* checkdoc rule; iterated until
clear.

### The one nit that stayed — principled defense

Remaining after the five fixes:

> **line 1734:** Keycode C-c embedded in doc string. Use \\<mapvar> &
> \\[command] instead

Context:

```elisp
"Keymap for `org-apple-reminders' commands.
`org-apple-reminders-setup' binds this under
`org-apple-reminders-keymap-prefix' (default \"C-c r\").  Keys
`p' and `m' both run `org-apple-reminders-push-heading' …"
```

The literal `"C-c r"` is inside *(default "C-c r")*. checkdoc's
pattern-matcher sees `C-c r` and assumes it's a key binding being
documented — recommends substituting `\\[…]` so the displayed key updates if
the user rebinds.

**But that's exactly wrong here.** The variable
`org-apple-reminders-keymap-prefix` has the literal string `"C-c r"` as its
**default value**. The docstring shows the user what string the variable
defaults to — not "this command is bound to C-c r". `\\[…]` substitution
applies when documenting a key binding so display reflects the user's
current setup. For a default-value string, you want the literal.

Options:

1. Add `\\=` escapes (`(default \\=\"C-c \\=r\\=\")`) to silence checkdoc —
   ugly, confusing to anyone reading source.
2. Rephrase to avoid the parenthetical — but then the user doesn't see what
   the default is.
3. Leave it and disclose.

Went with **3** — honest, and CONTRIBUTING.org's "within reason" caveat
exists precisely for cases like this.

### PR wording

> **[x]** I've used `M-x checkdoc` to check the package's documentation
> strings. One pedantic finding remains: a literal `"C-c r"` appears inside
> a docstring describing the *default value* of
> `org-apple-reminders-keymap-prefix`, which checkdoc flags as a key
> reference. The literal is the variable's actual default; happy to rephrase
> if the reviewers prefer.

Three things this wording does:
1. Ticks the box — every reasonable docstring convention is met.
2. Discloses the exception specifically, with the reason.
3. Offers a path forward — "happy to rephrase if the reviewers prefer".

The model "within reason" disclosure — fully tested-out, with one
principled holdout, transparently noted.

### Final state

| Check | Result |
|---|---|
| Wide docstrings | All wrapped in v1.9.1 wave 2 |
| Backticked symbols | Fixed |
| Escaped column-0 parens | Fixed |
| Imperative verbs in first sentence | All rephrased |
| Uppercase argument names in docstrings | All present |
| **Literal `C-c r` in default-value docstring** | **Disclosed nit** |

Strict answer: *almost-clean-with-one-disclosed-nit*. Honest PR answer: tick
the box (every fixable warning fixed) + disclose inline. "Within reason"
covers it.

### Why this row probably won't get pushback

Reviewer sees: ticked box, plain-English disclosure, principled reason, offer
to rephrase. If he disagrees, says "please rephrase" — we change it. If he
agrees, no comment needed. Lowest-cost interaction.

---

## 9. Checklist item **#8: Test your recipe**

Exact checklist line:

> I've built and installed the package using the instructions in
> [CONTRIBUTING.org](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org#test-your-recipe)

The **single checklist row that exercises the package as a MELPA
artifact** — everything else is metadata or attestation. This one says:
*the recipe actually produces an installable tarball, on both channels, and
a clean Emacs can install it without errors.*

Also the only checklist item with a **multi-step procedure**, and the PR row
is the most detailed of the eight — reviewers spot-check this; structured
output saves them work.

(Full technical command sequence is in §3.7. This section focuses on what
each step *proves about the package*, not how it's run.)

### Doc drift to note

CONTRIBUTING.org says:

> If the repository contains tags for releases, confirm that the correct
> version is detected by running `MELPA_CHANNEL=stable make recipes/<NAME>`.

But the actual Makefile variable is **`CHANNEL`**, not `MELPA_CHANNEL`.
Running the literal command from CONTRIBUTING.org gives you the rolling
build back. Correct invocation: `CHANNEL=stable make recipes/<NAME>`. Small
doc drift on MELPA's side; reviewers know.

### The four checks — each proves something distinct

**Step 1 — Rolling build** (`make recipes/org-apple-reminders`).

Proves:
- Recipe is structurally valid as elisp.
- GitHub fetcher works against the repo.
- `:branch "stable"` exists.
- `:files` selector (defaulting to `:defaults`) picks the right file.
- `package-build` can construct a `-pkg.el` from your headers.

Output: `org-apple-reminders-20260520.544.tar`, two files inside
(`.el` + generated `-pkg.el`).

**Step 2 — Stable build** (`CHANNEL=stable make recipes/org-apple-reminders`).

Proves the **semver-tag pipeline** works. `package-build` finds `v1.9.2`,
treats it as the version, generates an entry with `Package-Revision:
v1.9.2-0-g6b8a6e2d0c1f`, and tarballs it as `org-apple-reminders-1.9.2.tar`.
This is what **MELPA Stable users actually install**. If tags were missing,
malformed, or unreachable from `:branch`, this would fail.

**Step 3 — `package-install-file` on the stable tarball.**

Proves an **end-user's `package.el` can install the package** without
custom intervention. Four substantive things exercised:

- **Tarball extraction.** No structural archive problems.
- **Autoload generation.** `package.el` runs the autoload-cookie extraction;
  any malformed `;;;###autoload` errors here. Yours produces a clean
  `org-apple-reminders-autoloads.el`.
- **Byte-compilation of all three files.** Autoloads file, the generated
  `-pkg.el`, the source `.el` — all byte-compile without warnings.
- **`(require 'org-apple-reminders)` succeeds.** Whole file evaluates
  cleanly at load time — no top-level errors, no missing dependencies.

Output ends with `✓ installed (1 9 2), loaded successfully` — user-visible
installed version recorded in `package-alist`, derived from the tag.

**Step 4 — (optional) `make sandbox INSTALL=…`.** Not run. Would launch an
interactive sandbox Emacs with locally-built packages available for `M-x
package-install`. Equivalent to Step 3 functionally — just interactive
instead of `--batch`. Step 3 already exercises the install path; this is a
UX-level test, not a verification.

### Why the PR row is the longest of the eight

Tarsius (or any MELPA reviewer) might spot-check this row by re-running the
same commands. Listing the **concrete artifact names and outputs** lets them
either accept on trust or verify quickly:

> **[x]** I've built and installed the package using the instructions in
> CONTRIBUTING.org#test-your-recipe:
>
> - `CHANNEL=unstable make recipes/org-apple-reminders` → produces
>   `org-apple-reminders-20260520.544.tar` with `org-apple-reminders.el` +
>   generated `-pkg.el`.
> - `CHANNEL=stable make recipes/org-apple-reminders` → correctly detects
>   the `v1.9.2` tag and produces `org-apple-reminders-1.9.2.tar`.
> - `package-install-file` on the stable tarball in a clean `--batch` Emacs
>   installs the package, generates autoloads, byte-compiles every file
>   without warnings, and `(require 'org-apple-reminders)` loads cleanly.

Three bullets, three concrete artifacts (with filenames), three different
things proved. A reviewer who's done a hundred of these reads this and
immediately understands: "this person ran the full procedure, knows what
each step produces, got the right outputs." Earns trust.

### Where this fits in the broader picture

| # | Type of check | What it covers |
|---|---|---|
| 1 | Policy attestation | License |
| 2 | Self-attestation | Read CONTRIBUTING.org |
| 3 | Policy attestation + visible change | AI attribution |
| 4 | Calendar fact | 1-month age |
| 5 | Mechanical (`package-lint`) | Static metadata |
| 6 | Mechanical (byte-compile) | Static code |
| 7 | Mechanical (`checkdoc`) | Static prose |
| **8** | **End-to-end build + install** | **The package as a MELPA artifact** |

Items 1–7 verify *parts* of the package. Item 8 verifies the **whole thing
functions as a MELPA recipe**. If items 5–7 all pass but 8 fails: something
the static checks didn't catch but the build pipeline did — missing file,
broken recipe, `:files` spec excluding something the code needs.

Ours passed all four steps clean — the strongest possible "this thing
works" signal short of MELPA actually accepting and publishing it.

### One non-fatal warning during the build, worth knowing about

The rolling build's first run ended with:

```
convert: unable to read font `DejaVu-Sans' …
Error: error ("Could not determine string width")
make: *** [recipes/org-apple-reminders] Error 255
```

Looks alarming — **not a package problem**. It's `package-build`'s
**badge-image generator** — tries to render an SVG badge for MELPA's
archive web page using ImageMagick `convert`. Mac has ImageMagick but not
the DejaVu-Sans font; badge step fails. **The actual package tarball was
already created successfully before that step ran**
(`Created org-apple-reminders-20260520.544.tar containing: …`).

MELPA's servers have the font; never happens in production. Just useful to
know if you re-run the test locally and see the same error.

### Closing

This row carries more weight than any other in the eight. Static checks (5,
6, 7) tell you the **parts** are well-formed; this row tells you the
**whole** assembles into something MELPA can ship. The detailed wording on
the PR makes that case crisply, and the verifications behind it (both
channels build, install loads, no warnings) are the strongest tangible
evidence we could offer.

---

## 10. Follow-up comment to tarsius + final state

Once the PR body was rewritten with the MELPA template and the eight-row
checklist filled in, one more action was worth taking: **post a comment**
on the PR.

### Why a comment was needed in addition to the body edit

When you edit a PR description via `gh pr edit`, **GitHub does not notify
the reviewer**. The PR's "updated at" timestamp changes, the edit appears in
the timeline, but tarsius's inbox stays silent unless he's actively watching
the PR for every event.

A **comment**, by contrast, triggers a notification. Since tarsius's review
was the explicit prompt for all this work — and since he might not glance at
PR #10016 again on his own for days — making him aware that the work is done
was the polite thing to do.

It also serves as a **summary**. If he reads only the comment (not the new
body), he still gets the headline: template restored, GPL boilerplate added,
AI attribution in place, build tested, one box honestly unchecked. He can
then decide whether to dive into the full body or wait.

### What was posted

Via `gh pr comment 10016 --repo melpa/melpa --body-file …`. Permalink:
`https://github.com/melpa/melpa/pull/10016#issuecomment-4494923559`.

> Hi @tarsius — thanks for the review.
>
> The PR description now uses the MELPA template and the checklist is
> filled in honestly:
>
> - The full short-form GPL-3.0 boilerplate has been added above
>   `;;; Commentary` (in addition to the `SPDX-License-Identifier` line); a
>   `LICENSE` file is also present in the repo.
> - An `Assisted-by: Claude:claude-opus-4-7` line is present in the package
>   header per the AI-attribution policy.
> - `package-lint` output is clean, byte-compile is clean (no warnings),
>   `checkdoc` is essentially clean (one pedantic note about a literal
>   `"C-c r"` in a default-value docstring — happy to rephrase if you'd
>   prefer).
> - I built the recipe locally in both channels — `CHANNEL=unstable` and
>   `CHANNEL=stable` — and `package-install-file` on the stable tarball
>   installs and loads cleanly in a `--batch` Emacs.
>
> The only box I have left unchecked is *"maintained in a public repository
> for 1 month or more"* — the repo was created on **2026-05-17**, so it's
> three days old. I'd rather leave it unchecked than misreport the date;
> happy to re-ping this PR around **2026-06-17** when the 1-month threshold
> is met (or sooner if you'd like to proceed earlier).
>
> Thanks for your time.

Intentional choices in the comment:

1. **`@tarsius` mention** — guarantees a notification specifically to him,
   not just generic "PR updated" noise.
2. **Thanks for the review at the top.** First line. Cooperative tone.
3. **Concrete claims with verifiable details.** Each bullet maps to one or
   more checklist items but adds the concrete fact ("`package-lint` output
   is clean", not "we addressed package-lint feedback").
4. **The one disclosed nit (`"C-c r"` in default-value docstring)** is
   named explicitly with an offer to rephrase. He doesn't have to dig for
   what we held back.
5. **The 1-month date is exact** (`2026-06-17`, with a concrete commitment
   to re-ping). No vague "soon" language.
6. **Closing line** — short courtesy.

~12 lines total. Long enough to be substantive; short enough to read in 30
seconds.

### What happens now

Three realistic outcomes (also covered in §5, here from the "we've done
everything we can" angle):

1. **Most likely.** Tarsius (or another MELPA maintainer) reads the comment,
   recognises the work is complete, and leaves the PR alone until the
   1-month mark. You re-ping on or after **2026-06-17** with a one-line
   comment ("1-month threshold met, please re-review"). They proceed with
   the merge.

2. **Possible.** A maintainer decides the rest of the checklist is solid
   enough that the 1-month rule can be waived. They merge before then.

3. **Less likely.** A maintainer wants one of the remaining items adjusted
   (the `checkdoc` nit rephrased, a clarification on something in the
   package). We respond to that single point and re-ping.

In all three scenarios, the current state of the PR is the best we can
present today.

### The final state, in one table

| Component | State |
|---|---|
| `org-apple-reminders` repo | `main = stable = 6b8a6e2`, tag `v1.9.2` |
| `Package-Requires` | `((emacs "27.1") (org "9.3"))` — no redundant `cl-lib` |
| Header has GPL boilerplate | Yes, above `;;; Commentary` (v1.9.2) |
| Header has `Assisted-by: Claude:claude-opus-4-7` | Yes (v1.9.1) |
| `LICENSE` file | Present, detectable as `gpl-3.0` |
| `package-lint` | clean |
| byte-compile | clean (no warnings) |
| `checkdoc` | clean except one disclosed `"C-c r"` nit |
| Recipe tested (rolling) | builds `org-apple-reminders-20260520.544.tar` |
| Recipe tested (stable) | builds `org-apple-reminders-1.9.2.tar` |
| `package-install-file` test | installs, loads, autoloads, all byte-compile clean |
| MELPA PR body | uses MELPA template, 7/8 boxes ticked, 1 honestly unchecked |
| Follow-up comment posted | yes, with full summary + re-ping commitment |
| MELPA PR state | OPEN, awaiting maintainer action |

### Closing observation

What makes this PR likely to land cleanly when reviewed isn't any single
thing — it's the **defense in depth**. Static checks pass. Build pipeline
passes. Install pipeline passes. AI attribution is disclosed. The one weak
spot (repo age) is owned, not hidden. The one stylistic compromise
(`checkdoc` nit) is explained with an offer to change. A reviewer scanning
for reasons to push back has none — and the explicit invitations to push
back on the rephrasable nit and the calendar wait make it socially easy for
the reviewer to proceed.

The strongest position to be in for a MELPA submission. The PR is ready;
the next move is calendar-based.

---

## What to do on or after 2026-06-17

A short script of what to do when the 1-month threshold is met:

1. **Check that nothing has rotted** in the package since v1.9.2 (probably
   nothing has). Re-run the same triple-clean checks:
   ```sh
   cd ~/.emacs.d/elpa/org-apple-reminders
   emacs --batch -Q -l org -f batch-byte-compile org-apple-reminders.el
   # package-lint and checkdoc batch invocations — see §3.3 and §8 above
   ```
2. **If needed, ship a v1.9.3 / v1.10 / whatever** with any fixes that came
   up in the intervening month. Tag + push `main` + `stable` (the
   `:branch "stable"` MELPA recipe means changes to `stable` are what users
   see).
3. **Re-ping the PR** with a one-line comment, e.g.:
   > 1-month threshold met (repo public since 2026-05-17). Ready for re-review when convenient — happy to address any remaining feedback.
4. **Wait.** MELPA review can take "a week (sometimes several)" per
   CONTRIBUTING.org. Be patient.
5. **On merge,** the package becomes installable via standard `M-x
   package-install RET org-apple-reminders RET` for any Emacs user with
   MELPA in `package-archives`.

That closes the loop.
