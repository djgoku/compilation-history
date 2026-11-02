;;; tui-init.el --- Disposable terminal Emacs for verification -*- lexical-binding: t; -*-

;; Loaded by launch.sh --tui inside a private tmux server.  Everything the
;; session writes stays under CH_VERIFY_ROOT.

(let ((root (getenv "CH_VERIFY_ROOT")))
  (unless (and root (file-exists-p (expand-file-name "owned-fixture" root)))
    (error "Missing owned verify root"))
  (setq temporary-file-directory (file-name-as-directory root)
        default-directory (file-name-as-directory (expand-file-name "work" root))
        compilation-history-db-file (expand-file-name "history.db" root)
        server-socket-dir (expand-file-name "emacs-server" root)
        server-name "agent-test"
        inhibit-startup-screen t))

(require 'server)
(require 'compilation-history-view)
(require 'compilation-history-agent)
(global-set-key (kbd "C-c c") compilation-history-map)
(server-start)
(compilation-history-mode 1)
(compilation-history-agent-mode 1)
(compilation-history--ensure-db)
(write-region (format "%d\n" (emacs-pid)) nil
              (expand-file-name "server.pid" (getenv "CH_VERIFY_ROOT")) nil 'silent)
(write-region "ready\n" nil (expand-file-name "ready" (getenv "CH_VERIFY_ROOT")) nil 'silent)

;;; tui-init.el ends here
