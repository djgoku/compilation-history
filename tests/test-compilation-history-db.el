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

;;; FTS5 tests

(ert-deftest test-compilation-history--fts-table-created ()
  "FTS5 virtual table is created by ensure-db."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((db (sqlite-open compilation-history-db-file)))
      (unwind-protect
          (let ((tables (sqlite-select db "SELECT name FROM sqlite_master WHERE type='table' AND name='compilations_fts'")))
            (should (equal (caar tables) "compilations_fts")))
        (sqlite-close db)))))

(ert-deftest test-compilation-history--fts-triggers-created ()
  "FTS5 sync triggers are created by ensure-db."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((db (sqlite-open compilation-history-db-file)))
      (unwind-protect
          (let ((triggers (sqlite-select db "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name")))
            (should (= (length triggers) 3))
            (should (equal (caar triggers) "compilations_fts_delete"))
            (should (equal (car (nth 1 triggers)) "compilations_fts_insert"))
            (should (equal (car (nth 2 triggers)) "compilations_fts_update")))
        (sqlite-close db)))))

(ert-deftest test-compilation-history--fts-search-finds-records ()
  "FTS5 search returns matching records by full word."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    ;; Insert records with different commands
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :command "make test"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :command "npm run build"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000003"
      :command "make clean"))
    ;; FTS search for "make"
    (let ((db (sqlite-open compilation-history-db-file)))
      (unwind-protect
          (let ((results (sqlite-select db
                           "SELECT compile_command FROM compilations WHERE rowid IN (SELECT rowid FROM compilations_fts WHERE compilations_fts MATCH ?)"
                           ["make"])))
            (should (= (length results) 2))
            (should (cl-every (lambda (r) (string-match-p "make" (car r))) results)))
        (sqlite-close db)))))

(ert-deftest test-compilation-history--fts-substring-search ()
  "FTS5 trigram tokenizer supports substring matching."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :command "make test"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :command "npm run build"))
    ;; Substring search for "ake" should match "make test"
    (let ((db (sqlite-open compilation-history-db-file)))
      (unwind-protect
          (let ((results (sqlite-select db
                           "SELECT compile_command FROM compilations WHERE rowid IN (SELECT rowid FROM compilations_fts WHERE compilations_fts MATCH ?)"
                           ["ake"])))
            (should (= (length results) 1))
            (should (string-match-p "make" (caar results))))
        (sqlite-close db)))))

(ert-deftest test-compilation-history--fts-auto-syncs-on-insert ()
  "FTS index is automatically updated when records are inserted."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((db (sqlite-open compilation-history-db-file)))
      (unwind-protect
          (progn
            ;; Initially empty
            (should (= (caar (sqlite-select db "SELECT COUNT(*) FROM compilations_fts")) 0))
            ;; Insert a record
            (compilation-history--insert-compilation-record
             (compilation-history-test--make-record
              :record-id "20260321T120000000001"
              :command "cargo test"))
            ;; FTS should have it
            (let ((results (sqlite-select db
                             "SELECT * FROM compilations_fts WHERE compilations_fts MATCH ?"
                             ["cargo"])))
              (should (= (length results) 1))))
        (sqlite-close db)))))

(ert-deftest test-compilation-history--fts-output-search ()
  "FTS5 can search in compilation output."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :command "make test"))
    (compilation-history--update-compilation-record
     "20260321T120000000001" 1 "error: undefined reference to foo")
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :command "make build"))
    (compilation-history--update-compilation-record
     "20260321T120000000002" 0 "Build successful")
    ;; Search output for "undefined"
    (let ((db (sqlite-open compilation-history-db-file)))
      (unwind-protect
          (let ((results (sqlite-select db
                           "SELECT c.compile_command FROM compilations c WHERE c.rowid IN (SELECT rowid FROM compilations_fts WHERE output MATCH ?)"
                           ["undefined"])))
            (should (= (length results) 1))
            (should (equal (caar results) "make test")))
        (sqlite-close db)))))

(ert-deftest test-compilation-history--fts-column-specific-search ()
  "FTS5 supports column-specific searches."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :command "make test"
      :compile-directory "/tmp/project-a/"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :command "npm run test"
      :compile-directory "/tmp/project-b/"))
    ;; Search only in compile_command for "make"
    (let ((db (sqlite-open compilation-history-db-file)))
      (unwind-protect
          (let ((results (sqlite-select db
                           "SELECT c.compile_command FROM compilations c WHERE c.rowid IN (SELECT rowid FROM compilations_fts WHERE compile_command MATCH ?)"
                           ["make"])))
            (should (= (length results) 1))
            (should (equal (caar results) "make test")))
        (sqlite-close db)))))

