;;; keydrill-store-test.el --- Tests for keydrill-store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  keydrill contributors

;; Author: keydrill contributors
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

;; ERT tests for store round-trip.

;;; Code:

(require 'ert)
(require 'keydrill-engine)
(require 'keydrill-store)

(defvar keydrill-data-file)

(defvar keydrill-data-file)

(ert-deftest keydrill-store-provides-feature ()
  "The store module provides the `keydrill-store' feature."
  (should (featurep 'keydrill-store)))

(ert-deftest keydrill-store-load-missing-file-is-empty ()
  "A missing file loads as an empty store."
  (let ((file (expand-file-name "no-such-keydrill-store.eld"
                                (temporary-file-directory))))
    (when (file-exists-p file)
      (delete-file file))
    (let ((store (keydrill-store-load file)))
      (should (null (plist-get store :moves)))
      (should (null (plist-get store :decks))))))

(ert-deftest keydrill-store-load-empty-file-is-empty ()
  "An empty existing file loads as an empty store."
  (let ((file (make-temp-file "keydrill-store-" nil ".eld")))
    (unwind-protect
        (let ((store (keydrill-store-load file)))
          (should (null (plist-get store :moves)))
          (should (null (plist-get store :decks))))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest keydrill-store-round-trip ()
  "prin1 then read restores a store with a couple of moves."
  (let* ((file (make-temp-file "keydrill-store-" nil ".eld"))
         (store (keydrill-empty-store)))
    (setq store (keydrill-mark-drilling store "emacs.cancel"))
    (setq store (keydrill-record-recall store "emacs.cancel" t 250
                                        "2026-08-12"))
    (setq store (keydrill-mark-learning store "emacs.save"))
    (unwind-protect
        (progn
          (keydrill-store-save store file)
          (let* ((loaded (keydrill-store-load file))
                 (cancel (keydrill-move-record loaded "emacs.cancel"))
                 (save (keydrill-move-record loaded "emacs.save")))
            (should (= (plist-get cancel :seen) 1))
            (should (= (plist-get cancel :hits) 1))
            (should (= (plist-get cancel :last-latency) 250))
            (should (equal (plist-get cancel :last-seen) "2026-08-12"))
            (should (eq (plist-get cancel :state) 'drilling))
            (should (eq (plist-get save :state) 'learning))))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest keydrill-store-purge-deletes-file ()
  "Purge removes the bound `keydrill-data-file'."
  (let ((keydrill-data-file (make-temp-file "keydrill-store-" nil ".eld")))
    (unwind-protect
        (progn
          (keydrill-store-save (keydrill-empty-store))
          (should (file-exists-p keydrill-data-file))
          (should (keydrill-store-purge))
          (should-not (file-exists-p keydrill-data-file))
          (should-not (keydrill-store-purge)))
      (when (file-exists-p keydrill-data-file)
        (delete-file keydrill-data-file)))))

(provide 'keydrill-store-test)
;;; keydrill-store-test.el ends here
