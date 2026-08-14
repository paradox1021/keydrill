;;; keydrill-deck-emacs.el --- Curated Emacs fallback deck for keydrill  -*- lexical-binding: t; -*-

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

;; Curated deck of 85 vanilla GNU Emacs moves across 7 levels.
;; :key holds the *vanilla default* binding in `kbd' notation and is
;; only a fallback -- at runtime, keydrill resolves each :command
;; against the user's live keymap via `where-is-internal' and prefers
;; the user's actual binding.
;;
;; Vanilla keys are checked against `global-map' in
;; `test/keydrill-deck-test.el' (GNU Emacs -Q).

;;; Code:

(defconst keydrill-deck-emacs
  '(
    (:id "emacs.cancel" :command keyboard-quit :key "C-g" :level 1
     :prompt "A prompt you never meant to open is blinking in the minibuffer — bail out of it")
    (:id "emacs.find-file" :command find-file :key "C-x C-f" :level 1
     :prompt "Open notes.txt for editing without touching a menu")
    (:id "emacs.save" :command save-buffer :key "C-x C-s" :level 1
     :prompt "Write the buffer you are editing to disk")
    (:id "emacs.quit" :command save-buffers-kill-terminal :key "C-x C-c" :level 1
     :prompt "You are done for the day — leave Emacs entirely")
    (:id "emacs.fwd-char" :command forward-char :key "C-f" :level 1
     :prompt "Nudge the cursor one character to the right")
    (:id "emacs.back-char" :command backward-char :key "C-b" :level 1
     :prompt "Nudge the cursor one character to the left")
    (:id "emacs.next-line" :command next-line :key "C-n" :level 1
     :prompt "Drop the cursor down one line")
    (:id "emacs.prev-line" :command previous-line :key "C-p" :level 1
     :prompt "Lift the cursor up one line")
    (:id "emacs.run-command" :command execute-extended-command :key "M-x" :level 1
     :prompt "Run any Emacs command by typing its full name")
    (:id "emacs.line-start" :command move-beginning-of-line :key "C-a" :level 2
     :prompt "Jump to the very beginning of the current line")
    (:id "emacs.line-end" :command move-end-of-line :key "C-e" :level 2
     :prompt "Jump to the end of the current line")
    (:id "emacs.fwd-word" :command forward-word :key "M-f" :level 2
     :prompt "Skip forward over the next word")
    (:id "emacs.back-word" :command backward-word :key "M-b" :level 2
     :prompt "Skip back over the previous word")
    (:id "emacs.buffer-start" :command beginning-of-buffer :key "M-<" :level 2
     :prompt "Leap to the very top of the buffer")
    (:id "emacs.buffer-end" :command end-of-buffer :key "M->" :level 2
     :prompt "Leap to the very bottom of the buffer")
    (:id "emacs.page-down" :command scroll-up-command :key "C-v" :level 2
     :prompt "Scroll one screenful ahead in a long file")
    (:id "emacs.page-up" :command scroll-down-command :key "M-v" :level 2
     :prompt "Scroll one screenful back the way you came")
    (:id "emacs.recenter" :command recenter-top-bottom :key "C-l" :level 2
     :prompt "Pull the line you are on to the middle of the screen")
    (:id "emacs.delete-char" :command delete-char :key "C-d" :level 2
     :prompt "Delete the character sitting under the cursor")
    (:id "emacs.undo" :command undo :key "C-/" :level 2
     :prompt "Take back the edit you just made")
    (:id "emacs.set-mark" :command set-mark-command :key "C-SPC" :level 3
     :prompt "Drop the mark here to start selecting a region")
    (:id "emacs.kill-region" :command kill-region :key "C-w" :level 3
     :prompt "Kill the region between mark and cursor")
    (:id "emacs.copy-region" :command kill-ring-save :key "M-w" :level 3
     :prompt "Copy the region to the kill ring without deleting it")
    (:id "emacs.yank" :command yank :key "C-y" :level 3
     :prompt "Paste back the last thing you killed")
    (:id "emacs.yank-pop" :command yank-pop :key "M-y" :level 3
     :prompt "That yank pasted the wrong thing — cycle to an earlier kill")
    (:id "emacs.kill-line" :command kill-line :key "C-k" :level 3
     :prompt "Kill from the cursor to the end of the line")
    (:id "emacs.kill-word" :command kill-word :key "M-d" :level 3
     :prompt "Kill the word ahead of the cursor")
    (:id "emacs.kill-word-back" :command backward-kill-word :key "M-DEL" :level 3
     :prompt "Erase the word you just mistyped, behind the cursor")
    (:id "emacs.isearch-fwd" :command isearch-forward :key "C-s" :level 3
     :prompt "Hunt forward for a word as you type it")
    (:id "emacs.isearch-back" :command isearch-backward :key "C-r" :level 3
     :prompt "Hunt backward for something you passed earlier")
    (:id "emacs.query-replace" :command query-replace :key "M-%" :level 3
     :prompt "Replace one word with another, approving each occurrence")
    (:id "emacs.swap-point-mark" :command exchange-point-and-mark :key "C-x C-x" :level 3
     :prompt "Bounce back to where the region started")
    (:id "emacs.select-all" :command mark-whole-buffer :key "C-x h" :level 3
     :prompt "Select the entire buffer in one motion")
    (:id "emacs.switch-buffer" :command switch-to-buffer :key "C-x b" :level 4
     :prompt "Flip to another open buffer by name")
    (:id "emacs.kill-buffer" :command kill-buffer :key "C-x k" :level 4
     :prompt "Close the buffer you are done with")
    (:id "emacs.list-buffers" :command list-buffers :key "C-x C-b" :level 4
     :prompt "See every buffer you have open, in a list")
    (:id "emacs.split-below" :command split-window-below :key "C-x 2" :level 4
     :prompt "Split the frame into two windows, stacked")
    (:id "emacs.split-right" :command split-window-right :key "C-x 3" :level 4
     :prompt "Split the frame into two windows, side by side")
    (:id "emacs.other-window" :command other-window :key "C-x o" :level 4
     :prompt "Hop the cursor into the other window")
    (:id "emacs.close-window" :command delete-window :key "C-x 0" :level 4
     :prompt "Close the window you are in, keeping the rest")
    (:id "emacs.close-others" :command delete-other-windows :key "C-x 1" :level 4
     :prompt "Collapse every split back to a single window")
    (:id "emacs.describe-key" :command describe-key :key "C-h k" :level 4
     :prompt "Ask Emacs what a mystery keystroke actually does")
    (:id "emacs.describe-function" :command describe-function :key "C-h f" :level 4
     :prompt "Read the full documentation for a command by name")
    (:id "emacs.describe-variable" :command describe-variable :key "C-h v" :level 4
     :prompt "Check what a setting is and what it is currently set to")
    (:id "emacs.apropos" :command apropos-command :key "C-h a" :level 4
     :prompt "Find every command related to a keyword like 'rectangle'")
    (:id "emacs.tutorial" :command help-with-tutorial :key "C-h t" :level 4
     :prompt "Open the built-in interactive tutorial")
    (:id "emacs.sentence-start" :command backward-sentence :key "M-a" :level 5
     :prompt "Jump to the start of the sentence you are in")
    (:id "emacs.sentence-end" :command forward-sentence :key "M-e" :level 5
     :prompt "Jump to the end of the sentence you are in")
    (:id "emacs.kill-sentence" :command kill-sentence :key "M-k" :level 5
     :prompt "Kill from the cursor to the end of the sentence")
    (:id "emacs.back-paragraph" :command backward-paragraph :key "M-{" :level 5
     :prompt "Jump up to the start of the previous paragraph")
    (:id "emacs.fwd-paragraph" :command forward-paragraph :key "M-}" :level 5
     :prompt "Jump down past the end of this paragraph")
    (:id "emacs.mark-paragraph" :command mark-paragraph :key "M-h" :level 5
     :prompt "Select the whole paragraph around the cursor")
    (:id "emacs.transpose-chars" :command transpose-chars :key "C-t" :level 5
     :prompt "You typed 'teh' — fix it from right after the h")
    (:id "emacs.transpose-words" :command transpose-words :key "M-t" :level 5
     :prompt "Drag a word past its neighbor to fix the order")
    (:id "emacs.upcase-word" :command upcase-word :key "M-u" :level 5
     :prompt "Make the word ahead of the cursor ALL CAPS")
    (:id "emacs.downcase-word" :command downcase-word :key "M-l" :level 5
     :prompt "Drop the word ahead of the cursor to lowercase")
    (:id "emacs.capitalize-word" :command capitalize-word :key "M-c" :level 5
     :prompt "Capitalize the word ahead of the cursor")
    (:id "emacs.goto-line" :command goto-line :key "M-g g" :level 5
     :prompt "The compiler says the error is on line 247 — go there")
    (:id "emacs.comment-dwim" :command comment-dwim :key "M-;" :level 5
     :prompt "Comment out the selected region of code")
    (:id "emacs.refill" :command fill-paragraph :key "M-q" :level 5
     :prompt "Re-wrap a mangled paragraph to a tidy fill width")
    (:id "emacs.indent-line" :command indent-for-tab-command :key "TAB" :level 5
     :prompt "Snap the current line to its correct indentation")
    (:id "emacs.dabbrev" :command dabbrev-expand :key "M-/" :level 5
     :prompt "Finish typing a long identifier you have used before")
    (:id "emacs.prefix-arg" :command universal-argument :key "C-u" :level 5
     :prompt "Move down exactly 8 lines by giving the motion a count first")
    (:id "emacs.macro-start" :command kmacro-start-macro-or-insert-counter :key "<f3>" :level 6
     :prompt "Start recording every keystroke as a macro")
    (:id "emacs.macro-stop" :command kmacro-end-or-call-macro :key "<f4>" :level 6
     :prompt "Stop recording, then replay the macro on the next line")
    (:id "emacs.macro-replay" :command kmacro-end-and-call-macro :key "C-x e" :level 6
     :prompt "Replay the last macro the classic way")
    (:id "emacs.dired" :command dired :key "C-x d" :level 6
     :prompt "Browse a directory's files without leaving the editor")
    (:id "emacs.shell-command" :command shell-command :key "M-!" :level 6
     :prompt "Run one shell command and see its output in Emacs")
    (:id "emacs.async-shell" :command async-shell-command :key "M-&" :level 6
     :prompt "Kick off a long-running shell command in the background")
    (:id "emacs.bookmark-set" :command bookmark-set :key "C-x r m" :level 6
     :prompt "Mark this spot in the file so you can find it next week")
    (:id "emacs.bookmark-jump" :command bookmark-jump :key "C-x r b" :level 6
     :prompt "Jump to a bookmark you set days ago")
    (:id "emacs.bookmark-list" :command bookmark-bmenu-list :key "C-x r l" :level 6
     :prompt "Review everything you have bookmarked, in one list")
    (:id "emacs.isearch-regexp" :command isearch-forward-regexp :key "C-M-s" :level 6
     :prompt "Search forward with a regular expression instead of plain text")
    (:id "emacs.register-point" :command point-to-register :key "C-x r SPC" :level 7
     :prompt "Park your exact position in register A before wandering off")
    (:id "emacs.register-jump" :command jump-to-register :key "C-x r j" :level 7
     :prompt "Return to the position you parked in register A")
    (:id "emacs.register-copy" :command copy-to-register :key "C-x r s" :level 7
     :prompt "Stash the region in register A for safekeeping")
    (:id "emacs.register-insert" :command insert-register :key "C-x r i" :level 7
     :prompt "Drop the text stashed in register A back into the buffer")
    (:id "emacs.query-replace-regexp" :command query-replace-regexp :key "C-M-%" :level 7
     :prompt "Replace with a regexp pattern, approving each match")
    (:id "emacs.repeat" :command repeat :key "C-x z" :level 7
     :prompt "Do that last command again, whatever it was")
    (:id "emacs.upcase-region" :command upcase-region :key "C-x C-u" :level 7
     :prompt "Make the whole selected region ALL CAPS")
    (:id "emacs.downcase-region" :command downcase-region :key "C-x C-l" :level 7
     :prompt "Drop the whole selected region to lowercase")
    (:id "emacs.indent-region" :command indent-region :key "C-M-\\" :level 7
     :prompt "Reindent the whole region after a messy paste")
    (:id "emacs.back-to-indentation" :command back-to-indentation :key "M-m" :level 7
     :prompt "Land on the first real character of the line, not column zero")
    (:id "emacs.comment-line" :command comment-line :key "C-x C-;" :level 7
     :prompt "Toggle a comment on just the current line")
    (:id "emacs.write-file" :command write-file :key "C-x C-w" :level 7
     :prompt "Save the buffer under a brand-new filename"))
  "Curated Emacs deck: plist per move.
:id      stable string id (kept from web deck for cross-referencing)
:command the Emacs command symbol (source of truth for live-keymap mode)
:key     vanilla default binding, `kbd' notation (fallback display only)
:level   1-7 difficulty tier
:prompt  situational recall prompt shown to the player")

(provide 'keydrill-deck-emacs)
;;; keydrill-deck-emacs.el ends here
