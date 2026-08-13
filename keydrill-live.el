;;; keydrill-live.el --- Resolve deck commands against the live keymap  -*- lexical-binding: t; -*-

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

;; At session start, look up each deck command with `where-is-internal'
;; in the buffer the user launched from.  Drill the user's binding when
;; it differs from the vanilla default (`:key'), after comparing both
;; sides with `keydrill-normalize-keys' so `C-/' vs `C-_' is not a remap.
;;
;; Unbound commands follow `keydrill-unbound-strategy':
;;
;; - `skip': omit the move from this session's intros and recall.
;; - `prompt-by-name': keep the move.  The expected key is `M-x' (the
;;   chord that starts `execute-extended-command').  Capture scores
;;   only that chord, not typing the command name — the dropped `typed'
;;   move type.  The prompt note names the command so the user still
;;   knows what to type after M-x.
;;
;; Resolution is a plist copy (`:expected-key', `:binding-note',
;; maybe `:skipped').  The original deck is not mutated.  The engine
;; planner still sees original ids and levels; only keys shown and
;; scored change.

;;; Code:

(require 'keydrill-capture)

;; User-facing default lives in `keydrill.el' as a defcustom.  Bare
;; defvar so compiling this file after the defcustom does not warn.
(defvar keydrill-unbound-strategy 'prompt-by-name
  "What to do when a deck command has no binding in the live keymap.
Defined as a defcustom in keydrill.el.")

(defconst keydrill-live-mx-key "M-x"
  "Expected `key-description' when an unbound command is drilled by name.")

(defun keydrill-live--buffer (buffer)
  "Return BUFFER if it is live, otherwise `current-buffer'."
  (if (and buffer (buffer-live-p buffer))
      buffer
    (current-buffer)))

(defun keydrill-live--strategy (strategy)
  "Return STRATEGY, or `keydrill-unbound-strategy', or `prompt-by-name'."
  (or strategy
      (and (boundp 'keydrill-unbound-strategy)
           keydrill-unbound-strategy)
      'prompt-by-name))

(defun keydrill-live--same-binding-p (a b)
  "Return non-nil if key descriptions A and B are the same after normalize."
  (equal (keydrill-normalize-keys a)
         (keydrill-normalize-keys b)))

(defun keydrill-live--typeable-event-p (event)
  "Return non-nil if EVENT is a key a drill can ask the user to press.
Characters, control/meta chords, and function keys count.
Menu-bar, tool-bar, mouse, and GUI names such as `open' do not."
  (let ((base (event-basic-type event)))
    (or (integerp base)
        (and (symbolp base)
             (or (string-match-p "\\`f[0-9]+\\'" (symbol-name base))
                 (memq base '(tab backtab return backspace delete
                              home end prior next insert escape
                              up down left right iso-lefttab)))))))

(defun keydrill-live--key-vector (keys)
  "Return KEYS as a vector, or nil.
`where-is-internal' may yield a string or a vector."
  (cond
   ((vectorp keys) keys)
   ((stringp keys) (vconcat keys))
   (t nil)))

(defun keydrill-live--unusable-key-p (keys)
  "Return non-nil if KEYS is not a typeable drill binding."
  (let ((keys (keydrill-live--key-vector keys)))
    (or (null keys)
        (zerop (length keys))
        (not (keydrill-live--typeable-event-p (aref keys 0))))))

(defun keydrill-live--first-typeable (keys)
  "Return the first typeable sequence in KEYS as a vector."
  (let ((found nil))
    (dolist (k keys)
      (unless (or found (keydrill-live--unusable-key-p k))
        (setq found (keydrill-live--key-vector k))))
    found))

(defun keydrill-live--lookup (command buffer)
  "Return the first typeable key vector for COMMAND in BUFFER, or nil.
Uses BUFFER's active maps.  Menu-bar, tool-bar, mouse, and GUI
events such as `open' are skipped.  If COMMAND is remapped in
BUFFER, look up the remapped command instead."
  (with-current-buffer buffer
    (let* ((target (or (command-remapping command) command))
           (keys (where-is-internal target nil nil)))
      (keydrill-live--first-typeable keys))))

(defun keydrill-live--put (move &rest plist)
  "Return a copy of MOVE with PLIST keys replaced.
MOVE is not mutated.  PLIST is alternating keys and values."
  (let ((s (copy-sequence move)))
    (while plist
      (let ((k (pop plist))
            (v (pop plist)))
        (setq s (plist-put s k v))))
    s))

(defun keydrill-live--unbound-note (command vanilla)
  "Return the one-line note for an unbound COMMAND whose vanilla key is VANILLA."
  (format "this command is unbound here; vanilla is %s; type M-x then %s"
          vanilla
          command))

(defun keydrill-live-resolve-move (move &optional buffer strategy)
  "Return a copy of MOVE with live `:expected-key' and optional `:binding-note'.
BUFFER is the launch buffer; a dead or nil BUFFER uses `current-buffer'.
STRATEGY is `skip' or `prompt-by-name'; nil uses `keydrill-unbound-strategy'.

When the command is unbound and STRATEGY is `skip', the copy has
`:skipped' non-nil.  When STRATEGY is `prompt-by-name', `:expected-key'
is `M-x' and `:binding-note' explains the named-execution fallback.

Vanilla and live descriptions are compared with
`keydrill-normalize-keys' so `C-/' vs `C-_' is not a remap."
  (let* ((buffer (keydrill-live--buffer buffer))
         (strategy (keydrill-live--strategy strategy))
         (command (plist-get move :command))
         (vanilla (or (plist-get move :key) ""))
         (keys (and command (keydrill-live--lookup command buffer))))
    (cond
     ((null keys)
      (if (eq strategy 'skip)
          (keydrill-live--put move
                              :expected-key vanilla
                              :skipped t)
        (keydrill-live--put move
                            :expected-key keydrill-live-mx-key
                            :binding-note
                            (keydrill-live--unbound-note command vanilla))))
     ((keydrill-live--same-binding-p (key-description keys) vanilla)
      (keydrill-live--put move :expected-key vanilla))
     (t
      (let ((live (key-description keys)))
        (keydrill-live--put move
                            :expected-key live
                            :binding-note
                            (format "your binding; vanilla is %s" vanilla)))))))

(defun keydrill-live-resolve-deck (deck &optional buffer strategy)
  "Return live-resolved copies of DECK for BUFFER.
STRATEGY is passed to `keydrill-live-resolve-move'.  Moves with
`:skipped' non-nil are omitted."
  (let (out)
    (dolist (m deck)
      (let ((resolved (keydrill-live-resolve-move m buffer strategy)))
        (unless (plist-get resolved :skipped)
          (push resolved out))))
    (nreverse out)))

(provide 'keydrill-live)
;;; keydrill-live.el ends here
