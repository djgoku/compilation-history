;;; test-compilation-history-view.el --- Tests for compilation-history-view -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jonathan Otsuka

;;; Commentary:
;; Tests for compilation-history-view.el

;;; Code:

(require 'ert)
(require 'compilation-history-view)
(require 'compilation-history-test-helper)

(ert-deftest test-compilation-history-view-pagination-total-pages ()
  "Total pages is correctly derived from total-records and page-size."
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 0 :page-size 25)))
    (should (= (compilation-history-view--total-pages pag) 1)))
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 25 :page-size 25)))
    (should (= (compilation-history-view--total-pages pag) 1)))
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 26 :page-size 25)))
    (should (= (compilation-history-view--total-pages pag) 2)))
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 100 :page-size 25)))
    (should (= (compilation-history-view--total-pages pag) 4))))

(ert-deftest test-compilation-history-view-pagination-offset ()
  "Offset is correctly computed from current-page and page-size."
  (let ((pag (make-compilation-history-view-pagination
              :current-page 1 :total-records 100 :page-size 25)))
    (should (= (compilation-history-view--page-offset pag) 0)))
  (let ((pag (make-compilation-history-view-pagination
              :current-page 3 :total-records 100 :page-size 25)))
    (should (= (compilation-history-view--page-offset pag) 50))))

(ert-deftest test-compilation-history-view--row-to-plist ()
  "Database row is converted to a plist with all fields."
  (let* (;; Simulate a SQLite row matching compilation-history--page-columns + duration:
         ;; id, buffer_name, compile_command, default_directory, start_time,
         ;; end_time, exit_code, killed, git_branch, git_commit, duration_seconds
         (row '("20260321T120000" "*compilation*" "make test" "/project/"
                "2026-03-21 12:00:00" "2026-03-21 12:00:05" 0 0
                "main" "abc1234def" 5.0))
         (plist (compilation-history-view--row-to-plist row 0)))
    (should (equal (plist-get plist :id) "20260321T120000"))
    (should (equal (plist-get plist :buffer-name) "*compilation*"))
    (should (equal (plist-get plist :command) "make test"))
    (should (equal (plist-get plist :directory) "/project/"))
    (should (equal (plist-get plist :branch) "main"))
    (should (equal (plist-get plist :commit) "abc1234def"))
    (should (equal (plist-get plist :exit-code) 0))
    (should (equal (plist-get plist :status) "success"))))

(ert-deftest test-compilation-history-view--row-to-plist-status ()
  "Status is correctly derived from exit-code and killed fields."
  ;; Killed
  (let* ((row '("id1" "*buf*" "make" "/" "2026-03-21 12:00:00" "2026-03-21 12:00:05"
                1 1 nil nil 5.0))
         (plist (compilation-history-view--row-to-plist row)))
    (should (equal (plist-get plist :status) "killed")))
  ;; Failure
  (let* ((row '("id2" "*buf*" "make" "/" "2026-03-21 12:00:00" "2026-03-21 12:00:05"
                2 0 nil nil 5.0))
         (plist (compilation-history-view--row-to-plist row)))
    (should (equal (plist-get plist :status) "failure")))
  ;; Running (no end_time)
  (let* ((row '("id3" "*buf*" "make" "/" "2026-03-21 12:00:00" nil
                nil 0 nil nil nil))
         (plist (compilation-history-view--row-to-plist row)))
    (should (equal (plist-get plist :status) "running"))))

(ert-deftest test-compilation-history-view--format-duration ()
  "Duration formatting produces seconds with one decimal."
  (should (equal (compilation-history-view--format-duration nil) ""))
  (should (equal (compilation-history-view--format-duration 2.3) "2.3s"))
  (should (equal (compilation-history-view--format-duration 65.0) "65.0s")))

