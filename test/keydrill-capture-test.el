;;; keydrill-capture-test.el --- Tests for keydrill-capture  -*- lexical-binding: t; -*-

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

;; ERT tests for key reading and scoring.  Events are fed through
;; `unread-command-events'; no real tty is required.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'keydrill-capture)

(defun keydrill-test--read (expected events &optional timeout)
  "Call `keydrill-read-answer' on EXPECTED with EVENTS queued.
TIMEOUT when non-nil binds `keydrill-sequence-timeout'."
  (let ((unread-command-events (append events nil))
        (keydrill-sequence-timeout
         (or timeout keydrill-sequence-timeout)))
    (keydrill-read-answer expected)))

(defun keydrill-test--status (expected events)
  "Return :status from `keydrill-test--read' on EXPECTED and EVENTS."
  (plist-get (keydrill-test--read expected events) :status))

(ert-deftest keydrill-capture-provides-feature ()
  "The capture module provides the `keydrill-capture' feature."
  (should (featurep 'keydrill-capture)))

(ert-deftest keydrill-capture-c-f-hit ()
  "A matching `C-f' is a hit."
  (should (eq (keydrill-test--status "C-f" (list ?\C-f)) 'hit)))

(ert-deftest keydrill-capture-c-f-miss ()
  "A wrong chord is a miss."
  (let ((res (keydrill-test--read "C-f" (list ?\C-b))))
    (should (eq (plist-get res :status) 'miss))
    (should (equal (plist-get res :got) "C-b"))))

(ert-deftest keydrill-capture-c-x-c-f-hit ()
  "A matching `C-x C-f' sequence is a hit."
  (should (eq (keydrill-test--status "C-x C-f" (list ?\C-x ?\C-f)) 'hit)))

(ert-deftest keydrill-capture-c-x-c-f-wrong-second-miss ()
  "A wrong second key in a sequence is a miss."
  (should (eq (keydrill-test--status "C-x C-f" (list ?\C-x ?\C-b)) 'miss)))

(ert-deftest keydrill-capture-sequence-timeout ()
  "Waiting past `keydrill-sequence-timeout' after the first key is timeout."
  (let ((res (keydrill-test--read "C-x C-f" (list ?\C-x) 0.05)))
    (should (eq (plist-get res :status) 'timeout))
    (should (string-match-p "sequence timed out" (plist-get res :message)))))

(ert-deftest keydrill-capture-c-g-is-answer-when-expected ()
  "`C-g' is a hit when it is the expected answer, not an immediate quit."
  (keydrill-capture-reset)
  (let ((res (keydrill-test--read "C-g" (list ?\C-g))))
    (should (eq (plist-get res :status) 'hit))
    (should (null quit-flag))))

(ert-deftest keydrill-capture-double-c-g-quits ()
  "Two `C-g' presses within 1s quit when `C-g' is not the answer.
The first non-hit `C-g' is a miss and arms the hatch; the second
call returns quit.  Matches the web trainer: first Escape when
not expected starts the window; the second within 1s ends the
session."
  (keydrill-capture-reset)
  (should (eq (plist-get (keydrill-test--read "C-f" (list ?\C-g)) :status)
              'miss))
  (should (eq (plist-get (keydrill-test--read "C-f" (list ?\C-g)) :status)
              'quit)))

(ert-deftest keydrill-capture-c-g-hit-does-not-quit ()
  "When the card expects `C-g', that press is a hit even if the hatch is armed.
The hatch is for bailing; a correct `C-g' never ends the session."
  (keydrill-capture-reset)
  (should (eq (plist-get (keydrill-test--read "C-f" (list ?\C-g)) :status)
              'miss))
  (should (eq (plist-get (keydrill-test--read "C-g" (list ?\C-g)) :status)
              'hit)))

(ert-deftest keydrill-capture-correct-c-g-resets-hatch ()
  "A correct `C-g' does not leave the quit hatch armed for the next card."
  (keydrill-capture-reset)
  (should (eq (plist-get (keydrill-test--read "C-g" (list ?\C-g)) :status)
              'hit))
  (should (eq (plist-get (keydrill-test--read "C-f" (list ?\C-g)) :status)
              'miss)))

(ert-deftest keydrill-capture-c-x-c-c-hit-does-not-kill-emacs ()
  "`C-x C-c' is a hit and does not call `save-buffers-kill-terminal'."
  (let ((called nil))
    (cl-letf (((symbol-function 'save-buffers-kill-terminal)
               (lambda (&rest _) (setq called t))))
      (should (eq (keydrill-test--status "C-x C-c" (list ?\C-x ?\C-c))
                  'hit))
      (should-not called))))

(ert-deftest keydrill-normalize-c-slash-and-c-underscore ()
  "`C-/' and `C-_' normalize to the same undo binding."
  (should (equal (keydrill-normalize-keys [?\C-/])
                 (keydrill-normalize-keys [?\C-_])))
  (should (equal (keydrill-normalize-keys "C-/")
                 (keydrill-normalize-keys "C-_")))
  (should (equal (keydrill-normalize-keys [?\C-/]) "C-/")))

(ert-deftest keydrill-normalize-c-spc-and-c-at ()
  "`C-SPC' and `C-@' normalize to the same set-mark binding."
  (should (equal (keydrill-normalize-keys [?\C-\s])
                 (keydrill-normalize-keys [?\C-@])))
  (should (equal (keydrill-normalize-keys "C-SPC")
                 (keydrill-normalize-keys "C-@")))
  (should (equal (keydrill-normalize-keys [?\C-\s]) "C-SPC")))

(ert-deftest keydrill-normalize-esc-x-and-m-x ()
  "`ESC x' and `M-x' normalize to the same description."
  (should (equal (keydrill-normalize-keys [?\e ?x])
                 (keydrill-normalize-keys [?\M-x])))
  (should (equal (keydrill-normalize-keys "ESC x")
                 (keydrill-normalize-keys "M-x")))
  (should (equal (keydrill-normalize-keys [?\M-x]) "M-x")))

(ert-deftest keydrill-normalize-esc-lt-and-m-lt ()
  "`ESC <' and `M-<' normalize to the same beginning-of-buffer binding."
  (should (equal (keydrill-normalize-keys [?\e ?<])
                 (keydrill-normalize-keys [?\M-<])))
  (should (equal (keydrill-normalize-keys "ESC <")
                 (keydrill-normalize-keys "M-<")))
  (should (equal (keydrill-normalize-keys [?\M-<]) "M-<")))

(ert-deftest keydrill-normalize-esc-c-backslash-and-c-m-backslash ()
  "`ESC C-\\' and `C-M-\\' normalize to the same indent-region binding."
  (should (equal (keydrill-normalize-keys [?\e ?\C-\\])
                 (keydrill-normalize-keys [?\C-\M-\\])))
  (should (equal (keydrill-normalize-keys "ESC C-\\")
                 (keydrill-normalize-keys "C-M-\\")))
  (should (equal (keydrill-normalize-keys [?\C-\M-\\]) "C-M-\\")))

(ert-deftest keydrill-normalize-tab-and-c-i ()
  "`TAB', `C-i', and `<tab>' normalize to the same binding."
  (should (equal (keydrill-normalize-keys "TAB")
                 (keydrill-normalize-keys "C-i")))
  (should (equal (keydrill-normalize-keys [?\t])
                 (keydrill-normalize-keys [tab])))
  (should (equal (keydrill-normalize-keys [?\t]) "TAB")))

(ert-deftest keydrill-normalize-f3-f4 ()
  "`<f3>' and `<f4>' round-trip in both GUI and tty spellings."
  (should (equal (keydrill-normalize-keys [f3]) "<f3>"))
  (should (equal (keydrill-normalize-keys [f4]) "<f4>"))
  (should (equal (keydrill-normalize-keys "<f3>") "<f3>"))
  (should (equal (keydrill-normalize-keys "<f4>") "<f4>")))

(ert-deftest keydrill-capture-c-underscore-hits-c-slash ()
  "A terminal `C-_' is a hit for expected `C-/'."
  (should (eq (keydrill-test--status "C-/" (list ?\C-_)) 'hit)))

(ert-deftest keydrill-capture-c-at-hits-c-spc ()
  "A terminal `C-@' is a hit for expected `C-SPC'."
  (should (eq (keydrill-test--status "C-SPC" (list ?\C-@)) 'hit)))

(ert-deftest keydrill-capture-esc-x-hits-m-x ()
  "A terminal `ESC x' pair is a hit for expected `M-x'."
  (should (eq (keydrill-test--status "M-x" (list ?\e ?x)) 'hit)))

(ert-deftest keydrill-capture-esc-lt-hits-m-lt ()
  "A terminal `ESC <' pair is a hit for expected `M-<'."
  (should (eq (keydrill-test--status "M-<" (list ?\e ?<)) 'hit)))

(ert-deftest keydrill-capture-esc-c-backslash-hits-c-m-backslash ()
  "A terminal `ESC C-\\' pair is a hit for expected `C-M-\\'."
  (should (eq (keydrill-test--status "C-M-\\" (list ?\e ?\C-\\)) 'hit)))

(ert-deftest keydrill-capture-tab-hits-c-i ()
  "A `TAB' event is a hit for expected `C-i'."
  (should (eq (keydrill-test--status "C-i" (list ?\t)) 'hit)))

(ert-deftest keydrill-capture-function-keys ()
  "Function keys round-trip through `key-description'."
  (should (eq (keydrill-test--status "<f3>" (list 'f3)) 'hit))
  (should (eq (keydrill-test--status "<f4>" (list 'f4)) 'hit)))

(ert-deftest keydrill-capture-ignores-auto-repeat ()
  "Auto-repeat events are skipped and never scored.
Fed through a stub `read-event': a cons whose car is `repeat' is
not a valid `unread-command-events' element (Emacs treats that
shape as event-plus-frame)."
  (let ((queue (list (cons 'repeat ?\C-b) ?\C-f)))
    (cl-letf (((symbol-function 'read-event)
               (lambda (&rest _)
                 (and queue (pop queue)))))
      (should (eq (plist-get (keydrill-read-answer "C-f") :status)
                  'hit)))))

(ert-deftest keydrill-capture-ignores-held-prefix ()
  "A held prefix key does not miss the next step."
  (should (eq (keydrill-test--status "C-x C-f" (list ?\C-x ?\C-x ?\C-f))
              'hit)))

(ert-deftest keydrill-capture-identical-sequence-steps-still-hit ()
  "`C-x C-x' is two real steps, not auto-repeat."
  (should (eq (keydrill-test--status "C-x C-x" (list ?\C-x ?\C-x)) 'hit)))

(ert-deftest keydrill-capture-ignores-modifier-only ()
  "Bare Shift, Control, and Meta events are skipped and never scored."
  (should (eq (keydrill-test--status
               "C-f"
               (list 'shift 'control 'meta ?\C-f))
              'hit)))

(ert-deftest keydrill-capture-q-quits ()
  "A lone `q' that is not the expected answer quits."
  (keydrill-capture-reset)
  (should (eq (keydrill-test--status "C-f" (list ?q)) 'quit)))

(ert-deftest keydrill-capture-q-is-hit-when-expected ()
  "`q' is a hit when it is the expected answer."
  (should (eq (keydrill-test--status "q" (list ?q)) 'hit)))

(ert-deftest keydrill-capture-remapped-binding-is-description ()
  "A remapped binding is compared as a key description, same as vanilla."
  (should (eq (keydrill-test--status "C-o" (list ?\C-o)) 'hit)))

(provide 'keydrill-capture-test)
;;; keydrill-capture-test.el ends here
