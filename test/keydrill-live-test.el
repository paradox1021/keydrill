;;; keydrill-live-test.el --- Tests for keydrill-live  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Astrolabe Apps, Inc.

;; Author: Brendan Kavanaugh (Astrolabe Apps, Inc.) <Brendan@astrolabeapps.com>
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

;; ERT tests for live-keymap resolution.  Uses a temp buffer and a
;; local minor-mode map; no GUI is required.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'keydrill-capture)
(require 'keydrill-engine)
(require 'keydrill-live)
(require 'keydrill-store)
(require 'keydrill-ui)

(defvar keydrill-data-file)
(defvar keydrill-hit-pause-seconds)

(defun keydrill-test-live-unbound ()
  "Command used by live-keymap tests; intentionally unbound."
  (interactive))

(defun keydrill-test-live-alias-cmd ()
  "Command bound only to `C-_' in live-keymap alias tests."
  (interactive))

(define-minor-mode keydrill-test-live-mode
  "Test-only minor mode for live-keymap ERT."
  :lighter nil
  :keymap (make-sparse-keymap))

(defun keydrill-test-live-move (id command key)
  "Return a level-1 test move with ID, COMMAND, and KEY."
  (list :id id :command command :key key :level 1 :prompt "do the thing"))

(defun keydrill-test-live-call (map fn)
  "Call FN in a temp buffer with MAP as `keydrill-test-live-mode's map.
FN is called with the temp buffer as its one argument."
  (with-temp-buffer
    (let ((minor-mode-map-alist
           (cons (cons 'keydrill-test-live-mode map)
                 minor-mode-map-alist)))
      (keydrill-test-live-mode 1)
      (funcall fn (current-buffer)))))

(ert-deftest keydrill-live-provides-feature ()
  "The live-keymap module provides the `keydrill-live' feature."
  (should (featurep 'keydrill-live)))

(ert-deftest keydrill-live-vanilla-unchanged ()
  "A vanilla binding is the expected key and has no note."
  (let ((move (keydrill-test-live-move "t.find" 'find-file "C-x C-f")))
    (with-temp-buffer
      (let ((resolved (keydrill-live-resolve-move move (current-buffer))))
        (should (equal (plist-get resolved :expected-key) "C-x C-f"))
        (should-not (plist-get resolved :binding-note))
        (should-not (plist-get resolved :skipped))))))

(ert-deftest keydrill-live-remapped-uses-user-binding ()
  "A remapped command drills the user's key and notes vanilla."
  (let ((move (keydrill-test-live-move "t.find" 'find-file "C-x C-f"))
        (map (make-sparse-keymap)))
    (define-key map (kbd "C-c f") #'find-file)
    (keydrill-test-live-call
     map
     (lambda (buf)
       (let ((resolved (keydrill-live-resolve-move move buf)))
         (should (equal (keydrill-normalize-keys
                         (plist-get resolved :expected-key))
                        (keydrill-normalize-keys "C-c f")))
         (should (string-match-p "your binding" (plist-get resolved :binding-note)))
         (should (string-match-p "C-x C-f" (plist-get resolved :binding-note)))
         (should-not (plist-get resolved :skipped)))))))

(ert-deftest keydrill-live-unbound-skip-omitted ()
  "Unbound plus skip omits the move from the resolved deck."
  (let* ((bound (keydrill-test-live-move "t.find" 'find-file "C-x C-f"))
         (unbound (keydrill-test-live-move
                   "t.unb" #'keydrill-test-live-unbound "C-c u"))
         (deck (list bound unbound)))
    (with-temp-buffer
      (let* ((one (keydrill-live-resolve-move unbound (current-buffer) 'skip))
             (resolved (keydrill-live-resolve-deck deck (current-buffer) 'skip)))
        (should (plist-get one :skipped))
        (should (equal (mapcar (lambda (m) (plist-get m :id)) resolved)
                       '("t.find")))))))

(ert-deftest keydrill-live-unbound-prompt-by-name-is-mx ()
  "Unbound plus prompt-by-name expects M-x and stays in the deck."
  (let ((move (keydrill-test-live-move
               "t.unb" #'keydrill-test-live-unbound "C-c u")))
    (with-temp-buffer
      (let* ((resolved (keydrill-live-resolve-move
                        move (current-buffer) 'prompt-by-name))
             (deck (keydrill-live-resolve-deck
                    (list move) (current-buffer) 'prompt-by-name)))
        (should (equal (plist-get resolved :expected-key)
                       keydrill-live-mx-key))
        (should (string-match-p "unbound" (plist-get resolved :binding-note)))
        (should (string-match-p "C-c u" (plist-get resolved :binding-note)))
        (should (string-match-p "keydrill-test-live-unbound"
                                (plist-get resolved :binding-note)))
        (should-not (plist-get resolved :skipped))
        (should (= (length deck) 1))
        (should (equal (plist-get (car deck) :expected-key)
                       keydrill-live-mx-key))))))

(ert-deftest keydrill-live-alias-is-not-a-remap ()
  "A C-_ vs C-/ spelling difference is not a your-binding note."
  (let ((move (keydrill-test-live-move
               "t.alias" #'keydrill-test-live-alias-cmd "C-/"))
        (map (make-sparse-keymap)))
    (define-key map (kbd "C-_") #'keydrill-test-live-alias-cmd)
    (keydrill-test-live-call
     map
     (lambda (buf)
       (let ((resolved (keydrill-live-resolve-move move buf)))
         (should (equal (plist-get resolved :expected-key) "C-/"))
         (should-not (plist-get resolved :binding-note))
         (should-not (plist-get resolved :skipped)))))))

(ert-deftest keydrill-live-dead-buffer-uses-current ()
  "A dead launch buffer falls back to `current-buffer'."
  (let ((dead (generate-new-buffer "keydrill-dead"))
        (move (keydrill-test-live-move "t.find" 'find-file "C-x C-f")))
    (kill-buffer dead)
    (with-temp-buffer
      (let ((resolved (keydrill-live-resolve-move move dead)))
        (should (equal (plist-get resolved :expected-key) "C-x C-f"))
        (should-not (plist-get resolved :binding-note))))))

(ert-deftest keydrill-live-session-drops-skipped-keeps-ids ()
  "Session overlay drops skipped moves; remaining ids are unchanged."
  (let* ((bound (keydrill-test-live-move "t.find" 'find-file "C-x C-f"))
         (unbound (keydrill-test-live-move
                   "t.unb" #'keydrill-test-live-unbound "C-c u"))
         (deck (list bound unbound))
         (store (keydrill-empty-store))
         (keydrill-unbound-strategy 'skip))
    (with-temp-buffer
      (let* ((session (keydrill--session-make deck "emacs" store #'identity))
             (session (keydrill--session-apply-live session (current-buffer)))
             (ids (mapcar (lambda (it)
                            (plist-get (plist-get it :move) :id))
                          (plist-get session :queue))))
        (should (equal ids '("t.find")))
        (should (= (plist-get session :total) 1))
        (should (= (plist-get session :intro-count) 1))))))

(ert-deftest keydrill-live-ui-start-scores-expected-key ()
  "Interactive start passes the live expected key to capture."
  (let ((keydrill-data-file (make-temp-file "keydrill-live-" nil ".eld"))
        (keydrill-hit-pause-seconds 0)
        (got nil)
        (map (make-sparse-keymap))
        (deck (list (keydrill-test-live-move "t.find" 'find-file "C-x C-f"))))
    (define-key map (kbd "C-c f") #'find-file)
    (unwind-protect
        (progn
          (save-window-excursion
            (keydrill-test-live-call
             map
             (lambda (_buf)
               (cl-letf (((symbol-function 'keydrill-read-answer)
                          (lambda (expected &optional _start)
                            (setq got expected)
                            (list :status 'quit :latency 0))))
                 (keydrill-ui-start deck "emacs")))))
          (should (equal (keydrill-normalize-keys got)
                         (keydrill-normalize-keys "C-c f"))))
      (when (file-exists-p keydrill-data-file)
        (delete-file keydrill-data-file))
      (when (get-buffer keydrill-buffer-name)
        (kill-buffer keydrill-buffer-name)))))

(ert-deftest keydrill-live-skips-menu-only-binding ()
  "A command bound only on the menu-bar is treated as unbound."
  (let ((move (keydrill-test-live-move
               "t.unb" #'keydrill-test-live-unbound "C-c u"))
        (map (make-sparse-keymap)))
    (define-key map [menu-bar fake cmd] #'keydrill-test-live-unbound)
    (keydrill-test-live-call
     map
     (lambda (buf)
       (let ((resolved (keydrill-live-resolve-move move buf 'skip)))
         (should (plist-get resolved :skipped)))))))

(ert-deftest keydrill-live-prefers-key-over-menu-bar ()
  "A real key wins when the command is also on the menu-bar."
  (let ((move (keydrill-test-live-move
               "t.unb" #'keydrill-test-live-unbound "C-c u"))
        (map (make-sparse-keymap)))
    (define-key map [menu-bar fake cmd] #'keydrill-test-live-unbound)
    (define-key map (kbd "C-c u") #'keydrill-test-live-unbound)
    (keydrill-test-live-call
     map
     (lambda (buf)
       (let ((resolved (keydrill-live-resolve-move move buf)))
         (should (equal (keydrill-normalize-keys
                         (plist-get resolved :expected-key))
                        (keydrill-normalize-keys "C-c u")))
         (should-not (plist-get resolved :skipped)))))))

(ert-deftest keydrill-live-skips-gui-open-event ()
  "A GUI File-open event is not a drill binding; C-x C-f wins."
  (cl-letf (((symbol-function 'where-is-internal)
             (lambda (&rest _)
               (list (vector 'open) (vector ?\C-x ?\C-f)))))
    (with-temp-buffer
      (let* ((move (keydrill-test-live-move "t.find" 'find-file "C-x C-f"))
             (resolved (keydrill-live-resolve-move move (current-buffer))))
        (should (equal (plist-get resolved :expected-key) "C-x C-f"))
        (should-not (plist-get resolved :binding-note))
        (should-not (plist-get resolved :skipped))))))

(ert-deftest keydrill-live-gui-open-only-is-unbound ()
  "A command bound only to a GUI File-open event is unbound."
  (cl-letf (((symbol-function 'where-is-internal)
             (lambda (&rest _)
               (list (vector 'open)))))
    (with-temp-buffer
      (let* ((move (keydrill-test-live-move "t.find" 'find-file "C-x C-f"))
             (resolved (keydrill-live-resolve-move move (current-buffer) 'skip)))
        (should (plist-get resolved :skipped))))))

(ert-deftest keydrill-live-prefers-deck-key-among-vanilla-aliases ()
  "A second vanilla binding is not a remap.
`beginning-of-buffer' answers to both M-< and C-<home>, and
`where-is-internal' may list C-<home> first.  The deck key wins
and no \"your binding\" note is attached."
  (cl-letf (((symbol-function 'where-is-internal)
             (lambda (&rest _)
               (list (vector 'C-home) (kbd "M-<")))))
    (with-temp-buffer
      (let* ((move (keydrill-test-live-move
                    "t.bob" 'beginning-of-buffer "M-<"))
             (resolved (keydrill-live-resolve-move move (current-buffer))))
        (should (equal (plist-get resolved :expected-key) "M-<"))
        (should-not (plist-get resolved :binding-note))))))

(ert-deftest keydrill-live-reports-remap-when-deck-key-is-gone ()
  "With the deck key unbound, the surviving binding is a real remap."
  (cl-letf (((symbol-function 'where-is-internal)
             (lambda (&rest _)
               (list (vector 'C-home)))))
    (with-temp-buffer
      (let* ((move (keydrill-test-live-move
                    "t.bob" 'beginning-of-buffer "M-<"))
             (resolved (keydrill-live-resolve-move move (current-buffer))))
        (should (equal (plist-get resolved :expected-key) "C-<home>"))
        (should (string-match-p "your binding"
                                (plist-get resolved :binding-note)))))))

(provide 'keydrill-live-test)
;;; keydrill-live-test.el ends here
