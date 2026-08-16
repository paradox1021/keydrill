# keydrill roadmap

## Shipped

**v0.1.0** — live-keymap drilling, curated 85-move deck across 7 levels,
opt-in usage observer and gap report, local `.eld` store, Emacs-native drill
buffer with summary and graduation.

**v0.2.0** — measurement. Append-only answer journal (`keydrill-journal.eld`)
and `M-x keydrill-benchmark`, the cold full-deck pass that shows no answers
and never writes the progress store. Plus `keydrill-text-scale` for legibility
and recording. Suite at 122 ERT tests.

Two items from the original v0.2.5 instrumentation plan landed early, with
0.2.0, because a baseline is unrepeatable and waiting would have cost the
author his own. The two that remain are below.

---

The rest of this roadmap implements reviewer and community suggestions,
ordered by effort-to-credibility ratio. Items marked (SC) came from feedback
by Sacha Chua.

## v0.3 — focus and mnemonics (small, high value)

**Focus sets (SC).** Let the user pick which moves to drill instead of
always taking the planner's mix.
- `keydrill-focus` command: complete over deck ids/prompts, build a
  session from the selection. The plumbing exists — `keydrill-ui-start`
  already accepts an explicit MOVES list.
- `keydrill-focus-level`: drill one level only.
- Estimated: 1–2 days including tests.

**Personal mnemonics (SC).** A user note per move, shown on intro cards
and after a miss.
- New `:mnemonic` field in the store's per-move record; `keydrill-annotate`
  command to set it from the summary or during review.
- Renders under the prompt in `keydrill--render-card`.
- Estimated: 1 day.

## v0.4 — remaining instrumentation

**Transfer metric.** The persuasive number is not drill scores; it is
behavior in real work: observer counts of commands executed via M-x *that
have bindings*, falling over time. Drill scores show practice at the drill;
this shows the drill transferring. The observer already collects the raw
counts by command and week — this is a reporting layer, not new capture.

**`keydrill-plot`.** Render per-binding latency over time and the M-x-gap
trend as SVG in a buffer (no gnuplot dependency), reading from the journal.
The chart that matters: which chords resist learning.

## v0.5 — keyfreq integration and data-driven drilling

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
the report — the commands you demonstrably reach for slowly. Partly present
already: report rows drill on `RET`, a digit, or `a`. What is missing is a
single command that builds a session from the whole gap list without opening
the report first.

## v0.6 — sharing and interop

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

## v0.7 — spaced repetition honesty (SC)

The engine's requeue-on-miss is not SRS, and the README does not currently
say so plainly. Either:
- adopt real intervals per move (the store already tracks last-seen and
  latency, so the data is there), or
- document precisely why session-based repetition fits key-chords better
  than day-scale SRS (motor memory vs. declarative memory is a
  defensible argument — make it or drop it).

Credit org-drill / pamparam as prior art either way.

**The README section is written** (0.2.0, "Is this spaced repetition?"): it
states plainly that there is no interval algorithm, argues that the 800 ms
bar targets automaticity rather than retrievability, that contextual
interference is a within-session prescription, and that an 85-move deck does
not need a scheduler — then concedes that weak-and-stale biasing is the right
fix once a user carries several decks. That concession is the actual work
item here.

## Continuous

- **Dogfood data.** Daily sessions on the author's own config; publish
  accuracy/latency curves after ~30 days, benchmark weekly. Day zero on
  record: 3 cold hits of 71 answered, 4%, median 4101 ms, 2026-08-14.
- README candor section: how this package was built (AI-assisted code,
  human design/testing), and its relationship to any commercial work.
  **Done in 0.2.0.**

## Non-goals for the GPL package

- No network code, ever (Commentary already promises this).
- No accounts, no telemetry, no upsell text. Anything commercial lives
  elsewhere under a different name and is linked nowhere in this repo
  except one disclosure line in the README.