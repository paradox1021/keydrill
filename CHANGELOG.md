# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-08-16

Measurement release. The package can now record what it teaches, so a
before-and-after is possible instead of an impression.

### Added

- **Append-only answer journal** (`keydrill-journal.eld`): one readable sexp
  per answered card across drills and benchmarks, with session begin/end
  markers recording mode, deck, deck size, Emacs version, and whether the
  session ran in a GUI or a terminal.  Local file, no keystroke content.
  `M-x keydrill-journal-purge` deletes it; set `keydrill-journal-file` to nil
  to disable journaling entirely.  The aggregate store cannot reconstruct
  per-binding latency over time; this can.
- **`M-x keydrill-benchmark`**: a cold recall pass over the full 85-move deck,
  live-resolved, in deck order for week-over-week comparability.  No answers
  shown, no requeue, and the progress store is never written — a measurement,
  not a lesson, with a regression test asserting the store file is not created.
  The summary reports cold hit rate, median hit latency, and the five slowest
  moves.  Quitting early journals the pass honestly as incomplete.
  Run it once before habitual drilling starts — that baseline is unrepeatable —
  and weekly thereafter under identical conditions.
- **`keydrill-text-scale`** (default 0): text-scale steps applied to the drill
  buffer only, leaving the rest of Emacs untouched.  Each step is roughly a 20%
  size change; 3 is comfortably large.  Added for legibility on high-resolution
  displays and for screen recording.

### Changed

- `M-x keydrill` sessions now journal one answer record per card.  Quits are
  excluded from answer records; the session end marker carries the abort.
- Manual test helpers write to throwaway journals so they cannot pollute real
  progress data.

### Verified

- ERT suite at 122 tests, byte-compilation clean with warnings as errors, and
  `package-lint` and `checkdoc` silent.
- `grep -rn "url-retrieve\|url\.el\|request" *.el` returns nothing.

## [0.1.0] - 2026-08-14

Initial public release under GPL-3.0-or-later.

### Added

- Package skeleton: modules, Makefile, CI, and load-only ERT tests (M1).
- Move lifecycle, session planner, scoring, and `.eld` store round-trip (M2).
- `SPEC.md` describing those engine rules in prose.
- Key capture: `read-event` scoring, landmine chords, sequence timeout, and
  terminal/GUI normalization (M3).
- Drill buffer, session loop on the curated Emacs deck, summary, and
  graduation (`M-x keydrill`) (M4).
- Live-keymap resolution at session start: drill the launch buffer's binding
  when the vanilla default is no longer live; unbound commands skip or score
  `M-x` per `keydrill-unbound-strategy` (M5).
- Opt-in usage observer and unused-binding report (`M-x keydrill-observe-mode`,
  `M-x keydrill-report`) (M6).
- README, MELPA recipe, deck vanilla-key ERT against `global-map`, and live
  lookup skipping menu-bar, mouse, and GUI events such as `<open>` (M7).

### Fixed

Found on 2026-08-13 by playing real sessions in GUI Emacs and `emacs -nw` on
GNU Emacs 30.2 — neither was reachable by the 114 ERT tests in the suite at
the time, because both are about what the package *concludes*, not about what
a key does:

- **False "your binding" note on stock Emacs.**  `beginning-of-buffer` answers
  to both `M-<` and `C-<home>`, and `where-is-internal` listed `C-<home>`
  first, so a vanilla session labelled the card "your binding; vanilla is
  `M-<`" when nothing had been remapped — the same class of alias as `C-/`
  versus `C-_`.  Live lookup now keeps the deck's vanilla key when it is among
  the live bindings, and attaches no remap note.
- **Summary reported "0 ms" for a session with nothing timed.**  Latencies at
  or above the 10-second interruption cap are dropped from the median list, so
  a session with no surviving samples produced a median of 0 and printed
  "0 ms" — which reads as instant answers rather than as no measurement at
  all.  That case now states that there were no timed answers.

Caught earlier by the test suite rather than by hand:

- `find-file` drilled as `<open>`: the GUI File-open event was the first
  `where-is-internal` hit.  Live lookup now keeps only typeable keys.
- The deck check ran against the current buffer, so `fill-paragraph` looked
  unbound in `lisp-interaction-mode`, which shadows `M-q`.  Vanilla keys are
  now checked against `global-map`.
- Stale `.elc` files silently won over newer `.el` sources, so tests could pass
  while the running package was wrong.  Build scripts now clear bytecode first.
- Line endings normalized via `.gitattributes`.  The package is authored on
  Windows; `.el` sources are committed with LF so checkouts on any platform
  match what CI and MELPA see.

### Verified

- Manual landmine matrix walked on 2026-08-13, GUI and `emacs -nw` under
  Windows Terminal, GNU Emacs 30.2.  All six chords — `C-g`, `C-x C-c`, `C-/`,
  `C-SPC`, `M-<`, `C-M-\` — scored as answers without leaking to their real
  commands or ending the session.

[0.2.0]: https://github.com/paradox1021/keydrill/releases/tag/v0.2.0
[0.1.0]: https://github.com/paradox1021/keydrill/releases/tag/v0.1.0