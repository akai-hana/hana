# Hana Window Management — Architecture Rework Plan (v2, prescriptive)

**Status:** WP0 complete. WP1 in progress. This revision supersedes v1.
**Date:** 2026-08-21
**Prime directive for agents:** implementation is TRANSCRIPTION, not design.
Every module you are assigned is specified either as literal reference code
(Appendix E) or as an exhaustive numbered specification. You transcribe,
compile, and test. If you believe a semantic change to the spec is needed
(not just fixing a compile typo), STOP and report — do not improvise.

## Table of contents

1. How to use this document
2. Primer: hana + X11 concepts
3. Glossary
4. Current architecture tour
5. Why rework: case studies + structural diagnosis
6. Design principles P1–P5 and invariants I1–I8
7. Target architecture — full literal specifications
8. Behavioral contract BC01–BC26
9. Migration strategy and milestones
10. Work packages (mechanical task lists)
11. Agent coordination guide
12. Testing and verification
13. Enforcement
14. Risk register
15. Appendices: A reading order · B audit map · C decision log · E reference code

---

## 1. How to use this document

1. Read §2–§6 once. They explain platform, current system, and rationale.
2. Your Work Package (§10) tells you exactly which Appendix E parts to
   transcribe into which files, in which order, and which tests prove it done.
3. **Transcription rules:**
   - Copy reference code verbatim except: fix import paths, fix obvious
     compile typos, adapt names where the text says `RENAME`.
   - Reference code comments marked `INVARIANT:` must survive.
   - No new abstractions, no renames beyond instructed ones, no "improvements".
   - If code doesn't compile and the fix isn't mechanical (typo/import/missing
     field name), stop and report the compiler output.
4. Verification per WP is listed as exact commands. Run them; paste failures
   verbatim in your report instead of debugging beyond your mandate.

---

## 2. Primer

### 2.1 What hana is

Hana is an X11 tiling window manager written in Zig (~18,500 lines). It tiles
application windows automatically (master-stack, monocle, fibonacci, grid,
leaf, scroll layouts), supports floating windows with drag/resize/snapping,
virtual workspaces (tags), a clickable status bar, minimize, fullscreen, EWMH
hints, key/mouse bindings, hot-reloading TOML config.

```sh
zig build            # → zig-out/bin/hana
zig fmt --check      # formatting gate
```

There was no runtime test harness before WP0; `dev/harness/` now provides one
(WP0 deliverable).

### 2.2 X11 concepts everything depends on

1. The **X server owns the screen**; the WM is a privileged client reacting to
   events and issuing requests via xcb.
2. Window state manipulated with `xcb_configure_window`
   (position/size/border-width/stacking), `xcb_change_attributes` (border
   pixel), `xcb_map_window`.
3. Requests buffer client-side; queries return cookies;
   `xcb_..._reply()` blocks AND implicitly flushes the outgoing queue.
   This fact is load-bearing across the codebase.
4. `xcb_grab_server()` / `xcb_ungrab_server()`: exclusive processing window for
   atomic multi-step changes. Hana wraps: `utils.grabServer(conn)` /
   `utils.ungrabAndFlush(conn)` (ungrab + single flush).
5. **ConfigureRequest**: clients ask to move/resize themselves; WM honors or
   overrides. Honoring mutates server geometry behind our back.
6. ICCCM focus: `WM_PROTOCOLS` property advertises accept-input +
   `WM_TAKE_FOCUS` support; four input models; querying costs a round trip
   unless cached.
7. EWMH: `_NET_WM_STATE_FULLSCREEN`, `_NET_WM_PID`, desktop hints.
8. Compositors (picom) may not repaint a lone moved window without a restack;
   hana forces recomposite via `bar.raiseBar()` on restore-class transitions.
   Preserve this behavior.
9. **Parking**: hiding = configure x to -30000 (`constants.offscreen_x_position`,
   sentinel `-1000`), never unmap managed windows.
10. Workspaces: each window carries a workspace bitmask
    (`tracking.getWindowWorkspaceMask`); exactly one current workspace;
    visible = tagged on current ∧ not parked/minimized/hidden-by-fullscreen.