(ert-deftest test-compilation-history-view--getter-dispatches-on-key ()
  "Getter extracts correct field from plist based on column :key."
  (let* ((object '(:id "id1" :command "make test" :branch "main"
                   :start-time "2026-03-21 12:00:00" :duration 5.0
                   :status "success" :exit-code 0 :commit "abc1234def"
                   :directory "/project/" :row-index 0))
         (col-command '(:name "Command" :key :command))
         (col-branch '(:name "Branch" :key :branch))
         (col-commit '(:name "Commit" :key :commit)))
    (should (equal (compilation-history-view--get-value object col-command) "make test"))
    (should (equal (compilation-history-view--get-value object col-branch) "main"))
    ;; Without formatter, getter returns raw value
    (should (equal (compilation-history-view--get-value object col-commit) "abc1234def"))))

(ert-deftest test-compilation-history-view--formatter-is-called ()
  "Getter calls :formatter when present in column-def."
  (let* ((object '(:id "id1" :commit "abc1234def" :directory "/Users/someone/project/" :row-index 0))
         (col-commit '(:name "Commit" :key :commit :formatter compilation-history-view--format-commit))
         (col-dir '(:name "Directory" :key :directory :formatter compilation-history-view--format-directory))
         (col-custom '(:name "Test" :key :commit :formatter (lambda (v) (upcase v)))))
    ;; Commit formatter truncates to 7 chars
    (should (equal (compilation-history-view--get-value object col-commit) "abc1234"))
    ;; Directory formatter abbreviates
    (should (stringp (compilation-history-view--get-value object col-dir)))
    ;; Custom lambda formatter works
    (should (equal (compilation-history-view--get-value object col-custom) "ABC1234DEF"))))

(ert-deftest test-compilation-history-view--getter-row-number ()
  "Row number getter computes from pagination offset + row-index."
  (let* ((object '(:id "id1" :command "make" :row-index 3))
         (col '(:name "#" :key :row-number))
         (compilation-history-view--pagination
          (make-compilation-history-view-pagination
           :current-page 2 :total-records 50 :page-size 25)))
    ;; Page 2, page-size 25, index 3 → row 29
    ;; Offset = (2-1)*25 = 25, then 25 + 3 + 1 = 29 (1-based row numbers)
    (should (= (compilation-history-view--get-value object col) 29))))

(ert-deftest test-compilation-history-view-creates-buffer ()
  "compilation-history-view creates buffer with correct mode."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal (buffer-name) "*Compilation History*"))
            (should (eq major-mode 'compilation-history-view-mode))
            (should buffer-read-only)
            (should compilation-history-view--pagination))
        (kill-buffer buf)))))

(ert-deftest test-compilation-history-view-empty-db ()
  "View handles empty database gracefully."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (should (= (compilation-history-view-pagination-total-records
                        compilation-history-view--pagination) 0))
            (should (= (compilation-history-view--total-pages
                        compilation-history-view--pagination) 1)))
        (kill-buffer buf)))))

(ert-deftest test-compilation-history-view-displays-records ()
  "View displays records from the database."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :compile-command "make test"
      :buffer-name "*compilation-history-20260321T120000000001==proj__make-test*"))
    (compilation-history--update-compilation-record
     "20260321T120000000001" 0 "test output")
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (should (= (compilation-history-view-pagination-total-records
                        compilation-history-view--pagination) 1))
            (let ((content (buffer-string)))
              (should (string-match-p "make test" content))))
        (kill-buffer buf)))))

(ert-deftest test-compilation-history-view-pagination-controls ()
  "Pagination buttons are rendered."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    ;; Insert enough records for multiple pages
    (dotimes (i 30)
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record
        :record-id (format "20260321T120000%06d" i))))
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (let ((content (buffer-string)))
              (should (string-match-p "\\[First\\]" content))
              (should (string-match-p "\\[Previous\\]" content))
              (should (string-match-p "\\[Next\\]" content))
              (should (string-match-p "\\[Last\\]" content))
              (should (string-match-p "Page 1 of 2" content))
              (should (string-match-p "(30 records)" content))))
        (kill-buffer buf)))))

