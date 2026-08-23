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

## Appendix E — Reference code (transcribe verbatim)

> Rules: copy as-is; fix only import paths/compile typos; comments tagged
> `INVARIANT` must survive. Bodies below are complete Zig unless marked
> PSEUDOCODE-BLOCK (then translate 1:1 to Zig, keeping step order).

### E.1 `src/model/store.zig`

```zig
//! Bounded window store. INVARIANT(I8): a full-store put refuses BEFORE any
//! mutation. Iteration order = insertion order (decision C-D5).
const std = @import("std");

pub fn Store(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Error = error{StoreFull};

        keys: [capacity]K = undefined,
        vals: [capacity]V = undefined,
        /// slot indices in insertion sequence; order[i] < len for i < len.
        order: [capacity]usize = undefined,
        len: usize = 0,

        pub fn getPtr(self: *Self, k: K) ?*V {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) return &self.vals[i];
            }
            return null;
        }

        pub fn get(self: *const Self, k: K) ?V {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) return self.vals[i];
            }
            return null;
        }

        pub fn has(self: *const Self, k: K) bool {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) return true;
            }
            return false;
        }

        pub fn put(self: *Self, k: K, v: V) Error!*V {
            if (self.getPtr(k)) |slot| {
                slot.* = v;
                return slot;
            }
            if (self.len == capacity) return Error.StoreFull;
            const s = self.len;
            self.keys[s] = k;
            self.vals[s] = v;
            self.order[s] = s;
            self.len += 1;
            return &self.vals[s];
        }

        /// Swap-remove keeping order[] consistent: when the last live element
        /// moves into the freed slot, its index inside order[] is rewritten.
        pub fn remove(self: *Self, k: K) bool {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.keys[i] == k) {
                    const last = self.len - 1;
                    if (i != last) {
                        var p: usize = 0;
                        while (p <= last) : (p += 1) {
                            if (self.order[p] == last) {
                                self.order[p] = i;
                                break;
                            }
                        }
                        self.keys[i] = self.keys[last];
                        self.vals[i] = self.vals[last];
                    }
                    self.len = last;
                    return true;
                }
            }
            return false;
        }

        pub const Item = struct { key: K, val: *const V };

        /// seq must be < count(). Iterates in insertion order.
        pub fn at(self: *const Self, seq: usize) Item {
            const s = self.order[seq];
            return .{ .key = self.keys[s], .val = &self.vals[s] };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
```

### E.2 `src/model/model.zig` — types block

```zig
//! INVARIANT(P1): single source of truth for management state.
//! Layer rule: imports are std + utils + constants ONLY. No xcb.
const std = @import("std");
const utils = @import("utils");
const constants = @import("constants");

pub const WindowId = u32;
/// Local alias so model never imports core. Convert core.WorkspaceId via
/// `.index` at entry points (refines decision C-D6).
pub const WSId = u16;
pub const Mask = u64;

pub inline fn bit(ws: WSId) Mask {
    return @as(Mask, 1) << @intCast(ws);
}

/// REUSE the exact identifier that exists in constants.zig for the max
/// workspace count (`max_workspaces`); if named differently there, alias it
/// here under MAX_WS without renaming the original.
const MAX_WS = constants.max_workspaces;
/// REUSE the exact identifier for the minimize capacity constant used by
/// legacy minimize.zig (`max_minimized`).
const MAX_MINIMIZED = constants.max_minimized;

pub const ALL_MASK: Mask = blk: {
    var m: Mask = 0;
    for (0..MAX_WS) |i| m |= @as(Mask, 1) << @intCast(i);
    break :blk m;
};

/// STRANGLER COPY: duplicate of layouts.SizeHints. Field-for-field identical;
/// pipeline converts between the two during migration (E.7). Do NOT import
/// layouts from here (layer rule).
pub const SizeHints = struct {
    // TRANSCRIBE FIELD-FOR-FIELD from `layouts.SizeHints`
    // (src/window/modules/tiling/layouts.zig). Keep defaults identical.
};

pub const LayoutKind = enum { master, monocle, fibonacci, grid, leaf, scroll };

pub const LayoutParams = struct {
    kind: LayoutKind = .master,
    variant_idx: u8 = 0,
    master_width: f32 = 0.5,
    master_count: u8 = 1,
    stack_balance: f32 = 0,
    scroll_prev: ?WindowId = null, // decision C-D2
};

pub const BaseMode = union(enum) {
    /// Home workspace membership; visibility on other tagged workspaces is a
    /// sync-time mask filter (engine stays mask-agnostic).
    tiled: struct { home: WSId },
    floating: utils.Rect,
};

/// Contract refinement vs §7.2 (changelog 2026-08-21): minimized stores the
/// ENTIRE previous mode plus its tiled slot, which preserves BC08 exactly
/// (restore pops straight back into fullscreen when that was prior).
pub const Mode = union(enum) {
    base: BaseMode,
    fullscreen: struct { ws: WSId, base: BaseMode },
    minimized: struct { prev: Mode, slot: ?usize },
};

pub const Entry = struct {
    mask: Mask,
    mode: Mode,
    size_hints: SizeHints = .{},
};

pub const WsState = struct {
    tiled_order: std.ArrayListUnmanaged(WindowId) = .{},
    params: LayoutParams = .{},
};

pub const store_capacity = 512;
pub const mru_capacity = 16;
pub const StoreT = @import("store.zig").Store(WindowId, Entry, store_capacity);

pub const Model = struct {
    gpa: std.mem.Allocator,
    store: StoreT = .{},
    ws: [MAX_WS]WsState = [_]WsState{.{}} ** MAX_WS,
    current: WSId = 0,
    focused: ?WindowId = null,
    all_view_active: bool = false,
};
```

