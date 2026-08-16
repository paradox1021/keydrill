;;; keydrill-ui-test.el --- Tests for keydrill-ui  -*- lexical-binding: t; -*-

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

;; ERT tests for the drill session loop and summary.  Answers are
;; stubbed with `cl-letf' on `keydrill-read-answer'; no frames or
;; real keyboard are required.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'keydrill-engine)
(require 'keydrill-store)
(require 'keydrill-ui)

(defvar keydrill-data-file)
(defvar keydrill-hit-pause-seconds)

(defun keydrill-test--ui-move (id key)
  "Return a one-level test move with ID and KEY."
  (list :id id :command 'ignore :key key :level 1 :prompt "do the thing"))

(defun keydrill-test--answers (items)
  "Return a `keydrill-read-answer' stand-in that pops ITEMS.
Each element is a status symbol or a result plist."
  (let ((queue (copy-sequence items)))
    (lambda (_expected &optional _start-time)
      (let ((item (pop queue)))
        (unless item
          (error "No stubbed keydrill answer left"))
        (if (symbolp item)
            (list :status item :latency 100 :got "stub")
          (if (plist-member item :latency)
              item
            (append item (list :latency 100))))))))

(defmacro keydrill-test--with-answers (items &rest body)
  "Evaluate BODY with `keydrill-read-answer' popping ITEMS."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'keydrill-read-answer)
              (keydrill-test--answers ,items)))
     ,@body))

(ert-deftest keydrill-ui-provides-feature ()
  "The UI module provides the `keydrill-ui' feature."
  (should (featurep 'keydrill-ui)))

(ert-deftest keydrill-ui-summary-includes-accuracy-and-median ()
  "Summary text includes accuracy and median latency."
  (let ((text (keydrill-format-summary
               (list :attempted 12
                     :first-try 11
                     :accuracy 92
                     :median 420
                     :introduced 3
                     :pass nil
                     :graduated nil
                     :pass-dates 0
                     :deck-size 85
                     :deck-name "Emacs"))))
    (let ((case-fold-search t))
      (should (string-match-p "accuracy" text))
      (should (string-match-p "92%" text))
      (should (string-match-p "median" text))
      (should (string-match-p "420 ms" text)))
    (should (string-match-p "Introduced this session: 3" text))
    (should (string-match-p "Graduation pace: no" text))))

(ert-deftest keydrill-ui-summary-uses-engine-pass-constants ()
  "Summary target numbers are the engine constants, not a second copy."
  (let ((text (keydrill-format-summary
               (list :attempted 85
                     :first-try 81
                     :accuracy 95
                     :median 400
                     :introduced 0
                     :pass t
                     :graduated nil
                     :pass-dates 1
                     :deck-size 85
                     :deck-name "Emacs"))))
    (should (string-match-p
             (format "need >= %d%%" keydrill-pass-min-accuracy)
             text))
    (should (string-match-p
             (format "need < %d ms" keydrill-pass-max-median)
             text))
    (should (string-match-p "Graduation pace: yes" text))))

(ert-deftest keydrill-ui-intro-card-hides-the-key ()
  "An intro prompt shows the situation, not the binding."
  (let* ((move (keydrill-test--ui-move "a" "C-f"))
         (text (keydrill-card-text move 'intro)))
    (should (string-match-p "do the thing" text))
    (should (string-match-p "Intro" text))
    (should-not (string-match-p "C-f" text))))

(ert-deftest keydrill-ui-intro-hit-marks-drilling-with-seen-zero ()
  "A correct intro press locks drilling and does not add a recall sample."
  (let* ((deck (list (keydrill-test--ui-move "a" "C-f")))
         (store (keydrill-empty-store)))
    (keydrill-test--with-answers '(hit)
      (let* ((result (keydrill-run-session store deck #'identity))
             (rec (keydrill-move-record (plist-get result :store) "a")))
        (should-not (plist-get result :quit))
        (should (eq (plist-get rec :state) 'drilling))
        (should (= (plist-get rec :seen) 0))
        (should (= (plist-get rec :hits) 0))
        (should (= (plist-get result :introduced) 1))
        (should (= (plist-get result :attempted) 0))
        (should (= (plist-get result :first-try) 0))))))

(ert-deftest keydrill-ui-intro-miss-coaches-without-phase-change ()
  "An intro miss stays on the card; a later hit still has :seen 0."
  (let* ((deck (list (keydrill-test--ui-move "a" "C-f")))
         (store (keydrill-empty-store)))
    (keydrill-test--with-answers
        (list (list :status 'miss :latency 80 :got "C-b")
              'hit)
      (let* ((result (keydrill-run-session store deck #'identity))
             (rec (keydrill-move-record (plist-get result :store) "a")))
        (should (eq (plist-get rec :state) 'drilling))
        (should (= (plist-get rec :seen) 0))
        (should (= (plist-get result :attempted) 0))))))

(ert-deftest keydrill-ui-quit-does-not-append-pass-dates ()
  "Quit skips `keydrill-apply-session', so pass dates stay empty."
  (let* ((deck (list (keydrill-test--ui-move "a" "C-f")
                     (keydrill-test--ui-move "b" "C-b")))
         (store (keydrill-mark-drilling
                 (keydrill-mark-drilling (keydrill-empty-store) "a")
                 "b")))
    (keydrill-test--with-answers '(quit)
      (let* ((result (keydrill-run-session store deck #'identity))
             (finished (keydrill-finish-session
                        (plist-get result :store) "emacs" 2 result)))
        (should (plist-get result :quit))
        (should (null (plist-get (keydrill-deck-record finished "emacs")
                                 :pass-dates)))
        (should (eq (keydrill-move-phase finished "a") 'drilling))))))

(ert-deftest keydrill-ui-quit-after-intro-keeps-learning ()
  "Quit after an intro is shown still writes learning, not a pass day."
  (let* ((deck (list (keydrill-test--ui-move "a" "C-f")))
         (store (keydrill-empty-store)))
    (keydrill-test--with-answers '(quit)
      (let* ((result (keydrill-run-session store deck #'identity))
             (finished (keydrill-finish-session
                        (plist-get result :store) "emacs" 1 result))
             (rec (keydrill-move-record finished "a")))
        (should (plist-get result :quit))
        (should (eq (plist-get rec :state) 'learning))
        (should (= (plist-get rec :seen) 0))
        (should (null (plist-get (keydrill-deck-record finished "emacs")
                                 :pass-dates)))))))

(ert-deftest keydrill-ui-finish-matches-engine-apply ()
  "A finished session store equals a direct `keydrill-apply-session'."
  (let* ((store (keydrill-empty-store))
         (lats (make-list 81 300))
         (result (list :quit nil :attempted 85 :first-try 81
                       :lats lats :introduced 0))
         (via-ui (keydrill-finish-session store "emacs" 85 result))
         (acc (keydrill-accuracy 81 85))
         (med (keydrill-median lats))
         (via-engine (keydrill-apply-session store "emacs" acc med 85 85)))
    (should (equal via-ui via-engine))
    (should (equal (keydrill-session-pass-p acc med 85 85)
                   (plist-get (keydrill--summary-stats
                               result via-ui "emacs" 85)
                              :pass)))))

(ert-deftest keydrill-ui-finished-recall-pass-uses-engine ()
  "Full-coverage fast recall records a pass date through the engine."
  (let* ((deck (list (keydrill-test--ui-move "a" "C-f")))
         (store (keydrill-mark-drilling (keydrill-empty-store) "a")))
    (keydrill-test--with-answers
        (list (list :status 'hit :latency 120))
      (let* ((result (keydrill-run-session store deck #'identity))
             (finished (keydrill-finish-session
                        (plist-get result :store) "emacs" 1 result))
             (acc (keydrill-accuracy (plist-get result :first-try)
                                     (plist-get result :attempted)))
             (med (keydrill-median (plist-get result :lats))))
        (should (= (plist-get result :attempted) 1))
        (should (= (plist-get result :first-try) 1))
        (should (keydrill-session-pass-p acc med 1 1))
        (should (equal (plist-get (keydrill-deck-record finished "emacs")
                                  :pass-dates)
                       (list (keydrill-today-string))))))))

(ert-deftest keydrill-ui-slow-recall-does-not-pass ()
  "Median at the engine cap is not graduation pace."
  (let* ((deck (list (keydrill-test--ui-move "a" "C-f")))
         (store (keydrill-mark-drilling (keydrill-empty-store) "a")))
    (keydrill-test--with-answers
        (list (list :status 'hit :latency keydrill-pass-max-median))
      (let* ((result (keydrill-run-session store deck #'identity))
             (finished (keydrill-finish-session
                        (plist-get result :store) "emacs" 1 result))
             (acc (keydrill-accuracy 1 1))
             (med (keydrill-median (plist-get result :lats))))
        (should-not (keydrill-session-pass-p acc med 1 1))
        (should (null (plist-get (keydrill-deck-record finished "emacs")
                                 :pass-dates)))))))

(ert-deftest keydrill-ui-recall-miss-records-once-then-requeue-touches ()
  "First recall miss samples once; the requeue only touches last-seen."
  (let* ((deck (list (keydrill-test--ui-move "a" "C-f")))
         (store (keydrill-mark-drilling (keydrill-empty-store) "a")))
    (keydrill-test--with-answers
        (list (list :status 'miss :latency 90 :got "C-b")
              'hit
              'hit)
      (let* ((result (keydrill-run-session store deck #'identity))
             (rec (keydrill-move-record (plist-get result :store) "a")))
        (should (= (plist-get rec :seen) 1))
        (should (= (plist-get rec :hits) 0))
        (should (= (plist-get result :attempted) 1))
        (should (= (plist-get result :first-try) 0))
        (should (null (plist-get result :lats)))
        (should (equal (plist-get rec :last-seen)
                       (keydrill-today-string)))))))

(ert-deftest keydrill-ui-start-quit-saves-progress ()
  "Interactive start saves intro progress on quit and writes no pass dates."
  (let ((keydrill-data-file (make-temp-file "keydrill-ui-" nil ".eld"))
        (keydrill-hit-pause-seconds 0)
        (deck (list (keydrill-test--ui-move "a" "C-f"))))
    (unwind-protect
        (save-window-excursion
          (keydrill-test--with-answers '(quit)
            (keydrill-ui-start deck "emacs"))
          (let* ((store (keydrill-store-load))
                 (rec (keydrill-move-record store "a")))
            (should (eq (plist-get rec :state) 'learning))
            (should (null (plist-get (keydrill-deck-record store "emacs")
                                     :pass-dates)))))
      (when (file-exists-p keydrill-data-file)
        (delete-file keydrill-data-file))
      (when (get-buffer keydrill-buffer-name)
        (kill-buffer keydrill-buffer-name)))))

(ert-deftest keydrill-ui-start-finished-summary-in-buffer ()
  "A finished session writes accuracy and median into *keydrill*."
  (let ((keydrill-data-file (make-temp-file "keydrill-ui-" nil ".eld"))
        (keydrill-hit-pause-seconds 0)
        (deck (list (keydrill-test--ui-move "a" "C-f")))
        (store (keydrill-mark-drilling (keydrill-empty-store) "a")))
    (unwind-protect
        (progn
          (keydrill-store-save store)
          (save-window-excursion
            (keydrill-test--with-answers
                (list (list :status 'hit :latency 150))
              (keydrill-ui-start deck "emacs")))
          (with-current-buffer keydrill-buffer-name
            (let ((text (buffer-string))
                  (case-fold-search t))
              (should (string-match-p "accuracy" text))
              (should (string-match-p "100%" text))
              (should (string-match-p "median" text))
              (should (string-match-p "150 ms" text))
              (should (string-match-p "Graduation pace: yes" text)))))
      (when (file-exists-p keydrill-data-file)
        (delete-file keydrill-data-file))
      (when (get-buffer keydrill-buffer-name)
        (kill-buffer keydrill-buffer-name)))))

(ert-deftest keydrill-ui-graduation-text-is-quiet ()
  "Graduation copy names two distinct pass dates and nothing else loud."
  (let ((text (keydrill-format-graduation))
        (case-fold-search t))
    (should (string-match-p "Graduated" text))
    (should (string-match-p "two distinct local days" text))))

(ert-deftest keydrill-ui-summary-zero-median-is-not-a-speed-pass ()
  "A zero median means no sample survived, and must not read as 0 ms.
Latencies at or above `keydrill-latency-interrupt-ms' are dropped,
so an all-slow session leaves nothing to take a median of."
  (let ((text (keydrill-format-summary
               (list :accuracy 100 :median 0 :introduced 0
                     :attempted 1 :first-try 1 :pass nil
                     :graduated nil :pass-dates 0
                     :deck-size 85 :deck-name "Emacs"))))
    (should-not (string-match-p "latency: 0 ms" text))
    (should (string-match-p "no timed answers" text))))

(ert-deftest keydrill-ui-summary-real-median-is-shown ()
  "A surviving median is printed as milliseconds."
  (let ((text (keydrill-format-summary
               (list :accuracy 100 :median 412 :introduced 0
                     :attempted 1 :first-try 1 :pass nil
                     :graduated nil :pass-dates 0
                     :deck-size 85 :deck-name "Emacs"))))
    (should (string-match-p "latency: 412 ms" text))))

(ert-deftest keydrill-ui-text-scale-applies-to-drill-buffer ()
  "A nonzero `keydrill-text-scale' scales the keydrill buffer."
  (let ((keydrill-text-scale 3))
    (with-temp-buffer
      (keydrill-mode)
      (should (= text-scale-mode-amount 3))))
  (let ((keydrill-text-scale 0))
    (with-temp-buffer
      (keydrill-mode)
      (should (= text-scale-mode-amount 0)))))

(provide 'keydrill-ui-test)
;;; keydrill-ui-test.el ends here