(ert-deftest test-compilation-history-view-next-page-navigation ()
  "Next page advances current-page and rerenders."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (dotimes (i 30)
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record
        :record-id (format "20260321T120000%06d" i))))
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (should (= (compilation-history-view-pagination-current-page
                        compilation-history-view--pagination) 1))
            (compilation-history-view-next-page)
            (should (= (compilation-history-view-pagination-current-page
                        compilation-history-view--pagination) 2))
            ;; Should not go past last page
            (compilation-history-view-next-page)
            (should (= (compilation-history-view-pagination-current-page
                        compilation-history-view--pagination) 2)))
        (kill-buffer buf)))))

(ert-deftest test-compilation-history-view-mode-line ()
  "Mode-line shows page info."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            ;; Pagination info is now in mode-name (a string).
            (should (string-match-p "CompHist" mode-name))
            (should (string-match-p "Page 1 of 1" mode-name))
            (should (string-match-p "(0 records)" mode-name)))
        (kill-buffer buf)))))

(ert-deftest test-compilation-history-view-open-compilation ()
  "RET opens compilation buffer in other window."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((buf-name "*compilation-history-20260321T120000000001==proj__make-test*"))
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record
        :record-id "20260321T120000000001"
        :compile-command "make test"
        :buffer-name buf-name))
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0 "build output here")
      (let ((view-buf (compilation-history-view)))
        (unwind-protect
            (with-current-buffer view-buf
              (goto-char (point-min))
              (let ((obj (vtable-current-object)))
                (should obj)
                (should (equal (plist-get obj :command) "make test"))))
          (kill-buffer view-buf)
          (when (get-buffer buf-name)
            (kill-buffer buf-name)))))))

(ert-deftest test-compilation-history-view-no-record-at-point ()
  "RET on non-data row shows message."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-max))
            ;; Should not error
            (compilation-history-view-open))
        (kill-buffer buf)))))

(ert-deftest test-compilation-history-view-preview-activates ()
  "SPC activates preview mode."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :buffer-name "*compilation-history-20260321T120000000001==proj__make*"))
    (compilation-history--update-compilation-record
     "20260321T120000000001" 0 "output")
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (should-not compilation-history-view--preview-mode)
            (when (vtable-current-object)
              (compilation-history-view-preview)
              (should compilation-history-view--preview-mode)))
        (kill-buffer buf)
        (when (get-buffer "*compilation-history-20260321T120000000001==proj__make*")
          (kill-buffer "*compilation-history-20260321T120000000001==proj__make*"))))))

(ert-deftest test-compilation-history-view-open-preserves-preview ()
  "RET does not clear preview mode."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :buffer-name "*compilation-history-20260321T120000000001==proj__make*"))
    (compilation-history--update-compilation-record
     "20260321T120000000001" 0 "output")
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (when (vtable-current-object)
              (compilation-history-view-preview)
              (should compilation-history-view--preview-mode)
              (compilation-history-view-open)
              (with-current-buffer buf
                (should compilation-history-view--preview-mode))))
        (kill-buffer buf)
        (when (get-buffer "*compilation-history-20260321T120000000001==proj__make*")
          (kill-buffer "*compilation-history-20260321T120000000001==proj__make*"))))))

(ert-deftest test-compilation-history-view-quit-clears-preview-and-buries ()
  "q in view clears preview mode and buries opened buffers."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :buffer-name "*compilation-history-20260321T120000000001==proj__make*"))
    (compilation-history--update-compilation-record
     "20260321T120000000001" 0 "output")
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (when (vtable-current-object)
              (compilation-history-view-preview)
              (should compilation-history-view--preview-mode)
              (should compilation-history-view--opened-buffers)
              (compilation-history-view-quit)
              (should-not compilation-history-view--preview-mode)
              (should-not compilation-history-view--opened-buffers)))
        (kill-buffer buf)
        (when (get-buffer "*compilation-history-20260321T120000000001==proj__make*")
          (kill-buffer "*compilation-history-20260321T120000000001==proj__make*"))))))

;;; Opening behavior tests

