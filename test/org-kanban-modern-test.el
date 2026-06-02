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

(ert-deftest org-kanban-modern-test-edit-at-card ()
  "`--edit-at-card' edits the source heading, saves, and re-collects.
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
                ;; The change was written back to disk.
                (with-temp-buffer
                  (insert-file-contents file)
                  (should (string-match-p "\\[#A\\]" (buffer-string))))
                ;; The board was re-collected with the new priority, and the
                ;; selection survived because the ID is stable.
                (let ((card (org-kanban-modern--selected-card)))
                  (should card)
                  (should (eq (org-kanban-modern-card-priority card) ?A)))))))
      (when-let ((buf (find-buffer-visiting file)))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (delete-file file))))

(provide 'org-kanban-modern-test)
;;; org-kanban-modern-test.el ends here