### 2.3 Technology facts

| Fact | Value |
|---|---|
| Geometry | `utils.Rect { x: i16, y: i16, width: u16, height: u16, border_width (defaulted) }` |
| Global state | `core.getState()` → conn/screen/config |
| Compile flags | `build_options.has_tiling`, `.has_bar` |
| Perf counters | `"bench"` build option exists (`build.zig` ~line 50) |
| Workspace id | `core.WorkspaceId` (has `.index`), mask bit = `tracking.workspaceBit(idx)` |

## 3. Glossary

| Term | Meaning |
|---|---|
| park/parked | Configured offscreen (x=-30000) instead of unmapped |
| grab | Server grab for atomicity |
| flush | Send buffered requests once (`ungrabAndFlush`) |
| round trip | Blocking request→reply wait; also implicitly flushes |
| cookie | Handle to an in-flight query reply |
| retile | Run layout algorithm, push geometries |
| CacheMap | Legacy per-window mirror cache `{rect,border,hints,applied_border_width}` |
| replay path | Fast switch-in resending cached rects (`workspace_geom_valid_bits`) |
| ping-pong | Bar's two snapshot slots A/B |
| MRU | Per-workspace focus history |
| Mode | Target-arch exclusive window state: base/fullscreen/minimized |
| Placement | Pure layout output `{win, rect, visible}` |
| reconcile | Sync diff desired-vs-last-sent emitting minimal batch |
| strangler | New system beside old; migrate callers piecewise |
| train step | One sequential action migration (a…h), §9.2 |

---

## 4. Current architecture tour

### 4.1 Module map (LOC verified)

| File | LOC | Role |
|---|---|---|
| `core/main.zig` | 105 | entrypoint/init order |
| `core/core.zig` | 95 | global State; `getState()` |
| `core/events.zig` | 371 | event loop; `handleConfigReload` |
| `core/plugins.zig` | 58 | `fanOut("reload")` |
| `core/input/input.zig` | 823 | binds/mouse; `finishTilingOp` |
| `core/utils/utils.zig` | 639 | Rect, grabs/flush, parking, borders helpers |
| `core/utils/constants.zig` | 152 | offscreen constants |
| `config/*` | 2899 | TOML config + hot reload |
| `bar/bar.zig` | 1571 | snapshots ping-pong; `captureStateIntoSlot`; `redrawInsideGrab`/`commitInsideGrab`; `raiseBar` |
| `window/window.zig` | 1597 | MapRequest/ConfigureRequest; focus-prop caches; take-focus senders; border sweeps |
| `window/focus.zig` | 796 | setFocus family; CommitFlags; commitFocusTransition |
| `window/tracking.zig` | 489 | masks; iterators; prefetch; focus MRU |
| `window/borders.zig` | 57 | width/color/applyWidth/apply |
| `window/modules/minimize.zig` | 411 | g_minimized records; restore paths |
| `window/modules/fullscreen.zig` | 505 | per-ws records; enter/exit commits; EWMH |
| `window/modules/workspaces.zig` | 704 | moveWindowTo; switch hide/restore; all-view; pin |
| `window/modules/floating.zig` | 353 | drag/resize/snap |
| `window/modules/tiling/tiling.zig` | 1289 | pool+CacheMap+replay bits; retile family; dedup helpers |
| `window/modules/tiling/layouts.zig` | 261 | LayoutCtx; configureWithHints*; applyHintsToRect |
| `window/modules/tiling/modules/*` | 851 | master/fibonacci/grid/leaf/monocle/scroll |

### 4.2 Mechanisms

- **M1 reload ordering** (load-bearing): `plugins.fanOut("reload")` →
  `tiling.reloadConfig()` → `window.reloadBorders()`.
- **M2 birth**: `handleMapRequest` fires WM_NORMAL_HINTS + WM_PROTOCOLS +
  WM_HINTS cookies together, drains once. `resolveTargetWorkspace`: WM_CLASS
  rules → `_NET_WM_PID` fallback; discard unconsumed cookies on early return.
  Mask assigned via `moveWindowTo`/`registerWindow` BEFORE `addWindow`.
