;;; keydrill-journal.el --- Append-only answer journal and cold benchmark  -*- lexical-binding: t; -*-

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

;; The store keeps aggregates; curves need raw answers.  This module
;; appends one readable sexp per event to `keydrill-journal-file' so
;; per-binding latency and accuracy can be reconstructed over time.
;;
;; Record shapes, one per line, written with `prin1':
;;
;;   (:v 1 :kind begin  :t FLOAT :session ID :mode MODE :deck DECK
;;    :size N :emacs VERSION :ws WINDOW-SYSTEM)
;;   (:v 1 :kind answer :t FLOAT :session ID :deck DECK :id MOVE-ID
;;    :card CARD :status STATUS :latency MS :expected KEY)
;;   (:v 1 :kind end    :t FLOAT :session ID :complete BOOL)
;;
;; MODE is `drill' or `benchmark'.  CARD is `intro', `recall', or
;; `benchmark'.  STATUS is `hit', `miss', `timeout', or `quit'.
;;
;; `M-x keydrill-benchmark' is the before/after instrument: one cold
;; recall pass over the whole deck, live-resolved, no answers shown,
;; no requeue, and no writes to the progress store — a measurement,
;; not a lesson.  Run it before habitual drilling begins (a baseline
;; is unrepeatable once practice starts) and weekly after.
;;
;; Same privacy promise as the store: local file, no network code.
;; `M-x keydrill-journal-purge' deletes it.

;;; Code:

(require 'keydrill-engine)
(require 'keydrill-capture)
(require 'seq)

;; `keydrill-ui' requires this file, not the other way around; the
;; interactive benchmark reaches ui and deck symbols at runtime.
(declare-function keydrill-live-resolve-deck "keydrill-live")
(declare-function keydrill-mode "keydrill-ui")
(declare-function keydrill--render-text "keydrill-ui")
(defvar keydrill-buffer-name)
(defvar keydrill--window-config)
(defvar keydrill-deck-emacs)

;; User-facing default lives in `keydrill.el' as a defcustom.
(defvar keydrill-journal-file nil
  "Path of the append-only answer journal.
Defined as a defcustom in keydrill.el.  nil disables journaling.")

(defvar keydrill-journal-inhibit noninteractive
  "Non-nil suppresses journal writes from session loops.
Defaults to the value of `noninteractive' at load time so batch
test runs never touch a real journal.  Tests that exercise the
journal bind this to nil around a temp `keydrill-journal-file'.")

(defvar keydrill-journal--session-id nil
  "Session id stamped onto answer records, bound by session starters.")

;;; Writing

(defun keydrill-journal-enabled-p ()
  "Return non-nil when journal writes should happen."
  (and keydrill-journal-file (not keydrill-journal-inhibit)))

(defun keydrill-journal-append (record)
  "Append RECORD to `keydrill-journal-file' as one printed line.
No-op unless `keydrill-journal-enabled-p'.  Return RECORD."
  (when (keydrill-journal-enabled-p)
    (let ((file keydrill-journal-file)
          (print-length nil)
          (print-level nil))
      (when (file-name-directory file)
        (make-directory (file-name-directory file) t))
      (with-temp-buffer
        (prin1 record (current-buffer))
        (terpri (current-buffer))
        (let ((write-region-inhibit-fsync t)
              (inhibit-message t))
          (write-region (point-min) (point-max) file t 'quiet)))))
  record)

(defun keydrill-journal--stamp (kind &rest plist)
  "Return a journal record of KIND with PLIST fields appended."
  (append (list :v 1 :kind kind :t (float-time)
                :session keydrill-journal--session-id)
          plist))

(defun keydrill-journal-new-session-id (mode)
  "Return a fresh session id string for MODE (`drill' or `benchmark')."
  (format "%s-%s" mode (format-time-string "%Y%m%d-%H%M%S")))

(defun keydrill-journal-log-begin (mode deck-id size)
  "Append a begin record for MODE on DECK-ID with SIZE moves."
  (keydrill-journal-append
   (keydrill-journal--stamp 'begin
                            :mode mode :deck deck-id :size size
                            :emacs emacs-version
                            :ws (or window-system 'tty))))

(defun keydrill-journal-log-end (complete)
  "Append an end record.  COMPLETE non-nil means the pass finished."
  (keydrill-journal-append
   (keydrill-journal--stamp 'end :complete (and complete t))))

(defun keydrill-journal-log-answer (deck-id move card result)
  "Append an answer record.
DECK-ID identifies the deck.  MOVE is the move plist.  CARD is
`intro', `recall', or `benchmark'.  RESULT is a plist from
`keydrill-read-answer'."
  (keydrill-journal-append
   (keydrill-journal--stamp 'answer
                            :deck deck-id
                            :id (plist-get move :id)
                            :card card
                            :status (plist-get result :status)
                            :latency (plist-get result :latency)
                            :expected (or (plist-get move :expected-key)
                                          (plist-get move :key)))))

;;; Reading

(defun keydrill-journal-records (&optional file)
  "Return all records in FILE, or `keydrill-journal-file', oldest first.
Return nil when the file does not exist."
  (let ((file (or file keydrill-journal-file)))
    (when (and file (file-exists-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let (out)
          (while (not (eobp))
            (condition-case nil
                (push (read (current-buffer)) out)
              (end-of-file (goto-char (point-max)))))
          (nreverse out))))))

(defun keydrill-journal-purge (&optional file)
  "Delete FILE, or `keydrill-journal-file', after yes-or-no confirmation.
Return non-nil when a file was deleted."
  (interactive)
  (let ((file (or file keydrill-journal-file)))
    (if (not (and file (file-exists-p file)))
        (progn (message "No keydrill journal to delete") nil)
      (when (yes-or-no-p (format "Delete %s? " file))
        (delete-file file)
        (message "Deleted %s" file)
        t))))

;;; Benchmark

(defun keydrill-benchmark--summary (results size)
  "Return the benchmark summary string for RESULTS out of SIZE moves.
RESULTS is a list of (MOVE . RESULT) pairs, oldest first."
  (let* ((answered (length results))
         (hits (seq-count (lambda (r) (eq (plist-get (cdr r) :status) 'hit))
                          results))
         (lats (delq nil
                     (mapcar (lambda (r)
                               (and (eq (plist-get (cdr r) :status) 'hit)
                                    (plist-get (cdr r) :latency)))
                             results)))
         (med (keydrill-median lats))
         (slow (seq-take
                (sort (copy-sequence results)
                      (lambda (a b)
                        (> (or (plist-get (cdr a) :latency) 0)
                           (or (plist-get (cdr b) :latency) 0))))
                5)))
    (concat
     (format "Benchmark - %d / %d answered\n\n" answered size)
     (format "Cold hits: %d (%d%%)\n"
             hits (if (zerop answered) 0 (/ (* 100 hits) answered)))
     (if (> med 0)
         (format "Median hit latency: %d ms\n" med)
       "Median hit latency: no hits under the interruption cap\n")
     "\nSlowest five:\n"
     (mapconcat (lambda (r)
                  (format "  %-24s %6s ms  %s"
                          (plist-get (car r) :id)
                          (or (plist-get (cdr r) :latency) "-")
                          (plist-get (cdr r) :status)))
                slow "\n")
     "\n\nThis was a measurement, not a lesson: answers were never shown.\n"
     "Results are appended to the journal.  q quits.\n")))

(defun keydrill-benchmark--render (move done size)
  "Render the benchmark card for MOVE, number DONE of SIZE, in this buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "keydrill benchmark" 'face 'keydrill-muted))
    (insert "\n\n")
    (insert (propertize (format "%d / %d\n\n" done size) 'face 'keydrill-muted))
    (insert (propertize (or (plist-get move :prompt) "") 'face 'keydrill-prompt))
    (insert "\n\n")
    (insert (propertize
             "Cold pass: no answers are shown.  q quits."
             'face 'keydrill-muted))
    (goto-char (point-min))))

(defun keydrill-benchmark-run (moves deck-id &optional render-fn)
  "Run a cold benchmark over MOVES for DECK-ID.
Call `keydrill-read-answer' once per move; never show answers,
never requeue, never touch the progress store.  RENDER-FN, if
non-nil, is called with (MOVE DONE SIZE) before each read.

Journal a begin record, one answer record per move, and an end
record whose :complete reflects whether every move was answered.
Return a plist: :results (list of (MOVE . RESULT), oldest first),
:complete, and :quit."
  (let* ((size (length moves))
         (keydrill-journal--session-id
          (keydrill-journal-new-session-id 'benchmark))
         (done 0)
         (quit nil)
         results)
    (keydrill-journal-log-begin 'benchmark deck-id size)
    (keydrill-capture-reset)
    (catch 'keydrill-benchmark-over
      (dolist (move moves)
        (when render-fn
          (funcall render-fn move (1+ done) size))
        (let ((res (keydrill-read-answer
                    (or (plist-get move :expected-key)
                        (plist-get move :key)))))
          (if (eq (plist-get res :status) 'quit)
              (progn (setq quit t)
                     (throw 'keydrill-benchmark-over nil))
            (keydrill-journal-log-answer deck-id move 'benchmark res)
            (push (cons move res) results)
            (setq done (1+ done))))))
    (keydrill-journal-log-end (= done size))
    (list :results (nreverse results)
          :complete (= done size)
          :quit quit)))

;;;###autoload
(defun keydrill-benchmark ()
  "Run a cold benchmark over the full Emacs deck.
One recall pass, live-resolved against the buffer this command is
called from, in deck order.  No answers are shown, misses are not
requeued, and the progress store is untouched.  Every answer is
appended to `keydrill-journal-file'.

Run this once before you start drilling — that cold baseline can
never be taken again — and then weekly under the same conditions."
  (interactive)
  (require 'keydrill-live)
  (require 'keydrill-ui)
  (require 'keydrill-deck-emacs)
  (let* ((moves (keydrill-live-resolve-deck keydrill-deck-emacs
                                            (current-buffer)))
         (buf (get-buffer-create keydrill-buffer-name)))
    (unless moves
      (user-error "Nothing to benchmark"))
    (unless keydrill--window-config
      (setq keydrill--window-config (current-window-configuration)))
    (switch-to-buffer buf)
    (keydrill-mode)
    (let* ((outcome
            (keydrill-benchmark-run
             moves "emacs"
             (lambda (move done size)
               (keydrill-benchmark--render move done size)
               (redisplay t))))
           (results (plist-get outcome :results)))
      (keydrill--render-text
       (keydrill-benchmark--summary results (length moves)))
      (message (if (plist-get outcome :complete)
                   "Benchmark complete. Journaled."
                 "Benchmark stopped early. Answered cards were journaled."))
      outcome)))

(provide 'keydrill-journal)
;;; keydrill-journal.el ends here
