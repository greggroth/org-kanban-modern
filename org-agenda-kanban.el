;;; org-agenda-kanban.el --- A modern kanban board for Org TODOs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Gregg Rothmeier

;; Author: Gregg Rothmeier
;; Maintainer: Gregg Rothmeier
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: outlines, convenience, org
;; URL: https://github.com/greggroth/org-agenda-kanban

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; org-agenda-kanban presents Org-mode TODOs as a kanban board.  Columns are
;; TODO states (configurable, defaulting to `org-todo-keywords'); cards are TODO
;; headings collected from a configurable set of files (defaulting to
;; `org-agenda-files').
;;
;; Cards are selected by clicking and moved between columns with the keyboard;
;; moving a card writes the new TODO keyword back to the source buffer via
;; `org-todo'.  Tags are shown on cards as clickable chips and can be used to
;; filter the board elfeed-style: included tags combine with AND, and excluded
;; tags hide matching cards.  Cards can also be filtered by priority.
;;
;; Open the board with `M-x org-agenda-kanban'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-element)

;;;; Customization

(defgroup org-agenda-kanban nil
  "A modern kanban board for Org TODOs."
  :group 'org
  :prefix "org-agenda-kanban-")

(defconst org-agenda-kanban--bar-width 2
  "Columns reserved at the left of each card line for the selection bar.")

(defun org-agenda-kanban--validate-column-width (width)
  "Return WIDTH after validating `org-agenda-kanban-column-width'."
  (unless (and (integerp width) (> width org-agenda-kanban--bar-width))
    (user-error
     "`org-agenda-kanban-column-width' must be an integer greater than %d (got %S)"
     org-agenda-kanban--bar-width width))
  width)

(defun org-agenda-kanban--validate-column-gap (gap)
  "Return GAP after validating `org-agenda-kanban-column-gap'."
  (unless (and (integerp gap) (>= gap 0))
    (user-error
     "`org-agenda-kanban-column-gap' must be a non-negative integer (got %S)"
     gap))
  gap)

(defun org-agenda-kanban--set-column-width (symbol value)
  "Set SYMBOL to VALUE after validating the column width."
  (set-default symbol (org-agenda-kanban--validate-column-width value)))

(defun org-agenda-kanban--set-column-gap (symbol value)
  "Set SYMBOL to VALUE after validating the column gap."
  (set-default symbol (org-agenda-kanban--validate-column-gap value)))

(defun org-agenda-kanban--validate-dimensions ()
  "Validate board dimensions and return a cons of (WIDTH . GAP)."
  (cons (org-agenda-kanban--validate-column-width
         org-agenda-kanban-column-width)
        (org-agenda-kanban--validate-column-gap
         org-agenda-kanban-column-gap)))

(defcustom org-agenda-kanban-files nil
  "List of Org files to collect cards from.
When nil, the board uses `org-agenda-files'.  The value may be any
form accepted as an element of `org-agenda-files' resolution: file
names or directories."
  :type '(choice (const :tag "Use `org-agenda-files'" nil)
                 (repeat (choice (file :tag "File")
                                 (directory :tag "Directory"))))
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-columns nil
  "List of TODO keywords to use as board columns, left to right.
When nil, columns are derived from `org-todo-keywords' (all active
and done keywords, in order, with the \"|\" separator removed)."
  :type '(choice (const :tag "Derive from `org-todo-keywords'" nil)
                 (repeat string))
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-sort 'priority
  "How to order the cards within each column.
Possible values:
- `document' : keep the source document / collection order (the order
  headings appear in the Org files).
- `priority' : sort by Org priority, highest first (an =[#A]= card
  before =[#B]=).  Mirroring `org-agenda', a card with no priority
  cookie is treated as `org-default-priority' (normally =?B=), so it
  sorts among cards of that priority; equal-priority cards keep their
  document order.
- a function : a predicate of two cards, returning non-nil when the
  first card should sort before the second (passed to `sort')."
  :type '(choice (const :tag "Document order" document)
                 (const :tag "Priority, highest first" priority)
                 (function :tag "Custom predicate"))
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-column-width 26
  "Width, in characters, of each board column.
The value must be greater than `org-agenda-kanban--bar-width' so at
least one character remains for card content."
  :type 'natnum
  :set #'org-agenda-kanban--set-column-width
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-column-gap 2
  "Number of blank columns between board columns."
  :type 'natnum
  :set #'org-agenda-kanban--set-column-gap
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-buffer-name "*Kanban*"
  "Name of the buffer used to display the board."
  :type 'string
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-done-within-days 7
  "Number of days back for which done cards are shown.
A \"done\" card is one whose TODO keyword is among the buffer's done
keywords (those after the \"|\" in `org-todo-keywords').  When this is a
non-negative integer N, a done card appears only if its CLOSED timestamp
is within the last N days; done cards lacking a CLOSED timestamp are
always shown, since their age is unknown.  When nil, all done cards are
shown regardless of age.

This sets the initial value of the per-board window, which can be changed
interactively with `org-agenda-kanban-set-done-window'."
  :type '(choice (const :tag "Show all done cards" nil)
                 (integer :tag "Days"))
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-render-markup t
  "When non-nil, render Org inline markup in card titles.
Emphasis (=*bold*=, =/italic/=, =_underline_=, =~code~=, ==verbatim==,
=+strike+=) is shown with the corresponding face and its markers hidden,
and links such as =[[target][description]]= are shown as their
description.  When nil, titles are displayed as raw Org text."
  :type 'boolean
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-show-planning t
  "When non-nil, show a card's SCHEDULED and DEADLINE timestamps.
Each planning timestamp that is set on the heading is rendered on its
own line beneath the title, preserving any repeater (e.g. =+1w=).  The
glyphs are set by `org-agenda-kanban-scheduled-glyph' and
`org-agenda-kanban-deadline-glyph'."
  :type 'boolean
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-use-tag-faces t
  "When non-nil, color tag chips using Org's `org-tag-faces'.
