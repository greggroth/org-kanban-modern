;;; org-kanban-modern.el --- A modern kanban board for Org TODOs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Gregg Rothmeier

;; Author: Gregg Rothmeier
;; Maintainer: Gregg Rothmeier
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: outlines, convenience, org
;; URL: https://github.com/greggroth/org-kanban-modern

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

;; org-kanban-modern presents Org-mode TODOs as a kanban board.  Columns are
;; TODO states (configurable, defaulting to `org-todo-keywords'); cards are TODO
;; headings collected from a configurable set of files (defaulting to
;; `org-agenda-files').
;;
;; Cards are selected by clicking and moved between columns with the keyboard;
;; moving a card writes the new TODO keyword back to the source file via
;; `org-todo'.  Tags are shown on cards as clickable chips and can be used to
;; filter the board (elfeed-style, combining with AND).  Cards can also be
;; filtered by priority.
;;
;; Open the board with `M-x org-kanban-modern'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-element)

;;;; Customization

(defgroup org-kanban-modern nil
  "A modern kanban board for Org TODOs."
  :group 'org
  :prefix "org-kanban-modern-")

(defcustom org-kanban-modern-files nil
  "List of Org files to collect cards from.
When nil, the board uses `org-agenda-files'.  The value may be any
form accepted as an element of `org-agenda-files' resolution: file
names or directories."
  :type '(choice (const :tag "Use `org-agenda-files'" nil)
                 (repeat file))
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-columns nil
  "List of TODO keywords to use as board columns, left to right.
When nil, columns are derived from `org-todo-keywords' (all active
and done keywords, in order, with the \"|\" separator removed)."
  :type '(choice (const :tag "Derive from `org-todo-keywords'" nil)
                 (repeat string))
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-sort 'priority
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
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-column-width 26
  "Width, in characters, of each board column."
  :type 'integer
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-column-gap 2
  "Number of blank columns between board columns."
  :type 'integer
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-buffer-name "*Kanban*"
  "Name of the buffer used to display the board."
  :type 'string
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-done-within-days 7
  "Number of days back for which done cards are shown.
