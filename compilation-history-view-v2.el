;;; compilation-history-view-v2.el --- VTable-based view for compilation history -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: djgoku
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.4.0"))
;; Keywords: compilation, tools, history, vtable

;;; Commentary:

;; This package provides a vtable-based view for compilation history.
;; It displays compilation records in a tabular format with interactive features.

;;; Code:

(require 'vtable)
(require 'compilation-history)
(require 'transient)

(defcustom compilation-history-view-v2-display-location 'bottom
  "Where to display the compilation history view buffer.
'bottom - Display at bottom of frame
'current - Display in current window"
  :type '(choice (const :tag "Bottom of frame" bottom)
                 (const :tag "Current window" current))
  :group 'compilation-history)

(defvar compilation-history-view-v2-buffer-name "*Compilation History V2*"
  "Name of the compilation history view buffer.")

(defvar compilation-history-view-v2--vtable nil
  "The vtable object for displaying compilation history.")

;;; Filter Variables

(defvar compilation-history-view-v2--filter-date-from nil
  "Filter start date in format YYYY-MM-DD.")

(defvar compilation-history-view-v2--filter-date-to nil
  "Filter end date in format YYYY-MM-DD.")

(defvar compilation-history-view-v2--filter-status nil
  "Filter by status: success, failed, killed, running, or nil for all.")

(defvar compilation-history-view-v2--filter-directory nil
  "Filter by directory path (partial match).")

(defvar compilation-history-view-v2--filter-command nil
  "Filter by command (partial match).")

(defvar compilation-history-view-v2--filter-output nil
  "Filter by output content (partial match).")

(defun compilation-history-view-v2--get-data ()
  "Get compilation history data from the database."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (sqlite-select db "SELECT id, buffer_name, compile_command, default_directory, start_time, end_time, exit_code, killed, git_repo, git_branch, git_commit FROM compilations ORDER BY start_time DESC")
      (sqlite-close db))))

(defun compilation-history-view-v2--apply-filters (data)
  "Apply active filters to DATA and return filtered results."
  (let ((filtered-data data))

    ;; Filter by date range
    (when compilation-history-view-v2--filter-date-from
      (setq filtered-data
            (seq-filter (lambda (row)
                          (let ((start-time (nth 4 row)))
                            (and start-time
                                 (not (string< start-time compilation-history-view-v2--filter-date-from)))))
                        filtered-data)))

    (when compilation-history-view-v2--filter-date-to
      (setq filtered-data
            (seq-filter (lambda (row)
                          (let ((start-time (nth 4 row)))
                            (and start-time
                                 (string< start-time (concat compilation-history-view-v2--filter-date-to " 23:59:59")))))
                        filtered-data)))

    ;; Filter by status
    (when compilation-history-view-v2--filter-status
      (setq filtered-data
            (seq-filter (lambda (row)
                          (let ((exit-code (nth 6 row))
                                (killed (nth 7 row)))
                            (pcase compilation-history-view-v2--filter-status
                              ('success (and exit-code (= exit-code 0) (= killed 0)))
                              ('failed (and exit-code (not (= exit-code 0)) (= killed 0)))
                              ('killed (= killed 1))
                              ('running (null exit-code)))))
                        filtered-data)))

    ;; Filter by directory
    (when compilation-history-view-v2--filter-directory
      (setq filtered-data
            (seq-filter (lambda (row)
                          (let ((directory (nth 3 row)))
                            (and directory
                                 (string-match-p (regexp-quote compilation-history-view-v2--filter-directory) directory))))
                        filtered-data)))

    ;; Filter by command
    (when compilation-history-view-v2--filter-command
      (setq filtered-data
            (seq-filter (lambda (row)
                          (let ((command (nth 2 row)))
                            (and command
                                 (string-match-p (regexp-quote compilation-history-view-v2--filter-command) command))))
                        filtered-data)))

    ;; Filter by output (requires querying the output column)
    (when compilation-history-view-v2--filter-output
      (let ((db (sqlite-open compilation-history-db-file)))
        (unwind-protect
            (setq filtered-data
                  (seq-filter (lambda (row)
                                (let* ((id (nth 0 row))
                                       (output-result (sqlite-select db "SELECT output FROM compilations WHERE id = ?" (vector id)))
                                       (output (and output-result (caar output-result))))
                                  (and output
                                       (string-match-p (regexp-quote compilation-history-view-v2--filter-output) output))))
                              filtered-data))
          (sqlite-close db))))

    filtered-data))

(defun compilation-history-view-v2--get-filtered-data ()
  "Get compilation history data with filters applied."
  (compilation-history-view-v2--apply-filters (compilation-history-view-v2--get-data)))

(defun compilation-history-view-v2--format-time (time-str)
  "Format TIME-STR for display."
  (if time-str
      (format-time-string "%Y-%m-%d %H:%M:%S" (date-to-time time-str))
    ""))

(defun compilation-history-view-v2--format-command (command max-width)
  "Format COMMAND for display, truncating if longer than MAX-WIDTH."
  (if (> (length command) max-width)
      (concat (substring command 0 (max 0 (- max-width 3))) "...")
    command))

(defun compilation-history-view-v2--format-directory (directory max-width)
  "Format DIRECTORY for display, truncating if longer than MAX-WIDTH."
  (if (> (length directory) max-width)
      (concat (substring directory 0 (max 0 (- max-width 3))) "...")
    directory))

(defun compilation-history-view-v2--format-git-branch (branch)
  "Format git BRANCH for display."
  (or branch ""))

(defun compilation-history-view-v2--format-git-commit (commit)
  "Format git COMMIT for display, showing short hash."
  (if commit
      (substring commit 0 (min 8 (length commit)))
    ""))

(defun compilation-history-view-v2--format-status (exit-code killed)
  "Format status based on EXIT-CODE and KILLED flag."
  (cond
   ((equal killed 1) "Killed")
   ((null exit-code) "Running")
   ((equal exit-code 0) "Success")
   (t (format "Failed (%d)" exit-code))))

(defun compilation-history-view-v2--format-duration (start-time end-time)
  "Format duration for display."
  (if (and start-time end-time)
      (format "%.1fs"
              (float-time
               (time-subtract (date-to-time end-time)
                              (date-to-time start-time))))
    ""))

(defun compilation-history-view-v2--calculate-column-widths ()
  "Calculate column widths based on window width."
  (let* ((window-width (window-width))
         ;; Reserve space for vtable overhead (separators and padding)
         (usable-width window-width) ; Let vtable handle its own spacing
         ;; Minimum widths for columns
         (min-time-width 19)  ; Exact size for timestamp
         (min-status-width 10) ; Just enough for "Failed (2)"
         (min-duration-width 8)
         (min-git-branch-width 15)  ; Expanded by 1.5x
         (min-git-commit-width 8)
         (min-directory-width 10)  ; Reduced
         (min-command-width 15)    ; Reduced to fit
         ;; Calculate total minimum width
         (min-total-width (+ min-time-width min-status-width min-duration-width
                             min-git-branch-width min-git-commit-width
                             min-directory-width min-command-width))
         ;; Scale factor if we need to shrink
         (scale-factor (if (< usable-width min-total-width)
                           (/ (float usable-width) min-total-width)
                         1.0))
         ;; Calculate actual widths
         (time-width (max 12 (floor (* min-time-width scale-factor))))
         (status-width (max 6 (floor (* min-status-width scale-factor))))
         (duration-width (max 5 (floor (* min-duration-width scale-factor))))
         (git-branch-width (max 8 (floor (* min-git-branch-width scale-factor))))
         (git-commit-width (max 6 (floor (* min-git-commit-width scale-factor))))
         ;; Remaining width for flexible columns
         (fixed-width (+ time-width status-width duration-width git-branch-width git-commit-width))
         (remaining-width (- usable-width fixed-width))
         ;; Split remaining width between directory and command (30% directory, 70% command)
         (directory-width (max 10 (floor (* remaining-width 0.3))))
         (command-width (max 15 (- remaining-width directory-width))))
    ;; Return widths in the same order as columns: Time, Status, Duration, Branch, Commit, Directory, Command
    (list time-width status-width duration-width git-branch-width git-commit-width directory-width command-width)))

(defun compilation-history-view-v2--create-vtable ()
  "Create and return a vtable for compilation history."
  (let ((data (compilation-history-view-v2--get-filtered-data))
        (widths (compilation-history-view-v2--calculate-column-widths)))
    (make-vtable
     :columns `((:name "Time" :width ,(nth 0 widths) :align left)
                (:name "Status" :width ,(nth 1 widths) :align left)
                (:name "Duration" :width ,(nth 2 widths) :align right)
                (:name "Branch" :width ,(nth 3 widths) :align left)
                (:name "Commit" :width ,(nth 4 widths) :align left)
                (:name "Directory" :width ,(nth 5 widths) :align left)
                (:name "Command" :width ,(nth 6 widths) :align left))
     :separator-width 1
     :use-header-line t
     :objects (mapcar (lambda (row)
                        (let ((id (nth 0 row))
                              (buffer-name (nth 1 row))
                              (command (nth 2 row))
                              (directory (nth 3 row))
                              (start-time (nth 4 row))
                              (end-time (nth 5 row))
                              (exit-code (nth 6 row))
                              (killed (nth 7 row))
                              (git-repo (nth 8 row))
                              (git-branch (nth 9 row))
                              (git-commit (nth 10 row)))
                          (list :id id
                                :buffer-name buffer-name
                                :time (compilation-history-view-v2--format-time start-time)
                                :command (compilation-history-view-v2--format-command command (nth 6 widths))
                                :directory (compilation-history-view-v2--format-directory directory (nth 5 widths))
                                :status (compilation-history-view-v2--format-status exit-code killed)
                                :duration (compilation-history-view-v2--format-duration start-time end-time)
                                :git-branch (compilation-history-view-v2--format-git-branch git-branch)
                                :git-commit (compilation-history-view-v2--format-git-commit git-commit))))
                      data)
     :getter (lambda (object column vtable)
               (pcase (vtable-column vtable column)
                 ("Time" (plist-get object :time))
                 ("Command" (plist-get object :command))
                 ("Directory" (plist-get object :directory))
                 ("Status" (plist-get object :status))
                 ("Duration" (plist-get object :duration))
                 ("Branch" (plist-get object :git-branch))
                 ("Commit" (plist-get object :git-commit)))))))
;;;###autoload
(defun compilation-history-view-v2 ()
  "Display compilation history in a vtable."
  (interactive)
  (let ((buffer (get-buffer-create compilation-history-view-v2-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (compilation-history-view-v2-mode)
        (setq compilation-history-view-v2--vtable
              (compilation-history-view-v2--create-vtable))
        ;; (vtable-insert compilation-history-view-v2--vtable)
        (goto-char (point-min))))
    (compilation-history-view-v2--display-buffer buffer)))

(defun compilation-history-view-v2--display-buffer (buffer)
  "Display BUFFER according to `compilation-history-view-v2-display-location'."
  (pcase compilation-history-view-v2-display-location
    ('bottom
     (let ((window (display-buffer-at-bottom buffer '((window-height . 0.3)))))
       (select-window window)))
    ('current
     (switch-to-buffer buffer))
    (_
     (switch-to-buffer buffer))))

(defun compilation-history-view-v2--get-full-record (id)
  "Get the full compilation record from database by ID."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect
        (car (sqlite-select db "SELECT buffer_name, compile_command, default_directory, output FROM compilations WHERE id = ?" (vector id)))
      (sqlite-close db))))

(defun compilation-history-view-v2-open-buffer-at-point (&optional keep-view-visible)
  "Open or recreate the compilation buffer for the current vtable row.
If KEEP-VIEW-VISIBLE is non-nil, display the compilation buffer in another window
without replacing the view."
  (interactive)
  (condition-case err
      (let ((object (vtable-current-object)))
        (if object
            (let* ((buffer-name (plist-get object :buffer-name))
                   (existing-buffer (get-buffer buffer-name)))
              (if existing-buffer
                  (if keep-view-visible
                      (compilation-history-view-v2--display-compilation-buffer existing-buffer)
                    (switch-to-buffer existing-buffer))
                ;; Buffer doesn't exist, recreate it
                (let* ((id (plist-get object :id))
                       (record (compilation-history-view-v2--get-full-record id)))
                  (if record
                      (let ((buffer-name (nth 0 record))
                            (compile-command (nth 1 record))
                            (default-directory (nth 2 record))
                            (output (nth 3 record)))
                        (compilation-history-view-v2--recreate-buffer buffer-name compile-command default-directory output keep-view-visible))
                    (message "Could not find compilation record for ID: %s" id)))))
          (message "No object at current point")))
    (error (message "Error getting current vtable object: %s" err))))

(defun compilation-history-view-v2--display-compilation-buffer (buffer)
  "Display compilation BUFFER while keeping the view visible.
Creates a split below the view if needed, or reuses existing compilation window.
Focus returns to the view for continued navigation."
  (let ((view-window (selected-window)))
    ;; Look for existing non-view, non-scratch window to reuse
    (let ((compilation-window (get-window-with-predicate
                               (lambda (w)
                                 (and (not (eq w view-window))
                                      (not (string= (buffer-name (window-buffer w)) "*scratch*"))
                                      (not (string= (buffer-name (window-buffer w)) compilation-history-view-v2-buffer-name)))))))
      (if compilation-window
          ;; Reuse existing compilation window
          (progn
            (select-window compilation-window)
            (switch-to-buffer buffer)
            ;; Return focus to view
            (select-window view-window))
        ;; No suitable window exists, create new split below view
        (let ((new-window (split-window view-window nil 'below)))
          (select-window new-window)
          (switch-to-buffer buffer)
          ;; Return focus to view
          (select-window view-window))))))

(defun compilation-history-view-v2--recreate-buffer (buffer-name compile-command default-directory output &optional keep-view-visible)
  "Recreate a compilation buffer with stored output and settings.
If KEEP-VIEW-VISIBLE is non-nil, display the buffer in another window."
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (when output
          (insert output))
        (compilation-mode)
        (setq-local compile-command compile-command)
        (setq-local default-directory default-directory)
        (setq-local compilation-directory default-directory)
        (setq-local compilation-history-record (make-compilation-history :compile-command compile-command :default-directory default-directory))
        (goto-char (point-min))))
    (if keep-view-visible
        (compilation-history-view-v2--display-compilation-buffer buffer)
      (switch-to-buffer buffer))))

;;; Filter Functions

(defun compilation-history-view-v2-clear-filters ()
  "Clear all active filters."
  (interactive)
  (setq compilation-history-view-v2--filter-date-from nil
        compilation-history-view-v2--filter-date-to nil
        compilation-history-view-v2--filter-status nil
        compilation-history-view-v2--filter-directory nil
        compilation-history-view-v2--filter-command nil
        compilation-history-view-v2--filter-output nil)
  (compilation-history-view-v2-refresh)
  (message "All filters cleared"))

(defun compilation-history-view-v2-set-date-from (from)
  "Set date filter from FROM date (YYYY-MM-DD format)."
  (interactive "sFrom date (YYYY-MM-DD, empty to clear): ")
  (setq compilation-history-view-v2--filter-date-from (if (string-empty-p from) nil from))
  (compilation-history-view-v2-refresh)
  (message "Date from filter: %s" (or from "cleared")))

(defun compilation-history-view-v2-set-date-to (to)
  "Set date filter to TO date (YYYY-MM-DD format)."
  (interactive "sTo date (YYYY-MM-DD, empty to clear): ")
  (setq compilation-history-view-v2--filter-date-to (if (string-empty-p to) nil to))
  (compilation-history-view-v2-refresh)
  (message "Date to filter: %s" (or to "cleared")))

(defun compilation-history-view-v2-set-date-filter (from to)
  "Set date range filter from FROM to TO (YYYY-MM-DD format)."
  (interactive "sFrom date (YYYY-MM-DD): \nsTo date (YYYY-MM-DD): ")
  (setq compilation-history-view-v2--filter-date-from (if (string-empty-p from) nil from)
        compilation-history-view-v2--filter-date-to (if (string-empty-p to) nil to))
  (compilation-history-view-v2-refresh)
  (message "Date filter applied: %s to %s"
           (or from "beginning") (or to "end")))

(defun compilation-history-view-v2-set-status-filter (status)
  "Set status filter to STATUS."
  (interactive (list (intern (completing-read "Status: "
                                              '("success" "failed" "killed" "running" "all")
                                              nil t))))
  (setq compilation-history-view-v2--filter-status (if (eq status 'all) nil status))
  (compilation-history-view-v2-refresh)
  (message "Status filter: %s" (or status "all")))

(defun compilation-history-view-v2-set-directory-filter (directory)
  "Set directory filter to DIRECTORY."
  (interactive "sDirectory (partial match): ")
  (setq compilation-history-view-v2--filter-directory (if (string-empty-p directory) nil directory))
  (compilation-history-view-v2-refresh)
  (message "Directory filter: %s" (or directory "none")))

(defun compilation-history-view-v2-set-command-filter (command)
  "Set command filter to COMMAND."
  (interactive "sCommand (partial match): ")
  (setq compilation-history-view-v2--filter-command (if (string-empty-p command) nil command))
  (compilation-history-view-v2-refresh)
  (message "Command filter: %s" (or command "none")))

(defun compilation-history-view-v2-set-output-filter (output)
  "Set output filter to OUTPUT."
  (interactive "sOutput (partial match): ")
  (setq compilation-history-view-v2--filter-output (if (string-empty-p output) nil output))
  (compilation-history-view-v2-refresh)
  (message "Output filter: %s" (or output "none")))

;;; Transient Menu

(transient-define-prefix compilation-history-view-v2-filter-menu ()
  "Transient menu for filtering compilation history."
  :info-manual "(compilation-history-view-v2) Filtering"
  ["Filters"
   ["Date Range"
    ("f" "From date..." compilation-history-view-v2-set-date-from)
    ("t" "To date..." compilation-history-view-v2-set-date-to)
    ("d" "Date range..." compilation-history-view-v2-set-date-filter)
    ("T" "Today only" (lambda () (interactive)
                        (let ((today (format-time-string "%Y-%m-%d")))
                          (compilation-history-view-v2-set-date-filter today today))))]
   ["Status"
    ("s" "Status..." compilation-history-view-v2-set-status-filter)
    ("S" "Success only" (lambda () (interactive)
                          (compilation-history-view-v2-set-status-filter 'success)))
    ("F" "Failed only" (lambda () (interactive)
                         (compilation-history-view-v2-set-status-filter 'failed)))]
   ["Content"
    ("D" "Directory..." compilation-history-view-v2-set-directory-filter)
    ("c" "Command..." compilation-history-view-v2-set-command-filter)
    ("o" "Output..." compilation-history-view-v2-set-output-filter)]]
  ["Actions"
   ("C" "Clear all filters" compilation-history-view-v2-clear-filters)
   ("r" "Refresh" compilation-history-view-v2-refresh)
   ("q" "Quit" transient-quit-one)])

(define-key compilation-history-map (kbd "v") 'compilation-history-view-v2)

(defvar compilation-history-view-v2-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") 'compilation-history-view-v2-refresh)
    (define-key map (kbd "q") 'quit-window)
    (define-key map (kbd "RET") 'compilation-history-view-v2-open-buffer-at-point)
    (define-key map (kbd "f") 'compilation-history-view-v2-filter-menu)
    (define-key map (kbd "/") 'compilation-history-view-v2-filter-menu)
    (define-key map (kbd "M-n") 'compilation-history-view-v2-next-item)
    (define-key map (kbd "M-p") 'compilation-history-view-v2-previous-item)
    map)
  "Keymap for compilation-history-view-v2-mode.")

(defun compilation-history-view-v2--on-window-resize ()
  "Handle window resize by refreshing the vtable."
  (when (and (eq major-mode 'compilation-history-view-v2-mode)
             compilation-history-view-v2--vtable)
    (compilation-history-view-v2-refresh)))

(define-derived-mode compilation-history-view-v2-mode special-mode "CompHist-V2"
  "Major mode for displaying compilation history in a vtable."
  (setq truncate-lines t)
  (setq display-line-numbers nil)  ; Disable line numbers for better alignment
  (add-hook 'window-size-change-functions
            #'compilation-history-view-v2--on-window-resize nil t))

(defun compilation-history-view-v2-refresh ()
  "Refresh the compilation history vtable."
  (interactive)
  (when compilation-history-view-v2--vtable
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq compilation-history-view-v2--vtable
            (compilation-history-view-v2--create-vtable))
      ;; (vtable-insert compilation-history-view-v2--vtable)
      (goto-char (point-min)))))

(defun compilation-history-view-v2-next-item ()
  "Move to next compilation history item and open its buffer."
  (interactive)
  (when compilation-history-view-v2--vtable
    (condition-case err
        (progn
          (forward-line 1)
          ;; Skip empty lines or header lines if we hit them
          (while (and (not (eobp)) (not (vtable-current-object)))
            (forward-line 1))
          (if (vtable-current-object)
              (compilation-history-view-v2-open-buffer-at-point t)
            (message "No next item")))
      (error (message "Error navigating: %s" err)))))

(defun compilation-history-view-v2-previous-item ()
  "Move to previous compilation history item and open its buffer."
  (interactive)
  (when compilation-history-view-v2--vtable
    (condition-case err
        (progn
          (forward-line -1)
          ;; Skip empty lines or header lines if we hit them
          (while (and (not (bobp)) (not (vtable-current-object)))
            (forward-line -1))
          (if (vtable-current-object)
              (compilation-history-view-v2-open-buffer-at-point t)
            (message "No previous item")))
      (error (message "Error navigating: %s" err)))))

(defun compilation-history-view-v2-reload ()
  "Reload the compilation-history-view-v2 module."
  (interactive)
  (unload-feature 'compilation-history-view-v2 t)
  (let ((file (or (locate-library "compilation-history-view-v2")
                  (expand-file-name "compilation-history-view-v2.el" default-directory))))
    (load-file file)))

(provide 'compilation-history-view-v2)

;;; compilation-history-view-v2.el ends here
