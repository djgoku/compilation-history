;;; test-compilation-history.el --- Tests for compilation-history -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jonathan Otsuka

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Tests for compilation-history.el core tracking functions

;;; Code:

(require 'ert)
(require 'compilation-history)
(require 'compilation-history-test-helper)

(ert-deftest test-partial-buffer-name-format ()
  "Test that partial buffer name has correct format."
  (let ((name (compilation-history--partial-buffer-name nil)))
    ;; Should match: *compilation-history-TIMESTAMP*
    (should (string-prefix-p "*compilation-history-" name))
    (should (string-suffix-p "*" name))
    ;; Extract timestamp portion
    (string-match "\\*compilation-history-\\(.*\\)\\*" name)
    (let ((timestamp (match-string 1 name)))
      ;; Timestamp should be in YYYYMMDDTHHMMSSffffff format
      (should (string-match-p (rx string-start
                                  (repeat 8 digit) "T" (repeat 6 digit) (repeat 6 digit)
                                  string-end)
                              timestamp)))))


(ert-deftest test-compilation-history-mode-activation ()
  "Test that compilation-history-mode sets up hooks correctly."
  ;; Save original values
  (let ((orig-buffer-name-fn compilation-buffer-name-function)
        (orig-setup-fn compilation-process-setup-function))
    (unwind-protect
        (progn
          ;; Enable the mode
          (compilation-history-mode 1)
          ;; Check that functions are set
          (should (eq compilation-buffer-name-function
                      #'compilation-history--partial-buffer-name))
          (should (eq compilation-process-setup-function
                      #'compilation-history--setup-function))
          ;; Disable the mode
          (compilation-history-mode -1)
          ;; Check that functions are cleared
          (should (null compilation-buffer-name-function))
          (should (null compilation-process-setup-function)))
      ;; Restore original values
      (setq compilation-buffer-name-function orig-buffer-name-fn)
      (setq compilation-process-setup-function orig-setup-fn))))

(ert-deftest test-set-recompile-command ()
  "Test that recompile command is set correctly."
  (let ((test-record (make-compilation-history
                      :record-id "20250119T120000123456"
                      :compile-command "make test"
                      :default-directory "/tmp/")))
    (with-temp-buffer
      (setq-local compilation-history-record test-record)
      (setq-local default-directory "/tmp/")
      (compilation-history-set-recompile-command)
      ;; Verify compile-command is buffer-local and set correctly
      (should (local-variable-p 'compile-command))
      (should (equal "make test" compile-command))
      (should (equal "/tmp/" compilation-directory)))))

(ert-deftest test-set-recompile-command-does-not-overwrite-existing ()
  "Test that set-recompile-command does not overwrite an existing buffer-local compile-command."
  (let ((test-record (make-compilation-history
                      :record-id "20250119T120000123456"
                      :compile-command "make test"
                      :default-directory "/tmp/")))
    (with-temp-buffer
      (setq-local compilation-history-record test-record)
      (setq-local compile-command "existing command")
      (compilation-history-set-recompile-command)
      ;; Should NOT overwrite the existing buffer-local value
      (should (equal "existing command" compile-command)))))

(ert-deftest test-maybe-fix-buffer-compile-command ()
  "Test that compile-command is synchronized with record."
  (let ((buffer (generate-new-buffer "*compilation-history-20250119T120000123456*"))
        (test-record (make-compilation-history
                      :record-id "20250119T120000123456"
                      :compile-command "make test")))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local compilation-history-record test-record)
          ;; Set compile-command to something different
          (setq-local compile-command "wrong command")
          ;; Call the function
          (compilation-history--maybe-fix-buffer-compile-command)
          ;; Should be fixed now
          (should (equal "make test" compile-command)))
      (kill-buffer buffer))))

(ert-deftest test-add-sentinel-metadata-advice ()
  "Test that sentinel advice captures exit status correctly."
  (let* ((buffer (generate-new-buffer "*test-compilation*"))
         (test-record (make-compilation-history
                       :record-id "20250119T120000123456"
                       :compile-command "echo test")))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local compilation-history-record test-record)
          ;; Create a mock process
          (let ((proc (start-process "test-proc" buffer "echo" "test")))
            (while (process-live-p proc)
              (sit-for 0.1))
            ;; Simulate calling the advice
            (compilation-history--add-sentinel-metadata-advice proc "finished\n")
            ;; Check that exit-code and message were set
            (should (numberp (compilation-history-exit-code compilation-history-record)))
            (should (equal "finished\n" (compilation-history-message compilation-history-record)))))
      (kill-buffer buffer))))

(ert-deftest test-init-creates-database ()
  "Test that compilation-history-init creates database."
  (compilation-history-test-with-db
    (when (file-exists-p temp-db)
      (delete-file temp-db))
    (compilation-history-init)
    (should (file-exists-p temp-db))))

(ert-deftest test-integration-compile-workflow ()
  "Integration test: activate mode, run compile, verify database record."
  (compilation-history-test-with-db
    (let ((orig-db-file compilation-history-db-file)
          (orig-compile-command compile-command)
          (test-command "echo 'integration test'"))
      (unwind-protect
          (progn
            (compilation-history-init)

            ;; Enable compilation-history-mode
            (compilation-history-mode 1)

            ;; Run compile command
            (compile test-command)

            ;; Wait for compilation to finish
            (while compilation-in-progress
              (sit-for 0.1))

            ;; Find the compilation buffer
            (let ((comp-buffer (seq-find (lambda (buf)
                                           (string-prefix-p "*compilation-history-" (buffer-name buf)))
                                         (buffer-list))))
              (should comp-buffer)

              ;; Verify record in buffer
              (with-current-buffer comp-buffer
                (should (local-variable-p 'compilation-history-record))
                (let ((record compilation-history-record))
                  ;; Verify record fields
                  (should (equal test-command (compilation-history-compile-command record)))
                  (should (stringp (compilation-history-record-id record)))
                  (should (stringp (compilation-history-buffer-name record)))

                  ;; Verify database record
                  (let* ((record-id (compilation-history-record-id record))
                         (db (sqlite-open temp-db))
                         (rows (sqlite-select db "SELECT * FROM compilations WHERE id = ?" (vector record-id))))
                    (should (= 1 (length rows)))
                    (let* ((row (car rows))
                           (db-command (nth 2 row))
                           (db-start-time (nth 4 row))
                           (db-end-time (nth 5 row))
                           (db-git-repo (nth 8 row))
                           (db-git-branch (nth 9 row))
                           (db-git-commit (nth 10 row)))
                      (should (equal test-command db-command))
                      (should (stringp db-start-time))
                      (should (stringp db-end-time))
                      ;; Should have git metadata since we're in a git repo
                      (should (stringp db-git-repo))
                      (should (stringp db-git-branch))
                      (should (stringp db-git-commit)))
                    (sqlite-close db)))

                ;; Cleanup buffer
                (kill-buffer comp-buffer))))

        ;; Cleanup
        (compilation-history-mode -1)
        (setq compile-command orig-compile-command)
        (setq compilation-history-db-file orig-db-file)))))

(ert-deftest test-compile-from-non-compilation-buffer ()
  "Test that compile from a regular buffer creates a compilation-history buffer."
  (compilation-history-test-with-db
    (let ((orig-db-file compilation-history-db-file)
          (orig-compile-command compile-command)
          (test-command "echo from-regular-buffer"))
      (unwind-protect
          (progn
            (compilation-history-init)
            (compilation-history-mode 1)

            ;; Compile from a temp buffer (non-compilation buffer)
            (with-temp-buffer
              (compile test-command))

            ;; Wait for compilation to finish
            (while compilation-in-progress
              (sit-for 0.1))

            ;; Find the compilation buffer
            (let ((comp-buffer (seq-find (lambda (buf)
                                          (string-prefix-p "*compilation-history-" (buffer-name buf)))
                                        (buffer-list))))
              (should comp-buffer)

              ;; Verify compile-command is set correctly
              (with-current-buffer comp-buffer
                (should (equal test-command compile-command))
                (should (local-variable-p 'compile-command)))

              ;; Cleanup
              (dolist (buf (buffer-list))
                (when (string-prefix-p "*compilation-history-" (buffer-name buf))
                  (kill-buffer buf)))))

        ;; Cleanup
        (compilation-history-mode -1)
        (setq compile-command orig-compile-command)
        (setq compilation-history-db-file orig-db-file)))))

(ert-deftest test-recompile-from-compilation-buffer ()
  "Test that plain g (recompile without edit) reuses the original compile-command."
  (compilation-history-test-with-db
    (let ((orig-db-file compilation-history-db-file)
          (orig-compile-command compile-command)
          (original-command "echo original"))
      (unwind-protect
          (progn
            (compilation-history-init)
            (compilation-history-mode 1)

            ;; Run original compile command
            (compile original-command)

            ;; Wait for compilation to finish
            (while compilation-in-progress
              (sit-for 0.1))

            ;; Find buffer A
            (let ((buffer-a (seq-find (lambda (buf)
                                        (string-prefix-p "*compilation-history-" (buffer-name buf)))
                                      (buffer-list))))
              (should buffer-a)

              ;; Verify buffer A has original compile-command
              (with-current-buffer buffer-a
                (should (equal original-command compile-command))

                ;; Plain recompile (g) - should use original command
                (recompile))

              ;; Wait for new compilation to finish
              (while compilation-in-progress
                (sit-for 0.1))

              ;; Buffer A should still have the original compile-command
              (with-current-buffer buffer-a
                (should (equal original-command compile-command)))

              ;; Cleanup
              (dolist (buf (buffer-list))
                (when (string-prefix-p "*compilation-history-" (buffer-name buf))
                  (kill-buffer buf)))))

        ;; Cleanup
        (compilation-history-mode -1)
        (setq compile-command orig-compile-command)
        (setq compilation-history-db-file orig-db-file)))))

(ert-deftest test-recompile-with-prefix-preserves-original-compile-command ()
  "Test that C-u g (recompile with edit) does not overwrite compile-command in the original buffer.
Scenario: Buffer A runs 'echo original', user does C-u g and edits to 'echo edited'.
Buffer A's compile-command should still be 'echo original'."
  (compilation-history-test-with-db
    (let ((orig-db-file compilation-history-db-file)
          (orig-compile-command compile-command)
          (original-command "echo original")
          (edited-command "echo edited"))
      (unwind-protect
          (progn
            (compilation-history-init)
            (compilation-history-mode 1)

            ;; Run original compile command
            (compile original-command)

            ;; Wait for compilation to finish
            (while compilation-in-progress
              (sit-for 0.1))

            ;; Find buffer A (the original compilation buffer)
            (let ((buffer-a (seq-find (lambda (buf)
                                        (string-prefix-p "*compilation-history-" (buffer-name buf)))
                                      (buffer-list))))
              (should buffer-a)
              (message "Buffer A: %s" (buffer-name buffer-a))

              ;; Verify buffer A has original compile-command
              (with-current-buffer buffer-a
                (should (equal original-command compile-command))
                (message "Buffer A compile-command before C-u g: %s" compile-command)

                ;; Simulate C-u g: recompile with edited command
                ;; Mock compilation-read-command to return the edited command
                (cl-letf (((symbol-function 'compilation-read-command)
                           (lambda (_) edited-command)))
                  (recompile t)))

              ;; Wait for new compilation to finish
              (while compilation-in-progress
                (sit-for 0.1))

              ;; Check that buffer A's compile-command is still the original
              (with-current-buffer buffer-a
                (message "Buffer A compile-command after C-u g: %s" compile-command)
                (should (equal original-command compile-command)))

              ;; Cleanup all compilation-history buffers
              (dolist (buf (buffer-list))
                (when (string-prefix-p "*compilation-history-" (buffer-name buf))
                  (kill-buffer buf)))))

        ;; Cleanup
        (compilation-history-mode -1)
        (setq compile-command orig-compile-command)
        (setq compilation-history-db-file orig-db-file)))))

(ert-deftest test-compile-from-compilation-buffer-preserves-original-compile-command ()
  "Test that M-x compile from within a compilation buffer does not overwrite
compile-command in the original buffer.
Scenario: Buffer A runs 'echo original', user does M-x compile with 'echo edited'.
Buffer A's compile-command should still be 'echo original'."
  (compilation-history-test-with-db
    (let ((orig-db-file compilation-history-db-file)
          (original-command "echo original")
          (edited-command "echo edited"))
      (unwind-protect
          (progn
            (compilation-history-init)
            (compilation-history-mode 1)

            ;; Run original compile command
            (compile original-command)

            ;; Wait for compilation to finish
            (while compilation-in-progress
              (sit-for 0.1))

            ;; Find buffer A (the original compilation buffer)
            (let ((buffer-a (seq-find (lambda (buf)
                                        (string-prefix-p "*compilation-history-" (buffer-name buf)))
                                      (buffer-list))))
              (should buffer-a)
              (message "Buffer A: %s" (buffer-name buffer-a))

              ;; Verify buffer A has original compile-command
              (with-current-buffer buffer-a
                (should (equal original-command compile-command))
                (message "Buffer A compile-command before M-x compile: %s" compile-command)

                ;; Call compile with a different command from within buffer A
                (compile edited-command))

              ;; Wait for new compilation to finish
              (while compilation-in-progress
                (sit-for 0.1))

              ;; Check that buffer A's compile-command is still the original
              (with-current-buffer buffer-a
                (message "Buffer A compile-command after M-x compile: %s" compile-command)
                (should (equal original-command compile-command)))

              ;; Cleanup all compilation-history buffers
              (dolist (buf (buffer-list))
                (when (string-prefix-p "*compilation-history-" (buffer-name buf))
                  (kill-buffer buf)))))

        ;; Cleanup
        (compilation-history-mode -1)
        (setq compilation-history-db-file orig-db-file)))))

(ert-deftest test-recompile-with-prefix-while-running-preserves-original-compile-command ()
  "Test that C-u g while compilation is still running does not overwrite
compile-command in the original buffer via setcar on compilation-arguments."
  (compilation-history-test-with-db
    (let ((orig-db-file compilation-history-db-file)
          (orig-compile-command compile-command)
          (original-command "sleep 5")
          (edited-command "echo edited"))
      (unwind-protect
          (progn
            (compilation-history-init)
            (compilation-history-mode 1)

            ;; Run a long-running compile command
            (compile original-command)

            ;; Give it a moment to start but DON'T wait for it to finish
            (sit-for 0.5)

            ;; Find buffer A (the original compilation buffer)
            (let ((buffer-a (seq-find (lambda (buf)
                                        (string-prefix-p "*compilation-history-" (buffer-name buf)))
                                      (buffer-list))))
              (should buffer-a)
              (message "Buffer A: %s" (buffer-name buffer-a))

              ;; Verify compilation is still in progress
              (should compilation-in-progress)

              ;; Verify buffer A has original compile-command
              (with-current-buffer buffer-a
                (should (equal original-command compile-command))
                (message "Buffer A compile-command before C-u g (while running): %s" compile-command)
                (message "Buffer A compilation-arguments: %s" compilation-arguments)

                ;; Simulate C-u g while compilation is still running
                (cl-letf (((symbol-function 'compilation-read-command)
                           (lambda (_) edited-command)))
                  (recompile t)))

              ;; Wait for all compilations to finish
              (while compilation-in-progress
                (sit-for 0.1))

              ;; Check that buffer A's compile-command is still the original
              (with-current-buffer buffer-a
                (message "Buffer A compile-command after C-u g (while running): %s" compile-command)
                (message "Buffer A compilation-arguments after: %s" compilation-arguments)
                (should (equal original-command compile-command)))

              ;; Cleanup all compilation-history buffers
              (dolist (buf (buffer-list))
                (when (string-prefix-p "*compilation-history-" (buffer-name buf))
                  (kill-buffer buf)))))

        ;; Cleanup
        (compilation-history-mode -1)
        (setq compile-command orig-compile-command)
        (setq compilation-history-db-file orig-db-file)))))

(provide 'test-compilation-history)
;;; test-compilation-history.el ends here
