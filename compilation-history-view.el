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

(provide 'compilation-history-view)
;;; compilation-history-view.el ends here
