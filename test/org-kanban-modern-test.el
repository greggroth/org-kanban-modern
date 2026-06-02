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
                     (org-kanban-modern-test--card "c" "TODO" nil nil))))
    (should (equal (mapcar #'org-kanban-modern-card-title
                           (org-kanban-modern--cards-for-column "TODO" cards))
                   '("a" "c")))
    (should (null (org-kanban-modern--cards-for-column "DONE" cards)))))

(provide 'org-kanban-modern-test)
;;; org-kanban-modern-test.el ends here