Each tag's color (from `org-tag-faces', resolved via
`org-get-tag-face') is layered onto the chip while the package's
own state decoration is preserved: included tags stay inverse, and
excluded tags keep their strike-through.  A fixed-pitch family is
forced first so per-tag faces cannot break the card grid.  When
nil, chips use the package faces only, exactly as before."
  :type 'boolean
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-header-remove-glyph "x"
  "Marker shown on header filter chips to indicate click-to-remove.
Defaults to ASCII for portable fixed-pitch rendering.  Set this to a
Unicode marker such as \"✕\" if your fixed-pitch font supports it with
matching metrics."
  :type 'string
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-header-done-window-prefix "<="
  "Text shown before the active done-card day window in the header.
Defaults to ASCII for portable fixed-pitch rendering.  Set this to a
Unicode comparison marker such as \"≤\" if your fixed-pitch font supports
it with matching metrics."
  :type 'string
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-scheduled-glyph "S "
  "Prefix shown before a card's SCHEDULED timestamp.
Defaults to an ASCII label so its width is deterministic: cards are a
fixed-pitch monospace grid, and a non-ASCII glyph that is absent from
your fixed-pitch font is drawn from a fallback font whose advance does
not align to the grid, which misaligns the timestamp and can push it
past the card edge.  You may set a Unicode glyph (e.g. \"◷ \") only if it
is present in your fixed-pitch font with matching metrics."
  :type 'string
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-deadline-glyph "D "
  "Prefix shown before a card's DEADLINE timestamp.
Defaults to an ASCII label so its width is deterministic; see
`org-agenda-kanban-scheduled-glyph' for why non-ASCII glyphs can
misalign the monospace card grid.  You may set a Unicode glyph (e.g.
\"⚑ \") only if it is present in your fixed-pitch font."
  :type 'string
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-planning-compact t
  "When non-nil, omit the day-of-week name from planning timestamps.
Planning timestamps (with a date, optional time, and any repeater) are
often wider than a card.  The weekday name is redundant with the date,
so dropping it (e.g. =2026-06-03 11:00 +1w= instead of =2026-06-03 Wed
11:00 +1w=) helps the timestamp fit the card width.  Set to nil to keep
the weekday name."
  :type 'boolean
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-priority-style 'cookie
  "How a card reflects its Org priority.
Priority colors come from Org's own `org-priority-faces' (with the
`org-priority' face as fallback) — the same source org-agenda and Org
font-locking use — so the board matches your configured priority colors
instead of inventing its own.

Possible values:

  cookie  Color the [#X] priority cookie on the card (default).
  nil     Render priorities with no special color.

A selected card always uses the selection background regardless of
priority; its cookie is still colored when the style is `cookie'."
  :type '(choice (const :tag "Color the priority cookie" cookie)
                 (const :tag "No priority color" nil))
  :group 'org-agenda-kanban)

(defcustom org-agenda-kanban-line-spacing 0
  "Buffer-local `line-spacing' for the kanban board.
The board renders each card as a solid colored tile spanning several
screen lines.  When extra vertical space is added between lines, the
card background (like `hl-line') does not fill that space, so faint
horizontal stripes appear between a card's wrapped lines.

The default of 0 removes that extra space so cards read as continuous
tiles.  Note that a value of nil does NOT mean \"no spacing\"; like the
standard `line-spacing' variable, nil falls back to the frame's
`line-spacing' parameter (often the source of the stripes), so use 0 to
guarantee solid tiles.  A positive number adds that many pixels (or, if
a float, that fraction of the default line height) between lines."
  :type '(choice (const :tag "No extra spacing (solid tiles)" 0)
                 (number :tag "Pixels (or fraction if < 1.0)")
                 (const :tag "Inherit the frame's line-spacing" nil))
  :group 'org-agenda-kanban)

;;;; Faces

;; All board faces are defined by INHERITANCE from standard faces rather than
;; with literal colors, so the board adapts to the active theme (including
;; `modus-themes', `ef-themes', and the built-in light/dark defaults).  The
;; subtle vs. selected card backgrounds come from `hl-line' and `region', which
;; every well-behaved theme styles as a neutral row highlight and the selection
;; color respectively.  Per-element faces (title, tag, priority) deliberately do
;; NOT set a background; the card background face is composed underneath them as
;; a face list at render time, so the card block reads as one continuous tile.
;; Everything also inherits `fixed-pitch' so column alignment is by display
;; width even when the user's `default' face is variable-pitch.

(defface org-agenda-kanban-column-header
  '((t :inherit (fixed-pitch mode-line-emphasis) :weight bold))
  "Face for column headers.
Inherits `mode-line-emphasis' so it picks up the theme's accent."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-card
  '((t :inherit (fixed-pitch hl-line)))
  "Face for an unselected card body.
Inherits `hl-line' for a subtle, theme-aware neutral background."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-card-selected
  '((t :inherit (fixed-pitch region)))
  "Face for the currently selected card body.
Inherits `region' so the selection uses the theme's selection color."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-selection-bar
  '((t :inherit (fixed-pitch link) :weight bold))
  "Face supplying the accent color of the selected card's bar.
Inherits `link' to borrow the theme's accent foreground.  On graphical
frames the bar is drawn as a solid background fill using this face's
foreground color, so it tiles seamlessly across a card's lines; where no
color is available (e.g. a terminal) the bar falls back to a `▌' glyph
drawn with this face."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-title
  '((t :inherit fixed-pitch :weight bold))
  "Face for a card title.
Sets no background so the card background shows through."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-priority
  '((t :inherit (fixed-pitch org-priority)))
  "Face for a card priority cookie."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-scheduled
  '((t :inherit (fixed-pitch org-scheduled)))
  "Face for a card's SCHEDULED timestamp line."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-deadline
  '((t :inherit (fixed-pitch org-upcoming-deadline)))
  "Face for a card's DEADLINE timestamp line."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-tag
  '((t :inherit (fixed-pitch org-tag)))
  "Face for a tag chip on a card."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-tag-active
  '((t :inherit (fixed-pitch org-tag) :inverse-video t :weight bold))
  "Face for a tag chip that is included in the active filter.
Uses `:inverse-video' so the highlight tracks the theme."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-tag-excluded
  '((t :inherit (fixed-pitch org-tag shadow) :strike-through t))
  "Face for a tag chip that is excluded from the active filter.
The strike-through and dimmed `shadow' inheritance signal that cards
carrying this tag are hidden; both track the theme."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-tag-hover
  '((t :inherit (org-agenda-kanban-tag highlight)))
  "Face shown while the mouse hovers a clickable tag chip.
Layers the theme's `highlight' background beneath the tag styling to
signal that clicking the tag toggles it in the filter."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-filter-chip
  '((t :inherit (fixed-pitch mode-line-emphasis) :inverse-video t))
  "Face for an active include-filter chip in the header line."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-filter-chip-exclude
  '((t :inherit (fixed-pitch mode-line-emphasis) :inverse-video t
       :strike-through t))
  "Face for an active exclude-filter chip in the header line.
Like `org-agenda-kanban-filter-chip' but struck through to mark that the
tag is excluded rather than required."
  :group 'org-agenda-kanban)

(defface org-agenda-kanban-empty
  '((t :inherit (fixed-pitch shadow) :slant italic))
  "Face for placeholder text on an empty board or column."
  :group 'org-agenda-kanban)

;;;; Card model

(cl-defstruct (org-agenda-kanban-card
               (:constructor org-agenda-kanban-card-create)
               (:copier nil))
  "A single board card derived from an Org TODO heading.
ID is a stable identifier (file plus outline path) that survives a
TODO state change, so selection can be preserved across a move.
MARKER points at the source heading in its (live) file buffer and is
used as the fast path for locating the heading to move; it is
verified against TITLE before any destructive edit.
CLOSED is the entry's CLOSED time (a Lisp time value) or nil.
SCHEDULED and DEADLINE are the entry's raw planning timestamp strings
\(e.g. \"<2026-06-02 Tue +1w>\"), preserving any repeater, or nil."
  id file marker title todo tags priority closed scheduled deadline)

(defun org-agenda-kanban--strip-keyword (kw)
  "Return the bare keyword name of KW from `org-todo-keywords'.
KW may contain fast-access and logging annotations such as
\"WAITING(w@/!)\"; this returns just \"WAITING\"."
  (if (string-match "\\`\\([^(]+\\)" kw)
      (string-trim (match-string 1 kw))
    kw))

(defun org-agenda-kanban--default-columns ()
  "Derive the default column list from `org-todo-keywords'."
  (delete-dups
   (cl-loop for seq in org-todo-keywords
            append (cl-loop for kw in (cdr seq)
                            for name = (org-agenda-kanban--strip-keyword kw)
                            unless (string= name "|")
                            collect name))))

(defun org-agenda-kanban--columns ()
  "Return the effective list of column keywords."
  (or org-agenda-kanban-columns
      (org-agenda-kanban--default-columns)))

(defun org-agenda-kanban--resolve-files ()
  "Return the list of files to scan for cards."
  (let ((org-agenda-files (or org-agenda-kanban-files org-agenda-files)))
    (org-agenda-files t)))

(defun org-agenda-kanban--file-buffer (file)
  "Return a live buffer visiting FILE, opening it if necessary."
  (or (find-buffer-visiting file)
      (find-file-noselect file)))

