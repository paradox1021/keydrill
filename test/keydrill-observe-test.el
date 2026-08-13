;;; keydrill-observe-test.el --- Tests for keydrill-observe  -*- lexical-binding: t; -*-

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

;; ERT tests for observer aggregation, skip rules, gap ranking, and
;; report text.  The idle flush is not waited on; tests call bump and
;; overlay directly.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'keydrill-engine)
(require 'keydrill-store)
(require 'keydrill-ui)
(require 'keydrill-observe)
(require 'keydrill-deck-emacs)

(defvar keydrill-data-file)
(defvar isearch-mode)

(defun keydrill-test-observe-reset ()
  "Clear observer memory used by a test."
  (keydrill-observe-reset))

(ert-deftest keydrill-observe-provides-feature ()
  "The observer module provides the `keydrill-observe' feature."
  (should (featurep 'keydrill-observe)))

(ert-deftest keydrill-observe-bump-increments-week ()
  "Two bumps of the same command, method, and week add to 2."
  (unwind-protect
      (progn
        (keydrill-observe-reset)
        (keydrill-observe-bump 'query-replace 'mx "2026-W33")
        (keydrill-observe-bump 'query-replace 'mx "2026-W33")
        (let ((methods (cdr (assq 'query-replace keydrill-observe--counts))))
          (should (= (keydrill-observe--method-total methods 'mx) 2))))
    (keydrill-test-observe-reset)))

(ert-deftest keydrill-observe-weeks-are-separate ()
  "Counts in different weeks do not overwrite each other."
  (unwind-protect
      (progn
        (keydrill-observe-reset)
        (keydrill-observe-bump 'query-replace 'mx "2026-W32")
        (keydrill-observe-bump 'query-replace 'mx "2026-W33")
        (keydrill-observe-bump 'query-replace 'mx "2026-W33")
        (let ((methods (cdr (assq 'query-replace keydrill-observe--counts))))
          (should (= (keydrill-observe--method-total methods 'mx) 3))
          (should (= (cdr (assoc "2026-W32" (cdr (assq 'mx methods)))) 1))
          (should (= (cdr (assoc "2026-W33" (cdr (assq 'mx methods)))) 2))))
    (keydrill-test-observe-reset)))

(ert-deftest keydrill-observe-method-from-keys-key-and-mx ()
  "Bound keys are `key'; empty or M-x keys are `mx'."
  (with-temp-buffer
    (should (eq (keydrill-observe--method-from-keys
                 (kbd "C-f") 'forward-char)
                'key))
    (should (eq (keydrill-observe--method-from-keys
                 (kbd "M-x") 'query-replace)
                'mx))
    (should (eq (keydrill-observe--method-from-keys
                 [] 'query-replace)
                'mx))))

(ert-deftest keydrill-observe-skips-self-insert-and-minibuffer ()
  "Self-insert is ignored; minibuffer depth blocks recording."
  (should-not (keydrill-observe--should-record-p 'self-insert-command))
  (should-not (keydrill-observe--should-record-p 'execute-extended-command))
  (should (keydrill-observe--should-record-p 'query-replace))
  (cl-letf (((symbol-function 'minibuffer-depth) (lambda () 1)))
    (should-not (keydrill-observe--should-record-p 'query-replace))))

(ert-deftest keydrill-observe-skips-isearch ()
  "Commands during isearch are not recorded."
  (let ((isearch-mode t))
    (should-not (keydrill-observe--should-record-p 'query-replace))))

(ert-deftest keydrill-observe-hook-swallows-errors ()
  "A failure inside either command hook does not signal."
  (cl-letf (((symbol-function 'keydrill-observe-bump)
             (lambda (&rest _) (error "observer boom")))
            (this-command 'query-replace))
    (keydrill-observe--pre-command)
    (setq keydrill-observe--from-mx t)
    (keydrill-observe--post-command)
    (should t)))

(ert-deftest keydrill-observe-off-hook-not-installed ()
  "With the mode off, neither command hook is installed."
  (when keydrill-observe-mode
    (keydrill-observe-mode -1))
  (should-not (memq #'keydrill-observe--pre-command pre-command-hook))
  (should-not (memq #'keydrill-observe--post-command post-command-hook)))

(ert-deftest keydrill-observe-mx-records-on-post-command ()
  "M-x is flagged in pre-command and counted as `mx' in post-command."
  (unwind-protect
      (progn
        (keydrill-observe-reset)
        (let ((this-command 'execute-extended-command))
          (keydrill-observe--pre-command))
        (should (null (assq 'query-replace keydrill-observe--counts)))
        (let ((this-command 'query-replace))
          (keydrill-observe--post-command))
        (let ((methods (cdr (assq 'query-replace keydrill-observe--counts))))
          (should (= (keydrill-observe--method-total methods 'mx) 1))))
    (keydrill-test-observe-reset)))

(ert-deftest keydrill-observe-overlay-survives-move-update ()
  "Copying the store for a move update keeps observer counts."
  (unwind-protect
      (progn
        (keydrill-observe-reset)
        (keydrill-observe-bump 'query-replace 'mx "2026-W33")
        (let* ((store (keydrill-observe-overlay-store (keydrill-empty-store)))
               (store (keydrill-mark-drilling store "emacs.query-replace"))
               (methods (cdr (assq 'query-replace
                                   (plist-get store :observer)))))
          (should (= (keydrill-observe--method-total methods 'mx) 1))
          (should (eq (keydrill-move-phase store "emacs.query-replace")
                      'drilling))))
    (keydrill-test-observe-reset)))

(ert-deftest keydrill-observe-save-merges-counts ()
  "A store save writes in-memory observer counts."
  (let ((keydrill-data-file (make-temp-file "keydrill-obs-" nil ".eld")))
    (unwind-protect
        (progn
          (keydrill-observe-reset)
          (keydrill-observe-bump 'query-replace 'mx "2026-W33")
          (keydrill-store-save (keydrill-empty-store))
          (keydrill-observe-reset)
          (let* ((store (keydrill-store-load))
                 (methods (cdr (assq 'query-replace
                                     (plist-get store :observer)))))
            (should (= (keydrill-observe--method-total methods 'mx) 1))))
      (keydrill-test-observe-reset)
      (when (file-exists-p keydrill-data-file)
        (delete-file keydrill-data-file)))))

(ert-deftest keydrill-observe-curated-prompt-wins ()
  "A deck command uses the curated prompt, not the docstring."
  (let ((prompt (keydrill-observe--prompt 'query-replace))
        (curated (plist-get (keydrill-observe--curated-move 'query-replace)
                            :prompt)))
    (should (equal prompt curated))
    (should (stringp prompt))
    (should (> (length prompt) 0))))

(ert-deftest keydrill-observe-docstring-prompt-fallback ()
  "A command not in the deck uses its docstring first line."
  (let ((prompt (keydrill-observe--prompt 'ignore))
        (case-fold-search t))
    (should (string-match-p "ignore\\|do nothing" prompt))))

(ert-deftest keydrill-observe-gaps-rank-by-count-times-keys ()
  "Gaps rank by non-key count times live binding length."
  (unwind-protect
      (progn
        (keydrill-observe-reset)
        ;; Two-event binding * 5 = 10 beats one-event binding * 8 = 8.
        (let ((n 0))
          (while (< n 5)
            (keydrill-observe-bump 'find-file 'mx "2026-W33")
            (setq n (1+ n))))
        (let ((n 0))
          (while (< n 8)
            (keydrill-observe-bump 'query-replace 'mx "2026-W33")
            (setq n (1+ n))))
        (cl-letf (((symbol-function 'keydrill-observe--keyboard-keys)
                   (lambda (command _buffer)
                     (cond
                      ((eq command 'find-file) (kbd "C-x C-f"))
                      ((eq command 'query-replace) (kbd "M-%"))
                      (t nil)))))
          (let ((gaps (keydrill-observe-gaps 10)))
            (should (eq (plist-get (car gaps) :command) 'find-file))
            (should (eq (plist-get (cadr gaps) :command) 'query-replace))
            (should (= (plist-get (car gaps) :score) 10))
            (should (= (plist-get (cadr gaps) :score) 8)))))
    (keydrill-test-observe-reset)))

(ert-deftest keydrill-observe-key-only-is-not-a-gap ()
  "A command used only by its binding is not a gap."
  (unwind-protect
      (progn
        (keydrill-observe-reset)
        (keydrill-observe-bump 'forward-char 'key "2026-W33")
        (should (null (keydrill-observe-gaps 10))))
    (keydrill-test-observe-reset)))

(ert-deftest keydrill-observe-report-text-names-binding ()
  "Report text matches the unused-binding sentence."
  (unwind-protect
      (progn
        (keydrill-observe-reset)
        (let ((n 0))
          (while (< n 47)
            (keydrill-observe-bump 'query-replace 'mx "2026-W33")
            (setq n (1+ n))))
        (let* ((gaps (keydrill-observe-gaps 5))
               (text (keydrill-observe-format-report gaps)))
          (should (string-match-p "query-replace" text))
          (should (string-match-p "47×" text))
          (should (string-match-p "via M-x" text))
          (should (string-match-p "M-%" text))))
    (keydrill-test-observe-reset)))

(ert-deftest keydrill-observe-mode-toggles-hook ()
  "Enabling adds both command hooks; disabling removes them and flushes."
  (let ((keydrill-data-file (make-temp-file "keydrill-obs-" nil ".eld")))
    (unwind-protect
        (progn
          (keydrill-observe-reset)
          (keydrill-observe-mode 1)
          (should (memq #'keydrill-observe--pre-command pre-command-hook))
          (should (memq #'keydrill-observe--post-command post-command-hook))
          (keydrill-observe-mode -1)
          (should-not (memq #'keydrill-observe--pre-command pre-command-hook))
          (should-not (memq #'keydrill-observe--post-command
                            post-command-hook)))
      (when keydrill-observe-mode
        (keydrill-observe-mode -1))
      (keydrill-test-observe-reset)
      (when (get-buffer "*keydrill-observe*")
        (kill-buffer "*keydrill-observe*"))
      (when (file-exists-p keydrill-data-file)
        (delete-file keydrill-data-file)))))

(ert-deftest keydrill-observe-first-enable-explains-once ()
  "First enable names the .eld file; a later enable does not repeat it."
  (let ((keydrill-data-file (make-temp-file "keydrill-obs-" nil ".eld")))
    (unwind-protect
        (progn
          (keydrill-observe-reset)
          (keydrill-observe-mode 1)
          (should (eq (cdr (assq :explained keydrill-observe--counts)) t))
          (with-current-buffer "*keydrill-observe*"
            (let ((text (buffer-string)))
              (should (string-match-p (regexp-quote keydrill-data-file) text))
              (should (string-match-p ":observer" text))
              (should (string-match-p "ISO week" text))
              (should (string-match-p "no network" text))))
          (kill-buffer "*keydrill-observe*")
          (keydrill-observe-mode -1)
          (keydrill-observe-mode 1)
          (should-not (get-buffer "*keydrill-observe*")))
      (when keydrill-observe-mode
        (keydrill-observe-mode -1))
      (keydrill-test-observe-reset)
      (when (get-buffer "*keydrill-observe*")
        (kill-buffer "*keydrill-observe*"))
      (when (file-exists-p keydrill-data-file)
        (delete-file keydrill-data-file)))))

(defun keydrill-observe-test--clean-form-p (form)
  "Return non-nil if FORM is counts, symbols, week keys, or t.
Rejects event vectors and other keystroke content."
  (cond
   ((null form) t)
   ((eq form t) t)
   ((integerp form) t)
   ((symbolp form) t)
   ((and (stringp form)
         (string-match-p "\\`[0-9]\\{4\\}-W[0-9]\\{2\\}\\'" form))
    t)
   ((consp form)
    (and (keydrill-observe-test--clean-form-p (car form))
         (keydrill-observe-test--clean-form-p (cdr form))))
   (t nil)))

(ert-deftest keydrill-observe-stores-no-keystroke-content ()
  "Observer values are counts, symbols, and week keys, not event vectors."
  (unwind-protect
      (progn
        (keydrill-observe-reset)
        (keydrill-observe-bump 'query-replace 'mx "2026-W33")
        (keydrill-observe-bump 'find-file 'key "2026-W33")
        (push (cons :explained t) keydrill-observe--counts)
        (should (keydrill-observe-test--clean-form-p keydrill-observe--counts))
        (let ((store (keydrill-observe-overlay-store (keydrill-empty-store))))
          (should (keydrill-observe-test--clean-form-p
                   (plist-get store :observer))))
        (should-not (keydrill-observe-test--clean-form-p
                     (list (vector ?q ?u ?e ?r ?y)))))
    (keydrill-test-observe-reset)))

(ert-deftest keydrill-observe-gap-session-is-recall-only ()
  "An optional MOVES argument queues recall cards, not planner intros."
  (let* ((move (list :id "emacs.query-replace"
                     :command 'query-replace
                     :key "M-%"
                     :level 3
                     :prompt "Replace one word"))
         (store (keydrill-empty-store))
         (session (keydrill--session-make (list move) "gaps" store nil
                                          (list move)))
         (item (car (plist-get session :queue))))
    (should (= (length (plist-get session :queue)) 1))
    (should-not (plist-get item :intro))
    (should (plist-get item :first-try))
    (should (= (plist-get session :intro-count) 0))))

(ert-deftest keydrill-observe-purge-clears-memory ()
  "Purging the progress file resets in-memory counts."
  (let ((keydrill-data-file (make-temp-file "keydrill-obs-" nil ".eld")))
    (unwind-protect
        (progn
          (keydrill-observe-reset)
          (keydrill-observe-bump 'query-replace 'mx "2026-W33")
          (keydrill-store-save (keydrill-empty-store))
          (should (keydrill-store-purge))
          (should (null keydrill-observe--counts)))
      (keydrill-test-observe-reset)
      (when (file-exists-p keydrill-data-file)
        (delete-file keydrill-data-file)))))

(ert-deftest keydrill-observe-keyboard-keys-skips-gui-open ()
  "Report bindings skip a GUI File-open event in favor of a typeable key."
  (cl-letf (((symbol-function 'where-is-internal)
             (lambda (&rest _)
               (list (vector 'open) (kbd "M-%")))))
    (with-temp-buffer
      (should (equal (keydrill-observe--keyboard-keys
                      'query-replace (current-buffer))
                     (kbd "M-%"))))))

(provide 'keydrill-observe-test)
;;; keydrill-observe-test.el ends here