- **M3 mirror cache**: `WindowData{rect,border,hints,applied_border_width}`;
  `configureWithHintsImpl` sends only on rect change and updates cache;
  `updateBorderColor(create_if_missing=true)` for pixels;
  `markDirtyAndInvalidateGeom(s, affected_mask)` clears replay bits per
  affected ws; `removeWindow` evicts entry entirely.
- **M4 replay**: `restoreWorkspaceGeom()` replays cached rects when bit valid ∧
  `last_retile_area == workArea()`; else full retile.
- **M5 fullscreen**: save geom per-ws; park others; invalidate tiled neighbors'
  rects; raw configure screen-size + BW=0 + ABOVE; exit restores float geom or
  hands back to tiling then `applyBorder`.
- **M6 minimize**: record `{saved_fs, workspace_idx, tiling_index}`; evict
  cache; park; pre-grab refocus resolve (MRU tier → first visible, own ws);
  retile under grab. Restore: re-add at filtered index; retile OUTSIDE grab;
  blocking input-model resolve flushes batch; grab: applyBorder→map→focus→
  raiseBar→commitInsideGrab.
- **M7 switch**: hide parks non-shared + invalidates their rects; restore
  applies per-ws overrides → replay or full retile; shared windows skip re-map;
  prefetch geometries during switch-away.
- **M8 focus**: one live WM_PROTOCOLS reply yields model+take_focus bit
  (`getInputModelResolved`); pipelined cookie drained in
  `commitFocusTransition`; pointer_sync arms confirm cookie.
- **M9 bar**: title-diff inputs = {pending_force_title_redraw, focused change,
  is_invalidated, window list, minimized set}; `redrawInsideGrab` defers
  refetch frames via markDirty (never blocks under grab).
- **M10 input**: `finishTilingOp` = {border flush, bar.redrawInsideGrab, focus
  settle hooks, ungrabAndFlush}; floating drags mutate live with snapping.

## 5. Why rework

**Case A (regression, root-caused).** Dedup caches introduced for perf;
`applyFullscreenGeometry` sent BORDER_WIDTH=0 outside the cache and sweeps
sent pixel 0 around a `c != 0` guard that skipped recording. Exit-time dedup
compared against stale entries → skipped both restores → borderless window.
One forgotten writer out of six was enough.

**Case B.** After same rollout, un-minimized windows rendered broken until an
unrelated event. Geometry configure was always sent; stale border bookkeeping
polluted sessions, and the three "fixing" actions share one property: they
rebuild cache entries from scratch (unconditional re-sends).

| # | Structural flaw |
|---|---|
| D1 | N writers, one trust boundary: six sites send border/geometry raw; "cache mirrors server" is an unenforced convention |
| D2 | Mirror-of-server state incl. client-mutable fields (ConfigureRequest) |
| D3 | Imperative action sequences ~80% overlapping, diverging in details |
| D4 | Mode inference scattered across ≥5 structures (pool membership, tiling_index nullness, g_minimized, fs records, cache/replay bits) |
| D5 | Equality-dedup turns any lapse into permanent silent misbehavior elsewhere |

Appendix B maps all sixteen audit findings onto these flaws.

## 6. Principles and invariants

- **P1 Model is truth.** One authoritative structure for management state.
- **P2 Single writer.** Only sync sends geometry/border/map/stack requests;
  recording lives inside it.
- **P3 Actions are pure** Model→Model functions; zero XCB.
- **P4 Dedup safe-by-construction**: compare desired vs last-sent owned by P2's writer.
- **P5 Clients are inputs**: ConfigureRequests/properties flow through the model.

Invariants (codified runtime lore; preserve verbatim):

- **I1** No blocking round trip while holding the server grab.
- **I2** Atomic ops batch everything; exactly one flush at the end. A blocking
  reply may deliberately flush a prepared batch BEFORE grabbing.
- **I3** Pre-fired cookies are drained/discarded before any grab; none survive a return path.
- **I4** Restore-class transitions force full-scene restack (`raiseBar`).
- **I5** Honored ConfigureRequest updates the model first; sends derive from reconcile.
- **I6** Dedup only against last-sent owned by sync.
- **I7** Parking is modeled visibility, never emergent geometry.
- **I8** Capacity contracts: refuse-before-mutate (`max_minimized`), bounded buffers with defined overflow, no rollback paths.