(defun org-agenda-kanban--effective-tags ()
  "Return the effective tags at point as a list of plain strings."
  (mapcar #'substring-no-properties (org-get-tags)))

(defun org-agenda-kanban--card-at-point (todo seen)
  "Build a card for the heading at point with TODO keyword TODO.
SEEN is a hash table used to disambiguate duplicate outline paths."
  (let* ((el (org-element-at-point))
         (title (or (org-element-property :raw-value el) ""))
         (priority (org-element-property :priority el))
         (tags (org-agenda-kanban--effective-tags))
         (closed (org-agenda-kanban--closed-time))
         (scheduled (org-agenda-kanban--planning-raw el :scheduled))
         (deadline (org-agenda-kanban--planning-raw el :deadline))
         (path (org-get-outline-path t))
         (base (concat (buffer-file-name) "\0"
                       (mapconcat #'identity path "/")))
         (n (puthash base (1+ (gethash base seen 0)) seen))
         (id (if (> n 1) (format "%s#%d" base n) base)))
    (org-agenda-kanban-card-create
     :id id
     :file (buffer-file-name)
     :marker (copy-marker (point))
     :title title
     :todo todo
     :tags tags
     :priority priority
     :closed closed
     :scheduled scheduled
     :deadline deadline)))

(defun org-agenda-kanban--planning-raw (el prop)
  "Return the raw planning timestamp string of headline EL for PROP.
PROP is `:scheduled' or `:deadline'.  Returns the timestamp's raw
value (preserving any repeater), or nil when unset or malformed."
  (let ((ts (org-element-property prop el)))
    (and (eq (org-element-type ts) 'timestamp)
         (org-element-property :raw-value ts))))

(defvar-local org-agenda-kanban--done-window nil
  "Days back within which done cards are shown, or nil to show all.
Initialized from `org-agenda-kanban-done-within-days' and adjustable
with `org-agenda-kanban-set-done-window'.")

(defun org-agenda-kanban--closed-time ()
  "Return the CLOSED time of the entry at point as a Lisp time, or nil."
  (let ((s (org-entry-get (point) "CLOSED")))
    (and s (org-time-string-to-time s))))

(defun org-agenda-kanban--show-entry-p (todo window now)
  "Return non-nil if the entry at point passes the done-date filter.
TODO is the entry's keyword; this must run in the entry's Org buffer so
`org-done-keywords' is accurate.  WINDOW is the number of days back to
keep done cards (nil shows all).  NOW is the reference time.  Non-done
entries always pass; a done entry passes when WINDOW is nil, when it has
no CLOSED timestamp, or when its CLOSED time is within WINDOW days."
  (or (null window)
      (not (member todo org-done-keywords))
      (let ((time (org-agenda-kanban--closed-time)))
        (or (null time)
            (<= (float-time (time-subtract now time))
                (* window 86400))))))

(defun org-agenda-kanban--collect ()
  "Collect cards from the configured files into a flat list.
Only headings whose TODO keyword is one of the configured columns are
included.  Done headings closed more than `org-agenda-kanban--done-window'
days ago are skipped."
  (let ((columns (org-agenda-kanban--columns))
        (window org-agenda-kanban--done-window)
        (now (current-time))
        (seen (make-hash-table :test 'equal))
        (cards '()))
    (dolist (file (org-agenda-kanban--resolve-files))
      (when (file-readable-p file)
        (with-current-buffer (org-agenda-kanban--file-buffer file)
          (when (derived-mode-p 'org-mode)
            (org-with-wide-buffer
             (goto-char (point-min))
             (org-map-entries
              (lambda ()
                (let ((todo (org-get-todo-state)))
                  (when (and todo (member todo columns)
                             (org-agenda-kanban--show-entry-p todo window now))
                    (push (org-agenda-kanban--card-at-point todo seen)
                          cards))))
              nil 'file))))))
    (nreverse cards)))

;;;; Buffer-local state

(defvar-local org-agenda-kanban--cards nil
  "All cards collected from the source files (unfiltered).")

(defvar-local org-agenda-kanban--visible nil
  "Cards passing the active filters, in collection order.")

(defvar-local org-agenda-kanban--layout nil
  "Alist of (COLUMN . IDS) describing the last render, top to bottom.")

(defvar-local org-agenda-kanban--selected-id nil
  "ID of the currently selected card, or nil.")

(defvar-local org-agenda-kanban--tag-filter nil
  "List of tags a card must all carry to be shown (the include filter).")

(defvar-local org-agenda-kanban--tag-exclude nil
  "List of tags that hide a card when present (the exclude filter).
A card is shown only if it carries none of these tags.")

(defvar-local org-agenda-kanban--priority-filter nil
  "Effective priority character cards must match, or nil for no priority filter.
Cards with no explicit priority use `org-default-priority', matching
the default priority sort and `org-agenda'.")

;;;; Filtering

(defun org-agenda-kanban--tag-state (tag)
  "Return TAG's current filter state: `include', `exclude', or nil."
  (cond
   ((member tag org-agenda-kanban--tag-filter) 'include)
   ((member tag org-agenda-kanban--tag-exclude) 'exclude)
   (t nil)))

(defun org-agenda-kanban--set-tag-state (tag state)
  "Set TAG's filter STATE, keeping the include and exclude lists disjoint.
STATE is `include', `exclude', or nil.  A tag is in at most one list;
moving it into one list removes it from the other.  This is the only
function that should mutate the tag-filter lists, so the invariant that
no tag is both included and excluded always holds."
  (setq org-agenda-kanban--tag-filter
        (delete tag org-agenda-kanban--tag-filter)
        org-agenda-kanban--tag-exclude
        (delete tag org-agenda-kanban--tag-exclude))
  (pcase state
    ('include (push tag org-agenda-kanban--tag-filter))
    ('exclude (push tag org-agenda-kanban--tag-exclude))))

(defun org-agenda-kanban--priority-rank (card)
  "Return a sortable rank for CARD's priority; lower sorts first.
Priorities rank by their character code (so =?A= precedes =?B=).
Mirroring `org-agenda', a card with no explicit priority cookie is
treated as having `org-default-priority', so it sorts alongside cards
of that priority rather than last."
  (or (org-agenda-kanban-card-priority card) org-default-priority))

(defun org-agenda-kanban--filtered (cards)
  "Return the members of CARDS passing the active filters."
  (cl-remove-if-not
   (lambda (card)
     (let ((tags (org-agenda-kanban-card-tags card)))
       (and (or (null org-agenda-kanban--tag-filter)
                (cl-subsetp org-agenda-kanban--tag-filter tags
                            :test #'string=))
            (or (null org-agenda-kanban--tag-exclude)
                (null (cl-intersection org-agenda-kanban--tag-exclude tags
                                       :test #'string=)))
            (or (null org-agenda-kanban--priority-filter)
                (eql org-agenda-kanban--priority-filter
                     (org-agenda-kanban--priority-rank card))))))
   cards))

(defun org-agenda-kanban--sort-cards (cards)
  "Return CARDS ordered per `org-agenda-kanban-sort'.
CARDS is not modified.  `sort' is stable, so equal-ranked cards keep
their incoming (document) order."
  (pcase org-agenda-kanban-sort
    ('priority
     (sort (copy-sequence cards)
           (lambda (a b)
             (< (org-agenda-kanban--priority-rank a)
                (org-agenda-kanban--priority-rank b)))))
    ((and (pred functionp) pred)
     (sort (copy-sequence cards) pred))
    (_ cards)))

(defun org-agenda-kanban--cards-for-column (column cards)
  "Return the members of CARDS whose TODO keyword is COLUMN.
The result is ordered according to `org-agenda-kanban-sort'."
  (org-agenda-kanban--sort-cards
   (cl-remove-if-not
    (lambda (card) (string= (org-agenda-kanban-card-todo card) column))
    cards)))

(defun org-agenda-kanban--all-tags ()
  "Return a sorted list of every tag present on a collected card."
  (let ((tags '()))
    (dolist (card org-agenda-kanban--cards)
      (dolist (tag (org-agenda-kanban-card-tags card))
        (cl-pushnew tag tags :test #'string=)))
    (sort tags #'string<)))

;;;; Layout helpers (all width math uses display width)

(defun org-agenda-kanban--pad (str width)
  "Return STR truncated or space-padded to exactly WIDTH display columns.
Text properties on STR are preserved."
  (unless (and (integerp width) (>= width 0))
    (user-error "Pad width must be a non-negative integer (got %S)" width))
  (let ((w (string-width str)))
    (cond ((= w width) str)
          ((> w width) (truncate-string-to-width str width nil nil t))
          (t (concat str (make-string (- width w) ?\s))))))

(defun org-agenda-kanban--wrap (str width)
  "Wrap STR into a list of lines, each at most WIDTH display columns."
  (unless (and (integerp width) (> width 0))
    (user-error "Wrap width must be a positive integer (got %S)" width))
  (if (<= (string-width str) width)
      (list str)
    (let ((words (split-string str " " t))
          (lines '())
          (cur ""))
      (dolist (word words)
        (cond
         ((string= cur "")
          (if (<= (string-width word) width)
              (setq cur word)
            ;; A single word longer than WIDTH: hard-break it.
            (let ((rest word))
              (while (> (string-width rest) width)
                (let* ((head (truncate-string-to-width rest width))
                       (advance (max 1 (length head))))
                  (when (string-empty-p head)
                    (setq head (substring rest 0 advance)))
                  (push head lines)
                  (setq rest (substring rest advance))))
              (setq cur rest))))
         ((<= (string-width (concat cur " " word)) width)
          (setq cur (concat cur " " word)))
         (t (push cur lines)
            (setq cur word))))
      (unless (string= cur "") (push cur lines))
      (nreverse lines))))

;;;; Card rendering

(defconst org-agenda-kanban--markup-strip-props
  '(keymap nil help-echo nil mouse-face nil htmlize-link nil org-emphasis nil
    font-lock-multiline nil rear-nonsticky nil invisible nil)
  "Property/value plist removed from fontified titles via `remove-text-properties'.
These are Org/font-lock interaction properties that must not leak onto a
kanban card; only display faces are kept.")

(defun org-agenda-kanban--fontify-title (title)
  "Return TITLE with Org inline markup rendered, honoring options.
When `org-agenda-kanban-render-markup' is nil, return a fresh copy of
TITLE unchanged.  Otherwise fontify it like Org would, drop the now-hidden
emphasis markers so that `string-width' again equals the displayed width
\(keeping wrapping and padding correct), and strip Org's link keymap and
help-echo so cards keep their own click behavior."
  (if (not org-agenda-kanban-render-markup)
      (copy-sequence title)
    (let* ((org-hide-emphasis-markers t)
           (org-link-descriptive t)
           (fontified (condition-case nil
                          (org-fontify-like-in-org-mode title)
                        (error nil))))
      (if (null fontified)
          (copy-sequence title)
        (let ((i 0) (n (length fontified)) (parts '()))
          (while (< i n)
            (if (get-text-property i 'invisible fontified)
                (setq i (or (next-single-property-change i 'invisible fontified) n))
              (let ((next (or (next-single-property-change i 'invisible fontified)
                              n)))
                (push (substring fontified i next) parts)
                (setq i next))))
          (let ((s (apply #'concat (nreverse parts))))
            (remove-text-properties 0 (length s)
                                    org-agenda-kanban--markup-strip-props s)
            s))))))

(defun org-agenda-kanban--priority-spec (priority)
  "Return the configured face-or-color for PRIORITY from `org-priority-faces'.
Return nil when PRIORITY is nil or has no configured entry.  Each value
in `org-priority-faces' is, per Org, a face symbol or a color string."
  (and priority (cdr (assq priority org-priority-faces))))

(defun org-agenda-kanban--priority-cookie-face (priority)
  "Return the `face' value used to render PRIORITY's [#X] cookie.
Layer the per-priority color from `org-priority-faces' over
`org-agenda-kanban-priority' (so the cookie keeps fixed-pitch and the
base styling).  When PRIORITY has no configured entry, fall back to
`org-agenda-kanban-priority' alone."
  (let ((spec (org-agenda-kanban--priority-spec priority)))
    (cond
     ((null spec) 'org-agenda-kanban-priority)
     ;; A literal color string sets only the foreground.
     ((stringp spec)
      (list (list :foreground spec) 'org-agenda-kanban-priority))
     ;; A face symbol or attribute plist: apply it first so it wins, with
     ;; our face underneath for fixed-pitch.
     (t (list spec 'org-agenda-kanban-priority)))))

(defun org-agenda-kanban--format-timestamp (raw)
  "Return RAW Org timestamp string with its delimiter brackets removed.
Removes the active =<>= and inactive =[]= delimiters (including the inner
pair of a =<a>--<b>= range) while keeping the dates, times, and any
repeater or warning period intact."
  (string-trim (replace-regexp-in-string "[][<>]" "" raw)))

(defun org-agenda-kanban--strip-weekday (ts)
  "Return TS (a bracket-stripped timestamp) without its day-of-week name.
Org renders a timestamp's date as =YYYY-MM-DD DAYNAME=; the DAYNAME token
(localised, possibly non-ASCII and possibly ending in =.=) sits between
the date and any time or repeater.  TS is only compacted when it begins
with an ISO date and is not a =<a>--<b>= range (so diary sexp timestamps
and ranges are returned unchanged).  The weekday is dropped only when it
is the second whitespace token and is neither a time (contains =:=), a
repeater/warning (starts with =+=, =-=, or =.=), nor numeric."
  (if (or (string-match-p "--" ts)
          (not (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\(?: \\|\\'\\)"
                               ts)))
      ts
    (let ((parts (split-string ts " " t)))
      (if (and (cdr parts)
               (let ((tok (nth 1 parts)))
                 (and (not (string-match-p ":" tok))
                      (not (string-match-p "\\`[-+.0-9]" tok)))))
          (mapconcat #'identity (cons (car parts) (cddr parts)) " ")
        ts))))

(defun org-agenda-kanban--planning-line (glyph raw face content-width)
  "Return a propertized planning line for RAW timestamp.
GLYPH prefixes the formatted timestamp and FACE styles the line.  When
`org-agenda-kanban-planning-compact' is non-nil the day-of-week name is
dropped so the timestamp is more likely to fit.  The line is truncated
to CONTENT-WIDTH display columns."
  (let* ((ts (org-agenda-kanban--format-timestamp raw))
         (ts (if org-agenda-kanban-planning-compact
                 (org-agenda-kanban--strip-weekday ts)
               ts))
         (text (concat glyph ts))
         (shown (if (> (string-width text) content-width)
                    (truncate-string-to-width text content-width nil nil t)
                  text)))
    (propertize shown 'face face)))

(defun org-agenda-kanban--planning-lines (card content-width)
  "Return CARD's planning lines (0-2) truncated to CONTENT-WIDTH.
Returns the deadline line first (when set) then the scheduled line (when
set), or nil when planning display is disabled or neither is set."
  (when org-agenda-kanban-show-planning
    (let ((lines '()))
      (when-let ((d (org-agenda-kanban-card-deadline card)))
        (push (org-agenda-kanban--planning-line
               org-agenda-kanban-deadline-glyph d
               'org-agenda-kanban-deadline content-width)
              lines))
      (when-let ((s (org-agenda-kanban-card-scheduled card)))
        (push (org-agenda-kanban--planning-line
               org-agenda-kanban-scheduled-glyph s
               'org-agenda-kanban-scheduled content-width)
              lines))
      (nreverse lines))))

(defvar org-agenda-kanban--tag-chip-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [S-mouse-1] #'org-agenda-kanban--mouse-exclude-click)
    map)
  "Keymap placed on card tag chips so S-mouse-1 toggles the exclude filter.
Plain mouse-1 is intentionally left to the mode map's selection handler.")

(defun org-agenda-kanban--chip-face (tag base)
  "Return the `face' value for a chip showing TAG, layered over BASE.
When `org-agenda-kanban-use-tag-faces' is nil, BASE is returned
unchanged.  Otherwise a face list is returned: `fixed-pitch'
first (so a per-tag face cannot change the chip's family and break
the card grid), then the tag's own face from `org-get-tag-face'
\(supplying the tag color, or `org-tag' when the tag is unmapped),
then BASE last (so the package's state decoration -- inverse-video
for include, strike-through for exclude -- still applies)."
  (if org-agenda-kanban-use-tag-faces
      (list 'fixed-pitch (org-get-tag-face tag) base)
    base))

(defun org-agenda-kanban--tags-string (card content-width)
  "Return a propertized, clickable tag string for CARD.
The result is truncated to CONTENT-WIDTH display columns."
  (let ((chips '()))
    (dolist (tag (org-agenda-kanban-card-tags card))
      (let ((face (org-agenda-kanban--chip-face
                   tag
                   (pcase (org-agenda-kanban--tag-state tag)
                     ('include 'org-agenda-kanban-tag-active)
                     ('exclude 'org-agenda-kanban-tag-excluded)
                     (_ 'org-agenda-kanban-tag)))))
        (push (propertize (concat "#" tag)
                          'face face
                          'org-agenda-kanban-tag tag
                          'mouse-face 'org-agenda-kanban-tag-hover
                          'keymap org-agenda-kanban--tag-chip-keymap
                          'help-echo "mouse-1: include this tag, S-mouse-1: exclude it")
              chips)))
    (let ((s (mapconcat #'identity (nreverse chips) " ")))
      (if (> (string-width s) content-width)
          (truncate-string-to-width s content-width nil nil t)
        s))))

(defun org-agenda-kanban--finish-line (content width base bar-face bar-char id)
  "Assemble one card line of exactly WIDTH columns.
CONTENT is the (already propertized) text after the selection bar.
BASE is the card background face, applied beneath everything so the
padding is filled.  BAR-FACE/BAR-CHAR draw the selection bar.  ID is
stamped on every character so click and movement commands can find the
card; it never clobbers the per-tag properties (such as the tag chips'
own `mouse-face') already on CONTENT.

No card-wide `mouse-face' is set: the whole card does not change color on
hover.  Only the tag chips carry a hover face, signalling that they are
the clickable, filter-toggling elements."
  (let* ((content-width (- width org-agenda-kanban--bar-width))
         (padded (org-agenda-kanban--pad content content-width))
         (line (concat (propertize bar-char 'face bar-face)
                       (propertize " " 'face base)
                       padded)))
    ;; Lay BASE underneath as the lowest-priority face so blank padding gets
    ;; the card background while title/tag faces keep precedence.
    (add-face-text-property 0 (length line) base t line)
    (add-text-properties 0 (length line)
                         (list 'org-agenda-kanban-card-id id
                               'help-echo "mouse-1: select  M-<left>/<right>: move")
                         line)
    line))

(defun org-agenda-kanban--card-lines (card width selectedp)
  "Return a list of WIDTH-wide propertized lines rendering CARD."
  (let* ((content-width (- width org-agenda-kanban--bar-width))
         (prio (org-agenda-kanban-card-priority card))
         (base (cond (selectedp 'org-agenda-kanban-card-selected)
                     (t 'org-agenda-kanban-card)))
         ;; Draw the selection accent as a solid background fill rather than a
         ;; foreground glyph: a half-block character only paints as tall as its
         ;; glyph, so it looks segmented between a card's lines, whereas a
         ;; background fill tiles seamlessly across them.
         (bar-color (and selectedp
                         (or (face-foreground 'org-agenda-kanban-selection-bar nil t)
                             (face-foreground 'link nil t))))
         (bar-face (cond ((not selectedp) base)
                         (bar-color (list (list :background bar-color) base))
                         (t (list 'org-agenda-kanban-selection-bar base))))
         (bar-char (if (and selectedp (not bar-color)) "▌" " "))
         (id (org-agenda-kanban-card-id card))
         (rendered (org-agenda-kanban--fontify-title
                    (org-agenda-kanban-card-title card)))
         (title (concat (when prio (propertize (format "[#%c] " prio)
                                               ;; Any non-nil style colors the
                                               ;; cookie, so a legacy
                                               ;; `background'/`both' value
                                               ;; migrates to cookie coloring
                                               ;; rather than no color at all.
                                               'face (if org-agenda-kanban-priority-style
                                                        (org-agenda-kanban--priority-cookie-face prio)
                                                       'org-agenda-kanban-priority)))
                        (progn
                          ;; Lay the title face underneath as the base so any
                          ;; emphasis/link faces from the markup take precedence.
                          (add-face-text-property 0 (length rendered)
                                                  'org-agenda-kanban-title t rendered)
                          rendered)))
         (title-lines (org-agenda-kanban--wrap title content-width))
         (lines '()))
    ;; Cap card height: at most three title lines, with an ellipsis if clipped.
    (when (> (length title-lines) 3)
      (setq title-lines (append (seq-take title-lines 2)
                                (list (org-agenda-kanban--pad
                                       (concat (nth 2 title-lines) "…")
                                       content-width)))))
    (dolist (tl title-lines)
      (push (org-agenda-kanban--finish-line tl width base bar-face bar-char id)
            lines))
    (dolist (pl (org-agenda-kanban--planning-lines card content-width))
      (push (org-agenda-kanban--finish-line pl width base bar-face bar-char id)
            lines))
    (when (org-agenda-kanban-card-tags card)
      (push (org-agenda-kanban--finish-line
             (org-agenda-kanban--tags-string card content-width)
             width base bar-face bar-char id)
            lines))
    (nreverse lines)))

(defun org-agenda-kanban--column-block (cards width)
  "Return a flat list of WIDTH-wide lines stacking CARDS for one column.
A blank separator line is inserted after each card."
  (let ((blank (make-string width ?\s))
        (out '()))
    (if (null cards)
        (list (org-agenda-kanban--pad
               (propertize "  (empty)" 'face 'org-agenda-kanban-empty)
               width))
      (dolist (card cards)
        (setq out (append out
                          (org-agenda-kanban--card-lines
                           card width
                           (equal (org-agenda-kanban-card-id card)
                                  org-agenda-kanban--selected-id))
                          (list blank))))
      out)))

;;;; Board rendering

(defun org-agenda-kanban--render ()
  "Redraw the board from `org-agenda-kanban--visible'."
  (let* ((inhibit-read-only t)
         (dimensions (org-agenda-kanban--validate-dimensions))
         (columns (org-agenda-kanban--columns))
         (width (car dimensions))
         (gap (make-string (cdr dimensions) ?\s))
         (by-column (mapcar (lambda (col)
                              (cons col (org-agenda-kanban--cards-for-column
                                         col org-agenda-kanban--visible)))
                            columns)))
    (setq org-agenda-kanban--layout
          (mapcar (lambda (cell)
                    (cons (car cell)
                          (mapcar #'org-agenda-kanban-card-id (cdr cell))))
                  by-column))
    (erase-buffer)
    (cond
     ((null columns)
      (insert (propertize "No columns configured.\n"
                          'face 'org-agenda-kanban-empty)))
     ((null org-agenda-kanban--cards)
      (insert (propertize "No TODO cards found in the configured files.\n"
                          'face 'org-agenda-kanban-empty)))
     ((null org-agenda-kanban--visible)
      (insert (propertize "No cards match the active filters.\n"
                          'face 'org-agenda-kanban-empty)))
     (t
      ;; Column headers.
      (insert (mapconcat
               (lambda (cell)
                 (org-agenda-kanban--pad
                  (propertize (format " %s (%d)" (car cell) (length (cdr cell)))
                              'face 'org-agenda-kanban-column-header)
                  width))
               by-column gap))
      (insert "\n\n")
      ;; Zip the per-column blocks row by row.
      (let* ((blocks (mapcar (lambda (cell)
                               (org-agenda-kanban--column-block (cdr cell) width))
                             by-column))
             (height (apply #'max 0 (mapcar #'length blocks)))
             (blank (make-string width ?\s)))
        (dotimes (row height)
          (insert (mapconcat (lambda (block) (or (nth row block) blank))
                             blocks gap))
          (insert "\n")))))
    (set-buffer-modified-p nil)
    (org-agenda-kanban--goto-selected)))

(defun org-agenda-kanban--goto-selected ()
  "Move point to the start of the selected card, if it is visible."
  (when org-agenda-kanban--selected-id
    (let ((pos (point-min)) found)
      (while (and (not found)
                  (setq pos (next-single-property-change
                             pos 'org-agenda-kanban-card-id)))
        (when (equal (get-text-property pos 'org-agenda-kanban-card-id)
                     org-agenda-kanban--selected-id)
          (setq found pos)))
      (when found (goto-char found)))))

;;;; Selection bookkeeping

(defun org-agenda-kanban--visible-ids ()
  "Return the IDs of all visible cards in collection order."
  (mapcar #'org-agenda-kanban-card-id org-agenda-kanban--visible))

(defun org-agenda-kanban--ensure-selection ()
  "Fix `org-agenda-kanban--selected-id' so it points at a visible card.
If the current selection is still visible it is kept; otherwise the
first visible card is selected, or nil when nothing is visible."
  (let ((ids (org-agenda-kanban--visible-ids)))
    (unless (and org-agenda-kanban--selected-id
                 (member org-agenda-kanban--selected-id ids))
      (setq org-agenda-kanban--selected-id (car ids)))))

(defun org-agenda-kanban--apply-filters ()
  "Recompute visible cards, fix the selection, and redraw."
  (setq org-agenda-kanban--visible
        (org-agenda-kanban--filtered org-agenda-kanban--cards))
  (org-agenda-kanban--ensure-selection)
  (org-agenda-kanban--render))

(defun org-agenda-kanban--selected-card ()
  "Return the currently selected card object, or nil."
  (and org-agenda-kanban--selected-id
       (cl-find org-agenda-kanban--selected-id org-agenda-kanban--cards
                :key #'org-agenda-kanban-card-id :test #'equal)))

(defun org-agenda-kanban--column-of (id)
  "Return the column keyword whose visible list contains ID, or nil."
  (cl-loop for (col . ids) in org-agenda-kanban--layout
           when (member id ids) return col))

;;;; Navigation commands

(defun org-agenda-kanban--select (id)
  "Set the selection to ID and redraw."
  (setq org-agenda-kanban--selected-id id)
  (org-agenda-kanban--render))

(defun org-agenda-kanban-next-card ()
  "Select the next card down in the current column."
  (interactive)
  (let* ((id org-agenda-kanban--selected-id)
         (col (and id (org-agenda-kanban--column-of id)))
         (ids (cdr (assoc col org-agenda-kanban--layout)))
         (i (and ids (cl-position id ids :test #'equal))))
    (cond
     ((null id) (message "No card selected"))
     ((and i (< (1+ i) (length ids)))
      (org-agenda-kanban--select (nth (1+ i) ids)))
     (t (message "Last card in column")))))

(defun org-agenda-kanban-previous-card ()
  "Select the previous card up in the current column."
  (interactive)
  (let* ((id org-agenda-kanban--selected-id)
         (col (and id (org-agenda-kanban--column-of id)))
         (ids (cdr (assoc col org-agenda-kanban--layout)))
         (i (and ids (cl-position id ids :test #'equal))))
    (cond
     ((null id) (message "No card selected"))
     ((and i (> i 0)) (org-agenda-kanban--select (nth (1- i) ids)))
     (t (message "First card in column")))))

(defun org-agenda-kanban--horizontal (delta)
  "Move the selection DELTA columns left (negative) or right (positive)."
  (let* ((id org-agenda-kanban--selected-id)
         (cols (mapcar #'car org-agenda-kanban--layout))
         (col (and id (org-agenda-kanban--column-of id)))
         (ci (and col (cl-position col cols :test #'equal)))
         (ids (cdr (assoc col org-agenda-kanban--layout)))
         (row (or (and ids (cl-position id ids :test #'equal)) 0)))
    (if (null ci)
        (message "No card selected")
      (let ((target nil)
            (j (+ ci delta)))
        (while (and (>= j 0) (< j (length cols)) (not target))
          (let ((cands (cdr (assoc (nth j cols) org-agenda-kanban--layout))))
            (when cands
              (setq target (nth (min row (1- (length cands))) cands))))
          (setq j (+ j delta)))
        (if target
            (org-agenda-kanban--select target)
          (message "No card that way"))))))

(defun org-agenda-kanban-forward-column ()
  "Select a card in the next non-empty column to the right."
  (interactive)
  (org-agenda-kanban--horizontal 1))

(defun org-agenda-kanban-backward-column ()
  "Select a card in the next non-empty column to the left."
  (interactive)
  (org-agenda-kanban--horizontal -1))

(defun org-agenda-kanban--mouse-click (event)
  "Handle a mouse-1 click on a card or one of its tags.
A click on a tag chip toggles that tag in the include filter; a click
anywhere else on the card selects it."
  (interactive "e")
  (let* ((pos (posn-point (event-start event)))
         (tag (and pos (get-text-property pos 'org-agenda-kanban-tag)))
         (id (and pos (get-text-property pos 'org-agenda-kanban-card-id))))
    (cond
     (tag (org-agenda-kanban-include-tag tag))
     (id (org-agenda-kanban--select id)))))

(defun org-agenda-kanban--mouse-exclude-click (event)
  "Toggle the tag under EVENT in the exclude filter.
Bound to S-mouse-1 on tag chips only (via a chip-local keymap), so a
shift-click elsewhere in the buffer keeps its default behaviour."
  (interactive "e")
  (let* ((pos (posn-point (event-start event)))
         (tag (and pos (get-text-property pos 'org-agenda-kanban-tag))))
    (when tag (org-agenda-kanban-exclude-tag tag))))

;;;; Movement (written to the source buffer)

(defun org-agenda-kanban--heading-matches-p (pos card)
  "Return non-nil if the heading at POS still matches CARD's title."
  (save-excursion
    (goto-char pos)
    (and (org-at-heading-p)
         (let ((el (org-element-at-point)))
           (equal (or (org-element-property :raw-value el) "")
                  (org-agenda-kanban-card-title card))))))

(defun org-agenda-kanban--find-heading (card)
  "Return a buffer position for CARD's heading by rescanning its file.
Matches on the stable card ID, which is derived from the outline path."
  (let ((seen (make-hash-table :test 'equal))
        (target (org-agenda-kanban-card-id card))
        found)
    (org-with-wide-buffer
     (goto-char (point-min))
     (org-map-entries
      (lambda ()
        (unless found
          (when-let ((todo (org-get-todo-state)))
            (let ((probe (org-agenda-kanban--card-at-point todo seen)))
              (when (equal (org-agenda-kanban-card-id probe) target)
                (setq found (point)))))))
      nil 'file))
    found))

(defun org-agenda-kanban--locate (card)
  "Return a cons (BUFFER . POSITION) for CARD's heading, or nil.
The stored marker is used as a fast path but verified against the card
title first; if it no longer matches, the file is rescanned by the
stable card ID."
  (let* ((file (org-agenda-kanban-card-file card))
         (buf (and file (org-agenda-kanban--file-buffer file)))
         (marker (org-agenda-kanban-card-marker card)))
    (when buf
      (with-current-buffer buf
        (org-with-wide-buffer
         (let ((pos (cond
                     ((and marker (marker-position marker)
                           (org-agenda-kanban--heading-matches-p
                            (marker-position marker) card))
                      (marker-position marker))
                     (t (org-agenda-kanban--find-heading card)))))
           (and pos (cons buf pos))))))))

(defun org-agenda-kanban--set-todo (card target)
  "Set CARD's heading to the TODO keyword TARGET in its source file.
The change is written through `org-todo' so logging and notes are
honored.  Like Org Agenda commands, this does not save the source
buffer; save it explicitly when ready."
  (let ((loc (org-agenda-kanban--locate card)))
    (unless loc
      (user-error "Cannot locate heading for %S; refresh the board"
                  (org-agenda-kanban-card-title card)))
    (with-current-buffer (car loc)
      (org-with-wide-buffer
       (goto-char (cdr loc))
       (org-todo target)))))

(defun org-agenda-kanban--move (delta)
  "Move the selected card DELTA columns and edit the source TODO state."
  (let* ((card (org-agenda-kanban--selected-card))
         (cols (org-agenda-kanban--columns)))
    (unless card (user-error "No card selected"))
    (let* ((idx (cl-position (org-agenda-kanban-card-todo card) cols
                             :test #'string=))
           (target (and idx (nth (+ idx delta) cols))))
      (unless target (user-error "No column in that direction"))
      (org-agenda-kanban--set-todo card target)
      ;; Re-collect so the card carries its new keyword and a fresh marker;
      ;; the ID is stable across the state change, so the selection survives.
      (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
      (org-agenda-kanban--apply-filters)
      (message "Moved \"%s\" to %s" (org-agenda-kanban-card-title card) target))))

(defun org-agenda-kanban-move-right ()
  "Move the selected card one column to the right."
  (interactive)
  (org-agenda-kanban--move 1))

(defun org-agenda-kanban-move-left ()
  "Move the selected card one column to the left."
  (interactive)
  (org-agenda-kanban--move -1))

;;;; Editing the selected card in its source file

(defun org-agenda-kanban--edit-at-card (action)
  "Run ACTION on the selected card's heading, then refresh the board.
ACTION is a function of no arguments called with point on the heading
in the (widened) source buffer; it is expected to edit the entry.  The
source buffer is not saved automatically, matching Org Agenda edit
commands.  The board is then re-collected, preserving the selection by
stable ID.  Returns the card that was edited."
  (let ((card (org-agenda-kanban--selected-card)))
    (unless card (user-error "No card selected"))
    (let ((loc (org-agenda-kanban--locate card)))
      (unless loc
        (user-error "Cannot locate heading for %S; refresh the board"
                    (org-agenda-kanban-card-title card)))
      (with-current-buffer (car loc)
        (org-with-wide-buffer
         (goto-char (cdr loc))
         (funcall action))))
    ;; Re-collect so the card carries its new state/priority/tags and a fresh
    ;; marker; the ID is stable across the edit, so the selection survives.
    (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
    (org-agenda-kanban--apply-filters)
    card))

(defun org-agenda-kanban-set-todo ()
  "Set the TODO state of the selected card via the `org-todo' menu.
Mirrors \\[org-todo] in an Org buffer: the change is written back to the
source buffer (logging and notes honored), and the board is refreshed.
Save the source buffer explicitly when ready."
  (interactive)
  (let ((card (org-agenda-kanban--edit-at-card
               (lambda () (call-interactively #'org-todo)))))
    (message "Set state of \"%s\"" (org-agenda-kanban-card-title card))))

(defun org-agenda-kanban-set-priority ()
  "Set the priority of the selected card via `org-priority'.
The change is written back to the source buffer and the board refreshed.
Save the source buffer explicitly when ready."
  (interactive)
  (let ((card (org-agenda-kanban--edit-at-card
               (lambda () (call-interactively #'org-priority)))))
    (message "Set priority of \"%s\"" (org-agenda-kanban-card-title card))))

(defun org-agenda-kanban-set-tags ()
  "Set the tags of the selected card via `org-set-tags-command'.
The change is written back to the source buffer and the board refreshed.
Save the source buffer explicitly when ready."
  (interactive)
  (let ((card (org-agenda-kanban--edit-at-card
               (lambda () (call-interactively #'org-set-tags-command)))))
    (message "Set tags of \"%s\"" (org-agenda-kanban-card-title card))))

;;;; Visiting the source heading

(defun org-agenda-kanban--reveal ()
  "Unfold the Org context around point so the heading is visible."
  (cond ((fboundp 'org-fold-show-context) (org-fold-show-context 'org-goto))
        ((fboundp 'org-show-context) (org-show-context 'org-goto))))

(defun org-agenda-kanban-visit-card (&optional other-window)
  "Visit the selected card's heading in its source Org file.
With a prefix argument, or when OTHER-WINDOW is non-nil, show the
file in another window and keep focus on the board."
  (interactive "P")
  (let* ((card (org-agenda-kanban--selected-card))
         (loc (and card (org-agenda-kanban--locate card))))
    (unless card (user-error "No card selected"))
    (unless loc
      (user-error "Cannot locate heading for %S; refresh the board"
                  (org-agenda-kanban-card-title card)))
    (let ((buf (car loc))
          (pos (cdr loc)))
      (if other-window
          (save-selected-window
            (pop-to-buffer buf)
            (widen)
            (goto-char pos)
            (org-agenda-kanban--reveal)
            (recenter))
        (pop-to-buffer-same-window buf)
        (widen)
        (goto-char pos)
        (org-agenda-kanban--reveal)
        (recenter)))))

(defun org-agenda-kanban--mouse-visit (event)
  "Select the card under EVENT and visit its source heading.
Bound to a double click; the preceding single click has already
selected the card, but this re-selects defensively before visiting."
  (interactive "e")
  (let* ((pos (posn-point (event-start event)))
         (id (and pos (get-text-property pos 'org-agenda-kanban-card-id))))
    (when id (org-agenda-kanban--select id))
    (when (org-agenda-kanban--selected-card)
      (org-agenda-kanban-visit-card))))

;;;; Filtering commands

(defun org-agenda-kanban-include-tag (tag)
  "Toggle TAG in the include filter (cards must carry every included tag).
If TAG is already included it is removed; otherwise it is included,
dropping it from the exclude filter first."
  (interactive
   (list (completing-read "Include tag: " (org-agenda-kanban--all-tags) nil t)))
  (org-agenda-kanban--set-tag-state
   tag (unless (eq (org-agenda-kanban--tag-state tag) 'include) 'include))
  (org-agenda-kanban--apply-filters))

(defalias 'org-agenda-kanban-toggle-tag #'org-agenda-kanban-include-tag
  "Toggle TAG in the include filter.
Kept as an alias of `org-agenda-kanban-include-tag' for compatibility.")

(defun org-agenda-kanban-exclude-tag (tag)
  "Toggle TAG in the exclude filter (cards carrying it are hidden).
If TAG is already excluded it is removed; otherwise it is excluded,
dropping it from the include filter first."
  (interactive
   (list (completing-read "Exclude tag: " (org-agenda-kanban--all-tags) nil t)))
  (org-agenda-kanban--set-tag-state
   tag (unless (eq (org-agenda-kanban--tag-state tag) 'exclude) 'exclude))
  (org-agenda-kanban--apply-filters))

(defun org-agenda-kanban--active-tags ()
  "Return all tags in either the include or exclude filter."
  (append org-agenda-kanban--tag-filter org-agenda-kanban--tag-exclude))

(defun org-agenda-kanban-remove-tag (tag)
  "Remove TAG from whichever tag filter (include or exclude) it is in."
  (interactive
   (list (completing-read "Remove tag: " (org-agenda-kanban--active-tags) nil t)))
  (org-agenda-kanban--set-tag-state tag nil)
  (org-agenda-kanban--apply-filters))

(defun org-agenda-kanban--remove-include-tag (tag)
  "Remove TAG from the include filter only."
  (setq org-agenda-kanban--tag-filter
        (delete tag org-agenda-kanban--tag-filter))
  (org-agenda-kanban--apply-filters))

(defun org-agenda-kanban--remove-exclude-tag (tag)
  "Remove TAG from the exclude filter only."
  (setq org-agenda-kanban--tag-exclude
        (delete tag org-agenda-kanban--tag-exclude))
  (org-agenda-kanban--apply-filters))

(defun org-agenda-kanban-filter-by-priority (priority)
  "Filter the board to cards whose priority is PRIORITY.
Called interactively, prompt for a single priority letter; a blank
answer clears the priority filter."
  (interactive
   (list (let ((s (read-string "Priority (letter, blank to clear): ")))
           (if (string-empty-p s) nil (upcase (aref s 0))))))
  (setq org-agenda-kanban--priority-filter priority)
  (org-agenda-kanban--apply-filters))

(defun org-agenda-kanban-clear-filters ()
  "Clear all active tag (include and exclude) and priority filters."
  (interactive)
  (setq org-agenda-kanban--tag-filter nil
        org-agenda-kanban--tag-exclude nil
        org-agenda-kanban--priority-filter nil)
  (org-agenda-kanban--apply-filters))

(defun org-agenda-kanban-set-done-window (days)
  "Show done cards closed within DAYS days; blank input shows all.
Re-collects the board so the new window takes effect."
  (interactive
   (list (let ((s (read-string
                   "Show done cards closed within N days (blank = all): ")))
           (if (string-empty-p s) nil (max 0 (truncate (string-to-number s)))))))
  (setq org-agenda-kanban--done-window days)
  (org-agenda-kanban-refresh))

;;;; Header line

(defun org-agenda-kanban--chip-keymap (command &rest args)
  "Return a header-line keymap calling COMMAND with ARGS on mouse-1."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
                (lambda () (interactive) (apply command args)))
    map))

(defun org-agenda-kanban--header-line ()
  "Compute the header-line string showing active filter chips."
  (let ((chips '()))
    (dolist (tag (reverse org-agenda-kanban--tag-filter))
      (push (propertize (format " +#%s %s "
                                tag org-agenda-kanban-header-remove-glyph)
                        'face (org-agenda-kanban--chip-face
                               tag 'org-agenda-kanban-filter-chip)
                        'mouse-face 'highlight
                        'keymap (org-agenda-kanban--chip-keymap
                                 #'org-agenda-kanban--remove-include-tag tag)
                        'help-echo "mouse-1: remove this include filter")
            chips))
    (dolist (tag (reverse org-agenda-kanban--tag-exclude))
      (push (propertize (format " -#%s %s "
                                tag org-agenda-kanban-header-remove-glyph)
                        'face (org-agenda-kanban--chip-face
                               tag 'org-agenda-kanban-filter-chip-exclude)
                        'mouse-face 'highlight
                        'keymap (org-agenda-kanban--chip-keymap
                                 #'org-agenda-kanban--remove-exclude-tag tag)
                        'help-echo "mouse-1: remove this exclude filter")
            chips))
    (when org-agenda-kanban--priority-filter
      (push (propertize (format " [#%c] %s "
                                org-agenda-kanban--priority-filter
                                org-agenda-kanban-header-remove-glyph)
                        'face 'org-agenda-kanban-filter-chip
                        'mouse-face 'highlight
                        'keymap (org-agenda-kanban--chip-keymap
                                 #'org-agenda-kanban-filter-by-priority nil)
                        'help-echo "mouse-1: clear the priority filter")
            chips))
    (when org-agenda-kanban--done-window
      (push (propertize (format " done %s%dd %s "
                                org-agenda-kanban-header-done-window-prefix
                                org-agenda-kanban--done-window
                                org-agenda-kanban-header-remove-glyph)
                        'face 'org-agenda-kanban-filter-chip
                        'mouse-face 'highlight
                        'keymap (org-agenda-kanban--chip-keymap
                                 #'org-agenda-kanban-set-done-window nil)
                        'help-echo "mouse-1: show all done cards")
            chips))
    (concat (propertize "Filters: " 'face 'bold)
            (if chips
                (mapconcat #'identity (nreverse chips) " ")
              (propertize "none" 'face 'org-agenda-kanban-empty)))))

;;;; Major mode and entry point

(defvar org-agenda-kanban-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'org-agenda-kanban-next-card)
    (define-key map "p" #'org-agenda-kanban-previous-card)
    (define-key map "f" #'org-agenda-kanban-forward-column)
    (define-key map "b" #'org-agenda-kanban-backward-column)
    (define-key map (kbd "TAB") #'org-agenda-kanban-forward-column)
    (define-key map (kbd "<backtab>") #'org-agenda-kanban-backward-column)
    (define-key map (kbd "M-<right>") #'org-agenda-kanban-move-right)
    (define-key map (kbd "M-<left>") #'org-agenda-kanban-move-left)
    (define-key map ">" #'org-agenda-kanban-move-right)
    (define-key map "<" #'org-agenda-kanban-move-left)
    (define-key map "s" #'org-agenda-kanban-set-todo)
    (define-key map "," #'org-agenda-kanban-set-priority)
    (define-key map ":" #'org-agenda-kanban-set-tags)
    (define-key map [mouse-1] #'org-agenda-kanban--mouse-click)
    (define-key map [double-mouse-1] #'org-agenda-kanban--mouse-visit)
    (define-key map (kbd "RET") #'org-agenda-kanban-visit-card)
    (define-key map "c" #'org-capture)
    (define-key map "o" #'org-agenda-kanban-visit-card)
    (define-key map "tt" #'org-agenda-kanban-toggle-tag)
    (define-key map "t+" #'org-agenda-kanban-include-tag)
    (define-key map "t-" #'org-agenda-kanban-exclude-tag)
    (define-key map "tr" #'org-agenda-kanban-remove-tag)
    (define-key map "tp" #'org-agenda-kanban-filter-by-priority)
    (define-key map "tc" #'org-agenda-kanban-clear-filters)
    (define-key map "td" #'org-agenda-kanban-set-done-window)
    (define-key map "g" #'org-agenda-kanban-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `org-agenda-kanban-mode'.")

(define-derived-mode org-agenda-kanban-mode special-mode "Kanban"
  "Major mode for a modern Org TODO kanban board."
  (setq truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local line-spacing org-agenda-kanban-line-spacing)
  (unless (local-variable-p 'org-agenda-kanban--done-window)
    (setq-local org-agenda-kanban--done-window
                org-agenda-kanban-done-within-days))
  (buffer-face-set 'fixed-pitch)
  (setq header-line-format '(:eval (org-agenda-kanban--header-line))))

(defun org-agenda-kanban-refresh ()
  "Re-collect cards from the source files and redraw the board."
  (interactive)
  (org-agenda-kanban--validate-dimensions)
  (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
  (org-agenda-kanban--apply-filters))

;;;###autoload
(defun org-agenda-kanban ()
  "Open a modern kanban board of Org TODOs."
  (interactive)
  (let ((buffer (get-buffer-create org-agenda-kanban-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-agenda-kanban-mode)
        (org-agenda-kanban-mode))
      (org-agenda-kanban-refresh))
    (pop-to-buffer buffer)))

(provide 'org-agenda-kanban)
;;; org-agenda-kanban.el ends here
