;;; test-compilation-history-view.el --- Tests for compilation-history-view -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jonathan Otsuka

;;; Commentary:
;; Tests for compilation-history-view.el

;;; Code:

(require 'ert)
(require 'compilation-history-view)

(ert-deftest test-compilation-history-view-pagination-total-pages ()
  "Total pages is correctly derived from total-records and page-size."
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 0 :page-size 25)))
    (should (= (compilation-history-view--total-pages pag) 1)))
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 25 :page-size 25)))
    (should (= (compilation-history-view--total-pages pag) 1)))
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 26 :page-size 25)))
    (should (= (compilation-history-view--total-pages pag) 2)))
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 100 :page-size 25)))
    (should (= (compilation-history-view--total-pages pag) 4))))

(ert-deftest test-compilation-history-view-pagination-offset ()
  "Offset is correctly computed from current-page and page-size."
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 100 :page-size 25)))
    (should (= (compilation-history-view--page-offset pag) 0)))
  (let ((pag (make-compilation-history-view-pagination
              :current-page 3 :total-records 100 :page-size 25)))
    (should (= (compilation-history-view--page-offset pag) 50))))

(provide 'test-compilation-history-view)
;;; test-compilation-history-view.el ends here
