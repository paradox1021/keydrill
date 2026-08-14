# Changelog

All notable changes to this project are documented in this file.

## Unreleased

### Added

- Append-only answer journal (`keydrill-journal.eld`): one readable sexp per answered card across drills and benchmarks, with session begin/end markers.  `M-x keydrill-journal-purge` deletes it; set `keydrill-journal-file` to nil to disable.
- `M-x keydrill-benchmark`: cold recall pass over the full deck, live-resolved — no answers shown, no requeue, progress store untouched.  The before/after instrument for progress curves.

- Package skeleton: modules, Makefile, CI, and load-only ERT tests (M1).
- Move lifecycle, session planner, scoring, and `.eld` store round-trip (M2).
- `SPEC.md` describing those engine rules in prose.
- Key capture: `read-event` scoring, landmine chords, sequence timeout, and terminal/GUI normalization (M3).
- Drill buffer, session loop on the curated Emacs deck, summary, and graduation (`M-x keydrill`) (M4).
- Live-keymap resolution at session start: drill the launch buffer's binding when it differs from vanilla; unbound commands skip or score `M-x` per `keydrill-unbound-strategy` (M5).
- Opt-in usage observer and unused-binding report (`M-x keydrill-observe-mode`, `M-x keydrill-report`) (M6).
- README, MELPA recipe template (repo TBD), deck vanilla-key ERT against `global-map`, and live lookup skipping menu-bar, mouse, and GUI events such as `<open>` (M7).  The human GUI+tty landmine matrix is in the README; it has not been run on a real terminal here.