(ert-deftest test-compilation-history-view-open-sets-compile-command ()
  "Opening a record from the view sets compile-command to the record's command."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((buf-name "*compilation-history-20260321T120000000001==proj__make-test*"))
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record
        :record-id "20260321T120000000001"
        :compile-command "make test"
        :buffer-name buf-name
        :default-directory "/tmp/project/"))
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0 "test output")
      (let ((view-buf (compilation-history-view)))
        (unwind-protect
            (progn
              (with-current-buffer view-buf
                (goto-char (point-min))
                (when (vtable-current-object)
                  (compilation-history-view-open)))
              (let ((comp-buf (get-buffer buf-name)))
                (should comp-buf)
                (should (equal (buffer-local-value 'compile-command comp-buf)
                               "make test"))
                (should (equal (buffer-local-value 'compilation-directory comp-buf)
                               "/tmp/project/"))))
          (kill-buffer view-buf)
          (when (get-buffer buf-name)
            (kill-buffer buf-name)))))))

;;; Kill-buffer behavior tests

(ert-deftest test-compilation-history-kill-buffer-with-exit-code-does-not-update-db ()
  "Killing a compilation buffer that already has an exit code does not update the DB record."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let* ((record (compilation-history-test--make-record
                    :record-id "20260321T120000000001"
                    :buffer-name "*compilation-history-20260321T120000000001==proj__make*"
                    :compile-command "make test")))
      (compilation-history--insert-compilation-record record)
      (compilation-history--update-compilation-record "20260321T120000000001" 0 "success output")
      ;; Open the buffer from the view
      (let ((view-buf (compilation-history-view)))
        (unwind-protect
            (with-current-buffer view-buf
              (goto-char (point-min))
              (when (vtable-current-object)
                (compilation-history-view-open)
                ;; Kill the opened compilation buffer
                (let ((comp-buf (get-buffer "*compilation-history-20260321T120000000001==proj__make*")))
                  (when comp-buf (kill-buffer comp-buf)))
                ;; DB record should still have exit-code 0, not -1 (killed)
                (let* ((page (compilation-history--query-page 1 0))
                       (row (car page))
                       (exit-code (nth 6 row))
                       (killed (nth 7 row)))
                  (should (= exit-code 0))
                  (should (= killed 0)))))
          (kill-buffer view-buf))))))

(ert-deftest test-compilation-history-kill-buffer-without-exit-code-marks-killed ()
  "Killing a compilation buffer with no exit code marks it as killed in the DB."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let* ((record (compilation-history-test--make-record
                    :record-id "20260321T120000000001"
                    :buffer-name "*compilation-history-20260321T120000000001==proj__make*"
                    :compile-command "make test"))
           (buf (get-buffer-create "*compilation-history-20260321T120000000001==proj__make*")))
      (compilation-history--insert-compilation-record record)
      ;; Simulate a running compilation buffer with the record but no exit code
      (with-current-buffer buf
        (setq-local compilation-history-record record)
        (add-hook 'kill-buffer-hook #'compilation-history--kill-buffer-function nil t)
        (insert "partial output"))
      ;; Kill the buffer — should mark as killed
      (kill-buffer buf)
      ;; DB record should have exit-code -1 and killed=1
      (let* ((page (compilation-history--query-page 1 0))
             (row (car page))
             (exit-code (nth 6 row))
             (killed (nth 7 row)))
        (should (= exit-code -1))
        (should (= killed 1))))))

;;; Vtable keymap override tests

