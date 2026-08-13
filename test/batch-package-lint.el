;;; batch-package-lint.el --- Run package-lint on keydrill  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  keydrill contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Batch helper for `make lint'.  Installs package-lint into .elpa/
;; under the repo root if needed.  Not part of the package.
;;
;; There is no public homepage yet, so the missing Homepage/URL header
;; is filtered.  Every other package-lint warning or error still fails
;; the batch.

;;; Code:

(require 'cl-lib)
(require 'package)

(defun keydrill-batch-package-lint-keep-p (err)
  "Return non-nil if ERR should fail the batch.
ERR is (LINE COL TYPE MESSAGE) from `package-lint-buffer'."
  (let ((message (nth 3 err)))
    (not (string-equal message "Package should have a Homepage or URL header."))))

(let* ((root (expand-file-name ".." (file-name-directory (or load-file-name
                                                            default-directory))))
       (default-directory root)
       (package-user-dir (expand-file-name ".elpa" root))
       (package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                           ("melpa" . "https://melpa.org/packages/")))
       (files '("keydrill.el"
                "keydrill-engine.el"
                "keydrill-capture.el"
                "keydrill-ui.el"
                "keydrill-live.el"
                "keydrill-observe.el"
                "keydrill-store.el"
                "keydrill-deck-emacs.el"))
       (failed nil))
  (package-initialize)
  (unless (package-installed-p 'package-lint)
    (package-refresh-contents)
    (package-install 'package-lint))
  (require 'package-lint)
  (setq package-lint-main-file (expand-file-name "keydrill.el" root))
  (dolist (file files)
    (let ((abs (expand-file-name file root)))
      (with-temp-buffer
        (insert-file-contents abs t)
        (emacs-lisp-mode)
        (let ((kept (cl-remove-if-not #'keydrill-batch-package-lint-keep-p
                                      (package-lint-buffer))))
          (when kept
            (setq failed t)
            (dolist (err kept)
              (pcase err
                (`(,line ,col ,type ,message)
                 (message "%s:%d:%d: %s: %s"
                          file line col type message)))))))))
  (kill-emacs (if failed 1 0)))

;;; batch-package-lint.el ends here