---

## 7. Target architecture (prescriptive)

Layer rule (build-enforced later, §13):
`model` ← imports std+utils only · `layout` ← model types only ·
`sync` ← model+layout · actions ← model · entry points ← actions+sync.
**Only `src/sync/` may emit geometry/border/map/stack requests.**

### 7.1 Files you will create

| File | Contains | Spec |
|---|---|---|
| `src/model/store.zig` | bounded window-entry store | Appendix E.1 verbatim |
| `src/model/model.zig` | types + transitions | §7.2 types + Appendix E.2/E.3 verbatim |
| `src/model/model_test.zig` | unit tests | test table T1–T18 in WP1 |
| `src/layout/engine.zig` | View/Placement/compute dispatcher | §7.3 + Appendix E.4 |
| `src/layout/algo_{master,monocle,fibonacci,grid,leaf,scroll}.zig` | pure ports | transform recipe §10-WP2 |
| `src/sync/sync.zig` | LastSent + reconcile + grab helpers | §7.4 algorithm + Appendix E.5 |
| `src/actions.zig` | thin action wrappers used by entry points | Appendix E.6 |
| `src/pipeline.zig` | legacy/new dispatch flag | Appendix E.7 |

### 7.2 Model types (transcribe from Appendix E.2)

- `BaseMode = union(enum){ tiled, floating: utils.Rect }`
- `Mode = union(enum){ base: BaseMode, fullscreen: struct{ws: WSId, base: BaseMode}, minimized: struct{base: BaseMode, fullscreen_saved: ?utils.Rect} }`
- `Entry = struct{ mask: Mask, mode: Mode, size_hints: SizeHints = .{} }`
- `WsState = struct{ tiled_order: List(WindowId), params: LayoutParams }`
- `Model = struct{ store: Store, ws: [MAX_WS]WsState, current: WSId, focused: ?WindowId }`

Decisions already made (see also Appendix C): tiled membership is an ordered
list per workspace (kills filtered-index arithmetic); minimized remembers its
base mode + optional fullscreen rect (kills the float/tiled guess); fullscreen
is a window mode with ws tag (kills the per-ws record table); mask orthogonal
to mode; size hints are client-authored input data in the model.

### 7.3 Layout engine contract

```zig
pub const Placement = struct { win: WindowId, rect: utils.Rect, visible: bool };
pub const View = struct {
    order: []const WindowId,      // ws.tiled_order slice
    params: *const LayoutParams,
    workarea: utils.Rect,
    hints: *const HintsView,     // Entry.size_hints lookup via model store
    focused: ?WindowId,
};
pub fn compute(kind: LayoutKind, v: View, out: *List(Placement)) void;
```

Algorithm porting is a mechanical transform (WP2 recipe): each existing
algorithm keeps its math verbatim; every old emit call maps to exactly one of:

| Old call (layouts.zig / modules) | New code |
|---|---|
| `configureWithHintsAndRaiseIfVisible(ctx, win, rect)` | `out.append(.{win, applyHints(rect,hints), true})` |
| `configureWithHints(ctx, win, rect)` (background) | same, but `visible=false` only when algorithm hides it (monocle non-top), else `true` with `is_background` dropped — sync never raises background placements |
| `pushWindowOffscreenAndInvalidate(ctx, win)` | `out.append(.{win, undefined_rect, false})` |
| `focusedElse(ctx, wins, fallback)` | unchanged helper, pure |

### 7.4 Sync contract

```zig
pub const LastSent = struct { rect: utils.Rect, bw: u16, pixel: u32, parked: bool };
pub fn reconcile(m: *const Model, ctx: *Ctx) void;                  // caller flushes once
pub fn reconcileUnderGrab(m: *const Model, ctx: *Ctx) void;         // grab→reconcile→restack?→ungrabAndFlush
pub fn schedule(ctx: *Ctx) void;                                    // coalesced end-of-dispatch
```

RECONCILE ALGORITHM (transcribe Appendix E.5; numbered steps are normative):

