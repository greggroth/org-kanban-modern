# Copilot guide — org-agenda-kanban

Notes for AI assistants and contributors working in this repo. Keep changes
small, focused, and consistent with the conventions below.

## What this package is

`org-agenda-kanban` is an Emacs package that renders Org-mode TODOs as a kanban
board. It is deliberately a **view over Org**: it reuses standard `org-mode`
and `org-agenda` settings (`org-todo-keywords`, `org-agenda-files`,
`org-priority-faces`, `org-tag-faces`, `org-default-priority`, `org-log-done`,
…) rather than inventing parallel knobs. When you add behavior, ask first
whether Org already has the concept and mirror it; new user-facing knobs are a
last resort.

## Repository layout

- `org-agenda-kanban.el` — the entire library (single file, ~1500 lines).
- `test/org-agenda-kanban-test.el` — ERT tests for the pure logic
  (keyword stripping, column derivation, wrapping/padding, tag/priority
  filtering, bucketing).
- `examples/demo.org` — a self-contained board that exercises every feature.
- `screenshots/` — README images.
- `README.org` — user-facing documentation (org-mode, not markdown).

There is no build system. Lint with `checkdoc` / `byte-compile-file` on the
elisp file as needed; nothing else.

## How to run the tests

From the repo root:

```sh
emacs -Q --batch -L . \
  -l org-agenda-kanban.el \
  -l test/org-agenda-kanban-test.el \
  -f ert-run-tests-batch-and-exit
```

If you use `emacsclient` for interactive work, prefer it for byte-compilation,
`check-parens`, and ad-hoc ERT runs too — don't spin up new `emacs` processes
when an Emacs is already available.

When you add behavior, add an ERT test for the pure piece (collection,
filtering, sort, wrap, etc.). UI/face/keymap code is tested by hand against
`examples/demo.org`.

## Coding conventions

- **Lexical binding** on every file (`-*- lexical-binding: t; -*-`).
- **Prefix** every public symbol with `org-agenda-kanban-`; internal helpers
  use `org-agenda-kanban--` (double dash).
- **Emacs floor: 28.1.** No 29+ only features without bumping
  `Package-Requires`.
- `cl-lib`, `subr-x`, `org`, `org-element` are the allowed requires; do not add
  new dependencies casually.
- Use `defcustom` (with `:type`, `:group 'org-agenda-kanban`, and a docstring)
  for anything user-facing. Validate via a `:set` function when an invalid
  value can hang or error the renderer (see
  `org-agenda-kanban--validate-column-width` / `--validate-column-gap` and the
  setter pattern they use).
- Docstrings: first line is a complete sentence; reference other symbols with
  backticks (`like-this'`). Follow the style already in `org-agenda-kanban.el`.
- Card rendering assumes a **fixed-pitch monospace grid**. Defaults that
  appear in cards (glyphs, separators, header markers) must be ASCII so width
  is deterministic across fonts. Unicode is fine only as an opt-in via a
  defcustom.

## Behavioral conventions to preserve

A lot of past PRs have fixed regressions around these — keep them in mind:

- **Match `org-agenda` semantics** for priority. Unprioritized cards count as
  `org-default-priority` (normally `?B`) for both sorting **and** filtering.
- **Don't silently save the source buffer.** Card edits (move, set TODO, set
  priority, set tags) update the source heading but leave the buffer unsaved,
  exactly like Org Agenda. The `s` key (`org-save-all-org-buffers`) is the
  user's save affordance. Never call `save-buffer` on the source buffer as a
  side effect of a board edit.
- **Done filtering** uses the `CLOSED` timestamp. Cards without a `CLOSED`
  stamp are always shown (their age is unknown); active cards are always
  shown regardless of the window.
- **Validate dimensions** before render: `column-width` must be greater than
  `org-agenda-kanban--bar-width`; `column-gap` must be a non-negative integer.
  Both have setter validators and a `--validate-dimensions` helper — reuse
  them, don't add ad-hoc checks at call sites.
- **Tag filter** is two-state: a tag is either included (AND) or excluded
  (hides), never both at once.
- Keymap aims to mirror Org Agenda defaults (recent realignment PR). If you
  add a binding, check Org Agenda's binding for the same concept first and
  match it.

## Pull request workflow

- One concern per PR. The recent history is mostly small, focused PRs that
  address a single review finding or add a single feature.
- Branch names: `greggroth/<kebab-topic>` (e.g. `greggroth/validate-dimensions`,
  `greggroth/isearch-select-card`).
- Commit messages: imperative, scoped, no trailing period
  (e.g. "Validate kanban column dimensions",
  "Match agenda save behavior for board edits").
- Update `README.org` when user-facing behavior, keybindings, or defcustoms
  change. The README is the source of truth for the feature list; the package
  commentary is shorter and points users at the README.
- If you add or change a defcustom, also update the "Customization" section
  of `README.org`.

## Things to avoid

- Don't reintroduce the old `org-kanban-modern-` prefix anywhere.
- Don't commit `.DS_Store` or other machine metadata (already gitignored —
  keep it that way).
- Don't add a build tool, package manager, or CI config without being asked.
- Don't widen `Package-Requires` (currently `((emacs "28.1"))`) without a
  clear reason and an updated install section.
- Don't use non-ASCII glyphs as **defaults** in card rendering — they break
  the monospace grid on common fixed-pitch fonts. Provide them as opt-in
  defcustom values only.
