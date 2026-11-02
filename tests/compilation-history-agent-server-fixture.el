;;; compilation-history-agent-server-fixture.el --- Owned integration server -*- lexical-binding: t; -*-

(require 'server)
(require 'compilation-history-agent)

(defun ch-agent-test-client-event (client _chunk)
  "Notify the test driver once CLIENT is waiting for a result."
  (when (and (process-get client 'agent-job)
             (not (process-get client 'test-notified)))
    (process-put client 'test-notified t)
    (write-region "client\n" nil (expand-file-name "events" temporary-file-directory) nil 'silent)))

(defun ch-agent-test-expired-event (&rest _)
  "Notify the test driver after an expiry callback."
  (write-region "expired\n" nil (expand-file-name "events" temporary-file-directory) nil 'silent))

(defun ch-agent-test-finished-event (&rest _)
  "Notify the driver of ordinary completion after the interface is disabled."
  (write-region "finished\n" nil (expand-file-name "events" temporary-file-directory) nil 'silent))

(let ((root (getenv "CH_AGENT_TEST_ROOT")))
  (unless (and root (file-directory-p root)
               (file-exists-p (expand-file-name "owned-fixture" root)))
    (error "Missing owned server-test root"))
  (setq temporary-file-directory (file-name-as-directory root)
        default-directory (file-name-as-directory root)
        compilation-history-db-file (expand-file-name "history.db" root)
        server-socket-dir (expand-file-name "emacs-server" root)
        server-name "agent-test"))

(server-start)
(compilation-history-mode 1)
(compilation-history-agent-mode 1)
(compilation-history--ensure-db)
(write-region "ready\n" nil (expand-file-name "ready" temporary-file-directory) nil 'silent)
(unwind-protect
    (while (process-live-p server-process)
      (accept-process-output nil 1))
  (compilation-history-agent-mode -1))

;;; compilation-history-agent-server-fixture.el ends here
