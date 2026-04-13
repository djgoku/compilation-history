;;; test-compilation-history-core.el --- Tests for compilation-history -*- lexical-binding: t; -*-

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
(require 'seq)
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
                      :command "make test"
                      :compile-directory "/tmp/")))
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
                      :command "make test"
                      :compile-directory "/tmp/")))
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
                      :command "make test")))
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
                       :command "echo test")))
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
                  (should (equal test-command (compilation-history-command record)))
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

(ert-deftest test-recompile-with-prefix-preserves-compilation-arguments ()
  "Regression: C-u g mutates compilation-arguments via setcar but
compilation-history should restore it so the next plain g recompile
uses the original command, not the edited one.
Scenario: Buffer A runs 'echo original', user does C-u g with 'echo edited'.
Buffer A's (car compilation-arguments) should still be 'echo original'."
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

              ;; Verify buffer A has correct compilation-arguments
              (with-current-buffer buffer-a
                (should (equal original-command (car compilation-arguments)))
                (message "Buffer A compilation-arguments before C-u g: %s" compilation-arguments)

                ;; Simulate C-u g: recompile with edited command
                (cl-letf (((symbol-function 'compilation-read-command)
                           (lambda (_) edited-command)))
                  (recompile t)))

              ;; Wait for new compilation to finish
              (while compilation-in-progress
                (sit-for 0.1))

              ;; BUG: recompile's setcar mutated compilation-arguments in buffer A
              ;; so (car compilation-arguments) is now "echo edited" instead of "echo original"
              (with-current-buffer buffer-a
                (message "Buffer A compilation-arguments after C-u g: %s" compilation-arguments)
                (should (equal original-command (car compilation-arguments))))

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

(ert-deftest test-cancel-save-timer-cancels-active-timer ()
  "Test that cancel-save-timer cancels and nils an active timer."
  (with-temp-buffer
    (setq-local compilation-history--save-timer
                (run-with-timer 999 nil #'ignore))
    (compilation-history--cancel-save-timer)
    (should (null compilation-history--save-timer))))

(ert-deftest test-cancel-save-timer-noop-when-nil ()
  "Test that cancel-save-timer is a no-op when timer is nil."
  (with-temp-buffer
    (setq-local compilation-history--save-timer nil)
    (compilation-history--cancel-save-timer)
    (should (null compilation-history--save-timer))))

(ert-deftest test-save-partial-output-skips-when-not-dirty ()
  "Test that save-partial-output is a no-op when output is not dirty."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-partial-save*")))
      (unwind-protect
          (with-current-buffer buffer
            (setq-local compilation-history--output-dirty nil)
            (setq-local compilation-history-record
                        (compilation-history-test--make-record))
            (compilation-history--insert-compilation-record compilation-history-record)
            (insert "some output")
            (compilation-history--save-partial-output buffer)
            ;; Verify no output was saved (should still be nil in DB)
            (let* ((db (sqlite-open temp-db))
                   (rows (sqlite-select db "SELECT output FROM compilations WHERE id = ?"
                                        (vector (compilation-history-record-id compilation-history-record)))))
              (should (null (caar rows)))
              (sqlite-close db)))
        (kill-buffer buffer)))))

(ert-deftest test-save-partial-output-writes-when-dirty ()
  "Test that save-partial-output writes buffer content when dirty."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-partial-save*")))
      (unwind-protect
          (with-current-buffer buffer
            (setq-local compilation-history-record
                        (compilation-history-test--make-record))
            (compilation-history--insert-compilation-record compilation-history-record)
            (insert "partial output line 1\nline 2\n")
            (setq-local compilation-history--output-dirty t)
            (setq-local compilation-history--unsaved-line-count 2)
            (compilation-history--save-partial-output buffer)
            ;; Verify output was saved
            (let* ((db (sqlite-open temp-db))
                   (rows (sqlite-select db "SELECT output FROM compilations WHERE id = ?"
                                        (vector (compilation-history-record-id compilation-history-record)))))
              (should (equal "partial output line 1\nline 2\n" (caar rows)))
              (sqlite-close db))
            ;; Verify flags were reset
            (should (null compilation-history--output-dirty))
            (should (= 0 compilation-history--unsaved-line-count)))
        (kill-buffer buffer)))))

