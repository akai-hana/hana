# hana Subsystem Map — Agent Analysis Brief

Purpose: partition the codebase into independently analyzable subsystems for
parallel review. Each section is self-contained scope for one agent.
Agents receive: this file + their assigned section number + the analyst
prompt template at docs/analyst-prompt.md (written by the orchestrator).

## Ground rules every agent must know

- **Behavior is frozen.** The contract is `dev/harness/` (18 scenarios,
  golden artifacts) + `src/test/` (39 tests) + `src/test/check-layers.sh`
  (layer rules). Any proposal must name which gate would catch its
  regressions. Verification commands:
  - `zig build && zig build test --summary all` (39/39 expected)
  - `bash src/test/check-layers.sh`
  - `zig build && bash dev/harness/run-scenario.sh --compare S01-spawn-tiled
    S02-close S03-min-restore S04-min-from-fs S05-restore-all S06-switch-basic
    S07-pinned S08-all-view S09-tag-move S10-fs-cycle S11-configure-honored
    S12-client-bw S13-reload S14-drag-snap S15-monocle-focus S16-close-respawn
    S17-hover-focus S18-ewmh-fullscreen` (18/18 PASS expected)
- **Layer rules** (enforced by rule 1 of check-layers): raw xcb calls may
  appear ONLY in `src/sync/wire.zig`. Model (`src/model`) and tiling
  (`src/tiling`, minus facade) are pure — no XCB, no global state reads.
  `src/sync/sync.zig` is the SOLE writer of geometry/map/stack/border.
- **No new dependencies. No feature removal. No config-language changes.**
- **Comments are load-bearing**: this codebase documents WHY (invariants,
  legacy ports, caller duties). Never propose stripping them; correcting a
  comment that no longer matches behavior IS a valid finding.
- **Known trap**: textual reference scans (`grep` for a fn name) MISS
  comptime/string-keyed dispatch (plugin tables, action enum switches).
  Verify reachability via compiler or by reading dispatch sites before
  claiming dead code.
- **History lesson**: two recent simplification estimates overshot ~5x
  because behavior-contract hid inside what looked like mechanism (a diff
  cache held orphan-resurfacing semantics; layout "plumbing" lived in
  config types). Treat every cache/flag/table as guilty-of-behavior until
  proven otherwise, and say so explicitly in findings.
- Module resolution: build.zig maps every .zig basename stem to an importable
  module name; moving FILES is import-free, renaming breaks imports.
- Analysts are READ-ONLY. Produce findings; do not edit code.

## Subsystem 1 — Model (pure state) — 612 LoC
Files: `src/model/model.zig` (521), `src/model/store.zig` (91)
Role: single source of truth. Workspaces (tiled_order, focus_mru, params),
window entries (mask, mode: base/floating | minimized | fullscreen),
transitions returning whether state changed. Pure data + logic.
Invariants: no XCB, no globals beyond own struct; consumers poll or diff.
Sensitivities: pinned windows are mask==ALL_MASK (model.zig:337); scroll
viewport params live here (scroll_offset/prev_count) with caller-duty
contracts documented in layouts and pipeline.

## Subsystem 2 — Tiling math (pure placement) — 1039 LoC
Files: `src/tiling/{tiling,engine,hints}.zig`,
       `src/tiling/layouts/{master,fibonacci,leaf,grid,monocle,scroll}.zig`
Role: (layout kind, workarea, ordered windows) -> placements. Six algorithms
as separate files (user explicitly values this split — do NOT propose
merging). engine.zig holds View/List/emit infrastructure + triple-alias
re-exports (emitView/emitHidden/emitPlacement) that exist ONLY so sibling
files can share emit paths.
Sensitivities: bit-exact geometry parity is harness-pinned; master's
water-filling max_height redistribution and boost weights are subtle;
scroll has caller-duty preconditions (offset clamp) documented at top.

## Subsystem 3 — Sync (sole wire writer) — 535 LoC
Files: `src/sync/sync.zig` (430), `src/sync/wire.zig` (105)
Role: reconcile(model, env) -> unconditional apply of desired state via Sink
vtable. Write-only SENT LEDGER {last visible rect, parked} whose three
readers are behavioral contract (all-view orphan keep-last with park-
surviving rect — see header docs; winner raise on moved/unparked/
force_restack; lastRectFor floating-detach base). scheduled/takeScheduled
coalescing consumed by pipeline.postDispatch.
Sensitivities: recently rewritten (2026-08-23); S08-all-view previously
caught ledger losing park-surviving rect history. Parked/unpark transitions
and first-sight map ordering (map BEFORE geom) are pinned by sync_test
golden sequences.

## Subsystem 4 — Window lifecycle & protocol — 1945 LoC
Files: `src/window/window.zig` (1366), `borders.zig` (58),
       `wincache.zig` (169), `tracking.zig` (352)
Role: MapRequest handling (sequential property round trips, spawn queue +
cursor suppression), ConfigureRequest honoring, WM_DELETE/protocols,
WM_NORMAL_HINTS, border application, per-window caches (geometry/hints),
workspace-mask/MRU registries.
Sensitivities: performance comments document deliberate synchronous-once
choices ("MapRequest happens once per window"); wincache is EVENT-driven,
not a live mirror (floating/fullscreen/title read it at specific moments);
spawn suppression is harness-pinned (S16).

