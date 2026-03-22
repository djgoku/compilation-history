;;; compilation-history-view.el --- View compilation history -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jonathan Otsuka

;;; Commentary:
;; Paginated vtable-based UI for browsing compilation history records.

;;; Code:

(require 'cl-lib)
(require 'vtable)
(require 'compilation-history)

;;; Pagination

(cl-defstruct compilation-history-view-pagination
  "Pagination state for the compilation history view."
  (current-page 1)
  (total-records 0)
  (page-size 25))

(defun compilation-history-view--total-pages (pagination)
  "Return total number of pages for PAGINATION."
  (max 1 (ceiling (compilation-history-view-pagination-total-records pagination)
                   (compilation-history-view-pagination-page-size pagination))))

(defun compilation-history-view--page-offset (pagination)
  "Return the SQL OFFSET for the current page of PAGINATION."
  (* (1- (compilation-history-view-pagination-current-page pagination))
     (compilation-history-view-pagination-page-size pagination)))

(defun compilation-history-view--calculate-page-size ()
  "Calculate page size from current window height.
Subtracts space for header-line and pagination controls."
  (max 1 (- (window-height) 4)))

;;; Column Configuration

(defcustom compilation-history-view-columns
  '((:name "#" :key :row-number)
    (:name "Start Time" :key :start-time)
    (:name "Duration" :key :duration)
    (:name "Status" :key :status)
    (:name "Exit" :key :exit-code)
    (:name "Commit" :key :commit)
    (:name "Branch" :key :branch)
    (:name "Directory" :key :directory)
    (:name "Command" :key :command))
  "Column definitions for the compilation history view.
Each entry is a plist with :name (display header) and :key (data field keyword).
Users can reorder, remove, or modify entries. The getter dispatches on :key,
so column order does not affect data access."
  :type '(repeat plist)
  :group 'compilation-history)

;;; Buffer-local state

(defvar-local compilation-history-view--vtable nil
  "The vtable object for this buffer.")

(defvar-local compilation-history-view--pagination nil
  "Pagination state for this buffer.")

(defvar-local compilation-history-view--search-term nil
  "Current FTS search term, or nil.")

(defvar-local compilation-history-view--preview-mode nil
  "Whether preview mode is active.")

(defvar-local compilation-history-view--preview-window nil
  "The window used for previewing compilation buffers.")

;;; Getter

(defun compilation-history-view--get-value (object column-def)
  "Extract value from OBJECT plist for COLUMN-DEF.
COLUMN-DEF is a plist with at least :key. Dispatches on :key."
  (let ((key (plist-get column-def :key)))
    (pcase key
      (:row-number
       (+ (compilation-history-view--page-offset
           compilation-history-view--pagination)
          (plist-get object :row-index)
          1))
      (:commit
       (let ((val (plist-get object :commit)))
         (if (and val (> (length val) 7))
             (substring val 0 7)
           (or val ""))))
      (:duration
       (compilation-history-view--format-duration (plist-get object :duration)))
      (_
       (or (plist-get object key) "")))))

;;; Data Model

(defun compilation-history-view--format-duration (seconds)
  "Format SECONDS as a human-readable duration string.
Returns empty string if SECONDS is nil."
  (if seconds
      (format "%.1fs" seconds)
    ""))

(defun compilation-history-view--derive-status (exit-code killed end-time)
  "Derive status string from EXIT-CODE, KILLED flag, and END-TIME."
  (cond
   ((null end-time) "running")
   ((and killed (not (zerop killed))) "killed")
   ((and exit-code (zerop exit-code)) "success")
   (t "failure")))

(defun compilation-history-view--row-to-plist (row &optional index)
  "Convert a database ROW (list) to a plist for vtable display.
ROW is a list matching the SELECT * column order of the compilations table,
with an appended duration_seconds column from the SQL query.
INDEX is the 0-based row position within the current page."
  ;; Column order: id(0), buffer_name(1), compile_command(2), default_directory(3),
  ;; start_time(4), end_time(5), exit_code(6), killed(7), git_repo(8),
  ;; git_branch(9), git_commit(10), git_commit_message(11), git_remote_urls(12),
  ;; os(13), os_version(14), emacs_version(15), output(16), duration_seconds(17)
  (let* ((id (nth 0 row))
         (buffer-name (nth 1 row))
         (compile-command (nth 2 row))
         (default-directory (nth 3 row))
         (start-time (nth 4 row))
         (end-time (nth 5 row))
         (exit-code (nth 6 row))
         (killed (nth 7 row))
         (git-branch (nth 9 row))
         (git-commit (nth 10 row))
         (duration (nth 17 row)))
    (list :id id
          :buffer-name buffer-name
          :command compile-command
          :directory default-directory
          :start-time start-time
          :end-time end-time
          :duration duration
          :exit-code exit-code
          :status (compilation-history-view--derive-status exit-code killed end-time)
          :branch git-branch
          :commit git-commit
          :row-index (or index 0))))

;;; Mode

(defvar-keymap compilation-history-view-mode-map
  :parent special-mode-map
  "C-v" #'compilation-history-view-next-page
  "M-v" #'compilation-history-view-prev-page
  "<"   #'compilation-history-view-first-page
  ">"   #'compilation-history-view-last-page
  "g"   #'compilation-history-view-refresh
  "RET" #'compilation-history-view-open
  "SPC" #'compilation-history-view-preview
  "n"   #'compilation-history-view-preview-next
  "p"   #'compilation-history-view-preview-prev
  "M-n" #'compilation-history-view-preview-next
  "M-p" #'compilation-history-view-preview-prev
  "s"   #'compilation-history-view-search)

(define-derived-mode compilation-history-view-mode special-mode "CompHist"
  "Major mode for browsing compilation history."
  (display-line-numbers-mode -1)
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (compilation-history-view-refresh)))
  (add-hook 'post-command-hook #'compilation-history-view--check-preview-mode)
  (add-hook 'kill-buffer-hook
            (lambda () (remove-hook 'post-command-hook #'compilation-history-view--check-preview-mode))
            nil t))

;;; Rendering

(defun compilation-history-view--make-vtable-columns ()
  "Build vtable column specs from `compilation-history-view-columns'."
  (mapcar (lambda (col-def)
            (let ((name (plist-get col-def :name)))
              (list :name name
                    :getter (lambda (object _table)
                              (compilation-history-view--get-value object col-def)))))
          compilation-history-view-columns))

(defun compilation-history-view--render ()
  "Render the vtable and pagination in the current buffer."
  (let* ((inhibit-read-only t)
         (page-size (compilation-history-view-pagination-page-size
                     compilation-history-view--pagination))
         (total (compilation-history--count-records))
         (pagination compilation-history-view--pagination))
    (setf (compilation-history-view-pagination-total-records pagination) total)
    ;; Clamp current page
    (let ((max-page (compilation-history-view--total-pages pagination)))
      (when (> (compilation-history-view-pagination-current-page pagination) max-page)
        (setf (compilation-history-view-pagination-current-page pagination) max-page)))
    ;; Fetch data
    (let* ((offset (compilation-history-view--page-offset pagination))
           (rows (compilation-history--query-page page-size offset))
           (objects (cl-loop for row in rows
                             for i from 0
                             collect (compilation-history-view--row-to-plist row i))))
      (erase-buffer)
      (setq compilation-history-view--vtable
            (make-vtable
             :columns (compilation-history-view--make-vtable-columns)
             :objects objects
             :use-header-line t
             :insert t))
      (goto-char (point-max))
      (insert "\n")
      (compilation-history-view--insert-pagination)
      ;; Move point to first data row
      (goto-char (point-min))
      (compilation-history-view--update-mode-line))))

(defun compilation-history-view--update-mode-line ()
  "Update mode-line to show pagination info."
  (let* ((pagination compilation-history-view--pagination)
         (current (compilation-history-view-pagination-current-page pagination))
         (total-pages (compilation-history-view--total-pages pagination))
         (total-records (compilation-history-view-pagination-total-records pagination)))
    (setq mode-line-format
          (list " CompHist  "
                (format "Page %d of %d (%d records)" current total-pages total-records)
                "  "
                'mode-line-misc-info))))

(defun compilation-history-view--insert-pagination ()
  "Insert pagination controls below the vtable."
  (let* ((pagination compilation-history-view--pagination)
         (current (compilation-history-view-pagination-current-page pagination))
         (total-pages (compilation-history-view--total-pages pagination))
         (total-records (compilation-history-view-pagination-total-records pagination))
         (on-first (= current 1))
         (on-last (= current total-pages)))
    (insert "\n")
    (compilation-history-view--insert-button "First" #'compilation-history-view-first-page on-first)
    (insert " ")
    (compilation-history-view--insert-button "Previous" #'compilation-history-view-prev-page on-first)
    (insert (format " Page %d of %d (%d records) " current total-pages total-records))
    (compilation-history-view--insert-button "Next" #'compilation-history-view-next-page on-last)
    (insert " ")
    (compilation-history-view--insert-button "Last" #'compilation-history-view-last-page on-last)))

(defun compilation-history-view--insert-button (label action &optional disabled)
  "Insert a text button with LABEL that calls ACTION.
When DISABLED is non-nil, button is dimmed and non-interactive."
  (if disabled
      (insert (propertize (format "[%s]" label) 'face 'shadow))
    (insert-text-button (format "[%s]" label)
                        'action (lambda (_) (funcall action))
                        'follow-link t)))

;;;###autoload
(defun compilation-history-view ()
  "Open the compilation history view buffer."
  (interactive)
  (compilation-history--ensure-db)
  (let ((buf (get-buffer-create "*Compilation History*")))
    (with-current-buffer buf
      (compilation-history-view-mode)
      (setq compilation-history-view--pagination
            (make-compilation-history-view-pagination :page-size 25))
      (compilation-history-view--render))
    (switch-to-buffer buf)
    buf))

;;; Navigation

(defun compilation-history-view-next-page ()
  "Go to the next page."
  (interactive)
  (let* ((pagination compilation-history-view--pagination)
         (max-page (compilation-history-view--total-pages pagination)))
    (when (< (compilation-history-view-pagination-current-page pagination) max-page)
      (cl-incf (compilation-history-view-pagination-current-page pagination))
      (compilation-history-view--render))))

(defun compilation-history-view-prev-page ()
  "Go to the previous page."
  (interactive)
  (let ((pagination compilation-history-view--pagination))
    (when (> (compilation-history-view-pagination-current-page pagination) 1)
      (cl-decf (compilation-history-view-pagination-current-page pagination))
      (compilation-history-view--render))))

(defun compilation-history-view-first-page ()
  "Go to the first page."
  (interactive)
  (let ((pagination compilation-history-view--pagination))
    (unless (= (compilation-history-view-pagination-current-page pagination) 1)
      (setf (compilation-history-view-pagination-current-page pagination) 1)
      (compilation-history-view--render))))

(defun compilation-history-view-last-page ()
  "Go to the last page."
  (interactive)
  (let* ((pagination compilation-history-view--pagination)
         (max-page (compilation-history-view--total-pages pagination)))
    (unless (= (compilation-history-view-pagination-current-page pagination) max-page)
      (setf (compilation-history-view-pagination-current-page pagination) max-page)
      (compilation-history-view--render))))

(defun compilation-history-view-refresh ()
  "Refresh the view, recalculating page size from window height."
  (interactive)
  (setf (compilation-history-view-pagination-page-size
         compilation-history-view--pagination)
        (compilation-history-view--calculate-page-size))
  (compilation-history-view--render))

;;; Opening

(defun compilation-history-view--get-or-create-compilation-buffer (record)
  "Get or create the compilation buffer for RECORD.
Reuses existing buffer if still alive, otherwise creates from database."
  (let* ((buf-name (plist-get record :buffer-name))
         (id (plist-get record :id))
         (existing (get-buffer buf-name)))
    (or existing
        (let ((output (compilation-history--get-output id))
              (buf (get-buffer-create buf-name)))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (when output (insert output)))
            (compilation-mode)
            (setq buffer-read-only t))
          buf))))

(defun compilation-history-view--display-record (record)
  "Display compilation buffer for RECORD in the other window.
When preview mode is active and the preview window is alive, reuses
that window instead of opening a new one.
Returns the displayed buffer."
  (let ((buf (compilation-history-view--get-or-create-compilation-buffer record)))
    (if (and compilation-history-view--preview-window
            (window-live-p compilation-history-view--preview-window))
        (set-window-buffer compilation-history-view--preview-window buf)
      (let ((win (display-buffer buf '(nil (inhibit-same-window . t)))))
        (setq compilation-history-view--preview-window win)))
    buf))

(defun compilation-history-view-open ()
  "Open the compilation record at point in other window and switch to it."
  (interactive)
  (setq compilation-history-view--preview-mode nil)
  (setq compilation-history-view--preview-window nil)
  (if-let* ((object (vtable-current-object)))
      (let* ((buf (compilation-history-view--display-record object))
             (win (get-buffer-window buf)))
        (when win (select-window win)))
    (message "No compilation record at point")))

;;; Preview

(defun compilation-history-view-preview ()
  "Preview the compilation record at point without switching focus."
  (interactive)
  (if-let* ((object (vtable-current-object)))
      (let ((view-window (selected-window)))
        (compilation-history-view--display-record object)
        (setq compilation-history-view--preview-mode t)
        (select-window view-window))
    (message "No compilation record at point")))

(defun compilation-history-view-preview-next ()
  "Move to next row and preview it if preview mode is active.
No-op if preview mode is not active."
  (interactive)
  (when compilation-history-view--preview-mode
    (forward-line 1)
    (when-let* ((object (vtable-current-object)))
      (let ((view-window (selected-window)))
        (compilation-history-view--display-record object)
        (select-window view-window)))))

(defun compilation-history-view-preview-prev ()
  "Move to previous row and preview it if preview mode is active.
No-op if preview mode is not active."
  (interactive)
  (when compilation-history-view--preview-mode
    (forward-line -1)
    (when-let* ((object (vtable-current-object)))
      (let ((view-window (selected-window)))
        (compilation-history-view--display-record object)
        (select-window view-window)))))

(defun compilation-history-view-search ()
  "Search compilation history (not yet implemented)." (interactive) (message "Search not yet implemented"))

(defun compilation-history-view--check-preview-mode ()
  "Deactivate preview mode if the view buffer is no longer in the selected window."
  (when-let* ((view-buf (get-buffer "*Compilation History*")))
    (when (buffer-local-value 'compilation-history-view--preview-mode view-buf)
      (unless (eq (window-buffer (selected-window)) view-buf)
        (with-current-buffer view-buf
          (setq compilation-history-view--preview-mode nil)
          (setq compilation-history-view--preview-window nil))))))

(provide 'compilation-history-view)
;;; compilation-history-view.el ends here