1. `wa = workArea(ctx)` (screen minus bar).
2. `fs_win` := first window whose mode==`.fullscreen` and (mask bit of shown ws or ws==shown). If found: desired(fs_win)={screenRect, bw=0, pixel=0, parked=false, stack=ABOVE}; every other window tagged on shown ws ⇒ parked=true; windows not on shown ws ⇒ parked per step 4. Skip steps 3 for this branch's placements.
3. Else run `layout.compute(kind(m.ws[m.current]), view, &placements)` where `kind` resolves layout + variant + overrides exactly as today (`selectLayout` logic).
4. Build desired map over ALL store entries:
   - on shown ws ∧ placement exists ⇒ {placement.rect, bw=cfgBW(), pixel=colorFn(win,m), parked=!placement.visible}
   - floating on shown ws ⇒ {mode.floating rect, cfgBW, colorFn, parked=false}
   - fullscreen (branch 2 handled) else if fullscreen on other ws ⇒ parked
   - minimized ⇒ parked (rect irrelevant; keep last)
   - not tagged on shown ws ⇒ parked
5. Stacking: exactly one ABOVE per batch for focused-or-top visible window (I4 hook: callers pass `.force_restack` on restore-class ops → additionally raise bar/top); parked ⇒ BELOW; others none.
6. Diff each field vs `LastSent[win]`; queue ONLY deltas into the batch in this order: border pixel → border width → geometry(+stack flags merged into one configure_window) ; create missing LastSent entries on first sight.
7. Parked transitions must merge X + stack-mode BELOW into ONE configure_window call.
8. Update LastSent as queued; increment bench counters per request class.
9. Do NOT flush here. Caller owns I2 flushing. Never block (I1).

Policy functions (single definitions, no call-site variants):
`cfgBW() = config.tiling.border_width (already scaled at load)` ·
`colorFn(win,m) = focus/mode color — port borders.color() verbatim minus its fullscreen check (fullscreen zeroes via bw/pixel policy above)` ·
parked predicate as step 4.

Scheduling table (§7.6 of v1 preserved):

| Class | Mechanism |
|---|---|
| switch/minimize/restore/tag-move/fullscreen toggle | `reconcileUnderGrab` |
| focus change (color-only diff) | scheduled end-of-dispatch |
| drag tick | immediate reconcile, NO grab |
| inactive workspaces | none — parked rects deterministic; legacy replay machinery deleted in WP6 |

## 8. Behavioral contract (regression gates)

| ID | Scenario | Must observe |
|----|----------|--------------|
| BC01 | Spawn w/ WM_CLASS ws-rule | ruled ws, tiled, focused, bordered; M2 cookie pipeline intact |
| BC02 | PID fallback path | no leaked cookie on class-rule early return |
| BC03 | ConfigureRequest honored while floating | rect persists across min/restore |
| BC04 | ConfigureRequest while tiled | geometry ignored; BW honored+recorded |
| BC05 | Client sets own BW | recorded; survives retiles |
| BC06 | Minimize | park + MRU-tier fallback focus scoped to own ws + single-grab atomicity |
| BC07 | Un-minimize tiled | original slot; monocle shows it first frame |
| BC08 | Un-minimize from-fullscreen | slot re-added THEN fullscreen re-entered w/ saved rect |
| BC09 | Un-minimize-all | fs/plain partition; slot-sorted reinsert; LIFO focus |
| BC10 | Cross-ws specific restore | current ws undisturbed |
| BC11 | Destroy while minimized/fs | all refs cleaned incl. scroll prev_focused analog |
| BC12 | Tag-move minimized | record follows new ws |
| BC13 | Fullscreen enter | others parked; geom saved; EWMH set; deferred bar-hide fires |
| BC14 | Fullscreen exit | width AND pixel restored (hard gate — the fixed bug) |
| BC15 | Switch away/back | replay-equivalent fast path; correct fallback |
| BC16 | Pinned during switch | skip re-map; everywhere-visible |
| BC17 | All-view temp windows | mapped (fix 8.1) |
| BC18 | Tag-remove active | atomic refocus pre-grab resolve (fix 3.1) |
| BC19 | Pin-toggle | map inside grab (fix 3.2) |
| BC20 | Config reload | fanOut→reloadConfig→reloadBorders order; BW rescale; no double sends |
| BC21 | Drag + drop-to-tile | live updates; snap; finishTilingOp settle sequence |
| BC22 | Monocle spawn/restore | focused override shown first frame |
| BC23 | Swap-master | swapped window configured+raised last |
| BC24 | Bar under grabs | no blocking round trips inside grabs |
| BC25 | Focus change | ≤1 protocol round trip; correct take-focus dispatch; confirm retry |
| BC26 | Capacity | max_minimized refuse-before-mutate; bounded-buffer overflow paths |