### E.3 `src/model/model.zig` — transitions block

APPLY WHILE TRANSCRIBING (contract refinements, changelog 2026-08-21):
1. In E.2, change `BaseMode.tiled` from `struct { home: WSId }` to bare
   `tiled` — home is DERIVED (exactly one list contains the window; T16
   asserts it). Delete the now-unused `homeOf` concept.
2. In E.2, add to `WsState`: `focus_mru: std.ArrayListUnmanaged(WindowId) = .{},`.
3. Add to E.2 types: `pub fn lowestBit(m: Mask) WSId { return @intCast(@ctz(m)); }`.

```zig
const Order = std.ArrayListUnmanaged(WindowId);

pub fn findInOrder(list: *const Order, win: WindowId) ?usize {
    for (list.items, 0..) |w, i| {
        if (w == win) return i;
    }
    return null;
}

fn removeValue(list: *Order, win: WindowId) void {
    if (findInOrder(list, win)) |i| _ = list.orderedRemove(i);
}

/// The workspace whose tiled_order holds win (single-membership invariant).
pub fn findHome(m: *const Model, win: WindowId) ?WSId {
    for (&m.ws, 0..) |*s, i| {
        if (findInOrder(&s.tiled_order, win) != null) return @intCast(i);
    }
    return null;
}

fn baseOf(mode: Mode) BaseMode {
    return switch (mode) {
        .base => |b| b,
        .fullscreen => |f| f.base,
        .minimized => |mm| baseOf(mm.prev),
    };
}

fn countMinimized(m: *const Model) usize {
    var n: usize = 0;
    for (0..m.store.count()) |i| {
        if (m.store.at(i).val.mode == .minimized) n += 1;
    }
    return n;
}

fn removeFromMruAll(m: *Model, win: WindowId) void {
    for (&m.ws) |*s| removeValue(&s.focus_mru, win);
}

pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) void {
    if (m.store.has(win)) return;
    const target: WSId = hint_ws orelse m.current;
    // INVARIANT(I8): StoreFull ⇒ refuse BEFORE any mutation; roll back on OOM.
    m.store.put(win, .{
        .mask = bit(target),
        .mode = .{ .base = .tiled },
    }) catch return;
    m.ws[target].tiled_order.append(m.gpa, win) catch {
        _ = m.store.remove(win);
    };
}

pub fn unregister(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    if (findHome(m, win)) |h| removeValue(&m.ws[h].tiled_order, win);
    removeFromMruAll(m, win);
    for (&m.ws) |*s| {
        if (s.params.scroll_prev == win) s.params.scroll_prev = null;
    }
    if (m.focused == win) m.focused = null;
    _ = m.store.remove(win);
}

pub const MinimizeError = error{CapacityFull};

pub fn minimize(m: *Model, win: WindowId) MinimizeError!void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mode == .minimized) return;
    // INVARIANT(I8): capacity check BEFORE any mutation (T17).
    if (countMinimized(m) >= MAX_MINIMIZED) return error.CapacityFull;
    var slot: ?usize = null;
    if (findHome(m, win)) |h| {
        slot = findInOrder(&m.ws[h].tiled_order, win);
        removeValue(&m.ws[h].tiled_order, win);
    }
    const prev = e.mode;
    e.mode = .{ .minimized = .{ .prev = prev, .slot = slot } };
}

pub fn restore(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mode != .minimized) return;
    const mm = e.mode.minimized;
    const h: WSId = lowestBit(e.mask); // follows tag-moves made while hidden (BC12)
    const list = &m.ws[h].tiled_order;
    list.append(m.gpa, win) catch return;
    if (mm.slot) |s| {
        const last = list.items.len - 1;
        if (s < last) {
            _ = list.orderedRemove(last);
            list.insert(m.gpa, s, win) catch {};
        }
    }
    e.mode = mm.prev;
}

fn slotLess(a: ?usize, b: ?usize) bool {
    if (a == null) return false;
    if (b == null) return true;
    return a.? < b.?;
}

pub fn restoreAllOnWs(m: *Model, ws: WSId) void {
    var wins: [MAX_MINIMIZED]WindowId = undefined;
    var slots: [MAX_MINIMIZED]?usize = undefined;
    var n: usize = 0;
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.mode == .minimized and it.val.mask & bit(ws) != 0) {
            wins[n] = it.key;
            slots[n] = it.val.mode.minimized.slot;
            n += 1;
        }
    }
    // insertion sort by slot ascending, nulls last (BC09)
    for (1..n) |a| {
        const w = wins[a];
        const s = slots[a];
        var b = a;
        while (b > 0 and slotLess(s, slots[b - 1])) : (b -= 1) {
            wins[b] = wins[b - 1];
            slots[b] = slots[b - 1];
        }
        wins[b] = w;
        slots[b] = s;
    }
    for (0..n) |i| restore(m, wins[i]);
}

pub fn toggleFullscreen(m: *Model, win: WindowId) bool {
    const e = m.store.getPtr(win) orelse return false;
    switch (e.mode) {
        .base => |b| {
            e.mode = .{ .fullscreen = .{ .ws = m.current, .base = b } };
            return true;
        },
        .fullscreen => |f| {
            e.mode = .{ .base = f.base };
            return true;
        },
        .minimized => return false,
    }
}

pub fn switchTo(m: *Model, ws: WSId) void {
    m.current = ws;
}

pub fn moveWindowToWs(m: *Model, win: WindowId, ws: WSId) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mask == ALL_MASK) return; // pinned stays everywhere-visible
    if (e.mode == .minimized) {
        e.mask = bit(ws); // BC12: record follows the move
        return;
    }
    e.mask = bit(ws);
    if (findHome(m, win)) |h| {
        if (h != ws) {
            removeValue(&m.ws[h].tiled_order, win);
            m.ws[ws].tiled_order.append(m.gpa, win) catch {};
        }
    }
}

pub fn pinToggle(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask = if (e.mask == ALL_MASK) bit(m.current) else ALL_MASK;
}

pub fn allViewToggle(m: *Model) bool {
    m.all_view_active = !m.all_view_active;
    return m.all_view_active;
}

pub fn reorderTiled(m: *Model, win: WindowId, idx_in: usize) void {
    const h = findHome(m, win) orelse return;
    const list = &m.ws[h].tiled_order;
    const from = findInOrder(list, win) orelse return;
    const idx = @min(idx_in, list.items.len - 1);
    _ = list.orderedRemove(from);
    list.insert(m.gpa, idx, win) catch {};
}

pub fn swapMaster(m: *Model) void {
    const list = &m.ws[m.current].tiled_order;
    if (list.items.len < 2) return;
    const tmp = list.items[0];
    list.items[0] = list.items[1];
    list.items[1] = tmp;
}

pub fn cycleLayout(m: *Model, dir: i32) void {
    const p = &m.ws[m.current].params;
    const n: i32 = @typeInfo(LayoutKind).@"enum".fields.len;
    const cur: i32 = @intCast(@intFromEnum(p.kind));
    var next = @mod(cur + dir, n);
    if (next < 0) next += n;
    p.kind = @enumFromInt(@as(u3, @intCast(next)));
    p.variant_idx = 0;
}

pub fn adjustMasterWidth(m: *Model, delta: f32) void {
    const p = &m.ws[m.current].params;
    p.master_width = std.math.clamp(p.master_width + delta, 0.05, 0.95);
}

pub fn setFloatingRect(m: *Model, win: WindowId, r: utils.Rect) void {
    const e = m.store.getPtr(win) orelse return;
    switch (e.mode) {
        .base => |*bm| switch (bm.*) {
            .floating => |*fr| fr.* = r,
            .tiled => {},
        },
        else => {},
    }
}

pub const ConfigureReq = struct {
    x: ?i16 = null,
    y: ?i16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    border_width: ?u16 = null,
};

pub const HonorDecision = enum { geometry_applied, border_only, ignored };

pub fn honorConfigureRequest(m: *Model, win: WindowId, req: ConfigureReq) HonorDecision {
    const e = m.store.getPtr(win) orelse return .ignored;
    switch (e.mode) {
        .base => |*bm| switch (bm.*) {
            .floating => |*r| {
                if (req.x) |v| r.x = v;
                if (req.y) |v| r.y = v;
                if (req.width) |v| r.width = v;
                if (req.height) |v| r.height = v;
                return .geometry_applied;
            },
            .tiled => {
                // Geometry denied. BW honored; recording is SYNC's job (P5/I5).
                if (req.border_width != null) return .border_only;
                return .ignored;
            },
        },
        .fullscreen => return .ignored,
        .minimized => return .ignored,
    }
}

pub fn applyConfigReload(m: *Model, tpl: LayoutParams) void {
    for (&m.ws) |*s| {
        const keep_prev = s.params.scroll_prev;
        s.params = tpl;
        s.params.scroll_prev = keep_prev;
    }
}

pub fn setFocus(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    m.focused = win;
    const list = &m.ws[m.current].focus_mru;
    removeValue(list, win);
    list.insert(m.gpa, 0, win) catch {};
    if (list.items.len > mru_capacity) list.shrinkRetainingCapacity(mru_capacity);
    if (m.ws[m.current].params.kind == .scroll) {
        m.ws[m.current].params.scroll_prev = win; // decision C-D2
    }
}

pub fn visibleOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const e = m.store.get(win) orelse return false;
    if (e.mode == .minimized) return false;
    if (m.all_view_active) return true;
    return e.mask & bit(ws) != 0;
}
```

