;;; keydrill-observe.el --- Opt-in command usage observer  -*- lexical-binding: t; -*-

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

;; Optional global minor mode, off by default.  Opt-in, local file
;; only, no network.  A `pre-command-hook' function counts how
;; commands are invoked (key, M-x, mouse/menu) by command and local
;; ISO week.  The hook body is wrapped in `condition-case' and must
;; stay cheap: increment in-memory cells, no `prin1', no file I/O.
;;
;; `execute-extended-command' overwrites `this-command' with the
;; target before `post-command-hook'.  Pre-command therefore only
;; sees M-x itself; a matching `post-command-hook' records the
;; target as method `mx'.  Both hooks swallow errors: a broken
;; command hook makes Emacs unusable.
;;
;; Counts are aggregate only.  Keystroke content, buffer text, and
;; file names are not recorded.  Minibuffer and isearch commands are
;; ignored.  `self-insert-command' is ignored so typing does not
;; flood the file.
;;
;; Week keys are local ISO week-numbering year and week, `YYYY-Www',
;; from `format-time-string' with `%G-W%V' (Monday-based weeks).
;;
;; Persistence is idle-flushed into `keydrill-data-file' via the
;; store's :observer alist.  Session saves merge those counts through
;; `keydrill-store-before-save-functions'.
;;
;; `M-x keydrill-report' lists unused-binding gaps ranked by
;; (non-key count) times (live keyboard-binding length).

;;; Code:

(require 'keydrill-engine)
(require 'keydrill-store)
(require 'keydrill-live)
(require 'keydrill-deck-emacs)

(declare-function keydrill-ui-start "keydrill-ui" (deck deck-id &optional moves))

(defvar keydrill-data-file)
(defvar keydrill-observe-report-limit)

(defconst keydrill-observe--ignore
  '(self-insert-command
    org-self-insert-command
    execute-extended-command
    execute-extended-command-for-buffer
    digit-argument
    universal-argument
    universal-argument-more
    negative-argument
    handle-select-window
    handle-switch-frame)
  "Commands that must not be recorded.")

(defvar keydrill-observe--counts nil
  "In-memory observer alist.
Entries are (COMMAND . ((METHOD . ((WEEK . COUNT)...))...))
except (:explained . t) after the one-time notice.")

(defvar keydrill-observe--timer nil
  "Idle timer that flushes observer counts, or nil.")

(defvar keydrill-observe--from-mx nil
  "Non-nil when pre-command saw `execute-extended-command'.")

(defvar-local keydrill-observe--source-buffer nil
  "Buffer `keydrill-report' was invoked from, for live-keymap lookup.")

(defvar-local keydrill-observe--report-gaps nil
  "Gap plists shown in the current report buffer.")