(ert-deftest test-compilation-history-view-vtable-keymap-has-our-bindings ()
  "Vtable's keymap includes our key overrides so they work on table rows."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :buffer-name "*compilation-history-20260321T120000000001==proj__make*"))
    (compilation-history--update-compilation-record
     "20260321T120000000001" 0 "output")
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            ;; Get the text-property keymap from the vtable row
            (let ((tp-keymap (get-text-property (point) 'keymap)))
              (should tp-keymap)
              (should (eq (lookup-key tp-keymap "g") #'compilation-history-view-refresh))
              (should (eq (lookup-key tp-keymap "q") #'compilation-history-view-quit))
              (should (eq (lookup-key tp-keymap "Q") #'compilation-history-view-kill-all))
              (should (eq (lookup-key tp-keymap "n") #'compilation-history-view-preview-next))
              (should (eq (lookup-key tp-keymap "p") #'compilation-history-view-preview-prev))
              (should (eq (lookup-key tp-keymap (kbd "M-n")) #'compilation-history-view-preview-next))
              (should (eq (lookup-key tp-keymap (kbd "M-p")) #'compilation-history-view-preview-prev))))
        (kill-buffer buf)
        (when (get-buffer "*compilation-history-20260321T120000000001==proj__make*")
          (kill-buffer "*compilation-history-20260321T120000000001==proj__make*"))))))

(ert-deftest test-compilation-history-view-kill-all-kills-buffers ()
  "Q kills all opened buffers and the view."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((comp-buf-name "*compilation-history-20260321T120000000001==proj__make*"))
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record
        :record-id "20260321T120000000001"
        :buffer-name comp-buf-name))
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0 "output")
      (let ((view-buf (compilation-history-view)))
        (with-current-buffer view-buf
          (goto-char (point-min))
          (when (vtable-current-object)
            (compilation-history-view-preview)
            (should (get-buffer comp-buf-name))
            (compilation-history-view-kill-all)
            ;; Opened compilation buffer should be killed
            (should-not (get-buffer comp-buf-name))
            ;; View buffer should be killed
            (should-not (get-buffer "*Compilation History*"))))))))

(ert-deftest test-compilation-history-view-quit-buries-opened-buffers ()
  "q buries opened buffers (they still exist but are at end of buffer list)."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (let ((comp-buf-name "*compilation-history-20260321T120000000001==proj__make*"))
      (compilation-history--insert-compilation-record
       (compilation-history-test--make-record
        :record-id "20260321T120000000001"
        :buffer-name comp-buf-name))
      (compilation-history--update-compilation-record
       "20260321T120000000001" 0 "output")
      (let ((view-buf (compilation-history-view)))
        (unwind-protect
            (with-current-buffer view-buf
              (goto-char (point-min))
              (when (vtable-current-object)
                (compilation-history-view-preview)
                (should (get-buffer comp-buf-name))
                (compilation-history-view-quit)
                ;; Buffer should still exist (buried, not killed)
                (should (get-buffer comp-buf-name))
                ;; But opened-buffers list should be cleared
                (should-not compilation-history-view--opened-buffers)))
          (when (get-buffer "*Compilation History*")
            (kill-buffer "*Compilation History*"))
          (when (get-buffer comp-buf-name)
            (kill-buffer comp-buf-name)))))))

;;; Search tests

(ert-deftest test-compilation-history-view-search-filters-records ()
  "Setting search-term filters the view to matching records."
  (compilation-history-test-with-db
    (compilation-history--ensure-db)
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000001"
      :compile-command "make test"))
    (compilation-history--insert-compilation-record
     (compilation-history-test--make-record
      :record-id "20260321T120000000002"
      :compile-command "npm run build"))
    (let ((buf (compilation-history-view)))
      (unwind-protect
          (with-current-buffer buf
            ;; Initially shows all records
            (should (= (compilation-history-view-pagination-total-records
                        compilation-history-view--pagination) 2))
            ;; Set search term and re-render
            (setq compilation-history-view--search-term "make")
            (setf (compilation-history-view-pagination-current-page
                   compilation-history-view--pagination) 1)
            (compilation-history-view--render)
            ;; Should show only matching record
            (should (= (compilation-history-view-pagination-total-records
                        compilation-history-view--pagination) 1))
            (let ((content (buffer-string)))
              (should (string-match-p "make test" content))
              (should-not (string-match-p "npm run build" content)))
            ;; Clear search
            (setq compilation-history-view--search-term nil)
            (compilation-history-view--render)
            (should (= (compilation-history-view-pagination-total-records
                        compilation-history-view--pagination) 2)))
        (kill-buffer buf)))))

(provide 'test-compilation-history-view)
;;; test-compilation-history-view.el ends here
