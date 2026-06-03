;;; org-kanban-modern-test.el --- Tests for org-kanban-modern -*- lexical-binding: t; -*-

;; This file is part of org-kanban-modern and is released under the
;; same GPL-3.0-or-later license as the library.

;;; Commentary:

;; ERT tests for the pure logic of org-kanban-modern: keyword
;; stripping, column derivation, text wrapping/padding, tag/priority
;; filtering, and per-column bucketing.  Run with:
;;
;;   emacs -Q --batch -L . -l org-kanban-modern.el \
;;     -l test/org-kanban-modern-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org-kanban-modern)

;;;; Keyword stripping

(ert-deftest org-kanban-modern-test-strip-keyword ()
  (should (equal (org-kanban-modern--strip-keyword "WAITING") "WAITING"))
  (should (equal (org-kanban-modern--strip-keyword "WAITING(w@/!)") "WAITING"))
  (should (equal (org-kanban-modern--strip-keyword "TODO(t)") "TODO"))
  (should (equal (org-kanban-modern--strip-keyword "|") "|")))

;;;; Default column derivation

(ert-deftest org-kanban-modern-test-default-columns ()
  (let ((org-todo-keywords
         '((sequence "TODO(t)" "STARTED" "WAITING(w@/!)" "|" "DONE(d)")
           (sequence "BUG" "|" "FIXED"))))
    (should (equal (org-kanban-modern--default-columns)
                   '("TODO" "STARTED" "WAITING" "DONE" "BUG" "FIXED")))))

(ert-deftest org-kanban-modern-test-default-columns-dedup ()
  (let ((org-todo-keywords
         '((sequence "TODO" "|" "DONE")
           (sequence "TODO" "|" "DONE"))))
    (should (equal (org-kanban-modern--default-columns) '("TODO" "DONE")))))

(ert-deftest org-kanban-modern-test-columns-override ()
  (let ((org-kanban-modern-columns '("A" "B"))
        (org-todo-keywords '((sequence "TODO" "|" "DONE"))))
    (should (equal (org-kanban-modern--columns) '("A" "B")))))

;;;; Padding

(ert-deftest org-kanban-modern-test-pad-shorter ()
  (should (equal (org-kanban-modern--pad "hi" 5) "hi   "))
  (should (= (string-width (org-kanban-modern--pad "hi" 5)) 5)))

(ert-deftest org-kanban-modern-test-pad-exact ()
  (should (equal (org-kanban-modern--pad "hello" 5) "hello")))

(ert-deftest org-kanban-modern-test-pad-longer ()
  (let ((out (org-kanban-modern--pad "hello world" 5)))
    (should (= (string-width out) 5))))

;;;; Wrapping

(ert-deftest org-kanban-modern-test-wrap-short ()
  (should (equal (org-kanban-modern--wrap "hi there" 20) '("hi there"))))

(ert-deftest org-kanban-modern-test-wrap-words ()
  (let ((lines (org-kanban-modern--wrap "one two three four" 8)))
    (should (cl-every (lambda (l) (<= (string-width l) 8)) lines))
    (should (equal (string-join lines " ") "one two three four"))))

(ert-deftest org-kanban-modern-test-wrap-long-word ()
  (let ((lines (org-kanban-modern--wrap "supercalifragilistic" 6)))
    (should (cl-every (lambda (l) (<= (string-width l) 6)) lines))
    (should (equal (apply #'concat lines) "supercalifragilistic"))))

;;;; Filtering helpers

(defun org-kanban-modern-test--card (title todo tags priority)
  "Build a test card with TITLE TODO TAGS PRIORITY."
  (org-kanban-modern-card-create
   :id title :file "x.org" :marker nil
   :title title :todo todo :tags tags :priority priority))

(ert-deftest org-kanban-modern-test-filter-tags-and ()
  (with-temp-buffer
    (let ((cards (list (org-kanban-modern-test--card "a" "TODO" '("work" "urgent") nil)
                       (org-kanban-modern-test--card "b" "TODO" '("work") nil)
                       (org-kanban-modern-test--card "c" "TODO" '("home" "urgent") nil))))
      (setq org-kanban-modern--tag-filter '("work" "urgent")
            org-kanban-modern--priority-filter nil)
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--filtered cards))
                     '("a")))
      (setq org-kanban-modern--tag-filter '("urgent"))
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--filtered cards))
                     '("a" "c")))
      (setq org-kanban-modern--tag-filter nil)
      (should (= (length (org-kanban-modern--filtered cards)) 3)))))

(ert-deftest org-kanban-modern-test-filter-tags-exclude ()
  (with-temp-buffer
    (let ((cards (list (org-kanban-modern-test--card "a" "TODO" '("work" "urgent") nil)
                       (org-kanban-modern-test--card "b" "TODO" '("work") nil)
                       (org-kanban-modern-test--card "c" "TODO" '("home") nil))))
      (setq org-kanban-modern--tag-filter nil
            org-kanban-modern--tag-exclude '("work")
            org-kanban-modern--priority-filter nil)
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--filtered cards))
                     '("c")))
      (setq org-kanban-modern--tag-exclude '("urgent" "home"))
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--filtered cards))
                     '("b"))))))

(ert-deftest org-kanban-modern-test-filter-tags-include-and-exclude ()
  (with-temp-buffer
    (let ((cards (list (org-kanban-modern-test--card "a" "TODO" '("work" "urgent") nil)
                       (org-kanban-modern-test--card "b" "TODO" '("work") nil)
                       (org-kanban-modern-test--card "c" "TODO" '("work" "urgent" "home") nil))))
      ;; Must have "work", must not have "home".
      (setq org-kanban-modern--tag-filter '("work")
            org-kanban-modern--tag-exclude '("home")
            org-kanban-modern--priority-filter nil)
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--filtered cards))
                     '("a" "b"))))))

(ert-deftest org-kanban-modern-test-set-tag-state-mutual-exclusivity ()
  (with-temp-buffer
    (setq org-kanban-modern--tag-filter nil
          org-kanban-modern--tag-exclude nil)
    (should (eq (org-kanban-modern--tag-state "x") nil))
    (org-kanban-modern--set-tag-state "x" 'include)
    (should (eq (org-kanban-modern--tag-state "x") 'include))
    (should (member "x" org-kanban-modern--tag-filter))
    (should-not (member "x" org-kanban-modern--tag-exclude))
    ;; Moving to exclude drops it from include (lists stay disjoint).
    (org-kanban-modern--set-tag-state "x" 'exclude)
    (should (eq (org-kanban-modern--tag-state "x") 'exclude))
    (should-not (member "x" org-kanban-modern--tag-filter))
    (should (member "x" org-kanban-modern--tag-exclude))
    ;; nil removes from both.
    (org-kanban-modern--set-tag-state "x" nil)
    (should (eq (org-kanban-modern--tag-state "x") nil))
    (should-not (member "x" org-kanban-modern--tag-filter))
    (should-not (member "x" org-kanban-modern--tag-exclude))))

(ert-deftest org-kanban-modern-test-include-exclude-commands ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'org-kanban-modern--apply-filters) #'ignore))
      (setq org-kanban-modern--tag-filter nil
            org-kanban-modern--tag-exclude nil)
      ;; include toggles on then off.
      (org-kanban-modern-include-tag "x")
      (should (eq (org-kanban-modern--tag-state "x") 'include))
      (org-kanban-modern-include-tag "x")
      (should (eq (org-kanban-modern--tag-state "x") nil))
      ;; exclude toggles on then off.
      (org-kanban-modern-exclude-tag "x")
      (should (eq (org-kanban-modern--tag-state "x") 'exclude))
      (org-kanban-modern-exclude-tag "x")
      (should (eq (org-kanban-modern--tag-state "x") nil))
      ;; exclude then include flips state, never both.
      (org-kanban-modern-exclude-tag "x")
      (org-kanban-modern-include-tag "x")
      (should (eq (org-kanban-modern--tag-state "x") 'include))
      (should-not (member "x" org-kanban-modern--tag-exclude)))))

(ert-deftest org-kanban-modern-test-remove-tag-spans-both ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'org-kanban-modern--apply-filters) #'ignore))
      (setq org-kanban-modern--tag-filter '("inc")
            org-kanban-modern--tag-exclude '("exc"))
      (org-kanban-modern-remove-tag "inc")
      (should-not (member "inc" org-kanban-modern--tag-filter))
      (org-kanban-modern-remove-tag "exc")
      (should-not (member "exc" org-kanban-modern--tag-exclude)))))

(ert-deftest org-kanban-modern-test-clear-filters-clears-exclude ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'org-kanban-modern--apply-filters) #'ignore))
      (setq org-kanban-modern--tag-filter '("a")
            org-kanban-modern--tag-exclude '("b")
            org-kanban-modern--priority-filter ?A)
      (org-kanban-modern-clear-filters)
      (should-not org-kanban-modern--tag-filter)
      (should-not org-kanban-modern--tag-exclude)
      (should-not org-kanban-modern--priority-filter))))

(ert-deftest org-kanban-modern-test-chip-face-off-returns-base ()
  (let ((org-kanban-modern-use-tag-faces nil)
        (org-tag-faces '(("work" . "red"))))
    (should (eq (org-kanban-modern--chip-face
                 "work" 'org-kanban-modern-tag)
                'org-kanban-modern-tag))))

(ert-deftest org-kanban-modern-test-chip-face-on-unmapped ()
  (let ((org-kanban-modern-use-tag-faces t)
        (org-tag-faces nil))
    (should (equal (org-kanban-modern--chip-face
                    "work" 'org-kanban-modern-tag)
                   (list 'fixed-pitch 'org-tag 'org-kanban-modern-tag)))))

(ert-deftest org-kanban-modern-test-chip-face-on-color-mapped ()
  (let ((org-kanban-modern-use-tag-faces t)
        (org-tag-faces '(("work" . "red"))))
    (let ((result (org-kanban-modern--chip-face
                   "work" 'org-kanban-modern-tag-active)))
      ;; fixed-pitch must lead so the per-tag face cannot break the grid.
      (should (eq (car result) 'fixed-pitch))
      ;; the resolved tag spec (a plist) sits between fixed-pitch and base.
      (should (equal (nth 1 result) (org-get-tag-face "work")))
      ;; base stays last so state decoration still applies.
      (should (eq (nth 2 result) 'org-kanban-modern-tag-active)))))

(ert-deftest org-kanban-modern-test-filter-priority ()
  (with-temp-buffer
    (let ((cards (list (org-kanban-modern-test--card "a" "TODO" nil ?A)
                       (org-kanban-modern-test--card "b" "TODO" nil ?B)
                       (org-kanban-modern-test--card "c" "TODO" nil nil))))
      (setq org-kanban-modern--tag-filter nil
            org-kanban-modern--priority-filter ?A)
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--filtered cards))
                     '("a")))
      (setq org-kanban-modern--priority-filter nil)
      (should (= (length (org-kanban-modern--filtered cards)) 3)))))

(ert-deftest org-kanban-modern-test-cards-for-column ()
  (let ((cards (list (org-kanban-modern-test--card "a" "TODO" nil nil)
                     (org-kanban-modern-test--card "b" "STARTED" nil nil)
                     (org-kanban-modern-test--card "c" "TODO" nil nil)))
        (org-kanban-modern-sort 'document))
    (should (equal (mapcar #'org-kanban-modern-card-title
                           (org-kanban-modern--cards-for-column "TODO" cards))
                   '("a" "c")))
    (should (null (org-kanban-modern--cards-for-column "DONE" cards)))))

(ert-deftest org-kanban-modern-test-sort-priority ()
  "`priority' sorting puts higher priorities first and, like org-agenda,
treats an unprioritized card as `org-default-priority' (here ?B), so it
interleaves with explicit [#B] cards; equal-priority cards keep document
order."
  (let ((cards (list (org-kanban-modern-test--card "none1" "TODO" nil nil)
                     (org-kanban-modern-test--card "b1" "TODO" nil ?B)
                     (org-kanban-modern-test--card "a1" "TODO" nil ?A)
                     (org-kanban-modern-test--card "none2" "TODO" nil nil)
                     (org-kanban-modern-test--card "a2" "TODO" nil ?A)
                     (org-kanban-modern-test--card "c1" "TODO" nil ?C)))
        (org-default-priority ?B))
    (let ((org-kanban-modern-sort 'priority))
      ;; A's first, then the B-rank group (explicit and unprioritized) in
      ;; document order, then C.
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--cards-for-column "TODO" cards))
                     '("a1" "a2" "none1" "b1" "none2" "c1"))))
    ;; Document order leaves the collection order untouched.
    (let ((org-kanban-modern-sort 'document))
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--cards-for-column "TODO" cards))
                     '("none1" "b1" "a1" "none2" "a2" "c1"))))
    ;; A custom predicate is honored.
    (let ((org-kanban-modern-sort
           (lambda (x y) (string< (org-kanban-modern-card-title x)
                                  (org-kanban-modern-card-title y)))))
      (should (equal (mapcar #'org-kanban-modern-card-title
                             (org-kanban-modern--cards-for-column "TODO" cards))
                     '("a1" "a2" "b1" "c1" "none1" "none2"))))))

;;;; Markup rendering

(ert-deftest org-kanban-modern-test-fontify-title-off ()
  (let ((org-kanban-modern-render-markup nil))
    (should (equal (org-kanban-modern--fontify-title "raw *x* text")
                   "raw *x* text"))))

(ert-deftest org-kanban-modern-test-fontify-title-emphasis ()
  (let ((org-kanban-modern-render-markup t))
    (let ((s (org-kanban-modern--fontify-title "has *bold* word")))
      ;; Emphasis markers are dropped, so width matches the display.
      (should (equal (substring-no-properties s) "has bold word"))
      (should (= (string-width s) 13))
      ;; The inner text carries the bold face.
      (let ((f (get-text-property 4 'face s)))
        (should (memq 'bold (if (listp f) f (list f))))))))

(ert-deftest org-kanban-modern-test-fontify-title-link ()
  (let ((org-kanban-modern-render-markup t))
    (let ((s (org-kanban-modern--fontify-title "see [[https://x.org][Docs]] now")))
      ;; The link collapses to its description.
      (should (equal (substring-no-properties s) "see Docs now"))
      ;; Org's link keymap and help-echo must not leak onto the card.
      (should-not (get-text-property 4 'keymap s))
      (should-not (get-text-property 4 'help-echo s)))))

;;;; Priority coloring

(ert-deftest org-kanban-modern-test-priority-cookie-face ()
  (let ((org-priority-faces '((?A . "#ff0000") (?B . shadow))))
    ;; A color string becomes a foreground laid over our base face.
    (let ((f (org-kanban-modern--priority-cookie-face ?A)))
      (should (equal f (list '(:foreground "#ff0000")
                             'org-kanban-modern-priority))))
    ;; A face is applied first, with our base underneath for fixed-pitch.
    (should (equal (org-kanban-modern--priority-cookie-face ?B)
                   (list 'shadow 'org-kanban-modern-priority)))
    ;; Unmapped priorities fall back to the plain cookie face.
    (should (eq (org-kanban-modern--priority-cookie-face ?C)
                'org-kanban-modern-priority))))

(ert-deftest org-kanban-modern-test-priority-style-gate ()
  "The [#X] cookie is colored only when the style is non-nil."
  (let* ((org-priority-faces '((?A . "#ff0000")))
         (card (org-kanban-modern-card-create
                :id "x" :title "Task" :todo "TODO" :priority ?A))
         (cookie-face
          (lambda (style)
            (let* ((org-kanban-modern-priority-style style)
                   (line (car (org-kanban-modern--card-lines card 24 nil)))
                   (pos (string-match "\\[#A\\]" line))
                   (face (get-text-property pos 'face line)))
              (if (listp face) face (list face))))))
    ;; A non-nil style colors the cookie: the priority foreground is present.
    (should (member '(:foreground "#ff0000") (funcall cookie-face 'cookie)))
    ;; A nil style leaves the cookie on the plain priority face only.
    (let ((face (funcall cookie-face nil)))
      (should-not (member '(:foreground "#ff0000") face))
      (should (member 'org-kanban-modern-priority face)))
    ;; The defcustom no longer offers background tinting.
    (should (equal (get 'org-kanban-modern-priority-style 'custom-type)
                   '(choice (const :tag "Color the priority cookie" cookie)
                            (const :tag "No priority color" nil))))))

;;;; Planning timestamps

(ert-deftest org-kanban-modern-test-format-timestamp ()
  "Bracket stripping keeps the inner date, time, and any repeater."
  (should (equal (org-kanban-modern--format-timestamp "<2026-06-02 Tue>")
                 "2026-06-02 Tue"))
  ;; Active timestamp with a repeater.
  (should (equal (org-kanban-modern--format-timestamp "<2026-06-02 Tue +1w>")
                 "2026-06-02 Tue +1w"))
  ;; Other repeater/offset cookies survive intact.
  (should (equal (org-kanban-modern--format-timestamp "<2026-06-02 Tue .+1m>")
                 "2026-06-02 Tue .+1m"))
  (should (equal (org-kanban-modern--format-timestamp "<2026-06-02 Tue ++1y -3d>")
                 "2026-06-02 Tue ++1y -3d"))
  ;; A time range is preserved.
  (should (equal (org-kanban-modern--format-timestamp "<2026-06-02 Tue 09:00-10:00>")
                 "2026-06-02 Tue 09:00-10:00"))
  ;; Inactive timestamps are handled defensively.
  (should (equal (org-kanban-modern--format-timestamp "[2026-06-02 Tue]")
                 "2026-06-02 Tue"))
  ;; A timestamp range drops the inner delimiters too.
  (should (equal (org-kanban-modern--format-timestamp
                  "<2026-06-02 Tue>--<2026-06-03 Wed>")
                 "2026-06-02 Tue--2026-06-03 Wed")))

(ert-deftest org-kanban-modern-test-planning-raw ()
  "`--planning-raw' preserves repeaters and warning periods from real Org."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (org-mode)
      (insert "* TODO Example\n"
              "SCHEDULED: <2026-06-02 Tue +1w -3d> DEADLINE: <2026-06-09 Tue ++1m>\n")
      (goto-char (point-min))
      (let ((el (org-element-at-point)))
        (should (equal (org-kanban-modern--planning-raw el :scheduled)
                       "<2026-06-02 Tue +1w -3d>"))
        (should (equal (org-kanban-modern--planning-raw el :deadline)
                       "<2026-06-09 Tue ++1m>")))))
  ;; A heading with no planning info yields nil for both.
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (org-mode)
      (insert "* TODO Bare\n")
      (goto-char (point-min))
      (let ((el (org-element-at-point)))
        (should-not (org-kanban-modern--planning-raw el :scheduled))
        (should-not (org-kanban-modern--planning-raw el :deadline))))))

(ert-deftest org-kanban-modern-test-planning-lines ()
  "Planning lines render deadline first, then scheduled, gated on the toggle."
  (let* ((org-kanban-modern-scheduled-glyph "S:")
         (org-kanban-modern-deadline-glyph "D:")
         (org-kanban-modern-planning-compact nil)
         (card (org-kanban-modern-card-create
                :id "x" :title "Task" :todo "TODO"
                :scheduled "<2026-06-02 Tue +1w>"
                :deadline "<2026-06-09 Tue>")))
    ;; Both set: deadline line precedes the scheduled line.
    (let ((org-kanban-modern-show-planning t))
      (let ((lines (org-kanban-modern--planning-lines card 40)))
        (should (= (length lines) 2))
        (should (string-prefix-p "D:" (nth 0 lines)))
        (should (string-match-p "2026-06-09 Tue" (nth 0 lines)))
        (should (string-prefix-p "S:" (nth 1 lines)))
        ;; The repeater is preserved on the scheduled line.
        (should (string-match-p (regexp-quote "2026-06-02 Tue +1w") (nth 1 lines)))))
    ;; The toggle suppresses planning entirely.
    (let ((org-kanban-modern-show-planning nil))
      (should-not (org-kanban-modern--planning-lines card 40))))
  ;; Neither set: no lines.
  (let ((org-kanban-modern-show-planning t)
        (card (org-kanban-modern-card-create
               :id "y" :title "Task" :todo "TODO")))
    (should-not (org-kanban-modern--planning-lines card 40)))
  ;; Only one set: a single line.
  (let ((org-kanban-modern-show-planning t)
        (card (org-kanban-modern-card-create
               :id "z" :title "Task" :todo "TODO"
               :scheduled "<2026-06-02 Tue>")))
    (should (= (length (org-kanban-modern--planning-lines card 40)) 1))))

(ert-deftest org-kanban-modern-test-default-glyph-widths ()
  "Default planning glyphs are pure ASCII for a deterministic grid width.
A non-ASCII default (emoji, or any symbol absent from the user's
fixed-pitch font) is drawn from a fallback font whose pixel advance does
not align to the monospace card grid, which misaligns the timestamp.
ASCII chars are guaranteed to render in the fixed-pitch font, so guard
against regressing the defaults to non-ASCII."
  (dolist (glyph (list org-kanban-modern-scheduled-glyph
                       org-kanban-modern-deadline-glyph))
    (dolist (ch (string-to-list glyph))
      ;; Each char must be ASCII (< 128) so it lives in the fixed-pitch font.
      (should (< ch 128)))))

(ert-deftest org-kanban-modern-test-strip-weekday ()
  "`--strip-weekday' drops the day name but keeps time, repeater, warning."
  ;; Date + weekday only.
  (should (equal (org-kanban-modern--strip-weekday "2026-06-02 Tue")
                 "2026-06-02"))
  ;; Date + weekday + time.
  (should (equal (org-kanban-modern--strip-weekday "2026-06-03 Wed 11:00")
                 "2026-06-03 11:00"))
  ;; Date + weekday + time + repeater + warning.
  (should (equal (org-kanban-modern--strip-weekday "2026-06-03 Wed 11:00 +1w -3d")
                 "2026-06-03 11:00 +1w -3d"))
  ;; A non-ASCII (localised) weekday is still dropped.
  (should (equal (org-kanban-modern--strip-weekday "2026-06-03 木 11:00")
                 "2026-06-03 11:00"))
  ;; A locale weekday abbreviation ending in a period is still dropped.
  (should (equal (org-kanban-modern--strip-weekday "2026-06-03 mer. 11:00")
                 "2026-06-03 11:00"))
  ;; No weekday present: returned unchanged.
  (should (equal (org-kanban-modern--strip-weekday "2026-06-03 11:00")
                 "2026-06-03 11:00"))
  ;; A range is left intact (no corruption of the second date).
  (should (equal (org-kanban-modern--strip-weekday "2026-06-02 Tue--2026-06-03 Wed")
                 "2026-06-02 Tue--2026-06-03 Wed"))
  ;; A diary sexp timestamp (no ISO date prefix) is left intact.
  (should (equal (org-kanban-modern--strip-weekday "%%(diary-float t 4 2)")
                 "%%(diary-float t 4 2)")))

(ert-deftest org-kanban-modern-test-planning-compact ()
  "`org-kanban-modern-planning-compact' toggles weekday display."
  (let* ((org-kanban-modern-scheduled-glyph "S:")
         (card (org-kanban-modern-card-create
                :id "c" :title "Task" :todo "TODO"
                :scheduled "<2026-06-03 Wed 11:00 +1w>"))
         (org-kanban-modern-show-planning t))
    ;; Compact (default): the weekday is gone, the repeater stays.
    (let* ((org-kanban-modern-planning-compact t)
           (line (car (org-kanban-modern--planning-lines card 40))))
      (should (string-match-p (regexp-quote "2026-06-03 11:00 +1w") line))
      (should-not (string-match-p "Wed" line)))
    ;; Disabled: the weekday is preserved.
    (let* ((org-kanban-modern-planning-compact nil)
           (line (car (org-kanban-modern--planning-lines card 40))))
      (should (string-match-p (regexp-quote "2026-06-03 Wed 11:00 +1w") line)))))

(ert-deftest org-kanban-modern-test-planning-lines-in-card ()
  "Planning lines appear between the title and the tags in a rendered card."
  (let* ((org-kanban-modern-show-planning t)
         (org-kanban-modern-scheduled-glyph "S:")
         (org-kanban-modern-deadline-glyph "D:")
         (card (org-kanban-modern-card-create
                :id "x" :title "Task" :todo "TODO" :tags '("work")
                :scheduled "<2026-06-02 Tue +1w>"
                :deadline "<2026-06-09 Tue>"))
         (lines (org-kanban-modern--card-lines card 30 nil))
         (joined (mapcar #'substring-no-properties lines))
         (title-row (cl-position-if (lambda (l) (string-match-p "Task" l)) joined))
         (deadline-row (cl-position-if (lambda (l) (string-match-p "D:" l)) joined))
         (scheduled-row (cl-position-if (lambda (l) (string-match-p "S:" l)) joined))
         (tag-row (cl-position-if (lambda (l) (string-match-p "#work" l)) joined)))
    (should title-row)
    (should deadline-row)
    (should scheduled-row)
    (should tag-row)
    ;; Order: title < deadline < scheduled < tags.
    (should (< title-row deadline-row scheduled-row tag-row))))

;;;; Done date filtering

(defun org-kanban-modern-test--closed (days-ago)
  "Return a CLOSED inactive timestamp string DAYS-AGO days in the past."
  (format-time-string "[%Y-%m-%d %a %H:%M]"
                      (time-subtract (current-time) (* days-ago 86400))))

(ert-deftest org-kanban-modern-test-show-entry-p ()
  (let ((org-todo-keywords '((sequence "TODO" "|" "DONE" "CANCELLED"))))
    (with-temp-buffer
      (insert "* TODO active\n"
              "* DONE recent\n  CLOSED: " (org-kanban-modern-test--closed 1) "\n"
              "* DONE old\n  CLOSED: " (org-kanban-modern-test--closed 30) "\n"
              "* DONE undated\n"
              "* CANCELLED old cancel\n  CLOSED: "
              (org-kanban-modern-test--closed 30) "\n")
      (org-mode)
      (let ((now (current-time))
            (results '()))
        (org-map-entries
         (lambda ()
           (push (cons (org-get-heading t t t t)
                       (and (org-kanban-modern--show-entry-p
                             (org-get-todo-state) 7 now)
                            t))
                 results)))
        (setq results (nreverse results))
        ;; Window of 7 days: active and recently-closed pass; old done is
        ;; hidden; a done entry with no CLOSED is shown (unknown age);
        ;; custom done keywords (CANCELLED) obey the same cutoff.
        (should (cdr (assoc "active" results)))
        (should (cdr (assoc "recent" results)))
        (should-not (cdr (assoc "old" results)))
        (should (cdr (assoc "undated" results)))
        (should-not (cdr (assoc "old cancel" results)))
        ;; A nil window shows every entry regardless of CLOSED date.
        (let ((all '()))
          (org-map-entries
           (lambda ()
             (push (org-kanban-modern--show-entry-p
                    (org-get-todo-state) nil now)
                   all)))
          (should (cl-every #'identity all)))))))

;;;; Direct card editing

(defun org-kanban-modern-test--file-contents (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun org-kanban-modern-test--kill-file-buffer (file)
  "Kill FILE's visiting buffer without saving test changes."
  (when-let ((buf (find-buffer-visiting file)))
    (with-current-buffer buf (set-buffer-modified-p nil))
    (kill-buffer buf)))

(defun org-kanban-modern-test--card-by-title (title)
  "Return the collected card with TITLE."
  (cl-find title org-kanban-modern--cards
           :key #'org-kanban-modern-card-title
           :test #'equal))

(ert-deftest org-kanban-modern-test-set-todo-keeps-clean-source-unsaved ()
  "`--set-todo' leaves its Org change unsaved like Org Agenda."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (org-log-done nil)
         (file (make-temp-file "okm-set-todo" nil ".org"
                               "* TODO write tests\n")))
    (unwind-protect
        (let ((org-kanban-modern-files (list file))
              (org-kanban-modern-columns '("TODO" "DONE")))
          (with-temp-buffer
            (setq org-kanban-modern--cards (org-kanban-modern--collect))
            (org-kanban-modern--set-todo
             (org-kanban-modern-test--card-by-title "write tests")
             "DONE")
            (should (equal (org-kanban-modern-test--file-contents file)
                           "* TODO write tests\n"))
            (with-current-buffer (find-buffer-visiting file)
              (should (buffer-modified-p))
              (should (string-match-p "\\`\\* DONE write tests\n\\'"
                                      (buffer-string))))))
      (org-kanban-modern-test--kill-file-buffer file)
      (delete-file file))))

(ert-deftest org-kanban-modern-test-set-todo-keeps-dirty-source-unsaved ()
  "`--set-todo' does not save unrelated pre-existing source edits."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (org-log-done nil)
         (file (make-temp-file "okm-set-todo-dirty" nil ".org"
                               "* TODO write tests\n")))
    (unwind-protect
        (let ((org-kanban-modern-files (list file))
              (org-kanban-modern-columns '("TODO" "DONE")))
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-max))
            (insert "Unrelated draft note.\n"))
          (with-temp-buffer
            (setq org-kanban-modern--cards (org-kanban-modern--collect))
            (org-kanban-modern--set-todo
             (org-kanban-modern-test--card-by-title "write tests")
             "DONE"))
          (should (equal (org-kanban-modern-test--file-contents file)
                         "* TODO write tests\n"))
          (with-current-buffer (find-buffer-visiting file)
            (should (buffer-modified-p))
            (should (string-match-p "\\`\\* DONE write tests\n"
                                    (buffer-string)))
            (should (string-match-p "Unrelated draft note"
                                    (buffer-string)))))
      (org-kanban-modern-test--kill-file-buffer file)
      (delete-file file))))

(ert-deftest org-kanban-modern-test-edit-at-card ()
  "`--edit-at-card' edits a clean source heading and re-collects.
The selection (stable ID) survives the edit."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (file (make-temp-file "okm-edit" nil ".org"
                               "* TODO write tests\n")))
    (unwind-protect
        (let ((org-kanban-modern-files (list file))
              (org-kanban-modern-columns '("TODO" "DONE")))
          (with-temp-buffer
            ;; Stand up just enough board state for the helper, and keep
            ;; rendering headless by stubbing the redraw.
            (cl-letf (((symbol-function 'org-kanban-modern--render)
                       #'ignore))
              (setq org-kanban-modern--cards (org-kanban-modern--collect))
              (should (= (length org-kanban-modern--cards) 1))
              (setq org-kanban-modern--selected-id
                    (org-kanban-modern-card-id (car org-kanban-modern--cards)))
              (let ((edited (org-kanban-modern--edit-at-card
                             (lambda () (org-priority ?A)))))
                ;; The helper returns the (pre-edit) selected card.
                (should (equal (org-kanban-modern-card-title edited)
                               "write tests"))
                ;; The change stays in the source buffer, matching Org Agenda.
                (should (equal (org-kanban-modern-test--file-contents file)
                               "* TODO write tests\n"))
                (with-current-buffer (find-buffer-visiting file)
                  (should (buffer-modified-p))
                  (should (string-match-p "\\[#A\\]" (buffer-string))))
                ;; The board was re-collected with the new priority, and the
                ;; selection survived because the ID is stable.
                (let ((card (org-kanban-modern--selected-card)))
                  (should card)
                  (should (eq (org-kanban-modern-card-priority card) ?A)))))))
      (org-kanban-modern-test--kill-file-buffer file)
      (delete-file file))))

(ert-deftest org-kanban-modern-test-edit-at-card-keeps-dirty-source-unsaved ()
  "`--edit-at-card' does not save unrelated pre-existing source edits."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (file (make-temp-file "okm-edit-dirty" nil ".org"
                               "* TODO write tests\n")))
    (unwind-protect
        (let ((org-kanban-modern-files (list file))
              (org-kanban-modern-columns '("TODO" "DONE")))
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-max))
            (insert "Unrelated draft note.\n"))
          (with-temp-buffer
            (cl-letf (((symbol-function 'org-kanban-modern--render)
                       #'ignore))
              (setq org-kanban-modern--cards (org-kanban-modern--collect))
              (setq org-kanban-modern--selected-id
                    (org-kanban-modern-card-id
                     (org-kanban-modern-test--card-by-title "write tests")))
              (org-kanban-modern--edit-at-card
               (lambda () (org-priority ?A)))
              (let ((card (org-kanban-modern--selected-card)))
                (should card)
                (should (eq (org-kanban-modern-card-priority card) ?A)))))
          (should (equal (org-kanban-modern-test--file-contents file)
                         "* TODO write tests\n"))
          (with-current-buffer (find-buffer-visiting file)
            (should (buffer-modified-p))
            (should (string-match-p "\\[#A\\]" (buffer-string)))
            (should (string-match-p "Unrelated draft note"
                                    (buffer-string)))))
      (org-kanban-modern-test--kill-file-buffer file)
      (delete-file file))))

(provide 'org-kanban-modern-test)
;;; org-kanban-modern-test.el ends here