;;; FTS query function tests

(ert-deftest test-compilation-history--count-records-fts ()
  "FTS count returns correct count for matching records."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :command "make test"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :command "npm run build"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000003"
      :command "make clean"))
    (should (= (compilation-history--count-records-fts "make") 2))
    (should (= (compilation-history--count-records-fts "npm") 1))
    (should (= (compilation-history--count-records-fts "nonexistent") 0))))

(ert-deftest test-compilation-history--query-page-fts ()
  "FTS page query returns matching records with pagination."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :command "make test"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :command "npm run build"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000003"
      :command "make clean"))
    ;; Search for "make" with pagination
    (let ((page (compilation-history--query-page-fts 1 0 "make")))
      (should (= (length page) 1)))
    (let ((page (compilation-history--query-page-fts 10 0 "make")))
      (should (= (length page) 2)))))

;;; LIKE fallback tests

(ert-deftest test-compilation-history--short-search-uses-like ()
  "Search terms shorter than 3 chars fall back to LIKE."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :command "echo date pwd ls"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :command "make test"))
    ;; "ls" is 2 chars — should use LIKE and find it
    (should (= (compilation-history--count-records-fts "ls") 1))
    ;; "pw" is 2 chars
    (should (= (compilation-history--count-records-fts "pw") 1))
    ;; Query page also works
    (let ((page (compilation-history--query-page-fts 10 0 "ls")))
      (should (= (length page) 1)))))

(ert-deftest test-compilation-history--short-column-search-uses-like ()
  "Column-specific searches with short values fall back to LIKE."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :command "echo date pwd ls"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :command "make test"))
    ;; Column-specific with short value
    (should (= (compilation-history--count-records-fts "compile_command:ls") 1))
    ;; Column-specific with 3+ chars still uses FTS
    (should (= (compilation-history--count-records-fts "compile_command:make") 1))))

(ert-deftest test-fts-search-special-characters-falls-back-to-like ()
  "FTS search with special characters (e.g. s3://) falls back to LIKE instead of erroring."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((record (compilation-history-test--make-record
                   :record-id "20260321T120000000001"
                   :command "aws s3 ls s3://my-bucket")))
      (compilation-history--insert-compilation-record record)
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0 "listing objects..." nil)
      ;; This search term contains :// which is invalid FTS5 syntax
      ;; Should fall back to LIKE and return results, not error
      (should (= (compilation-history--count-records-fts "s3://") 1))
      ;; Query should also work without error
      (let ((rows (compilation-history--query-page-fts 10 0 "s3://")))
        (should (= (length rows) 1))))))

(ert-deftest test-compilation-history--insert-stores-utc-offset ()
  "Insert stores UTC offset in the database."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((record (compilation-history-test--make-record
                   :record-id "20260321T120000000001")))
      (compilation-history--insert-compilation-record record)
      (let* ((db (sqlite-open compilation-history-db-file))
             (row (car (sqlite-select db "SELECT utc_offset FROM compilations WHERE id = ?"
                                      (vector "20260321T120000000001")))))
        (sqlite-close db)
        ;; utc_offset should be a non-nil integer
        (should (integerp (car row)))
        ;; Should be in valid range
        (should (<= -720 (car row) 840))))))

(ert-deftest test-compilation-history--query-page-converts-start-time ()
  "Query page returns start_time converted to local time using utc_offset."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((record (compilation-history-test--make-record
                   :record-id "20260321T120000000001")))
      (compilation-history--insert-compilation-record record)
      ;; Manually set a known start_time and offset for predictable testing
      (let ((db (sqlite-open compilation-history-db-file)))
        (sqlite-execute db "UPDATE compilations SET start_time = '2026-03-28 16:30:00', utc_offset = -300 WHERE id = ?"
                        (vector "20260321T120000000001"))
        (sqlite-close db))
      ;; Query should return the converted local time
      (let* ((page (compilation-history--query-page 1 0))
             (row (car page))
             ;; start_time is at index 4 in page-columns
             (start-time (nth 4 row)))
        (should (equal start-time "2026-03-28 11:30:00"))))))

(ert-deftest test-compilation-history--saves-ansi-codes-in-output ()
  "Output saved to database preserves ANSI escape codes."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((record (compilation-history-test--make-record
                   :record-id "20260321T120000000001")))
      (compilation-history--insert-compilation-record record)
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0
       "header\n\033[32mPASS\033[0m test_one\nfooter\n")
      (let ((output (compilation-history--get-output "20260321T120000000001")))
        (should (string-match-p "\033\\[32m" output))))))

(provide 'test-compilation-history-db)
;;; test-compilation-history-db.el ends here
