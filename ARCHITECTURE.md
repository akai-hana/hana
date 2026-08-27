# hana architecture (post-rework)

Authoritative spec: `REARCHITECTURE_PLAN.md` §6–§8. This file summarizes the
shipped shape; when the two disagree, the plan wins and this file is stale.

## Layers (enforced by `zig build check` → `dev/scripts/check-layers.sh`)

```
model  ← std + utils only, no xcb          src/model/model.zig
tiling ← model types only, pure            src/tiling/{engine,hints,layouts/*}.zig
sync   ← model + tiling; ONLY writer       src/sync/sync.zig (+ wire.zig)
actions← model transitions, zero XCB       src/window/actions.zig
entry points ← actions + sync              core/, window/, bar/ (src/main.zig)
```

- **P1** The model (`src/model/model.zig`) is the single source of truth:
  per-ws `tiled_order`, masks (multi-tag), `BaseMode` (tiled/floating rect),
  fullscreen records, minimize records with LIFO/FIFO sequence numbers,
  focus, all-view flag.
- **P2** Only `src/sync/` sends geometry/border/map/stack requests. Reconcile
  computes the desired state for every window and applies it CONDITIONALLY
  against the sent ledger (skip identical desires; force_restack and a
  periodic full sweep bypass the diff); parked windows sit at
  x=-30000+BELOW (I7), never unmapped.
- **P3/P5** Actions mutate the model only; ConfigureRequests and properties
  enter as model updates before any send derives from reconcile (I5).
- Invariants I1–I8 (plan §6) are binding: no round trips inside grabs (I1),
  one flush per atomic op (I2), cookie drain-before-grab (I3),
  restore-class ⇒ full restack incl. bar (I4), refuse-before-mutate capacity
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
a caller-owned buffer — zero allocation, zero I/O, fully unit-tested
(`zig build test`, 65 test blocks).

## Tests

65 unit test blocks across `src/test/*.zig` (model transitions, tiling math
incl. golden-value layout traces, sync wire sequences, config reader,
workspace overrides, clock deadlines, carousel timing), run via
`zig build test`.

## Behavioral gates

BC01–BC26 are the regression contract; the harness in `dev/harness/`
replays 21 scenarios against a running X server (`--compare` diffs against
recorded goldens; run locally or on CI). Known baseline: S02/S04/S05/S16
diverge from goldens recorded before the T36 close-fallback change — that
change is intentional; re-record goldens when adopting it.

## Allowlists

The allowlists (embedded in `dev/scripts/check-layers.sh`) document
every file still sending XCB outside sync (bar self-window, ConfigureRequest
compliance, click-raise, reload BW sweep, wire primitives in utils). Shrink
by moving the traffic behind sync, then delete the entry.

## Behavioral gates

BC01–BC26 (plan §8) are the regression contract; the harness from WP0
replays them against a running X server (not available in CI — run locally
via `scripts/` harness).
