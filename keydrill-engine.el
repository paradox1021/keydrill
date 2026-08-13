;;; keydrill-engine.el --- Lifecycle, session planner, and scoring  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  keydrill contributors

;; Author: keydrill contributors
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

;; Pure functions over the progress store: move lifecycle (new,
;; learning, drilling, learned), session planning, and scoring.
;; No I/O and no UI live here.
;;
;; Latency is a number the caller supplies.  Capture it when the
;; prompt renders, not when the session starts.  This module only
;; records the value it is given.

;;; Code:

(require 'cl-lib)

;; User-facing default lives in `keydrill.el' as a defcustom.  Bare
;; defvar so compiling this file after the defcustom does not warn.
(defvar keydrill-max-new-per-session)

(defun keydrill--max-new-per-session ()
  "Return `keydrill-max-new-per-session', or 5 if it is unbound."
  (if (boundp 'keydrill-max-new-per-session)
      keydrill-max-new-per-session
    5))

(defconst keydrill-learned-min-samples 3
  "Minimum recall samples before a drilling move can display as learned.")

(defconst keydrill-learned-min-hit-rate 0.9
  "Minimum first-try hit rate for the derived learned state.")

(defconst keydrill-learned-max-latency 800
  "Last-latency must be strictly below this many milliseconds to be learned.")

(defconst keydrill-pass-min-accuracy 95
  "Minimum first-try accuracy percent for a graduation-pace session.")

(defconst keydrill-pass-max-median 800
  "Median first-try latency must be strictly below this many milliseconds.")

(defconst keydrill-latency-interrupt-ms 10000
  "Latencies at or above this many milliseconds are interruptions, not samples.")

;;; Store shape

(defun keydrill-empty-store ()
  "Return a fresh empty progress store.
The store is a plist with :moves and :decks alists and :observer
counts.  Observer may be nil."
  (list :moves nil :decks nil :observer nil))

(defun keydrill--alist-put (alist key value)
  "Return a new alist with KEY associated to VALUE.
ALIST is not mutated."
  (cons (cons key value)
        (cl-remove key alist :key #'car :test #'equal)))

(defun keydrill--copy-store (store)
  "Return a shallow copy of STORE with copied alists."
  (list :moves (copy-alist (plist-get store :moves))
        :decks (copy-alist (plist-get store :decks))
        :observer (copy-alist (plist-get store :observer))))

(defun keydrill-move-record (store id)
  "Return the move plist for ID in STORE, or nil if unseen."
  (cdr (assoc id (plist-get store :moves))))

(defun keydrill-deck-record (store deck-id)
  "Return the deck plist for DECK-ID in STORE, or nil."
  (cdr (assoc deck-id (plist-get store :decks))))

(defun keydrill--put-move (store id record)
  "Return STORE with ID mapped to RECORD.  Do not mutate STORE."
  (let ((new (keydrill--copy-store store)))
    (setq new (plist-put new :moves
                         (keydrill--alist-put (plist-get new :moves)
                                              id record)))
    new))

(defun keydrill--put-deck (store deck-id record)
  "Return STORE with DECK-ID mapped to RECORD.  Do not mutate STORE."
  (let ((new (keydrill--copy-store store)))
    (setq new (plist-put new :decks
                         (keydrill--alist-put (plist-get new :decks)
                                              deck-id record)))
    new))

(defun keydrill--blank-move ()
  "Return a zeroed move plist with no lifecycle state yet."
  (list :seen 0 :hits 0 :last-latency 0 :last-seen "" :state nil))

;;; Dates and rounding

(defun keydrill-today-string (&optional time)
  "Return the local calendar date of TIME as YYYY-MM-DD.
TIME defaults to now.  Uses local time, not UTC, so an evening
session is one day even if UTC has already rolled over."
  (format-time-string "%Y-%m-%d" time))

(defun keydrill--round-nonneg (n)
  "Round non-negative N half-up toward +inf.
Matches the session engine's integer percent and median rounding."
  (floor (+ (float n) 0.5)))

(defun keydrill-median (numbers)
  "Return the median of NUMBERS as a rounded integer.
Empty NUMBERS yields 0.  For a non-empty list, sort ascending and
take the element at index floor of length/2, then round.  Even-length
lists therefore use the upper middle value, not the mean of the two
middles."
  (if (null numbers)
      0
    (let* ((sorted (sort (copy-sequence numbers) #'<))
           (mid (nth (/ (length sorted) 2) sorted)))
      (keydrill--round-nonneg mid))))

(defun keydrill-accuracy (first-try attempted)
  "Return first-try percent from FIRST-TRY hits over ATTEMPTED recalls.
Zero ATTEMPTED yields 0.  The result is a rounded integer 0-100."
  (if (zerop attempted)
      0
    (keydrill--round-nonneg (* 100.0 (/ (float first-try) attempted)))))

;;; Lifecycle

(defun keydrill-move-phase (store id)
  "Return the stored phase of move ID in STORE.
This is `new', `learning', or `drilling'.  `learned' is never stored;
use `keydrill-move-state' for the derived display state.

A missing record is `new'.  A record with no :state and a positive
:seen count is treated as `drilling' (pre-state migration).  Any
other unexpected :state is treated as `new'."
  (let ((rec (keydrill-move-record store id)))
    (if (null rec)
        'new
      (let ((st (plist-get rec :state))
            (seen (or (plist-get rec :seen) 0)))
        (cond
         ((eq st 'learning) 'learning)
         ((eq st 'drilling) 'drilling)
         ((null st)
          (if (> seen 0) 'drilling 'new))
         (t 'new))))))

(defun keydrill-move-learned-p (record)
  "Return non-nil if RECORD meets the derived learned thresholds.
RECORD is a move plist.  Learned requires a drilling phase (stored
`drilling', or a missing :state with a positive :seen count), at
least 3 recall samples, first-try rate at least 0.9, and last
latency greater than 0 and strictly less than 800 milliseconds.
800 ms is not learned.  Two samples are not learned."
  (let* ((st (plist-get record :state))
         (seen (or (plist-get record :seen) 0))
         (hits (or (plist-get record :hits) 0))
         (lat (or (plist-get record :last-latency) 0))
         (drilling (or (eq st 'drilling)
                       (and (null st) (> seen 0)))))
    (and drilling
         (>= seen keydrill-learned-min-samples)
         (>= (/ (float hits) seen) keydrill-learned-min-hit-rate)
         (> lat 0)
         (< lat keydrill-learned-max-latency))))

(defun keydrill-move-state (store id)
  "Return the derived display state of move ID in STORE.
One of `new', `learning', `drilling', or `learned'.  `learned' is
computed from samples; it is never written to the store."
  (let ((phase (keydrill-move-phase store id)))
    (cond
     ((eq phase 'new) 'new)
     ((eq phase 'learning) 'learning)
     ((eq phase 'drilling)
      (let ((rec (keydrill-move-record store id)))
        (if (and rec (keydrill-move-learned-p rec))
            'learned
          'drilling)))
     (t 'new))))

(defun keydrill-mark-learning (store id)
  "Return STORE with ID marked `learning' if it was `new'.
Call this when an intro card is shown.  Already-introduced moves
are left unchanged.  STORE is not mutated."
  (if (not (eq (keydrill-move-phase store id) 'new))
      store
    (let ((rec (or (copy-sequence (keydrill-move-record store id))
                   (keydrill--blank-move))))
      (setq rec (plist-put rec :state 'learning))
      (keydrill--put-move store id rec))))

(defun keydrill-mark-drilling (store id)
  "Return STORE with ID locked in as `drilling'.
Call this when an intro card is answered correctly.  Intro hits
must not also call `keydrill-record-recall'; recall stats stay
recall-only.  STORE is not mutated."
  (let ((rec (or (copy-sequence (keydrill-move-record store id))
                 (keydrill--blank-move))))
    (setq rec (plist-put rec :state 'drilling))
    (keydrill--put-move store id rec)))

(defun keydrill-record-recall (store id first-try-hit latency &optional day)
  "Return STORE with one recall sample for ID.
FIRST-TRY-HIT non-nil counts a first-try success.  LATENCY is
milliseconds from prompt render; values at or above 10000 are
ignored as interruptions and do not update last latency.  DAY is a
local YYYY-MM-DD string and defaults to `keydrill-today-string'.

A miss still increments :seen and updates :last-seen, but does not
increment :hits or change :last-latency.  This does not change
learning/drilling phase.  STORE is not mutated."
  (let* ((day (or day (keydrill-today-string)))
         (old (or (keydrill-move-record store id)
                  (keydrill--blank-move)))
         (rec (copy-sequence old))
         (seen (1+ (or (plist-get rec :seen) 0)))
         (hits (+ (or (plist-get rec :hits) 0)
                  (if first-try-hit 1 0)))
         (lat (or (plist-get rec :last-latency) 0)))
    (when (and first-try-hit latency (< latency keydrill-latency-interrupt-ms))
      (setq lat (keydrill--round-nonneg latency)))
    (setq rec (plist-put rec :seen seen))
    (setq rec (plist-put rec :hits hits))
    (setq rec (plist-put rec :last-latency lat))
    (setq rec (plist-put rec :last-seen day))
    (keydrill--put-move store id rec)))

(defun keydrill-touch-last-seen (store id &optional day)
  "Return STORE with ID's :last-seen set to DAY and no new sample.
Used for a corrected or requeued completion.  DAY defaults to
`keydrill-today-string'.  If ID has no record, STORE is unchanged.
STORE is not mutated."
  (let ((old (keydrill-move-record store id)))
    (if (null old)
        store
      (let ((rec (copy-sequence old))
            (day (or day (keydrill-today-string))))
        (setq rec (plist-put rec :last-seen day))
        (keydrill--put-move store id rec)))))

;;; Planner

(defun keydrill-shuffle (items)
  "Return a new list with ITEMS in random order.
Does not mutate ITEMS.  Session tests should pass an explicit
shuffle function to `keydrill-session-plan' instead of this."
  (let* ((vec (vconcat items))
         (i (length vec)))
    (while (> i 1)
      (setq i (1- i))
      (let* ((j (random (1+ i)))
             (tmp (aref vec i)))
        (aset vec i (aref vec j))
        (aset vec j tmp)))
    (append vec nil)))

(defun keydrill--apply-shuffle (items shuffle-fn)
  "Return ITEMS reordered by SHUFFLE-FN, or `keydrill-shuffle'."
  (funcall (or shuffle-fn #'keydrill-shuffle) items))

(defun keydrill--deck-levels (deck)
  "Return sorted unique :level numbers from DECK."
  (let ((levels nil))
    (dolist (m deck)
      (let ((lvl (plist-get m :level)))
        (unless (member lvl levels)
          (push lvl levels))))
    (sort levels #'<)))

(defun keydrill--open-levels (deck store)
  "Return open level numbers for DECK given STORE.
The lowest present level is always open.  Each next level opens
only when every move of the previous present level is no longer
`new'.  Opening stops at the first level that still has a `new'
move.  There is no paywall lock; every move is available."
  (let ((open nil)
        (stop nil))
    (dolist (lvl (keydrill--deck-levels deck))
      (unless stop
        (push lvl open)
        (let ((all-introduced t))
          (dolist (m deck)
            (when (and (equal (plist-get m :level) lvl)
                       (eq (keydrill-move-phase store (plist-get m :id))
                           'new))
              (setq all-introduced nil)))
          (unless all-introduced
            (setq stop t)))))
    (nreverse open)))

(defun keydrill--pick-intros (intro-pool store shuffle-fn max-new)
  "Return intro cards from INTRO-POOL, capped at MAX-NEW.
STORE supplies phase.  Order is level ascending, then learning
before new, with SHUFFLE-FN applied inside each bucket."
  (let ((ordered nil))
    (dolist (lvl (keydrill--deck-levels intro-pool))
      (let ((learning nil)
            (neu nil))
        (dolist (m intro-pool)
          (when (equal (plist-get m :level) lvl)
            (if (eq (keydrill-move-phase store (plist-get m :id)) 'learning)
                (push m learning)
              (push m neu))))
        (setq learning (keydrill--apply-shuffle (nreverse learning)
                                                shuffle-fn))
        (setq neu (keydrill--apply-shuffle (nreverse neu) shuffle-fn))
        (setq ordered (append ordered learning neu))))
    (if (> (length ordered) max-new)
        (cl-subseq ordered 0 max-new)
      ordered)))

(defun keydrill-session-plan (deck store &optional shuffle-fn max-new)
  "Plan a session from DECK and STORE.
DECK is a list of move plists with at least :id and :level.  STORE
is a progress plist from `keydrill-empty-store'.

Return a plist:
:intros       moves to teach this session, capped
:recall       drilling moves in open levels, shuffled
:open-levels  level numbers currently in rotation
:eligible     all moves whose level is open

A level opens only when every lower present level has been
introduced (phase is not `new').  Intros are every eligible move
that is not yet drilling, sorted level then learning-before-new,
then capped at MAX-NEW (default `keydrill-max-new-per-session').

SHUFFLE-FN, if given, is called with a list and must return a list
of the same elements.  Tests pass `identity' or a fixed
permutation.  The default is `keydrill-shuffle'.

There is no locked or monetized subset: every move is available
once its level is open."
  (let* ((max-new (or max-new (keydrill--max-new-per-session)))
         (open (keydrill--open-levels deck store))
         (eligible (cl-remove-if-not
                    (lambda (m) (member (plist-get m :level) open))
                    deck))
         (intro-pool (cl-remove-if
                      (lambda (m)
                        (eq (keydrill-move-phase store (plist-get m :id))
                            'drilling))
                      eligible))
         (intros (keydrill--pick-intros intro-pool store shuffle-fn max-new))
         (recall-src (cl-remove-if-not
                      (lambda (m)
                        (eq (keydrill-move-phase store (plist-get m :id))
                            'drilling))
                      eligible))
         (recall (keydrill--apply-shuffle recall-src shuffle-fn)))
    (list :intros intros
          :recall recall
          :open-levels open
          :eligible eligible)))

;;; Pass / graduation

(defun keydrill-session-pass-p (accuracy median attempted deck-size)
  "Return non-nil if a deck session meets graduation-pace criteria.
ACCURACY is first-try percent (0-100).  MEDIAN is median first-try
latency in milliseconds.  ATTEMPTED is distinct first recall
presentations, including unresolved misses.  DECK-SIZE is the
number of moves in the full deck.

Pass requires accuracy at least 95, median greater than 0 and
strictly less than 800, and ATTEMPTED at least DECK-SIZE so a
short intro session cannot pass a barely-started deck.  Intro
cards never count toward accuracy or median."
  (and (>= accuracy keydrill-pass-min-accuracy)
       (> median 0)
       (< median keydrill-pass-max-median)
       (>= attempted deck-size)))

(defun keydrill-deck-graduated-p (store deck-id)
  "Return non-nil if DECK-ID has two distinct pass dates in STORE.
Graduation is two separate local days held at graduation pace.
There is no license or tier check."
  (let* ((rec (keydrill-deck-record store deck-id))
         (dates (and rec (plist-get rec :pass-dates))))
    (and dates (>= (length dates) 2))))

(defun keydrill--blank-deck ()
  "Return a zeroed per-deck record."
  (list :sessions 0
        :best (list :acc 0 :med 0)
        :pass-dates nil
        :celebrated nil))

(defun keydrill-apply-session (store deck-id accuracy median attempted
                                     deck-size &optional day)
  "Return STORE with DECK-ID updated from a finished session.
ACCURACY, MEDIAN, ATTEMPTED, and DECK-SIZE are as in
`keydrill-session-pass-p'.  DAY is a local YYYY-MM-DD string and
defaults to `keydrill-today-string'.

Increments :sessions, maybe updates :best, and appends DAY to
:pass-dates when the session passes and DAY is not already listed.
Does not mutate STORE."
  (let* ((day (or day (keydrill-today-string)))
         (pass (keydrill-session-pass-p accuracy median attempted deck-size))
         (old (or (keydrill-deck-record store deck-id)
                  (keydrill--blank-deck)))
         (rec (copy-sequence old))
         (best (copy-sequence (or (plist-get rec :best)
                                  (list :acc 0 :med 0))))
         (best-acc (or (plist-get best :acc) 0))
         (best-med (or (plist-get best :med) 0))
         (dates (copy-sequence (plist-get rec :pass-dates))))
    (setq rec (plist-put rec :sessions (1+ (or (plist-get rec :sessions) 0))))
    (when (or (> accuracy best-acc)
              (and (= accuracy best-acc)
                   median
                   (not (zerop median))
                   (or (zerop best-med) (< median best-med))))
      (setq best (list :acc accuracy :med median)))
    (setq rec (plist-put rec :best best))
    (when (and pass (not (member day dates)))
      (setq dates (append dates (list day))))
    (setq rec (plist-put rec :pass-dates dates))
    (keydrill--put-deck store deck-id rec)))

(provide 'keydrill-engine)
;;; keydrill-engine.el ends here