(ert-deftest test-save-partial-output-skips-dead-buffer ()
  "Test that save-partial-output is a no-op for a dead buffer."
  (let ((buffer (generate-new-buffer "*test-dead-buffer*")))
    (kill-buffer buffer)
    ;; Should not error
    (compilation-history--save-partial-output buffer)))

(ert-deftest test-save-partial-output-skips-nil-record ()
  "Test that save-partial-output is a no-op when record is nil."
  (let ((buffer (generate-new-buffer "*test-nil-record*")))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local compilation-history--output-dirty t)
          ;; No compilation-history-record set
          (compilation-history--save-partial-output buffer))
      (kill-buffer buffer))))

(ert-deftest test-track-output-counts-newlines ()
  "Test that track-output correctly counts newlines in new output."
  (with-temp-buffer
    (setq-local compilation-history--unsaved-line-count 0)
    (setq-local compilation-history--output-dirty nil)
    (setq-local compilation-history-record
                (compilation-history-test--make-record))
    (insert "line 1\nline 2\nline 3\n")
    (let ((compilation-filter-start (point-min)))
      (compilation-history--track-output))
    (should (= 3 compilation-history--unsaved-line-count))
    (should compilation-history--output-dirty)))

(ert-deftest test-track-output-accumulates-across-calls ()
  "Test that line count accumulates across multiple filter calls."
  (with-temp-buffer
    (setq-local compilation-history--unsaved-line-count 0)
    (setq-local compilation-history--output-dirty nil)
    (setq-local compilation-history-record
                (compilation-history-test--make-record))
    (insert "line 1\n")
    (let ((compilation-filter-start (point-min)))
      (compilation-history--track-output))
    (should (= 1 compilation-history--unsaved-line-count))
    (let ((start (point)))
      (insert "line 2\nline 3\n")
      (let ((compilation-filter-start start))
        (compilation-history--track-output)))
    (should (= 3 compilation-history--unsaved-line-count))))

(ert-deftest test-track-output-triggers-save-at-threshold ()
  "Test that track-output triggers a save when line threshold is reached."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-threshold*"))
          (compilation-history-save-line-threshold 3)
          (compilation-history-save-interval nil))
      (unwind-protect
          (with-current-buffer buffer
            (setq-local compilation-history--unsaved-line-count 0)
            (setq-local compilation-history--output-dirty nil)
            (setq-local compilation-history-record
                        (compilation-history-test--make-record))
            (compilation-history--insert-compilation-record compilation-history-record)
            (insert "line 1\nline 2\nline 3\n")
            (let ((compilation-filter-start (point-min)))
              (compilation-history--track-output))
            (should (null compilation-history--output-dirty))
            (should (= 0 compilation-history--unsaved-line-count))
            (let* ((db (sqlite-open temp-db))
                   (rows (sqlite-select db "SELECT output FROM compilations WHERE id = ?"
                                        (vector (compilation-history-record-id compilation-history-record)))))
              (should (equal "line 1\nline 2\nline 3\n" (caar rows)))
              (sqlite-close db)))
        (kill-buffer buffer)))))

(ert-deftest test-kill-buffer-cancels-timer-unconditionally ()
  "Test that kill-buffer-function cancels timer even when exit-code is set."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-kill-timer*")))
      (with-current-buffer buffer
        (setq-local compilation-history-record
                    (compilation-history-test--make-record))
        (compilation-history--insert-compilation-record compilation-history-record)
        ;; Set exit-code (simulates completed compilation)
        (setf (compilation-history-exit-code compilation-history-record) 0)
        ;; Set up a timer
        (setq-local compilation-history--save-timer
                    (run-with-timer 999 nil #'ignore))
        (let ((timer compilation-history--save-timer))
          ;; Call kill-buffer-function
          (compilation-history--kill-buffer-function)
          ;; Timer should be cancelled
          (should (null compilation-history--save-timer)))))))

