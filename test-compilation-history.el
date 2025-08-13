;;; test-compilation-history.el --- Tests for compilation-history -*- lexical-binding: t; -*-

(require 'ert)
(require 'compilation-history)

(ert-deftest compilation-history--partial-buffer-name-test ()
  (should (string-match-p
           (rx "*compilation-history-" (repeat 8 num) "T" (repeat 12 num) "*")
           (compilation-history--partial-buffer-name "compilation"))))

(ert-deftest compilation-history--path-test ()
  (cl-letf (((symbol-function 'compilation-history--get-project-root)
             (lambda (dir) "/path/to/my-project")))
    ;; Test case 1: Compilation at project root
    (should (string=
             "my-project"
             (compilation-history--get-path-string "/path/to/my-project")))

    ;; Test case 2: Compilation in a subdirectory
    (should (string=
             "my-project--src--app"
             (compilation-history--get-path-string "/path/to/my-project/src/app")))

    ;; Test case 3: Compilation in a subdirectory with a trailing slash
    (should (string=
             "my-project--src--app"
             (compilation-history--get-path-string "/path/to/my-project/src/app/")))))

(ert-deftest compilation-history--path-test-no-project-root ()
  (cl-letf (((symbol-function 'compilation-history--get-project-root)
             (lambda (dir) nil)))
    (should (string=
             "my-project"
             (compilation-history--get-path-string "/path/to/my-project")))))

(ert-deftest compilation-history--command-test ()
  (let ((compilation-history-command-truncate-length 25))
    ;; Test case 1: Command with special characters
    (should (string=
             "a-b-c-d-e"
             (compilation-history--sanitize-command "a!b@c#d$e")))

    ;; Test case 2: Command with consecutive hyphens
    (should (string=
             "a-b-c"
             (compilation-history--sanitize-command "a---b-c")))

    ;; Test case 3: Command truncation
    (should (string=
             "1234567890123456789012345"
             (compilation-history--sanitize-command "123456789012345678901234567890")))))

(ert-deftest compilation-history-mode-test ()
  (let ((original-function compilation-buffer-name-function))
    ;; Enable the mode
    (compilation-history-mode 1)
    (should (eq #'compilation-history--partial-buffer-name compilation-buffer-name-function))

    ;; Disable the mode
    (compilation-history-mode -1)
    (should (eq original-function compilation-buffer-name-function))))

(ert-deftest compilation-history-partial-buffer-name-integration-test ()
  (with-temp-buffer
    (compilation-history-mode 1)
    (let ((compilation-mode-hook
           (lambda ()
             (should (string-match-p
                      (rx "*compilation-history-" (repeat 8 num) "T" (repeat 12 num) "*")
                      (buffer-name))))))
      (compile "make"))
    (sit-for 1)))

(ert-deftest compilation-history-full-buffer-name-integration-test ()
  (with-temp-buffer
    (compilation-history-mode 1)
    (let ((compilation-finished-hook
           (lambda (buffer status)
             (should (string-match-p
                      (rx "*compilation-history-"
                          (repeat 8 num) "T" (repeat 12 num)
                          "=="
                          "compilation-history-redux"
                          "__"
                          "make"
                          "*")
                      (buffer-name buffer))))))
      (compile "make"))
    (sit-for 1)))