A \"done\" card is one whose TODO keyword is among the buffer's done
keywords (those after the \"|\" in `org-todo-keywords').  When this is a
non-negative integer N, a done card appears only if its CLOSED timestamp
is within the last N days; done cards lacking a CLOSED timestamp are
always shown, since their age is unknown.  When nil, all done cards are
shown regardless of age.

This sets the initial value of the per-board window, which can be changed
interactively with `org-kanban-modern-set-done-window'."
  :type '(choice (const :tag "Show all done cards" nil)
                 (integer :tag "Days"))
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-render-markup t
  "When non-nil, render Org inline markup in card titles.
Emphasis (=*bold*=, =/italic/=, =_underline_=, =~code~=, ==verbatim==,
=+strike+=) is shown with the corresponding face and its markers hidden,
and links such as =[[target][description]]= are shown as their
description.  When nil, titles are displayed as raw Org text."
  :type 'boolean
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-show-planning t
  "When non-nil, show a card's SCHEDULED and DEADLINE timestamps.
Each planning timestamp that is set on the heading is rendered on its
own line beneath the title, preserving any repeater (e.g. =+1w=).  The
glyphs are set by `org-kanban-modern-scheduled-glyph' and
`org-kanban-modern-deadline-glyph'."
  :type 'boolean
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-scheduled-glyph "S "
  "Prefix shown before a card's SCHEDULED timestamp.
Defaults to an ASCII label so its width is deterministic: cards are a
fixed-pitch monospace grid, and a non-ASCII glyph that is absent from
your fixed-pitch font is drawn from a fallback font whose advance does
not align to the grid, which misaligns the timestamp and can push it
past the card edge.  You may set a Unicode glyph (e.g. \"◷ \") only if it
is present in your fixed-pitch font with matching metrics."
  :type 'string
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-deadline-glyph "D "
  "Prefix shown before a card's DEADLINE timestamp.
Defaults to an ASCII label so its width is deterministic; see
`org-kanban-modern-scheduled-glyph' for why non-ASCII glyphs can
misalign the monospace card grid.  You may set a Unicode glyph (e.g.
\"⚑ \") only if it is present in your fixed-pitch font."
  :type 'string
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-planning-compact t
  "When non-nil, omit the day-of-week name from planning timestamps.
Planning timestamps (with a date, optional time, and any repeater) are
often wider than a card.  The weekday name is redundant with the date,
so dropping it (e.g. =2026-06-03 11:00 +1w= instead of =2026-06-03 Wed
11:00 +1w=) helps the timestamp fit the card width.  Set to nil to keep
the weekday name."
  :type 'boolean
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-priority-style 'cookie
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
  :group 'org-kanban-modern)

(defcustom org-kanban-modern-line-spacing 0
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
  :group 'org-kanban-modern)

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

(defface org-kanban-modern-column-header
  '((t :inherit (fixed-pitch mode-line-emphasis) :weight bold))
  "Face for column headers.
Inherits `mode-line-emphasis' so it picks up the theme's accent."
  :group 'org-kanban-modern)

(defface org-kanban-modern-card
  '((t :inherit (fixed-pitch hl-line)))
  "Face for an unselected card body.
Inherits `hl-line' for a subtle, theme-aware neutral background."
  :group 'org-kanban-modern)

(defface org-kanban-modern-card-selected
  '((t :inherit (fixed-pitch region)))
  "Face for the currently selected card body.
Inherits `region' so the selection uses the theme's selection color."
  :group 'org-kanban-modern)

(defface org-kanban-modern-selection-bar
  '((t :inherit (fixed-pitch link) :weight bold))
  "Face supplying the accent color of the selected card's bar.
Inherits `link' to borrow the theme's accent foreground.  On graphical
frames the bar is drawn as a solid background fill using this face's
foreground color, so it tiles seamlessly across a card's lines; where no
color is available (e.g. a terminal) the bar falls back to a `▌' glyph
drawn with this face."
  :group 'org-kanban-modern)

(defface org-kanban-modern-title
  '((t :inherit fixed-pitch :weight bold))
  "Face for a card title.
Sets no background so the card background shows through."
  :group 'org-kanban-modern)

(defface org-kanban-modern-priority
  '((t :inherit (fixed-pitch org-priority)))
  "Face for a card priority cookie."
  :group 'org-kanban-modern)

(defface org-kanban-modern-scheduled
  '((t :inherit (fixed-pitch org-scheduled)))
  "Face for a card's SCHEDULED timestamp line."
  :group 'org-kanban-modern)

(defface org-kanban-modern-deadline
  '((t :inherit (fixed-pitch org-upcoming-deadline)))
  "Face for a card's DEADLINE timestamp line."
  :group 'org-kanban-modern)

(defface org-kanban-modern-tag
  '((t :inherit (fixed-pitch org-tag)))
  "Face for a tag chip on a card."
  :group 'org-kanban-modern)

(defface org-kanban-modern-tag-active
  '((t :inherit (fixed-pitch org-tag) :inverse-video t :weight bold))
  "Face for a tag chip that is included in the active filter.
Uses `:inverse-video' so the highlight tracks the theme."
  :group 'org-kanban-modern)

(defface org-kanban-modern-tag-excluded
  '((t :inherit (fixed-pitch org-tag shadow) :strike-through t))
  "Face for a tag chip that is excluded from the active filter.
The strike-through and dimmed `shadow' inheritance signal that cards
carrying this tag are hidden; both track the theme."
  :group 'org-kanban-modern)

(defface org-kanban-modern-tag-hover
  '((t :inherit (org-kanban-modern-tag highlight)))
  "Face shown while the mouse hovers a clickable tag chip.
Layers the theme's `highlight' background beneath the tag styling to
signal that clicking the tag toggles it in the filter."
  :group 'org-kanban-modern)

(defface org-kanban-modern-filter-chip
  '((t :inherit (fixed-pitch mode-line-emphasis) :inverse-video t))
  "Face for an active include-filter chip in the header line."
  :group 'org-kanban-modern)

(defface org-kanban-modern-filter-chip-exclude
  '((t :inherit (fixed-pitch mode-line-emphasis) :inverse-video t
       :strike-through t))
  "Face for an active exclude-filter chip in the header line.
Like `org-kanban-modern-filter-chip' but struck through to mark that the
tag is excluded rather than required."
  :group 'org-kanban-modern)

(defface org-kanban-modern-empty
  '((t :inherit (fixed-pitch shadow) :slant italic))
  "Face for placeholder text on an empty board or column."
  :group 'org-kanban-modern)

;;;; Card model

(cl-defstruct (org-kanban-modern-card
               (:constructor org-kanban-modern-card-create)
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

(defun org-kanban-modern--strip-keyword (kw)
  "Return the bare keyword name of KW from `org-todo-keywords'.
KW may contain fast-access and logging annotations such as
\"WAITING(w@/!)\"; this returns just \"WAITING\"."
  (if (string-match "\\`\\([^(]+\\)" kw)
      (string-trim (match-string 1 kw))
    kw))

(defun org-kanban-modern--default-columns ()
  "Derive the default column list from `org-todo-keywords'."
  (delete-dups
   (cl-loop for seq in org-todo-keywords
            append (cl-loop for kw in (cdr seq)
                            for name = (org-kanban-modern--strip-keyword kw)
                            unless (string= name "|")
                            collect name))))

(defun org-kanban-modern--columns ()
  "Return the effective list of column keywords."
  (or org-kanban-modern-columns
      (org-kanban-modern--default-columns)))

(defun org-kanban-modern--resolve-files ()
  "Return the list of files to scan for cards."
  (let ((org-agenda-files (or org-kanban-modern-files org-agenda-files)))
    (org-agenda-files t)))

(defun org-kanban-modern--file-buffer (file)
  "Return a live buffer visiting FILE, opening it if necessary."
  (or (find-buffer-visiting file)
      (find-file-noselect file)))

(defun org-kanban-modern--effective-tags ()
  "Return the effective tags at point as a list of plain strings."
  (mapcar #'substring-no-properties (org-get-tags)))

(defun org-kanban-modern--card-at-point (todo seen)
  "Build a card for the heading at point with TODO keyword TODO.
SEEN is a hash table used to disambiguate duplicate outline paths."
  (let* ((el (org-element-at-point))
         (title (or (org-element-property :raw-value el) ""))
         (priority (org-element-property :priority el))
         (tags (org-kanban-modern--effective-tags))
         (closed (org-kanban-modern--closed-time))
         (scheduled (org-kanban-modern--planning-raw el :scheduled))
         (deadline (org-kanban-modern--planning-raw el :deadline))
         (path (org-get-outline-path t))
         (base (concat (buffer-file-name) "\0"
                       (mapconcat #'identity path "/")))
         (n (puthash base (1+ (gethash base seen 0)) seen))
         (id (if (> n 1) (format "%s#%d" base n) base)))
    (org-kanban-modern-card-create
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

(defun org-kanban-modern--planning-raw (el prop)
  "Return the raw planning timestamp string of headline EL for PROP.
PROP is `:scheduled' or `:deadline'.  Returns the timestamp's raw
value (preserving any repeater), or nil when unset or malformed."
  (let ((ts (org-element-property prop el)))
    (and (eq (org-element-type ts) 'timestamp)
         (org-element-property :raw-value ts))))

(defvar-local org-kanban-modern--done-window nil
  "Days back within which done cards are shown, or nil to show all.
Initialized from `org-kanban-modern-done-within-days' and adjustable
with `org-kanban-modern-set-done-window'.")

(defun org-kanban-modern--closed-time ()
  "Return the CLOSED time of the entry at point as a Lisp time, or nil."
  (let ((s (org-entry-get (point) "CLOSED")))
    (and s (org-time-string-to-time s))))

(defun org-kanban-modern--show-entry-p (todo window now)
  "Return non-nil if the entry at point passes the done-date filter.
TODO is the entry's keyword; this must run in the entry's Org buffer so
`org-done-keywords' is accurate.  WINDOW is the number of days back to
keep done cards (nil shows all).  NOW is the reference time.  Non-done
entries always pass; a done entry passes when WINDOW is nil, when it has
no CLOSED timestamp, or when its CLOSED time is within WINDOW days."
  (or (null window)
      (not (member todo org-done-keywords))
      (let ((time (org-kanban-modern--closed-time)))
        (or (null time)
            (<= (float-time (time-subtract now time))
                (* window 86400))))))

(defun org-kanban-modern--collect ()
  "Collect cards from the configured files into a flat list.
Only headings whose TODO keyword is one of the configured columns are
included.  Done headings closed more than `org-kanban-modern--done-window'
days ago are skipped."
  (let ((columns (org-kanban-modern--columns))
        (window org-kanban-modern--done-window)
        (now (current-time))
        (seen (make-hash-table :test 'equal))
        (cards '()))
    (dolist (file (org-kanban-modern--resolve-files))
      (when (file-readable-p file)
        (with-current-buffer (org-kanban-modern--file-buffer file)
          (when (derived-mode-p 'org-mode)
            (org-with-wide-buffer
             (goto-char (point-min))
             (org-map-entries
              (lambda ()
                (let ((todo (org-get-todo-state)))
                  (when (and todo (member todo columns)
                             (org-kanban-modern--show-entry-p todo window now))
                    (push (org-kanban-modern--card-at-point todo seen)
                          cards))))
              nil 'file))))))
    (nreverse cards)))

;;;; Buffer-local state

(defvar-local org-kanban-modern--cards nil
  "All cards collected from the source files (unfiltered).")

(defvar-local org-kanban-modern--visible nil
  "Cards passing the active filters, in collection order.")

(defvar-local org-kanban-modern--layout nil
  "Alist of (COLUMN . IDS) describing the last render, top to bottom.")

(defvar-local org-kanban-modern--selected-id nil
  "ID of the currently selected card, or nil.")

(defvar-local org-kanban-modern--tag-filter nil
  "List of tags a card must all carry to be shown (the include filter).")

(defvar-local org-kanban-modern--tag-exclude nil
  "List of tags that hide a card when present (the exclude filter).
A card is shown only if it carries none of these tags.")

(defvar-local org-kanban-modern--priority-filter nil
  "Priority character cards must match, or nil for no priority filter.")

;;;; Filtering

(defun org-kanban-modern--tag-state (tag)
  "Return TAG's current filter state: `include', `exclude', or nil."
  (cond
   ((member tag org-kanban-modern--tag-filter) 'include)
   ((member tag org-kanban-modern--tag-exclude) 'exclude)
   (t nil)))

(defun org-kanban-modern--set-tag-state (tag state)
  "Set TAG's filter STATE, keeping the include and exclude lists disjoint.
STATE is `include', `exclude', or nil.  A tag is in at most one list;
moving it into one list removes it from the other.  This is the only
function that should mutate the tag-filter lists, so the invariant that
no tag is both included and excluded always holds."
  (setq org-kanban-modern--tag-filter
        (delete tag org-kanban-modern--tag-filter)
        org-kanban-modern--tag-exclude
        (delete tag org-kanban-modern--tag-exclude))
  (pcase state
    ('include (push tag org-kanban-modern--tag-filter))
    ('exclude (push tag org-kanban-modern--tag-exclude))))

(defun org-kanban-modern--filtered (cards)
  "Return the members of CARDS passing the active filters."
  (cl-remove-if-not
   (lambda (card)
     (let ((tags (org-kanban-modern-card-tags card)))
       (and (or (null org-kanban-modern--tag-filter)
                (cl-subsetp org-kanban-modern--tag-filter tags
                            :test #'string=))
            (or (null org-kanban-modern--tag-exclude)
                (null (cl-intersection org-kanban-modern--tag-exclude tags
                                       :test #'string=)))
            (or (null org-kanban-modern--priority-filter)
                (eql org-kanban-modern--priority-filter
                     (org-kanban-modern-card-priority card))))))
   cards))

(defun org-kanban-modern--priority-rank (card)
  "Return a sortable rank for CARD's priority; lower sorts first.
Priorities rank by their character code (so =?A= precedes =?B=).
Mirroring `org-agenda', a card with no explicit priority cookie is
treated as having `org-default-priority', so it sorts alongside cards
of that priority rather than last."
  (or (org-kanban-modern-card-priority card) org-default-priority))

(defun org-kanban-modern--sort-cards (cards)
  "Return CARDS ordered per `org-kanban-modern-sort'.
CARDS is not modified.  `sort' is stable, so equal-ranked cards keep
their incoming (document) order."
  (pcase org-kanban-modern-sort
    ('priority
     (sort (copy-sequence cards)
           (lambda (a b)
             (< (org-kanban-modern--priority-rank a)
                (org-kanban-modern--priority-rank b)))))
    ((and (pred functionp) pred)
     (sort (copy-sequence cards) pred))
    (_ cards)))

(defun org-kanban-modern--cards-for-column (column cards)
  "Return the members of CARDS whose TODO keyword is COLUMN.
The result is ordered according to `org-kanban-modern-sort'."
  (org-kanban-modern--sort-cards
   (cl-remove-if-not
    (lambda (card) (string= (org-kanban-modern-card-todo card) column))
    cards)))

(defun org-kanban-modern--all-tags ()
  "Return a sorted list of every tag present on a collected card."
  (let ((tags '()))
    (dolist (card org-kanban-modern--cards)
      (dolist (tag (org-kanban-modern-card-tags card))
        (cl-pushnew tag tags :test #'string=)))
    (sort tags #'string<)))

;;;; Layout helpers (all width math uses display width)

(defun org-kanban-modern--pad (str width)
  "Return STR truncated or space-padded to exactly WIDTH display columns.
Text properties on STR are preserved."
  (let ((w (string-width str)))
    (cond ((= w width) str)
          ((> w width) (truncate-string-to-width str width nil nil t))
          (t (concat str (make-string (- width w) ?\s))))))

(defun org-kanban-modern--wrap (str width)
  "Wrap STR into a list of lines, each at most WIDTH display columns."
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
                (let ((head (truncate-string-to-width rest width)))
                  (push head lines)
                  (setq rest (substring rest (length head)))))
              (setq cur rest))))
         ((<= (string-width (concat cur " " word)) width)
          (setq cur (concat cur " " word)))
         (t (push cur lines)
            (setq cur word))))
      (unless (string= cur "") (push cur lines))
      (nreverse lines))))

;;;; Card rendering

(defconst org-kanban-modern--bar-width 2
  "Columns reserved at the left of each card line for the selection bar.")

(defconst org-kanban-modern--markup-strip-props
  '(keymap nil help-echo nil mouse-face nil htmlize-link nil org-emphasis nil
    font-lock-multiline nil rear-nonsticky nil invisible nil)
  "Property/value plist removed from fontified titles via `remove-text-properties'.
These are Org/font-lock interaction properties that must not leak onto a
kanban card; only display faces are kept.")

(defun org-kanban-modern--fontify-title (title)
  "Return TITLE with Org inline markup rendered, honoring options.
When `org-kanban-modern-render-markup' is nil, return a fresh copy of
TITLE unchanged.  Otherwise fontify it like Org would, drop the now-hidden
emphasis markers so that `string-width' again equals the displayed width
\(keeping wrapping and padding correct), and strip Org's link keymap and
help-echo so cards keep their own click behavior."
  (if (not org-kanban-modern-render-markup)
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
                                    org-kanban-modern--markup-strip-props s)
            s))))))

(defun org-kanban-modern--priority-spec (priority)
  "Return the configured face-or-color for PRIORITY from `org-priority-faces'.
Return nil when PRIORITY is nil or has no configured entry.  Each value
in `org-priority-faces' is, per Org, a face symbol or a color string."
  (and priority (cdr (assq priority org-priority-faces))))

(defun org-kanban-modern--priority-cookie-face (priority)
  "Return the `face' value used to render PRIORITY's [#X] cookie.
Layer the per-priority color from `org-priority-faces' over
`org-kanban-modern-priority' (so the cookie keeps fixed-pitch and the
base styling).  When PRIORITY has no configured entry, fall back to
`org-kanban-modern-priority' alone."
  (let ((spec (org-kanban-modern--priority-spec priority)))
    (cond
     ((null spec) 'org-kanban-modern-priority)
     ;; A literal color string sets only the foreground.
     ((stringp spec)
      (list (list :foreground spec) 'org-kanban-modern-priority))
     ;; A face symbol or attribute plist: apply it first so it wins, with
     ;; our face underneath for fixed-pitch.
     (t (list spec 'org-kanban-modern-priority)))))

(defun org-kanban-modern--format-timestamp (raw)
  "Return RAW Org timestamp string with its delimiter brackets removed.
Removes the active =<>= and inactive =[]= delimiters (including the inner
pair of a =<a>--<b>= range) while keeping the dates, times, and any
repeater or warning period intact."
  (string-trim (replace-regexp-in-string "[][<>]" "" raw)))

(defun org-kanban-modern--strip-weekday (ts)
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

(defun org-kanban-modern--planning-line (glyph raw face content-width)
  "Return a propertized planning line for RAW timestamp.
GLYPH prefixes the formatted timestamp and FACE styles the line.  When
`org-kanban-modern-planning-compact' is non-nil the day-of-week name is
dropped so the timestamp is more likely to fit.  The line is truncated
to CONTENT-WIDTH display columns."
  (let* ((ts (org-kanban-modern--format-timestamp raw))
         (ts (if org-kanban-modern-planning-compact
                 (org-kanban-modern--strip-weekday ts)
               ts))
         (text (concat glyph ts))
         (shown (if (> (string-width text) content-width)
                    (truncate-string-to-width text content-width nil nil t)
                  text)))
    (propertize shown 'face face)))

(defun org-kanban-modern--planning-lines (card content-width)
  "Return CARD's planning lines (0-2) truncated to CONTENT-WIDTH.
Returns the deadline line first (when set) then the scheduled line (when
set), or nil when planning display is disabled or neither is set."
  (when org-kanban-modern-show-planning
    (let ((lines '()))
      (when-let ((d (org-kanban-modern-card-deadline card)))
        (push (org-kanban-modern--planning-line
               org-kanban-modern-deadline-glyph d
               'org-kanban-modern-deadline content-width)
              lines))
      (when-let ((s (org-kanban-modern-card-scheduled card)))
        (push (org-kanban-modern--planning-line
               org-kanban-modern-scheduled-glyph s
               'org-kanban-modern-scheduled content-width)
              lines))
      (nreverse lines))))

(defvar org-kanban-modern--tag-chip-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-3] #'org-kanban-modern--mouse-exclude-click)
    map)
  "Keymap placed on card tag chips so mouse-3 toggles the exclude filter.
Mouse-1 is intentionally left to the mode map's selection handler.")

(defun org-kanban-modern--tags-string (card content-width)
  "Return a propertized, clickable tag string for CARD.
The result is truncated to CONTENT-WIDTH display columns."
  (let ((chips '()))
    (dolist (tag (org-kanban-modern-card-tags card))
      (let ((face (pcase (org-kanban-modern--tag-state tag)
                    ('include 'org-kanban-modern-tag-active)
                    ('exclude 'org-kanban-modern-tag-excluded)
                    (_ 'org-kanban-modern-tag))))
        (push (propertize (concat "#" tag)
                          'face face
                          'org-kanban-modern-tag tag
                          'mouse-face 'org-kanban-modern-tag-hover
                          'keymap org-kanban-modern--tag-chip-keymap
                          'help-echo "mouse-1: include this tag, mouse-3: exclude it")
              chips)))
    (let ((s (mapconcat #'identity (nreverse chips) " ")))
      (if (> (string-width s) content-width)
          (truncate-string-to-width s content-width nil nil t)
        s))))

(defun org-kanban-modern--finish-line (content width base bar-face bar-char id)
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
  (let* ((content-width (- width org-kanban-modern--bar-width))
         (padded (org-kanban-modern--pad content content-width))
         (line (concat (propertize bar-char 'face bar-face)
                       (propertize " " 'face base)
                       padded)))
    ;; Lay BASE underneath as the lowest-priority face so blank padding gets
    ;; the card background while title/tag faces keep precedence.
    (add-face-text-property 0 (length line) base t line)
    (add-text-properties 0 (length line)
                         (list 'org-kanban-modern-card-id id
                               'help-echo "mouse-1: select  M-<left>/<right>: move")
                         line)
    line))

(defun org-kanban-modern--card-lines (card width selectedp)
  "Return a list of WIDTH-wide propertized lines rendering CARD."
  (let* ((content-width (- width org-kanban-modern--bar-width))
         (prio (org-kanban-modern-card-priority card))
         (base (cond (selectedp 'org-kanban-modern-card-selected)
                     (t 'org-kanban-modern-card)))
         ;; Draw the selection accent as a solid background fill rather than a
         ;; foreground glyph: a half-block character only paints as tall as its
         ;; glyph, so it looks segmented between a card's lines, whereas a
         ;; background fill tiles seamlessly across them.
         (bar-color (and selectedp
                         (or (face-foreground 'org-kanban-modern-selection-bar nil t)
                             (face-foreground 'link nil t))))
         (bar-face (cond ((not selectedp) base)
                         (bar-color (list (list :background bar-color) base))
                         (t (list 'org-kanban-modern-selection-bar base))))
         (bar-char (if (and selectedp (not bar-color)) "▌" " "))
         (id (org-kanban-modern-card-id card))
         (rendered (org-kanban-modern--fontify-title
                    (org-kanban-modern-card-title card)))
         (title (concat (when prio (propertize (format "[#%c] " prio)
                                               ;; Any non-nil style colors the
                                               ;; cookie, so a legacy
                                               ;; `background'/`both' value
                                               ;; migrates to cookie coloring
                                               ;; rather than no color at all.
                                               'face (if org-kanban-modern-priority-style
                                                        (org-kanban-modern--priority-cookie-face prio)
                                                       'org-kanban-modern-priority)))
                        (progn
                          ;; Lay the title face underneath as the base so any
                          ;; emphasis/link faces from the markup take precedence.
                          (add-face-text-property 0 (length rendered)
                                                  'org-kanban-modern-title t rendered)
                          rendered)))
         (title-lines (org-kanban-modern--wrap title content-width))
         (lines '()))
    ;; Cap card height: at most three title lines, with an ellipsis if clipped.
    (when (> (length title-lines) 3)
      (setq title-lines (append (seq-take title-lines 2)
                                (list (org-kanban-modern--pad
                                       (concat (nth 2 title-lines) "…")
                                       content-width)))))
    (dolist (tl title-lines)
      (push (org-kanban-modern--finish-line tl width base bar-face bar-char id)
            lines))
    (dolist (pl (org-kanban-modern--planning-lines card content-width))
      (push (org-kanban-modern--finish-line pl width base bar-face bar-char id)
            lines))
    (when (org-kanban-modern-card-tags card)
      (push (org-kanban-modern--finish-line
             (org-kanban-modern--tags-string card content-width)
             width base bar-face bar-char id)
            lines))
    (nreverse lines)))

(defun org-kanban-modern--column-block (cards width)
  "Return a flat list of WIDTH-wide lines stacking CARDS for one column.
A blank separator line is inserted after each card."
  (let ((blank (make-string width ?\s))
        (out '()))
    (if (null cards)
        (list (org-kanban-modern--pad
               (propertize "  (empty)" 'face 'org-kanban-modern-empty)
               width))
      (dolist (card cards)
        (setq out (append out
                          (org-kanban-modern--card-lines
                           card width
                           (equal (org-kanban-modern-card-id card)
                                  org-kanban-modern--selected-id))
                          (list blank))))
      out)))

;;;; Board rendering

(defun org-kanban-modern--render ()
  "Redraw the board from `org-kanban-modern--visible'."
  (let* ((inhibit-read-only t)
         (columns (org-kanban-modern--columns))
         (width org-kanban-modern-column-width)
         (gap (make-string org-kanban-modern-column-gap ?\s))
         (by-column (mapcar (lambda (col)
                              (cons col (org-kanban-modern--cards-for-column
                                         col org-kanban-modern--visible)))
                            columns)))
    (setq org-kanban-modern--layout
          (mapcar (lambda (cell)
                    (cons (car cell)
                          (mapcar #'org-kanban-modern-card-id (cdr cell))))
                  by-column))
    (erase-buffer)
    (cond
     ((null columns)
      (insert (propertize "No columns configured.\n"
                          'face 'org-kanban-modern-empty)))
     ((null org-kanban-modern--cards)
      (insert (propertize "No TODO cards found in the configured files.\n"
                          'face 'org-kanban-modern-empty)))
     ((null org-kanban-modern--visible)
      (insert (propertize "No cards match the active filters.\n"
                          'face 'org-kanban-modern-empty)))
     (t
      ;; Column headers.
      (insert (mapconcat
               (lambda (cell)
                 (org-kanban-modern--pad
                  (propertize (format " %s (%d)" (car cell) (length (cdr cell)))
                              'face 'org-kanban-modern-column-header)
                  width))
               by-column gap))
      (insert "\n\n")
      ;; Zip the per-column blocks row by row.
      (let* ((blocks (mapcar (lambda (cell)
                               (org-kanban-modern--column-block (cdr cell) width))
                             by-column))
             (height (apply #'max 0 (mapcar #'length blocks)))
             (blank (make-string width ?\s)))
        (dotimes (row height)
          (insert (mapconcat (lambda (block) (or (nth row block) blank))
                             blocks gap))
          (insert "\n")))))
    (set-buffer-modified-p nil)
    (org-kanban-modern--goto-selected)))

(defun org-kanban-modern--goto-selected ()
  "Move point to the start of the selected card, if it is visible."
  (when org-kanban-modern--selected-id
    (let ((pos (point-min)) found)
      (while (and (not found)
                  (setq pos (next-single-property-change
                             pos 'org-kanban-modern-card-id)))
        (when (equal (get-text-property pos 'org-kanban-modern-card-id)
                     org-kanban-modern--selected-id)
          (setq found pos)))
      (when found (goto-char found)))))

;;;; Selection bookkeeping

(defun org-kanban-modern--visible-ids ()
  "Return the IDs of all visible cards in collection order."
  (mapcar #'org-kanban-modern-card-id org-kanban-modern--visible))

(defun org-kanban-modern--ensure-selection ()
  "Fix `org-kanban-modern--selected-id' so it points at a visible card.
If the current selection is still visible it is kept; otherwise the
first visible card is selected, or nil when nothing is visible."
  (let ((ids (org-kanban-modern--visible-ids)))
    (unless (and org-kanban-modern--selected-id
                 (member org-kanban-modern--selected-id ids))
      (setq org-kanban-modern--selected-id (car ids)))))

(defun org-kanban-modern--apply-filters ()
  "Recompute visible cards, fix the selection, and redraw."
  (setq org-kanban-modern--visible
        (org-kanban-modern--filtered org-kanban-modern--cards))
  (org-kanban-modern--ensure-selection)
  (org-kanban-modern--render))

(defun org-kanban-modern--selected-card ()
  "Return the currently selected card object, or nil."
  (and org-kanban-modern--selected-id
       (cl-find org-kanban-modern--selected-id org-kanban-modern--cards
                :key #'org-kanban-modern-card-id :test #'equal)))

(defun org-kanban-modern--column-of (id)
  "Return the column keyword whose visible list contains ID, or nil."
  (cl-loop for (col . ids) in org-kanban-modern--layout
           when (member id ids) return col))

;;;; Navigation commands

(defun org-kanban-modern--select (id)
  "Set the selection to ID and redraw."
  (setq org-kanban-modern--selected-id id)
  (org-kanban-modern--render))

(defun org-kanban-modern-next-card ()
  "Select the next card down in the current column."
  (interactive)
  (let* ((id org-kanban-modern--selected-id)
         (col (and id (org-kanban-modern--column-of id)))
         (ids (cdr (assoc col org-kanban-modern--layout)))
         (i (and ids (cl-position id ids :test #'equal))))
    (cond
     ((null id) (message "No card selected"))
     ((and i (< (1+ i) (length ids)))
      (org-kanban-modern--select (nth (1+ i) ids)))
     (t (message "Last card in column")))))

(defun org-kanban-modern-previous-card ()
  "Select the previous card up in the current column."
  (interactive)
  (let* ((id org-kanban-modern--selected-id)
         (col (and id (org-kanban-modern--column-of id)))
         (ids (cdr (assoc col org-kanban-modern--layout)))
         (i (and ids (cl-position id ids :test #'equal))))
    (cond
     ((null id) (message "No card selected"))
     ((and i (> i 0)) (org-kanban-modern--select (nth (1- i) ids)))
     (t (message "First card in column")))))

(defun org-kanban-modern--horizontal (delta)
  "Move the selection DELTA columns left (negative) or right (positive)."
  (let* ((id org-kanban-modern--selected-id)
         (cols (mapcar #'car org-kanban-modern--layout))
         (col (and id (org-kanban-modern--column-of id)))
         (ci (and col (cl-position col cols :test #'equal)))
         (ids (cdr (assoc col org-kanban-modern--layout)))
         (row (or (and ids (cl-position id ids :test #'equal)) 0)))
    (if (null ci)
        (message "No card selected")
      (let ((target nil)
            (j (+ ci delta)))
        (while (and (>= j 0) (< j (length cols)) (not target))
          (let ((cands (cdr (assoc (nth j cols) org-kanban-modern--layout))))
            (when cands
              (setq target (nth (min row (1- (length cands))) cands))))
          (setq j (+ j delta)))
        (if target
            (org-kanban-modern--select target)
          (message "No card that way"))))))

(defun org-kanban-modern-forward-column ()
  "Select a card in the next non-empty column to the right."
  (interactive)
  (org-kanban-modern--horizontal 1))

(defun org-kanban-modern-backward-column ()
  "Select a card in the next non-empty column to the left."
  (interactive)
  (org-kanban-modern--horizontal -1))

(defun org-kanban-modern--mouse-click (event)
  "Handle a mouse-1 click on a card or one of its tags.
A click on a tag chip toggles that tag in the include filter; a click
anywhere else on the card selects it."
  (interactive "e")
  (let* ((pos (posn-point (event-start event)))
         (tag (and pos (get-text-property pos 'org-kanban-modern-tag)))
         (id (and pos (get-text-property pos 'org-kanban-modern-card-id))))
    (cond
     (tag (org-kanban-modern-include-tag tag))
     (id (org-kanban-modern--select id)))))

(defun org-kanban-modern--mouse-exclude-click (event)
  "Toggle the tag under EVENT in the exclude filter.
Bound to mouse-3 on tag chips only (via a chip-local keymap), so a
right-click elsewhere in the buffer keeps its default behaviour."
  (interactive "e")
  (let* ((pos (posn-point (event-start event)))
         (tag (and pos (get-text-property pos 'org-kanban-modern-tag))))
    (when tag (org-kanban-modern-exclude-tag tag))))

;;;; Movement (persisted to the source file)

(defun org-kanban-modern--heading-matches-p (pos card)
  "Return non-nil if the heading at POS still matches CARD's title."
  (save-excursion
    (goto-char pos)
    (and (org-at-heading-p)
         (let ((el (org-element-at-point)))
           (equal (or (org-element-property :raw-value el) "")
                  (org-kanban-modern-card-title card))))))

(defun org-kanban-modern--find-heading (card)
  "Return a buffer position for CARD's heading by rescanning its file.
Matches on the stable card ID, which is derived from the outline path."
  (let ((seen (make-hash-table :test 'equal))
        (target (org-kanban-modern-card-id card))
        found)
    (org-with-wide-buffer
     (goto-char (point-min))
     (org-map-entries
      (lambda ()
        (unless found
          (when-let ((todo (org-get-todo-state)))
            (let ((probe (org-kanban-modern--card-at-point todo seen)))
              (when (equal (org-kanban-modern-card-id probe) target)
                (setq found (point)))))))
      nil 'file))
    found))

(defun org-kanban-modern--locate (card)
  "Return a cons (BUFFER . POSITION) for CARD's heading, or nil.
The stored marker is used as a fast path but verified against the card
title first; if it no longer matches, the file is rescanned by the
stable card ID."
  (let* ((file (org-kanban-modern-card-file card))
         (buf (and file (org-kanban-modern--file-buffer file)))
         (marker (org-kanban-modern-card-marker card)))
    (when buf
      (with-current-buffer buf
        (org-with-wide-buffer
         (let ((pos (cond
                     ((and marker (marker-position marker)
                           (org-kanban-modern--heading-matches-p
                            (marker-position marker) card))
                      (marker-position marker))
                     (t (org-kanban-modern--find-heading card)))))
           (and pos (cons buf pos))))))))

(defun org-kanban-modern--set-todo (card target)
  "Set CARD's heading to the TODO keyword TARGET in its source file.
The change is written through `org-todo' so logging and notes are
honored, then the buffer is saved."
  (let ((loc (org-kanban-modern--locate card)))
    (unless loc
      (user-error "Cannot locate heading for %S; refresh the board"
                  (org-kanban-modern-card-title card)))
    (with-current-buffer (car loc)
      (org-with-wide-buffer
       (goto-char (cdr loc))
       (org-todo target))
      (save-buffer))))

(defun org-kanban-modern--move (delta)
  "Move the selected card DELTA columns and persist the new TODO state."
  (let* ((card (org-kanban-modern--selected-card))
         (cols (org-kanban-modern--columns)))
    (unless card (user-error "No card selected"))
    (let* ((idx (cl-position (org-kanban-modern-card-todo card) cols
                             :test #'string=))
           (target (and idx (nth (+ idx delta) cols))))
      (unless target (user-error "No column in that direction"))
      (org-kanban-modern--set-todo card target)
      ;; Re-collect so the card carries its new keyword and a fresh marker;
      ;; the ID is stable across the state change, so the selection survives.
      (setq org-kanban-modern--cards (org-kanban-modern--collect))
      (org-kanban-modern--apply-filters)
      (message "Moved \"%s\" to %s" (org-kanban-modern-card-title card) target))))

(defun org-kanban-modern-move-right ()
  "Move the selected card one column to the right."
  (interactive)
  (org-kanban-modern--move 1))

(defun org-kanban-modern-move-left ()
  "Move the selected card one column to the left."
  (interactive)
  (org-kanban-modern--move -1))

;;;; Editing the selected card in its source file

(defun org-kanban-modern--edit-at-card (action)
  "Run ACTION on the selected card's heading, then refresh the board.
ACTION is a function of no arguments called with point on the heading
in the (widened) source buffer; it is expected to edit the entry.  The
source buffer is then saved and the board re-collected, preserving the
selection by stable ID.  Returns the card that was edited."
  (let ((card (org-kanban-modern--selected-card)))
    (unless card (user-error "No card selected"))
    (let ((loc (org-kanban-modern--locate card)))
      (unless loc
        (user-error "Cannot locate heading for %S; refresh the board"
                    (org-kanban-modern-card-title card)))
      (with-current-buffer (car loc)
        (org-with-wide-buffer
         (goto-char (cdr loc))
         (funcall action))
        (save-buffer)))
    ;; Re-collect so the card carries its new state/priority/tags and a fresh
    ;; marker; the ID is stable across the edit, so the selection survives.
    (setq org-kanban-modern--cards (org-kanban-modern--collect))
    (org-kanban-modern--apply-filters)
    card))

(defun org-kanban-modern-set-todo ()
  "Set the TODO state of the selected card via the `org-todo' menu.
Mirrors \\[org-todo] in an Org buffer: the change is written back to the
source file (logging and notes honored) and the board is refreshed."
  (interactive)
  (let ((card (org-kanban-modern--edit-at-card
               (lambda () (call-interactively #'org-todo)))))
    (message "Set state of \"%s\"" (org-kanban-modern-card-title card))))

(defun org-kanban-modern-set-priority ()
  "Set the priority of the selected card via `org-priority'.
The change is written back to the source file and the board refreshed."
  (interactive)
  (let ((card (org-kanban-modern--edit-at-card
               (lambda () (call-interactively #'org-priority)))))
    (message "Set priority of \"%s\"" (org-kanban-modern-card-title card))))

(defun org-kanban-modern-set-tags ()
  "Set the tags of the selected card via `org-set-tags-command'.
The change is written back to the source file and the board refreshed."
  (interactive)
  (let ((card (org-kanban-modern--edit-at-card
               (lambda () (call-interactively #'org-set-tags-command)))))
    (message "Set tags of \"%s\"" (org-kanban-modern-card-title card))))

;;;; Visiting the source heading

(defun org-kanban-modern--reveal ()
  "Unfold the Org context around point so the heading is visible."
  (cond ((fboundp 'org-fold-show-context) (org-fold-show-context 'org-goto))
        ((fboundp 'org-show-context) (org-show-context 'org-goto))))

(defun org-kanban-modern-visit-card (&optional other-window)
  "Visit the selected card's heading in its source Org file.
With a prefix argument, or when OTHER-WINDOW is non-nil, show the
file in another window and keep focus on the board."
  (interactive "P")
  (let* ((card (org-kanban-modern--selected-card))
         (loc (and card (org-kanban-modern--locate card))))
    (unless card (user-error "No card selected"))
    (unless loc
      (user-error "Cannot locate heading for %S; refresh the board"
                  (org-kanban-modern-card-title card)))
    (let ((buf (car loc))
          (pos (cdr loc)))
      (if other-window
          (save-selected-window
            (pop-to-buffer buf)
            (widen)
            (goto-char pos)
            (org-kanban-modern--reveal)
            (recenter))
        (pop-to-buffer-same-window buf)
        (widen)
        (goto-char pos)
        (org-kanban-modern--reveal)
        (recenter)))))

(defun org-kanban-modern--mouse-visit (event)
  "Select the card under EVENT and visit its source heading.
Bound to a double click; the preceding single click has already
selected the card, but this re-selects defensively before visiting."
  (interactive "e")
  (let* ((pos (posn-point (event-start event)))
         (id (and pos (get-text-property pos 'org-kanban-modern-card-id))))
    (when id (org-kanban-modern--select id))
    (when (org-kanban-modern--selected-card)
      (org-kanban-modern-visit-card))))

;;;; Filtering commands

(defun org-kanban-modern-include-tag (tag)
  "Toggle TAG in the include filter (cards must carry every included tag).
If TAG is already included it is removed; otherwise it is included,
dropping it from the exclude filter first."
  (interactive
   (list (completing-read "Include tag: " (org-kanban-modern--all-tags) nil t)))
  (org-kanban-modern--set-tag-state
   tag (unless (eq (org-kanban-modern--tag-state tag) 'include) 'include))
  (org-kanban-modern--apply-filters))

(defalias 'org-kanban-modern-toggle-tag #'org-kanban-modern-include-tag
  "Toggle TAG in the include filter.
Kept as an alias of `org-kanban-modern-include-tag' for compatibility.")

(defun org-kanban-modern-exclude-tag (tag)
  "Toggle TAG in the exclude filter (cards carrying it are hidden).
If TAG is already excluded it is removed; otherwise it is excluded,
dropping it from the include filter first."
  (interactive
   (list (completing-read "Exclude tag: " (org-kanban-modern--all-tags) nil t)))
  (org-kanban-modern--set-tag-state
   tag (unless (eq (org-kanban-modern--tag-state tag) 'exclude) 'exclude))
  (org-kanban-modern--apply-filters))

(defun org-kanban-modern--active-tags ()
  "Return all tags in either the include or exclude filter."
  (append org-kanban-modern--tag-filter org-kanban-modern--tag-exclude))

(defun org-kanban-modern-remove-tag (tag)
  "Remove TAG from whichever tag filter (include or exclude) it is in."
  (interactive
   (list (completing-read "Remove tag: " (org-kanban-modern--active-tags) nil t)))
  (org-kanban-modern--set-tag-state tag nil)
  (org-kanban-modern--apply-filters))

(defun org-kanban-modern--remove-include-tag (tag)
  "Remove TAG from the include filter only."
  (setq org-kanban-modern--tag-filter
        (delete tag org-kanban-modern--tag-filter))
  (org-kanban-modern--apply-filters))

(defun org-kanban-modern--remove-exclude-tag (tag)
  "Remove TAG from the exclude filter only."
  (setq org-kanban-modern--tag-exclude
        (delete tag org-kanban-modern--tag-exclude))
  (org-kanban-modern--apply-filters))

(defun org-kanban-modern-filter-by-priority (priority)
  "Filter the board to cards whose priority is PRIORITY.
Called interactively, prompt for a single priority letter; a blank
answer clears the priority filter."
  (interactive
   (list (let ((s (read-string "Priority (letter, blank to clear): ")))
           (if (string-empty-p s) nil (upcase (aref s 0))))))
  (setq org-kanban-modern--priority-filter priority)
  (org-kanban-modern--apply-filters))

(defun org-kanban-modern-clear-filters ()
  "Clear all active tag (include and exclude) and priority filters."
  (interactive)
  (setq org-kanban-modern--tag-filter nil
        org-kanban-modern--tag-exclude nil
        org-kanban-modern--priority-filter nil)
  (org-kanban-modern--apply-filters))

(defun org-kanban-modern-set-done-window (days)
  "Show done cards closed within DAYS days; blank input shows all.
Re-collects the board so the new window takes effect."
  (interactive
   (list (let ((s (read-string
                   "Show done cards closed within N days (blank = all): ")))
           (if (string-empty-p s) nil (max 0 (truncate (string-to-number s)))))))
  (setq org-kanban-modern--done-window days)
  (org-kanban-modern-refresh))

;;;; Header line

(defun org-kanban-modern--chip-keymap (command &rest args)
  "Return a header-line keymap calling COMMAND with ARGS on mouse-1."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
                (lambda () (interactive) (apply command args)))
    map))

(defun org-kanban-modern--header-line ()
  "Compute the header-line string showing active filter chips."
  (let ((chips '()))
    (dolist (tag (reverse org-kanban-modern--tag-filter))
      (push (propertize (format " +#%s ✕ " tag)
                        'face 'org-kanban-modern-filter-chip
                        'mouse-face 'highlight
                        'keymap (org-kanban-modern--chip-keymap
                                 #'org-kanban-modern--remove-include-tag tag)
                        'help-echo "mouse-1: remove this include filter")
            chips))
    (dolist (tag (reverse org-kanban-modern--tag-exclude))
      (push (propertize (format " -#%s ✕ " tag)
                        'face 'org-kanban-modern-filter-chip-exclude
                        'mouse-face 'highlight
                        'keymap (org-kanban-modern--chip-keymap
                                 #'org-kanban-modern--remove-exclude-tag tag)
                        'help-echo "mouse-1: remove this exclude filter")
            chips))
    (when org-kanban-modern--priority-filter
      (push (propertize (format " [#%c] ✕ " org-kanban-modern--priority-filter)
                        'face 'org-kanban-modern-filter-chip
                        'mouse-face 'highlight
                        'keymap (org-kanban-modern--chip-keymap
                                 #'org-kanban-modern-filter-by-priority nil)
                        'help-echo "mouse-1: clear the priority filter")
            chips))
    (when org-kanban-modern--done-window
      (push (propertize (format " done ≤%dd ✕ " org-kanban-modern--done-window)
                        'face 'org-kanban-modern-filter-chip
                        'mouse-face 'highlight
                        'keymap (org-kanban-modern--chip-keymap
                                 #'org-kanban-modern-set-done-window nil)
                        'help-echo "mouse-1: show all done cards")
            chips))
    (concat (propertize "Filters: " 'face 'bold)
            (if chips
                (mapconcat #'identity (nreverse chips) " ")
              (propertize "none" 'face 'org-kanban-modern-empty)))))

;;;; Major mode and entry point

(defvar org-kanban-modern-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'org-kanban-modern-next-card)
    (define-key map "p" #'org-kanban-modern-previous-card)
    (define-key map "f" #'org-kanban-modern-forward-column)
    (define-key map "b" #'org-kanban-modern-backward-column)
    (define-key map (kbd "TAB") #'org-kanban-modern-forward-column)
    (define-key map (kbd "<backtab>") #'org-kanban-modern-backward-column)
    (define-key map (kbd "M-<right>") #'org-kanban-modern-move-right)
    (define-key map (kbd "M-<left>") #'org-kanban-modern-move-left)
    (define-key map ">" #'org-kanban-modern-move-right)
    (define-key map "<" #'org-kanban-modern-move-left)
    (define-key map "s" #'org-kanban-modern-set-todo)
    (define-key map (kbd "C-c C-t") #'org-kanban-modern-set-todo)
    (define-key map "," #'org-kanban-modern-set-priority)
    (define-key map (kbd "C-c ,") #'org-kanban-modern-set-priority)
    (define-key map ":" #'org-kanban-modern-set-tags)
    (define-key map (kbd "C-c C-q") #'org-kanban-modern-set-tags)
    (define-key map [mouse-1] #'org-kanban-modern--mouse-click)
    (define-key map [double-mouse-1] #'org-kanban-modern--mouse-visit)
    (define-key map (kbd "RET") #'org-kanban-modern-visit-card)
    (define-key map "o" #'org-kanban-modern-visit-card)
    (define-key map "tt" #'org-kanban-modern-toggle-tag)
    (define-key map "t+" #'org-kanban-modern-include-tag)
    (define-key map "t-" #'org-kanban-modern-exclude-tag)
    (define-key map "tr" #'org-kanban-modern-remove-tag)
    (define-key map "tp" #'org-kanban-modern-filter-by-priority)
    (define-key map "tc" #'org-kanban-modern-clear-filters)
    (define-key map "td" #'org-kanban-modern-set-done-window)
    (define-key map "g" #'org-kanban-modern-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `org-kanban-modern-mode'.")

(define-derived-mode org-kanban-modern-mode special-mode "Kanban"
  "Major mode for a modern Org TODO kanban board."
  (setq truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local line-spacing org-kanban-modern-line-spacing)
  (unless (local-variable-p 'org-kanban-modern--done-window)
    (setq-local org-kanban-modern--done-window
                org-kanban-modern-done-within-days))
  (buffer-face-set 'fixed-pitch)
  (setq header-line-format '(:eval (org-kanban-modern--header-line))))

(defun org-kanban-modern-refresh ()
  "Re-collect cards from the source files and redraw the board."
  (interactive)
  (setq org-kanban-modern--cards (org-kanban-modern--collect))
  (org-kanban-modern--apply-filters))

;;;###autoload
(defun org-kanban-modern ()
  "Open a modern kanban board of Org TODOs."
  (interactive)
  (let ((buffer (get-buffer-create org-kanban-modern-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-kanban-modern-mode)
        (org-kanban-modern-mode))
      (org-kanban-modern-refresh))
    (pop-to-buffer buffer)))

(provide 'org-kanban-modern)
;;; org-kanban-modern.el ends here
