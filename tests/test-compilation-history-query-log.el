;;; test-compilation-history-query-log.el --- Tests for the compilation-history query log -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jonathan Otsuka

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Tests for `compilation-history-query-log-mode'.

;;; Code:

(require 'ert)
(require 'compilation-history)
(require 'compilation-history-test-helper)

(defun compilation-history-test--kill-query-log ()
  "Kill the query log buffer if it exists."
  (when (get-buffer "*compilation-history queries*")
    (kill-buffer "*compilation-history queries*")))

(defmacro compilation-history-test-with-query-log (enabled &rest body)
  "Run BODY with `compilation-history-query-log-mode' bound to ENABLED.
Kills the query log buffer before and after BODY."
  (declare (indent 1) (debug t))
  `(let ((compilation-history-query-log-mode ,enabled))
     (compilation-history-test--kill-query-log)
     (unwind-protect
         (progn ,@body)
       (compilation-history-test--kill-query-log))))

(defun compilation-history-test--query-log-entries ()
  "Return the query log as (SUMMARY METHOD PARAMS) lists, oldest first.
METHOD is `match' for an FTS query, `like' for a LIKE query, else nil.
PARAMS is the text after \"-- params: \", or nil when the entry has none."
  (with-current-buffer "*compilation-history queries*"
    (mapcar
     (lambda (entry)
       (pcase-let ((`(,header ,sql ,params) (split-string entry "\n")))
         (list (and (string-match "\\`-- [0-9:]\\{8\\}  \\(.+\\)  [0-9.]+ ms\\'" header)
                    (match-string 1 header))
               (cond ((string-search "MATCH ?" sql) 'match)
                     ((string-search "LIKE ?" sql) 'like))
               (and params (string-remove-prefix "-- params: " params)))))
     (split-string (buffer-string) "\n\n" t))))

(ert-deftest test-compilation-history--query-log-records-search-queries ()
  "With the query log on, FTS searches log their SQL, params, and result size."
  (compilation-history-test-with-db
    (compilation-history-test-with-query-log t
      (compilation-history--ensure-db)
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record :command "make test"))
      (compilation-history--count-records-fts "make")
      (compilation-history--query-page-fts 10 0 "make")
      (should (get-buffer "*compilation-history queries*"))
      (should (equal (compilation-history-test--query-log-entries)
                     '(("count 1" match "[\"make\"]")
                       ("1 row" match "[\"make\" 10 0]")))))))

(ert-deftest test-compilation-history--query-log-records-browse-queries ()
  "Unfiltered queries log no params line and never log row contents."
  (compilation-history-test-with-db
    (compilation-history-test-with-query-log t
      (compilation-history--ensure-db)
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record :record-id "20260321T120000000001"))
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0 "build output here")
      (compilation-history--count-records)
      (compilation-history--query-page 10 0)
      (compilation-history--get-output "20260321T120000000001")
      (should (get-buffer "*compilation-history queries*"))
      (should (equal (compilation-history-test--query-log-entries)
                     '(("count 1" nil nil)
                       ("1 row" nil "[10 0]")
                       ("1 row" nil "[\"20260321T120000000001\"]"))))
      (should-not (string-search "build output here"
                                 (with-current-buffer "*compilation-history queries*"
                                   (buffer-string)))))))

(ert-deftest test-compilation-history--query-log-off-creates-no-buffer ()
  "With the query log off, searching creates no log buffer."
  (compilation-history-test-with-db
    (compilation-history-test-with-query-log nil
      (compilation-history--ensure-db)
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record :command "make test"))
      (compilation-history--count-records-fts "make")
      (compilation-history--query-page-fts 10 0 "make")
      (should-not (get-buffer "*compilation-history queries*")))))

(ert-deftest test-compilation-history--query-log-shows-like-fallback ()
  "An FTS query that fails on special characters logs 0 rows, then its LIKE fallback."
  (compilation-history-test-with-db
    (compilation-history-test-with-query-log t
      (compilation-history--ensure-db)
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record
        :record-id "20260321T120000000001"
        :command "aws s3 ls s3://my-bucket"))
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0 "listing objects..." nil)
      (compilation-history--count-records-fts "s3://")
      (compilation-history--query-page-fts 10 0 "s3://")
      (should (get-buffer "*compilation-history queries*"))
      (should (equal (mapcar (lambda (entry) (take 2 entry))
                             (compilation-history-test--query-log-entries))
                     '(("0 rows" match)
                       ("count 1" like)
                       ("0 rows" match)
                       ("1 row" like)))))))

(provide 'test-compilation-history-query-log)
;;; test-compilation-history-query-log.el ends here
