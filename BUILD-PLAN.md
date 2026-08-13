# keydrill — Build Plan & Cursor Handoff

Working name: **keydrill** (verify no MELPA collision before publishing; alternates: `key-fluent`, `drillkey`).
Three rungs: **R1** Emacs package (free, GPL) → **R2** VS Code/JetBrains extension (freemium) → **R3** Epic/EHR pilot (B2B). This document is 90% R1; R2/R3 are scoped at the end so R1 decisions don't foreclose them.

---

## 0. Repo & Cursor environment setup

**Two repos, one Cursor workspace.** keydrill gets its own repo — it must never share git history, CI, or licensing with cmdenter (cmdenter is proprietary; keydrill is GPL-3.0-or-later; mixing them creates license questions you don't want).

```bash
# 1. New repo
mkdir keydrill && cd keydrill
git init
git branch -M main

# 2. Multi-root Cursor workspace: keydrill (writable) + cmdenter (reference)
# File > Add Folder to Workspace... > select your cmdenter checkout
# File > Save Workspace As... > keydrill.code-workspace  (inside keydrill repo)
```

`keydrill.code-workspace`:

```json
{
  "folders": [
    { "path": ".", "name": "keydrill (WRITE HERE)" },
    { "path": "../cmdenter-main", "name": "cmdenter (READ-ONLY REFERENCE)" }
  ],
  "settings": {
    "files.readonlyInclude": { "../cmdenter-main/**": true }
  }
}
```

`.cursor/rules/boundaries.mdc` (create this first — it's the guardrail):

```
---
description: Repo boundaries
alwaysApply: true
---
- The cmdenter folder is READ-ONLY reference material. Never edit, never
  copy files from it wholesale, never import its code verbatim.
- Port LOGIC and DATA only (spaced-repetition lifecycle, session planning,
  deck content). All Elisp is written fresh in this repo.
- Never port: anything under /api, /lib/creem, /lib/invite, /lib/ref,
  paywall/licensing/tier logic, analytics, email capture, pricing.
  keydrill has ZERO network code. If a change would add url-retrieve,
  url.el, request.el, or any process talking to a network, stop and ask.
- License: GPL-3.0-or-later. Every .el file gets the standard GPL header,
  lexical-binding: t, and must pass checkdoc and package-lint.
- Docstrings and comments are written in plain, specific, first-person-
  engineer English. No marketing language.
```

---

## 1. Extraction map — where everything lives in cmdenter

Everything worth taking is in `index.html` (single-file app). Line numbers from the 2026-08 snapshot; grep the anchor strings if they've drifted.

| What | Where in cmdenter | Take? |
|---|---|---|
| Emacs deck (85 moves, 7 levels) | `index.html` ~5974–6069, anchor `id: 'emacs', name: 'Emacs'` | **DONE** — already converted to `keydrill-deck-emacs.el` (in this handoff folder). Don't re-extract. |
| Move lifecycle `new → learning → drilling → learned` | ~971–1005, anchor `learn-then-drill move lifecycle` | **Yes** — port semantics exactly (incl. learned = ≥3 samples, ≥90% first-try, last latency <800ms) |
| Session planner (level gating, intro cap) | ~10884–10910, anchor `function sessionPlan` | **Yes** — incl. `MAX_NEW_PER_SESSION = 5` and the "a level opens only when every lower-level move has been introduced" rule |
| Drill loop / scoring | `startDeck`, `next`, `hit`, `miss`, `recordMove`, `finish` (~10912–11340) | **Yes** — logic only; all UI is rebuilt Emacs-native |
| Sequence timeout | `const SEQ_TIMEOUT = 1500` (~10850) | **Yes** — as `defcustom` |
| Key parsing (`normKey`, `parseCombo`, `comboMatches`) | ~1024–1117 | **No** — browser KeyboardEvent logic is useless in Emacs; use `kbd`, `key-description`, `read-event` instead |
| Everything else: Creem/checkout, invites, tiers, paywall, ref tracking, certs/LinkedIn, Formspree, daily-streak share text | `/api`, `/lib`, ~793–930, ~12113–12770 | **NEVER** — see boundaries rule |

Also port the *pass criteria* used by `finish()`/`renderDeckSummary` (read them from source when porting — accuracy + median-latency thresholds decide graduation).

---

## 2. R1 package architecture

```
keydrill/
├── keydrill.el              ; entry points, defgroup/defcustoms, autoloads
├── keydrill-engine.el       ; lifecycle, session planner, scoring (pure functions)
├── keydrill-capture.el      ; key reading — the hard file, see §3
├── keydrill-ui.el           ; drill buffer rendering, summary, graduation
├── keydrill-live.el         ; Tier 1: live-keymap resolution (where-is-internal)
├── keydrill-observe.el      ; Tier 2: opt-in usage observer (pre-command-hook)
├── keydrill-store.el        ; persistence — one readable .eld file
├── keydrill-deck-emacs.el   ; curated 85-move fallback deck (PROVIDED)
├── test/
│   ├── keydrill-engine-test.el
│   ├── keydrill-live-test.el
│   ├── keydrill-observe-test.el
│   └── keydrill-store-test.el
├── Makefile                 ; compile / lint / test targets
├── .github/workflows/ci.yml ; emacs 27.1, 28.2, 29.x, snapshot matrix
├── README.org
├── CHANGELOG.md
└── LICENSE                  ; GPL-3.0-or-later
```

**Data model (port of the JS `state`):** single file `keydrill-data.eld` in `user-emacs-directory`, written with `prin1`, human-readable by design (this is a privacy *feature* — document it in README). Structure mirrors cmdenter: per-move plist `(:seen N :hits N :last-latency MS :last-seen "YYYY-MM-DD" :state learning|drilling)` + per-deck records + observer counts. Provide `M-x keydrill-purge-data`.

**Engine port notes (JS → Elisp):**

- `moveState`/`setMoveState`/`displayState` → pure functions over the store alist. Keep the derived-`learned` rule identical.
- `sessionPlan` → `keydrill-session-plan`: same algorithm — open levels bottom-up until a level still has `new` moves; intros sorted level-then-(learning-before-new); cap at `keydrill-max-new-per-session` (default 5); recall = everything drilling in open levels, shuffled.
- Latency: `(float-time)` captured when the prompt renders, not when the session starts.
- Local-time day strings, same rationale as the JS comment (evening sessions must not straddle UTC midnight).
- **Drop entirely:** monetization gate in `sessionPlan` (`isMoveLocked` → always available), mac/win key variants (Emacs bindings are Emacs bindings; the deck file already collapsed them), the `typed` move type (Emacs deck has none).

**Tier 1 — `keydrill-live.el`:** for each deck entry, `(where-is-internal (plist-get m :command) nil t)` in the buffer the user launched from. User's binding ≠ vanilla default → drill *their* binding and show a one-line note ("your binding; vanilla is C-x C-f"). Command unbound → fall back to prompting M-x by name, or skip per `defcustom keydrill-unbound-strategy`. This resolution happens at session start, cached per session.

**Tier 2 — `keydrill-observe.el`:** OFF by default; enabling prints a plain-English one-time explanation of exactly what is recorded and where. A `pre-command-hook` fn — **must be near-zero cost and error-proof** (wrap body in `condition-case`, ignore errors silently; a broken pre-command-hook makes Emacs unusable):

- record `this-command` + invocation method: `(this-single-command-keys)` vs `M-x` (detect: `this-command` reached via `execute-extended-command`) vs mouse/menu event
- aggregate counts only (command × method × week). Never record keystroke *content*, never record commands in minibuffer/isearch contexts
- `M-x keydrill-report`: "you ran query-replace 47× via M-x; it's bound to M-%" — top N gaps ranked by count × keys-saved, each with a one-key jump into a drill of exactly those moves
- gap moves get auto-generated prompts from the command's own docstring first line; curated deck prompt wins when the command is in the deck

---

## 3. `keydrill-capture.el` — the hard part, design constraints

This is where the bugs will live. Constraints discovered up front:

1. **`read-key-sequence` won't work** for scoring: with no active keymap entries it terminates on undefined prefixes and eats mistakes. Use `read-event` in a loop, building the key vector manually, comparing against the expected sequence with `key-description` normalization.
2. **`C-g` is an answer** (`keyboard-quit` is move #1). Bind `inhibit-quit` to t around the read loop and check for `?\C-g` as data; provide the escape hatch *explicitly*: `q` on the "press q to quit" affordance plus double-`C-g`-within-1s ends the session (mirror of cmdenter's double-Escape hatch in `drillKey`).
3. **`C-x C-c` is an answer.** Events are consumed by our loop, never executed — but test this specifically; a bug here kills the user's Emacs session.
4. **Sequence timeout:** cmdenter's 1500ms between steps → `with-timeout`/timer around each subsequent `read-event`; timeout = miss, message identical in spirit to `SEQ_TIMED_OUT`.
5. **Terminal vs GUI normalization table** (unit-test each): `C-/` arrives as `C-_` in terminals; `C-SPC` as `C-@`; `M-x` may arrive as `ESC x` (two events — coalesce ESC-prefix pairs); `<f3>`/`<f4>` fine in both; `TAB` vs `C-i` — accept both.
6. **Never score auto-repeat or modifier-only events** (port of the `e.repeat` and bare-modifier guards).
7. Answers are compared as *key descriptions*, so a user's remapped binding from Tier 1 flows through the same path as a vanilla one.

Manual test matrix (human, not CI): GUI Emacs + `emacs -nw` in a real terminal × the 6 landmine moves (`C-g`, `C-x C-c`, `C-/`, `C-SPC`, `M-<`, `C-M-\`).

---

## 4. Quality gates (non-negotiable, r/emacs will check)

- `emacs -Q --batch -f batch-byte-compile` — zero warnings
- `package-lint`, `checkdoc` clean; `lexical-binding: t` everywhere
- ERT suite runs in batch: engine, planner, store round-trip, observer aggregation, capture normalization table (event-level tests via synthetic `unread-command-events`)
- CI matrix: Emacs 27.1 / 28.2 / 29.x / snapshot (use `purcell/setup-emacs` or `jcs090218/setup-emacs`)
- README.org: honest Commentary, credits **key-quiz** (federicotdn) and **keywiz** as prior art and states what's different (live-keymap resolution + usage-gap drilling); the privacy section invites `grep -r url-retrieve`
- Zero network code. Zero telemetry. No mention of cmdenter beyond one "prompts adapted from my web trainer" credit line in Commentary.

## 5. Milestones

1. **M1 — skeleton compiles:** repo, CI, empty modules pass lint. (½ day)
2. **M2 — engine ported + ERT green:** lifecycle, planner, store; pure functions, no UI. (1 day)
3. **M3 — capture works in GUI:** chord + sequence scoring, landmine moves safe. (1–2 days)
4. **M4 — drill UI + summary:** full session loop on curated deck; graduation screen. (1 day)
5. **M5 — Tier 1 live keymap.** (½ day)
6. **M6 — Tier 2 observer + report.** (1 day)
7. **M7 — terminal hardening + manual matrix + README + MELPA recipe.** (1 day)

v1 = M1–M5. Ship that, email Sacha, land Tier 2 while feedback comes in.

---

## 6. Rung 2/3 stubs (do not build yet — just don't foreclose)

**R2 — VS Code first (separate repo `keydrill-vscode`, MIT or BSL, your choice — no GPL obligation there).** Reads `keybindings.json` + defaults for Tier 1; usage capture via extension telemetry APIs is consent-gated. The Elisp engine's *rules* (lifecycle thresholds, planner, pass criteria) should therefore live documented in a `SPEC.md` in the keydrill repo — write it during M2 while porting, so R2 is a re-implementation of a spec, not a source port from GPL code (keeps R2's license clean). Paid tier = sync + team dashboard; that server is a third repo.

**R3 — Epic pilot.** No code yet. Asset to produce later: one-pager + the published keydrill methodology as credibility. Depends on R2's dashboard existing.

---

## 7. Paste-ready Cursor kickoff prompt

> You are building **keydrill**, a GPL-3.0-or-later Emacs package, in this repo. The second workspace folder (`cmdenter`) is read-only reference — port logic and data per BUILD-PLAN.md §1, never copy code or touch anything listed as NEVER. Read `.cursor/rules/boundaries.mdc` and `BUILD-PLAN.md` fully before writing code. `keydrill-deck-emacs.el` already exists — treat it as given data (but flag any :command mapping that looks wrong). Work milestone by milestone starting at M1; after each milestone run `make compile lint test` and do not proceed with failures. The engine semantics in cmdenter's `index.html` (anchors: "learn-then-drill move lifecycle", "function sessionPlan", "function drillKey") are the spec for M2–M3 — match behavior, including MAX_NEW_PER_SESSION=5, SEQ_TIMEOUT=1500ms, and the learned-state thresholds (≥3 samples, ≥90% first-try, <800ms). While porting M2, also write SPEC.md describing the engine rules in prose (needed later for a clean-room TypeScript port). Docstrings: plain, specific, human. All key-capture edge cases in §3 get explicit tests. Ask before adding any dependency beyond GNU Emacs ≥27.1.

---

## 8. Verify-before-publish checklist

- [x] Every `:command` in `keydrill-deck-emacs.el` checked against `global-map` in `emacs -Q` (ERT: `test/keydrill-deck-test.el`; 85/85 on GNU Emacs 30.2). Uses `global-map` because a major mode can shadow keys such as `M-q`.
- [x] Package name collision check against a local MELPA/GNU archive snapshot (had `key-quiz`, not `keydrill` or `keywiz`). **Re-check on submit day.**
- [x] `grep -rn "url-retrieve\|url\.el\|request" *.el` returns nothing
- [ ] Manual landmine matrix (GUI + terminal) passed — human, README table
- [x] README credits key-quiz/keywiz; site mentioned once, as an aside
- [ ] The 95-vs-85 move count claim on cmdenter.app reconciled before the Sacha email goes out (deck is 85)
