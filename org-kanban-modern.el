;;; org-kanban-modern.el --- A modern kanban board for Org TODOs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Greg Roth

;; Author: Greg Roth
;; Maintainer: Greg Roth
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
  "Face for the accent bar marking the selected card.
Inherits `link' to borrow the theme's accent foreground."
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

(defface org-kanban-modern-tag
  '((t :inherit (fixed-pitch org-tag)))
  "Face for a tag chip on a card."
  :group 'org-kanban-modern)

(defface org-kanban-modern-tag-active
  '((t :inherit (fixed-pitch org-tag) :inverse-video t :weight bold))
  "Face for a tag chip that is part of the active filter.
Uses `:inverse-video' so the highlight tracks the theme."
  :group 'org-kanban-modern)

(defface org-kanban-modern-filter-chip
  '((t :inherit (fixed-pitch mode-line-emphasis) :inverse-video t))
  "Face for an active-filter chip in the header line."
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
verified against TITLE before any destructive edit."
  id file marker title todo tags priority)

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
     :priority priority)))

(defun org-kanban-modern--collect ()
  "Collect cards from the configured files into a flat list.
Only headings whose TODO keyword is one of the configured columns
are included."
  (let ((columns (org-kanban-modern--columns))
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
                  (when (and todo (member todo columns))
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
  "List of tags that cards must all carry to be shown (AND filter).")

(defvar-local org-kanban-modern--priority-filter nil
  "Priority character cards must match, or nil for no priority filter.")

;;;; Filtering

(defun org-kanban-modern--filtered (cards)
  "Return the members of CARDS passing the active filters."
  (cl-remove-if-not
   (lambda (card)
     (and (or (null org-kanban-modern--tag-filter)
              (cl-subsetp org-kanban-modern--tag-filter
                          (org-kanban-modern-card-tags card)
                          :test #'string=))
          (or (null org-kanban-modern--priority-filter)
              (eql org-kanban-modern--priority-filter
                   (org-kanban-modern-card-priority card)))))
   cards))

(defun org-kanban-modern--cards-for-column (column cards)
  "Return the members of CARDS whose TODO keyword is COLUMN."
  (cl-remove-if-not
   (lambda (card) (string= (org-kanban-modern-card-todo card) column))
   cards))

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

(defun org-kanban-modern--tags-string (card content-width)
  "Return a propertized, clickable tag string for CARD.
The result is truncated to CONTENT-WIDTH display columns."
  (let ((chips '()))
    (dolist (tag (org-kanban-modern-card-tags card))
      (let* ((activep (member tag org-kanban-modern--tag-filter))
             (face (if activep
                       'org-kanban-modern-tag-active
                     'org-kanban-modern-tag)))
        (push (propertize (concat "#" tag)
                          'face face
                          'org-kanban-modern-tag tag
                          'mouse-face 'highlight
                          'help-echo "mouse-1: toggle this tag in the filter")
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
card; it never clobbers the per-tag `keymap'-free properties already on
CONTENT."
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
                               'mouse-face (unless (eq base 'org-kanban-modern-card-selected)
                                             'highlight)
                               'help-echo "mouse-1: select  M-<left>/<right>: move")
                         line)
    line))

(defun org-kanban-modern--card-lines (card width selectedp)
  "Return a list of WIDTH-wide propertized lines rendering CARD."
  (let* ((content-width (- width org-kanban-modern--bar-width))
         (base (if selectedp
                   'org-kanban-modern-card-selected
                 'org-kanban-modern-card))
         (bar-face (if selectedp 'org-kanban-modern-selection-bar base))
         (bar-char (if selectedp "▌" " "))
         (id (org-kanban-modern-card-id card))
         (prio (org-kanban-modern-card-priority card))
         (title (concat (when prio (propertize (format "[#%c] " prio)
                                               'face 'org-kanban-modern-priority))
                        (propertize (org-kanban-modern-card-title card)
                                    'face 'org-kanban-modern-title)))
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
A click on a tag chip toggles that tag in the filter; a click anywhere
else on the card selects it."
  (interactive "e")
  (let* ((pos (posn-point (event-start event)))
         (tag (and pos (get-text-property pos 'org-kanban-modern-tag)))
         (id (and pos (get-text-property pos 'org-kanban-modern-card-id))))
    (cond
     (tag (org-kanban-modern-toggle-tag tag))
     (id (org-kanban-modern--select id)))))

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

(defun org-kanban-modern--set-todo (card target)
  "Set CARD's heading to the TODO keyword TARGET in its source file.
The stored marker is used as a fast path but verified against the card
title first; if it no longer matches, the file is rescanned by card ID.
The change is written through `org-todo' so logging and notes are
honored, then the buffer is saved."
  (let* ((file (org-kanban-modern-card-file card))
         (buf (org-kanban-modern--file-buffer file))
         (marker (org-kanban-modern-card-marker card)))
    (with-current-buffer buf
      (org-with-wide-buffer
       (let ((pos (cond
                   ((and (marker-position marker)
                         (org-kanban-modern--heading-matches-p
                          (marker-position marker) card))
                    (marker-position marker))
                   (t (org-kanban-modern--find-heading card)))))
         (unless pos
           (user-error "Cannot locate heading for %S; refresh the board"
                       (org-kanban-modern-card-title card)))
         (goto-char pos)
         (org-todo target)))
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

;;;; Filtering commands

(defun org-kanban-modern-toggle-tag (tag)
  "Toggle TAG in the active tag filter (elfeed-style)."
  (interactive
   (list (completing-read "Toggle tag: " (org-kanban-modern--all-tags) nil t)))
  (setq org-kanban-modern--tag-filter
        (if (member tag org-kanban-modern--tag-filter)
            (delete tag org-kanban-modern--tag-filter)
          (cons tag org-kanban-modern--tag-filter)))
  (org-kanban-modern--apply-filters))

(defun org-kanban-modern-remove-tag (tag)
  "Remove TAG from the active tag filter."
  (interactive
   (list (completing-read "Remove tag: " org-kanban-modern--tag-filter nil t)))
  (setq org-kanban-modern--tag-filter
        (delete tag org-kanban-modern--tag-filter))
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
  "Clear all active tag and priority filters."
  (interactive)
  (setq org-kanban-modern--tag-filter nil
        org-kanban-modern--priority-filter nil)
  (org-kanban-modern--apply-filters))

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
      (push (propertize (format " #%s ✕ " tag)
                        'face 'org-kanban-modern-filter-chip
                        'mouse-face 'highlight
                        'keymap (org-kanban-modern--chip-keymap
                                 #'org-kanban-modern-remove-tag tag)
                        'help-echo "mouse-1: remove this tag from the filter")
            chips))
    (when org-kanban-modern--priority-filter
      (push (propertize (format " [#%c] ✕ " org-kanban-modern--priority-filter)
                        'face 'org-kanban-modern-filter-chip
                        'mouse-face 'highlight
                        'keymap (org-kanban-modern--chip-keymap
                                 #'org-kanban-modern-filter-by-priority nil)
                        'help-echo "mouse-1: clear the priority filter")
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
    (define-key map [mouse-1] #'org-kanban-modern--mouse-click)
    (define-key map "tt" #'org-kanban-modern-toggle-tag)
    (define-key map "tr" #'org-kanban-modern-remove-tag)
    (define-key map "tp" #'org-kanban-modern-filter-by-priority)
    (define-key map "tc" #'org-kanban-modern-clear-filters)
    (define-key map "g" #'org-kanban-modern-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `org-kanban-modern-mode'.")

(define-derived-mode org-kanban-modern-mode special-mode "Kanban"
  "Major mode for a modern Org TODO kanban board."
  (setq truncate-lines t)
  (setq-local cursor-type nil)
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
