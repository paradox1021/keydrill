# keydrill engine specification

This document describes the session-engine rules implemented in the Emacs package. It is prose only, for a later clean-room TypeScript port. It is not source, and it does not describe key capture, UI, or persistence file format beyond the logical store.

## Out of scope

The engine does not talk to a network. There is no account, license, paywall, tier, invite, analytics, or certificate flow. Every move is available once its level is open.

The engine does not parse keystrokes. Bindings are opaque strings supplied by the caller. There is no mac/win key-variant split and no typed-command move type.

Daily timed sessions, due-list bias, weak/stale ranking, band shuffle, and same-shape spacing are not part of this engine. Recall order is a shuffle of drilling moves in open levels.

## Store

Progress is a single local document.

- **Moves** are keyed by stable string id. Each record holds: seen count, first-try hit count, last latency in milliseconds, last-seen local date string, and stored phase `learning` or `drilling`.
- **Decks** are keyed by deck id. Each record holds: session count, best accuracy and median, a list of distinct local dates that met graduation pace, and a celebrated flag for UI.
- **Observer** counts may be present and empty. The engine does not read them.

A missing move record means the move has never been introduced.

## Local-time day strings

Dates are `YYYY-MM-DD` in the user's local calendar, not UTC. An evening session must not split across two days just because UTC midnight has passed. Last-seen and pass dates use this clock.

## Latency

Latency is milliseconds from the moment the prompt is shown to the moment the answer is scored. The engine does not start a clock. The caller captures the timestamp when the prompt renders and passes the elapsed number in. Values of 10000 ms or greater are interruptions: they may still count as a first-try hit for accuracy, but they do not update last latency and they are not stored in the session median list.

## Move lifecycle

Four display states, three of them stored:

1. **new** — no record (or a record with no phase and zero samples). The move must get an intro card before any recall.
2. **learning** — intro card has been shown; a correct intro press has not yet landed. Stored as phase `learning`.
3. **drilling** — locked in by a correct intro press. Stored as phase `drilling`. Recall statistics accrue only in this phase.
4. **learned** — display only, never stored. A drilling move whose recall record meets all of:
   - at least 3 recall samples
   - first-try hits / samples ≥ 0.90
   - last latency > 0 and **strictly less than** 800 ms

Boundary cases that are **not** learned: 2 samples even at 100%; 89% first-try (below 0.90); last latency 800 ms; last latency 0. A move with 3/3 first-try hits and last latency 799 ms **is** learned.

A record with no phase and a positive seen count is treated as drilling (migration from older stores). Any other unexpected phase is treated as new.

### Transitions

- Showing an intro card for a **new** move writes phase `learning`. Already-introduced moves are left alone.
- A correct intro press writes phase `drilling`. It does **not** add a recall sample, does not count toward attempted/first-try, and does not record latency.
- A wrong intro press is coaching: no sample, no requeue, no phase change.
- Recall first-try hit: increment seen and hits; if latency < 10000 ms, store rounded last latency; set last-seen to today.
- Recall first-try miss: increment seen; do not increment hits; do not change last latency; set last-seen to today.
- A later corrected or requeued completion updates last-seen only. It must not add a sample.

Intro statistics never mix with recall statistics. Graduation math is recall-only.

## Session planner

Inputs: a deck (list of moves with at least id and level) and the store. Output: intros, recall, open levels, and eligible moves.

**Level gate.** Collect unique levels present in the deck, sorted ascending. The lowest level is always open. Walk upward: add the level, then if every move at that level has been introduced (phase is not `new`), continue; otherwise stop. A higher level never opens while a lower present level still has a `new` move. Missing level numbers are not a gap; only un-introduced moves block the next present level.

**Eligible** moves are those whose level is open. There is no lock filter.

**Intro pool** is eligible moves whose phase is not `drilling` (so `new` and `learning`). Sort by level ascending. Within a level, all `learning` moves come before all `new` moves. Shuffle inside each of those buckets. Cap the list at the configured maximum new-per-session (default 5).

**Recall** is eligible moves whose phase is `drilling` (this includes display-learned moves), shuffled. The planner does **not** put this session's intros into the recall list. Whether the session loop later quizzes a just-locked-in move is a UI concern, not a planner rule.

Default maximum new-per-session is 5. Sequence timeout (default 1.5 seconds / 1500 ms) is a capture setting, not an engine input.

## Scoring a recall presentation

Callers must invoke the recall recorder **once** per first presentation of a recall card: on a clean first-try hit, or on the first miss. Requeued copies must not add a sample.

Session totals (owned by the session loop, consumed by pass criteria):

- **attempted** — distinct first recall presentations, including unresolved misses. Intro cards are excluded.
- **first-try** — those presentations answered correctly with no miss.
- **lats** — first-try hit latencies under 10000 ms.
- **introduced** — intro cards locked in. Never included in accuracy or median.

Accuracy is `round(100 * first-try / attempted)`, or 0 if attempted is 0. Rounding is half-up toward +inf.

Median: if the latency list is empty, 0; otherwise sort ascending, take the element at index `floor(length / 2)`, round half-up. Even-length lists use the upper middle value, not the average of the two middles.

## Pass criteria and graduation

A deck session is **graduation pace** when all of the following hold:

- first-try accuracy ≥ 95
- median latency > 0 and **strictly less than** 800 ms
- attempted ≥ number of moves in the full deck (coverage). A 5-move intro session cannot pass a larger deck.

If the session is graduation pace and today's local date is not already in the deck's pass-date list, append it. Best accuracy/median updates when accuracy is strictly better, or accuracy ties and the new median is positive and better (smaller) than the stored best, including when stored best median is 0.

The deck is **graduated** when it has two distinct pass dates (two separate local days at graduation pace). Graduation does not depend on a license. The celebrated flag is UI bookkeeping, not an engine rule.

A session with zero recall attempts is an intro session: it cannot pass, regardless of how many moves were locked in.