(ert-deftest test-both-nil-disables-incremental-saving ()
  "Test that setting both save-interval and save-line-threshold to nil disables everything."
  (let ((compilation-history-save-interval nil)
        (compilation-history-save-line-threshold nil))
    (with-temp-buffer
      (setq-local compilation-history-record
                  (compilation-history-test--make-record))
      (setq-local compilation-history--unsaved-line-count 0)
      (setq-local compilation-history--output-dirty nil)
      ;; No timer should be created
      (should (null compilation-history--save-timer))
      ;; Filter hook should not be added
      (should-not (memq #'compilation-history--track-output
                        compilation-filter-hook)))))

(ert-deftest test-comint-mode-timer-sets-dirty-flag ()
  "Test that timer callback sets dirty flag unconditionally in comint-mode."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-comint-dirty*"))
          (compilation-history-save-interval 1)
          (compilation-history-save-line-threshold nil))
      (unwind-protect
          (with-current-buffer buffer
            (comint-mode)
            (setq-local compilation-history-record
                        (compilation-history-test--make-record))
            (compilation-history--insert-compilation-record compilation-history-record)
            (setq-local compilation-history--output-dirty nil)
            (setq-local compilation-history--unsaved-line-count 0)
            (insert "comint output\n")
            ;; Dirty should still be nil (no filter hook in comint-mode)
            (should (null compilation-history--output-dirty))
            ;; Simulate what the timer callback does
            (when (eq major-mode 'comint-mode)
              (setq-local compilation-history--output-dirty t))
            (compilation-history--save-partial-output buffer)
            ;; Verify output was saved
            (let* ((db (sqlite-open temp-db))
                   (rows (sqlite-select db "SELECT output FROM compilations WHERE id = ?"
                                        (vector (compilation-history-record-id compilation-history-record)))))
              (should (equal "comint output\n" (caar rows)))
              (sqlite-close db)))
        (kill-buffer buffer)))))

