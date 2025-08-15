;;; compilation-history.el --- Track compilation history in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: djgoku
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: compilation, tools, history
;; URL: https://github.com/djgoku/compilation-history

;;; Commentary:

;; This package provides automatic tracking of compilation history in Emacs.
;; It captures compilation commands, timing, results, and metadata to help
;; analyze build patterns and debug compilation issues.

;;; Code:

(require 'cl-lib)
(require 'vc)
(require 'vc-git)
(require 'vc-hooks)
(require 'json)
(require 'compile)
(require 'subr-x)

;;; Build Keybindings

(defvar compilation-history-map (make-sparse-keymap)
  "Keymap for compilation history commands.")

(define-key compilation-history-map (kbd "c") 'compile)

(global-set-key (kbd "C-c b") compilation-history-map)

;;; Customization

(defgroup compilation-history nil
  "Track compilation history in Emacs."
  :group 'tools
  :prefix "compilation-history-")

(defcustom compilation-history-db-file
  (expand-file-name "compilation-history.db" user-emacs-directory)
  "Path to the SQLite database file for compilation history."
  :type 'file
  :group 'compilation-history)

(defcustom compilation-history-command-truncate-length 25
  "The length to truncate the compile command to in the buffer name."
  :type 'integer
  :group 'compilation-history)

;;; Database Schema

(defconst compilation-history-db-schema
  "CREATE TABLE IF NOT EXISTS compilations (
    id TEXT PRIMARY KEY,
    buffer_name TEXT NOT NULL,
    compile_command TEXT NOT NULL,
    default_directory TEXT NOT NULL,
    start_time DATETIME NOT NULL,
    end_time DATETIME,
    exit_code INTEGER,
    killed BOOLEAN DEFAULT 0,
    git_repo TEXT,
    git_branch TEXT,
    git_commit TEXT,
    git_commit_message TEXT,
    git_remote_urls JSONB,
    os TEXT,
    os_version TEXT,
    emacs_version TEXT,
    output BLOB
  );"
  "SQL schema for the compilations table.")

;;; Buffer Name

(defun compilation-history--get-timestamp (&optional start-time)
  "Return a timestamp string."
  (or start-time
      (format-time-string "%Y%m%dT%H%M%S%6N")))

(defun compilation-history--get-path-string (default-directory)
  "Return the path string for the buffer name."
  (let* ((project-root (or (compilation-history--get-project-root default-directory)
                           default-directory))
         (project-name (file-name-nondirectory (directory-file-name project-root)))
         (relative-path (file-relative-name default-directory project-root)))
    (let ((relative-path (string-remove-suffix "/" relative-path)))
      (if (string-equal "." relative-path)
          project-name
        (concat project-name "--" (string-replace "/" "--" relative-path))))))

(defun compilation-history--sanitize-command (compile-command)
  "Return a sanitized version of the compile command."
  (let* ((cmd (replace-regexp-in-string "[^a-zA-Z0-9-]" "-" compile-command))
         (cmd (replace-regexp-in-string "-+" "-" cmd)))
    (if (> (length cmd) compilation-history-command-truncate-length)
        (substring cmd 0 compilation-history-command-truncate-length)
      cmd)))

(defun compilation-history--get-project-root (dir)
  "Return the project root for DIR."
  (vc-find-root dir ".git"))

(defun compilation-history--get-macos-version ()
  "Return the macOS version string."
  (when (eq system-type 'darwin)
    (string-trim (shell-command-to-string "sw_vers -productVersion"))))

(defun compilation-history--get-git-remote-urls ()
  "Return an alist of remote names to URLs for the current git repository."
  (let ((output (shell-command-to-string "git config --get-regexp '^remote\\..*\\.url$'")))
    (when-let* ((lines (split-string output "\n" t)))
      (mapcar (lambda (line)
                (let* ((parts (split-string line " "))
                       (key-parts (split-string (car parts) "\\."))
                       (remote-name (nth 1 key-parts))
                       (url (cadr parts)))
                  (cons remote-name url)))
              lines))))


(defun compilation-history--get-system-info (default-directory)
  "Return a plist of system information."
  (let ((info (list :os system-type
                    :os-version (compilation-history--get-macos-version)
                    :emacs-version (emacs-version))))
    (if-let* ((git-repo (vc-git-root default-directory)))
        (append info
                (list :git-repo git-repo
                      :git-branch (car (vc-git-branches))
                      :git-commit (vc-git-working-revision default-directory)
                      :git-commit-message (vc-git-get-change-comment default-directory "HEAD")
                      :git-remote-urls (compilation-history--get-git-remote-urls)))
      info)))

(defun compilation-history--generate-buffer-name (compile-command default-directory &optional start-time)
  "Generate a unique buffer name for a compilation history buffer."
  (let ((timestamp (compilation-history--get-timestamp start-time))
        (path-string (compilation-history--get-path-string default-directory))
        (command-sanitized (compilation-history--sanitize-command compile-command)))
    (format "*compilation-history-%s==%s__%s*"
            timestamp
            path-string
            command-sanitized)))

(defun compilation-history--partial-buffer-name (mode-name)
  "Generate a partially unique buffer name for a compilation."
  (format "*compilation-history-%s*" (compilation-history--get-timestamp)))

;;; Database Functions

(defun compilation-history--extract-id-from-buffer-name (buffer-name)
  "Extract the timestamp ID from a compilation history buffer name."
  (when (string-match "\\*compilation-history-\\(.*?\\)==" buffer-name)
    (match-string 1 buffer-name)))

(defun compilation-history--ensure-db ()
  "Ensure the compilation history database exists and is properly initialized."
  (let ((db-dir (file-name-directory compilation-history-db-file)))
    (unless (file-directory-p db-dir)
      (make-directory db-dir t))
    (compilation-history--execute-sql compilation-history-db-schema)))

(defun compilation-history--execute-sql (sql &optional params)
  "Execute SQL statement with optional PARAMS on the compilation history database."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (if params
            (sqlite-execute db sql params)
          (sqlite-execute db sql))
      (sqlite-close db))))

(defun compilation-history--insert-compilation-record (id buffer-name command default-directory system-info)
  "Insert a new compilation record into the database."
  (let ((sql "INSERT INTO compilations (id, buffer_name, compile_command, default_directory, start_time, git_repo, git_branch, git_commit, git_commit_message, git_remote_urls, os, os_version, emacs_version) VALUES (?, ?, ?, ?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?)"))
    (compilation-history--execute-sql
     sql
     (vector id
             buffer-name
             command
             default-directory
             (plist-get system-info :git-repo)
             (plist-get system-info :git-branch)
             (plist-get system-info :git-commit)
             (plist-get system-info :git-commit-message)
             (json-encode (plist-get system-info :git-remote-urls))
             (symbol-name (plist-get system-info :os))
             (plist-get system-info :os-version)
             (plist-get system-info :emacs-version)))))

(defun compilation-history--update-compilation-record (id exit-code output &optional killed)
  "Update a compilation record with completion data."
  (let ((sql "UPDATE compilations SET
                end_time = datetime('now'),
                exit_code = ?,
                output = ?,
                killed = ?
              WHERE id = ?"))
    (compilation-history--execute-sql
     sql
     (vector exit-code output (if killed 1 0) id))))

(defun compilation-history--finish-function (buffer status)
  "Finish function for compilation-finished-hook."
  (when-let* ((record-id (buffer-local-value 'compilation-history--record-id buffer)))
    (with-current-buffer buffer
      (let* ((output (buffer-substring-no-properties (point-min) (point-max)))
             (killed (string-match-p "killed\|interrupt" status))
             (exit-code (cond
                         ((string-match "exited abnormally with code \\([0-9]+\\)" status)
                          (string-to-number (match-string 1 status)))
                         ((string-match-p "finished" status)
                          0)
                         (killed
                          2)
                         (t
                          1))))
        (compilation-history--update-compilation-record record-id exit-code output killed)))))


(defun compilation-history--kill-buffer-function ()
  "Function to handle when compilation buffer is killed."
  (when-let* ((record-id compilation-history--record-id))
    (let ((output (buffer-substring-no-properties (point-min) (point-max))))
      (compilation-history--update-compilation-record record-id -1 output t))))

;;; Recompile Support

(defun compilation-history-set-recompile-command ()
  "Set buffer-local compile-command to make standard recompile work."
  (when compilation-history--original-command
    (setq-local compile-command compilation-history--original-command)
    (setq-local compilation-directory default-directory)))

;;; Public API

(defun compilation-history-init ()
  "Initialize the compilation history database."
  (interactive)
  (compilation-history--ensure-db)
  (message "Compilation history database initialized at %s" compilation-history-db-file))

(defun compilation-history--setup-function ()
  "Setup function for the compilation process."
  (let* ((command (car compilation-arguments))
         (partial-name (buffer-name))
         (record-id (when (string-match "\\*compilation-history-\\(.*\\)\\*" partial-name)
                      (match-string 1 partial-name))))
    (when record-id
      (let* ((buffer-name (compilation-history--generate-buffer-name command default-directory record-id))
             (system-info (compilation-history--get-system-info default-directory)))
        (rename-buffer buffer-name)
        (compilation-history--ensure-db)
        (setq-local compilation-history--record-id record-id)
        (setq-local compilation-history--original-command command)
        (setq-local compilation-history--system-info system-info)
        (compilation-history--insert-compilation-record record-id buffer-name command default-directory system-info)
        (compilation-history-set-recompile-command)
        (add-hook 'kill-buffer-hook #'compilation-history--kill-buffer-function nil t)))))

(defvar compilation-history--original-buffer-name-function nil)
(defvar compilation-history--original-setup-function nil)



(define-minor-mode compilation-history-mode
  "Toggle compilation history tracking."
  :global t
  :lighter " CompHist"
  (if compilation-history-mode
      (progn
        (setq compilation-history--original-buffer-name-function
              compilation-buffer-name-function)
        (setq compilation-buffer-name-function
              #'compilation-history--partial-buffer-name)
        (setq compilation-history--original-setup-function
              compilation-process-setup-function)
        (setq compilation-process-setup-function
              #'compilation-history--setup-function)
        (add-hook 'compilation-finish-functions #'compilation-history--finish-function))
    (setq compilation-buffer-name-function
          compilation-history--original-buffer-name-function)
    (setq compilation-process-setup-function
          compilation-history--original-setup-function)
    (remove-hook 'compilation-finish-functions #'compilation-history--finish-function)))

(provide 'compilation-history)

;;; compilation-history.el ends here