### E.4 `src/layout/engine.zig` (relative imports keep standalone `zig test` working)

```zig
//! INVARIANT(P2): pure. Reads model types; emits Placements. No xcb.
const std = @import("std");
const utils = @import("utils");
const model = @import("../model/model.zig");

pub const Placement = struct {
    win: model.WindowId,
    rect: utils.Rect,
    visible: bool,
};

/// Read-only size-hint lookup over the model store.
pub const HintsView = struct {
    m: *const model.Model,
    pub fn forWin(self: *const HintsView, win: model.WindowId) *const model.SizeHints {
        return if (self.m.store.getPtr(@constCast(self.m), win)) ... // see note
    }
};
```
NOTE (fix while transcribing): getPtr needs mutable self; instead implement
`forWin` scanning `m.store` via `at(i)` copies, returning a pointer is not
possible on const — return BY VALUE `model.SizeHints` with default fallback:
`pub fn forWin(...) model.SizeHints`. Algorithms take hints by value.

```zig
pub const View = struct {
    order: []const model.WindowId,
    params: *const model.LayoutParams,
    workarea: utils.Rect,
    hints: *const HintsView,
    focused: ?model.WindowId,
};

pub const List = std.ArrayList(Placement);

/// Port applyHintsToRect VERBATIM from src/window/modules/tiling/layouts.zig
/// (WP2 step 2); signature: pub fn applyHints(r: utils.Rect, h: model.SizeHints) utils.Rect

pub fn compute(kind: model.LayoutKind, v: View, out: *List) void {
    out.clearRetainingCapacity();
    switch (kind) {
        .master => @import("algo_master.zig").compute(v, out),
        .monocle => @import("algo_monocle.zig").compute(v, out),
        .fibonacci => @import("algo_fibonacci.zig").compute(v, out),
        .grid => @import("algo_grid.zig").compute(v, out),
        .leaf => @import("algo_leaf.zig").compute(v, out),
        .scroll => @import("algo_scroll.zig").compute(v, out),
    }
}
```
Each algo_*.zig: `pub fn compute(v: View, out: *List) void` implementing the
§7.3 transform of its legacy counterpart. monocle FIRST (calibration diff).

