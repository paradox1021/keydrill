;;; keydrill-capture.el --- Read and score key sequences  -*- lexical-binding: t; -*-

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

;; Event loop that builds a key vector with `read-event' and compares
;; it to the expected sequence as canonical `key-description' strings.
;; `read-key-sequence' is not used: it stops on undefined prefixes and
;; swallows mistakes.
;;
;; `C-g' and `C-x C-c' are answers, not editor commands, while the
;; loop is active.  Events are never executed.
;;
;; Latency: `keydrill-read-answer' records `(float-time)' when the
;; read loop starts, unless the caller passes START-TIME (also a
;; `float-time' value, typically from prompt render).  The returned
;; :latency is milliseconds from that instant.  The engine records
;; whatever number it is given.
;;
;; Manual test matrix (human, not CI): GUI Emacs and `emacs -nw' in a
;; real terminal, each of C-g, C-x C-c, C-/, C-SPC, M-<, C-M-\.
;; `M-<' and `C-M-\\' need no extra alias-table rows: the read loop
;; coalesces Escape plus a follower into Meta, and `key-description'
;; already folds the two-event ESC-prefixed vector.

;;; Code:

;; User-facing default lives in `keydrill.el' as a defcustom.  Bare
;; defvar so compiling this file after the defcustom does not warn.
(defvar keydrill-sequence-timeout 1.5
  "Seconds to wait for the next key in a multi-key sequence.
A timeout is a miss.  Defined as a defcustom in keydrill.el.")

(defconst keydrill-quit-hatch-seconds 1.0
  "Window in which a second `C-g' ends the session.")

(defconst keydrill-esc-coalesce-seconds 0.1
  "Seconds to wait after Escape for a following key to treat as Meta.")

(defvar keydrill--last-cg-time nil
  "Float-time of the last non-hit `C-g', or nil.
Persists across `keydrill-read-answer' calls so a miss then a
retry can still form a double-`C-g' quit.")

(defun keydrill--sequence-timeout ()
  "Return `keydrill-sequence-timeout', or 1.5 if it is unbound."
  (if (boundp 'keydrill-sequence-timeout)
      keydrill-sequence-timeout
    1.5))

(defun keydrill-capture-reset ()
  "Clear the double-`C-g' hatch at session start."
  (setq keydrill--last-cg-time nil))

(defun keydrill--alias-key (key)
  "Return the canonical spelling of one KEY description atom.
ESC-prefixed Meta chords (`M-x', `M-<', `C-M-\\\\') are not listed
here.  `key-description' already folds those two-event vectors,
and `keydrill--coalesce-escape' folds them at read time."
  (cond
   ((member key '("C-_" "C-/")) "C-/")
   ((member key '("C-@" "C-SPC")) "C-SPC")
   ((member key '("C-i" "TAB" "<tab>")) "TAB")
   (t key)))

(defun keydrill--alias-description (desc)
  "Fold terminal/GUI aliases in `key-description' string DESC."
  (mapconcat #'keydrill--alias-key (split-string desc) " "))

(defun keydrill-normalize-keys (keys)
  "Return a canonical `key-description' string for KEYS.
KEYS may be a single event, a vector or list of events, or a kbd
or `key-description' string.  Terminal and GUI spellings of the
same binding are folded together: `C-/' and `C-_', `C-SPC' and
`C-@', `TAB' and `C-i' and `<tab>'.  ESC-prefixed Meta chords
such as `ESC x' / `M-x', `ESC <' / `M-<', and `ESC C-\\\\' /
`C-M-\\\\' already share a `key-description'; the read loop also
coalesces an Escape follower into Meta."
  (keydrill--alias-description
   (cond
    ((stringp keys)
     (key-description (kbd keys)))
    ((vectorp keys)
     (key-description keys))
    ((or (integerp keys) (symbolp keys))
     (key-description (vector keys)))
    ((and (listp keys) (null (cdr (last keys))))
     (key-description (vconcat keys)))
    (t
     (key-description (vector keys))))))

(defun keydrill--escape-event-p (event)
  "Return non-nil if EVENT is a raw Escape / ESC prefix."
  (or (eq event ?\e)
      (eq event 'escape)
      (and (integerp event) (= event 27))))

(defun keydrill--c-g-event-p (event)
  "Return non-nil if EVENT is a `C-g' character."
  (eq event ?\C-g))

(defun keydrill--auto-repeat-p (event)
  "Return non-nil if EVENT is an OS auto-repeat and must not score.
A cons whose car is `repeat' is the test stand-in for the web
trainer's e.repeat guard.  Emacs does not expose that flag on
ordinary character events."
  (eq (car-safe event) 'repeat))

(defun keydrill--modifier-only-p (event)
  "Return non-nil if EVENT is a modifier key with no character.
Bare Shift, Control, Meta, Alt, Super, or Hyper must not score."
  (and (not (consp event))
       (or (memq event '(shift control meta alt super hyper
                         lshift rshift lcontrol rcontrol))
           (memq (event-basic-type event)
                 '(shift control meta alt super hyper))
           (and (symbolp event)
                (string-match-p
                 "\\`\\(shift\\|control\\|ctrl\\|meta\\|alt\\|super\\|hyper\\)"
                 (symbol-name event))))))

(defun keydrill--apply-meta (event)
  "Return EVENT with the Meta modifier added, or nil if impossible."
  (let ((basic (event-basic-type event)))
    (when basic
      (event-convert-list
       (append '(meta)
               (delq 'meta (copy-sequence (or (event-modifiers event) '())))
               (list basic))))))

(defun keydrill--read-raw (seconds)
  "Read one event, waiting at most SECONDS if that is a number.
The first key of an answer passes SECONDS as nil and waits.  Later
keys pass `keydrill-sequence-timeout'.  `read-event' implements
the wait; `with-timeout' is a second bound if a platform ignores
the SECONDS argument.  Return nil on timeout."
  (if (null seconds)
      (read-event)
    (with-timeout (seconds nil)
      (read-event nil nil seconds))))

(defun keydrill--read-skipped (seconds)
  "Read the next real key, skipping auto-repeat and modifier-only events.
SECONDS is a timeout for this wait, or nil to wait indefinitely.
Return nil if the wait times out."
  (let ((deadline (and seconds (+ (float-time) seconds)))
        event
        done)
    (while (not done)
      (setq event
            (keydrill--read-raw
             (and deadline (max 0.0 (- deadline (float-time))))))
      (cond
       ((null event)
        (setq done t))
       ((or (keydrill--auto-repeat-p event)
            (keydrill--modifier-only-p event))
        (when (and deadline (<= deadline (float-time)))
          (setq event nil
                done t)))
       (t
        (setq done t))))
    event))

(defun keydrill--coalesce-escape (event timeout)
  "If EVENT is Escape, read a follower and apply Meta.
TIMEOUT is seconds to wait for the follower, or nil to wait
indefinitely.  A timeout leaves EVENT as a lone Escape.  This is
how terminal `ESC x' becomes `M-x'."
  (if (not (keydrill--escape-event-p event))
      event
    (let ((next (keydrill--read-skipped timeout)))
      (cond
       ((null next)
        event)
       (t
        (let ((meta (keydrill--apply-meta next)))
          (if meta
              meta
            (push next unread-command-events)
            event)))))))

(defun keydrill--steps-prefix-p (got expected)
  "Return non-nil if GOT is a proper prefix of EXPECTED.
Both GOT and EXPECTED are canonical strings from
`keydrill-normalize-keys'."
  (let ((gs (split-string got))
        (es (split-string expected))
        (ok t))
    (and (< (length gs) (length es))
         (progn
           (while (and ok gs)
             (unless (equal (car gs) (car es))
               (setq ok nil))
             (setq gs (cdr gs)
                   es (cdr es)))
           ok))))

(defun keydrill--latency-ms (start)
  "Return milliseconds from START (`float-time') to now."
  (max 0 (round (* 1000.0 (- (float-time) start)))))

(defun keydrill--result (status start &rest extra)
  "Return a capture result plist for STATUS from START.
EXTRA is additional plist keys such as :got or :message."
  (append (list :status status :latency (keydrill--latency-ms start))
          extra))

(defun keydrill--timeout-message ()
  "Return the sequence-timeout feedback string."
  (format "✗ sequence timed out (%.1fs window)"
          (keydrill--sequence-timeout)))

(defun keydrill-read-answer (expected &optional start-time)
  "Read one answer for EXPECTED and classify it.
EXPECTED is a `key-description' or kbd string, or an event vector.
START-TIME is an Emacs `float-time' value; if nil, this function
records `(float-time)' when the read loop starts.

Return a plist:
  :status   `hit', `miss', `timeout', or `quit'
  :latency  milliseconds from START-TIME (or loop start) to scoring
  :got      canonical description of what was pressed, when useful
  :message  timeout feedback in the spirit of a 1.5s sequence miss

The first event has no inter-key timeout.  Later events use
`keydrill-sequence-timeout' seconds; a wait that expires is
:status `timeout'.

`inhibit-quit' is bound around the loop so `C-g' is data.
A `C-g' that matches EXPECTED is a hit.  A `C-g' that does not
match arms a 1s quit hatch; a second non-hit `C-g' inside that
window is :status `quit'.  A lone `q' that is not EXPECTED is
also :status `quit' (the \"press q to quit\" affordance).

Events are consumed and never executed."
  (let ((inhibit-quit t)
        (quit-flag nil)
        (start (or start-time (float-time)))
        (want (keydrill-normalize-keys expected))
        (got nil)
        (first t))
    (unwind-protect
        (catch 'keydrill-done
          (while t
            (let* ((timeout (unless first (keydrill--sequence-timeout)))
                   (raw (keydrill--read-skipped timeout)))
              (when (null raw)
                (throw 'keydrill-done
                       (keydrill--result
                        'timeout start
                        :got (and got (keydrill-normalize-keys (vconcat got)))
                        :message (keydrill--timeout-message))))
              (let* ((event (keydrill--coalesce-escape
                             raw keydrill-esc-coalesce-seconds))
                     (so-far nil)
                     (desc nil))
                (when (and first
                           (eq event ?q)
                           (not (equal want (keydrill-normalize-keys [?q]))))
                  (throw 'keydrill-done
                         (keydrill--result 'quit start :got "q")))
                ;; Held prefix keys auto-repeat.  Emacs does not flag
                ;; that the way a browser's e.repeat does, so a repeat
                ;; of the last event is ignored unless it is a real
                ;; next step (e.g. expected C-x C-x).
                (when (and got (equal event (car (last got))))
                  (let ((trial (keydrill-normalize-keys
                                (vconcat got (list event)))))
                    (unless (or (equal trial want)
                                (keydrill--steps-prefix-p trial want))
                      (setq event nil))))
                (when event
                  (setq got (append got (list event))
                        so-far (vconcat got)
                        desc (keydrill-normalize-keys so-far)
                        first nil)
                  (when (and (keydrill--c-g-event-p event)
                             (not (equal desc want)))
                    (let ((now (float-time)))
                      (when (and keydrill--last-cg-time
                                 (< (- now keydrill--last-cg-time)
                                    keydrill-quit-hatch-seconds))
                        (throw 'keydrill-done
                               (keydrill--result 'quit start :got desc)))
                      (setq keydrill--last-cg-time now)))
                  (cond
                   ((equal desc want)
                    (setq keydrill--last-cg-time nil)
                    (throw 'keydrill-done
                           (keydrill--result 'hit start :got desc)))
                   ((keydrill--steps-prefix-p desc want)
                    nil)
                   (t
                    (throw 'keydrill-done
                           (keydrill--result 'miss start :got desc)))))))))
      (setq quit-flag nil))))

(provide 'keydrill-capture)
;;; keydrill-capture.el ends here