---

## 9. Migration strategy

Strangler with runtime flag `HANA_MODEL_PIPELINE=1`. `src/pipeline.zig`
(Appendix E.7) holds one dispatch slot per train step; legacy path stays
byte-identical when flag unset. Port train, strictly sequential:

| Step | Ports | Legacy module read first |
|---|---|---|
| a | minimize / restore / restoreAll | `minimize.zig` (all 411 lines) |
| b | fullscreen enter/exit/toggle | `fullscreen.zig` |
| c | workspace switch | `workspaces.zig` |
| d | spawn/map/close lifecycle | `window.zig` M2 paths |
| e | tag-move / pin / all-view | `workspaces.zig` remainder |
| f | drag/resize + tiling-op finish | `floating.zig`, `input.zig` |
| g | config reload | `events.zig:handleConfigReload`, `tiling.reloadConfig` |
| h | retire-inactive + delete background retiles | `bar.retileAllWorkspaces` |

Milestones:

| ID | Exit criteria |
|----|---------------|
| M0 | **DONE** — harness + goldens captured from unmodified binary |
| M1 | model/layout/sync compile + unit tests green; unused by production; signatures match §7 exactly |
| M2 | train step a behind flag; parity green S01–S10; default remains legacy |
| M3 | steps b–h done; flag defaults ON; full suite green |
| M4 | WP6 deletion done; guards enforced; docs final |

## 10. Work packages

> Every WP below is transcription against §7 + Appendix E. If any step
> requires a decision not written here, STOP and report.

### WP1 — Model core  [lane B] — status: IN PROGRESS
1. Create `src/model/store.zig` = Appendix E.1 verbatim.
2. Create `src/model/model.zig`:
   a. Types block = Appendix E.2 verbatim.
   b. Transitions = Appendix E.3 verbatim.
   c. Imports: `std`, `utils` (Rect), constants (`MAX_WS` alias to the
      existing max-workspaces constant in `constants.zig` — reuse its name).
3. Create `src/model/model_test.zig` implementing test table T1–T18:

| # | Test |
|---|------|
| T01 | register → tiled in current ws order, mask set |
| T02 | register with hint_ws → mask bit of hinted ws |
| T03 | minimize tiled → mode.minimized.base==tiled; removed from tiled_order; CapacityFull when store full (pre-refused) |
| T04 | restore tiled → back at ORIGINAL index |
| T05 | minimize floating → base==floating(rect); restore returns rect |
| T06 | toggleFullscreen on tiled/fullscreen/minimized round trip; fullscreen_saved preserved through minimize-from-fullscreen (BC08) |
| T07 | switchTo updates current; visible-set helper correctness |
| T08 | moveWindowToWs retargets mask; minimized record follows (BC12) |
| T09 | pinToggle sets/clears all-bits; composes with every mode |
| T10 | allViewToggle round trip incl. temp-window tracking parity with legacy `enterAllView` semantics |
| T11 | reorderTiled bounds-checked; swapMaster master/stack swap |
| T12 | unregister cleans tiled_order/MRU/minimized/fs refs everywhere (BC11) |
| T13 | honorConfigureRequest: floating→accept+update rect; tiled→deny geometry accept BW; fullscreen→deny both |
| T14 | applyConfigReload rescales BW-dependent params only |
| T15 | setFocus updates focused+MRU; MRU capped (size const in E.2) |
| T16 | store remove-swap keeps iteration deterministic |
| T17 | I8: no function mutates before capacity check |
| T18 | determinism: same op sequence ⇒ identical store dump twice |

