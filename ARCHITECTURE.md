# hana architecture (post-rework)

Authoritative spec: `REARCHITECTURE_PLAN.md` §6-§8. This file summarizes the
shipped shape; when the two disagree, the plan wins and this file is stale.

## Layers (enforced by `zig build check` through `dev/scripts/check-layers.sh`)

```
model  ← std + utils only, no xcb          src/model/model.zig
tiling ← model types only, pure            src/tiling/{engine,hints,layouts/*}.zig
sync   ← model + tiling; ONLY writer       src/core/sync/sync.zig (+ wire.zig)
actions← model transitions, zero XCB       src/window/actions.zig
entry points ← actions + sync              core/, window/, bar/ (src/main.zig)
```

- **P1** The model (`src/model/model.zig`) is the single source of truth
  for the **core intents** that cross-cut features: per-ws `tiled_order`, masks
  (multi-tag), `BaseMode` (tiled/floating rect), `presence` (present/parked/
  covering), `covering_ws` (a covering window's capture target), `home_ws`,
  focus, all-view flag. The model is **authoritative for these core intents**;
  it does NOT hold feature names or feature payloads.
  Per-feature *identity* — minimize slot/sequence, fullscreen's pre-fullscreen
  anchor + ghost bookkeeping — lives in the open addon modules
  (`src/window/modules/*.zig`) as a private store that core never reads. This is
  by design ("open addons, trace-free removal"): a feature writes its
  cross-cutting facts into the model's intent fields and reads them back from
  the model, so deleting the addon simply stops it producing those fields'
  values. Core layers (sync, bar, persistence) read ONLY the core intents.
- **P2** Only `src/core/sync/` sends geometry/border/map/stack requests. Reconcile
  runs UNCONDITIONAL APPLY: every pass computes the desired state for every
  stored window and sends it (parked windows get one merged park request;
  visible windows replay map, pixel, bw, geometry in order). X configure/map
  requests are idempotent, so replaying the full desired state is drift-proof;
  there is no diff cache or sweep counter. The sent ledger is a WRITE-ONLY
  record ({rect, has_rect, parked}) read only for multi-tag orphans,
  winner-raise derivation, and floating-detach; parked windows sit at
  x=-30000+BELOW (I7), never unmapped.
- **P3/P5** Actions mutate the model only; ConfigureRequests and properties
  enter as model updates before any send derives from reconcile (I5).
- Invariants I1-I8 (plan §6) are binding: no round trips inside grabs (I1),
  one flush per atomic op (I2), cookie drain-before-grab (I3),
  restore-class includes full restack incl. bar (I4), refuse-before-mutate capacity
  contracts (I8).

## Data flow

```
X event / keybind ─► entry point (window.zig / input.zig / bar.zig / events.zig)
                       │ legacy bookkeeping still updated where other
                       │ modules read it (strangler dual-write)
                       ▼
                    actions.*   (one action ≙ one plan §7.2 transition)
                       │ model mutations (+ scroll duties in pipeline)
                       ▼
                 pipeline.reconcileUnderGrabNow / reconcileNow
                       │ builds sync.Ctx from live config/bar state
                       ▼
                    sync.reconcile  ── conditional apply vs sent ledger ──► xcb_sink
```

The layout engine (`engine.compute`) receives a frozen `View`
(order ∩ mask, params, workarea, margins, hints) and writes placements into
a caller-owned buffer: zero allocation, zero I/O, fully unit-tested
(`zig build test`, 107 unit test blocks).

## Tests

107 unit test blocks across `src/test/*_test.zig` (model transitions, tiling
math incl. golden-value layout traces, sync wire sequences, config reader,
workspace overrides, clock deadlines, carousel timing, perf sanity), run via
`zig build test`.

## Behavioral gates

BC01-BC26 are the regression contract; the harness in `dev/harness/`
replays 21 scenarios against a running X server (`--compare` diffs against
recorded goldens; run locally or on CI). Known baseline: S02/S04/S05/S16
diverge from goldens recorded before the T36 close-fallback change; that
change is intentional; re-record goldens when adopting it.

## Allowlists

The allowlists (embedded in `dev/scripts/check-layers.sh`) document
every file still sending XCB outside sync (bar self-window, ConfigureRequest
compliance, click-raise, reload BW sweep, wire primitives in x11wire). Shrink
by moving the traffic behind sync, then delete the entry.