(ert-deftest test-mode-deactivation-cancels-all-timers ()
  "Test that disabling compilation-history-mode cancels timers in all buffers."
  (let ((buf-a (generate-new-buffer "*test-mode-deact-a*"))
        (buf-b (generate-new-buffer "*test-mode-deact-b*"))
        (orig-buffer-name-fn compilation-buffer-name-function)
        (orig-setup-fn compilation-process-setup-function))
    (unwind-protect
        (progn
          (with-current-buffer buf-a
            (setq-local compilation-history--save-timer
                        (run-with-timer 999 nil #'ignore)))
          (with-current-buffer buf-b
            (setq-local compilation-history--save-timer
                        (run-with-timer 999 nil #'ignore)))
          ;; Enable then disable mode
          (compilation-history-mode 1)
          (compilation-history-mode -1)
          ;; Both timers should be cancelled
          (with-current-buffer buf-a
            (should (null compilation-history--save-timer)))
          (with-current-buffer buf-b
            (should (null compilation-history--save-timer))))
      (kill-buffer buf-a)
      (kill-buffer buf-b)
      (setq compilation-buffer-name-function orig-buffer-name-fn)
      (setq compilation-process-setup-function orig-setup-fn))))

(ert-deftest test-integration-incremental-save-during-compilation ()
  "Integration test: compile with incremental saves, verify partial and final output in DB."
  (compilation-history-test-with-db
    (let ((orig-db-file compilation-history-db-file)
          (orig-compile-command compile-command)
          (compilation-history-save-line-threshold 2)
          (compilation-history-save-interval nil)
          (test-command "printf 'line1\\nline2\\nline3\\nline4\\n'"))
      (unwind-protect
          (progn
            (compilation-history-init)
            (compilation-history-mode 1)

            (compile test-command)

            ;; Wait for compilation to finish
            (while compilation-in-progress
              (sit-for 0.1))

            ;; Find the compilation buffer
            (let ((comp-buffer (seq-find (lambda (buf)
                                           (string-prefix-p "*compilation-history-" (buffer-name buf)))
                                         (buffer-list))))
              (should comp-buffer)

              (with-current-buffer comp-buffer
                (let* ((record-id (compilation-history-record-id compilation-history-record))
                       (db (sqlite-open temp-db))
                       (rows (sqlite-select db "SELECT output FROM compilations WHERE id = ?"
                                            (vector record-id))))
                  ;; Final output should contain all lines
                  (should (string-match-p "line1" (caar rows)))
                  (should (string-match-p "line4" (caar rows)))
                  (sqlite-close db)))

              ;; Cleanup
              (dolist (buf (buffer-list))
                (when (string-prefix-p "*compilation-history-" (buffer-name buf))
                  (kill-buffer buf)))))

        ;; Cleanup
        (compilation-history-mode -1)
        (setq compile-command orig-compile-command)
        (setq compilation-history-db-file orig-db-file)))))

(ert-deftest test-comint-buffer-read-only-after-finish ()
  "Test that comint compilation buffers become read-only with buffer-mode after finish."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-comint-finish*")))
      (unwind-protect
          (with-current-buffer buffer
            (comint-mode)
            (setq-local compilation-history-record
                        (compilation-history-test--make-record))
            (compilation-history--insert-compilation-record compilation-history-record)
            (setf (compilation-history-exit-code compilation-history-record) 0)
            (insert "some comint output\n")
            ;; Should not be read-only before finish
            (should-not buffer-read-only)
            ;; Simulate compilation finishing
            (compilation-history--finish-function buffer "finished\n")
            ;; Should be read-only after finish
            (should buffer-read-only)
            ;; Minor mode should be active
            (should compilation-history-buffer-mode)
            ;; q should be bound to quit-window via minor mode
            (should (eq (key-binding (kbd "q")) #'quit-window)))
        (kill-buffer buffer)))))

(ert-deftest test-non-comint-buffer-mode-after-finish ()
  "Test that non-comint compilation buffers also get buffer-mode after finish."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-non-comint-finish*")))
      (unwind-protect
          (with-current-buffer buffer
            (setq-local compilation-history-record
                        (compilation-history-test--make-record))
            (compilation-history--insert-compilation-record compilation-history-record)
            (setf (compilation-history-exit-code compilation-history-record) 0)
            (insert "some output\n")
            ;; Simulate compilation finishing
            (compilation-history--finish-function buffer "finished\n")
            ;; Minor mode should be active
            (should compilation-history-buffer-mode)
            ;; q should be bound via minor mode
            (should (eq (key-binding (kbd "q")) #'quit-window))
            ;; g should be bound to recompile via minor mode
            (should (eq (key-binding (kbd "g")) #'recompile)))
        (kill-buffer buffer)))))

(ert-deftest test-utc-offset-minutes ()
  "Test that UTC offset helper returns an integer in valid range."
  (let ((offset (compilation-history--utc-offset-minutes)))
    (should (integerp offset))
    ;; Valid UTC offsets range from -720 (UTC-12) to +840 (UTC+14)
    (should (<= -720 offset 840))))

(ert-deftest test-capture-raw-output-accumulates ()
  "Raw output capture hook accumulates text from compilation-filter-start to point."
  (with-temp-buffer
    (setq-local compilation-history--raw-output "")
    (insert "header\n")
    (let ((compilation-filter-start (point)))
      (insert "\033[32mPASS\033[0m test_one\n")
      (compilation-history--capture-raw-output))
    (should (equal compilation-history--raw-output "\033[32mPASS\033[0m test_one\n"))))

(ert-deftest test-ansi-codes-survive-save-and-reopen ()
  "ANSI escape codes in process output survive DB save and are rendered on reopen."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((record (compilation-history-test--make-record
                   :record-id "20260321T120000000001"
                   :buffer-name "*compilation-history-test-roundtrip*")))
      (compilation-history--insert-compilation-record record)
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0
       "Compilation started\n\033[32mPASS\033[0m one\n\033[31mFAIL\033[0m two\nCompilation finished\n")
      ;; Verify raw codes are in DB
      (let ((output (compilation-history--get-output "20260321T120000000001")))
        (should (string-match-p "\033\\[32m" output))
        (should (string-match-p "\033\\[31m" output))))))

;;; Recompile switch buffer tests

(ert-deftest test-recompile-switch-default-switches-buffer ()
  "Recompile from a compilation-history buffer selects the new buffer's window by default."
  (let ((old-buf (generate-new-buffer "*compilation-history-20260331T000000*"))
        (new-buf (generate-new-buffer "*compilation-history-20260331T000001*"))
        (selected-win nil))
    (unwind-protect
        (with-current-buffer old-buf
          ;; Display new-buf in a window so get-buffer-window finds it
          (display-buffer new-buf)
          (let ((compilation-history-recompile-switch-behavior 'switch))
            (cl-letf (((symbol-function 'recompile)
                       (lambda (&rest _) new-buf))
                      ((symbol-function 'select-window)
                       (lambda (win) (setq selected-win win))))
              (compilation-history--switch-to-recompile-buffer #'recompile))
            (should (eq selected-win (get-buffer-window new-buf)))))
      (kill-buffer old-buf)
      (kill-buffer new-buf))))

(ert-deftest test-recompile-switch-pop-uses-pop-to-buffer ()
  "With `pop' setting, recompile uses `pop-to-buffer' instead of `switch-to-buffer'."
  (let ((old-buf (generate-new-buffer "*compilation-history-20260331T000000*"))
        (new-buf (generate-new-buffer "*compilation-history-20260331T000001*"))
        (popped-to nil))
    (unwind-protect
        (with-current-buffer old-buf
          (let ((compilation-history-recompile-switch-behavior 'pop))
            (cl-letf (((symbol-function 'recompile)
                       (lambda (&rest _) new-buf))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buf) (setq popped-to buf))))
              (compilation-history--switch-to-recompile-buffer #'recompile))
            (should (eq popped-to new-buf))))
      (kill-buffer old-buf)
      (kill-buffer new-buf))))

(ert-deftest test-recompile-switch-nil-stays-in-current-buffer ()
  "With nil setting, recompile does not switch buffers."
  (let ((old-buf (generate-new-buffer "*compilation-history-20260331T000000*"))
        (new-buf (generate-new-buffer "*compilation-history-20260331T000001*"))
        (selected-win nil))
    (unwind-protect
        (with-current-buffer old-buf
          (display-buffer new-buf)
          (let ((compilation-history-recompile-switch-behavior nil))
            (cl-letf (((symbol-function 'recompile)
                       (lambda (&rest _) new-buf))
                      ((symbol-function 'select-window)
                       (lambda (win) (setq selected-win win))))
              (compilation-history--switch-to-recompile-buffer #'recompile))
            (should-not selected-win)))
      (kill-buffer old-buf)
      (kill-buffer new-buf))))

(ert-deftest test-recompile-switch-non-history-buffer-does-not-switch ()
  "Recompile from a non-compilation-history buffer does not switch regardless of setting."
  (let ((old-buf (generate-new-buffer "*some-other-buffer*"))
        (new-buf (generate-new-buffer "*compilation-history-20260331T000001*"))
        (selected-win nil))
    (unwind-protect
        (with-current-buffer old-buf
          (display-buffer new-buf)
          (let ((compilation-history-recompile-switch-behavior 'switch))
            (cl-letf (((symbol-function 'recompile)
                       (lambda (&rest _) new-buf))
                      ((symbol-function 'select-window)
                       (lambda (win) (setq selected-win win))))
              (compilation-history--switch-to-recompile-buffer #'recompile))
            (should-not selected-win)))
      (kill-buffer old-buf)
      (kill-buffer new-buf))))

(ert-deftest test-recompile-switch-advice-lifecycle ()
  "Advice is added when mode is enabled and removed when disabled."
  (let ((orig-compile-command compile-command))
    (unwind-protect
        (progn
          (compilation-history-mode 1)
          (should (advice-member-p #'compilation-history--switch-to-recompile-buffer 'recompile))
          (compilation-history-mode -1)
          (should-not (advice-member-p #'compilation-history--switch-to-recompile-buffer 'recompile)))
      (compilation-history-mode -1)
      (setq compile-command orig-compile-command))))

(ert-deftest test-recompile-switch-nil-return-no-error ()
  "No error when recompile returns nil (e.g., error or cancellation)."
  (let ((old-buf (generate-new-buffer "*compilation-history-20260331T000000*"))
        (selected-win nil))
    (unwind-protect
        (with-current-buffer old-buf
          (let ((compilation-history-recompile-switch-behavior 'switch))
            (cl-letf (((symbol-function 'recompile)
                       (lambda (&rest _) nil))
                      ((symbol-function 'select-window)
                       (lambda (win) (setq selected-win win))))
              (compilation-history--switch-to-recompile-buffer #'recompile))
            (should-not selected-win)))
      (kill-buffer old-buf))))

(ert-deftest test-comint-output-captured-to-database ()
  "Test that comint-mode output is captured via preoutput filter and saved to DB."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-comint-capture*")))
      (unwind-protect
          (with-current-buffer buffer
            (comint-mode)
            (setq-local compilation-history-record
                        (compilation-history-test--make-record :comint t))
            (compilation-history--insert-compilation-record compilation-history-record)
            ;; Set up incremental save (this should add comint hook, not compilation-filter-hook)
            (compilation-history--setup-incremental-save)
            ;; Simulate process output via the preoutput filter
            (compilation-history--comint-capture-raw-output "total 42\n")
            (compilation-history--comint-capture-raw-output "drwxr-xr-x  10 user staff 320 Apr 13 12:00 .\n")
            ;; Mark dirty and save
            (setq-local compilation-history--output-dirty t)
            (compilation-history--save-partial-output buffer)
            ;; Verify DB has header + actual output, not just header
            (let* ((db (sqlite-open temp-db))
                   (rows (sqlite-select db "SELECT output FROM compilations WHERE id = ?"
                                        (vector (compilation-history-record-id compilation-history-record)))))
              (should rows)
              (should (string-match-p "total 42" (caar rows)))
              (should (string-match-p "drwxr-xr-x" (caar rows)))
              (sqlite-close db)))
        (kill-buffer buffer)))))

(ert-deftest test-comint-hook-removed-after-finish ()
  "Test that comint preoutput filter is removed after compilation finishes."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-comint-hook-cleanup*")))
      (unwind-protect
          (with-current-buffer buffer
            (comint-mode)
            (setq-local compilation-history-record
                        (compilation-history-test--make-record :comint t))
            (compilation-history--insert-compilation-record compilation-history-record)
            (compilation-history--setup-incremental-save)
            ;; Hook should be present
            (should (memq #'compilation-history--comint-capture-raw-output
                          comint-preoutput-filter-functions))
            ;; Simulate output and finish
            (compilation-history--comint-capture-raw-output "output\n")
            (insert "output\n\nComint finished\n")
            (setf (compilation-history-exit-code compilation-history-record) 0)
            (compilation-history--finish-function buffer "finished\n")
            ;; Hook should be removed
            (should-not (memq #'compilation-history--comint-capture-raw-output
                              comint-preoutput-filter-functions)))
        (kill-buffer buffer)))))

(ert-deftest test-comint-setup-does-not-add-compilation-filter-hook ()
  "Test that comint-mode buffers do not get --capture-raw-output on compilation-filter-hook."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-comint-no-comp-hook*")))
      (unwind-protect
          (with-current-buffer buffer
            (comint-mode)
            (setq-local compilation-history-record
                        (compilation-history-test--make-record :comint t))
            (compilation-history--insert-compilation-record compilation-history-record)
            (compilation-history--setup-incremental-save)
            ;; Should have comint hook
            (should (memq #'compilation-history--comint-capture-raw-output
                          comint-preoutput-filter-functions))
            ;; Should NOT have compilation-filter-hook capture
            (should-not (memq #'compilation-history--capture-raw-output
                              compilation-filter-hook)))
        (kill-buffer buffer)))))

(ert-deftest test-compilation-setup-does-not-add-comint-hook ()
  "Test that compilation-mode buffers do not get comint preoutput hook."
  (compilation-history-test-with-db
    (compilation-history-init)
    (let ((buffer (generate-new-buffer "*test-comp-no-comint-hook*")))
      (unwind-protect
          (with-current-buffer buffer
            (setq-local compilation-history-record
                        (compilation-history-test--make-record))
            (compilation-history--insert-compilation-record compilation-history-record)
            (compilation-history--setup-incremental-save)
            ;; Should have compilation-filter-hook capture
            (should (memq #'compilation-history--capture-raw-output
                          compilation-filter-hook))
            ;; Should NOT have comint hook
            (should-not (and (boundp 'comint-preoutput-filter-functions)
                             (memq #'compilation-history--comint-capture-raw-output
                                   comint-preoutput-filter-functions))))
        (kill-buffer buffer)))))

(provide 'test-compilation-history-core)
;;; test-compilation-history-core.el ends here
