# keydrill roadmap

v0.1.0 is feature-complete for a first release: live-keymap drilling,
curated 85-move deck, opt-in observer, local `.eld` store, 114 tests.

This roadmap implements reviewer and community suggestions, ordered by
effort-to-credibility ratio. Items marked (SC) came from feedback by
Sacha Chua.

## v0.2 — focus and mnemonics (small, high value)

**Focus sets (SC).** Let the user pick which moves to drill instead of
always taking the planner's mix.
- `keydrill-focus` command: complete over deck ids/prompts, build a
  session from the selection. The plumbing exists — `keydrill-ui-start`
  already accepts an explicit MOVES list (landmine.el proves it).
- `keydrill-focus-level`: drill one level only.
- Estimated: 1–2 days including tests.

**Personal mnemonics (SC).** A user note per move, shown on intro cards
and after a miss.
- New `:mnemonic` field in the store's per-move record; `keydrill-annotate`
  command to set it from the summary or during review.
- Renders under the prompt in `keydrill--render-card`.
- Estimated: 1 day.

## v0.3 — keyfreq integration and data-driven drilling

**keyfreq as a data source (SC).** `keydrill-observe-mode` overlaps with
[keyfreq](https://github.com/dacap/keyfreq); do not ship a rival counter.
- If keyfreq is installed and has data, `keydrill-report` reads its
  table (soft dependency, `featurep` guard) and merges it with observer
  counts.
- Document the relationship in the README: observer = "commands you ran
  by name that have keys"; keyfreq = "everything, longer history."
- Estimated: 2–3 days; the report layer already exists in
  keydrill-observe.el.

**Gap-driven sessions.** `keydrill-drill-gaps`: build a focus set from
the report — the commands you demonstrably reach for slowly.
This is the package's whole thesis closing its own loop.

## v0.4 — sharing and interop

**Deck export/import (SC).** Org table and JSON round-trip.
- `keydrill-export-deck` / `keydrill-import-deck`. The deck is already
  a plist list; serialization is mechanical. Org format makes decks
  reviewable in Emacs and diffable in PRs — likely how community decks
  arrive.
- Progress export stays out of scope until someone asks; the `.eld` is
  already readable.

**Custom decks.** Document the deck plist shape (`:id`, `:command`,
`:key`, `:level`, `:prompt`) as a stable format. A mode-specific deck
(magit, org, dired) is the obvious community contribution; make it a
one-file PR.

## v0.5 — spaced repetition honesty (SC)

The engine's requeue-on-miss is not SRS. Survey org-drill's SM-2
implementation and either:
- adopt real intervals per move (the store already tracks last-seen and
  latency, so the data is there), or
- document precisely why session-based repetition fits key-chords better
  than day-scale SRS (motor memory vs. declarative memory is a
  defensible argument — make it or drop it).
Credit org-drill / pamparam as prior art either way.

## v0.2.5 — instrumentation (before daily use begins)

Data that makes results publishable later has to be captured from day
one; the aggregate store alone cannot reconstruct curves.

- **Session journal.** Append-only `keydrill-journal.eld`: one record
  per answer — timestamp, deck, move id, intro/recall, status, latency,
  expected key. Local file, same no-network promise. ~1 day: the
  capture result plist already carries every field.
- **`keydrill-benchmark`.** Cold-recall pass over the full deck, no
  answers shown, no requeue, results journaled under a `benchmark` tag.
  This is the before/after instrument. Must run BEFORE habitual
  drilling starts — a baseline is unrepeatable once practice begins.
- **Transfer metric.** The persuasive number is not drill scores; it is
  behavior in real work: observer/keyfreq counts of commands executed
  via M-x *that have bindings*, falling over time. Drill scores show
  practice at the drill; this shows the drill transferring.
- **`keydrill-plot`.** Render per-binding latency over time and the
  M-x-gap trend as SVG in a buffer (no gnuplot dependency). The chart
  that matters: which chords resist learning.

## Continuous

- **Dogfood data.** Daily sessions on the author's own config; publish
  accuracy/latency curves after ~30 days, benchmark weekly.
- README candor section: how this package was built (AI-assisted code,
  human design/testing), and its relationship to any commercial work.

## Non-goals for the GPL package

- No network code, ever (Commentary already promises this).
- No accounts, no telemetry, no upsell text. Anything commercial lives
  elsewhere under a different name and is linked nowhere in this repo
  except one disclosure line in the README.
