;;; org-agenda-kanban-test.el --- Tests for org-agenda-kanban -*- lexical-binding: t; -*-

;; This file is part of org-agenda-kanban and is released under the
;; same GPL-3.0-or-later license as the library.

;;; Commentary:

;; ERT tests for the pure logic of org-agenda-kanban: keyword
;; stripping, column derivation, text wrapping/padding, tag/priority
;; filtering, and per-column bucketing.  Run with:
;;
;;   emacs -Q --batch -L . -l org-agenda-kanban.el \
;;     -l test/org-agenda-kanban-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org-agenda-kanban)

;;;; Keyword stripping

(ert-deftest org-agenda-kanban-test-strip-keyword ()
  (should (equal (org-agenda-kanban--strip-keyword "WAITING") "WAITING"))
  (should (equal (org-agenda-kanban--strip-keyword "WAITING(w@/!)") "WAITING"))
  (should (equal (org-agenda-kanban--strip-keyword "TODO(t)") "TODO"))
  (should (equal (org-agenda-kanban--strip-keyword "|") "|")))

;;;; Default column derivation

(ert-deftest org-agenda-kanban-test-default-columns ()
  (let ((org-todo-keywords
         '((sequence "TODO(t)" "STARTED" "WAITING(w@/!)" "|" "DONE(d)")
           (sequence "BUG" "|" "FIXED"))))
    (should (equal (org-agenda-kanban--default-columns)
                   '("TODO" "STARTED" "WAITING" "DONE" "BUG" "FIXED")))))

(ert-deftest org-agenda-kanban-test-default-columns-dedup ()
  (let ((org-todo-keywords
         '((sequence "TODO" "|" "DONE")
           (sequence "TODO" "|" "DONE"))))
    (should (equal (org-agenda-kanban--default-columns) '("TODO" "DONE")))))

(ert-deftest org-agenda-kanban-test-columns-override ()
  (let ((org-agenda-kanban-columns '("A" "B"))
        (org-todo-keywords '((sequence "TODO" "|" "DONE"))))
    (should (equal (org-agenda-kanban--columns) '("A" "B")))))

;;;; Padding

(ert-deftest org-agenda-kanban-test-pad-shorter ()
  (should (equal (org-agenda-kanban--pad "hi" 5) "hi   "))
  (should (= (string-width (org-agenda-kanban--pad "hi" 5)) 5)))

(ert-deftest org-agenda-kanban-test-pad-exact ()
  (should (equal (org-agenda-kanban--pad "hello" 5) "hello")))

(ert-deftest org-agenda-kanban-test-pad-longer ()
  (let ((out (org-agenda-kanban--pad "hello world" 5)))
    (should (= (string-width out) 5))))

;;;; Wrapping

(ert-deftest org-agenda-kanban-test-wrap-short ()
  (should (equal (org-agenda-kanban--wrap "hi there" 20) '("hi there"))))

(ert-deftest org-agenda-kanban-test-wrap-words ()
  (let ((lines (org-agenda-kanban--wrap "one two three four" 8)))
    (should (cl-every (lambda (l) (<= (string-width l) 8)) lines))
    (should (equal (string-join lines " ") "one two three four"))))

(ert-deftest org-agenda-kanban-test-wrap-long-word ()
  (let ((lines (org-agenda-kanban--wrap "supercalifragilistic" 6)))
    (should (cl-every (lambda (l) (<= (string-width l) 6)) lines))
    (should (equal (apply #'concat lines) "supercalifragilistic"))))

(ert-deftest org-agenda-kanban-test-wrap-invalid-width ()
  (should-error (org-agenda-kanban--wrap "nope" 0) :type 'user-error)
  (should-error (org-agenda-kanban--wrap "nope" -1) :type 'user-error))

(ert-deftest org-agenda-kanban-test-render-invalid-column-width ()
  (with-temp-buffer
    (let ((org-agenda-kanban-column-width org-agenda-kanban--bar-width)
          (org-agenda-kanban-column-gap 0))
      (should-error (org-agenda-kanban--render) :type 'user-error))))

(ert-deftest org-agenda-kanban-test-render-invalid-column-gap ()
  (with-temp-buffer
    (let ((org-agenda-kanban-column-width (1+ org-agenda-kanban--bar-width))
          (org-agenda-kanban-column-gap -1))
      (should-error (org-agenda-kanban--render) :type 'user-error))))

(ert-deftest org-agenda-kanban-test-render-minimum-column-width ()
  (let* ((width (1+ org-agenda-kanban--bar-width))
         (card (org-agenda-kanban-card-create
                :id "small" :title "abc" :todo "TODO")))
    (with-temp-buffer
      (let ((org-agenda-kanban-column-width width)
            (org-agenda-kanban-column-gap 0)
            (org-agenda-kanban-columns '("TODO"))
            (org-agenda-kanban--cards (list card))
            (org-agenda-kanban--visible (list card))
            (org-agenda-kanban--selected-id "small"))
        (org-agenda-kanban--render)
        (dolist (line (split-string (buffer-string) "\n" t))
          (should (<= (string-width line) width)))))))

;;;; Filtering helpers

(defun org-agenda-kanban-test--card (title todo tags priority)
  "Build a test card with TITLE TODO TAGS PRIORITY."
  (org-agenda-kanban-card-create
   :id title :file "x.org" :marker nil
   :title title :todo todo :tags tags :priority priority))

(ert-deftest org-agenda-kanban-test-filter-tags-and ()
  (with-temp-buffer
    (let ((cards (list (org-agenda-kanban-test--card "a" "TODO" '("work" "urgent") nil)
                       (org-agenda-kanban-test--card "b" "TODO" '("work") nil)
                       (org-agenda-kanban-test--card "c" "TODO" '("home" "urgent") nil))))
      (setq org-agenda-kanban--tag-filter '("work" "urgent")
            org-agenda-kanban--priority-filter nil)
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("a")))
      (setq org-agenda-kanban--tag-filter '("urgent"))
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("a" "c")))
      (setq org-agenda-kanban--tag-filter nil)
      (should (= (length (org-agenda-kanban--filtered cards)) 3)))))

(ert-deftest org-agenda-kanban-test-filter-tags-exclude ()
  (with-temp-buffer
    (let ((cards (list (org-agenda-kanban-test--card "a" "TODO" '("work" "urgent") nil)
                       (org-agenda-kanban-test--card "b" "TODO" '("work") nil)
                       (org-agenda-kanban-test--card "c" "TODO" '("home") nil))))
      (setq org-agenda-kanban--tag-filter nil
            org-agenda-kanban--tag-exclude '("work")
            org-agenda-kanban--priority-filter nil)
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("c")))
      (setq org-agenda-kanban--tag-exclude '("urgent" "home"))
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("b"))))))

(ert-deftest org-agenda-kanban-test-filter-tags-include-and-exclude ()
  (with-temp-buffer
    (let ((cards (list (org-agenda-kanban-test--card "a" "TODO" '("work" "urgent") nil)
                       (org-agenda-kanban-test--card "b" "TODO" '("work") nil)
                       (org-agenda-kanban-test--card "c" "TODO" '("work" "urgent" "home") nil))))
      ;; Must have "work", must not have "home".
      (setq org-agenda-kanban--tag-filter '("work")
            org-agenda-kanban--tag-exclude '("home")
            org-agenda-kanban--priority-filter nil)
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("a" "b"))))))

(ert-deftest org-agenda-kanban-test-set-tag-state-mutual-exclusivity ()
  (with-temp-buffer
    (setq org-agenda-kanban--tag-filter nil
          org-agenda-kanban--tag-exclude nil)
    (should (eq (org-agenda-kanban--tag-state "x") nil))
    (org-agenda-kanban--set-tag-state "x" 'include)
    (should (eq (org-agenda-kanban--tag-state "x") 'include))
    (should (member "x" org-agenda-kanban--tag-filter))
    (should-not (member "x" org-agenda-kanban--tag-exclude))
    ;; Moving to exclude drops it from include (lists stay disjoint).
    (org-agenda-kanban--set-tag-state "x" 'exclude)
    (should (eq (org-agenda-kanban--tag-state "x") 'exclude))
    (should-not (member "x" org-agenda-kanban--tag-filter))
    (should (member "x" org-agenda-kanban--tag-exclude))
    ;; nil removes from both.
    (org-agenda-kanban--set-tag-state "x" nil)
    (should (eq (org-agenda-kanban--tag-state "x") nil))
    (should-not (member "x" org-agenda-kanban--tag-filter))
    (should-not (member "x" org-agenda-kanban--tag-exclude))))

(ert-deftest org-agenda-kanban-test-include-exclude-commands ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'org-agenda-kanban--apply-filters) #'ignore))
      (setq org-agenda-kanban--tag-filter nil
            org-agenda-kanban--tag-exclude nil)
      ;; include toggles on then off.
      (org-agenda-kanban-include-tag "x")
      (should (eq (org-agenda-kanban--tag-state "x") 'include))
      (org-agenda-kanban-include-tag "x")
      (should (eq (org-agenda-kanban--tag-state "x") nil))
      ;; exclude toggles on then off.
      (org-agenda-kanban-exclude-tag "x")
      (should (eq (org-agenda-kanban--tag-state "x") 'exclude))
      (org-agenda-kanban-exclude-tag "x")
      (should (eq (org-agenda-kanban--tag-state "x") nil))
      ;; exclude then include flips state, never both.
      (org-agenda-kanban-exclude-tag "x")
      (org-agenda-kanban-include-tag "x")
      (should (eq (org-agenda-kanban--tag-state "x") 'include))
      (should-not (member "x" org-agenda-kanban--tag-exclude)))))

(ert-deftest org-agenda-kanban-test-remove-tag-spans-both ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'org-agenda-kanban--apply-filters) #'ignore))
      (setq org-agenda-kanban--tag-filter '("inc")
            org-agenda-kanban--tag-exclude '("exc"))
      (org-agenda-kanban-remove-tag "inc")
      (should-not (member "inc" org-agenda-kanban--tag-filter))
      (org-agenda-kanban-remove-tag "exc")
      (should-not (member "exc" org-agenda-kanban--tag-exclude)))))

(ert-deftest org-agenda-kanban-test-clear-filters-clears-exclude ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'org-agenda-kanban--apply-filters) #'ignore))
      (setq org-agenda-kanban--tag-filter '("a")
            org-agenda-kanban--tag-exclude '("b")
            org-agenda-kanban--priority-filter ?A)
      (org-agenda-kanban-clear-filters)
      (should-not org-agenda-kanban--tag-filter)
      (should-not org-agenda-kanban--tag-exclude)
      (should-not org-agenda-kanban--priority-filter))))

(ert-deftest org-agenda-kanban-test-chip-face-off-returns-base ()
  (let ((org-agenda-kanban-use-tag-faces nil)
        (org-tag-faces '(("work" . "red"))))
    (should (eq (org-agenda-kanban--chip-face
                 "work" 'org-agenda-kanban-tag)
                'org-agenda-kanban-tag))))

(ert-deftest org-agenda-kanban-test-chip-face-on-unmapped ()
  (let ((org-agenda-kanban-use-tag-faces t)
        (org-tag-faces nil))
    (should (equal (org-agenda-kanban--chip-face
                    "work" 'org-agenda-kanban-tag)
                   (list 'fixed-pitch 'org-tag 'org-agenda-kanban-tag)))))

(ert-deftest org-agenda-kanban-test-chip-face-on-color-mapped ()
  (let ((org-agenda-kanban-use-tag-faces t)
        (org-tag-faces '(("work" . "red"))))
    (let ((result (org-agenda-kanban--chip-face
                   "work" 'org-agenda-kanban-tag-active)))
      ;; fixed-pitch must lead so the per-tag face cannot break the grid.
      (should (eq (car result) 'fixed-pitch))
      ;; the resolved tag spec (a plist) sits between fixed-pitch and base.
      (should (equal (nth 1 result) (org-get-tag-face "work")))
      ;; base stays last so state decoration still applies.
      (should (eq (nth 2 result) 'org-agenda-kanban-tag-active)))))

(ert-deftest org-agenda-kanban-test-filter-priority-explicit ()
  (with-temp-buffer
    (let ((cards (list (org-agenda-kanban-test--card "a" "TODO" nil ?A)
                       (org-agenda-kanban-test--card "b" "TODO" nil ?B)
                       (org-agenda-kanban-test--card "c" "TODO" nil nil))))
      (setq org-agenda-kanban--tag-filter nil
            org-agenda-kanban--tag-exclude nil
            org-agenda-kanban--priority-filter ?A)
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("a")))
      (setq org-agenda-kanban--priority-filter nil)
      (should (= (length (org-agenda-kanban--filtered cards)) 3)))))

(ert-deftest org-agenda-kanban-test-filter-priority-includes-default ()
  "`org-default-priority' cards match the same priority filter as explicit cards."
  (with-temp-buffer
    (let ((cards (list (org-agenda-kanban-test--card "a" "TODO" nil ?A)
                       (org-agenda-kanban-test--card "b" "TODO" nil ?B)
                       (org-agenda-kanban-test--card "none" "TODO" nil nil)))
          (org-default-priority ?B))
      (setq org-agenda-kanban--tag-filter nil
            org-agenda-kanban--tag-exclude nil
            org-agenda-kanban--priority-filter ?B)
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("b" "none"))))))

(ert-deftest org-agenda-kanban-test-filter-priority-custom-default ()
  "Priority filtering respects custom `org-default-priority' values."
  (with-temp-buffer
    (let ((cards (list (org-agenda-kanban-test--card "b" "TODO" nil ?B)
                       (org-agenda-kanban-test--card "none" "TODO" nil nil)
                       (org-agenda-kanban-test--card "c" "TODO" nil ?C)))
          (org-default-priority ?C))
      (setq org-agenda-kanban--tag-filter nil
            org-agenda-kanban--tag-exclude nil
            org-agenda-kanban--priority-filter ?B)
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("b")))
      (setq org-agenda-kanban--priority-filter ?C)
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--filtered cards))
                     '("none" "c"))))))

(ert-deftest org-agenda-kanban-test-cards-for-column ()
  (let ((cards (list (org-agenda-kanban-test--card "a" "TODO" nil nil)
                     (org-agenda-kanban-test--card "b" "STARTED" nil nil)
                     (org-agenda-kanban-test--card "c" "TODO" nil nil)))
        (org-agenda-kanban-sort 'document))
    (should (equal (mapcar #'org-agenda-kanban-card-title
                           (org-agenda-kanban--cards-for-column "TODO" cards))
                   '("a" "c")))
    (should (null (org-agenda-kanban--cards-for-column "DONE" cards)))))

(ert-deftest org-agenda-kanban-test-sort-priority ()
  "`priority' sorting puts higher priorities first and, like org-agenda,
treats an unprioritized card as `org-default-priority' (here ?B), so it
interleaves with explicit [#B] cards; equal-priority cards keep document
order."
  (let ((cards (list (org-agenda-kanban-test--card "none1" "TODO" nil nil)
                     (org-agenda-kanban-test--card "b1" "TODO" nil ?B)
                     (org-agenda-kanban-test--card "a1" "TODO" nil ?A)
                     (org-agenda-kanban-test--card "none2" "TODO" nil nil)
                     (org-agenda-kanban-test--card "a2" "TODO" nil ?A)
                     (org-agenda-kanban-test--card "c1" "TODO" nil ?C)))
        (org-default-priority ?B))
    (let ((org-agenda-kanban-sort 'priority))
      ;; A's first, then the B-rank group (explicit and unprioritized) in
      ;; document order, then C.
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--cards-for-column "TODO" cards))
                     '("a1" "a2" "none1" "b1" "none2" "c1"))))
    ;; Document order leaves the collection order untouched.
    (let ((org-agenda-kanban-sort 'document))
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--cards-for-column "TODO" cards))
                     '("none1" "b1" "a1" "none2" "a2" "c1"))))
    ;; A custom predicate is honored.
    (let ((org-agenda-kanban-sort
           (lambda (x y) (string< (org-agenda-kanban-card-title x)
                                  (org-agenda-kanban-card-title y)))))
      (should (equal (mapcar #'org-agenda-kanban-card-title
                             (org-agenda-kanban--cards-for-column "TODO" cards))
                     '("a1" "a2" "b1" "c1" "none1" "none2"))))))

;;;; Markup rendering

(ert-deftest org-agenda-kanban-test-fontify-title-off ()
  (let ((org-agenda-kanban-render-markup nil))
    (should (equal (org-agenda-kanban--fontify-title "raw *x* text")
                   "raw *x* text"))))

(ert-deftest org-agenda-kanban-test-fontify-title-emphasis ()
  (let ((org-agenda-kanban-render-markup t))
    (let ((s (org-agenda-kanban--fontify-title "has *bold* word")))
      ;; Emphasis markers are dropped, so width matches the display.
      (should (equal (substring-no-properties s) "has bold word"))
      (should (= (string-width s) 13))
      ;; The inner text carries the bold face.
      (let ((f (get-text-property 4 'face s)))
        (should (memq 'bold (if (listp f) f (list f))))))))

(ert-deftest org-agenda-kanban-test-fontify-title-link ()
  (let ((org-agenda-kanban-render-markup t))
    (let ((s (org-agenda-kanban--fontify-title "see [[https://x.org][Docs]] now")))
      ;; The link collapses to its description.
      (should (equal (substring-no-properties s) "see Docs now"))
      ;; Org's link keymap and help-echo must not leak onto the card.
      (should-not (get-text-property 4 'keymap s))
      (should-not (get-text-property 4 'help-echo s)))))

;;;; Priority coloring

(ert-deftest org-agenda-kanban-test-priority-cookie-face ()
  (let ((org-priority-faces '((?A . "#ff0000") (?B . shadow))))
    ;; A color string becomes a foreground laid over our base face.
    (let ((f (org-agenda-kanban--priority-cookie-face ?A)))
      (should (equal f (list '(:foreground "#ff0000")
                             'org-agenda-kanban-priority))))
    ;; A face is applied first, with our base underneath for fixed-pitch.
    (should (equal (org-agenda-kanban--priority-cookie-face ?B)
                   (list 'shadow 'org-agenda-kanban-priority)))
    ;; Unmapped priorities fall back to the plain cookie face.
    (should (eq (org-agenda-kanban--priority-cookie-face ?C)
                'org-agenda-kanban-priority))))

(ert-deftest org-agenda-kanban-test-priority-style-gate ()
  "The [#X] cookie is colored only when the style is non-nil."
  (let* ((org-priority-faces '((?A . "#ff0000")))
         (card (org-agenda-kanban-card-create
                :id "x" :title "Task" :todo "TODO" :priority ?A))
         (cookie-face
          (lambda (style)
            (let* ((org-agenda-kanban-priority-style style)
                   (line (car (org-agenda-kanban--card-lines card 24 nil)))
                   (pos (string-match "\\[#A\\]" line))
                   (face (get-text-property pos 'face line)))
              (if (listp face) face (list face))))))
    ;; A non-nil style colors the cookie: the priority foreground is present.
    (should (member '(:foreground "#ff0000") (funcall cookie-face 'cookie)))
    ;; A nil style leaves the cookie on the plain priority face only.
    (let ((face (funcall cookie-face nil)))
      (should-not (member '(:foreground "#ff0000") face))
      (should (member 'org-agenda-kanban-priority face)))
    ;; The defcustom no longer offers background tinting.
    (should (equal (get 'org-agenda-kanban-priority-style 'custom-type)
                   '(choice (const :tag "Color the priority cookie" cookie)
                            (const :tag "No priority color" nil))))))

(ert-deftest org-agenda-kanban-test-files-custom-type-includes-directories ()
  "The files defcustom accepts both files and directories."
  (should (equal (get 'org-agenda-kanban-files 'custom-type)
                '(choice (const :tag "Use `org-agenda-files'" nil)
                         (repeat (choice (file :tag "File")
                                         (directory :tag "Directory")))))))

;;;; Planning timestamps

(ert-deftest org-agenda-kanban-test-format-timestamp ()
  "Bracket stripping keeps the inner date, time, and any repeater."
  (should (equal (org-agenda-kanban--format-timestamp "<2026-06-02 Tue>")
                 "2026-06-02 Tue"))
  ;; Active timestamp with a repeater.
  (should (equal (org-agenda-kanban--format-timestamp "<2026-06-02 Tue +1w>")
                 "2026-06-02 Tue +1w"))
  ;; Other repeater/offset cookies survive intact.
  (should (equal (org-agenda-kanban--format-timestamp "<2026-06-02 Tue .+1m>")
                 "2026-06-02 Tue .+1m"))
  (should (equal (org-agenda-kanban--format-timestamp "<2026-06-02 Tue ++1y -3d>")
                 "2026-06-02 Tue ++1y -3d"))
  ;; A time range is preserved.
  (should (equal (org-agenda-kanban--format-timestamp "<2026-06-02 Tue 09:00-10:00>")
                 "2026-06-02 Tue 09:00-10:00"))
  ;; Inactive timestamps are handled defensively.
  (should (equal (org-agenda-kanban--format-timestamp "[2026-06-02 Tue]")
                 "2026-06-02 Tue"))
  ;; A timestamp range drops the inner delimiters too.
  (should (equal (org-agenda-kanban--format-timestamp
                  "<2026-06-02 Tue>--<2026-06-03 Wed>")
                 "2026-06-02 Tue--2026-06-03 Wed")))

(ert-deftest org-agenda-kanban-test-planning-raw ()
  "`--planning-raw' preserves repeaters and warning periods from real Org."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (org-mode)
      (insert "* TODO Example\n"
              "SCHEDULED: <2026-06-02 Tue +1w -3d> DEADLINE: <2026-06-09 Tue ++1m>\n")
      (goto-char (point-min))
      (let ((el (org-element-at-point)))
        (should (equal (org-agenda-kanban--planning-raw el :scheduled)
                       "<2026-06-02 Tue +1w -3d>"))
        (should (equal (org-agenda-kanban--planning-raw el :deadline)
                       "<2026-06-09 Tue ++1m>")))))
  ;; A heading with no planning info yields nil for both.
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (org-mode)
      (insert "* TODO Bare\n")
      (goto-char (point-min))
      (let ((el (org-element-at-point)))
        (should-not (org-agenda-kanban--planning-raw el :scheduled))
        (should-not (org-agenda-kanban--planning-raw el :deadline))))))

(ert-deftest org-agenda-kanban-test-planning-lines ()
  "Planning lines render deadline first, then scheduled, gated on the toggle."
  (let* ((org-agenda-kanban-scheduled-glyph "S:")
         (org-agenda-kanban-deadline-glyph "D:")
         (org-agenda-kanban-planning-compact nil)
         (card (org-agenda-kanban-card-create
                :id "x" :title "Task" :todo "TODO"
                :scheduled "<2026-06-02 Tue +1w>"
                :deadline "<2026-06-09 Tue>")))
    ;; Both set: deadline line precedes the scheduled line.
    (let ((org-agenda-kanban-show-planning t))
      (let ((lines (org-agenda-kanban--planning-lines card 40)))
        (should (= (length lines) 2))
        (should (string-prefix-p "D:" (nth 0 lines)))
        (should (string-match-p "2026-06-09 Tue" (nth 0 lines)))
        (should (string-prefix-p "S:" (nth 1 lines)))
        ;; The repeater is preserved on the scheduled line.
        (should (string-match-p (regexp-quote "2026-06-02 Tue +1w") (nth 1 lines)))))
    ;; The toggle suppresses planning entirely.
    (let ((org-agenda-kanban-show-planning nil))
      (should-not (org-agenda-kanban--planning-lines card 40))))
  ;; Neither set: no lines.
  (let ((org-agenda-kanban-show-planning t)
        (card (org-agenda-kanban-card-create
               :id "y" :title "Task" :todo "TODO")))
    (should-not (org-agenda-kanban--planning-lines card 40)))
  ;; Only one set: a single line.
  (let ((org-agenda-kanban-show-planning t)
        (card (org-agenda-kanban-card-create
               :id "z" :title "Task" :todo "TODO"
               :scheduled "<2026-06-02 Tue>")))
    (should (= (length (org-agenda-kanban--planning-lines card 40)) 1))))

(ert-deftest org-agenda-kanban-test-default-glyph-widths ()
  "Default planning glyphs are pure ASCII for a deterministic grid width.
A non-ASCII default (emoji, or any symbol absent from the user's
fixed-pitch font) is drawn from a fallback font whose pixel advance does
not align to the monospace card grid, which misaligns the timestamp.
ASCII chars are guaranteed to render in the fixed-pitch font, so guard
against regressing the defaults to non-ASCII."
  (dolist (glyph (list org-agenda-kanban-scheduled-glyph
                       org-agenda-kanban-deadline-glyph))
    (dolist (ch (string-to-list glyph))
      ;; Each char must be ASCII (< 128) so it lives in the fixed-pitch font.
      (should (< ch 128)))))

(ert-deftest org-agenda-kanban-test-header-chip-portable-defaults ()
  "Header filter chips default to ASCII-only labels."
  (with-temp-buffer
    (setq org-agenda-kanban--tag-filter '("work")
          org-agenda-kanban--tag-exclude '("home")
          org-agenda-kanban--priority-filter ?A
          org-agenda-kanban--done-window 7)
    (let ((header (substring-no-properties (org-agenda-kanban--header-line))))
      (should (string-match-p (regexp-quote "+#work x") header))
      (should (string-match-p (regexp-quote "-#home x") header))
      (should (string-match-p (regexp-quote "[#A] x") header))
      (should (string-match-p (regexp-quote "done <=7d x") header))
      (dolist (ch (string-to-list header))
        (should (< ch 128))))))

(ert-deftest org-agenda-kanban-test-header-chip-custom-glyphs ()
  "Header filter chips honor custom glyph variables."
  (with-temp-buffer
    (let ((org-agenda-kanban-header-remove-glyph "[rm]")
          (org-agenda-kanban-header-done-window-prefix "within ")
          (org-agenda-kanban--done-window 3))
      (let ((header (substring-no-properties (org-agenda-kanban--header-line))))
        (should (string-match-p (regexp-quote "done within 3d [rm]")
                                header))))))

(ert-deftest org-agenda-kanban-test-strip-weekday ()
  "`--strip-weekday' drops the day name but keeps time, repeater, warning."
  ;; Date + weekday only.
  (should (equal (org-agenda-kanban--strip-weekday "2026-06-02 Tue")
                 "2026-06-02"))
  ;; Date + weekday + time.
  (should (equal (org-agenda-kanban--strip-weekday "2026-06-03 Wed 11:00")
                 "2026-06-03 11:00"))
  ;; Date + weekday + time + repeater + warning.
  (should (equal (org-agenda-kanban--strip-weekday "2026-06-03 Wed 11:00 +1w -3d")
                 "2026-06-03 11:00 +1w -3d"))
  ;; A non-ASCII (localised) weekday is still dropped.
  (should (equal (org-agenda-kanban--strip-weekday "2026-06-03 木 11:00")
                 "2026-06-03 11:00"))
  ;; A locale weekday abbreviation ending in a period is still dropped.
  (should (equal (org-agenda-kanban--strip-weekday "2026-06-03 mer. 11:00")
                 "2026-06-03 11:00"))
  ;; No weekday present: returned unchanged.
  (should (equal (org-agenda-kanban--strip-weekday "2026-06-03 11:00")
                 "2026-06-03 11:00"))
  ;; A range is left intact (no corruption of the second date).
  (should (equal (org-agenda-kanban--strip-weekday "2026-06-02 Tue--2026-06-03 Wed")
                 "2026-06-02 Tue--2026-06-03 Wed"))
  ;; A diary sexp timestamp (no ISO date prefix) is left intact.
  (should (equal (org-agenda-kanban--strip-weekday "%%(diary-float t 4 2)")
                 "%%(diary-float t 4 2)")))

(ert-deftest org-agenda-kanban-test-planning-compact ()
  "`org-agenda-kanban-planning-compact' toggles weekday display."
  (let* ((org-agenda-kanban-scheduled-glyph "S:")
         (card (org-agenda-kanban-card-create
                :id "c" :title "Task" :todo "TODO"
                :scheduled "<2026-06-03 Wed 11:00 +1w>"))
         (org-agenda-kanban-show-planning t))
    ;; Compact (default): the weekday is gone, the repeater stays.
    (let* ((org-agenda-kanban-planning-compact t)
           (line (car (org-agenda-kanban--planning-lines card 40))))
      (should (string-match-p (regexp-quote "2026-06-03 11:00 +1w") line))
      (should-not (string-match-p "Wed" line)))
    ;; Disabled: the weekday is preserved.
    (let* ((org-agenda-kanban-planning-compact nil)
           (line (car (org-agenda-kanban--planning-lines card 40))))
      (should (string-match-p (regexp-quote "2026-06-03 Wed 11:00 +1w") line)))))

(ert-deftest org-agenda-kanban-test-planning-lines-in-card ()
  "Planning lines appear between the title and the tags in a rendered card."
  (let* ((org-agenda-kanban-show-planning t)
         (org-agenda-kanban-scheduled-glyph "S:")
         (org-agenda-kanban-deadline-glyph "D:")
         (card (org-agenda-kanban-card-create
                :id "x" :title "Task" :todo "TODO" :tags '("work")
                :scheduled "<2026-06-02 Tue +1w>"
                :deadline "<2026-06-09 Tue>"))
         (lines (org-agenda-kanban--card-lines card 30 nil))
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

(defun org-agenda-kanban-test--closed (days-ago)
  "Return a CLOSED inactive timestamp string DAYS-AGO days in the past."
  (format-time-string "[%Y-%m-%d %a %H:%M]"
                      (time-subtract (current-time) (* days-ago 86400))))

(ert-deftest org-agenda-kanban-test-show-entry-p ()
  (let ((org-todo-keywords '((sequence "TODO" "|" "DONE" "CANCELLED"))))
    (with-temp-buffer
      (insert "* TODO active\n"
              "* DONE recent\n  CLOSED: " (org-agenda-kanban-test--closed 1) "\n"
              "* DONE old\n  CLOSED: " (org-agenda-kanban-test--closed 30) "\n"
              "* DONE undated\n"
              "* CANCELLED old cancel\n  CLOSED: "
              (org-agenda-kanban-test--closed 30) "\n")
      (org-mode)
      (let ((now (current-time))
            (results '()))
        (org-map-entries
         (lambda ()
           (push (cons (org-get-heading t t t t)
                       (and (org-agenda-kanban--show-entry-p
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
             (push (org-agenda-kanban--show-entry-p
                    (org-get-todo-state) nil now)
                   all)))
          (should (cl-every #'identity all)))))))

;;;; Direct card editing

(defun org-agenda-kanban-test--file-contents (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun org-agenda-kanban-test--kill-file-buffer (file)
  "Kill FILE's visiting buffer without saving test changes."
  (when-let ((buf (find-buffer-visiting file)))
    (with-current-buffer buf (set-buffer-modified-p nil))
    (kill-buffer buf)))

(defun org-agenda-kanban-test--card-by-title (title)
  "Return the collected card with TITLE."
  (cl-find title org-agenda-kanban--cards
           :key #'org-agenda-kanban-card-title
           :test #'equal))

(ert-deftest org-agenda-kanban-test-set-todo-keeps-clean-source-unsaved ()
  "`--set-todo' leaves its Org change unsaved like Org Agenda."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (org-log-done nil)
         (file (make-temp-file "okm-set-todo" nil ".org"
                               "* TODO write tests\n")))
    (unwind-protect
        (let ((org-agenda-kanban-files (list file))
              (org-agenda-kanban-columns '("TODO" "DONE")))
          (with-temp-buffer
            (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
            (org-agenda-kanban--set-todo
             (org-agenda-kanban-test--card-by-title "write tests")
             "DONE")
            (should (equal (org-agenda-kanban-test--file-contents file)
                           "* TODO write tests\n"))
            (with-current-buffer (find-buffer-visiting file)
              (should (buffer-modified-p))
              (should (string-match-p "\\`\\* DONE write tests\n\\'"
                                      (buffer-string))))))
      (org-agenda-kanban-test--kill-file-buffer file)
      (delete-file file))))

(ert-deftest org-agenda-kanban-test-set-todo-keeps-dirty-source-unsaved ()
  "`--set-todo' does not save unrelated pre-existing source edits."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (org-log-done nil)
         (file (make-temp-file "okm-set-todo-dirty" nil ".org"
                               "* TODO write tests\n")))
    (unwind-protect
        (let ((org-agenda-kanban-files (list file))
              (org-agenda-kanban-columns '("TODO" "DONE")))
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-max))
            (insert "Unrelated draft note.\n"))
          (with-temp-buffer
            (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
            (org-agenda-kanban--set-todo
             (org-agenda-kanban-test--card-by-title "write tests")
             "DONE"))
          (should (equal (org-agenda-kanban-test--file-contents file)
                         "* TODO write tests\n"))
          (with-current-buffer (find-buffer-visiting file)
            (should (buffer-modified-p))
            (should (string-match-p "\\`\\* DONE write tests\n"
                                    (buffer-string)))
            (should (string-match-p "Unrelated draft note"
                                    (buffer-string)))))
      (org-agenda-kanban-test--kill-file-buffer file)
      (delete-file file))))

(ert-deftest org-agenda-kanban-test-edit-at-card ()
  "`--edit-at-card' edits a clean source heading and re-collects.
The selection (stable ID) survives the edit."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (file (make-temp-file "okm-edit" nil ".org"
                               "* TODO write tests\n")))
    (unwind-protect
        (let ((org-agenda-kanban-files (list file))
              (org-agenda-kanban-columns '("TODO" "DONE")))
          (with-temp-buffer
            ;; Stand up just enough board state for the helper, and keep
            ;; rendering headless by stubbing the redraw.
            (cl-letf (((symbol-function 'org-agenda-kanban--render)
                       #'ignore))
              (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
              (should (= (length org-agenda-kanban--cards) 1))
              (setq org-agenda-kanban--selected-id
                    (org-agenda-kanban-card-id (car org-agenda-kanban--cards)))
              (let ((edited (org-agenda-kanban--edit-at-card
                             (lambda () (org-priority ?A)))))
                ;; The helper returns the (pre-edit) selected card.
                (should (equal (org-agenda-kanban-card-title edited)
                               "write tests"))
                ;; The change stays in the source buffer, matching Org Agenda.
                (should (equal (org-agenda-kanban-test--file-contents file)
                               "* TODO write tests\n"))
                (with-current-buffer (find-buffer-visiting file)
                  (should (buffer-modified-p))
                  (should (string-match-p "\\[#A\\]" (buffer-string))))
                ;; The board was re-collected with the new priority, and the
                ;; selection survived because the ID is stable.
                (let ((card (org-agenda-kanban--selected-card)))
                  (should card)
                  (should (eq (org-agenda-kanban-card-priority card) ?A)))))))
      (org-agenda-kanban-test--kill-file-buffer file)
      (delete-file file))))

(ert-deftest org-agenda-kanban-test-edit-at-card-keeps-dirty-source-unsaved ()
  "`--edit-at-card' does not save unrelated pre-existing source edits."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (file (make-temp-file "okm-edit-dirty" nil ".org"
                               "* TODO write tests\n")))
    (unwind-protect
        (let ((org-agenda-kanban-files (list file))
              (org-agenda-kanban-columns '("TODO" "DONE")))
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-max))
            (insert "Unrelated draft note.\n"))
          (with-temp-buffer
            (cl-letf (((symbol-function 'org-agenda-kanban--render)
                       #'ignore))
              (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
              (setq org-agenda-kanban--selected-id
                    (org-agenda-kanban-card-id
                     (org-agenda-kanban-test--card-by-title "write tests")))
              (org-agenda-kanban--edit-at-card
               (lambda () (org-priority ?A)))
              (let ((card (org-agenda-kanban--selected-card)))
                (should card)
                (should (eq (org-agenda-kanban-card-priority card) ?A)))))
          (should (equal (org-agenda-kanban-test--file-contents file)
                         "* TODO write tests\n"))
          (with-current-buffer (find-buffer-visiting file)
            (should (buffer-modified-p))
            (should (string-match-p "\\[#A\\]" (buffer-string)))
            (should (string-match-p "Unrelated draft note"
                                    (buffer-string)))))
      (org-agenda-kanban-test--kill-file-buffer file)
      (delete-file file))))

;;;; Priority up / down commands

(ert-deftest org-agenda-kanban-test-priority-up-raises-priority ()
  "`priority-up' on a [#B] card raises it toward [#A], like `org-agenda'."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (file (make-temp-file "okm-prio-up" nil ".org"
                               "* TODO [#B] write tests\n")))
    (unwind-protect
        (let ((org-agenda-kanban-files (list file))
              (org-agenda-kanban-columns '("TODO" "DONE")))
          (with-temp-buffer
            (cl-letf (((symbol-function 'org-agenda-kanban--render) #'ignore))
              (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
              (setq org-agenda-kanban--selected-id
                    (org-agenda-kanban-card-id (car org-agenda-kanban--cards)))
              (org-agenda-kanban-priority-up)
              (let ((card (org-agenda-kanban--selected-card)))
                (should card)
                (should (eq (org-agenda-kanban-card-priority card) ?A))))))
      (org-agenda-kanban-test--kill-file-buffer file)
      (delete-file file))))

(ert-deftest org-agenda-kanban-test-priority-down-lowers-priority ()
  "`priority-down' on a [#B] card lowers it toward [#C], like `org-agenda'."
  (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
         (file (make-temp-file "okm-prio-down" nil ".org"
                               "* TODO [#B] write tests\n")))
    (unwind-protect
        (let ((org-agenda-kanban-files (list file))
              (org-agenda-kanban-columns '("TODO" "DONE")))
          (with-temp-buffer
            (cl-letf (((symbol-function 'org-agenda-kanban--render) #'ignore))
              (setq org-agenda-kanban--cards (org-agenda-kanban--collect))
              (setq org-agenda-kanban--selected-id
                    (org-agenda-kanban-card-id (car org-agenda-kanban--cards)))
              (org-agenda-kanban-priority-down)
              (let ((card (org-agenda-kanban--selected-card)))
                (should card)
                (should (eq (org-agenda-kanban-card-priority card) ?C))))))
      (org-agenda-kanban-test--kill-file-buffer file)
      (delete-file file))))

(ert-deftest org-agenda-kanban-test-priority-keys-bound ()
  "`+' and `-' invoke priority-up / priority-down in the kanban map."
  (should (eq (lookup-key org-agenda-kanban-mode-map "+")
              #'org-agenda-kanban-priority-up))
  (should (eq (lookup-key org-agenda-kanban-mode-map "-")
              #'org-agenda-kanban-priority-down)))

(ert-deftest org-agenda-kanban-test-follow-key-bound ()
  "`F' toggles kanban follow-mode."
  (should (eq (lookup-key org-agenda-kanban-mode-map "F")
              #'org-agenda-kanban-follow-mode)))

(ert-deftest org-agenda-kanban-test-follow-mode-toggle ()
  "`org-agenda-kanban-follow-mode' toggles buffer-local follow state."
  (with-temp-buffer
    (let ((calls 0))
      (cl-letf (((symbol-function 'org-agenda-kanban--follow-selection)
                 (lambda () (setq calls (1+ calls)))))
        (should-not org-agenda-kanban--follow-mode)
        (org-agenda-kanban-follow-mode)
        (should org-agenda-kanban--follow-mode)
        (should (= calls 1))
        (org-agenda-kanban-follow-mode -1)
        (should-not org-agenda-kanban--follow-mode)
        (should (= calls 2))))))

(ert-deftest org-agenda-kanban-test-follow-mode-select-previews-card ()
  "Selecting a card previews it when follow-mode is active."
  (let ((card (org-agenda-kanban-card-create
               :id "card" :title "Task" :todo "TODO")))
    (with-temp-buffer
      (let ((org-agenda-kanban-column-width 12)
            (org-agenda-kanban-column-gap 0)
            (org-agenda-kanban-columns '("TODO"))
            (org-agenda-kanban--cards (list card))
            (org-agenda-kanban--visible (list card))
            (org-agenda-kanban--selected-id "card")
            (org-agenda-kanban--follow-mode t)
            (calls 0))
        (cl-letf (((symbol-function 'org-agenda-kanban--follow-selection)
                   (lambda () (setq calls (1+ calls)))))
          (org-agenda-kanban--select "card")
          (should (= calls 1)))))))

(ert-deftest org-agenda-kanban-test-follow-highlights-source-row ()
  "Follow-mode marks the selected card's heading line in the source buffer."
  (org-agenda-kanban--follow-unhighlight)
  (unwind-protect
      (with-temp-buffer
        (insert "* TODO Task\n  body\n* TODO Other\n")
        (org-mode)
        (let ((org-agenda-kanban--follow-mode t)
              (src (current-buffer)))
          (cl-letf (((symbol-function 'recenter) #'ignore)
                    ((symbol-function 'switch-to-buffer-other-window)
                     (lambda (buf &rest _) (set-buffer buf)))
                    ((symbol-function 'pop-to-buffer-same-window)
                     (lambda (buf &rest _) (set-buffer buf))))
            (org-agenda-kanban--show-heading (cons src (point-min)) nil))
          (should (overlayp org-agenda-kanban--follow-overlay))
          (should (eq (overlay-buffer org-agenda-kanban--follow-overlay) src))
          (should (eq (overlay-get org-agenda-kanban--follow-overlay 'face)
                      'highlight))
          ;; The overlay spans the first heading line, not the body or the
          ;; second heading.
          (goto-char (overlay-start org-agenda-kanban--follow-overlay))
          (should (looking-at-p "\\* TODO Task"))
          (should (= (overlay-end org-agenda-kanban--follow-overlay)
                     (line-end-position)))))
    (org-agenda-kanban--follow-unhighlight)))

(ert-deftest org-agenda-kanban-test-follow-no-highlight-when-disabled ()
  "Without follow-mode, showing a heading leaves no source highlight."
  (org-agenda-kanban--follow-unhighlight)
  (unwind-protect
      (with-temp-buffer
        (insert "* TODO Task\n")
        (org-mode)
        (let ((org-agenda-kanban--follow-mode nil)
              (src (current-buffer)))
          (cl-letf (((symbol-function 'recenter) #'ignore)
                    ((symbol-function 'pop-to-buffer-same-window)
                     (lambda (buf &rest _) (set-buffer buf))))
            (org-agenda-kanban--show-heading (cons src (point-min)) nil))
          (should-not (and (overlayp org-agenda-kanban--follow-overlay)
                           (overlay-buffer org-agenda-kanban--follow-overlay)))))
    (org-agenda-kanban--follow-unhighlight)))

(ert-deftest org-agenda-kanban-test-follow-mode-disable-clears-highlight ()
  "Disabling follow-mode removes the source-buffer highlight."
  (with-temp-buffer
    (setq org-agenda-kanban--follow-overlay
          (make-overlay (point-min) (point-max)))
    (let ((org-agenda-kanban--follow-mode t))
      (cl-letf (((symbol-function 'org-agenda-kanban--follow-selection) #'ignore))
        (org-agenda-kanban-follow-mode -1)))
    (should-not (overlay-buffer org-agenda-kanban--follow-overlay))))

(ert-deftest org-agenda-kanban-test-follow-selection-clears-when-empty ()
  "Follow-mode drops the highlight when nothing is selected."
  (with-temp-buffer
    (setq org-agenda-kanban--follow-overlay
          (make-overlay (point-min) (point-max)))
    (let ((org-agenda-kanban--follow-mode t)
          (org-agenda-kanban--selected-id nil)
          (org-agenda-kanban--cards nil))
      (org-agenda-kanban--follow-selection))
    (should-not (overlay-buffer org-agenda-kanban--follow-overlay))))

(ert-deftest org-agenda-kanban-test-quit-key-bound ()
  "`q' buries the board via the highlight-clearing quit command."
  (should (eq (lookup-key org-agenda-kanban-mode-map "q")
              #'org-agenda-kanban-quit)))

(ert-deftest org-agenda-kanban-test-quit-clears-highlight ()
  "`org-agenda-kanban-quit' removes the follow highlight before burying."
  (with-temp-buffer
    (setq org-agenda-kanban--follow-overlay
          (make-overlay (point-min) (point-max)))
    (cl-letf (((symbol-function 'quit-window) #'ignore))
      (org-agenda-kanban-quit))
    (should-not (overlay-buffer org-agenda-kanban--follow-overlay))))

(ert-deftest org-agenda-kanban-test-agenda-aligned-keys-bound ()
  "Top-level keys mirror Org Agenda: `t' sets TODO, `s' saves, etc."
  (should (eq (lookup-key org-agenda-kanban-mode-map "t")
              #'org-agenda-kanban-set-todo))
  (should (eq (lookup-key org-agenda-kanban-mode-map "s")
              #'org-save-all-org-buffers))
  (should (eq (lookup-key org-agenda-kanban-mode-map "g")
              #'org-agenda-kanban-refresh))
  (should (eq (lookup-key org-agenda-kanban-mode-map "r")
              #'org-agenda-kanban-refresh))
  (should (eq (lookup-key org-agenda-kanban-mode-map "k")
              #'org-capture))
  (should (eq (lookup-key org-agenda-kanban-mode-map "c")
              #'org-capture)))

(ert-deftest org-agenda-kanban-test-filter-prefix-bound ()
  "Tag/priority filters live under the `/' prefix, with `\\' as a shortcut."
  (should (eq (lookup-key org-agenda-kanban-mode-map "/t")
              #'org-agenda-kanban-toggle-tag))
  (should (eq (lookup-key org-agenda-kanban-mode-map "/+")
              #'org-agenda-kanban-include-tag))
  (should (eq (lookup-key org-agenda-kanban-mode-map "/-")
              #'org-agenda-kanban-exclude-tag))
  (should (eq (lookup-key org-agenda-kanban-mode-map "/r")
              #'org-agenda-kanban-remove-tag))
  (should (eq (lookup-key org-agenda-kanban-mode-map "/p")
              #'org-agenda-kanban-filter-by-priority))
  (should (eq (lookup-key org-agenda-kanban-mode-map "/c")
              #'org-agenda-kanban-clear-filters))
  (should (eq (lookup-key org-agenda-kanban-mode-map "/d")
              #'org-agenda-kanban-set-done-window))
  (should (eq (lookup-key org-agenda-kanban-mode-map "\\")
              #'org-agenda-kanban-toggle-tag)))

(ert-deftest org-agenda-kanban-test-old-tag-prefix-removed ()
  "The legacy `t' tag-filter prefix no longer shadows the `t' TODO key."
  (should-not (eq (lookup-key org-agenda-kanban-mode-map "tt")
                  #'org-agenda-kanban-toggle-tag))
  (should-not (keymapp (lookup-key org-agenda-kanban-mode-map "t"))))

(provide 'org-agenda-kanban-test)
;;; org-agenda-kanban-test.el ends here
