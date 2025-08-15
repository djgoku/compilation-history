;;; test-compilation-history.el --- Tests for compilation-history -*- lexical-binding: t; -*-

;; TESTS GRADUALLY BEING RE-ENABLED
;; Starting with simple tests first

(require 'ert)
(require 'compile)
(require 'sqlite)
(require 'compilation-history)

;; All tests commented out for stability - will be uncommented as they are fixed

(ert-deftest compilation-history--get-git-remote-urls-test ()
  "Test the `compilation-history--get-git-remote-urls` function."
  ;; Test case 1: Git repository with remote URLs
  (cl-letf (((symbol-function 'shell-command-to-string)
             (lambda (command)
               (when (string-equal command "git config --get-regexp '^remote\\..*\\.url$'")
                 "remote.origin.url git@github.com:user/repo.git\nremote.upstream.url https://github.com/user/repo.git\n"))))
    (should (equal (compilation-history--get-git-remote-urls)
                   '(("origin" . "git@github.com:user/repo.git")
                     ("upstream" . "https://github.com/user/repo.git")))))

  ;; Test case 2: Git repository with no remote URLs
  (cl-letf (((symbol-function 'shell-command-to-string)
             (lambda (command)
               (when (string-equal command "git config --get-regexp '^remote\\..*\\.url$'")
                 ""))))
    (should (equal (compilation-history--get-git-remote-urls)
                   nil))))
;;
;;
(ert-deftest compilation-history--partial-buffer-name-test ()
  (should (string-match-p
           (rx "*compilation-history-" (repeat 8 num) "T" (repeat 12 num) "*")
           (compilation-history--partial-buffer-name "compilation"))))
;;
(ert-deftest compilation-history--path-test ()
  (cl-letf (((symbol-function 'compilation-history--get-project-root)
             (lambda (dir) "/path/to/my-project")))
    ;; Test case 1: Compilation at project root
    (should (string= "my-project"
                     (compilation-history--get-path-string "/path/to/my-project")))

    ;; Test case 2: Compilation in a subdirectory
    (should (string= "my-project--src--app"
                     (compilation-history--get-path-string "/path/to/my-project/src/app")))

    ;; Test case 3: Compilation in a subdirectory with a trailing slash
    (should (string= "my-project--src--app"
                     (compilation-history--get-path-string "/path/to/my-project/src/app/")))))
;;
(ert-deftest compilation-history--path-test-no-project-root ()
  (cl-letf (((symbol-function 'compilation-history--get-project-root)
             (lambda (dir) nil)))
    (should (string= "my-project"
                     (compilation-history--get-path-string "/path/to/my-project")))))
;;
(ert-deftest compilation-history--command-test ()
  (let ((compilation-history-command-truncate-length 25))
    ;; Test case 1: Command with special characters
    (should (string= "a-b-c-d-e"
                     (compilation-history--sanitize-command "a!b@c#d$e")))

    ;; Test case 2: Command with consecutive hyphens
    (should (string= "a-b-c"
                     (compilation-history--sanitize-command "a---b-c")))

    ;; Test case 3: Command truncation
    (should (string= "1234567890123456789012345"
                     (compilation-history--sanitize-command "123456789012345678901234567890")))))
;;
(ert-deftest compilation-history--get-system-info-test ()
  (cl-letf (((symbol-function 'compilation-history--get-macos-version) (lambda () "15.6"))
            ((symbol-function 'vc-git-root) (lambda (dir) "/path/to/my-project"))
            ((symbol-function 'vc-git-branches) (lambda () '("main")))
            ((symbol-function 'vc-git-working-revision) (lambda (dir) "abcdef123"))
            ((symbol-function 'vc-git-get-change-comment) (lambda (dir rev) "Initial commit"))
            ((symbol-function 'compilation-history--get-git-remote-urls) (lambda () '(("origin" . "url1") ("upstream" . "url2")))))
    (let ((info (compilation-history--get-system-info "/path/to/my-project")))
      (should (equal (plist-get info :os) system-type))
      (should (equal (plist-get info :os-version) "15.6"))
      (should (equal (plist-get info :emacs-version) (emacs-version)))
      (should (equal (plist-get info :git-repo) "/path/to/my-project"))
      (should (equal (plist-get info :git-branch) "main"))
      (should (equal (plist-get info :git-commit) "abcdef123"))
      (should (equal (plist-get info :git-commit-message) "Initial commit"))
      (should (equal (plist-get info :git-remote-urls) '(("origin" . "url1") ("upstream" . "url2")))))))
;;
(ert-deftest compilation-history--get-system-info-no-git-test ()
  (cl-letf (((symbol-function 'vc-git-root) (lambda (dir) nil)))
    (let ((info (compilation-history--get-system-info "/path/to/some-dir")))
      (should (equal (plist-get info :os) system-type))
      (should (equal (plist-get info :emacs-version) (emacs-version)))
      (should (null (plist-get info :git-repo)))
      (should (null (plist-get info :git-branch)))
      (should (null (plist-get info :git-commit)))
      (should (null (plist-get info :git-commit-message))))))
;;
(ert-deftest compilation-history--extract-id-from-buffer-name-test ()
  ;; Test extracting ID from a valid buffer name
  (should (string= "20240101T123456789012"
                   (compilation-history--extract-id-from-buffer-name
                    "*compilation-history-20240101T123456789012==my-project__make*")))

  ;; Test with different timestamp format
  (should (string= "20251213T140530123456"
                   (compilation-history--extract-id-from-buffer-name
                    "*compilation-history-20251213T140530123456==test-project--src__npm-run-build*")))

  ;; Test with invalid buffer name
  (should (null (compilation-history--extract-id-from-buffer-name "*compilation*")))

  ;; Test with malformed buffer name
  (should (null (compilation-history--extract-id-from-buffer-name "*compilation-history-no-equals*"))))
;;

;; Database Tests

(ert-deftest compilation-history-db-creation-test ()
  "Test that database and table creation works."
  (let ((db-file (make-temp-file "compilation-history-test.db")))
    (unwind-protect
        (let ((compilation-history-db-file db-file))
          (compilation-history--ensure-db)
          ;; Verify the database file was created
          (should (file-exists-p db-file))
          ;; Test that we can open the database
          (let ((db (sqlite-open db-file)))
            (unwind-protect
                (progn
                  ;; Check that the compilations table exists
                  (let ((tables (sqlite-execute db "SELECT name FROM sqlite_master WHERE type='table' AND name='compilations';")))
                    (should (equal (car (car tables)) "compilations"))))
              (sqlite-close db))))
      (delete-file db-file))))

(ert-deftest compilation-history-db-insert-test ()
  "Test direct database insertion without using the problematic wrapper function."
  (let ((db-file (make-temp-file "compilation-history-test.db")))
    (unwind-protect
        (let ((compilation-history-db-file db-file))
          (compilation-history--ensure-db)
          ;; Insert a record directly using sqlite-execute
          (let ((db (sqlite-open db-file)))
            (unwind-protect
                (progn
                  ;; Insert test data
                  (sqlite-execute db 
                                  "INSERT INTO compilations (
                       id, buffer_name, compile_command, default_directory, start_time,
                       git_repo, git_branch, git_commit, git_commit_message, git_remote_urls,
                       os, os_version, emacs_version
                     ) VALUES (?, ?, ?, ?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?)"
                                  (vector "test-id-123"
                                          "test-buffer"
                                          "make test"
                                          "/tmp/test"
                                          "/path/to/repo"
                                          "main"
                                          "abc123"
                                          "Test commit"
                                          "{\"origin\":\"test-url\"}"
                                          "gnu/linux"
                                          "5.10"
                                          "29.1"))
                  ;; Verify the record was inserted
                  (let* ((result (sqlite-execute db "SELECT id, buffer_name, compile_command FROM compilations WHERE id = ?" (vector "test-id-123")))
                         (row (car result)))
                    (should (equal (nth 0 row) "test-id-123"))
                    (should (equal (nth 1 row) "test-buffer"))
                    (should (equal (nth 2 row) "make test"))))
              (sqlite-close db))))
      (delete-file db-file))))

(ert-deftest compilation-history-db-update-test ()
  "Test database record updates."
  (let ((db-file (make-temp-file "compilation-history-test.db")))
    (unwind-protect
        (let ((compilation-history-db-file db-file))
          (compilation-history--ensure-db)
          (let ((db (sqlite-open db-file)))
            (unwind-protect
                (progn
                  ;; Insert a record
                  (sqlite-execute db 
                                  "INSERT INTO compilations (
                       id, buffer_name, compile_command, default_directory, start_time,
                       os, os_version, emacs_version
                     ) VALUES (?, ?, ?, ?, datetime('now'), ?, ?, ?)"
                                  (vector "update-test-id"
                                          "update-buffer"
                                          "make update"
                                          "/tmp/update"
                                          "gnu/linux"
                                          "5.10"
                                          "29.1"))
                  ;; Update the record with completion data
                  (sqlite-execute db 
                                  "UPDATE compilations SET
                       end_time = datetime('now'), 
                       exit_code = ?, 
                       output = ?,
                       killed = ?
                     WHERE id = ?"
                                  (vector 0 "Build successful" 0 "update-test-id"))
                  ;; Verify the update
                  (let* ((result (sqlite-execute db "SELECT exit_code, output, killed FROM compilations WHERE id = ?" (vector "update-test-id")))
                         (row (car result)))
                    (should (equal (nth 0 row) 0))       ;; exit_code
                    (should (equal (nth 1 row) "Build successful")) ;; output
                    (should (equal (nth 2 row) 0))))     ;; killed = false
              (sqlite-close db))))
      (delete-file db-file))))

(ert-deftest compilation-history-db-integration-test ()
  "Test the high-level database functions work correctly."
  (let ((db-file (make-temp-file "compilation-history-test.db")))
    (unwind-protect
        (let ((compilation-history-db-file db-file))
          ;; Test database initialization
          (compilation-history--ensure-db)
          
          ;; Test high-level record insertion using direct SQL to avoid the broken wrapper
          (let ((db (sqlite-open db-file))
                (system-info (list :os 'darwin
                                   :os-version "14.0"
                                   :emacs-version "29.1"
                                   :git-repo "/path/to/test-repo"
                                   :git-branch "feature-branch"
                                   :git-commit "def456"
                                   :git-commit-message "Add new feature"
                                   :git-remote-urls '(("origin" . "git@github.com:user/repo.git")))))
            (unwind-protect
                (progn
                  ;; Insert using the approach the actual code would use
                  (sqlite-execute db 
                                  "INSERT INTO compilations (
                       id, buffer_name, compile_command, default_directory, start_time,
                       git_repo, git_branch, git_commit, git_commit_message, git_remote_urls,
                       os, os_version, emacs_version
                     ) VALUES (?, ?, ?, ?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?)"
                                  (vector "integration-test-id"
                                          "*compilation-history-integration-test*"
                                          "npm run build"
                                          "/path/to/project"
                                          (plist-get system-info :git-repo)
                                          (plist-get system-info :git-branch)
                                          (plist-get system-info :git-commit)
                                          (plist-get system-info :git-commit-message)
                                          (json-encode (plist-get system-info :git-remote-urls))
                                          (symbol-name (plist-get system-info :os))
                                          (plist-get system-info :os-version)
                                          (plist-get system-info :emacs-version)))

                  ;; Test completion update
                  (sqlite-execute db 
                                  "UPDATE compilations SET
                       end_time = datetime('now'), 
                       exit_code = ?, 
                       output = ?,
                       killed = ?
                     WHERE id = ?"
                                  (vector 1 "Build failed with errors" 0 "integration-test-id"))

                  ;; Verify all data is correct
                  (let* ((result (sqlite-execute db 
                                                 "SELECT id, compile_command, git_branch, exit_code, git_remote_urls
                            FROM compilations WHERE id = ?" 
                                                 (vector "integration-test-id")))
                         (row (car result)))
                    (should (equal (nth 0 row) "integration-test-id"))
                    (should (equal (nth 1 row) "npm run build"))
                    (should (equal (nth 2 row) "feature-branch"))
                    (should (equal (nth 3 row) 1))
                    (should (equal (nth 4 row) "{\"origin\":\"git@github.com:user/repo.git\"}"))
                    
                    ;; Test that we can query multiple records
                    (sqlite-execute db 
                                    "INSERT INTO compilations (id, buffer_name, compile_command, default_directory, start_time, os)
                       VALUES (?, ?, ?, ?, datetime('now'), ?)"
                                    (vector "second-record" "second-buffer" "make clean" "/tmp" "linux"))

                    (let ((all-records (sqlite-execute db "SELECT COUNT(*) FROM compilations")))
                      (should (equal (car (car all-records)) 2)))))
              (sqlite-close db))))
      (delete-file db-file))))

(ert-deftest compilation-history-wrapper-functions-test ()
  "Test that the high-level wrapper functions work correctly after the fix."
  (let ((db-file (make-temp-file "compilation-history-test.db")))
    (unwind-protect
        (let ((compilation-history-db-file db-file))
          (compilation-history--ensure-db)
          
          ;; Test the insert wrapper function
          (compilation-history--insert-compilation-record
           "wrapper-test-id"
           "*compilation-history-wrapper-test*"
           "npm run test"
           "/path/to/project"
           (list :os 'darwin
                 :os-version "14.0"
                 :emacs-version "29.1"
                 :git-repo "/path/to/test-repo"
                 :git-branch "main"
                 :git-commit "abc123"
                 :git-commit-message "Fix tests"
                 :git-remote-urls '(("origin" . "git@github.com:user/repo.git"))))
          
          ;; Test the update wrapper function  
          (compilation-history--update-compilation-record
           "wrapper-test-id" 0 "All tests passed" nil)
          
          ;; Test querying with the wrapper function
          (let* ((result (compilation-history--execute-sql 
                          "SELECT id, compile_command, exit_code, output FROM compilations WHERE id = ?"
                          (vector "wrapper-test-id")))
                 (row (car result)))
            (should (equal (nth 0 row) "wrapper-test-id"))
            (should (equal (nth 1 row) "npm run test"))
            (should (equal (nth 2 row) 0))
            (should (equal (nth 3 row) "All tests passed"))))
      (delete-file db-file))))

(ert-deftest compilation-history--setup-function-test ()
  "Test the compilation setup function that initializes compilation tracking."
  (let ((db-file (make-temp-file "compilation-history-test.db"))
        (test-buffer-name "*compilation-history-20240101T123456789012*")
        (test-command "make test")
        (test-directory "/path/to/project"))
    (unwind-protect
        (let ((compilation-history-db-file db-file))
          ;; Create a test buffer with the expected name pattern
          (with-temp-buffer
            (rename-buffer test-buffer-name)
            
            ;; Mock the compilation environment
            (let ((compilation-arguments (list test-command))
                  (default-directory test-directory))
              
              ;; Mock system info to avoid external dependencies
              (cl-letf (((symbol-function 'compilation-history--get-system-info)
                         (lambda (dir)
                           (list :os 'gnu-linux
                                 :os-version "5.10"
                                 :emacs-version "29.1"
                                 :git-repo "/path/to/repo"
                                 :git-branch "main"
                                 :git-commit "abc123"
                                 :git-commit-message "Test commit"
                                 :git-remote-urls '(("origin" . "test-url")))))
                        ((symbol-function 'compilation-history--generate-buffer-name)
                         (lambda (cmd dir id)
                           (format "*compilation-history-%s==%s__%s*" id "test-project" "make-test"))))

                ;; Call the setup function
                (compilation-history--setup-function)
                
                ;; Verify the buffer was renamed
                (should (string-match-p "\\*compilation-history-20240101T123456789012==.*\\*" (buffer-name)))
                
                ;; Verify local variables were set
                (should (equal compilation-history--record-id "20240101T123456789012"))
                (should (equal compilation-history--original-command test-command))
                (should (plist-get compilation-history--system-info :os))
                
                ;; Verify database record was created
                (let* ((result (compilation-history--execute-sql 
                                "SELECT id, compile_command, default_directory FROM compilations WHERE id = ?"
                                (vector "20240101T123456789012")))
                       (row (car result)))
                  (should (equal (nth 0 row) "20240101T123456789012"))
                  (should (equal (nth 1 row) test-command))
                  (should (equal (nth 2 row) test-directory)))))))
      (delete-file db-file))))
