;;; keydrill-journal-test.el --- Tests for keydrill-journal  -*- lexical-binding: t; -*-

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

;; ERT tests for the append-only answer journal and the cold
;; benchmark.  Journal files are temp files; `keydrill-journal-inhibit'
;; is bound to nil where writes are exercised.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'keydrill-engine)
(require 'keydrill-capture)
(require 'keydrill-journal)
(require 'keydrill-store)
(require 'keydrill-ui)
(require 'keydrill-live)

(defvar keydrill-data-file)
(defvar keydrill-hit-pause-seconds)

(defmacro keydrill-test-journal-with (varlist &rest body)
  "Run BODY with a temp journal enabled, then delete it.
VARLIST is ignored; it exists so the macro reads like `let'."
  (declare (indent 1))
  (ignore varlist)
  `(let ((keydrill-journal-file
          (make-temp-file "keydrill-journal-" nil ".eld"))
         (keydrill-journal-inhibit nil))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p keydrill-journal-file)
         (delete-file keydrill-journal-file)))))

(defun keydrill-test-journal-move (id key &optional prompt)
  "Return a minimal move plist for ID bound to KEY with PROMPT."
  (list :id id :command 'ignore :key key :level 1
        :prompt (or prompt id)))

(ert-deftest keydrill-journal-append-and-read-round-trip ()
  "Records written with `keydrill-journal-append' read back in order."
  (keydrill-test-journal-with ()
    (keydrill-journal-append '(:v 1 :kind begin :t 1.0 :session "s"))
    (keydrill-journal-append '(:v 1 :kind answer :t 2.0 :session "s"
                               :id "a" :status hit :latency 500))
    (keydrill-journal-append '(:v 1 :kind end :t 3.0 :session "s"
                               :complete t))
    (let ((records (keydrill-journal-records)))
      (should (= (length records) 3))
      (should (equal (mapcar (lambda (r) (plist-get r :kind)) records)
                     '(begin answer end)))
      (should (= (plist-get (nth 1 records) :latency) 500)))))

