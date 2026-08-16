;;; keydrill-store.el --- Persist progress to a readable .eld file  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Astrolabe Apps, Inc.

;; Author: Brendan Kavanaugh (Astrolabe Apps, Inc.) <Brendan@astrolabeapps.com>
;; Assisted-by: Cursor:claude-opus-5
;; Assisted-by: Cursor:composer-2.5
;; Assisted-by: Cursor:grok-4.6
;; Keywords: convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
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

;; Read and write `keydrill-data-file' with `prin1' / `read'.  The file
;; is meant to be greppable.  This module is the only place that touches
;; the progress file.  The sexp is the store plist from
;; `keydrill-empty-store'.

;;; Code:

(require 'keydrill-engine)

(defvar keydrill-data-file nil
  "Path of the progress file.  Defined as a defcustom in keydrill.el.")

(defvar keydrill-store-before-save-functions nil
  "Abnormal hook run before writing a store.
Each function receives the store plist and must return a store
plist.  Used to merge in-memory observer counts into a session
save so a drill does not wipe them.")

(defvar keydrill-store-after-purge-functions nil
  "Normal hook run after a progress file is deleted.")

(defun keydrill-store-load (&optional file)
  "Read progress from FILE, or `keydrill-data-file'.
Return an empty store when FILE does not exist or is empty."
  (let ((file (or file keydrill-data-file)))
    (if (not (file-exists-p file))
        (keydrill-empty-store)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (if (eobp)
            (keydrill-empty-store)
          (let ((form (read (current-buffer))))
            (unless (listp form)
              (error "Progress file %s is not a Lisp list" file))
            form))))))

(defun keydrill-store-save (store &optional file)
  "Write STORE to FILE, or `keydrill-data-file'.
The file is a single readable sexp.  Functions on
`keydrill-store-before-save-functions' may replace STORE before
the write."
  (let ((file (or file keydrill-data-file))
        (print-length nil)
        (print-level nil)
        (print-circle nil))
    (dolist (fn keydrill-store-before-save-functions)
      (setq store (funcall fn store)))
    (when (file-name-directory file)
      (make-directory (file-name-directory file) t))
    (with-temp-file file
      (prin1 store (current-buffer))
      (terpri (current-buffer)))))

(defun keydrill-store-purge (&optional file)
  "Delete FILE, or `keydrill-data-file', if it exists.
Return non-nil when a file was deleted.  Runs
`keydrill-store-after-purge-functions' after a successful
delete."
  (let ((file (or file keydrill-data-file)))
    (when (file-exists-p file)
      (delete-file file)
      (run-hooks 'keydrill-store-after-purge-functions)
      t)))

(provide 'keydrill-store)
;;; keydrill-store.el ends here
