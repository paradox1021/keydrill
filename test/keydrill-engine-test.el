;;; keydrill-engine-test.el --- Tests for keydrill-engine  -*- lexical-binding: t; -*-

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

;; ERT tests for lifecycle, planner, and scoring.

;;; Code:

(require 'ert)
(require 'keydrill-engine)

(defun keydrill-test--move (id level)
  "Return a deck move plist for tests with ID and LEVEL."
  (list :id id :command 'ignore :key "C-f" :level level :prompt "p"))

(defun keydrill-test--drilling (id &rest rec-plist)
  "Return STORE with ID drilling and REC-PLIST merged into the record."
  (let* ((store (keydrill-mark-drilling (keydrill-empty-store) id))
         (rec (copy-sequence (keydrill-move-record store id))))
    (while rec-plist
      (setq rec (plist-put rec (pop rec-plist) (pop rec-plist))))
    (keydrill--put-move store id rec)))

(ert-deftest keydrill-engine-provides-feature ()
  "The engine module provides the `keydrill-engine' feature."
  (should (featurep 'keydrill-engine)))

(ert-deftest keydrill-move-state-absent-is-new ()
  "A missing record is new."
  (should (eq (keydrill-move-state (keydrill-empty-store) "emacs.cancel")
              'new)))

(ert-deftest keydrill-move-phase-missing-state-with-samples-is-drilling ()
  "Pre-state records with samples are drilling."
  (let ((store (keydrill--put-move
                (keydrill-empty-store) "a"
                (list :seen 2 :hits 1 :last-latency 400
                      :last-seen "2026-01-01" :state nil))))
    (should (eq (keydrill-move-phase store "a") 'drilling))
    (should (eq (keydrill-move-state store "a") 'drilling))))

(ert-deftest keydrill-move-phase-missing-state-without-samples-is-new ()
  "Pre-state records with no samples are new."
  (let ((store (keydrill--put-move
                (keydrill-empty-store) "a"
                (list :seen 0 :hits 0 :last-latency 0
                      :last-seen "" :state nil))))
    (should (eq (keydrill-move-phase store "a") 'new))))

(ert-deftest keydrill-mark-learning-and-drilling ()
  "Intro shown writes learning; a correct intro press locks drilling."
  (let* ((shown (keydrill-mark-learning (keydrill-empty-store) "a"))
         (locked (keydrill-mark-drilling shown "a")))
    (should (eq (keydrill-move-phase shown "a") 'learning))
    (should (eq (keydrill-move-phase locked "a") 'drilling))
    (should (= (plist-get (keydrill-move-record locked "a") :seen) 0))))

(ert-deftest keydrill-mark-learning-skips-non-new ()
  "Marking learning on an already-introduced move is a no-op."
  (let ((store (keydrill-mark-learning (keydrill-empty-store) "a")))
    (should (eq (keydrill-move-phase
                 (keydrill-mark-learning store "a") "a")
                'learning))))

(ert-deftest keydrill-move-state-learned-thresholds ()
  "Learned requires 3 samples, 90% first-try, and last latency under 800ms."
  (should (eq (keydrill-move-state
               (keydrill-test--drilling "a" :seen 3 :hits 3 :last-latency 400)
               "a")
              'learned))
  (should (eq (keydrill-move-state
               (keydrill-test--drilling "a" :seen 2 :hits 2 :last-latency 400)
               "a")
              'drilling))
  (should (eq (keydrill-move-state
               (keydrill-test--drilling "a" :seen 3 :hits 3 :last-latency 800)
               "a")
              'drilling))
  (should (eq (keydrill-move-state
               (keydrill-test--drilling "a" :seen 3 :hits 3 :last-latency 0)
               "a")
              'drilling))
  (should (eq (keydrill-move-state
               (keydrill-test--drilling "a" :seen 30 :hits 26 :last-latency 400)
               "a")
              'drilling))
  (should (eq (keydrill-move-state
               (keydrill-test--drilling "a" :seen 100 :hits 89 :last-latency 400)
               "a")
              'drilling))
  (should (eq (keydrill-move-state
               (keydrill-test--drilling "a" :seen 30 :hits 27 :last-latency 400)
               "a")
              'learned))
  (should (eq (keydrill-move-state
               (keydrill-test--drilling "a" :seen 3 :hits 3 :last-latency 799)
               "a")
              'learned))
  (let ((store (keydrill-mark-learning (keydrill-empty-store) "a"))
        (rec nil)
        (store2 nil))
    (setq rec (copy-sequence (keydrill-move-record store "a")))
    (setq rec (plist-put rec :seen 3))
    (setq rec (plist-put rec :hits 3))
    (setq rec (plist-put rec :last-latency 400))
    (setq store2 (keydrill--put-move store "a" rec))
    (should (eq (keydrill-move-state store2 "a") 'learning))))

(ert-deftest keydrill-record-recall-hit-and-miss ()
  "A first-try hit updates hits and latency; a miss only increments seen."
  (let* ((base (keydrill-mark-drilling (keydrill-empty-store) "a"))
         (hit (keydrill-record-recall base "a" t 412.2 "2026-08-12"))
         (miss (keydrill-record-recall hit "a" nil 0 "2026-08-13")))
    (should (= (plist-get (keydrill-move-record hit "a") :seen) 1))
    (should (= (plist-get (keydrill-move-record hit "a") :hits) 1))
    (should (= (plist-get (keydrill-move-record hit "a") :last-latency) 412))
    (should (equal (plist-get (keydrill-move-record hit "a") :last-seen)
                   "2026-08-12"))
    (should (= (plist-get (keydrill-move-record miss "a") :seen) 2))
    (should (= (plist-get (keydrill-move-record miss "a") :hits) 1))
    (should (= (plist-get (keydrill-move-record miss "a") :last-latency) 412))))

(ert-deftest keydrill-record-recall-ignores-interrupt-latency ()
  "Latencies at or above 10000ms are not stored."
  (let* ((base (keydrill-mark-drilling (keydrill-empty-store) "a"))
         (store (keydrill-record-recall base "a" t 10000 "2026-08-12")))
    (should (= (plist-get (keydrill-move-record store "a") :hits) 1))
    (should (= (plist-get (keydrill-move-record store "a") :last-latency) 0))))

(ert-deftest keydrill-touch-last-seen-does-not-add-sample ()
  "A requeued completion updates the date only."
  (let* ((base (keydrill-mark-drilling (keydrill-empty-store) "a"))
         (store (keydrill-record-recall base "a" t 300 "2026-08-11"))
         (touched (keydrill-touch-last-seen store "a" "2026-08-12")))
    (should (= (plist-get (keydrill-move-record touched "a") :seen) 1))
    (should (equal (plist-get (keydrill-move-record touched "a") :last-seen)
                   "2026-08-12"))))

(ert-deftest keydrill-median-matches-upper-middle ()
  "Empty is 0; even length uses the upper middle after sort."
  (should (= (keydrill-median nil) 0))
  (should (= (keydrill-median '(5)) 5))
  (should (= (keydrill-median '(1 2 3)) 2))
  (should (= (keydrill-median '(1 2 3 4)) 3)))

(ert-deftest keydrill-accuracy-rounds-half-up ()
  "Accuracy is a rounded percent; zero attempted is 0."
  (should (= (keydrill-accuracy 0 0) 0))
  (should (= (keydrill-accuracy 3 3) 100))
  (should (= (keydrill-accuracy 2 3) 67)))

(ert-deftest keydrill-session-pass-criteria ()
  "A pass needs 95% accuracy, median in (0, 800), and full coverage."
  (should (keydrill-session-pass-p 95 400 85 85))
  (should-not (keydrill-session-pass-p 94 400 85 85))
  (should-not (keydrill-session-pass-p 95 0 85 85))
  (should-not (keydrill-session-pass-p 95 800 85 85))
  (should-not (keydrill-session-pass-p 95 400 5 85)))

(ert-deftest keydrill-apply-session-records-pass-days ()
  "Pass days accumulate once per local day; two days graduate."
  (let* ((empty (keydrill-empty-store))
         (s1 (keydrill-apply-session empty "emacs" 96 350 85 85
                                     "2026-08-11"))
         (s2 (keydrill-apply-session s1 "emacs" 96 350 85 85
                                     "2026-08-11"))
         (s3 (keydrill-apply-session s2 "emacs" 97 300 85 85
                                     "2026-08-12")))
    (should (= (plist-get (keydrill-deck-record s1 "emacs") :sessions) 1))
    (should (equal (plist-get (keydrill-deck-record s2 "emacs") :pass-dates)
                   '("2026-08-11")))
    (should-not (keydrill-deck-graduated-p s2 "emacs"))
    (should (equal (plist-get (keydrill-deck-record s3 "emacs") :pass-dates)
                   '("2026-08-11" "2026-08-12")))
    (should (keydrill-deck-graduated-p s3 "emacs"))
    (should (= (plist-get (plist-get (keydrill-deck-record s3 "emacs") :best)
                          :acc)
               97))
    (should (= (plist-get (plist-get (keydrill-deck-record s3 "emacs") :best)
                          :med)
               300))))

(ert-deftest keydrill-apply-session-ignores-uncovered-pass-pace ()
  "A high-accuracy intro-sized session does not count as a pass day."
  (let ((store (keydrill-apply-session (keydrill-empty-store) "emacs"
                                       100 200 5 85 "2026-08-12")))
    (should (null (plist-get (keydrill-deck-record store "emacs")
                             :pass-dates)))))

(ert-deftest keydrill-today-string-is-local-iso-date ()
  "Today is a YYYY-MM-DD string in local time."
  (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'"
                          (keydrill-today-string))))

(ert-deftest keydrill-session-plan-level-gate ()
  "A level with new moves is open, but higher levels are not."
  (let ((deck (list (keydrill-test--move "a" 1)
                    (keydrill-test--move "b" 1)
                    (keydrill-test--move "c" 2))))
    (should (equal (plist-get (keydrill-session-plan
                               deck (keydrill-empty-store) #'identity)
                              :open-levels)
                   '(1)))
    (let ((store (keydrill-mark-learning
                  (keydrill-mark-learning (keydrill-empty-store) "a")
                  "b")))
      (should (equal (plist-get (keydrill-session-plan deck store #'identity)
                                :open-levels)
                     '(1 2))))))

(ert-deftest keydrill-session-plan-intro-cap-and-learning-first ()
  "Intros cap at 5 and put learning ahead of new within a level."
  (let* ((deck (list (keydrill-test--move "n1" 1)
                     (keydrill-test--move "n2" 1)
                     (keydrill-test--move "n3" 1)
                     (keydrill-test--move "n4" 1)
                     (keydrill-test--move "n5" 1)
                     (keydrill-test--move "n6" 1)
                     (keydrill-test--move "learn" 1)))
         (store (keydrill-mark-learning (keydrill-empty-store) "learn"))
         (plan (keydrill-session-plan deck store #'identity))
         (ids (mapcar (lambda (m) (plist-get m :id))
                      (plist-get plan :intros))))
    (should (= (length ids) 5))
    (should (equal (car ids) "learn"))
    (should-not (member "n6" ids))))

(ert-deftest keydrill-move-phase-unexpected-state-is-new ()
  "An unknown stored :state is treated as new, not learned."
  (let ((store (keydrill--put-move
                (keydrill-empty-store) "a"
                (list :seen 5 :hits 5 :last-latency 100
                      :last-seen "2026-08-12" :state 'frozen))))
    (should (eq (keydrill-move-phase store "a") 'new))
    (should (eq (keydrill-move-state store "a") 'new))))

(ert-deftest keydrill-session-plan-no-monetization-lock ()
  "Level 2 intros are available once every level 1 move is introduced."
  (let* ((deck (list (keydrill-test--move "a" 1)
                     (keydrill-test--move "b" 2)))
         (store (keydrill-mark-drilling (keydrill-empty-store) "a"))
         (plan (keydrill-session-plan deck store #'identity))
         (intro-ids (mapcar (lambda (m) (plist-get m :id))
                            (plist-get plan :intros))))
    (should (equal (plist-get plan :open-levels) '(1 2)))
    (should (member "b" intro-ids))))

(ert-deftest keydrill-session-plan-recall-is-drilling-only ()
  "Recall is drilling moves in open levels, not this session's intros."
  (let* ((deck (list (keydrill-test--move "new" 1)
                     (keydrill-test--move "drill" 1)))
         (store (keydrill-mark-drilling (keydrill-empty-store) "drill"))
         (plan (keydrill-session-plan deck store #'identity))
         (recall-ids (mapcar (lambda (m) (plist-get m :id))
                             (plist-get plan :recall))))
    (should (equal recall-ids '("drill")))
    (should (member "new" (mapcar (lambda (m) (plist-get m :id))
                                  (plist-get plan :intros))))))

(provide 'keydrill-engine-test)
;;; keydrill-engine-test.el ends here