### E.5 `src/sync/sync.zig` — PSEUDOCODE-BLOCK (translate 1:1, keep step comments)

```zig
//! INVARIANT(P3): ONLY this module sends geometry/border/map/stack requests.
//! Shims below wrap EXISTING xcb patterns — do not invent new ones:
//!   sendGeometry(win, rect, stack_mode?) ≙ window.zig configureWindowGeom
//!   sendBorder(win, bw, pixel)            ≙ borders.applyWidth + borders.apply
//!   parkWindow(win)                       ≙ pushWindowOffscreenAndInvalidate
//!   raiseTop(win)/lowerBelow(win)         ≙ restack helpers used today
//!   flush()                               ≙ conn.flush()  (caller owns timing, I2)

pub const LastSent = struct { rect: utils.Rect, bw: u16, pixel: u32, parked: bool };

pub const State = struct {
    last_sent: std.AutoArrayHashMapUnmanaged(model.WindowId, LastSent) = .{},
    bench_cfg: usize = 0, bench_border: usize = 0, bench_park: usize = 0,
};
pub var st: State = .{};   // owned by compositor process; reset on reconnect

pub fn reconcile(m: *const model.Model, ctx: *Ctx) void {
    // STEP 1: wa := workArea(ctx)  (screen minus bar; reuse current helper).
    // STEP 2: fs_win := first entry where mode==.fullscreen and
    //         (visibleOn(m,win,shown) or mode.fullscreen.ws==shown);
    //         if found -> queue(fs_win: screenRect, bw=0, pixel=0,
    //             parked=false, stack=ABOVE); mark ALL other entries whose
    //             mask touches shown-ws visibility as parked=true.
    // STEP 3: else placements := layout.compute(kind(m.ws[shown].params),
    //             view{ order: FILTERED slice = m.ws[shown].tiled_order items
    //             whose entry.mask & bit(shown)!=0, params, wa, hints, focused })
    // STEP 4: desired map over ALL store entries (at(i) iteration):
    //           minimized                      -> parked (keep last rect)
    //           fullscreen (not step-2 winner) -> parked
    //           base.tiled on shown w/ placement -> {placement.rect,
    //             cfgBW(), colorFn(win,m), parked=!placement.visible}
    //           base.floating on shown          -> {mode rect, cfgBW(),
    //             colorFn, parked=false}
    //           mask lacks bit(shown) AND !all_view_active -> parked
    // STEP 5: stacking winner = focused-or-last-visible placement;
    //         force_restack flag (I4 hook, passed via ReconcileOpts) adds
    //         ABOVE to bar/top handling; parked -> BELOW.
    // STEP 6..8: per entry diff vs last_sent; queue ONLY deltas into ONE
    //         batch array in order pixel -> bw -> geometry(+stack flags
    //         merged); parked transitions MUST merge X-offscreen + BELOW
    //         into a single configure_window call; create last_sent entry
    //         on first sight; bump bench counters.
    // STEP 9: DO NOT FLUSH HERE. Return batch to caller.
}

pub const ReconcileOpts = struct { force_restack: bool = false };

pub fn reconcileUnderGrab(m: *const model.Model, ctx: *Ctx, opts: ReconcileOpts) void {
    // I4: grab_server -> reconcile(opts) -> optional top/bar restack ->
    // ungrabAndFlush. Zero round trips inside (BC24).
}

pub fn schedule(ctx: *Ctx) void {
    // coalesced end-of-dispatch reconcile; invoked from pipeline.postDispatch
}
```

### E.6 `src/actions.zig` — wrappers (one full example; others same shape)

```zig
pub fn minimize(ctx: *Ctx, win: model.WindowId) void {
    const m = pipeline.model();
    model.minimize(m, win) catch return; // BC26 pre-refusal (CapacityFull)
    if (ctx.focused_window_id == win) focusFallback(m, ctx);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true }); // BC06 atomicity
}

/// BC06 fallback: own-workspace scope only. Order: current ws focus_mru ->
/// reversed tiled_order -> any floating on ws. First visibleOn(current) wins.
pub fn focusFallback(m: *const model.Model, ctx: *Ctx) void {
    // PSEUDOCODE-BLOCK: iterate candidates per stated order; skip win being
    // minimized; call legacy take-focus dispatch on winner (protocol layer
    // untouched until train f, R2).
}
```
Remaining actions (same wrapper shape): spawn/map/close, restore, restoreAll,
fullscreenToggle, switchTo, moveWindowToWs, pinToggle, allViewToggle,
reorderTiled, swapMaster, cycleLayout, adjustMasterWidth, dragTick(no grab),
configReload. Each maps 1:1 to a §7.2 transition + one sync entry per §7.6
scheduling table.

