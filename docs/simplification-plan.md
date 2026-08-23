# hana From First Principles -- Simplification Plan

Question: knowing everything we know now, what is the SIMPLEST system that
produces exactly the behavior hana produces today? Status: PROPOSAL.

## 0. The contract

Behavior is frozen; mechanism is free. Concretely, the contract is:
every harness scenario passes unchanged (geometry, focus, stacking, logs),
and every user-visible feature survives: 6 layouts + variants, floating +
drag-snap, fullscreen (native + EWMH) + minimize/restore, workspaces/tags/
pinning/all-view, hover+click focus with spawn-suppression, the bar with
indicators/carousel-titles/layout/clock/vim-prompt/transparency, TOML config
with includes/themes/fallback/hot-reload.

## 1. First-principles accounting

19.0k lines today decompose into three classes:

| Class | ~LoC | Nature |
|---|---|---|
| Behavior | ~9k   | protocol compliance, features, rendering -- the contract itself |
| Mechanism | ~7k  | caches, diff engines, indirection layers, batching -- ways to AVOID work the machine can cheaply do |
| Truth | ~2k    | model + tiling math + wire primitives -- already minimal |

The rearchitecture spent its effort on class 3 (correctness structure).
Almost nothing left there. The remaining fat is class 2: mechanisms built
when we assumed operations were expensive. First-principles question per
mechanism: at hana's real scale (<50 windows, redraws on human timescales),
is the thing it avoids actually expensive? Mostly: no.

## 2. The simplifications, ranked by (savings x confidence)

### A. arrange() over diff-sync          DONE 2026-08-23
Diff/skip machinery deleted: reconcile now computes desired state and
APPLIES it unconditionally every pass (map/border/geom are server-side
idempotent; re-parking is idempotent; self-heals client-side drift that a
skip-cache would silently tolerate). Kept, deliberately renamed the SENT
LEDGER: {last visible rect, parked flag} written as a side-effect of
sending, never consulted to omit a request. Its three readers are
behavioral contract, not optimization:
  - all-view orphans resurface at their last real slot (rect survives
    parks -- S08 pinned this exact legacy subtlety on the first attempt);
  - winner raises iff moved / unparked / force_restack (legacy triggers,
    derived instead of remembered);
  - actions.lastRectFor floating-detach base.
scheduled/takeScheduled trigger coalescing kept (event-driven retile
timing unchanged). ACTUALS: sync.zig 524 -> 430 (-94), tests +25 (full-
replay sequences pinned), net -69. Verified: 39/39 unit (rewritten golden
sequences), layers pass, harness 18/18 with ZERO artifact churn.
Lesson: the volumetric estimate overshot because half of LastSent was
contract (orphan/raise/detach semantics), not cache. What died is the bug
class, not just lines.

### B. Layouts are data, not modules      EXECUTED THEN REVERTED 2026-08-23
Six algo files were absorbed into src/tiling/engine.zig (-17 LoC; the math
was already irreducible -- registry/variant plumbing lives in config/types,
which is contract). User preference overrides: the per-layout file split
aids navigation and keeps each algorithm's logic separate; restored
verbatim (harness spot-parity confirmed on S13/S14/S15/S16). Structural
lesson retained: file splits that force alias re-exports are ceremony, but
splits that aid human differentiation are worth their lines.

### C. The action table is the dispatcher  actions.zig 720 -> ~250 (-450)
30 pub wrappers whose bodies are `model.X(); sync.entry(); return`. The
keybind enum already names every action; input.zig's match collapses into
one dispatch site calling model/window directly for trivial transitions,
keeping genuinely multi-step flows (restore-with-refocus, drag begin) as
named functions where they belong. Guard remains: UI code mutates only via
model API. Risk: low; purely mechanical, harness-covered.

### D. Bar draws from live state           bar.zig+title ~-500
The double-slot snapshot relay (captureStateIntoSlot, snap_idx, ownership
relay pages) and title batch pre-fetch exist to eliminate per-draw round
trips during drags. Real cost of direct queries: O(N) round trips per actual
redraw; redraws happen on focus/workspace/clock-second boundaries. Sub-
millisecond at any realistic N; invisible. Pixel output identical (goldens
prove it), bench.txt artifacts become trivial constants.
Risk: medium -- most intricate file in the tree; do it after C so fewer
callers churn the slots.

### E. One focus path                      focus.zig 786 -> ~500 (-280)
Hover, click, MRU-fallback, pending-confirm, spawn-suppression are five
mechanisms braided through one file. Refactor shape: `pickCandidate() ->
applyFocus()` plus one suppression predicate consulted at entry. All
observable timings preserved (S16/S17 pin them). Internal states collapse.
Risk: medium; focus bugs are loud and harness-visible, which is why this is
safe to attempt at all.

### F. Config de-layering                  config.zig ~-200
Parser stays (hand-rolled TOML is a no-dependency feature). Merge paths,
fallback embedding, terminal detection: collapse duplicated merge walks and
dead branches found along the way. Semantics frozen.

### G. Window property plumbing            window.zig ~-200
Manage-path and reload-path both walk properties with slightly different
helpers; unify into one query set. Spawn-queue/suppression internals
shrink under E's unified predicate.

## 3. End state

~16.5k +- 0.5k total (~11.5k code after comments/blanks), zero behavioral
change, harness green after every step. Shape unchanged from today's tree --
this is deletion inside files, not another migration. That is deliberate:
the second-order win is stopping the accretion pattern (each historical
optimization deposited a mechanism nobody dares remove); A-G removes the
deposits and the guard suite makes them un-redepositable.

## 4. What this plan refuses to do

Go below ~15k requires removing contract items: vim-prompt (-1.5k), carousel
(-0.5k), hand-rolled TOML for a library (-1.5k, adds dependency), EWMH
fullscreen (-0.3k), includes/themes (-0.5k). Those are product decisions,
out of scope here. A "simple WM" at 8k lines is a DIFFERENT product; hana's
contract is what costs the remaining kilolines, and per-line maintainability
is highest precisely because model/tiling/sync stay pure and small.

## 5. Sequencing and verification

Order: B (pure, warm-up) -> A -> C -> E+G -> D -> F. Every step lands only
with: zig build test 39/39, check-layers pass, full-harness 18/18 parity,
zero golden churn expected at any step (log formats untouched). Est. effort:
B=half day, A=day, C=day, E+G=day, D=two days, F=half day.

## 6. Non-goals

No new features, no dependency changes, no protocol additions, no perf
regression beyond noise (A/D trade negligible traffic for less code --
documented, accepted).
