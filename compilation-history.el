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
    os TEXT,
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

    (when (string-suffix-p "/" relative-path)
      (setq relative-path (substring relative-path 0 -1)))
    (if (string-equal "." relative-path)
        project-name
      (concat project-name "--" (replace-regexp-in-string "/" "--" relative-path)))))

(defun compilation-history--sanitize-command (compile-command)
  "Return a sanitized version of the compile command."
  (let* ((cmd (replace-regexp-in-string "[^a-zA-Z0-9-]" "-" compile-command))
         (cmd (replace-regexp-in-string "-+" "-" cmd)))
    (if (> (length cmd) compilation-history-command-truncate-length)
        (substring cmd 0 compilation-history-command-truncate-length)
      cmd)))

(defun compilation-history--get-project-root (dir)
  "Return the project root for DIR."
  (when-let* ((root (locate-dominating-file dir ".git")))
    root))

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

;;; Public API

(defun compilation-history-init ()
  "Initialize the compilation history database."
  (interactive)
  (compilation-history--ensure-db)
  (message "Compilation history database initialized at %s" compilation-history-db-file))

(defun compilation-history--setup-function ()
  "Setup function for the compilation process."
  (let* ((command (car compilation-arguments))
         (buffer-name (compilation-history--generate-buffer-name command default-directory)))
    (rename-buffer buffer-name)))

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
              #'compilation-history--setup-function))
    (setq compilation-buffer-name-function
          compilation-history--original-buffer-name-function)
    (setq compilation-process-setup-function
          compilation-history--original-setup-function)))

(provide 'compilation-history)