(ert-deftest keydrill-journal-disabled-writes-nothing ()
  "A nil journal file or inhibit flag suppresses writes."
  (let ((keydrill-journal-file nil)
        (keydrill-journal-inhibit nil))
    (should-not (keydrill-journal-enabled-p))
    (should (equal (keydrill-journal-append '(:v 1 :kind begin))
                   '(:v 1 :kind begin))))
  (keydrill-test-journal-with ()
    (let ((keydrill-journal-inhibit t))
      (keydrill-journal-append '(:v 1 :kind begin)))
    (should (null (keydrill-journal-records)))))

(ert-deftest keydrill-journal-records-missing-file-is-nil ()
  "Reading a journal that does not exist returns nil."
  (let ((keydrill-journal-file "/nonexistent/keydrill-journal.eld"))
    (should (null (keydrill-journal-records)))))

(ert-deftest keydrill-journal-benchmark-run-logs-and-preserves-store ()
  "A benchmark journals begin/answers/end and never touches the store."
  (keydrill-test-journal-with ()
    (let* ((keydrill-data-file
            (make-temp-file "keydrill-journal-store-" nil ".eld"))
           (moves (list (keydrill-test-journal-move "t.a" "C-a")
                        (keydrill-test-journal-move "t.b" "C-b")))
           (script '((:status hit :latency 400)
                     (:status miss :latency 900 :got "C-c"))))
      ;; Start with no store file; the benchmark must not create one.
      (delete-file keydrill-data-file)
      (unwind-protect
          (cl-letf (((symbol-function 'keydrill-read-answer)
                     (lambda (_expected &optional _start)
                       (pop script))))
            (let ((outcome (keydrill-benchmark-run moves "emacs")))
              (should (plist-get outcome :complete))
              (should-not (plist-get outcome :quit))
              (should (= (length (plist-get outcome :results)) 2))
              ;; The store file was never created: measurement, not lesson.
              (should-not (file-exists-p keydrill-data-file))
              (let* ((records (keydrill-journal-records))
                     (kinds (mapcar (lambda (r) (plist-get r :kind))
                                    records)))
                (should (equal kinds '(begin answer answer end)))
                (should (eq (plist-get (car records) :mode) 'benchmark))
                (should (equal (plist-get (nth 1 records) :id) "t.a"))
                (should (eq (plist-get (nth 2 records) :status) 'miss))
                (should (eq (plist-get (nth 3 records) :complete) t))
                ;; One session id stamps every record.
                (should (= 1 (length (delete-dups
                                      (mapcar (lambda (r)
                                                (plist-get r :session))
                                              records))))))))
        (when (file-exists-p keydrill-data-file)
          (delete-file keydrill-data-file))))))

(ert-deftest keydrill-journal-benchmark-quit-marks-incomplete ()
  "Quitting mid-benchmark journals an end record with :complete nil."
  (keydrill-test-journal-with ()
    (let* ((moves (list (keydrill-test-journal-move "t.a" "C-a")
                        (keydrill-test-journal-move "t.b" "C-b")))
           (script '((:status hit :latency 300)
                     (:status quit :latency 0))))
      (cl-letf (((symbol-function 'keydrill-read-answer)
                 (lambda (_expected &optional _start)
                   (pop script))))
        (let ((outcome (keydrill-benchmark-run moves "emacs")))
          (should (plist-get outcome :quit))
          (should-not (plist-get outcome :complete))
          (let* ((records (keydrill-journal-records))
                 (kinds (mapcar (lambda (r) (plist-get r :kind)) records)))
            ;; The quit itself is not an answer record.
            (should (equal kinds '(begin answer end)))
            (should (eq (plist-get (nth 2 records) :complete) nil))))))))

(ert-deftest keydrill-journal-drill-session-logs-answers ()
  "An interactive drill run journals begin, per-card answers, and end."
  (keydrill-test-journal-with ()
    (let* ((keydrill-data-file
            (make-temp-file "keydrill-journal-drill-" nil ".eld"))
           (keydrill-hit-pause-seconds 0)
           (deck (list (keydrill-test-journal-move "t.a" "C-a")))
           (script '((:status hit :latency 350))))
      (unwind-protect
          (save-window-excursion
            (with-temp-buffer
              (cl-letf (((symbol-function 'keydrill-read-answer)
                         (lambda (_expected &optional _start)
                           (pop script))))
                (keydrill-ui-start deck "emacs" deck))
              (let* ((records (keydrill-journal-records))
                     (kinds (mapcar (lambda (r) (plist-get r :kind))
                                    records)))
                (should (equal kinds '(begin answer end)))
                (should (eq (plist-get (car records) :mode) 'drill))
                (should (eq (plist-get (nth 1 records) :card) 'recall))
                (should (equal (plist-get (nth 1 records) :id) "t.a"))
                (should (eq (plist-get (nth 2 records) :complete) t)))))
        (when (file-exists-p keydrill-data-file)
          (delete-file keydrill-data-file))
        (when (get-buffer keydrill-buffer-name)
          (kill-buffer keydrill-buffer-name))))))

(ert-deftest keydrill-journal-summary-handles-empty-and-full ()
  "Benchmark summary renders for zero answers and for real results."
  (let ((empty (keydrill-benchmark--summary nil 85)))
    (should (string-match-p "0 / 85" empty)))
  (let* ((move (keydrill-test-journal-move "t.a" "C-a"))
         (results (list (cons move '(:status hit :latency 412))))
         (text (keydrill-benchmark--summary results 1)))
    (should (string-match-p "1 / 1" text))
    (should (string-match-p "412 ms" text))
    (should (string-match-p "t.a" text))))

(provide 'keydrill-journal-test)
;;; keydrill-journal-test.el ends here
