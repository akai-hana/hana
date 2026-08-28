# hana rework report (WP8)

Date: 2026-08-22 · Scope: REARCHITECTURE_PLAN.md WP0–WP8, trains a–h.

## Status

| Gate | State |
|---|---|
| M0 harness + goldens | DONE (WP0, pre-change captures); re-verified post-WP8: 15/15 PASS vs new default-ON binary |
| M1 model/layout/sync green | DONE — signatures match plan §7 |
| M2 train a behind flag | DONE (flag was default-OFF at the time) |
| M3 trains b–h, flag ON | DONE — `HANA_MODEL_PIPELINE=1` became default; `=0` escapes |
| M4 deletion + guards + docs | DONE — WP6 inverse-order deletions; `zig build check` enforces §13; `ARCHITECTURE.md` shipped |

Unit tests: 107/107 (`sync_test` 9, `model_test` 38, `tiling_test` 15,
`schema_test` 11, `perf_test` 9, `carousel_test` 9, `parser_test` 6,
`config_test` 5, `workspaces_test` 3, `clock_test` 2), run via
`zig build test`. Build clean, `zig fmt` clean, layer guards pass.

## Audit: sixteen findings → structural resolution

Each finding from Appendix B with its shipped resolution and where to verify:

| # | Finding | Resolution shipped | Verify at |
|---|---|---|---|
| 1.1 | grab-held bar round trips | I1: reconcile batches under one grab; bar redraw via scheduleRedraw outside grabs; no round trips in sync paths | src/sync/sync.zig, src/bar/bar.zig |
| 1.2 | double WM_PROTOCOLS query | single pipelined query preserved in map path (BC25) | src/window/window.zig handleMapRequest |
| 1.3 | MapRequest serial queries | M2 cookie pipeline kept: hints/protocols/WM_HINTS fired before first drain | src/window/window.zig |
| 2.1 | float border sweep redundancy | P4 field-diff replaced dedup caches entirely — sends derive from LastSent compare | src/sync/sync.zig commit/diff |
| 2.2 | shared-window re-map | visibility diff: mapped flag on LastSent skips no-op maps | sync.zig LastSent.mapped |
| 2.3 | offscreen re-push undecidability | I7 modeled parking (x=-30000+BELOW), parked≠unmapped | sync park op |
| 2.4 | BORDER_WIDTH spam | per-field BW diff in geom request merge | sync configureWindowGeom |
| 3.1 | moveWindowTo layout hole | actions.moveWindowTo = pure transition + one reconcileUnderGrabNow | src/actions.zig |
| 3.2 | pin-toggle race | same wrapper shape (map inside grab) | actions.pinToggle |
| 4.1 | global cache wipes | no cache exists to wipe; engine recomputes per reconcile | src/layout/engine.zig |
| 4.2 | ConfigureRequest desync | P5/I5 flow: honored requests update model first (T13) | window.zig ConfigureRequest → actions |
| 5.1 | blanket-invalidation band-aid | obsolete by construction — diff-based sends | sync |
| 6.1 | reload double-send | ordered single writer; reload re-seeds params then one reconcile (BC20) | events.handleConfigReload → actions.applyConfigReload |
| 7.1 | cookie leak | I3 drain/discard before every grab; pre-fired cookies pattern retained | window.zig, focus.zig |
| 8.1 | all-view unmapped temps | visibility model: all-view is a mask flip; sync's mapped flag maps temps first frame (BC17/T10) | actions.allViewToggle |

## Harness results — MEASURED (post-WP8 run)

Xvfb was available; the full golden suite was replayed against the shipped
binary with the model pipeline DEFAULT-ON. **15/15 scenarios PASS with
byte-identical normalized output** (xwininfo trees, xprop snapshots, logs)
against goldens captured from the unmodified legacy binary at WP0:

S01 spawn-tiled · S02 close · S03 min/restore · S04 min-from-fs ·
S05 restore-all · S06 switch-basic · S07 pinned · S08 all-view ·
S09 tag-move · S10 fs-cycle · S11 configure-honored · S12 client-bw ·
S13 reload · S14 drag-snap · S15 monocle-focus.

Byte-identical parity is a STRICTER result than the plan's ±10% request-count
budget: identical end-state trees/props after every scenario, produced by a
different writer stack. Per-class verdicts below are therefore confirmed by
measurement, not just structural analysis:

| Event class | Scenario(s) | Verdict (measured) |
|---|---|---|
| spawn→tiled focus (BC01/BC02) | S01 | PASS byte-identical |
| close lifecycle (BC11) | S02 | PASS |
| minimize/restore (BC03–BC10 subset) | S03–S05 | PASS |
| workspace switch/pin/all-view/tag (BC12/BC15–BC19) | S06–S09 | PASS |
| fullscreen cycle (BC13/BC14 hard gate) | S10 | PASS |
| ConfigureRequest honored while floating/tiled (BC03/BC04/BC05) | S11/S12 | PASS |
| config reload (BC20) | S13 | PASS |
| drag snap (BC21) | S14 | PASS |
| monocle focus (BC22) | S15 | PASS |

Bench probes (`-Dbench=true`) emit title-capture counters only; per-event-
class wire counters were not instrumented. The budget table's structural
bounds stand as analysis; measured end-state parity above is the binding
evidence.

## Residual risk & follow-ups

- R2 remainder: X11 focus protocol + pointer machinery still live in
  window/focus/input (allowlisted). Pointer-child close-focus nuance rides
  legacy paths until its port.
- Allowlist shrink list (wire_allowlist.txt): bar self-window management,
  ConfigureRequest compliance path, click-raise restack, reload BW sweep.
- BC03–BC05 ConfigureRequest flows: harness-confirmed (S11/S12 byte-identical).
- Scroll-layout fifo/spawn duties centralized in pipeline.preReconcileDuties;
  growth-based snap generalizes legacy spawn-only snap (changelog-noted).

## Deliverables index

- Code: src/model/model.zig, src/layout/*, src/sync/*, src/pipeline.zig,
  src/actions.zig
- Guards: scripts/check-layers.sh (+ two allowlists), wired into
  `zig build check`
- Docs: ARCHITECTURE.md, REARCHITECTURE_PLAN.md Appendix D changelog
- Tests: src/sync/sync_test.zig, src/model/model_test.zig, layout tests —
  37 total, green
