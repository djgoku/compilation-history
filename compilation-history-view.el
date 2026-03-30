;;; compilation-history-view.el --- View compilation history -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jonathan Carroll Otsuka

;; Author: Jonathan Carroll Otsuka <pitas.axioms0c@icloud.com>
;; Version: 0.2.1
;; Keywords: processes, tools
;; URL: https://github.com/djgoku/compilation-history

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Paginated vtable-based UI for browsing compilation history records.

;;; Code:

(require 'cl-lib)
(require 'vtable)
(require 'color)
(require 'ansi-color)
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
  (max 1 (- (window-height) 6)))

;;; Column Configuration

(defcustom compilation-history-view-split-direction 'horizontal
  "How to split the window when opening compilation history items.
`horizontal' splits above/below (horizontal divider),
`vertical' splits side-by-side (vertical divider)."
  :type '(choice (const :tag "Horizontal (above/below)" horizontal)
                 (const :tag "Vertical (side-by-side)" vertical))
  :group 'compilation-history)

(defcustom compilation-history-view-columns
  '((:name "#" :key :row-number)
    (:name "Start Time" :key :start-time)
    (:name "Duration" :key :duration :min-width 8)
    (:name "Status" :key :status)
    (:name "Exit" :key :exit-code :min-width 5)
    (:name "Commit" :key :commit :formatter compilation-history-view--format-commit)
    (:name "Branch" :key :branch)
    (:name "Directory" :key :directory :formatter compilation-history-view--format-directory)
    (:name "Command" :key :command :formatter compilation-history-view--format-command))
  "Column definitions for the compilation history view.
Each entry is a plist with:
  :name      - display header
  :key       - keyword identifying which data field to extract
  :formatter - optional function to format the raw value for display
  :min-width - optional minimum column width
  :max-width - optional maximum column width
  :align     - optional alignment (left or right)
Users can reorder, remove, or modify entries.  The getter dispatches on :key,
so column order does not affect data access."
  :type '(repeat
          (plist :key-type (choice (const :name)
                                   (const :key)
                                   (const :formatter)
                                   (const :min-width)
                                   (const :max-width)
                                   (const :align))
                 :value-type sexp))
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

(defvar-local compilation-history-view--opened-buffers nil
  "List of compilation buffers opened from this view.")

;;; Default Formatters

(defun compilation-history-view--format-commit (value)
  "Truncate commit hash VALUE to 7 characters."
  (if (and value (> (length value) 7))
      (substring value 0 7)
    (or value "")))

(defun compilation-history-view--format-directory (value)
  "Abbreviate directory VALUE and make it a clickable link if it exists."
  (if value
      (let ((display (abbreviate-file-name value)))
        (if (file-directory-p value)
            (buttonize display #'dired value)
          display))
    ""))

(defun compilation-history-view--format-command (command)
  "Collapse whitespace in COMMAND to single spaces for display."
  (if command
      (replace-regexp-in-string "[[:space:]]+" " " (string-trim command))
    ""))

;;; Getter

(defun compilation-history-view--get-value (object column-def)
  "Extract value from OBJECT plist for COLUMN-DEF.
COLUMN-DEF is a plist with at least :key and optionally :formatter.
If :formatter is set, the raw value is passed through it."
  (let* ((key (plist-get column-def :key))
         (formatter (plist-get column-def :formatter))
         (raw (pcase key
                (:row-number
                 (+ (compilation-history-view--page-offset
                     compilation-history-view--pagination)
                    (plist-get object :row-index)
                    1))
                (:duration
                 (compilation-history-view--format-duration (plist-get object :duration)))
                (_
                 (or (plist-get object key) "")))))
    (if formatter
        (funcall formatter raw)
      raw)))

;;; Data Model

(defun compilation-history-view--format-duration (seconds)
  "Format SECONDS as a human-readable duration string.
Under 60s: \"5.2s\".  Under 1h: \"2m 30s\".  Over 1h: \"1h 5m\".
Returns empty string if SECONDS is nil."
  (if seconds
      (let ((s (truncate seconds)))
        (cond
         ((< s 60) (format "%.1fs" seconds))
         ((< s 3600) (format "%dm %ds" (/ s 60) (% s 60)))
         (t (format "%dh %dm" (/ s 3600) (/ (% s 3600) 60)))))
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
ROW columns match `compilation-history--page-columns' with duration appended.
INDEX is the 0-based row position within the current page."
  ;; Column order: id(0), buffer_name(1), compile_command(2), default_directory(3),
  ;; start_time(4), end_time(5), exit_code(6), killed(7),
  ;; git_branch(8), git_commit(9), comint(10), duration_seconds(11)
  (let* ((id (nth 0 row))
         (buffer-name (nth 1 row))
         (compile-command (nth 2 row))
         (default-directory (nth 3 row))
         (start-time (nth 4 row))
         (end-time (nth 5 row))
         (exit-code (nth 6 row))
         (killed (nth 7 row))
         (git-branch (nth 8 row))
         (git-commit (nth 9 row))
         (comint-flag (nth 10 row))
         (duration (nth 11 row)))
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
          :comint comint-flag
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
  "s"   #'compilation-history-view-search
  "q"   #'compilation-history-view-quit
  "Q"   #'compilation-history-view-kill-all)

(define-derived-mode compilation-history-view-mode special-mode "CompHist"
  "Major mode for browsing compilation history."
  (display-line-numbers-mode -1)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (compilation-history-view-refresh))))

;;; Rendering

(defun compilation-history-view--row-colors ()
  "Return alternating row colors based on the current theme, or nil in batch mode."
  (when (display-graphic-p)
    (let ((bg (face-background 'default)))
      (when bg
        (list bg
              (if (eq (frame-parameter nil 'background-mode) 'dark)
                  (color-lighten-name bg 10)
                (color-darken-name bg 5)))))))

(defun compilation-history-view--make-vtable-columns ()
  "Build vtable column specs from `compilation-history-view-columns'."
  (mapcar (lambda (col-def)
            (let ((spec (list :name (plist-get col-def :name)
                              :getter (lambda (object _table)
                                        (compilation-history-view--get-value object col-def)))))
              (when-let* ((min-w (plist-get col-def :min-width)))
                (setq spec (plist-put spec :min-width min-w)))
              (when-let* ((max-w (plist-get col-def :max-width)))
                (setq spec (plist-put spec :max-width max-w)))
              (when-let* ((align (plist-get col-def :align)))
                (setq spec (plist-put spec :align align)))
              spec))
          compilation-history-view-columns))

(defun compilation-history-view--render ()
  "Render the vtable and pagination in the current buffer."
  (let* ((inhibit-read-only t)
         (page-size (compilation-history-view-pagination-page-size
                     compilation-history-view--pagination))
         (search compilation-history-view--search-term)
         (pagination compilation-history-view--pagination))
    ;; Single DB connection for both count and page query
    (compilation-history--with-db _
      (let ((total (or (if search
                          (compilation-history--count-records-fts search)
                        (compilation-history--count-records))
                      0)))
        (setf (compilation-history-view-pagination-total-records pagination) total))
      ;; Clamp current page
      (let ((max-page (compilation-history-view--total-pages pagination)))
        (when (> (compilation-history-view-pagination-current-page pagination) max-page)
          (setf (compilation-history-view-pagination-current-page pagination) max-page)))
      ;; Fetch data
      (let* ((offset (compilation-history-view--page-offset pagination))
             (rows (if search
                       (compilation-history--query-page-fts page-size offset search)
                     (compilation-history--query-page page-size offset)))
             (objects (cl-loop for row in rows
                             for i from 0
                             collect (compilation-history-view--row-to-plist row i))))
      (erase-buffer)
      (if (null objects)
          (progn
            (setq compilation-history-view--vtable nil)
            (insert (propertize "No compilations found." 'face 'shadow)))
        (setq compilation-history-view--vtable
              (make-vtable
               :columns (compilation-history-view--make-vtable-columns)
               :objects objects
               :use-header-line t
               :row-colors (compilation-history-view--row-colors)
               ;; vtable rows carry a text-property keymap that shadows the
               ;; mode-map.  We must re-bind interactive keys here so they
               ;; work when point is on a table row.  The mode-map bindings
               ;; (compilation-history-view-mode-map) still cover areas
               ;; outside the table (header, footer, empty space).
               :keymap (define-keymap
                         "g"   #'compilation-history-view-refresh
                         "q"   #'compilation-history-view-quit
                         "Q"   #'compilation-history-view-kill-all
                         "n"   #'compilation-history-view-preview-next
                         "p"   #'compilation-history-view-preview-prev
                         "M-n" #'compilation-history-view-preview-next
                         "M-p" #'compilation-history-view-preview-prev
                         "s"   #'compilation-history-view-search
                         "<mouse-1>" #'compilation-history-view-open
                         "<mouse-2>" #'compilation-history-view-open)
               :insert t)))
      (goto-char (point-max))
      (insert "\n")
      (compilation-history-view--insert-pagination)
      ;; Move point to first data row
      (goto-char (point-min))
      (compilation-history-view--update-mode-line)))))

(defun compilation-history-view--update-mode-line ()
  "Update mode-line to show pagination info via `mode-name'.
Preserves the default `mode-line-format' so users keep standard
mode-line segments (input method, narrowing, global modes, etc.)."
  (let* ((pagination compilation-history-view--pagination)
         (current (compilation-history-view-pagination-current-page pagination))
         (total-pages (compilation-history-view--total-pages pagination))
         (total-records (compilation-history-view-pagination-total-records pagination)))
    (setq mode-name
          (format "CompHist  Page %d of %d (%d records)%s"
                  current total-pages total-records
                  (if compilation-history-view--search-term
                      (format "  [search: %s]" compilation-history-view--search-term)
                    "")))
    (force-mode-line-update)))

(defun compilation-history-view--insert-pagination ()
  "Insert pagination controls below the vtable."
  (let* ((pagination compilation-history-view--pagination)
         (current (compilation-history-view-pagination-current-page pagination))
         (total-pages (compilation-history-view--total-pages pagination))
         (total-records (compilation-history-view-pagination-total-records pagination))
         (on-first (= current 1))
         (on-last (= current total-pages)))
    (insert "\n")
    (let* ((left-keys "RET:open │ SPC:preview │ n/p:nav │ s:search │ C-v/M-v:page")
           (right-keys "g:refresh │ q:quit │ Q:kill-all")
           (center (concat "[First] [Previous]"
                           (format " Page %d of %d (%d records) " current total-pages total-records)
                           "[Next] [Last]"))
           (total-width (+ (length left-keys) 2 (length center) 2 (length right-keys)))
           (center-padding (max 1 (/ (- (window-width) total-width) 3))))
      ;; Left keys
      (let ((sep (propertize " │ " 'face 'vtable)))
        (insert (propertize "RET" 'face 'shadow) ":open" sep
                (propertize "SPC" 'face 'shadow) ":preview" sep
                (propertize "n/p" 'face 'shadow) ":nav" sep
                (propertize "s" 'face 'shadow) ":search" sep
                (propertize "C-v/M-v" 'face 'shadow) ":page"))
      (insert (make-string center-padding ?\s))
      ;; Center pagination
      (compilation-history-view--insert-button "First" #'compilation-history-view-first-page on-first)
      (insert " ")
      (compilation-history-view--insert-button "Previous" #'compilation-history-view-prev-page on-first)
      (insert (format " Page %d of %d (%d records) " current total-pages total-records))
      (compilation-history-view--insert-button "Next" #'compilation-history-view-next-page on-last)
      (insert " ")
      (compilation-history-view--insert-button "Last" #'compilation-history-view-last-page on-last)
      ;; Right keys
      (insert (make-string center-padding ?\s))
      (let ((sep (propertize " │ " 'face 'vtable)))
        (insert (propertize "g" 'face 'shadow) ":refresh" sep
                (propertize "q" 'face 'shadow) ":quit" sep
                (propertize "Q" 'face 'shadow) ":kill-all")))))

(defun compilation-history-view--insert-button (label action &optional disabled)
  "Insert a text button with LABEL that call ACTION.
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
    (pop-to-buffer buf '((display-buffer-reuse-window display-buffer-same-window)))
    (unless (derived-mode-p 'compilation-history-view-mode)
      (compilation-history-view-mode)
      (setq compilation-history-view--pagination
            (make-compilation-history-view-pagination
             :page-size (compilation-history-view--calculate-page-size))))
    (compilation-history-view--render)
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
              (buf (get-buffer-create buf-name))
              (dir (plist-get record :directory))
              (cmd (plist-get record :command))
              (comint-flag (and (plist-get record :comint)
                                (not (zerop (plist-get record :comint))))))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (when output (insert output)))
            (setq default-directory dir)
            (compilation-mode)
            (font-lock-mode -1)
            (let ((inhibit-read-only t))
              (ansi-color-apply-on-region (point-min) (point-max)))
            (setq-local compile-command cmd)
            (setq-local compilation-directory dir)
            (setq-local compilation-arguments (list cmd (when comint-flag t) nil nil))
            (setq-local compilation-history-record
                        (make-compilation-history
                         :record-id id
                         :command cmd
                         :buffer-name buf-name
                         :compile-directory dir
                         :comint comint-flag))
            (compilation-history-buffer-mode 1))
          buf))))

(defun compilation-history-view--display-action ()
  "Return a `display-buffer' action for the view split."
  `(display-buffer-in-direction (inhibit-same-window . t)
                                (direction . ,(if (eq compilation-history-view-split-direction 'horizontal)
                                                  'below
                                                'right))))

(defun compilation-history-view--display-record (record)
  "Display compilation buffer for RECORD in the other window.
When preview mode is active and the preview window is alive, reuses
that window instead of opening a new one.
Returns the displayed buffer."
  (let ((view-buf (get-buffer "*Compilation History*"))
        (buf (compilation-history-view--get-or-create-compilation-buffer record)))
    (if (and compilation-history-view--preview-window
            (window-live-p compilation-history-view--preview-window))
        (set-window-buffer compilation-history-view--preview-window buf)
      (let ((win (display-buffer buf (compilation-history-view--display-action))))
        (with-current-buffer view-buf
          (setq compilation-history-view--preview-window win))))
    (with-current-buffer view-buf
      (cl-pushnew buf compilation-history-view--opened-buffers))
    buf))

(defun compilation-history-view-open (&optional event)
  "Follow button at point, or open the compilation record.
When called from a mouse EVENT, move point to the click position first."
  (interactive (list last-input-event))
  (when (mouse-event-p event)
    (mouse-set-point event))
  (if (get-text-property (point) 'button)
      (push-button)
    (if-let* ((object (vtable-current-object)))
        (let* ((buf (compilation-history-view--display-record object))
               (win (get-buffer-window buf)))
          (when win (select-window win)))
      (message "No compilation record at point"))))

;;; Preview

(defun compilation-history-view-preview ()
  "Preview the compilation record at point without switching focus."
  (interactive)
  (if-let* ((object (vtable-current-object)))
      (let ((view-buf (current-buffer))
            (view-window (selected-window)))
        (compilation-history-view--display-record object)
        (with-current-buffer view-buf
          (setq compilation-history-view--preview-mode t))
        (select-window view-window))
    (message "No compilation record at point")))

(defun compilation-history-view-preview-next ()
  "Move to next row.  If preview mode is active, also update the other window."
  (interactive)
  (forward-line 1)
  (when compilation-history-view--preview-mode
    (when-let* ((object (vtable-current-object)))
      (let ((view-window (selected-window)))
        (compilation-history-view--display-record object)
        (select-window view-window)))))

(defun compilation-history-view-preview-prev ()
  "Move to previous row.  If preview mode is active, also update the other window."
  (interactive)
  (forward-line -1)
  (when compilation-history-view--preview-mode
    (when-let* ((object (vtable-current-object)))
      (let ((view-window (selected-window)))
        (compilation-history-view--display-record object)
        (select-window view-window)))))

(defun compilation-history-view--search-capf ()
  "Completion-at-point function for FTS column names in search minibuffer."
  (let* ((line (buffer-substring-no-properties (line-beginning-position) (point)))
         ;; Complete at start of input or after a space
         (start (if (string-match "\\(?:^\\|.* \\)\\([^ ]*\\)\\'" line)
                    (- (point) (length (match-string 1 line)))
                  (point))))
    (list start (point)
          (mapcar (lambda (col) (concat col ":"))
                  compilation-history--fts-column-names))))

(defun compilation-history-view-search ()
  "Search compilation history using FTS.
Supports substring matching and column-specific searches
\(e.g., compile_command:make).  TAB completes column names.
Empty input clears the search."
  (interactive)
  (let ((term (minibuffer-with-setup-hook
                  (lambda ()
                    (add-hook 'completion-at-point-functions
                              #'compilation-history-view--search-capf nil t))
                (read-from-minibuffer
                 (if compilation-history-view--search-term
                     (format "Search (current: %s): " compilation-history-view--search-term)
                   "Search: ")))))
    (setq compilation-history-view--search-term
          (if (string-empty-p term) nil term))
    ;; Reset to page 1 on new search
    (setf (compilation-history-view-pagination-current-page
           compilation-history-view--pagination) 1)
    (compilation-history-view--render)))

(defun compilation-history-view-quit ()
  "Quit the compilation history view.
Buries all compilation buffers opened from the view,
then buries the view itself.  Clears preview mode."
  (interactive)
  (setq compilation-history-view--preview-mode nil)
  (setq compilation-history-view--preview-window nil)
  (dolist (buf compilation-history-view--opened-buffers)
    (when (buffer-live-p buf)
      (let ((win (get-buffer-window buf)))
        (when win (delete-window win)))
      (bury-buffer buf)))
  (setq compilation-history-view--opened-buffers nil)
  (quit-window))

(defun compilation-history-view-kill-all ()
  "Kill all compilation-history buffers and the view itself."
  (interactive)
  (setq compilation-history-view--preview-mode nil)
  (setq compilation-history-view--preview-window nil)
  (setq compilation-history-view--opened-buffers nil)
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (string-prefix-p "*compilation-history-" (buffer-name buf)))
      (let ((win (get-buffer-window buf)))
        (when win (delete-window win)))
      (kill-buffer buf)))
  (kill-buffer))

(provide 'compilation-history-view)
;;; compilation-history-view.el ends here