(defun keydrill-observe--limit ()
  "Return `keydrill-observe-report-limit', or 10 if unbound."
  (if (boundp 'keydrill-observe-report-limit)
      keydrill-observe-report-limit
    10))

(defun keydrill-observe--week (&optional time)
  "Return the local ISO week string for TIME, or now.
The form is YYYY-Www using `%G-W%V': ISO week-numbering year and
week (Monday-based, 01-53).  Local time, not UTC, same rationale
as `keydrill-today-string'."
  (format-time-string "%G-W%V" time))

(defun keydrill-observe--ensure-package ()
  "Load the keydrill entry file so defcustoms are defined.
No-op when the `keydrill' feature is already loaded.  Autoloading
this module does not load that entry file, so `keydrill-data-file'
would otherwise stay unbound and observer counts would not flush."
  (unless (featurep 'keydrill)
    (require 'keydrill)))

(defun keydrill-observe--method-from-keys (keys command)
  "Return `key', `mx', `mouse', or `menu' for KEYS and COMMAND.
KEYS is a vector from `this-single-command-keys'.  Empty keys or
keys that invoked `execute-extended-command' are `mx'."
  (cond
   ((or (null keys) (zerop (length keys)))
    'mx)
   ((mouse-event-p (aref keys 0))
    'mouse)
   ((memq (event-basic-type (aref keys 0))
          '(menu-bar tool-bar tab-bar header-line))
    'menu)
   ((memq (key-binding keys)
          '(execute-extended-command
            execute-extended-command-for-buffer))
    'mx)
   ((eq (key-binding keys) command)
    'key)
   (t
    'mx)))

(defun keydrill-observe--context-ok-p ()
  "Return non-nil when this command may be recorded."
  (and (zerop (minibuffer-depth))
       (not (bound-and-true-p isearch-mode))))

(defun keydrill-observe--should-record-p (command)
  "Return non-nil if COMMAND should be counted."
  (and (keydrill-observe--context-ok-p)
       (symbolp command)
       (not (keywordp command))
       (not (memq command keydrill-observe--ignore))))

(defun keydrill-observe-bump (command method &optional week)
  "Increment the count for COMMAND, METHOD, and WEEK.
METHOD is `key', `mx', `mouse', or `menu'.  WEEK defaults to
`keydrill-observe--week'.  Mutates `keydrill-observe--counts'.
COMMAND that is not a symbol is ignored.  Does not cons a new
store and does not write a file."
  (when (symbolp command)
    (let* ((week (or week (keydrill-observe--week)))
           (entry (assq command keydrill-observe--counts)))
      (unless entry
        (setq entry (cons command nil))
        (push entry keydrill-observe--counts))
      (let ((method-cell (assq method (cdr entry))))
        (unless method-cell
          (setq method-cell (cons method nil))
          (setcdr entry (cons method-cell (cdr entry))))
        (let ((week-cell (assoc week (cdr method-cell))))
          (if week-cell
              (setcdr week-cell (1+ (cdr week-cell)))
            (setcdr method-cell
                    (cons (cons week 1) (cdr method-cell)))))))))

(defun keydrill-observe--method-total (methods method)
  "Return the summed count for METHOD in METHODS across weeks."
  (let ((total 0))
    (dolist (week-pair (cdr (assq method methods)))
      (setq total (+ total (cdr week-pair))))
    total))

(defun keydrill-observe-overlay-store (store)
  "Return STORE with in-memory observer counts in :observer.
If there are no in-memory counts, return STORE unchanged."
  (if (null keydrill-observe--counts)
      store
    (let ((new (keydrill--copy-store store)))
      (plist-put new :observer (copy-alist keydrill-observe--counts)))))

(defun keydrill-observe-reset ()
  "Clear in-memory observer counts and cancel a pending flush."
  (when keydrill-observe--timer
    (cancel-timer keydrill-observe--timer)
    (setq keydrill-observe--timer nil))
  (setq keydrill-observe--from-mx nil)
  (setq keydrill-observe--counts nil))

(defun keydrill-observe--load ()
  "Load :observer from the progress file into memory."
  (let ((obs (plist-get (keydrill-store-load) :observer)))
    (setq keydrill-observe--counts (copy-alist obs))))

(defun keydrill-observe--flush ()
  "Write in-memory observer counts into the progress file."
  (when keydrill-observe--timer
    (cancel-timer keydrill-observe--timer)
    (setq keydrill-observe--timer nil))
  (when (and keydrill-observe--counts
             (boundp 'keydrill-data-file)
             keydrill-data-file)
    (keydrill-store-save
     (keydrill-observe-overlay-store (keydrill-store-load)))))

(defun keydrill-observe--schedule-save ()
  "Arm a 5-second idle flush if one is not already pending."
  (unless keydrill-observe--timer
    (setq keydrill-observe--timer
          (run-with-idle-timer 5 nil #'keydrill-observe--flush))))

(defun keydrill-observe--record-this (&optional method)
  "Count `this-command' if it is eligible.
METHOD if non-nil overrides detection from `this-single-command-keys'."
  (when (keydrill-observe--should-record-p this-command)
    (keydrill-observe-bump
     this-command
     (or method
         (keydrill-observe--method-from-keys
          (this-single-command-keys) this-command)))
    (keydrill-observe--schedule-save)))

(defun keydrill-observe--pre-command ()
  "Record `this-command' from `pre-command-hook'.
Never signal.  An extended-command invocation is deferred to
`keydrill-observe--post-command'."
  (condition-case nil
      (if (memq this-command
                '(execute-extended-command
                  execute-extended-command-for-buffer))
          (setq keydrill-observe--from-mx t)
        (setq keydrill-observe--from-mx nil)
        (keydrill-observe--record-this))
    (error nil)))

(defun keydrill-observe--post-command ()
  "Record an extended-command target after `execute-extended-command'.
Never signal."
  (condition-case nil
      (when keydrill-observe--from-mx
        (setq keydrill-observe--from-mx nil)
        (keydrill-observe--record-this 'mx))
    (error nil)))

(defun keydrill-observe--explanation-text ()
  "Return the one-time explanation, including the progress file path."
  (format "keydrill observer is on.

What is recorded (aggregates only):
- the command name (a symbol, for example query-replace)
- how it was invoked: a key binding, M-x, or the menu/mouse
- which local ISO week it happened in (YYYY-Www, Monday-based)
- a running count for that command × method × week

What is not recorded:
- the keys you typed (no keystroke text, no file names, no buffer text)
- commands run in the minibuffer or during isearch

Where it is stored:
- the same local file as your drill progress:
  %s
  in the :observer section
- nothing is sent anywhere; this package has no network code

Disable with M-x keydrill-observe-mode.  M-x keydrill-report
lists commands you run via M-x or the menu that already have a key.
"
          (or keydrill-data-file "keydrill-data.eld")))

(defun keydrill-observe--explain ()
  "Show the one-time observer explanation in *keydrill-observe*."
  (let ((text (keydrill-observe--explanation-text))
        (buf (get-buffer-create "*keydrill-observe*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf)
    (message "keydrill observer is on.  Details in *keydrill-observe*.")))

(defun keydrill-observe--enable ()
  "Start recording and maybe show the one-time explanation."
  (unless keydrill-observe--counts
    (keydrill-observe--load))
  (unless (assq :explained keydrill-observe--counts)
    (keydrill-observe--explain)
    (push (cons :explained t) keydrill-observe--counts)
    (keydrill-observe--flush))
  (add-hook 'pre-command-hook #'keydrill-observe--pre-command)
  (add-hook 'post-command-hook #'keydrill-observe--post-command)
  (add-hook 'kill-emacs-hook #'keydrill-observe--flush))

(defun keydrill-observe--disable ()
  "Stop recording and flush counts."
  (remove-hook 'pre-command-hook #'keydrill-observe--pre-command)
  (remove-hook 'post-command-hook #'keydrill-observe--post-command)
  (remove-hook 'kill-emacs-hook #'keydrill-observe--flush)
  (keydrill-observe--flush))

;;;###autoload
(define-minor-mode keydrill-observe-mode
  "Toggle the keydrill usage observer.
When on, counts how commands are invoked.  Off by default.  Opt-in,
local file only, no network.  See `keydrill-report'."
  :global t
  :group 'keydrill
  :lighter " KD-obs"
  (keydrill-observe--ensure-package)
  (if keydrill-observe-mode
      (keydrill-observe--enable)
    (keydrill-observe--disable)))

(defun keydrill-observe--curated-move (command)
  "Return the curated Emacs-deck move for COMMAND, or nil."
  (let ((found nil))
    (dolist (m keydrill-deck-emacs)
      (when (eq (plist-get m :command) command)
        (setq found m)))
    found))

(defun keydrill-observe--prompt (command)
  "Return a drill prompt for COMMAND.
A curated deck prompt wins.  Otherwise use the first line of
COMMAND's docstring, or a fallback that names COMMAND."
  (let ((curated (keydrill-observe--curated-move command)))
    (or (and curated (plist-get curated :prompt))
        (let ((doc (ignore-errors (documentation command t))))
          (if (and doc (stringp doc) (> (length doc) 0))
              (car (split-string doc "\n"))
            (format "Run %s" command))))))

(defun keydrill-observe--keyboard-keys (command buffer)
  "Return the first typeable key vector of COMMAND in BUFFER, or nil.
Uses the same filter as live-keymap lookup: menu-bar, tool-bar,
mouse, and GUI events such as `open' are skipped."
  (keydrill-live--lookup command (keydrill-live--buffer buffer)))

(defun keydrill-observe--move-for-command (command)
  "Return a drill move plist for COMMAND, or nil if unbound."
  (let* ((curated (keydrill-observe--curated-move command))
         (buf (if (and (boundp 'keydrill--launch-buffer)
                       (buffer-live-p keydrill--launch-buffer))
                  keydrill--launch-buffer
                (current-buffer)))
         (keys (keydrill-observe--keyboard-keys command buf)))
    (when keys
      (list :id (if curated
                    (plist-get curated :id)
                  (format "observe.%s" command))
            :command command
            :key (key-description keys)
            :level (or (and curated (plist-get curated :level)) 1)
            :prompt (keydrill-observe--prompt command)))))

(defun keydrill-observe-gaps (&optional limit)
  "Return unused-binding gap plists, highest score first.
LIMIT defaults to `keydrill-observe-report-limit'.  Each plist
has :command, :score, :mx, :mouse, :menu, :binding, :prompt, and
:move.  Score is non-key count times live keyboard-binding length.
A gap is a command invoked via extended command, menu, or mouse
that has a keyboard binding in the current buffer."
  (let ((limit (or limit (keydrill-observe--limit)))
        (gaps nil))
    (dolist (entry keydrill-observe--counts)
      (let ((command (car entry)))
        (when (and (symbolp command) (not (keywordp command)))
          (let* ((methods (cdr entry))
                 (mx (keydrill-observe--method-total methods 'mx))
                 (mouse (keydrill-observe--method-total methods 'mouse))
                 (menu (keydrill-observe--method-total methods 'menu))
                 (not-key (+ mx mouse menu))
                 (move (and (> not-key 0)
                            (keydrill-observe--move-for-command command))))
            (when move
              (let* ((binding (plist-get move :key))
                     (keys (keydrill-observe--keyboard-keys
                            command
                            (if (and (boundp 'keydrill--launch-buffer)
                                     (buffer-live-p keydrill--launch-buffer))
                                keydrill--launch-buffer
                              (current-buffer))))
                     (nkeys (max 1 (length keys)))
                     (score (* not-key nkeys)))
                (push (list :command command
                            :score score
                            :mx mx
                            :mouse mouse
                            :menu menu
                            :binding binding
                            :prompt (plist-get move :prompt)
                            :move move)
                      gaps)))))))
    (setq gaps (sort gaps
                     (lambda (a b)
                       (> (plist-get a :score) (plist-get b :score)))))
    (if (> (length gaps) limit)
        (let ((cut nil)
              (i 0))
          (dolist (g gaps)
            (when (< i limit)
              (push g cut)
              (setq i (1+ i))))
          (nreverse cut))
      gaps)))

(defun keydrill-observe--via-text (gap)
  "Return the invocation phrase for GAP."
  (cond
   ((> (plist-get gap :mx) 0) "via M-x")
   ((> (plist-get gap :menu) 0) "from the menu")
   ((> (plist-get gap :mouse) 0) "with the mouse")
   (t "without its key")))

(defun keydrill-observe--gap-count (gap)
  "Return the non-key invocation count for GAP."
  (+ (plist-get gap :mx)
     (plist-get gap :mouse)
     (plist-get gap :menu)))

(defun keydrill-observe-format-gap (gap)
  "Return one report line for GAP."
  (format "you ran %s %d× %s; it's bound to %s"
          (plist-get gap :command)
          (keydrill-observe--gap-count gap)
          (keydrill-observe--via-text gap)
          (plist-get gap :binding)))

(defun keydrill-observe-format-report (gaps)
  "Return the full report string for GAPS."
  (if (null gaps)
      "No unused-binding gaps yet. Enable keydrill-observe-mode and use Emacs as usual.\n"
    (let ((out "Unused bindings (count × keys saved)\n\n")
          (n 0))
      (dolist (g gaps)
        (setq n (1+ n))
        (setq out (concat out
                          (format "%d  %s\n" n
                                  (keydrill-observe-format-gap g)))))
      (concat out "\n1-9 drills that row.  RET drills this line.  a drills all listed moves.  q buries this buffer.\n"))))

(defvar keydrill-report-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'keydrill-report-drill)
    (define-key map (kbd "a") #'keydrill-report-drill-all)
    (dotimes (i 9)
      (define-key map (format "%d" (1+ i)) #'keydrill-report-drill-digit))
    map)
  "Keymap for `keydrill-report-mode'.")

(define-derived-mode keydrill-report-mode special-mode "Keydrill-Report"
  "Major mode for the keydrill unused-binding report."
  (setq buffer-read-only t)
  (setq-local truncate-lines nil))

(defun keydrill-observe--start-gap-drill (moves source)
  "Start a recall-only gap drill.
MOVES is a list of move plists.  SOURCE is the launch buffer
for live-keymap resolution.  Does not run the session planner."
  (require 'keydrill-ui)
  (let ((buf (if (and source (buffer-live-p source))
                 source
               (current-buffer))))
    (with-current-buffer buf
      (keydrill-ui-start moves "gaps" moves))))

(defun keydrill-report-drill ()
  "Start a drill of the gap move on this line."
  (interactive)
  (let ((move (get-text-property (point) 'keydrill-gap-move)))
    (unless move
      (user-error "No gap move on this line"))
    (keydrill-observe--start-gap-drill
     (list move) keydrill-observe--source-buffer)))

(defun keydrill-report-drill-all ()
  "Start a drill of every gap listed in this report."
  (interactive)
  (let ((moves (get-text-property (point-min) 'keydrill-gap-moves)))
    (unless moves
      (user-error "No gap moves in this report"))
    (keydrill-observe--start-gap-drill
     moves keydrill-observe--source-buffer)))

(defun keydrill-report-drill-digit ()
  "Drill the numbered gap matching the key just typed."
  (interactive)
  (let* ((n (- last-command-event ?0))
         (gap (nth (1- n) keydrill-observe--report-gaps)))
    (unless gap
      (user-error "No gap numbered %d" n))
    (keydrill-observe--start-gap-drill
     (list (plist-get gap :move))
     keydrill-observe--source-buffer)))

(defun keydrill-observe--ensure-counts ()
  "Load observer counts from disk when memory is empty."
  (unless keydrill-observe--counts
    (keydrill-observe--load)))

;;;###autoload
(defun keydrill-report ()
  "Show unused-binding gaps from the usage observer.
Ranked by non-key invocations times live binding length.  RET
starts a drill of the move at point.  Digits 1-9 jump to that row."
  (interactive)
  (keydrill-observe--ensure-package)
  (require 'keydrill-ui)
  (keydrill-observe--ensure-counts)
  (let* ((source (current-buffer))
         (gaps (keydrill-observe-gaps))
         (moves (mapcar (lambda (g) (plist-get g :move)) gaps))
         (buf (get-buffer-create "*keydrill-report*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (keydrill-report-mode)
        (setq keydrill-observe--source-buffer source)
        (setq keydrill-observe--report-gaps gaps)
        (insert (propertize (keydrill-observe-format-report gaps)
                            'keydrill-gap-moves moves))
        (goto-char (point-min))
        (dolist (g gaps)
          (when (re-search-forward
                 (regexp-quote (keydrill-observe-format-gap g)) nil t)
            (add-text-properties
             (line-beginning-position) (line-end-position)
             (list 'keydrill-gap-move (plist-get g :move)))))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

(add-hook 'keydrill-store-before-save-functions
          #'keydrill-observe-overlay-store)
(add-hook 'keydrill-store-after-purge-functions
          #'keydrill-observe-reset)

(provide 'keydrill-observe)
;;; keydrill-observe.el ends here