## Subsystem 5 — Actions & behaviors — 1558 LoC
Files: `src/window/actions.zig` (720),
       `src/window/behaviors/{floating,fullscreen,minimize,workspaces}.zig`
       (283/381/36/138)
Role: keybind action implementations (30 pub fns dispatched by enum switch
in input.zig — textual scans undercount callers), drag/move with snap,
EWMH fullscreen state machines, minimize/restore, workspace ops.
Sensitivities: actions call sync.lastRectFor / sync.forget; fullscreen
has deferred bar-show/hide timing that is user-visible; drag interacts
with reconcileUnderGrab (zero-round-trip rule BC24).

## Subsystem 6 — Focus — 779 LoC
Files: `src/window/focus.zig` (779)
Role: hover-focus, click-focus, MRU fallback, focus-suppression reasons
(spawn crossing), WM_TAKE_FOCUS/pending-confirm handling, pointer-sync
cancellation.
Sensitivities: S17-hover-focus and S16-close-respawn pin observable
timings; suppression reasons interplay with window.zig spawn queue;
five mechanisms braided through one file — prime readability-review
candidate but every internal state may be load-bearing.

## Subsystem 7 — Event loop & orchestration — 815 LoC
Files: `src/core/{core,events,pipeline,plugins,signals,x11}.zig`
       (93/376/162/84/90/10)
Role: X connection + event fetch/dispatch loop, plugin registry
(comptime table: bar segments register hooks incl. poll_timeout_ms),
pipeline choke points (preReconcileDuties, postDispatch, tilingOpFinished),
signal handling (reload).
Sensitivities: poll-timeout min-over-hooks semantics (clock depends on it);
postDispatch consumes takeScheduled then flushes once (I2: caller owns
flush timing).

## Subsystem 8 — Input & keybinds — 999 LoC
Files: `src/core/input/input.zig` (762), `xkbcommon.zig` (237)
Role: XKB key handling, keybind matching from config, modifier state,
action enum dispatch switch (the real caller graph of subsystem 5),
bar prompt key routing when focused.
Sensitivities: vim-mode prompt receives keys through here when focused;
keybind config surface is user contract.

## Subsystem 9 — Utils — 1220 LoC
Files: `src/core/utils/{utils,constants,debug,bench,refresh_rate,scale}.zig`
       (637/163/61/54/167/138)
Role: BoundedList, wire primitives (raise/restack/fetchPropertyToBuffer),
scaling (HiDPI), constants, debug logging, bench counters, refresh-rate
detection.
Sensitivities: utils.zig is imported near-universally — signature changes
ripple; refresh_rate.getDetectedRateHz was already verified dead and
removed; scan again independently if suspicious.

## Subsystem 10 — Bar shell & drawing — 2164 LoC
Files: `src/bar/{bar,drawing,render}.zig` (1519/537/108)
Role: plugin orchestration, dirty tracking, double-buffered snapshot slots
(captureStateIntoSlot ownership relay, snap_idx), batched title prefetch,
cairo/pango rendering, opaque vs ARGB visual paths, transparency.
Sensitivities: slot relay exists to avoid redundant queries during drags —
prior analysis suspected removable (direct queries sub-ms at real N) but
pixel output must stay identical; ARGB path untestable locally (Xvfb lacks
32-bit visuals) — proposals there need extra-careful risk notes.

## Subsystem 11 — Bar segments — 1182 LoC
Files: `src/bar/segments/{tags,clock}.zig` (134/109),
       `title/{title,carousel}.zig` (867/1), `layout/{layout,variants}.zig`
       (30/41)
Role: indicator rendering as plugins. Title segment includes carousel
rotation of long window lists (carousel.zig is a 1-line re-export shim —
investigate why). Clock is threadless (deadline math + lazy strftime),
recently re-architected — low priority.
Sensitivities: title.zig batch prefetch couples to subsystem 10's slots.

## Subsystem 12 — Prompt & vim mode — 1753 LoC
Files: `src/bar/segments/prompt/{prompt,vim}.zig` (1132/621)
Role: in-bar command prompt with vim-style motions/editing (user feature —
removal off the table), null_vim stub for feature-off builds.
Sensitivities: keystroke routing through input.zig; text editing state
machine is large but self-contained.

## Subsystem 13 — Config — 2899 LoC
Files: `src/config/{config,types,parser,fallback}.zig` (1414/619/784/82)
Role: hand-rolled TOML parser (no deps — deliberate), includes/themes
merging, typed accessors, fallback embedded default config, hot reload.
Sensitivities: parser accepts/rejects exactly today's inputs (users have
real configs); fallback embedding feeds zero-config boot; types.zig holds
the layout name/alias table (contract).

## Subsystem 14 — Build & test infrastructure — auxiliary
Files: `build.zig`, `src/test/*.zig`, `src/test/check-layers.sh`,
       `dev/harness/**`
Role: module discovery/feature-detection, unit tests, layer guards,
golden-scenario harness (Xvfb-based).
Note: analyze only for gaps (untested paths, guard blind spots) — these
are the yardsticks, changing them to make findings pass is forbidden.

## Cross-subsystem contracts (agents must not break)
- P2 purity: model + tiling compute from inputs only.
- P3 single writer: only sync issues geometry/map/stack/border requests.
- I2 flush ownership: callers flush; sync never does.
- §7.6 scheduling: focus-class changes coalesce via scheduled flag.
- Plugin hook order and poll_timeout_ms min-aggregation (clock correctness).