4. `zig test src/model/model_test.zig` green; `grep -r "xcb" src/model/` empty.

### WP2 — Layout engine  [lane C]
1. Create `src/layout/engine.zig` = Appendix E.4 verbatim (+ imports).
2. Move `applyHintsToRect` + helpers from `layouts.zig` unchanged into
   `src/layout/hints.zig`; re-export.
3. For each algorithm file create sibling under `src/layout/algo_*.zig` using
   the §7.3 transform table. Preserve each algorithm's math line-for-line;
   only emit calls change. monocle.zig is 37 lines — do it FIRST as the
   calibration example, and include the diff in your report for review.
4. Property tests: within-workarea; no overlap except monocle; coverage;
   determinism. `zig test src/layout/…` green; grep xcb empty.

### WP3 — Sync  [lane B after WP1]
1. Create `src/sync/sync.zig`: LastSent store + reconcile steps 1–9 (§7.4)
   transcribed from Appendix E.5; grab helpers; bench counters wired to the
   existing option.
2. Golden-sequence unit test: fake model + fake Ctx (record requests instead
   of sending) → assert exact request sequences for scenarios {spawn, color
   flip, fullscreen enter, park/unpark}.
3. Acceptance: tests green; `grep -rn "xcb_" src/sync/ | wc -l` > 0 ONLY
   inside send shims.

### WP4 — Bridge  [lane B after WP3]
1. Create `src/pipeline.zig` = Appendix E.7 verbatim.
2. Insert marked call sites (each ≤30 lines, comment `// PIPELINE:`):
   events dispatch tail → `pipeline.postDispatch()`; input finishTilingOp →
   `pipeline.tilingOpFinished()`; drag update → `pipeline.dragTick()`.
3. Flag OFF ⇒ byte-identical behavior vs goldens (harness).

### WP5 — Train steps a–h  [lane B sequential]
Per step: read listed legacy module fully → implement wiring in
`src/actions.zig` (E.6) → enable its pipeline slot → run its BC scenarios →
PR. Do not touch later steps' slots.

### WP6 — Deletion  [after M3] · delete legacy bodies inverse order h→a;
keep SizeHints type (re-homed), pure helpers now in layout/.
### WP7 — Guards & docs  [lane C after WP3] · scripts/check-layers.sh per §13;
ARCHITECTURE.md from §6–§7.
### WP8 — Final audit & perf report  [A+B after M4] · 16-finding checklist +
±10% request-count budget per event class; results → docs/rework-report.md.

## 11. Agent coordination

```
Lane A (WP0 ✔ ───────────────────────────────► WP8 support)
Lane B (WP1 ● ─► WP3 ─► WP4 ─► WP5[a..h] ─► WP6 ─► WP8)
Lane C (WP2 ──────────► WP7 ──────────────────────────►)
```

- Contracts (§7) are frozen; changes only via coordinator + changelog.
- Ownership: each WP's created dirs exclusive; legacy tree read-only except
  WP4's marked insertions and WP6 deletions.
- One PR per WP or train step; prefix `wp<n>:` / `train(<step>):`.
- Conflict protocol: out-of-ownership need ⇒ halt + written rationale.

---

## 12. Testing and verification

- **Harness** (WP0 ✔): Xvfb headless runner `dev/harness/run-scenario.sh`;
  outputs normalized `xwininfo -root -tree`, `xprop`, bench counters under
  `dev/harness/out/<scenario>/`; goldens in `dev/harness/golden/`.
- **Scenarios S01–S15**: spawn-tiled · close · min/restore · min-from-fs ·
  restore-all · switch-basic · pinned · all-view · tag-move · fs-cycle
  (BC14 gate) · configure-honored · client-bw · reload · drag-snap ·
  monocle-focus.
- **Parity:** flag OFF ⇒ byte-identical to goldens; flag ON ⇒ semantic match
  (stacking ties/timing jitter allowed).
- **Perf budget:** per event-class request counts within ±10% of post-audit
  baseline; latency-critical: focus change ≤1 protocol round trip, drag tick,
  switch-in fast path.

