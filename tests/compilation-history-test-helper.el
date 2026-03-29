;;; compilation-history-test-helper.el --- Test helpers for compilation-history -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jonathan Otsuka

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Shared test helpers for compilation-history test suite.

;;; Code:

(require 'cl-lib)
(require 'compilation-history)

;;; Test Macros

(defmacro compilation-history-test-with-db (&rest body)
  "Execute BODY with a temporary test database in an isolated directory.
Creates a temporary directory with a database file inside it, binds
`compilation-history-db-file' to the database path, and recursively
cleans up the entire directory afterward.
Variables available in BODY: temp-dir, temp-db."
  (declare (indent 0) (debug t))
  `(let* ((temp-dir (make-temp-file "test-compilation-history" t))
          (temp-db (expand-file-name "test.db" temp-dir))
          (compilation-history-db-file temp-db)
          (default-directory (file-name-as-directory temp-dir)))
     ;; Create a git repo so vc-git can resolve a branch name
     (call-process "git" nil nil nil "-C" temp-dir "init" "-b" "test-branch")
     (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test")
     (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
     (call-process "git" nil nil nil "-C" temp-dir "commit" "--allow-empty" "-m" "init")
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p temp-dir)
         (delete-directory temp-dir t)))))

;;; Test Helper Functions

(cl-defun compilation-history-test--make-record (&key
                                                 (record-id (format-time-string "%Y%m%dT%H%M%S000000"))
                                                 (buffer-name "*compilation-history-test*")
                                                 (command "make test")
                                                 (compile-directory "/tmp/")
                                                 (comint nil)
                                                 (system-info '(:os darwin :emacs-version "29.1")))
  "Create a test compilation record with optional keyword arguments.
All parameters are optional and have sensible test defaults."
  (make-compilation-history
   :buffer-name buffer-name
   :command command
   :compile-directory compile-directory
   :record-id record-id
   :system-info system-info
   :comint comint))

(provide 'compilation-history-test-helper)
;;; compilation-history-test-helper.el ends here
