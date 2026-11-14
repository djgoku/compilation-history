;;; compilation-history-agent.el --- Local agent compilation interface -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jonathan Carroll Otsuka
;; Author: Jonathan Carroll Otsuka <pitas.axioms0c@icloud.com>
;; Version: 0.2.10
;; Package-Requires: ((emacs "29.1"))
;; Keywords: processes, tools
;; URL: https://github.com/djgoku/compilation-history

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Optional local interface for shell-capable agents.  The bundled CLI
;; sends Lisp requests through the Emacs server to
;; `compilation-history-agent-request' and prints the replies as JSON.
;; Enabling `compilation-history-agent-mode' also opens one Unix socket in
;; a private directory, where clients block until a started job finishes.
;; Enable `compilation-history-mode' separately.  This module never starts
;; Emacs or changes the history database setting.

;;; Code:

(require 'compilation-history)
(require 'compilation-history-view)
(require 'cl-lib)
(require 'subr-x)
(require 'rx)

(defgroup compilation-history-agent nil
  "Local agent access to compilation history."
  :group 'compilation-history)

(defcustom compilation-history-agent-retention-seconds 3600
  "Seconds to retain completed agent results, measured from completion."
  :type 'number
  :group 'compilation-history-agent)

(defconst compilation-history-agent-list-default-limit 20
  "Records `list' returns when the request names no limit.")

(defconst compilation-history-agent-list-max-limit 100
  "Largest limit a `list' request may name.")

(defvar compilation-history-agent-mode nil)
(defvar compilation-history-agent--runtime-directory nil
  "Private directory holding the interface socket.")
(defvar compilation-history-agent--listener nil
  "Server process accepting agent requests.")