## 13. Enforcement

WP7 delivers `scripts/check-layers.sh` wired into `zig build check`:

1. `xcb_configure_window | XCB_CONFIG_WINDOW_* | xcb_map_window |
   xcb_change_attributes` only under `src/sync/`.
2. `xcb_grab_server` only under `src/sync/` (+ legacy allowlist file, emptied
   at M4).
3. No xcb imports in `src/model/`, `src/layout/`.
4. `zig fmt --check`.

Rationale: the §5 bug class required arbitrary files to be able to send;
after enforcement the violation is a build failure.

## 14. Risk register

| ID | Risk | Mitigation |
|----|------|------------|
| R1 | Compositor quirk regression (I4 removal) | I4 codified; S03/S10 assert restack |
| R2 | Focus protocol subtleties | protocol layer untouched until train f; BC25 gate |
| R3 | Legacy unknowns | train step requires full module read first; harness catches drift |
| R4 | Reconcile perf | counters + ±10% budget |
| R5 | Switch-in slowdown after replay deletion | parked-rect derivation replaces replay; measure S06 |
| R6 | Dual-path divergence post-M3 | WP6 deletes legacy immediately after soak |
| R7 | Agent conflicts | ownership matrix + halt protocol |
| R8 | Harness flakiness | aggressive normalization; Xephyr escape hatch |
| R9 | Drag latency | immediate no-grab path for drags |
| R10 | Capacity regressions | I8 asserts; BC26 |

---

## 15. Appendix A — Reading order for agents

1. §§1, 6, 7, 8 of this document. 2. Your WP's Appendix E parts verbatim.
3. For train steps: the listed legacy module end-to-end BEFORE writing code.
4. Report format: commands run + outputs; deviations = none expected.

## Appendix B — Audit findings ↔ structural resolution

| Finding | Resolved by |
|---|---|
| 1.1 grab-held bar round trips | I1 + sync batching |
| 1.2 double WM_PROTOCOLS query | retained single-query design (BC25) |
| 1.3 MapRequest serial queries | M2 pipeline preserved in adapter |
| 2.1 float border sweep redundancy | P4 field-diff supersedes dedup caches |
| 2.2 shared-window re-map | visibility diff skips no-ops |
| 2.3 offscreen re-push undecidability | I7 modeled parking |
| 2.4 BORDER_WIDTH spam | LastSent.bw diff |
| 3.1 moveWindowTo layout hole | action purity + reconcileUnderGrab |
| 3.2 pin-toggle race | same |
| 4.1 global cache wipes | obsolete — no wipe exists in target |
| 4.2 ConfigureRequest desync | P5/I5 flow (T13) |
| 5.1 blanket-invalidation band-aid | diff-based sends inherent |
| 6.1 reload double-send | ordered single writer (BC20) |
| 7.1 cookie leak | I3 asserted |
| 8.1 all-view unmapped temps | visibility model (BC17/T10) |

## Appendix C — Decision log (v1 open questions, now closed)

| ID | Decision |
|----|----------|
| C-D1 | Floating windows do NOT occupy tiled_order slots; restore-to-float returns saved rect directly. No slot memory for floats. |
| C-D2 | Scroll layout prev_focused: model-owned field `params.scroll_prev: ?WindowId`; engine consumes read-only; `model.setFocus` updates it when current layout is scroll. Engine stays pure. |
| C-D3 | EWMH workspace/desktop hints emitted by sync whenever a window's mask or current-ws changes (policy row added to reconcile step 6 queue order: hints last). |
| C-D4 | Single-screen assumption kept; workArea() computed inside sync from ctx; future XRandR support touches sync only. |
| C-D5 | Store iteration determinism: parallel `order` array, append on put, swap-remove on delete (T16). |
| C-D6 | WSId reuses `core.WorkspaceId`; MAX_WS aliases the existing max-workspaces constant in constants.zig (reuse its exact name at import site). |
| C-D7 | `colorFn` ports borders.color() verbatim EXCEPT fullscreen zeroing moves into sync policy (fullscreen ⇒ pixel 0 AND bw 0) so mode logic lives in one place. |
