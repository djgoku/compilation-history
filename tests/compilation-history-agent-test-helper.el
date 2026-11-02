;;; compilation-history-agent-test-helper.el --- Isolated agent fixtures -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'compilation-history-test-helper)
(require 'compilation-history-agent)

(defvar compilation-history-agent-test--owned-buffers nil
  "Compilation and wait-client buffers created by the running test.")

(defun compilation-history-agent-test--own-buffer ()
  "Remember the newly created compilation buffer in this test session."
  (cl-pushnew (current-buffer) compilation-history-agent-test--owned-buffers))

(defun compilation-history-agent-test--sql (sql)
  "Run SQL against the test history DB."
  (let ((db (sqlite-open compilation-history-db-file)))
    (unwind-protect (sqlite-execute db sql)
      (sqlite-close db))))

;; Batch Emacs exits on an error escaping a sentinel run by the event loop, so
;; tests that need the final save to fail deliver the exit to the sentinel by hand.
(defun compilation-history-agent-test-deliver-exit (buffer)
  "Run BUFFER's process sentinel synchronously once its process has exited."
  (let* ((process (get-buffer-process buffer))
         (sentinel (process-sentinel process)))
    (set-process-sentinel process #'ignore)
    (compilation-history-agent-test-await (lambda () (not (process-live-p process))))
    (funcall sentinel process "finished\n")))

(defun compilation-history-agent-test-break-final-save ()
  "Make the history DB reject the final update of any record."
  (compilation-history-agent-test--sql
   (concat "CREATE TRIGGER fail_final BEFORE UPDATE OF exit_code ON compilations "
           "BEGIN SELECT RAISE(ABORT, 'fixture final save failure'); END")))

(defun compilation-history-agent-test--cleanup ()
  "Disable the interface and discard every buffer and process the test owns."
  (when (file-exists-p compilation-history-db-file)
    (compilation-history-agent-test--sql "DROP TRIGGER IF EXISTS fail_final"))
  ;; Save timers write to the test DB, which is deleted right after the body.
  (dolist (buffer compilation-history-agent-test--owned-buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (compilation-history--cancel-save-timer))))
  (unwind-protect
      (compilation-history-agent-mode -1)
    (dolist (buffer compilation-history-agent-test--owned-buffers)
      (when (buffer-live-p buffer)
        (let ((process (get-buffer-process buffer)))
          (when (process-live-p process)
            (set-process-query-on-exit-flag process nil)
            (delete-process process)))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buffer))))))

(defmacro compilation-history-agent-test-with-session (&rest body)
  "Run BODY with an isolated DB, history mode, agent interface and UI."
  (declare (indent 0) (debug t))
  `(compilation-history-test-with-db
     (let ((old-setup (default-value 'compilation-process-setup-function))
           (old-name (default-value 'compilation-buffer-name-function))
           (old-metadata-advice
            (advice-member-p #'compilation-history--add-sentinel-metadata-advice
                             'compilation-sentinel))
           (old-recompile-advice
            (advice-member-p #'compilation-history--switch-to-recompile-buffer 'recompile))
           (compilation-history-mode nil)
           (compilation-history-agent-mode nil)
           (compilation-history-agent--jobs (make-hash-table :test #'equal))
           (compilation-history-agent--runtime-directory nil)
           (compilation-history-agent--listener nil)
           (compilation-history-agent-test--owned-buffers nil)
           (compilation-history-final-save-functions
            (copy-sequence compilation-history-final-save-functions))
           (compilation-mode-hook (copy-sequence compilation-mode-hook))
           (kill-emacs-hook (copy-sequence kill-emacs-hook))
           (compilation-in-progress (copy-sequence compilation-in-progress))
           (next-error-last-buffer next-error-last-buffer)
           (display-buffer-overriding-action nil))
       (save-window-excursion
         (unwind-protect
             (progn
               (compilation-history-mode 1)
               (compilation-history-agent-mode 1)
               (add-hook 'compilation-mode-hook #'compilation-history-agent-test--own-buffer)
               ,@body)
           (unwind-protect (compilation-history-agent-test--cleanup)
             (set-default 'compilation-process-setup-function old-setup)
             (set-default 'compilation-buffer-name-function old-name)
             (unless old-metadata-advice
               (advice-remove 'compilation-sentinel
                              #'compilation-history--add-sentinel-metadata-advice))
             (unless old-recompile-advice
               (advice-remove 'recompile #'compilation-history--switch-to-recompile-buffer))))))))

(defun compilation-history-agent-test-await (predicate &optional seconds)
  "Pump events until PREDICATE succeeds, failing after SECONDS (default 10)."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun compilation-history-agent-test-pause (seconds)
  "Pump events for SECONDS."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (accept-process-output nil 0.02))))

(defun compilation-history-agent-test-request (request)
  "Send REQUEST through the server entry as the CLI does; return the reply."
  (car (read-from-string
        (compilation-history-agent-request
         (car (read-from-string (prin1-to-string request)))))))

(defun compilation-history-agent-test-start (command &optional display)
  "Start COMMAND in `default-directory' through the request entry."
  (compilation-history-agent-test-request
   `(:op start :command ,command :directory ,default-directory :display ,display)))

(defun compilation-history-agent-test-get (id &optional full)
  "Fetch ID's persisted history through the request entry."
  (compilation-history-agent-test-request `(:op get :id ,id :full ,full)))

(defun compilation-history-agent-test-socket ()
  "Return the interface socket path."
  (alist-get 'socket (compilation-history-agent-doctor)))

(defun compilation-history-agent-test-wait (id)
  "Open a client that waits on ID over the interface socket."
  (let ((buffer (generate-new-buffer " *agent-wait*")))
    (push buffer compilation-history-agent-test--owned-buffers)
    (with-current-buffer buffer (set-buffer-multibyte nil))
    (let ((client (make-network-process
                   :name "agent-test-wait" :family 'local :noquery t :coding 'binary
                   :buffer buffer :sentinel #'ignore
                   :service (compilation-history-agent-test-socket))))
      (process-send-string client (concat id "\n"))
      client)))

(defun compilation-history-agent-test-reply (client)
  "Await CLIENT's closed connection and return the reply it read."
  (compilation-history-agent-test-await (lambda () (not (process-live-p client))))
  (car (read-from-string
        (decode-coding-string (with-current-buffer (process-buffer client) (buffer-string))
                              'utf-8))))

(defun compilation-history-agent-test-finished (id)
  "Await ID's persisted state leaving \"running\" and return the `get' reply."
  (compilation-history-agent-test-await
   (lambda () (not (equal "running" (alist-get 'state (compilation-history-agent-test-get id))))))
  (compilation-history-agent-test-get id))

(provide 'compilation-history-agent-test-helper)
;;; compilation-history-agent-test-helper.el ends here