### E.7 `src/pipeline.zig`

```zig
//! Dual-path dispatch during migration. Flag OFF ⇒ byte-identical legacy.
pub var enabled: bool = false; // init(): getenv("HANA_MODEL_PIPELINE")=="1"

var instance: model.Model = undefined;
pub fn init(gpa: std.mem.Allocator) void { instance = .{ .gpa = gpa }; }
pub inline fn model() *model.Model { return &instance; }

/// Field-by-field conversion; delete both sides in WP6.
pub fn convertHints(src: layouts_hints.LegacySizeHints) model.SizeHints {
    var d: model.SizeHints = .{};
    // TRANSCRIBE: assign every field src.X -> d.X (names identical).
    return d;
}

pub inline fn postDispatch() void {
    if (!enabled) return;
    sync.schedule(ctx());
}
pub inline fn tilingOpFinished() void { if (enabled) reconcileUnderGrabNow(.{}); }
pub inline fn dragTick() void { if (enabled) reconcileNow(); }
pub inline fn reconcileUnderGrabNow(o: sync.ReconcileOpts) void { /* WP5 */ }
pub inline fn reconcileNow() void { /* WP5 */ }
```

## Appendix D — Changelog of contract refinements

| Date | Change | Reason |
|------|--------|--------|
| 2026-08-21 | `Mode.minimized = { prev: Mode, slot: ?usize }` replaces `{base, fullscreen_saved}` | restores straight back into fullscreen (BC08 exact) |
| 2026-08-21 | `BaseMode.tiled` payload dropped; home derived via `findHome` | avoids nested-mode writes; T16 asserts single membership |
| 2026-08-21 | `WsState.focus_mru` added | T15 / BC06 fallback source |
| 2026-08-21 | `lowestBit(mask)` helper added | restore destination tracks tag-moves (BC12) |
| 2026-08-21 | `WSId = u16` local alias (refines C-D6) | model never imports core |
| 2026-08-21 | SizeHints duplicated in model; converted in pipeline (E.7) | strangler without circular imports |
| 2026-08-21 | all-view reduced to a flag; temp-window list deleted | BC17 emerges from visibility model |
| 2026-08-22 | `Mode.minimized.prev` retyped to flattened `PrevMode = union(enum){ base, fullscreen }` (coordinator-approved) | by-value recursive `prev: Mode` cannot compile; depth provably ≤ 1; BC08 unchanged |
| 2026-08-22 | `constants.max_minimized = 32` added; model aliases it (coordinator-approved) | legacy read an undefined build option (always 32); model layer rule forbids build_options |
| 2026-08-22 | Unit tests run via `zig build test` over auto-discovered `*_test.zig` modules (coordinator-approved) | Zig 0.16 module-root rules make standalone `zig test <nested file>` impossible with named imports |
| 2026-08-22 | `View` gains caller-resolved env: `margins`, `min_dim`, `master_on_right`, `grid_relaxed`, `monocle_gaps` (coordinator-approved) | algorithms' math needs them; layout may not import config; §7.4 step 3 keeps variant resolution caller-side |
| 2026-08-22 | `LayoutParams` gains `scroll_offset: i32`, `scroll_prev_count: u32`; engine consumes read-only (coordinator-approved) | legacy scroll.zig mutated viewport mid-retile; P2/P3 purity; mutation duties move to actions/sync (train e/f) |
| 2026-08-22 | Centralized hint application at engine emit confirmed behavior-preserving | legacy emitOrDefer → configureWithHints already applied hints to EVERY visible rect across all layouts; only pushWindowOffscreenAndInvalidate bypassed them |
| 2026-08-22 | No aggregator root in src/layout/ (no layout.zig) | module stem "layout" is taken by bar segment; §7.3 file list never required one; consumers import engine/algo_* directly |
| 2026-08-22 | algo_scroll parks off-viewport slots as visible=false; sync owns parking geometry (legacy parked at constants.offscreen_x_position with full content size) | I7 visibility model; uniform parking policy decided at WP3 |
| 2026-08-22 | T24/T25 caught port bug: fibonacci cursor advanced BOTH axes per split; legacy advances x only for .right, y only for .down | golden-value calibration working as intended; engine now matches legacy output exactly |
| 2026-08-22 | grid relaxed partial-row x-spacing overlap quirk preserved verbatim | BC parity: x stays column-based while partial widths widen (T23 documents it) |
| 2026-08-22 | sync.State gains explicit gpa + init/deinit/reset; plan E.5's bare `pub var st: State = .{}` cannot allocate for AutoArrayHashMapUnmanaged puts | allocator must live somewhere; reset() keeps backing memory across reconnects |
| 2026-08-22 | Request sending abstracted behind a Sink vtable; production XcbSink isolated so raw libxcb symbols appear ONLY in its shims | golden-sequence tests record ops instead of touching X; satisfies WP3 acceptance gate literally |
| 2026-08-22 | Stacking rule refined: winner's ABOVE merges into its geometry request whenever geometry changes; standalone raise only under force_restack | matches legacy retile wire behavior (only promoted tops raised unconditionally); focus-only changes stay color-only per scheduling table |
| 2026-08-22 | reconcile takes *const Model — scroll viewport snap/clamp/prev_count duties land in actions before reconcile | P3 purity; m const rules out mid-retile mutation |
| 2026-08-22 | Fullscreen branch parks all other entries with keep-last rect | step 4 "rect irrelevant" made literal |
| 2026-08-22 | pipeline.zig internal import aliased `model_mod`; public API stays `model()` returning *Model (coordinator-approved) | E.7 sketch declares import `model` AND fn `model()` — duplicate container member name, does not compile |
| 2026-08-22 | env flag read via std.c.getenv (Zig 0.16 has no std.posix.getenv); bar accessors guarded by build_options.has_bar like floating/input do | platform/idiom parity |
| 2026-08-22 | bar.getBarWindow() added beside isBarWindow/getBarHeight | pipeline Ctx needs the top window id for force_restack raise (I4 hook) |
| 2026-08-22 | Four marked call sites live: main startup init, events dispatch tail postDispatch, input finishTilingOp tilingOpFinished, floating updateDrag dragTick | WP4 step 2; each ≤30 lines, comment `// PIPELINE:` |
| 2026-08-22 | Flag-OFF parity argued structurally: every entry point early-returns before touching new-pipeline state; full harness run deferred to WP7 | no X server in CI environment |
| 2026-08-22 | `MinimizedPayload` gains `seq: u32`; `Model.next_seq` counter stamps it at minimize | LIFO/FIFO restore-target selection without the legacy side buffer; T31 locks semantics |
| 2026-08-22 | model gains `restoreCandidate(m,ws,order)`, `latestMinimizedBase(m,ws)` (BC09 plain-only focus), `clearFocus(m)` | actions must select targets purely from model state (P2/P3); legacy buffer order is not visible to them |
| 2026-08-22 | actions.minimize accepts `?WindowId` focused param | entry points hand over getFocused() result; null = no-op exactly like legacy's early return |
| 2026-08-22 | Train-a slots live behind flag in input.zig keybinding dispatch + bar title click; focus protocol still via window.focus (R2 deferral honored) | E.6 wrapper shape; protocol untouched until train f |
| 2026-08-22 | Actions keep model.focused and X11 input focus in lockstep inside fallback/restore paths | sync winner rule reads m.focused only; divergence would desync border colors |
| 2026-08-22 | restoreAllOnWs + latestMinimizedBase reproduce BC09 (slot order, plain-LIFO focus); BC08 fullscreen straight-back emerges from MinimizedPayload.prev + reconcile fs branch | verified against minimize.zig full read (411 lines, train-a precondition) |
| 2026-08-22 | Train b: fullscreen switch (A→B) collapses legacy's restore-A-then-repark-A into one parked transition | same end state via LastSent diff; fewer requests, BC24 budget improves |
| 2026-08-22 | Enter-path saved-geometry round trip deleted in new path: floating rect lives in BaseMode.floating; tiled exit is engine-recomputed | legacy fetchWindowGeom existed only to fill g_slots record; model needs no copy |
| 2026-08-22 | fullscreen.zig gains pub armPendingBarHide/Show + setEwmhFullscreenState made pub | bar-deferral and EWMH stay protocol-side (R2) driven by actions; events.zig ConfigureNotify handler works unchanged for both paths |
| 2026-08-22 | actions.fullscreenToggle classifies enter/exit/switch BEFORE model.toggle to time EWMH + bar arms exactly like legacy commits | BC13 parity |
| 2026-08-22 | Per-ws single-fullscreen guarantee restated as model property: sync parks non-current-ws fullscreen entries; toggleFullscreen records ws at enter | legacy g_slots[ws] semantics preserved without a slot array |
| 2026-08-22 | Sink vtable + LastSent gain `map` / `mapped` (default false): first visible reconcile maps a window | windows registered while hidden were never mapped server-side (registerWindowOffscreen); diffing avoids redundant map traffic; correctness over request budget on first sight |
| 2026-08-22 | Train c: legacy hide/park + map/restore + restoreWorkspaceGeom cache dance collapses into the LastSent diff | leavers park once, arrivers map+place; per-ws geom-cache invalidation bookkeeping deleted by design |
| 2026-08-22 | actions.switchTo dual-writes tracking.setCurrentWorkspace while the strangler runs | bar segments and other modules still read legacy tracking |
| 2026-08-22 | All-view exit in switchTo is a model flag flip (no temp-window masks) | BC17 emerges from visibility model (changelog 2026-08-21) |
| 2026-08-22 | Post-switch focus: pointer-hover child validated against visibleOn(new_ws), else newest-first focus_mru, else first visible store entry | ≙ resolvePostSwitchFocus + lastFocusedOrFirst; round trip stays pre-grab |
| 2026-08-22 | switchTo raises bar via reconcile force_restack hook instead of manual raiseBar | I4 hook owns top-window stacking; one less call site to port at train f |
| 2026-08-22 | layouts.peekHints(cache, win) read-back accessor added | actions must bridge legacy hints cache into model entries at registration (delete both sides WP6) |
| 2026-08-22 | Train d: handleMapRequest branches after the shared protocol front-end (event mask + property queries); unmanageWindow branches after pure-local bookkeeping | legacy front-ends stay the single protocol implementation (R2); model+sync take over from there |
| 2026-08-22 | Off-current spawns skip immediate border-width send; sync applies it at first show | window is invisible until shown; one less request; BC24 budget |
| 2026-08-22 | Close-path inactive-workspace repair rides the global LastSent diff | legacy retileInactiveWorkspace's separate pass deleted by design |
| 2026-08-22 | actions.unmanage re-focuses via pickFallback (MRU -> reversed tiled_order -> floating) instead of scroll-prev/pointer-child chain | pointer-child close-focus nuance deferred to train f alongside the rest of the pointer machinery (R2); S-scenario gates will judge |
| 2026-08-22 | Spawn focus uses .window_spawn reason through legacy setFocus; model.setFocus keeps m.focused authoritative for sync colors/winner | dual-write coherence while strangler runs |
| 2026-08-22 | model gains tagRemove (last-tag protected, fs-record transfer/drop to lowest remaining bit) and tagAdd(protect_current) | train e needs multi-tag ops; legacy setWindowMask/transferFullscreenRecord semantics |
| 2026-08-22 | moveWindowToWs now relocates the fullscreen record too (destination occupied ⇒ drop, never clobber) | legacy transferFullscreenRecord ran BEFORE mask change for exactly this |
| 2026-08-22 | Sync .tiled no-placement branch: visible foreign-home windows keep last geometry instead of defensive park | BC parity: legacy multi-tagged tiled windows stay at home-ws geometry when a co-tagged ws is shown; park only on true first sight |
| 2026-08-22 | Train e slots live: move_to_workspace, toggle_tag, all_workspaces, pin toggles behind flag in executeWorkspaceAction | E.6 wrapper shape; one reconcile per action |
| 2026-08-22 | All-view enter/exit is one flag flip + one reconcile; sync's mapped flag maps previously-unmapped foreign windows automatically | legacy enterAllView's explicit map loop deleted by design |
| 2026-08-22 | Train f slots live behind flag: toggle_floating_window, layout/variant/master/count/balance ops, swap_master(+focus_swap), move_next/prev, scroll steps | E.6 wrapper shape; suppress+settle preserved, bar redraws on layout-affecting ops |
| 2026-08-22 | Drag path under flag: pending-float detach goes through model (detachToFloating), tick sends rect to model + flushless reconcile; legacy configureWindow skipped | sync owns the wire during drags; no double-send |
| 2026-08-22 | Scroll viewport duties (snap-right-on-growth, clamp) centralized in pipeline.preReconcileDuties at the reconcile choke point | changelog C-D2/D3 caller duties; generalized from spawn-only snap to any visible-count growth |
| 2026-08-22 | sync.lastRectFor accessor exposes LastSent geometry for floating-detach/toggle-float seeding | model needs current on-screen rect; parked windows report null |
| 2026-08-22 | model.variantCount(kind) added (master/monocle/grid=2, else 1); stepVariant wraps variant_idx against it | caller-side variant resolution §7.4 step 3 |
| 2026-08-22 | Train g: actions.applyConfigReload re-seeds all ws params from new config (per-ws layout/variant/count overrides last-wins, runtime master_width/stack_balance reset) | mirrors workspaces.applyWorkspaceOverrides; hooked after tiling.reloadConfig in handleConfigReload |
| 2026-08-22 | pipeline.ctx() variant booleans now resolve from current ws model params (variantBool) instead of global config | per-ws overrides + stepVariant must reach the engine (§7.4 step 3) |
| 2026-08-22 | Master fifo variant enforced in model.register: new window takes slot 0 when kind==.master && variant_idx==1 | legacy spawn-placement duty; engine has no fifo knob by design |
| 2026-08-22 | Config layout="floating" maps to params.kind=.master without retile semantics | engine has no floating layout; floating is a window mode in the model |
| 2026-08-22 | Train h: bar show/hide under flag reconciles via pipeline (reconcileInGrab in the grabbed arm, reconcileNow otherwise); background retile loop retired | model has no per-ws geometry caches to refresh; sync recomputes on demand |
| 2026-08-22 | effective_visible fullscreen-override nuance not replicated: ctx() reads post-transition isVisible() | model path reaches this state through armPendingBarHide/Show where should_be_visible already encodes the override |
| 2026-08-22 | WP6 deletion, h→a: retileAllWorkspaces + background retile loop; window.zig map/unmap legacy tails (+ PreGrabState/resolveDestroyFocusTarget/registerWindowOffscreen/mapWindowToScreen); input.zig legacy else-arms + tiling* wrappers + executeSwapMaster + withTilingGrab family + finishTilingOp; floating.zig legacy drag wire; bar title/tag-click legacy arms; minimize.minimizeWindow/unminimize/unminimizeSpecific/unminimizeAll/moveToWorkspace; workspaces.switchTo/moveWindowTo/tagToggle/switchToAll/moveWindowToAll; fullscreen.toggle; tiling.addWindow/addWindowAtFilteredIndex/getWindowFilteredIndex/toggleWindowFloat/invalidateWsGeomBit/retileIfDirty/retileInactiveWorkspace/stepScrollView/swapWithMaster/takePrevFocusedForScroll | M4 gate: flag defaults ON (HANA_MODEL_PIPELINE=0 escapes), dead bodies removed inverse train order |
| 2026-08-22 | Focus-change scroll snap ported to actions.snapScrollToFocused (model viewport math via algo_scroll.slotWidth/maxOffset) | replaced withTilingGrabKeepFocus(tilingSnapScrollToFocused) at focus_next/prev |
| 2026-08-22 | SizeHints re-home completed: layouts.SizeHints carries a comptime shape guard against model.SizeHints; convertHints reduced to a field copy | plan's "delete both sides" — single logical type, no cross-module layering violation (model stays a leaf) |
| 2026-08-22 | WP7: scripts/check-layers.sh per §13 wired as zig build check dependency; wire + grab allowlist files document every surviving out-of-sync send with rationale | rule enforcement: sync-owned wire, grab, xcb-free model/layout, zig fmt |
| 2026-08-22 | Dead-code sweep removed 10 transitively-orphaned legacy fns (minimize partition/restore helpers, workspaces all-view exits, tiling swap core, scroll takePrevFocused) | fixpoint removal after entry-arm deletions |
| 2026-08-22 | ARCHITECTURE.md written from §6–§7: layers, data flow, flag, allowlists, BC gates | WP7 docs deliverable |
| 2026-08-22 | WP8: docs/rework-report.md — 16-finding audit with verify-at pointers, request-count budget table (structural analysis + deferred harness measurements), residual risk list | final deliverable; measured S01–S26 numbers need live Xvfb harness |
| 2026-08-22 | Harness replay on live Xvfb: ALL 15 scenarios byte-identical vs WP0 goldens with the model pipeline DEFAULT-ON (S01–S15 incl. BC14 hard gate) | measured M4 confirmation; supersedes ±10% budget estimates; report updated |
| 2026-08-22 | P0-4 recycled-XID fix: sync.forget(win) evicts LastSent on unmanage | reused XIDs stayed unmapped because stale LastSent diffed away every field; actions.unmanage calls forget after model unregister |
| 2026-08-22 | mapRequest focus reorder: setFocus AFTER reconcileUnderGrabNow | SetInputFocus before map → BadMatch (code=8 major=42); focus-after-map |
| 2026-08-22 | Regression scenarios S16-close-respawn / S17-hover-focus / S18-ewmh-fullscreen + hana.log.sig signal log in harness compare | golden capture + generation filters; 18/18 parity baseline |
| 2026-08-22 | WP6 completion, pool/registry purge: minimize.zig rewritten as model facade (g_minimized zombie registry deleted — nothing ever appended, bar indicators dead); bar all_view indicator reads pipeline.model().all_view_active (all_view_temp_wins zombie deleted — read was permanently false); workspaces.zig rewritten as minimal state holder (switch/tag/evict machinery deleted; applyWorkspaceOverrides reduced to 2 args); tiling.zig 1091→312 lines: retile engine, layout dispatch (invokeLayout/selectLayout), filtered-window ops, scroll-snap, updateWindowFocus, getTiledWindows pool queries all deleted; layouts.zig 282→89 lines: LayoutFn/LayoutCtx/configureWithHints family deleted; src/window/modules/tiling/modules/ (master/fibonacci/scroll/leaf/grid/monocle) deleted; tracking.Tracking legacy pool struct deleted | hints cache deliberately re-homed later: window.zig→tiling.cacheSizeHints→actions peekHints bridge stays (geom CacheMap = shared infra for border dedup + float restore) |
| 2026-08-22 | shouldRaise(mouse_click/user_command/pointer_sync) now skips tiled windows (was constant-true); pending_float drag-detach uses tracking.isTiledMode (was silently broken for tiled); sweepWorkspaceBorders skip_tiled arm actually skips via model predicate | behavior changes absorbed by harness after golden recapture of S12/S13: fewer raise-induced crossing events, spawn suppression persists until next click/command, focused tiled windows no longer raised on hover |
| 2026-08-22 | WP6 follow-up, cache re-home: per-window geometry/border/hints cache moved out of modules/tiling into src/window/wincache.zig (singleton init/deinit, peekHints(win) without cache pointer); SizeHints unified onto model.SizeHints (layouts.SizeHints copy + comptime guard + pipeline.convertHints deleted); layouts.zig deleted; tiling.zig reduced to stateless config mapping (84 lines: isEnabled/getBorderWidth/getCurrentLayout/getLayoutVariants/layoutFromString/defaultLayout computed live from core config + model) | getBorderWidth now reads reloaded config live -- caught S13 regression where WP6's init-cached width kept borders at 4 after a 4→7 reload; BC20 was silently vacated by the 19:59 golden recapture |
| 2026-08-22 | S13-reload hardened: server-side border-width assertion via xwininfo (borders-after-reload.norm artifact, fails the scenario when widths != 7) | golden log comparison alone missed the stale-width regression |
| 2026-08-22 | Bugfix, stale bar on workspace switch: WP6 workspaces.zig rewrite orphaned State.current -- actions.switchTo updated only model+tracking, so bar indicators pinned to WS1 and per-ws title lists never changed. Fixes: switchTo mirrors into new workspaces.setCurrent; bar captureWorkspaceState reads authoritative pipeline.model().current; input state_dump reads tracking.getCurrentWorkspace() | harness could not catch this: bar never initialized under Xvfb (see next row) and dumps ran only after switching back |
| 2026-08-22 | Bugfix, bar init: offscreen pixmap created with depth=XCB_COPY_FROM_PARENT(0) in opaque mode -- CreatePixmap requires a concrete depth (BadValue code=2 major=53 at every boot); now uses screen root_depth | default config (transparency=1.0 = opaque) could never start the bar; ARGB path unaffected |

*END OF DOCUMENT — v2.0 prescriptive edition*
