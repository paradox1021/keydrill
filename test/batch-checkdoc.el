;;; batch-checkdoc.el --- Run checkdoc on keydrill package files  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Astrolabe Apps, Inc.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Batch helper for `make lint'.  Not part of the package.
;; Emacs 27 has no `checkdoc-create-error-function'; that binding is
;; used only when `boundp' is true.  On Emacs 27, warnings are read
;; from the diagnostic buffer instead.

;;; Code:

(require 'checkdoc)

(defvar keydrill-batch-checkdoc-issues 0
  "Number of checkdoc issues found in this batch run.")

(defun keydrill-batch-checkdoc-note (text start end &optional unfixable)
  "Record a checkdoc issue and keep going.
TEXT, START, END, and UNFIXABLE match `checkdoc-create-error-function'."
  (setq keydrill-batch-checkdoc-issues (1+ keydrill-batch-checkdoc-issues))
  (message "%s:%s: %s"
           (or (buffer-file-name) (buffer-name))
           (line-number-at-pos (or start (point)))
           text)
  (list text start end unfixable))

(defun keydrill-batch-checkdoc-scan-diagnostics ()
  "Count Emacs 27 checkdoc warnings in the diagnostic buffer.
Look for a \"[0-9]+ warning\" line written by checkdoc."
  (let* ((name (if (boundp 'checkdoc-diagnostic-buffer)
                   checkdoc-diagnostic-buffer
                 "*Style Warnings*"))
         (buf (get-buffer name)))
    (when buf
      (with-current-buffer buf
        (goto-char (point-min))
        (while (re-search-forward "[0-9]+ warning" nil t)
          (setq keydrill-batch-checkdoc-issues
                (1+ keydrill-batch-checkdoc-issues)))
        (message "%s" (buffer-string))
        (kill-buffer buf)))))

(defun keydrill-batch-checkdoc-file (file)
  "Run checkdoc on FILE with an Emacs 27-compatible method."
  (with-current-buffer (find-file-noselect file)
    (if (boundp 'checkdoc-create-error-function)
        (let ((checkdoc-create-error-function #'keydrill-batch-checkdoc-note))
          (checkdoc-current-buffer t))
      (checkdoc-current-buffer t)
      (keydrill-batch-checkdoc-scan-diagnostics))))

(let* ((root (expand-file-name ".." (file-name-directory (or load-file-name
                                                            default-directory))))
       (default-directory root)
       (files '("keydrill.el"
                "keydrill-engine.el"
                "keydrill-capture.el"
                "keydrill-ui.el"
                "keydrill-live.el"
                "keydrill-journal.el"
                "keydrill-observe.el"
                "keydrill-store.el"
                "keydrill-deck-emacs.el")))
  (dolist (file files)
    (let ((abs (expand-file-name file root)))
      (message "checkdoc %s" file)
      (keydrill-batch-checkdoc-file abs)))
  (when (> keydrill-batch-checkdoc-issues 0)
    (message "checkdoc found %d issue(s)" keydrill-batch-checkdoc-issues))
  (kill-emacs (if (> keydrill-batch-checkdoc-issues 0) 1 0)))

;;; batch-checkdoc.el ends here