(defvar compilation-history-agent--jobs (make-hash-table :test #'equal)
  "Jobs started through the interface, indexed by history ID.")
(defvar compilation-history-agent--early-saves t
  "Final saves seen while starting a job, as (ID . ERROR), or t when not starting.")

(cl-defstruct (compilation-history-agent--job
               (:constructor compilation-history-agent--make-job))
  id buffer result waiters expiry-timer)

(define-error 'compilation-history-agent-invalid-request "Invalid agent request")

;;; Protocol values

(defun compilation-history-agent--error-reply (code message &optional id)
  "Return a protocol error with CODE and MESSAGE.
With ID, include it and the `get' command that recovers its history."
  (append `((protocol_version . 1) (error . ,code) (message . ,message))
          (when id `((id . ,id) (recovery . ,(concat "get " id))))))

(defun compilation-history-agent--print (object)
  "Return OBJECT printed readably, ignoring the user's print limits."
  (let ((print-length nil) (print-level nil))
    (prin1-to-string object)))

(defun compilation-history-agent--invalid (message)
  "Signal an invalid request with MESSAGE."
  (signal 'compilation-history-agent-invalid-request (list message)))

(defun compilation-history-agent--tail (text)
  "Return the final 4096 characters of TEXT and a truncation flag."
  (let ((start (max 0 (- (length text) 4096))))
    `((tail . ,(substring text start))
      (tail_truncated . ,(if (> start 0) t :false)))))

(defun compilation-history-agent--display-state (buffer)
  "Report whether BUFFER is visible and whether its window is selected."
  (let ((windows (when (buffer-live-p buffer)
                   (get-buffer-window-list buffer nil t))))
    `((visible . ,(if (cl-some (lambda (window)
                                 (eq t (frame-visible-p (window-frame window))))
                               windows)
                      t :false))
      (selected . ,(if (memq (selected-window) windows) t :false)))))

(defun compilation-history-agent--state (exit-code killed finished)
  "Name the state for EXIT-CODE, KILLED and FINISHED."
  (cond (killed "killed")
        ((not finished) "running")
        ((eql exit-code 0) "succeeded")
        (t "failed")))

(defun compilation-history-agent--validate-id (id)
  "Reject ID unless it is a canonical history timestamp."
  (unless (and (stringp id)
               (string-match-p
                (rx string-start (repeat 8 digit) "T" (repeat 12 digit) string-end) id))
    (compilation-history-agent--invalid "Invalid compilation ID")))

(defun compilation-history-agent--parse-request (request)
  "Validate REQUEST, a plist whose `:op' names the operation, and return it."
  (unless (and (proper-list-p request) (cl-evenp (length request)))
    (compilation-history-agent--invalid "Expected a plist"))
  (let* ((op (plist-get request :op))
         (allowed (pcase op
                    ('doctor '(:op))
                    ('start '(:op :command :directory :display))
                    ('get '(:op :id :full))
                    ('show '(:op :id :select))
                    ('list '(:op :search :limit :offset))
                    (_ (compilation-history-agent--invalid "Unknown operation")))))
    (cl-loop for (key value) on request by #'cddr
             unless (memq key allowed)
             do (compilation-history-agent--invalid "Unknown request field")
             when (and (memq key '(:display :full :select)) (not (booleanp value)))
             do (compilation-history-agent--invalid "Flags must be t or nil"))
    (when (memq op '(get show))
      (compilation-history-agent--validate-id (plist-get request :id)))
    (when (eq op 'list)
      (let ((search (plist-get request :search))
            (limit (plist-get request :limit))
            (offset (plist-get request :offset)))
        (unless (or (null search)
                    (and (stringp search) (not (string-empty-p (string-trim search)))
                         (not (string-search "\0" search))))
          (compilation-history-agent--invalid "Search must be nonempty text without NUL"))
        (unless (or (null limit)
                    (and (natnump limit)
                         (<= 1 limit compilation-history-agent-list-max-limit)))
          (compilation-history-agent--invalid
           (format "Limit must be an integer from 1 to %d"
                   compilation-history-agent-list-max-limit)))
        (unless (or (null offset) (natnump offset))
          (compilation-history-agent--invalid "Offset must be a nonnegative integer"))))
    request))

;;; Transport

(defun compilation-history-agent-request (request)
  "Answer REQUEST, a plist from the CLI, with its reply alist printed as text.
The reply is printed here because the Emacs server prints results with
the user's `print-length'.  Complete output is written to a private file
named by `output_file', because Emacs sends large strings to clients slowly."
  (let ((response
         (condition-case err
             (let ((request (compilation-history-agent--parse-request request)))
               (pcase (plist-get request :op)
                 ('doctor (compilation-history-agent-doctor))
                 ('start (compilation-history-agent-start
                          (plist-get request :command) (plist-get request :directory)
                          (plist-get request :display)))
                 ('get (compilation-history-agent-get
                        (plist-get request :id) (plist-get request :full)))
                 ('show (compilation-history-agent-show
                         (plist-get request :id) (plist-get request :select)))
                 ('list (compilation-history-agent-list
                         (plist-get request :search) (plist-get request :limit)
                         (plist-get request :offset)))))
           (compilation-history-agent-invalid-request
            (compilation-history-agent--error-reply "invalid_request" (error-message-string err)))
           (error
            (compilation-history-agent--error-reply "internal_error" (error-message-string err))))))
    (when-let* ((output (alist-get 'output response)))
      (let ((file (make-temp-file "ch-agent-output-"))
            (coding-system-for-write 'utf-8-unix))
        (write-region output nil file nil 'silent)
        (setq response (cons (cons 'output_file file) (assq-delete-all 'output response)))))
    (compilation-history-agent--print response)))

(defun compilation-history-agent--send (client object)
  "Send OBJECT to CLIENT printed as UTF-8 Lisp, then close it.
A client that reads an incomplete reply knows the connection was cut."
  (unwind-protect
      (condition-case nil
          (when (process-live-p client)
            (process-send-string
             client (encode-coding-string (compilation-history-agent--print object) 'utf-8)))
        (error nil))
    (delete-process client)))

(defun compilation-history-agent--accept (_server client _message)
  "Prepare CLIENT to send one wait request."
  (set-process-coding-system client 'binary 'binary)
  (set-process-query-on-exit-flag client nil)
  (set-process-filter client #'compilation-history-agent--filter)
  (set-process-sentinel client #'compilation-history-agent--client-sentinel))

(defun compilation-history-agent--filter (client chunk)
  "Read CLIENT's ID line from CHUNK, then answer or hold its wait."
  (unless (process-get client 'agent-handled)
    (let ((input (concat (process-get client 'agent-input) chunk)))
      (process-put client 'agent-input input)
      (when (string-search "\n" input)
        (process-put client 'agent-handled t)
        (process-put client 'agent-input nil)
        (let ((response
               (if (string-match (rx bos (group (repeat 8 digit) "T" (repeat 12 digit)) "\n")
                                 input)
                   (compilation-history-agent--wait client (match-string 1 input))
                 (compilation-history-agent--error-reply "invalid_request" "Expected one ID line"))))
          (unless (eq response 'waiting)
            (compilation-history-agent--send client response)))))))

(defun compilation-history-agent--client-sentinel (client _event)
  "Forget disconnected CLIENT without cancelling the job it waits for."
  (unless (process-live-p client)
    (when-let* ((job (process-get client 'agent-job)))
      (setf (compilation-history-agent--job-waiters job)
            (delq client (compilation-history-agent--job-waiters job))))))

(defun compilation-history-agent--wait (client id)
  "Return ID's retained result, or register CLIENT and return `waiting'."
  (let ((job (gethash id compilation-history-agent--jobs)))
    (cond
     ((not job)
      (compilation-history-agent--error-reply "wait_unavailable" "No retained job for this ID" id))
     ((compilation-history-agent--job-result job)
      (compilation-history-agent--response job))
     (t
      (process-put client 'agent-job job)
      (push client (compilation-history-agent--job-waiters job))
      'waiting))))

;;; Jobs

(defun compilation-history-agent--response (job)
  "Return JOB's retained result with a fresh display snapshot."
  (let ((result (compilation-history-agent--job-result job)))
    (if (alist-get 'error result)
        result
      (append result
              `((display . ,(compilation-history-agent--display-state
                             (compilation-history-agent--job-buffer job))))))))

(defun compilation-history-agent--complete (job error)
  "Retain JOB's persisted outcome and notify its waiters.
ERROR is the failure from the final save, or nil when it succeeded."
  (let* ((id (compilation-history-agent--job-id job))
         (result (if error
                     (compilation-history-agent--error-reply
                      "completion_unavailable"
                      (concat "Final history save failed: " (error-message-string error))
                      id)
                   (compilation-history-agent-get id))))
    (unless (or (compilation-history-agent--job-result job)
                (equal "running" (alist-get 'state result)))
      (setf (compilation-history-agent--job-result job) result
            (compilation-history-agent--job-expiry-timer job)
            (run-at-time compilation-history-agent-retention-seconds nil
                         #'compilation-history-agent--expire job))
      (let ((waiters (compilation-history-agent--job-waiters job)))
        (setf (compilation-history-agent--job-waiters job) nil)
        (dolist (client waiters)
          (compilation-history-agent--send client (compilation-history-agent--response job)))))))

(defun compilation-history-agent--final-save (id error)
  "Complete the job for ID after its final save; ERROR is any failure."
  (if-let* ((job (gethash id compilation-history-agent--jobs)))
      (compilation-history-agent--complete job error)
    (unless (eq t compilation-history-agent--early-saves)
      (push (cons id error) compilation-history-agent--early-saves))))

(defun compilation-history-agent--expire (job)
  "Forget JOB if it is still the registered job for its ID."
  (let ((id (compilation-history-agent--job-id job)))
    (when (eq job (gethash id compilation-history-agent--jobs))
      (remhash id compilation-history-agent--jobs))))

(defun compilation-history-agent--validate-directory (directory)
  "Return DIRECTORY as an existing local directory name."
  (unless (and (stringp directory) (not (string-empty-p directory))
               (not (string-search "\0" directory)) (not (file-remote-p directory)))
    (compilation-history-agent--invalid "Directory must be local text without NUL"))
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (unless (file-directory-p directory)
      (compilation-history-agent--invalid "Directory does not exist"))
    directory))

(defun compilation-history-agent-start (command directory &optional display)
  "Start COMMAND in DIRECTORY without selecting its buffer.
Non-nil DISPLAY shows the buffer on the selected frame."
  (unless (and (stringp command) (not (string-empty-p (string-trim command)))
               (not (string-search "\0" command)))
    (compilation-history-agent--invalid "Command must be nonempty text without NUL"))
  (setq directory (compilation-history-agent--validate-directory directory))
  (cond
   ((not compilation-history-agent-mode)
    (compilation-history-agent--error-reply "interface_disabled" "Agent interface is disabled"))
   ((not compilation-history-mode)
    (compilation-history-agent--error-reply "history_unavailable" "History tracking is disabled"))
   (t
    (let* ((compilation-history-agent--early-saves nil)
           (buffer (save-selected-window
                     (with-temp-buffer
                       (setq default-directory directory)
                       (let ((display-buffer-overriding-action
                              '(display-buffer-no-window (allow-no-window . t))))
                         (compilation-start command)))))
           (record (buffer-local-value 'compilation-history-record buffer)))
      (unless (compilation-history-p record)
        (error "History setup did not create a record"))
      (let* ((id (compilation-history-record-id record))
             (job (compilation-history-agent--make-job :id id :buffer buffer))
             (early (assoc id compilation-history-agent--early-saves)))
        (puthash id job compilation-history-agent--jobs)
        (when early
          (compilation-history-agent--complete job (cdr early)))
        (let ((shown (when display (compilation-history-agent-show id))))
          (if (alist-get 'error shown)
              (progn
                (setf (alist-get 'message shown)
                      (concat "Compilation started; display failed: " (alist-get 'message shown)))
                shown)
            `((protocol_version . 1) (id . ,id) (state . "running")
              (command . ,command) (directory . ,directory)
              (buffer . ,(buffer-name buffer))
              (display . ,(compilation-history-agent--display-state buffer))))))))))

;;; Persisted recovery and explicit display

(defun compilation-history-agent-get (id &optional full)
  "Return persisted history for ID, with complete output when FULL is non-nil."
  (condition-case err
      (if (not (file-exists-p compilation-history-db-file))
          (compilation-history-agent--error-reply "history_unavailable" "History database does not exist")
        (pcase (compilation-history--get-record id)
          ('nil (compilation-history-agent--error-reply "unknown_id" "No persisted record for this ID"))
          (`(,_ ,buffer ,command ,directory ,_start ,end ,exit ,killed ,_ ,_ ,_ ,duration)
           (let* ((output (replace-regexp-in-string
                           ;; The CLI prints JSON, which cannot carry raw non-UTF-8 bytes.
                           (rx (any (#x3fff80 . #x3fffff))) "\uFFFD"
                           (or (compilation-history--get-output id) "") t t))
                  (state (compilation-history-agent--state exit (eql killed 1) end))
                  (running (equal state "running")))
             (append
              `((protocol_version . 1) (id . ,id) (state . ,state)
                (exit_code . ,(if running :null (or exit :null)))
                (duration_seconds . ,(if running :null (or duration :null)))
                (command . ,command) (directory . ,directory) (buffer . ,buffer))
              (if full
                  `((output . ,output))
                (compilation-history-agent--tail output)))))))
    (error (compilation-history-agent--error-reply "history_unavailable" (error-message-string err)))))

(defun compilation-history-agent-list (&optional search limit offset)
  "Return up to LIMIT persisted records newest first, skipping OFFSET.
Non-nil SEARCH filters them as the history view's search does.  Records
carry no output; `get' reads it."
  (let ((limit (or limit compilation-history-agent-list-default-limit))
        (offset (or offset 0)))
    (condition-case err
        (if (not (file-exists-p compilation-history-db-file))
            (compilation-history-agent--error-reply "history_unavailable" "History database does not exist")
          `((protocol_version . 1)
            (search . ,(or search :null))
            (total . ,(if search
                          (compilation-history--count-records-fts search)
                        (compilation-history--count-records)))
            (offset . ,offset)
            (records
             . ,(vconcat
                 (mapcar
                  (pcase-lambda (`(,id ,_buffer ,command ,directory ,start ,end ,exit ,killed
                                       ,branch ,_ ,_ ,duration))
                    (let* ((state (compilation-history-agent--state exit (eql killed 1) end))
                           (running (equal state "running")))
                      `((id . ,id) (state . ,state)
                        (exit_code . ,(if running :null (or exit :null)))
                        (duration_seconds . ,(if running :null (or duration :null)))
                        (start_time . ,start)
                        (command . ,command) (directory . ,directory)
                        (git_branch . ,(or branch :null)))))
                  (if search
                      (compilation-history--query-page-fts limit offset search)
                    (compilation-history--query-page limit offset)))))))
      (error (compilation-history-agent--error-reply "history_unavailable" (error-message-string err))))))

(defun compilation-history-agent--find-buffer (id)
  "Return a live buffer whose history record has ID."
  (cl-find-if
   (lambda (buffer)
     (let ((record (buffer-local-value 'compilation-history-record buffer)))
       (and (compilation-history-p record) (equal id (compilation-history-record-id record)))))
   (buffer-list)))

(defun compilation-history-agent--display-on-frame (buffer alist)
  "Display BUFFER on the selected frame using ALIST, or return `fail'."
  (or (display-buffer-reuse-window buffer alist)
      (and (not (frame-parameter (selected-frame) 'unsplittable))
           (not (window-minibuffer-p (frame-root-window (selected-frame))))
           (display-buffer-pop-up-window buffer alist))
      (display-buffer-use-some-window buffer (cons '(inhibit-same-window . t) alist))
      (display-buffer-no-window buffer alist)))

(defun compilation-history-agent--reopen (id)
  "Recreate ID's buffer from history as the view does, or return nil.
Never create the database."
  (when (file-exists-p compilation-history-db-file)
    (when-let* ((row (compilation-history--get-record id)))
      (compilation-history-view--get-or-create-compilation-buffer
       (compilation-history-view--row-to-plist row)))))

(defun compilation-history-agent-show (id &optional select)
  "Show ID's buffer on the selected frame; SELECT its window if non-nil.
A closed compilation's buffer is recreated from history first.  Never
raise a frame or request operating-system focus."
  (pcase (condition-case err
             (or (compilation-history-agent--find-buffer id)
                 (compilation-history-agent--reopen id))
           (error (compilation-history-agent--error-reply
                   "history_unavailable" (error-message-string err) id)))
    ('nil (compilation-history-agent--error-reply
           "unknown_id" "No compilation buffer or history record" id))
    ((and (pred consp) reply) reply)
    (buffer
     (condition-case err
         (let* ((frame (selected-frame))
                (display-buffer-overriding-action
                 `(compilation-history-agent--display-on-frame
                   (reusable-frames . ,frame) (inhibit-switch-frame . t) (allow-no-window . t)))
                (window (save-selected-window (display-buffer buffer)))
                (record (buffer-local-value 'compilation-history-record buffer))
                (exit (compilation-history-exit-code record)))
           (unless (and (window-live-p window) (eq frame (window-frame window)))
             (error "No compilation window is available on the selected frame"))
           (when select (select-window window))
           `((protocol_version . 1) (id . ,id)
             (state . ,(compilation-history-agent--state
                        exit
                        (string-match-p (rx (or "killed" "interrupt"))
                                        (or (compilation-history-message record) ""))
                        (and exit (not (process-live-p (get-buffer-process buffer))))))
             (buffer . ,(buffer-name buffer))
             (display . ,(compilation-history-agent--display-state buffer))))
       (error (compilation-history-agent--error-reply
               "display_unavailable" (error-message-string err) id))))))

;;; Runtime

(defun compilation-history-agent--socket ()
  "Return the interface socket path, or nil when the interface is disabled."
  (and compilation-history-agent--runtime-directory
       (expand-file-name "agent.sock" compilation-history-agent--runtime-directory)))

(defun compilation-history-agent-doctor ()
  "Report interface health without opening SQLite."
  `((protocol_version . 1)
    (history_enabled . ,(if compilation-history-mode t :false))
    (interface_enabled . ,(if compilation-history-agent-mode t :false))
    (socket . ,(or (compilation-history-agent--socket) :null))
    (database . ,compilation-history-db-file)
    (server_name . ,(if (boundp 'server-name) (symbol-value 'server-name) :null))))

(defun compilation-history-agent--disable ()
  "Close the socket, answer waiting clients, and forget all jobs."
  (remove-hook 'kill-emacs-hook #'compilation-history-agent--disable)
  (remove-hook 'compilation-history-final-save-functions #'compilation-history-agent--final-save)
  (maphash (lambda (id job)
             (dolist (client (copy-sequence (compilation-history-agent--job-waiters job)))
               (compilation-history-agent--send
                client (compilation-history-agent--error-reply
                        "interface_disabled" "Agent interface was disabled" id)))
             (when (compilation-history-agent--job-expiry-timer job)
               (cancel-timer (compilation-history-agent--job-expiry-timer job))))
           compilation-history-agent--jobs)
  (clrhash compilation-history-agent--jobs)
  (when compilation-history-agent--listener
    (delete-process compilation-history-agent--listener)
    (setq compilation-history-agent--listener nil))
  (when compilation-history-agent--runtime-directory
    (when (file-directory-p compilation-history-agent--runtime-directory)
      (delete-directory compilation-history-agent--runtime-directory t))
    (setq compilation-history-agent--runtime-directory nil)))

(defun compilation-history-agent--enable ()
  "Open the private socket and subscribe to final saves."
  (unless (and (numberp compilation-history-agent-retention-seconds)
               (> compilation-history-agent-retention-seconds 0))
    (user-error "Retention seconds must be positive"))
  (setq compilation-history-agent--runtime-directory
        (make-temp-file (expand-file-name "ch-agent-" temporary-file-directory) t))
  (set-file-modes compilation-history-agent--runtime-directory #o700)
  (setq compilation-history-agent--listener
        (make-network-process :name "compilation-history-agent"
                              :family 'local :server t
                              :service (compilation-history-agent--socket)
                              :coding 'binary :noquery t
                              ;; A listener without a filter gives each
                              ;; connection a buffer that outlives it.
                              :filter #'compilation-history-agent--filter
                              :log #'compilation-history-agent--accept))
  (add-hook 'compilation-history-final-save-functions #'compilation-history-agent--final-save)
  (add-hook 'kill-emacs-hook #'compilation-history-agent--disable 90))

;;;###autoload
(define-minor-mode compilation-history-agent-mode
  "Toggle the optional local agent interface without enabling history tracking."
  :global t
  :group 'compilation-history-agent
  (if (not compilation-history-agent-mode)
      (compilation-history-agent--disable)
    (unless compilation-history-agent--listener
      (condition-case err
          (compilation-history-agent--enable)
        (error
         (setq compilation-history-agent-mode nil)
         (compilation-history-agent--disable)
         (signal (car err) (cdr err)))))))

(defun compilation-history-agent-unload-function ()
  "Disable the interface before unloading it."
  (compilation-history-agent-mode -1)
  nil)

(provide 'compilation-history-agent)
;;; compilation-history-agent.el ends here
