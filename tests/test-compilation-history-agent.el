;;; test-compilation-history-agent.el --- Agent interface tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'compilation-history-test-helper)
(require 'compilation-history-agent)
(require 'compilation-history-view)
(require 'compilation-history-agent-test-helper)

(defun compilation-history-agent-test--launched-p ()
  "Return non-nil when any buffer holds a history record."
  (cl-some (lambda (buffer) (buffer-local-value 'compilation-history-record buffer))
           (buffer-list)))

(defun compilation-history-agent-test--emacs (form)
  "Run FORM in a fresh batch Emacs with this checkout loaded; return its output."
  (with-temp-buffer
    (should (zerop (call-process
                    (expand-file-name invocation-name invocation-directory) nil t nil
                    "--batch" "-Q" "-L" (file-name-directory (locate-library "compilation-history"))
                    "--eval" (prin1-to-string form))))
    (string-trim (buffer-string))))

;;; Requests

(ert-deftest agent-request-rejects-malformed-requests ()
  (dolist (request '(nil [] 42 "doctor" (:op) (:op doctor :id) ((op . doctor)) (:op . doctor)
                     (:op nil) (:op unknown) (:op "doctor") (:op doctor :id "unexpected")
                     (:op get :id "20260903T120000000081" :full "yes")
                     (:op get :id "20260903T120000000081" :full 1)
                     (:op show :id "20260903T120000000081" :select :null)
                     (:op start :command "true" :directory "/" :display "yes")
                     (:op get :id 4) (:op get :id "../etc")
                     (:op get :id "2026090T120000000081")
                     (:op list :search "") (:op list :search " ") (:op list :search 4)
                     (:op list :limit 0) (:op list :limit 101) (:op list :limit 1.5)
                     (:op list :offset -1) (:op list :id "20260903T120000000081")))
    (let ((reply (compilation-history-agent-test-request request)))
      (should (= 1 (alist-get 'protocol_version reply)))
      (should (equal "invalid_request" (alist-get 'error reply))))))

(ert-deftest agent-request-requires-an-id-for-get-and-show ()
  (compilation-history-agent-test-with-session
    (dolist (op '(get show))
      (should (equal "invalid_request"
                     (alist-get 'error (compilation-history-agent-test-request
                                        (list :op op))))))))

(ert-deftest agent-request-replies-ignore-the-users-print-limits ()
  (compilation-history-agent-test-with-session
    (let ((print-length 2) (print-level 1))
      (should (equal compilation-history-db-file
                     (alist-get 'database (compilation-history-agent-test-request
                                           '(:op doctor))))))))

(ert-deftest agent-request-doctor-reports-state-without-opening-db ()
  (compilation-history-agent-test-with-session
    (cl-letf (((symbol-function 'sqlite-open)
               (lambda (&rest _) (ert-fail "Doctor opened SQLite"))))
      (let ((reply (compilation-history-agent-test-request '(:op doctor))))
        (should (eq t (alist-get 'history_enabled reply)))
        (should (eq t (alist-get 'interface_enabled reply)))
        (should (file-exists-p (alist-get 'socket reply)))
        (should (equal compilation-history-db-file (alist-get 'database reply))))
      (compilation-history-agent-mode -1)
      (compilation-history-mode -1)
      (let ((reply (compilation-history-agent-test-request '(:op doctor))))
        (should (eq :false (alist-get 'history_enabled reply)))
        (should (eq :false (alist-get 'interface_enabled reply)))
        (should (eq :null (alist-get 'socket reply)))))))

;;; Mode

(ert-deftest agent-mode-owns-a-private-runtime-directory ()
  (compilation-history-agent-test-with-session
    (compilation-history-agent-mode -1)
    (let* ((root (make-temp-file "agent-mode-" t))
           (temporary-file-directory (file-name-as-directory root)))
      (unwind-protect
          (cl-letf (((symbol-function 'sqlite-open)
                     (lambda (&rest _) (ert-fail "Enabling the interface opened SQLite"))))
            (compilation-history-agent-mode 1)
            (let* ((socket (compilation-history-agent-test-socket))
                   (directory (file-name-directory socket)))
              (should (file-in-directory-p directory root))
              (should (= #o700 (logand #o777 (file-modes directory))))
              (should (file-exists-p socket))
              (compilation-history-agent-mode 1)
              (should (equal socket (compilation-history-agent-test-socket)))
              (compilation-history-agent-mode -1)
              (compilation-history-agent-mode -1)
              (should-not (file-exists-p directory))
              (should (eq :null (compilation-history-agent-test-socket)))))
        (delete-directory root t)))))

(ert-deftest agent-mode-failed-enable-rolls-back ()
  (compilation-history-agent-test-with-session
    (compilation-history-agent-mode -1)
    (cl-letf (((symbol-function 'make-temp-file)
               (lambda (&rest _) (signal 'file-error '("fixture: cannot create directory")))))
      (should-error (compilation-history-agent-mode 1)))
    (should-not compilation-history-agent-mode)
    (should (eq :null (compilation-history-agent-test-socket)))
    (let (created)
      (cl-letf (((symbol-function 'set-file-modes)
                 (lambda (path &rest _) (setq created path) (error "fixture permissions failure"))))
        (should-error (compilation-history-agent-mode 1)))
      (should created)
      (should-not (file-exists-p created))
      (should-not compilation-history-agent-mode))
    (dolist (value '(0 -1 invalid))
      (let ((compilation-history-agent-retention-seconds value))
        (should-error (compilation-history-agent-mode 1))
        (should-not compilation-history-agent-mode)))
    (compilation-history-agent-mode 1)
    (should (file-exists-p (compilation-history-agent-test-socket)))))

(ert-deftest agent-mode-loading-is-opt-in ()
  (should (equal "ok"
                 (compilation-history-agent-test--emacs
                  '(progn
                     (require 'compilation-history)
                     (when (featurep 'compilation-history-agent) (error "Core loaded agent"))
                     (require 'compilation-history-agent)
                     (when (or compilation-history-agent-mode compilation-history-mode
                               (stringp (alist-get 'socket (compilation-history-agent-doctor))))
                       (error "Loading enabled the interface"))
                     (princ "ok"))))))

(ert-deftest agent-mode-normal-emacs-exit-removes-runtime-directory ()
  (let ((socket (compilation-history-agent-test--emacs
                 '(progn (require 'compilation-history-agent)
                         (compilation-history-agent-mode 1)
                         (princ (alist-get 'socket (compilation-history-agent-doctor)))
                         (kill-emacs 0)))))
    (unwind-protect
        (progn (should (string-suffix-p "agent.sock" socket))
               (should-not (file-exists-p (file-name-directory socket))))
      (ignore-errors (delete-directory (file-name-directory socket) t)))))

;;; Start

(ert-deftest agent-start-never-selects-or-changes-the-selected-window ()
  (compilation-history-agent-test-with-session
    (let ((window (selected-window)) (frame (selected-frame))
          (buffer (window-buffer (selected-window))))
      (let ((reply (compilation-history-agent-test-start "sleep 0.1")))
        (should-not (alist-get 'error reply))
        (should (eq :false (alist-get 'visible (alist-get 'display reply)))))
      (let ((reply (compilation-history-agent-test-start "sleep 0.1" t)))
        (should (eq t (alist-get 'visible (alist-get 'display reply))))
        (should (eq :false (alist-get 'selected (alist-get 'display reply)))))
      (should (eq window (selected-window)))
      (should (eq frame (selected-frame)))
      (should (eq buffer (window-buffer window))))))

(ert-deftest agent-start-rejects-bad-input-without-launching ()
  (compilation-history-agent-test-with-session
    (dolist (request `((:op start :directory ,default-directory)
                       (:op start :command "" :directory ,default-directory)
                       (:op start :command " \n" :directory ,default-directory)
                       (:op start :command 4 :directory ,default-directory)
                       (:op start :command "bad\0command" :directory ,default-directory)
                       (:op start :command "true")
                       (:op start :command "true" :directory 4)
                       (:op start :command "true" :directory "/ssh:host:/tmp/")
                       (:op start :command "true" :directory "/does-not-exist-agent/")))
      (should (equal "invalid_request"
                     (alist-get 'error (compilation-history-agent-test-request request)))))
    (should-not (compilation-history-agent-test--launched-p))))

(ert-deftest agent-start-refuses-when-interface-or-history-is-disabled ()
  (compilation-history-agent-test-with-session
    (compilation-history-agent-mode -1)
    (should (equal "interface_disabled"
                   (alist-get 'error (compilation-history-agent-test-start "true"))))
    (compilation-history-agent-mode 1)
    (compilation-history-mode -1)
    (should (equal "history_unavailable"
                   (alist-get 'error (compilation-history-agent-test-start "true"))))
    (should-not (compilation-history-agent-test--launched-p))))

;;; Wait

(ert-deftest agent-wait-delivers-the-persisted-result-over-the-socket ()
  (compilation-history-agent-test-with-session
    (dolist (case '(("printf 'héllo λ 🚀\\n'" "succeeded" 0 "héllo λ 🚀")
                    ("printf 'failed-marker\\n'; exit 7" "failed" 7 "failed-marker")
                    ("printf 'raw\\377byte\\n'" "succeeded" 0 "raw�byte")))
      (let* ((start (compilation-history-agent-test-start (car case)))
             (id (alist-get 'id start))
             (waited (compilation-history-agent-test-reply
                      (compilation-history-agent-test-wait id))))
        (should (equal (car case) (alist-get 'command start)))
        (should (equal "running" (alist-get 'state start)))
        (should (equal (nth 1 case) (alist-get 'state waited)))
        (should (= (nth 2 case) (alist-get 'exit_code waited)))
        (should (string-match-p (regexp-quote (nth 3 case)) (alist-get 'tail waited)))
        (should (equal (assq-delete-all 'display (copy-sequence waited))
                       (compilation-history-agent-test-get id)))))))

(ert-deftest agent-wait-gives-multiple-and-late-waiters-the-same-result ()
  (compilation-history-agent-test-with-session
    (let* ((id (alist-get 'id (compilation-history-agent-test-start
                               "sleep 0.3; printf 'shared-marker\\n'")))
           (first (compilation-history-agent-test-wait id))
           (second (compilation-history-agent-test-wait id))
           (expected (compilation-history-agent-test-reply first)))
      (should (equal "succeeded" (alist-get 'state expected)))
      (should (equal expected (compilation-history-agent-test-reply second)))
      (should (equal expected (compilation-history-agent-test-reply
                               (compilation-history-agent-test-wait id))))
      (should (equal expected (compilation-history-agent-test-reply
                               (compilation-history-agent-test-wait id)))))))

(ert-deftest agent-wait-survives-a-disconnected-waiter ()
  (compilation-history-agent-test-with-session
    (let* ((start (compilation-history-agent-test-start "sleep 0.5; printf done"))
           (id (alist-get 'id start))
           (gone (compilation-history-agent-test-wait id))
           (stays (compilation-history-agent-test-wait id)))
      (compilation-history-agent-test-pause 0.2)
      (delete-process gone)
      (compilation-history-agent-test-pause 0.1)
      (should (process-live-p (get-buffer-process (get-buffer (alist-get 'buffer start)))))
      (should (equal "succeeded" (alist-get 'state (compilation-history-agent-test-reply stays)))))))

(ert-deftest agent-wait-expiry-is-completion-based-and-history-survives ()
  (compilation-history-agent-test-with-session
    (let* ((compilation-history-agent-retention-seconds 0.3)
           (start (compilation-history-agent-test-start "sleep 0.5; printf retained"))
           (id (alist-get 'id start))
           (waiter (compilation-history-agent-test-wait id)))
      (compilation-history-agent-test-pause 0.4)
      (should (process-live-p waiter))
      (should (equal "succeeded" (alist-get 'state (compilation-history-agent-test-reply waiter))))
      (should (equal "succeeded" (alist-get 'state (compilation-history-agent-test-reply
                                                    (compilation-history-agent-test-wait id)))))
      (compilation-history-agent-test-await
       (lambda () (equal "wait_unavailable"
                         (alist-get 'error (compilation-history-agent-test-reply
                                            (compilation-history-agent-test-wait id))))))
      (let ((expired (compilation-history-agent-test-reply (compilation-history-agent-test-wait id))))
        (should (equal id (alist-get 'id expired)))
        (should (equal (concat "get " id) (alist-get 'recovery expired))))
      (should (string-match-p "retained" (alist-get 'tail (compilation-history-agent-test-get id))))
      (should (buffer-live-p (get-buffer (alist-get 'buffer start)))))))

(ert-deftest agent-wait-socket-answers-one-id-line-and-handles-unknown-ids ()
  (compilation-history-agent-test-with-session
    (let* ((id "20200101T000000000000")
           (reply "")
           (client (make-network-process
                    :name "agent-test-client" :family 'local :noquery t :coding 'binary
                    :service (compilation-history-agent-test-socket)
                    :filter (lambda (_ chunk) (setq reply (concat reply chunk))))))
      (process-send-string client id)
      (compilation-history-agent-test-pause 0.1)
      (should (equal "" reply))
      (process-send-string client "\n")
      (compilation-history-agent-test-await (lambda () (not (process-live-p client))))
      (let ((parsed (car (read-from-string (decode-coding-string reply 'utf-8)))))
        (should (equal "wait_unavailable" (alist-get 'error parsed)))
        (should (equal id (alist-get 'id parsed)))
        (should (equal (concat "get " id) (alist-get 'recovery parsed)))))
    (let ((client (compilation-history-agent-test-wait "not-an-id")))
      (should (equal "invalid_request"
                     (alist-get 'error (compilation-history-agent-test-reply client)))))))

(ert-deftest agent-wait-disable-answers-waiters-but-keeps-compilation-running ()
  (compilation-history-agent-test-with-session
    (let* ((start (compilation-history-agent-test-start "sleep 0.6; printf survived"))
           (id (alist-get 'id start))
           (buffer (get-buffer (alist-get 'buffer start)))
           (directory (file-name-directory (compilation-history-agent-test-socket)))
           (client (compilation-history-agent-test-wait id)))
      (compilation-history-agent-test-pause 0.2)
      (compilation-history-agent-mode -1)
      (let ((reply (compilation-history-agent-test-reply client)))
        (should (equal "interface_disabled" (alist-get 'error reply)))
        (should (equal id (alist-get 'id reply))))
      (should-not (file-exists-p directory))
      (should (buffer-live-p buffer))
      (should (process-live-p (get-buffer-process buffer)))
      (should (equal "succeeded" (alist-get 'state (compilation-history-agent-test-finished id)))))))

(ert-deftest agent-wait-reports-killed-when-the-running-buffer-is-killed ()
  (compilation-history-agent-test-with-session
    (let* ((start (compilation-history-agent-test-start "sleep 5"))
           (id (alist-get 'id start))
           (buffer (get-buffer (alist-get 'buffer start)))
           (client (compilation-history-agent-test-wait id)))
      (compilation-history-agent-test-pause 0.2)
      (set-process-query-on-exit-flag (get-buffer-process buffer) nil)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))
      (let ((reply (compilation-history-agent-test-reply client)))
        (should (equal "killed" (alist-get 'state reply)))
        (should (= -1 (alist-get 'exit_code reply))))
      (should (equal "killed" (alist-get 'state (compilation-history-agent-test-get id)))))))

(ert-deftest agent-wait-reports-completion-unavailable-when-the-final-save-fails ()
  (compilation-history-agent-test-with-session
    (let* ((finished-start (compilation-history-agent-test-start "sleep 0.1"))
           (finished (alist-get 'id finished-start))
           (finished-buffer (get-buffer (alist-get 'buffer finished-start)))
           (killed-start (compilation-history-agent-test-start "sleep 5"))
           (killed (alist-get 'id killed-start))
           (killed-buffer (get-buffer (alist-get 'buffer killed-start)))
           (finish-waiter (compilation-history-agent-test-wait finished))
           (kill-waiter (compilation-history-agent-test-wait killed)))
      (compilation-history-agent-test-break-final-save)
      (should-error (compilation-history-agent-test-deliver-exit finished-buffer))
      (set-process-query-on-exit-flag (get-buffer-process killed-buffer) nil)
      (let ((kill-buffer-query-functions nil))
        (should-error (kill-buffer killed-buffer)))
      (dolist (case (list (cons finished finish-waiter) (cons killed kill-waiter)))
        (let ((reply (compilation-history-agent-test-reply (cdr case))))
          (should (equal "completion_unavailable" (alist-get 'error reply)))
          (should (equal (car case) (alist-get 'id reply)))
          (should (equal (concat "get " (car case)) (alist-get 'recovery reply)))
          (should-not (assq 'state reply))))
      (should (equal "running" (alist-get 'state (compilation-history-agent-test-get finished)))))))

;;; Get

(ert-deftest agent-get-reports-state-and-bounds-the-tail ()
  (compilation-history-agent-test-with-session
    (compilation-history-agent-mode -1)
    (compilation-history--ensure-db)
    (let ((id "20260903T120000000081"))
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record :record-id id))
      (let ((running (compilation-history-agent-test-get id)))
        (should (equal "running" (alist-get 'state running)))
        (should (eq :null (alist-get 'exit_code running)))
        (should (eq :null (alist-get 'duration_seconds running))))
      (dolist (case '((0 nil "succeeded") (7 nil "failed") (-1 t "killed")))
        (compilation-history--update-compilation-record id (car case) "out" (nth 1 case))
        (let ((reply (compilation-history-agent-test-get id)))
          (should (equal (nth 2 case) (alist-get 'state reply)))
          (should (= (car case) (alist-get 'exit_code reply)))
          (should (numberp (alist-get 'duration_seconds reply)))))
      (dolist (length '(0 4095 4096 4097))
        (let ((text (apply #'string (cl-loop for i below length collect (+ #x3b1 (% i 24))))))
          (compilation-history--update-compilation-record id 0 text nil)
          (let ((reply (compilation-history-agent-test-get id)))
            (should (equal (substring text (max 0 (- length 4096))) (alist-get 'tail reply)))
            (should (eq (if (> length 4096) t :false) (alist-get 'tail_truncated reply)))))))
    (should (equal "unknown_id"
                   (alist-get 'error (compilation-history-agent-test-get "20260903T120000000082"))))))

(ert-deftest agent-get-full-writes-exact-output-to-a-private-file ()
  (compilation-history-agent-test-with-session
    (let ((id "20260903T120000000081")
          (text (concat "héllo λ 🚀\n" (make-string 5000 ?x) "\nend\n"))
          file)
      (compilation-history--ensure-db)
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record :record-id id))
      (compilation-history--update-compilation-record id 0 text nil)
      (unwind-protect
          (let ((reply (compilation-history-agent-test-get id t)))
            (setq file (alist-get 'output_file reply))
            (should-not (assq 'output reply))
            (should (= #o600 (logand #o777 (file-modes file))))
            (should (equal text (with-temp-buffer
                                  (let ((coding-system-for-read 'utf-8-unix))
                                    (insert-file-contents file))
                                  (buffer-string)))))
        (when file (delete-file file))))))

(ert-deftest agent-get-without-a-database-does-not-create-one ()
  (compilation-history-test-with-db
    (should (equal "history_unavailable"
                   (alist-get 'error (compilation-history-agent-test-get "20260903T120000000082"))))
    (should-not (file-exists-p compilation-history-db-file))))

(ert-deftest agent-get-works-after-the-interface-is-disabled ()
  (compilation-history-agent-test-with-session
    (let ((id (alist-get 'id (compilation-history-agent-test-start "printf 'recovered\\n'"))))
      (compilation-history-agent-test-finished id)
      (compilation-history-agent-mode -1)
      (let ((reply (compilation-history-agent-test-get id)))
        (should (equal "succeeded" (alist-get 'state reply)))
        (should (string-match-p "recovered" (alist-get 'tail reply)))))))

;;; List

(ert-deftest agent-list-pages-newest-first-and-searches-without-output ()
  (compilation-history-agent-test-with-session
    (compilation-history-agent-mode -1)
    (compilation-history--ensure-db)
    (dolist (case '(("20260903T120000000081" "make build" 0)
                    ("20260903T120000000082" "make test" 2)
                    ("20260903T120000000083" "cargo test" nil)))
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record :record-id (car case) :command (nth 1 case)))
      (when (nth 2 case)
        (compilation-history--update-compilation-record (car case) (nth 2 case) "secret-out" nil)))
    (let ((reply (compilation-history-agent-test-request '(:op list))))
      (should (= 3 (alist-get 'total reply)))
      (should (equal '("20260903T120000000083" "20260903T120000000082" "20260903T120000000081")
                     (mapcar (lambda (r) (alist-get 'id r)) (alist-get 'records reply))))
      (should (equal '("running" "failed" "succeeded")
                     (mapcar (lambda (r) (alist-get 'state r)) (alist-get 'records reply))))
      (should-not (string-search "secret-out" (prin1-to-string reply))))
    (let ((reply (compilation-history-agent-test-request '(:op list :limit 1 :offset 1))))
      (should (= 3 (alist-get 'total reply)))
      (should (equal '("20260903T120000000082")
                     (mapcar (lambda (r) (alist-get 'id r)) (alist-get 'records reply)))))
    (dolist (case '(("test" 2) ("compile_command:make" 2) ("ca" 1) ("secret-out" 2) ("nothing-matches" 0)))
      (let ((reply (compilation-history-agent-test-request `(:op list :search ,(car case)))))
        (should (equal (car case) (alist-get 'search reply)))
        (should (= (nth 1 case) (alist-get 'total reply)))
        (should (= (nth 1 case) (length (alist-get 'records reply))))))))

(ert-deftest agent-list-without-a-database-does-not-create-one ()
  (compilation-history-test-with-db
    (should (equal "history_unavailable"
                   (alist-get 'error (compilation-history-agent-test-request '(:op list)))))
    (should-not (file-exists-p compilation-history-db-file))))

;;; Show

(ert-deftest agent-show-displays-without-selecting-unless-asked ()
  (compilation-history-agent-test-with-session
    (let* ((window (selected-window)) (frame (selected-frame))
           (start (compilation-history-agent-test-start "sleep 0.2"))
           (id (alist-get 'id start))
           (buffer (get-buffer (alist-get 'buffer start))))
      (cl-letf (((symbol-function 'raise-frame) (lambda (&rest _) (ert-fail "Raised a frame")))
                ((symbol-function 'select-frame-set-input-focus)
                 (lambda (&rest _) (ert-fail "Requested OS focus"))))
        (let ((reply (compilation-history-agent-test-request `(:op show :id ,id))))
          (should (equal "running" (alist-get 'state reply)))
          (should (eq t (alist-get 'visible (alist-get 'display reply))))
          (should (eq :false (alist-get 'selected (alist-get 'display reply))))
          (should (eq window (selected-window))))
        (compilation-history-agent-test-finished id)
        (compilation-history-agent-mode -1)
        (let ((reply (compilation-history-agent-test-request
                      `(:op show :id ,id :select t))))
          (should (equal "succeeded" (alist-get 'state reply)))
          (should (eq t (alist-get 'selected (alist-get 'display reply))))
          (should (eq frame (selected-frame)))
          (should (eq buffer (window-buffer (selected-window)))))))
    (should (equal "unknown_id"
                   (alist-get 'error (compilation-history-agent-test-request
                                      '(:op show :id "20200101T000000000000")))))))

(ert-deftest agent-show-uses-another-window-when-the-frame-cannot-split ()
  (compilation-history-agent-test-with-session
    (delete-other-windows)
    (let* ((window (selected-window))
           (buffer (window-buffer window))
           (other (split-window))
           (split-height-threshold nil)
           (split-width-threshold nil)
           (id (alist-get 'id (compilation-history-agent-test-start "sleep 0.2")))
           reply)
      (dolist (request (list (lambda ()
                               (compilation-history-agent-test-request `(:op show :id ,id)))
                             (lambda () (compilation-history-agent-test-start "sleep 0.2" t))))
        (setq reply (funcall request))
        (should-not (alist-get 'error reply))
        (should (eq t (alist-get 'visible (alist-get 'display reply))))
        (should (eq :false (alist-get 'selected (alist-get 'display reply))))
        (should (equal (list window other) (window-list)))
        (should (eq window (selected-window)))
        (should (eq buffer (window-buffer window)))
        (should (equal (alist-get 'buffer reply) (buffer-name (window-buffer other))))))))

(ert-deftest agent-show-never-falls-through-on-an-unsplittable-frame ()
  (compilation-history-agent-test-with-session
    (let* ((id (alist-get 'id (compilation-history-agent-test-start "sleep 0.2")))
           (frame-parameter (symbol-function 'frame-parameter))
           (display-buffer-alist '(("." display-buffer-pop-up-frame))))
      (cl-letf (((symbol-function 'frame-parameter)
                 (lambda (frame key)
                   (if (eq key 'unsplittable) t (funcall frame-parameter frame key))))
                ((symbol-function 'display-buffer-pop-up-frame)
                 (lambda (&rest _) (ert-fail "Display escaped to another frame"))))
        (let ((shown (compilation-history-agent-test-request `(:op show :id ,id)))
              (started (compilation-history-agent-test-start "sleep 0.2" t)))
          (should (equal "display_unavailable" (alist-get 'error shown)))
          (should (equal id (alist-get 'id shown)))
          (should (equal "display_unavailable" (alist-get 'error started)))
          (should (string-prefix-p "Compilation started" (alist-get 'message started)))
          (should (equal "succeeded" (alist-get 'state (compilation-history-agent-test-finished
                                                        (alist-get 'id started))))))))))

(ert-deftest agent-show-reopens-a-closed-compilation-from-history ()
  (compilation-history-agent-test-with-session
    (let* ((window (selected-window))
           (id (alist-get 'id (compilation-history-agent-test-start "printf 'reopened\\n'; exit 5"))))
      (compilation-history-agent-test-finished id)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (compilation-history-agent--find-buffer id)))
      (should-not (compilation-history-agent--find-buffer id))
      (let* ((reply (compilation-history-agent-test-request `(:op show :id ,id)))
             (buffer (get-buffer (alist-get 'buffer reply))))
        (should (equal "failed" (alist-get 'state reply)))
        (should (eq t (alist-get 'visible (alist-get 'display reply))))
        (should (eq window (selected-window)))
        (should (eq buffer (compilation-history-agent--find-buffer id)))
        (should (with-current-buffer buffer
                  (and compilation-history-buffer-mode
                       (string-search "reopened" (buffer-string)))))
        (compilation-history-agent-test-request `(:op show :id ,id))
        (should (= 1 (cl-count-if (lambda (b) (eq b (compilation-history-agent--find-buffer id)))
                                  (buffer-list))))))))

(ert-deftest agent-show-without-a-database-does-not-create-one ()
  (compilation-history-test-with-db
    (should (equal "unknown_id"
                   (alist-get 'error (compilation-history-agent-test-request
                                      '(:op show :id "20260903T120000000082")))))
    (should-not (file-exists-p compilation-history-db-file))))

(ert-deftest agent-show-reports-reopened-history-buffers-with-their-terminal-state ()
  (compilation-history-agent-test-with-session
    (compilation-history--ensure-db)
    (dolist (case '((0 "success" "succeeded") (7 "failed" "failed") (-1 "killed" "killed")))
      (let* ((id "20260903T120000000080")
             (buffer (compilation-history-view--get-or-create-compilation-buffer
                      (list :id id :buffer-name "*agent-reopened*" :directory default-directory
                            :command "true" :exit-code (car case) :status (nth 1 case)))))
        (unwind-protect
            (should (equal (nth 2 case)
                           (alist-get 'state (compilation-history-agent-test-request
                                              `(:op show :id ,id)))))
          (kill-buffer buffer))))))

(provide 'test-compilation-history-agent)
;;; test-compilation-history-agent.el ends here
