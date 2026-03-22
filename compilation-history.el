;;; compilation-history.el --- Track compilation history -*- lexical-binding: t; -*-

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
;;
;; Suggested keybinding:
;;   (global-set-key (kbd "C-c c") compilation-history-map)

;;; Code:

(require 'cl-lib)
(require 'vc)
(require 'vc-git)
(require 'vc-hooks)
(require 'json)
(require 'compile)
(require 'subr-x)

;;; Keymaps

(autoload 'compilation-history-view "compilation-history-view"
  "Open the compilation history view buffer." t)

(defvar compilation-history-map (make-sparse-keymap)
  "Keymap for compilation history commands.")

(define-key compilation-history-map (kbd "c") 'compile)
(define-key compilation-history-map (kbd "v") 'compilation-history-view)

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

;;; Buffer-local Variables

(defvar compile-command)           ; built-in, silence byte-compiler
(defvar compilation-directory)     ; built-in, silence byte-compiler

(defvar-local compilation-history-record nil
  "The compilation-history record for this buffer.")

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

(defconst compilation-history-db-fts-schema
  "CREATE VIRTUAL TABLE IF NOT EXISTS compilations_fts USING fts5(
    compile_command,
    default_directory,
    git_branch,
    output,
    content=compilations,
    content_rowid=rowid,
    tokenize='trigram'
  );"
  "SQL schema for the FTS5 full-text search table.
Uses trigram tokenizer for substring matching.
Indexes compile_command, default_directory, git_branch, and output.")

(defconst compilation-history-db-fts-triggers
  '("CREATE TRIGGER IF NOT EXISTS compilations_fts_insert AFTER INSERT ON compilations BEGIN
      INSERT INTO compilations_fts(rowid, compile_command, default_directory, git_branch, output)
      VALUES (new.rowid, new.compile_command, new.default_directory, new.git_branch, new.output);
    END;"
    "CREATE TRIGGER IF NOT EXISTS compilations_fts_delete AFTER DELETE ON compilations BEGIN
      INSERT INTO compilations_fts(compilations_fts, rowid, compile_command, default_directory, git_branch, output)
      VALUES('delete', old.rowid, old.compile_command, old.default_directory, old.git_branch, old.output);
    END;"
    "CREATE TRIGGER IF NOT EXISTS compilations_fts_update AFTER UPDATE ON compilations BEGIN
      INSERT INTO compilations_fts(compilations_fts, rowid, compile_command, default_directory, git_branch, output)
      VALUES('delete', old.rowid, old.compile_command, old.default_directory, old.git_branch, old.output);
      INSERT INTO compilations_fts(rowid, compile_command, default_directory, git_branch, output)
      VALUES (new.rowid, new.compile_command, new.default_directory, new.git_branch, new.output);
    END;")
  "SQL triggers to keep FTS5 index in sync with compilations table.")

(cl-defstruct compilation-history compile-command record-id system-info buffer-name default-directory exit-code message)

;;; Buffer Name

(defun compilation-history--get-timestamp (&optional start-time)
  "Return a timestamp string in YYYYMMDDTHHMMSSffffff format.
If START-TIME is non-nil, return it unchanged."
  (or start-time
      (format-time-string "%Y%m%dT%H%M%S%6N")))

(defun compilation-history--get-path-string (dir)
  "Return the path string for the buffer name from DIR."
  (let* ((project-root (or (compilation-history--get-project-root dir)
                           dir))
         (project-name (file-name-nondirectory (directory-file-name project-root)))
         (relative-path (file-relative-name dir project-root)))
    (let ((relative-path (string-remove-suffix "/" relative-path)))
      (if (string-equal "." relative-path)
          project-name
        (concat project-name "--" (string-replace "/" "--" relative-path))))))

(defun compilation-history--sanitize-command (command)
  "Return a sanitized version of COMMAND for use in buffer names."
  (let* ((cmd (replace-regexp-in-string "[^a-zA-Z0-9-]" "-" command))
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


(defun compilation-history--get-system-info (dir)
  "Return a plist of system information for DIR."
  (let ((info (list :os system-type
                    :os-version (compilation-history--get-macos-version)
                    :emacs-version (emacs-version))))
    (if-let* ((git-repo (vc-git-root dir)))
        (append info
                (list :git-repo git-repo
                      :git-branch (car (vc-git-branches))
                      :git-commit (vc-git-working-revision dir)
                      :git-commit-message (vc-git-get-change-comment dir "HEAD")
                      :git-remote-urls (compilation-history--get-git-remote-urls)))
      info)))

(defun compilation-history--generate-buffer-name (command dir &optional start-time)
  "Generate a unique buffer name for COMMAND in DIR."
  (let ((timestamp (compilation-history--get-timestamp start-time))
        (path-string (compilation-history--get-path-string dir))
        (command-sanitized (compilation-history--sanitize-command command)))
    (format "*compilation-history-%s==%s__%s*"
            timestamp
            path-string
            command-sanitized)))

(defun compilation-history--partial-buffer-name (_mode)
  "Generate a partially unique buffer name for a compilation.
_MODE is required by `compilation-buffer-name-function' but unused."
  (compilation-history--maybe-fix-buffer-compile-command)
  (format "*compilation-history-%s*" (compilation-history--get-timestamp)))

(defun compilation-history--maybe-fix-buffer-compile-command ()
  "Restore buffer-local `compile-command' to match the compilation record.
When compiling from an existing compilation-history buffer, Emacs may
overwrite the buffer-local `compile-command'.  This function detects
that case and restores it to the value stored in the record."
  (when (and (local-variable-p 'compile-command)
             (string-prefix-p "*compilation-history-" (buffer-name))
             (boundp 'compilation-history-record)
             compilation-history-record)
    (let ((record-command (compilation-history-compile-command compilation-history-record)))
      (unless (equal compile-command record-command)
        (with-no-warnings (setq-local compile-command record-command))))))
;;; Database Functions

(defun compilation-history--extract-id-from-buffer-name (buffer-name)
  "Extract the timestamp ID from a compilation history buffer name."
  (when (string-match "\\*compilation-history-\\(.*?\\)==" buffer-name)
    (match-string 1 buffer-name)))

(defun compilation-history--ensure-db ()
  "Ensure the compilation history database exists and is initialized.
Creates the main table, FTS5 virtual table, and sync triggers
if they don't exist."
  (let ((db-dir (file-name-directory compilation-history-db-file)))
    (unless (file-directory-p db-dir)
      (make-directory db-dir t))
    (let ((db (sqlite-open compilation-history-db-file)))
      (unwind-protect
          (progn
            (sqlite-execute db compilation-history-db-schema)
            (sqlite-execute db compilation-history-db-fts-schema)
            (dolist (trigger compilation-history-db-fts-triggers)
              (sqlite-execute db trigger)))
        (sqlite-close db)))))

(defun compilation-history-rebuild-fts ()
  "Drop and recreate the FTS5 table and triggers.
Use after upgrading the FTS schema (e.g., adding columns)."
  (interactive)
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (progn
          (sqlite-execute db "DROP TRIGGER IF EXISTS compilations_fts_insert")
          (sqlite-execute db "DROP TRIGGER IF EXISTS compilations_fts_delete")
          (sqlite-execute db "DROP TRIGGER IF EXISTS compilations_fts_update")
          (sqlite-execute db "DROP TABLE IF EXISTS compilations_fts")
          (sqlite-execute db compilation-history-db-fts-schema)
          (dolist (trigger compilation-history-db-fts-triggers)
            (sqlite-execute db trigger))
          (sqlite-execute db "INSERT INTO compilations_fts(compilations_fts) VALUES('rebuild')"))
      (sqlite-close db)))
  (message "FTS index rebuilt"))

(defun compilation-history--execute-sql (sql &optional params)
  "Execute SQL statement with optional PARAMS on the compilation history database."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (if params
            (sqlite-execute db sql params)
          (sqlite-execute db sql))
      (sqlite-close db))))

(defun compilation-history--insert-compilation-record (record)
  "Insert RECORD into the database."
  (let* ((id (compilation-history-record-id record))
         (buffer-name (compilation-history-buffer-name record))
         (command (compilation-history-compile-command record))
         (dir (compilation-history-default-directory record))
         (system-info (compilation-history-system-info record))
         (sql "INSERT INTO compilations (id, buffer_name, compile_command, default_directory, start_time, git_repo, git_branch, git_commit, git_commit_message, git_remote_urls, os, os_version, emacs_version) VALUES (?, ?, ?, ?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?)"))
    (compilation-history--execute-sql
     sql
     (vector id
             buffer-name
             command
             dir
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

(defun compilation-history--count-records ()
  "Return the total number of compilation records."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (caar (sqlite-select db "SELECT COUNT(*) FROM compilations"))
      (sqlite-close db))))

(defconst compilation-history--page-columns
  "id, buffer_name, compile_command, default_directory, start_time, end_time, exit_code, killed, git_branch, git_commit"
  "Columns selected for page queries (excludes large output BLOB).")

(defconst compilation-history--duration-expr
  "CASE WHEN end_time IS NOT NULL AND start_time IS NOT NULL THEN (julianday(end_time) - julianday(start_time)) * 86400.0 ELSE NULL END AS duration_seconds"
  "SQL expression to compute duration in seconds.")

(defun compilation-history--query-page (limit offset)
  "Return LIMIT compilation records starting at OFFSET, newest first.
Each row includes a computed duration_seconds column appended at the end."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (sqlite-select db
                       (format "SELECT %s, %s FROM compilations ORDER BY start_time DESC LIMIT ? OFFSET ?"
                               compilation-history--page-columns
                               compilation-history--duration-expr)
                       (vector limit offset))
      (sqlite-close db))))

(defun compilation-history--get-output (id)
  "Return the output for compilation record with ID, or nil."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (caar (sqlite-select db
                             "SELECT output FROM compilations WHERE id = ?"
                             (vector id)))
      (sqlite-close db))))

(defconst compilation-history--fts-column-names
  '("compile_command" "default_directory" "git_branch" "output")
  "FTS-indexed column names for LIKE fallback.")

(defun compilation-history--search-needs-like-p (search-term)
  "Return non-nil if SEARCH-TERM needs LIKE fallback (value < 3 chars).
Handles both plain terms and column:value syntax."
  (let ((value (if (string-match "\\`\\([a-z_]+\\):\\(.+\\)\\'" search-term)
                   (match-string 2 search-term)
                 search-term)))
    (< (length value) 3)))

(defun compilation-history--like-sql-parts (search-term)
  "Parse SEARCH-TERM and return (where-clause . params) for LIKE query.
Handles plain terms (searches all FTS columns) and column:value syntax."
  (if (string-match "\\`\\([a-z_]+\\):\\(.+\\)\\'" search-term)
      (let ((col (match-string 1 search-term))
            (val (match-string 2 search-term)))
        (unless (member col compilation-history--fts-column-names)
          (user-error "Unknown search column: %s (valid: %s)"
                      col (mapconcat #'identity compilation-history--fts-column-names ", ")))
        (cons (format "%s LIKE ?" col)
              (vector (concat "%" val "%"))))
    ;; Plain term: search across all FTS-indexed columns
    (let ((clauses (mapcar (lambda (col) (format "%s LIKE ?" col))
                           compilation-history--fts-column-names))
          (pattern (concat "%" search-term "%")))
      (cons (format "(%s)" (mapconcat #'identity clauses " OR "))
            (apply #'vector (make-list (length compilation-history--fts-column-names) pattern))))))

(defun compilation-history--count-records-fts (search-term)
  "Return the number of compilation records matching SEARCH-TERM.
Uses LIKE for short terms (< 3 chars), FTS otherwise."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (if (compilation-history--search-needs-like-p search-term)
            (let ((parts (compilation-history--like-sql-parts search-term)))
              (caar (sqlite-select db
                                   (format "SELECT COUNT(*) FROM compilations WHERE %s" (car parts))
                                   (cdr parts))))
          (caar (sqlite-select db
                               "SELECT COUNT(*) FROM compilations WHERE rowid IN (SELECT rowid FROM compilations_fts WHERE compilations_fts MATCH ?)"
                               (vector search-term))))
      (sqlite-close db))))

(defun compilation-history--query-page-fts (limit offset search-term)
  "Return LIMIT matching records starting at OFFSET, newest first.
Uses LIKE for short terms (< 3 chars), FTS otherwise."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (if (compilation-history--search-needs-like-p search-term)
            (let ((parts (compilation-history--like-sql-parts search-term)))
              (sqlite-select db
                             (format "SELECT %s, %s FROM compilations WHERE %s ORDER BY start_time DESC LIMIT ? OFFSET ?"
                                     compilation-history--page-columns
                                     compilation-history--duration-expr
                                     (car parts))
                             (vconcat (cdr parts) (vector limit offset))))
          (sqlite-select db
                         (format "SELECT %s, %s FROM compilations WHERE rowid IN (SELECT rowid FROM compilations_fts WHERE compilations_fts MATCH ?) ORDER BY start_time DESC LIMIT ? OFFSET ?"
                                 compilation-history--page-columns
                                 compilation-history--duration-expr)
                         (vector search-term limit offset)))
      (sqlite-close db))))

(defun compilation-history--finish-function (buffer status)
  "Finish function for compilation-finished-hook."
  (when-let* ((record-id (compilation-history-record-id (buffer-local-value 'compilation-history-record buffer))))
    (with-current-buffer buffer
      (let* ((output (buffer-substring-no-properties (point-min) (point-max)))
             (killed (string-match-p "killed\|interrupt" status))
             (exit-code (compilation-history-exit-code (buffer-local-value 'compilation-history-record buffer))))
        (compilation-history--update-compilation-record record-id exit-code output killed))
      (setq-local compilation-arguments nil)
      ;; would be nice if we could switch to compilation-mode if in
      ;; comint-mode since if we try to use C-u g or g to re-compile
      ;; it doesn't work with a comint-mode buffer.  so maybe switch
      ;; to compilation-mode without running any hooks? if that is
      ;; possible
      (when (eq major-mode 'comint-mode)
        (setq-local buffer-read-only t)))))

(defun compilation-history--kill-buffer-function ()
  "Mark the compilation record as killed if it has no exit code yet.
Does nothing if the record already has an exit code, preventing
completed compilations from being incorrectly marked as killed."
  (when (and compilation-history-record
             (not (compilation-history-exit-code compilation-history-record)))
    (when-let* ((record-id (compilation-history-record-id compilation-history-record)))
      (let ((output (buffer-substring-no-properties (point-min) (point-max))))
        (compilation-history--update-compilation-record (compilation-history-record-id compilation-history-record) -1 output t)))))

(defun compilation-history--add-sentinel-metadata-advice (proc msg)
  "Simple debug advice for compilation-sentinel focusing on record-id and process."
  (let* ((buffer (process-buffer proc)))
    (with-current-buffer buffer
      (setf (compilation-history-exit-code compilation-history-record) (process-exit-status proc)
            (compilation-history-message compilation-history-record) msg))))

(defun compilation-history--maybe-save-history ()
  "This is came about since if we close emacs and a compilation is still in
progress we want to stop and save whatever output is present."
  (when compilation-in-progress
    (dolist (proc compilation-in-progress)
      (let* ((buffer (process-buffer proc)))
        (message "Killing compilation in buffer %s" (buffer-name buffer))
        (with-current-buffer buffer
          (call-interactively 'kill-compilation)
          (sit-for .25)
          (setf (compilation-history-exit-code compilation-history-record) (process-exit-status proc))
          (compilation-history--finish-function buffer "interrupt"))))))

;;; Recompile Support

(defun compilation-history-set-recompile-command ()
  "Set buffer-local compile-command to make standard recompile work."
  (unless (local-variable-p 'compile-command)
    (when (compilation-history-compile-command compilation-history-record)
      (with-no-warnings
        (setq-local compile-command (compilation-history-compile-command compilation-history-record))
        (setq-local compilation-directory default-directory)))))

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
        (setq-local compilation-history-record (make-compilation-history :record-id record-id :compile-command command :system-info system-info :buffer-name buffer-name :default-directory default-directory))
        (add-hook 'compilation-finish-functions #'compilation-history--finish-function nil t)
        (compilation-history--insert-compilation-record compilation-history-record)
        (compilation-history-set-recompile-command)
        (add-hook 'kill-buffer-hook #'compilation-history--kill-buffer-function nil t)))))

;;;###autoload
(define-minor-mode compilation-history-mode
  "Toggle compilation history tracking."
  :global t
  :lighter " CompHist"
  (if compilation-history-mode
      (progn
        (setq compilation-buffer-name-function
              #'compilation-history--partial-buffer-name)
        (setq compilation-process-setup-function
              #'compilation-history--setup-function)
        (advice-add 'compilation-sentinel :before #'compilation-history--add-sentinel-metadata-advice)
        (add-hook 'kill-emacs-hook #'compilation-history--maybe-save-history))
    (setq compilation-buffer-name-function nil)
    (setq compilation-process-setup-function nil)
    (advice-remove 'compilation-sentinel #'compilation-history--add-sentinel-metadata-advice)
    (remove-hook 'kill-emacs-hook #'compilation-history--maybe-save-history)))

(provide 'compilation-history)

;;; compilation-history.el ends here
