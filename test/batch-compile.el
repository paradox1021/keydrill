;;; batch-compile.el --- Byte-compile keydrill with warnings as errors  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  keydrill contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Batch helper for `make compile'.  Not part of the package.

;;; Code:

(setq byte-compile-error-on-warn t)

(let* ((root (expand-file-name ".." (file-name-directory (or load-file-name
                                                            default-directory))))
       (default-directory root)
       (load-path (cons root load-path))
       ;; Libraries first so `keydrill.el' sees current definitions.
       (files '("keydrill-engine.el"
                "keydrill-capture.el"
                "keydrill-store.el"
                "keydrill-live.el"
                "keydrill-ui.el"
                "keydrill-deck-emacs.el"
                "keydrill-observe.el"
                "keydrill.el"))
       (failed nil))
  (dolist (elc (directory-files root t "\\.elc\\'"))
    (delete-file elc))
  (dolist (file files)
    (let ((abs (expand-file-name file root)))
      (message "byte-compile %s" file)
      (unless (byte-compile-file abs)
        (setq failed t))))
  (kill-emacs (if failed 1 0)))

;;; batch-compile.el ends here
