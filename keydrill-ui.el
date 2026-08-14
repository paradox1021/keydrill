;;; keydrill-ui.el --- Drill buffer, summary, and graduation  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Astrolabe Apps, Inc.

;; Author: Brendan Kavanaugh (Astrolabe Apps, Inc.) <Brendan@astrolabeapps.com>
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

;; Session loop and Emacs-native drill buffer.  The planner returns
;; intros and drilling recall; this module owns the queue, attempted /
;; first-try / latency lists, and whether a just-locked-in intro is
;; quizzed later (it is not: recall starts next session).  Capture
;; results are applied by pure functions so ERT can drive a session
;; without a tty.

;;; Code:

(require 'keydrill-engine)
(require 'keydrill-capture)
(require 'keydrill-store)
(require 'keydrill-live)
(require 'keydrill-journal)

(defvar keydrill-hit-pause-seconds 0.35
  "Seconds to pause after a hit before the next card.
Tests bind this to 0 so `sit-for' does not steal queued events.
Headless `keydrill-run-session' never pauses.")

(defconst keydrill-buffer-name "*keydrill*"
  "Name of the dedicated drill buffer.")

(defvar keydrill--launch-buffer nil
  "Buffer `keydrill' was invoked from, for a later live-keymap lookup.")

(defvar keydrill--window-config nil
  "Window configuration to restore when leaving the keydrill buffer.")

(defun keydrill--restore-windows ()
  "Restore `keydrill--window-config' when it is set."
  (when keydrill--window-config
    (set-window-configuration keydrill--window-config)
    (setq keydrill--window-config nil)))

(defun keydrill-quit-window (&optional kill)
  "Leave the keydrill buffer and restore the previous window layout.
If no layout was saved, pass KILL to `quit-window'."
  (interactive "P")
  (if (null keydrill--window-config)
      (quit-window kill)
    (let ((buf (current-buffer)))
      (keydrill--restore-windows)
      (when (and (buffer-live-p buf)
                 (not (eq (current-buffer) buf)))
        (bury-buffer buf)))))

(defvar keydrill-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'keydrill-quit-window)
    map)
  "Keymap for `keydrill-mode'.")

(defface keydrill-prompt
  '((t :inherit default :height 1.15))
  "Face for the situation prompt.")

(defface keydrill-key
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for a shown key binding.")

(defface keydrill-ok
  '((t :inherit success))
  "Face for a correct-answer line.")

(defface keydrill-bad
  '((t :inherit error))
  "Face for a miss line.")

(defface keydrill-muted
  '((t :inherit shadow))
  "Face for secondary session text.")

(define-derived-mode keydrill-mode special-mode "Keydrill"
  "Major mode for a keydrill session buffer.

During a card, keys are read by `keydrill-read-answer', not this
map.  After the summary, `q' restores the previous windows."
  (setq buffer-read-only t)
  (buffer-disable-undo)
  (setq-local truncate-lines nil)
  (setq-local cursor-type nil)
  (visual-line-mode 1))

;;; Session state

(defun keydrill--sess (session &rest plist)
  "Return a copy of SESSION with PLIST keys replaced.
SESSION is a plist.  PLIST is alternating keys and values.
Does not mutate SESSION."
  (let ((s (copy-sequence session)))
    (while plist
      (let ((k (pop plist))
            (v (pop plist)))
        (setq s (plist-put s k v))))
    s))

(defun keydrill--move-expected-key (move)
  "Return the key string to show and score for MOVE.
Uses `:expected-key' from live resolution when present."
  (or (plist-get move :expected-key)
      (plist-get move :key)))

(defun keydrill--session-apply-live (session &optional buffer)
  "Return SESSION with live-resolved copies in the queue.
BUFFER is the launch buffer passed to `keydrill-live-resolve-deck'.
Skipped moves are dropped.  `:total' and `:intro-count' are updated.
The planner already ran on the original deck ids and levels."
  (let* ((resolved (keydrill-live-resolve-deck
                    (plist-get session :deck) buffer))
         (by-id (make-hash-table :test 'equal)))
    (dolist (m resolved)
      (puthash (plist-get m :id) m by-id))
    (let (new-queue
          (intro-count 0))
      (dolist (item (plist-get session :queue))
        (let* ((old (plist-get item :move))
               (id (plist-get old :id))
               (new-move (gethash id by-id)))
          (when (and new-move (not (plist-get new-move :skipped)))
            (let ((new-item (copy-sequence item)))
              (setq new-item (plist-put new-item :move new-move))
              (push new-item new-queue)
              (when (plist-get new-item :intro)
                (setq intro-count (1+ intro-count)))))))
      (setq new-queue (nreverse new-queue))
      (keydrill--sess session
                      :queue new-queue
                      :total (length new-queue)
                      :intro-count intro-count))))

(defun keydrill--queue-item (move intro first-try)
  "Return a queue item for MOVE.
INTRO non-nil means a teach card.  FIRST-TRY non-nil means this
recall presentation may count toward accuracy."
  (list :move move :intro intro :first-try first-try))

(defun keydrill--build-queue (deck store shuffle-fn)
  "Return the session queue for DECK and STORE.
SHUFFLE-FN is passed to the planner.

Intros come first as teach cards.  Recall is the planner's
drilling list only.  Just-locked-in intros are not quizzed until
a later session."
  (let* ((plan (keydrill-session-plan deck store shuffle-fn))
         (intro-items (mapcar (lambda (m)
                                (keydrill--queue-item m t nil))
                              (plist-get plan :intros)))
         (recall-items (mapcar (lambda (m)
                                 (keydrill--queue-item m nil t))
                               (plist-get plan :recall))))
    (append intro-items recall-items)))

(defun keydrill--session-make (deck deck-id store &optional shuffle-fn moves)
  "Return a new session plist for DECK identified by DECK-ID.
STORE is the loaded progress plist.  SHUFFLE-FN nil uses
`keydrill-shuffle'.  Tests pass `identity' for a stable queue.

If MOVES is non-nil, the queue is those moves as first-try recall
cards and the planner is not used.  SHUFFLE-FN is ignored.  The
session :deck becomes MOVES so live-keymap resolution walks the
same list."
  (let* ((deck (or moves deck))
         (queue (if moves
                    (mapcar (lambda (m)
                              (keydrill--queue-item m nil t))
                            moves)
                  (keydrill--build-queue deck store shuffle-fn))))
    (list :store store
          :deck deck
          :deck-id deck-id
          :queue queue
          :current nil
          :last nil
          :missed nil
          :total (length queue)
          :done 0
          :attempted 0
          :first-try 0
          :requeued 0
          :intro-count (let ((n 0))
                         (dolist (it queue)
                           (when (plist-get it :intro)
                             (setq n (1+ n))))
                         n)
          :intro-done 0
          :lats nil
          :aborted nil
          :feedback nil
          :feedback-ok nil
          :show-answer nil)))

(defun keydrill--session-item (session)
  "Return SESSION's current queue item, or the last one after a hit."
  (or (plist-get session :current)
      (plist-get session :last)))

(defun keydrill--session-ensure-current (session)
  "Return SESSION with :current set from the queue when needed.
Showing an intro card marks the move `learning'.  If :current is
already set, SESSION is returned unchanged."
  (if (plist-get session :current)
      session
    (let ((q (plist-get session :queue)))
      (if (null q)
          (keydrill--sess session :current nil)
        (let* ((item (car q))
               (id (plist-get (plist-get item :move) :id))
               (store (plist-get session :store))
               (store (if (plist-get item :intro)
                          (keydrill-mark-learning store id)
                        store)))
          (keydrill--sess session
                          :store store
                          :queue (cdr q)
                          :current item
                          :missed nil
                          :feedback nil
                          :feedback-ok nil
                          :show-answer nil))))))

(defun keydrill--miss-text (result intro already)
  "Return feedback for a miss RESULT.
INTRO non-nil means a teach card.  ALREADY non-nil means this
card has already missed once."
  (let ((status (plist-get result :status))
        (got (plist-get result :got))
        (msg (plist-get result :message)))
    (cond
     ((and (eq status 'timeout) msg)
      msg)
     ((eq status 'timeout)
      "sequence timed out — start it again")
     (intro
      (if got
          (format "you pressed %s — press the keys shown" got)
        "press the keys shown"))
     (already
      "try again")
     (got
      (format "you pressed %s" got))
     (t
      "not it"))))

(defun keydrill--session-abort (session)
  "Return SESSION marked aborted, with no current card."
  (keydrill--sess session
                  :aborted t
                  :current nil
                  :feedback "Session ended. Progress saved."
                  :feedback-ok nil))

(defun keydrill--session-apply (session result)
  "Return SESSION after applying capture RESULT.
RESULT is a plist from `keydrill-read-answer' with at least
:status and :latency.  Does not mutate SESSION.  Quit does not
call `keydrill-apply-session'."
  (let* ((status (plist-get result :status))
         (lat (or (plist-get result :latency) 0))
         (item (plist-get session :current))
         (intro (and item (plist-get item :intro)))
         (first-try (and item (plist-get item :first-try)))
         (move (and item (plist-get item :move)))
         (id (and move (plist-get move :id)))
         (store (plist-get session :store))
         (missed (plist-get session :missed)))
    (cond
     ((or (null item) (eq status 'quit))
      (keydrill--session-abort session))
     (intro
      (if (eq status 'hit)
          (keydrill--sess session
                          :store (keydrill-mark-drilling store id)
                          :current nil
                          :last item
                          :done (1+ (plist-get session :done))
                          :intro-done (1+ (plist-get session :intro-done))
                          :missed nil
                          :feedback "locked in"
                          :feedback-ok t
                          :show-answer nil)
        (keydrill--sess session
                        :missed t
                        :feedback (keydrill--miss-text result t nil)
                        :feedback-ok nil
                        :show-answer t)))
     ((eq status 'hit)
      (let* ((first (and first-try (not missed)))
             (store (if first
                        (keydrill-record-recall store id t lat)
                      (keydrill-touch-last-seen store id)))
             (lats (plist-get session :lats))
             (lats (if (and first (< lat keydrill-latency-interrupt-ms))
                       (cons lat lats)
                     lats)))
        (keydrill--sess session
                        :store store
                        :current nil
                        :last item
                        :done (1+ (plist-get session :done))
                        :attempted (if first
                                       (1+ (plist-get session :attempted))
                                     (plist-get session :attempted))
                        :first-try (if first
                                       (1+ (plist-get session :first-try))
                                     (plist-get session :first-try))
                        :lats lats
                        :missed nil
                        :feedback (if first
                                      (format "first try · %d ms" lat)
                                    (format "got it · %d ms" lat))
                        :feedback-ok t
                        :show-answer nil)))
     (t
      (if missed
          (keydrill--sess session
                          :feedback (keydrill--miss-text result nil t)
                          :feedback-ok nil
                          :show-answer t)
        (let* ((copy (keydrill--queue-item move nil nil))
               (q (append (plist-get session :queue) (list copy)))
               (sample first-try)
               (store (if sample
                          (keydrill-record-recall store id nil 0)
                        store)))
          (keydrill--sess session
                          :store store
                          :queue q
                          :missed t
                          :requeued (1+ (plist-get session :requeued))
                          :attempted (if sample
                                         (1+ (plist-get session :attempted))
                                       (plist-get session :attempted))
                          :feedback (keydrill--miss-text result nil nil)
                          :feedback-ok nil
                          :show-answer t)))))))

(defun keydrill--result-from-session (session)
  "Return the `keydrill-run-session' result plist for SESSION."
  (list :store (plist-get session :store)
        :quit (plist-get session :aborted)
        :introduced (plist-get session :intro-done)
        :attempted (plist-get session :attempted)
        :first-try (plist-get session :first-try)
        :lats (plist-get session :lats)
        :requeued (plist-get session :requeued)))

(defun keydrill--session-loop (session &optional display)
  "Run SESSION until the queue is empty or the user quits.
DISPLAY, if given, is a function of one session argument.  It is
called after a card is selected and again after each answer.
Does not write the progress file."
  (catch 'keydrill-session-over
    (while t
      (setq session (keydrill--session-ensure-current session))
      (when (or (plist-get session :aborted)
                (null (plist-get session :current)))
        (throw 'keydrill-session-over session))
      (when display
        (funcall display session))
      (let* ((start (float-time))
             (item (plist-get session :current))
             (move (plist-get item :move))
             (res (keydrill-read-answer
                   (keydrill--move-expected-key move) start)))
        ;; A quit is not an attempt; the end record carries the abort.
        (unless (eq (plist-get res :status) 'quit)
          (keydrill-journal-log-answer
           (plist-get session :deck-id) move
           (if (plist-get item :intro) 'intro 'recall) res))
        (setq session (keydrill--session-apply session res))
        (when display
          (funcall display session))
        (when (plist-get session :aborted)
          (throw 'keydrill-session-over session))
        (when (and display
                   (not noninteractive)
                   (eq (plist-get res :status) 'hit)
                   (> keydrill-hit-pause-seconds 0))
          (sit-for keydrill-hit-pause-seconds)
          (discard-input)))))
  session)

(defun keydrill-run-session (store deck &optional shuffle-fn)
  "Run a headless session on DECK starting from STORE.
SHUFFLE-FN is passed to the planner; nil uses `keydrill-shuffle'.

Calls `keydrill-read-answer' once per card.  Return a plist:
:store, :quit, :introduced, :attempted, :first-try, :lats, and
:requeued.  Does not write the progress file and does not call
`keydrill-apply-session'."
  (keydrill-capture-reset)
  (keydrill--result-from-session
   (keydrill--session-loop
    (keydrill--session-make deck "session" store shuffle-fn))))

(defun keydrill-finish-session (store deck-id deck-size result)
  "Return STORE with RESULT applied for DECK-ID, or STORE on quit.
DECK-SIZE is the number of moves in the full deck.  RESULT is a
plist from `keydrill-run-session'.  Quit does not append pass
dates.  Accuracy and median come from the engine."
  (if (plist-get result :quit)
      store
    (let ((acc (keydrill-accuracy (plist-get result :first-try)
                                  (plist-get result :attempted)))
          (med (keydrill-median (plist-get result :lats))))
      (keydrill-apply-session store deck-id acc med
                              (plist-get result :attempted)
                              deck-size))))

(defun keydrill--summary-stats (result store deck-id deck-size)
  "Return summary fields for RESULT against STORE.
DECK-ID and DECK-SIZE identify the deck.  RESULT is a plist from
`keydrill-run-session'."
  (let* ((acc (keydrill-accuracy (plist-get result :first-try)
                                 (plist-get result :attempted)))
         (med (keydrill-median (plist-get result :lats)))
         (rec (keydrill-deck-record store deck-id))
         (dates (and rec (plist-get rec :pass-dates))))
    (list :attempted (plist-get result :attempted)
          :first-try (plist-get result :first-try)
          :accuracy acc
          :median med
          :introduced (or (plist-get result :introduced) 0)
          :pass (keydrill-session-pass-p acc med
                                         (plist-get result :attempted)
                                         deck-size)
          :graduated (keydrill-deck-graduated-p store deck-id)
          :pass-dates (length dates)
          :deck-size deck-size
          :deck-name (if (equal deck-id "emacs") "Emacs" deck-id))))

(defun keydrill-format-graduation ()
  "Return the graduation screen text."
  "Graduated\n\nTwo distinct local days at graduation pace.")

(defun keydrill-format-summary (stats)
  "Return a session summary string for STATS.
STATS is a plist with :accuracy, :median, :introduced, :pass,
:graduated, :pass-dates, :deck-size, :deck-name, :attempted, and
:first-try.  :pass-dates may be a count or a list of day strings.
Target numbers are the engine constants, not a second copy of the
bar.  :pass is whatever `keydrill-session-pass-p' returned."
  (let* ((acc (or (plist-get stats :accuracy) 0))
         (med (or (plist-get stats :median) 0))
         (introduced (or (plist-get stats :introduced) 0))
         (attempted (or (plist-get stats :attempted) 0))
         (first-try (or (plist-get stats :first-try) 0))
         (pass (plist-get stats :pass))
         (grad (plist-get stats :graduated))
         (dates (plist-get stats :pass-dates))
         (n (if (numberp dates) dates (length dates)))
         (size (or (plist-get stats :deck-size) 0))
         (name (or (plist-get stats :deck-name) "Deck"))
         (pace-if-covered (keydrill-session-pass-p acc med size size)))
    (concat
     (format "%s deck - session complete\n\n" name)
     (format "Recall attempted: %d\n" attempted)
     (format "First-try hits: %d\n" first-try)
     (format "First-try accuracy (recall only): %d%% (need >= %d%%)\n"
             acc keydrill-pass-min-accuracy)
     ;; A zero median means no sample survived, not an instant answer:
     ;; latencies at or above `keydrill-latency-interrupt-ms' are
     ;; discarded as interruptions.  Saying "0 ms" would read as
     ;; clearing the speed bar when the session in fact cannot pass it.
     (if (> med 0)
         (format "Median first-try latency: %d ms (need < %d ms)\n"
                 med keydrill-pass-max-median)
       (format "Median first-try latency: no timed answers, every one took over %d s (need < %d ms)\n"
               (/ keydrill-latency-interrupt-ms 1000)
               keydrill-pass-max-median))
     (format "Introduced this session: %d\n" introduced)
     (format "Graduation pace: %s\n" (if pass "yes" "no"))
     (format "Pass dates: %d / 2\n" n)
     (format "Deck graduated: %s\n\n" (if grad "yes" "no"))
     (cond
      (grad
       (concat (keydrill-format-graduation) "\n"))
      (pass
       (if (>= n 2)
           "Graduation pace held.  The deck has two distinct pass dates.\n"
         (format "Graduation pace - day %d of 2.  A second separate local day at this bar completes the deck.\n"
                 n)))
      ((zerop attempted)
       (format "Intro session - %d move%s locked in.  Recall stats start next session.\n"
               introduced (if (= introduced 1) "" "s")))
      ((and pace-if-covered (< attempted size))
       (format "Accuracy and median meet the bar, but a graduation day needs every move in the deck recalled this session (attempted %d, deck %d).\n"
               attempted size))
      (t
       "Below graduation pace.  Accuracy and median use recall first presentations only; intro cards are excluded.\n")))))

(defun keydrill-card-text (move kind)
  "Return the prompt text for MOVE.
KIND is `intro' or `recall'.  The binding is omitted here; the
drill buffer shows keys on an intro card and after a recall miss."
  (format "%s\n\n%s\nlevel %s"
          (if (eq kind 'intro) "Intro" "Recall")
          (or (plist-get move :prompt) "")
          (or (plist-get move :level) "")))

;;; Rendering

(defun keydrill--erase ()
  "Erase the current buffer, ignoring read-only."
  (let ((inhibit-read-only t))
    (erase-buffer)))

(defun keydrill--insert (text &optional face)
  "Insert TEXT at point.
If FACE is non-nil, apply it to TEXT."
  (if face
      (insert (propertize text 'face face))
    (insert text)))

(defun keydrill--render-text (text)
  "Replace the current buffer with TEXT."
  (keydrill--erase)
  (let ((inhibit-read-only t))
    (insert text)
    (goto-char (point-min))))

(defun keydrill--render-card (session)
  "Replace the current buffer with the drill card for SESSION."
  (let* ((item (keydrill--session-item session))
         (move (and item (plist-get item :move)))
         (intro (and item (plist-get item :intro)))
         (show (or intro (plist-get session :show-answer)))
         (done (plist-get session :done))
         (total (plist-get session :total))
         (requeued (plist-get session :requeued))
         (denom (+ total requeued))
         (feedback (plist-get session :feedback))
         (kind (if intro 'intro 'recall)))
    (keydrill--erase)
    (let ((inhibit-read-only t))
      (keydrill--insert "keydrill" 'keydrill-muted)
      (insert "\n\n")
      (when move
        (keydrill--insert
         (format "%d / %d\n\n"
                 (if (plist-get session :current) (1+ done) done)
                 denom)
         'keydrill-muted)
        (keydrill--insert (keydrill-card-text move kind) 'keydrill-prompt)
        (insert "\n\n")
        (let ((note (plist-get move :binding-note)))
          (when note
            (keydrill--insert note 'keydrill-muted)
            (insert "\n\n")))
        (when show
          (keydrill--insert (if intro "Keys: " "Answer: ") 'keydrill-muted)
          (keydrill--insert (keydrill--move-expected-key move) 'keydrill-key)
          (insert "\n\n"))
        (when feedback
          (keydrill--insert feedback
                            (if (plist-get session :feedback-ok)
                                'keydrill-ok
                              'keydrill-bad))
          (insert "\n\n")))
      (keydrill--insert
       "q quits.  Two keyboard-quit chords within 1s also quit."
       'keydrill-muted)
      (goto-char (point-min)))))

(defun keydrill--render-aborted (session)
  "Replace the current buffer with an abort screen for SESSION."
  (keydrill--render-text
   (format "keydrill — session ended\n\nNew moves locked in: %d\nRecall presentations: %d\n\nProgress saved.  q closes this buffer."
           (plist-get session :intro-done)
           (plist-get session :attempted))))

;;; Interactive entry

(defun keydrill-ui-start (deck deck-id &optional moves)
  "Start a drill session on DECK identified by DECK-ID.
DECK is a list of move plists.  Progress is loaded and saved
through `keydrill-store-load' and `keydrill-store-save'.

If MOVES is non-nil, the queue is those moves as recall cards
instead of a planned intro/recall mix.  `M-x keydrill' does not
pass MOVES.

A quit (`q', or two `keyboard-quit' chords within 1s) saves lock-ins
already made and does not increment the deck session count.
Remembers `current-buffer' in `keydrill--launch-buffer'.

Live-keymap resolution runs against that launch buffer *before*
switching to the drill buffer, whose map is not the user's."
  (setq keydrill--launch-buffer (current-buffer))
  (unless keydrill--window-config
    (setq keydrill--window-config (current-window-configuration)))
  (let* ((store (keydrill-store-load))
         (session (keydrill--session-make deck deck-id store nil moves))
         (session (keydrill--session-apply-live
                   session keydrill--launch-buffer))
         (buf (get-buffer-create keydrill-buffer-name))
         (keydrill-journal--session-id
          (keydrill-journal-new-session-id 'drill)))
    (unless (plist-get session :queue)
      (user-error "Nothing to drill"))
    (keydrill-journal-log-begin 'drill deck-id (plist-get session :total))
    (keydrill-capture-reset)
    (switch-to-buffer buf)
    (keydrill-mode)
    (setq session
          (keydrill--session-loop
           session
           (lambda (s)
             (keydrill-store-save (plist-get s :store))
             (keydrill--render-card s)
             (redisplay t))))
    (keydrill-journal-log-end (not (plist-get session :aborted)))
    (if (plist-get session :aborted)
        (progn
          (keydrill-store-save (plist-get session :store))
          (keydrill--render-aborted session)
          (message "Session ended. Progress saved."))
      (let* ((result (keydrill--result-from-session session))
             (size (length (or moves deck)))
             (store (keydrill-finish-session
                     (plist-get session :store)
                     deck-id size result))
             (stats (keydrill--summary-stats
                     result store deck-id size)))
        (keydrill-store-save store)
        (keydrill--render-text (keydrill-format-summary stats))
        (message "Session complete.")))
    session))

(provide 'keydrill-ui)
;;; keydrill-ui.el ends here
