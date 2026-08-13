;;; keydrill.el --- Drill key bindings until they stick  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  keydrill contributors

;; Author: keydrill contributors
;; Maintainer: keydrill contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, help
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

;; Drill Emacs key bindings in short sessions until they stick.
;; Progress is a readable .eld file in `user-emacs-directory'.
;; `M-x keydrill' starts a session on the curated Emacs deck.
;; At session start, each command is looked up in the buffer you
;; launched from; a remapped binding is drilled instead of the
;; vanilla default.  `M-x keydrill-observe-mode' is an opt-in usage
;; counter, off by default.  Counts stay in the same local .eld
;; file; this package has no network code.  `M-x keydrill-report'
;; lists commands you run via M-x or the menu that already have a
;; key.  `M-x keydrill-purge-data' deletes progress.
;;
;; This package does not talk to the network.  There is no
;; account, no telemetry, and no HTTP client.
;;
;; Prompts were adapted from my web trainer.  Prior art: key-quiz
;; (federicotdn) and keywiz.

;;; Code:

(defgroup keydrill nil
  "Drill Emacs key bindings until they stick."
  :group 'convenience
  :prefix "keydrill-")

(defcustom keydrill-data-file
  (locate-user-emacs-file "keydrill-data.eld")
  "File where keydrill stores progress.
The file is a readable Lisp sexp written with `prin1'."
  :type 'file
  :group 'keydrill)

(defcustom keydrill-max-new-per-session 5
  "Maximum number of new or learning moves introduced in one session."
  :type 'integer
  :group 'keydrill)

(defcustom keydrill-sequence-timeout 1.5
  "Seconds to wait for the next key in a multi-key sequence.
A timeout is a miss.  The default 1.5 is a 1500 ms window."
  :type 'number
  :group 'keydrill)

(defcustom keydrill-unbound-strategy 'prompt-by-name
  "What to do when a deck command has no binding in the live keymap.
`skip' omits the move from intros and recall for this session.
`prompt-by-name' keeps the move.  The expected key is
\\[execute-extended-command].  Scoring does not include typing
the command name.  The prompt shows the command symbol so the
user knows what to type after that chord."
  :type '(choice (const prompt-by-name)
                 (const skip))
  :group 'keydrill)

(defcustom keydrill-observe-report-limit 10
  "Maximum unused-binding gaps to show in `keydrill-report'."
  :type 'integer
  :group 'keydrill)

(require 'keydrill-engine)
(require 'keydrill-capture)
(require 'keydrill-ui)
(require 'keydrill-live)
(require 'keydrill-observe)
(require 'keydrill-store)
(require 'keydrill-deck-emacs)

;;;###autoload
(defun keydrill ()
  "Start a keydrill session on the curated Emacs deck.
Remembers `current-buffer' as the launch context for a later
live-keymap lookup.  Progress is the file `keydrill-data-file'."
  (interactive)
  (keydrill-ui-start keydrill-deck-emacs "emacs"))

;;;###autoload
(defun keydrill-purge-data ()
  "Delete the local keydrill progress file after yes-or-no confirmation."
  (interactive)
  (if (not (and (boundp 'keydrill-data-file)
                keydrill-data-file
                (file-exists-p keydrill-data-file)))
      (message "No keydrill progress file to delete")
    (when (yes-or-no-p (format "Delete %s? " keydrill-data-file))
      (keydrill-store-purge)
      (message "Deleted %s" keydrill-data-file))))

(provide 'keydrill)
;;; keydrill.el ends here
