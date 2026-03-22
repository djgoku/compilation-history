;;; test-compilation-history-db.el --- Tests for compilation-history database functions -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jonathan Otsuka

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Tests for database query functions in compilation-history.el

;;; Code:

(require 'ert)
(require 'compilation-history)
(require 'compilation-history-test-helper)

(ert-deftest test-compilation-history--count-records ()
  "Count records returns correct count."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (should (= (compilation-history--count-records) 0))
    (let ((record (compilation-history-test--make-record
                   :record-id "20260321T120000000001")))
      (compilation-history--insert-compilation-record record)
      (should (= (compilation-history--count-records) 1)))))

(ert-deftest test-compilation-history--query-page ()
  "Query page returns records with limit and offset."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    ;; Insert 3 records with different timestamps
    (dolist (id '("20260321T120000000001" "20260321T120000000002" "20260321T120000000003"))
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record :record-id id)))
    ;; Page 1, size 2
    (let ((page (compilation-history--query-page 2 0)))
      (should (= (length page) 2)))
    ;; Page 2, size 2
    (let ((page (compilation-history--query-page 2 2)))
      (should (= (length page) 1)))
    ;; Empty page
    (let ((page (compilation-history--query-page 2 10)))
      (should (= (length page) 0)))))

(ert-deftest test-compilation-history--get-output ()
  "Get output returns the stored output for a record."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let* ((record (compilation-history-test--make-record
                    :record-id "20260321T120000000001")))
      (compilation-history--insert-compilation-record record)
      (compilation-history--update-compilation-record "20260321T120000000001" 0 "build output here")
      (should (equal (compilation-history--get-output "20260321T120000000001")
                     "build output here"))
      ;; Non-existent ID
      (should-not (compilation-history--get-output "nonexistent")))))

(provide 'test-compilation-history-db)
;;; test-compilation-history-db.el ends here
