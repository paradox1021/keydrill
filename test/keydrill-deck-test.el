;;; keydrill-deck-test.el --- Tests for the curated Emacs deck  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Astrolabe Apps, Inc.

;; Author: Brendan Kavanaugh (Astrolabe Apps, Inc.) <Brendan@astrolabeapps.com>
;; Assisted-by: Cursor:claude-opus-5
;; Assisted-by: Cursor:composer-2.5
;; Assisted-by: Cursor:grok-4.6
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

;; Every curated move must be a real command whose vanilla :key is a
;; binding in `global-map'.  This is the emacs -Q check from the
;; publish checklist, run in CI so it cannot drift.

;;; Code:

(require 'ert)
(require 'keydrill-capture)
(require 'keydrill-deck-emacs)

(ert-deftest keydrill-deck-emacs-size ()
  "The curated Emacs deck has 85 moves."
  (should (= (length keydrill-deck-emacs) 85)))

(ert-deftest keydrill-deck-emacs-vanilla-keys-in-global-map ()
  "Every move is a command and its :key is in `global-map'.
Compared as `keydrill-normalize-keys' strings so `C-/' and `C-_'
count as the same binding.  Uses `global-map' rather than the
current buffer: a major mode may shadow M-q and similar."
  (dolist (m keydrill-deck-emacs)
    (let* ((cmd (plist-get m :command))
           (want (keydrill-normalize-keys (plist-get m :key)))
           (raw (where-is-internal cmd global-map nil nil t))
           (got (mapcar #'keydrill-normalize-keys raw)))
      (should (commandp cmd))
      (should (consp raw))
      (should (member want got)))))

(provide 'keydrill-deck-test)
;;; keydrill-deck-test.el ends here
