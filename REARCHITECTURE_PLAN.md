# Hana Window Management — Architecture Rework Plan

**Status:** Approved design, pending implementation
**Date:** 2026-08-21
**Scope:** Replace the imperative, mirror-state window-action architecture with a
Model / Layout / Sync triad, migrated incrementally ("strangler" pattern).
**Audience:** Implementation agents working asynchronously, plus any human
maintainer. This document is self-contained: it assumes **no prior knowledge of
the hana codebase**, and includes an X11 primer for readers unfamiliar with the
platform.

---

## Table of contents

1. [How to use this document](#1-how-to-use-this-document)
2. [Primer: what hana is, and the X11 concepts you need](#2-primer)
3. [Glossary](#3-glossary)
4. [Current architecture tour](#4-current-architecture-tour)
5. [Why rework: two case studies and the structural diagnosis](#5-why-rework)
6. [Design principles and global invariants](#6-design-principles-and-global-invariants)
7. [Target architecture](#7-target-architecture)
8. [Behavioral contract: behaviors that must not change](#8-behavioral-contract)
9. [Migration strategy and milestones](#9-migration-strategy-and-milestones)
10. [Work packages](#10-work-packages)
11. [Agent coordination guide](#11-agent-coordination-guide)
12. [Testing and verification strategy](#12-testing-and-verification-strategy)
13. [Enforcement: making the architecture self-defending](#13-enforcement)
14. [Risk register](#14-risk-register)
15. [Appendices](#15-appendices)

---

## 1. How to use this document

**For implementation agents:**

- Read sections 2–6 fully once before touching anything. They explain the
  platform, the existing system, and why it is being restructured.
- Section 7 defines the target design. Sections 7.2–7.4 contain the **frozen
  interface contracts** (struct shapes and function signatures). These are the
  coordination points between asynchronously-developed components: implement
  *exactly* these signatures; propose changes through the coordinator rather
  than deviating silently.
- Your assignment is one **Work Package** (section 10). Each WP lists: goal,
  dependencies, files you may touch (exclusive ownership), numbered tasks,
  deliverables, and acceptance criteria.
- Section 11 explains which WPs may run in parallel and which must be
  sequential, plus the conflict protocol.
- **Hard rules for every agent:**
  1. Touch only files listed in your WP's "Files owned" section (plus new files
     under your WP's directory). If you believe you need another file, stop and
     report back instead of editing.
  2. Every behavioral claim in section 8 that your WP affects must have a
     smoke-scenario (section 12.3) passing before your WP is done.
  3. `zig build` and `zig fmt --check` must pass. No exceptions.
  4. Do not delete legacy code unless your WP explicitly says so (deletion is
     centralized in WP6 to keep ports reversible).

**For humans:** sections 5, 6, 7, 9, and 14 carry the decision-making content;
the rest is operational detail.

---

## 2. Primer

### 2.1 What hana is

Hana is an **X11 tiling window manager written in Zig** (~18,500 lines across
`src/`). Like dwm/awesome/i3, it manages the placement and decoration of
application windows: automatic tiled layouts (master-stack, monocle,
fibonacci, grid, leaf, scroll), manual floating windows with drag/resize and
edge snapping, virtual workspaces (tags), a status bar with clickable segments,
window minimization, fullscreen support, EWMH compliance bits, keyboard/mouse
bindings, and a TOML configuration file (`config/config.toml`) hot-reloadable
at runtime.

Build and run:

```sh
zig build            # produces zig-out/bin/hana
zig fmt --check      # formatting gate; must stay clean
./dev/scripts/xephyr.sh   # run inside an Xephyr nested server (see WP0 note: stale DISPLAY)
```

There is currently **no automated test suite** for runtime behavior. Verification
is manual (run the WM, poke at it). One of the explicit goals of this rework is
to fix that first (WP0).

### 2.2 The ten X11 concepts everything else depends on

If you know Wayland compositors, note that X11 inverts control: the **X server**
owns the screen, and the window manager is just a *privileged client* that
reacts to events and issues requests.

1. **Windows & attributes.** Every top-level app window has server-side state:
   position/size (`geometry`), `border_width`, border `pixel` color, stacking
   order, map state. The WM manipulates these with
   `xcb_configure_window` (position/size/border-width/stacking),
   `xcb_change_attributes` (border pixel), `xcb_map_window` /
   `xcb_unmap_window`.

2. **Async requests, blocking replies.** Requests are buffered client-side and
   flushed later. Queries return *cookies*; calling `xcb_..._reply()` blocks
   until the reply arrives — and **implicitly flushes the outgoing queue**. This
   "blocking reply flushes my pending batch" fact is load-bearing throughout
   the codebase and appears repeatedly in the invariants (§6).

3. **Server grab.** `xcb_grab_server()` makes the server process *only* our
   requests for a while; `xcb_ungrab_server()` ends it. Used to make multi-step
   visual changes atomic (the compositor cannot observe half-applied states).
   Hana wraps these as `utils.grabServer(conn)` / `utils.ungrabAndFlush(conn)`
   — the latter also flushes the accumulated batch exactly once.

4. **ConfigureRequest.** Clients may ask to move/resize *themselves*. The WM
   receives this as an event and chooses to honor or override it. Honoring it
   mutates server-side geometry **behind the WM's back** — a recurring source
   of state desync in the current design (§5).

5. **Focus protocol (ICCCM).** A window advertises via the `WM_PROTOCOLS`
   property whether it accepts input and supports the `WM_TAKE_FOCUS`
   ClientMessage. Four input models result (`normal`/`globally_active`/
   `locally_active`/`no_input`); focus delivery differs per model, and querying
   costs a round trip unless cached.

6. **EWMH.** Extended hints other tools agree on. Hana uses
   `_NET_WM_STATE_FULLSCREEN` (set/cleared on the window as a property),
   `_NET_WM_PID`, `_NET_WM_STATE` handling, workspace desktop hints.

7. **Compositors.** Tools like `picom` composite windows offscreen and repaint
   based on damage/stacking events. Empirically (documented in code comments
   and confirmed by bugs), picom may **not repaint** when a lone window moves
   without an accompanying restack — hana works around this by raising the bar
   window (`bar.raiseBar()`) to force full-scene recomposite on
   restore-type transitions. Preserve this lore.

8. **Offscreen parking.** Hana never unmaps managed windows (unmap breaks
   focus/properties and confuses clients). "Hiding" means configuring the
   window to x = `-30000` (`constants.offscreen_x_position`; sentinel threshold
   `offscreen_sentinel_min = -1000`). We call this *parking*.

9. **Workspaces/tags.** A window carries a bitmask of workspaces it belongs to
   (`tracking.getWindowWorkspaceMask`). Exactly one workspace is *current*;
   visible = tagged on current workspace and not parked/minimized.

10. **Cookies & pipelining.** Firing several query cookies back-to-back lets
    the server process them concurrently; drain them afterwards. Hot paths
    (MapRequest, focus transitions) pipeline deliberately (see §4.2).

### 2.3 Technology facts an agent must know

| Fact | Value |
|---|---|
| Language | Zig (build via `zig build`; formatter `zig fmt --check`) |
| X binding | raw `xcb` C imports via `core.xcb` |
| Geometry type | `utils.Rect { x: i16, y: i16, width: u16, height: u16, border_width }` — note **i16** coords |
| Connection/state | `core.getState()` → `conn`, `screen`, `config`, … |
| Config | `src/config/*` parsed TOML; hot-reloadable; `cs.config.tiling.*`, `.minimize_enabled`, `.fullscreen_enabled`, … |
| Optional subsystems | compile-time flags `build_options.has_tiling`, `.has_bar` — many call sites guard with both |
| Perf counters | opt-in `"bench"` build option already exists in `build.zig` (line ~50) |

---

## 3. Glossary

| Term | Meaning |
|---|---|
| **Park / parked** | Window configured offscreen (x=-30000) instead of unmapped. |
| **Grab** | Server grab: exclusive request-processing window for atomicity. |
| **Flush** | Send buffered XCB requests (`xcb_flush` or implicit via blocking reply or `ungrabAndFlush`). |
| **Round trip** | Request→reply wait; blocks the caller and implicitly flushes. |
| **Cookie** | Handle for an in-flight query whose reply is fetched (or discarded) later. |
| **Retile** | Run the layout algorithm and push resulting geometries to windows. |
| **CacheMap** | Per-window tiling cache: `{ rect, border pixel, size hints, applied_border_width }`. The "mirror" of believed server state. |
| **Replay path** | Fast workspace switch-in that re-sends cached rects instead of recomputing (`workspace_geom_valid_bits`, `last_retile_area`). |
| **Ping-pong snapshots** | Bar keeps two frame slots; renders into slot A while displaying slot B (`s.snapshots[2]`, `snap_idx`). |
| **MRU** | Most-recently-used focus history per workspace (`tracking.popFocusMru`). |
| **Mode** | *(target arch)* The single enum describing a window's management state: tiled/floating/fullscreen/minimized. |
| **Placement** | *(target arch)* Pure layout output: `{win, rect, visible}`. |
| **Reconcile** | *(target arch)* Sync-layer diff of desired-vs-last-sent state emitting the minimal request batch. |
| **Strangler pattern** | Building the new system alongside the old and migrating callers piecewise until the old is deleted. |
| **Port train** | The sequential series of action migrations (minimize → fullscreen → …), see §9.2. |

---

## 4. Current architecture tour

Line counts verified 2026-08-21 (`wc -l`). Symbols referenced throughout this
plan use `file:symbol` form.

### 4.1 Module map

| File | LOC | Responsibility |
|---|---|---|
| `src/core/main.zig` | 105 | Entrypoint, subsystem init ordering |
| `src/core/core.zig` | 95 | Global `State` (conn, screen, config); `core.getState()` |
| `src/core/events.zig` | 371 | Event loop + dispatch; `handleConfigReload` |
| `src/core/signals.zig` | 90 | Signal handling |
| `src/core/plugins.zig` | 58 | Plugin registry; `fanOut("reload", …)` |
| `src/core/input/input.zig` | 823 | Keybind/mouse dispatch; `finishTilingOp` |
| `src/core/input/xkbcommon.zig` | 237 | Keyboard model/layout handling |
| `src/core/utils/utils.zig` | 639 | `Rect`, `grabServer`, `ungrabAndFlush`, `pushWindowOffscreen[AndLower]`, `configureWindow`, `setBorderPixel`, `raiseWindow`, `getAtomCached`, scaling |
| `src/core/utils/constants.zig` | 152 | `offscreen_x_position=-30000`, `offscreen_sentinel_min=-1000`, … |
| `src/core/modules/{clock,debug,refresh_rate,scale}.zig` | — | Misc services |
| `src/config/{config,parser,types,fallback}.zig` | 2899 | TOML config, hot reload |
| `src/bar/bar.zig` | 1571 | Bar state machine; ping-pong `snapshots[2]`; `captureStateIntoSlot`; `redrawInsideGrab`/`commitInsideGrab`/`snapshotNeedsRefetch`; `raiseBar`; `retileAllWorkspaces`; click routing |
| `src/bar/{render,drawing}.zig` | 647 | Cairo/pixmap render pipeline |
| `src/bar/modules/**` | — | Title/carousel, tags, layout indicator, prompt segments |
| `src/window/window.zig` | 1597 | MapRequest/ConfigureRequest/etc.; focus-property caches; `getInputModelResolved`; take-focus senders; border sweeps; `restoreFloatGeom`/`configureWindowGeom`/`applyBorder`; `resolveTargetWorkspace` |
| `src/window/focus.zig` | 796 | `setFocus` family; `FocusContext`; `CommitFlags`; `commitFocusTransition` |
| `src/window/tracking.zig` | 489 | Masks, registration, window iterators, geometry prefetch, focus MRU |
| `src/window/borders.zig` | 57 | `width()`/`color()`/`applyWidth`/`apply` (dedup + record) |
| `src/window/modules/minimize.zig` | 411 | `g_minimized` records; `minimizeWindow`/`restoreWindowImpl`/`unminimize*` |
| `src/window/modules/fullscreen.zig` | 505 | Per-ws fullscreen records; enter/exit commits; `applyFullscreenGeometry`; EWMH property; deferred bar show/hide |
| `src/window/modules/workspaces.zig` | 704 | `moveWindowTo`; switch hide/restore; `enterAllView`; pin toggle; retire inactive ws |
| `src/window/modules/floating.zig` | 353 | Drag/resize (`startDrag`/`updateDrag`/`stopDrag`), snapping |
| `src/window/modules/tiling/tiling.zig` | 1289 | Tiler `State` (window pool, CacheMap, replay bits); `add/remove/addWindowAtFilteredIndex`; retile family; border dedup helpers; `reloadConfig` |
| `src/window/modules/tiling/layouts.zig` | 261 | `LayoutCtx`; `configureWithHints*` (emit); `applyHintsToRect` (pure) |
| `src/window/modules/tiling/modules/*.zig` | 851 | Algorithms: master(375), fibonacci(123), grid(72), leaf(80), monocle(37), scroll(164) |

### 4.2 Core mechanisms

**M1 — Event loop.** `events.zig` polls and routes XCB events. Config reload
ordering is load-bearing (audit fix 6.1): `plugins.fanOut("reload")` →
`tiling.reloadConfig()` → `window.reloadBorders()`.

**M2 — Window birth.** `window.zig:handleMapRequest` fires three query cookies
concurrently (WM_NORMAL_HINTS, WM_PROTOCOLS, WM_HINTS), drains once (fix 1.3);
`resolveTargetWorkspace` applies WM_CLASS rules, falling back to `_NET_WM_PID`,
discarding unconsumed cookies on early return (fix 7.1). Mask assignment
happens via `workspaces.moveWindowTo`/`tracking.registerWindow` **before**
`tiling.addWindow`. Spawn = add + retile; `addWindow` pre-populates a fresh
CacheMap entry (`border=color`) so the following retile's border sweep is free.

**M3 — Tiling engine + mirror cache.** `layouts.WindowData{rect, border,
hints, applied_border_width}` mirrors believed server state.
`layouts.zig:configureWithHintsImpl` recomputes the layout rect, applies size
hints purely (`applyHintsToRect`), diffs against the cached rect and **sends
only on change**, updating the cache immediately. `updateBorderColor(create_
if_missing=true)` dedups border pixels. `markDirtyAndInvalidateGeom(s,
affected_mask)` clears per-workspace replay bits only for affected workspaces
(fix 4.1). `removeWindow` evicts the whole entry (geometry, border dedup data,
embedded hints).

**M4 — Replay path.** `tiling.zig:restoreWorkspaceGeom()` replays cached rects
on workspace switch-in when the workspace bit is valid and `last_retile_area`
matches the current work area; otherwise callers fall back to a full retile.
`hideWorkspaceWindows` invalidates rects of tiled windows it parks.

**M5 — Parking + fullscreen.** `utils.pushWindowOffscreen` parks at x=-30000.
`fullscreen.enterFullscreenCommit` saves the window's geometry per-workspace,
parks every other window on the workspace, invalidates *tiled* neighbors'
cached rects (floats keep theirs — they hold restore geometry),
`applyFullscreenGeometry` raw-configures screen-size + `BORDER_WIDTH=0` +
`ABOVE` and records BW=0 into the dedup cache (post-bugfix). Exit restores
saved geometry (floats) or hands back to tiling, then `applyBorder` restores
width+color.

**M6 — Minimize.** Record `{saved_fs, workspace_idx, tiling_index}`;
`tiling.removeWindow` evicts the cache entry; park; refocus fallback resolved
pre-grab (two-tier MRU then first-visible, both scoped to the window's own
workspace); retile under grab. Restore mirrors spawn: `addWindowAtFilteredIndex`
re-inserts at the remembered slot, retile runs **outside** the grab so the
blocking input-model resolve flushes the configure batch atomically; then grab:
applyBorder → map_window → setFocusWithModel → `raiseBar` → `commitInsideGrab`.

**M7 — Workspace switch.** Hide phase parks non-shared windows and invalidates
their rects; restore phase applies per-ws layout overrides, tries the replay
path (`restore_ok`), else full-retiles; windows shared with the old workspace
skip re-map (fix 2.2); `prefetchAndSaveWindowGeometries` warms caches during
switch-away.

**M8 — Focus layer.** `setFocus` uses `getInputModelResolved`: one live
WM_PROTOCOLS reply yields both the input model (accepts_input comes from a
cache) and the take-focus bit (fix 1.2). A pre-fired protocol cookie is
pipelined and drained inside `commitFocusTransition`;
`CommitFlags{set_input_focus, raise, send_wm_take_focus, take_focus_known,
arm_confirm, schedule_bar, new_suppress}` parameterize the transition.
`.pointer_sync` arms an async confirm cookie to detect silently-dropped focus.

**M9 — Bar.** Ping-pong snapshot slots; `captureStateIntoSlot` decides
"title data changed" from {pending_force_title_redraw, focused change vs the
*other* slot, `title_cache.is_invalidated`, workspace window list, minimized
set}; `redrawInsideGrab` defers refetch-heavy frames via `markDirty` (fix 1.1)
so grabs never stall on blocking property reads.

**M10 — Input/drag.** `input.zig:finishTilingOp` closes ops with
{border flush, `bar.redrawInsideGrab`, focus settle hooks, `ungrabAndFlush`}.
`floating.zig` drags mutate geometry live with edge snapping.

**M11 — Border bookkeeping (the trust boundary that broke).** After the
bugfix, every sender records: `borders.applyWidth`/`apply`,
`tiling.cacheBorderWidth` called from `applyFullscreenGeometry`,
`configureWindowGeom`, honored `handleConfigureRequest`, and the
`reloadConfig` loop; sweeps use `sendBorderColorIfChanged` which always
records.

### 4.3 Representative flow: un-minimize (today)

```
keybind/click ──► minimize.unminimizeSpecific(win)
  ├─ pop g_minimized record {saved_fs?, ws_idx, tiling_idx}
  ├─ tiling.addWindowAtFilteredIndex(win, ti)        (re-add + slot move)
  ├─ tiling.retileCurrentWorkspaceWithOpts(.{.focus_override=win})   ← OUTSIDE grab
  ├─ focus.FocusContext.resolve(win)                 (blocking reply FLUSHES the batch)
  ├─ grabServer
  │   ├─ window.applyBorder(win)      (width+pixel, dedup+record)
  │   ├─ xcb_map_window(win)
  │   ├─ focus.setFocusWithModel(win, .window_spawn, model)
  │   └─ bar.raiseBar()               (compositor recomposite hack, invariant I4)
  └─ bar.commitInsideGrab()           (render/blit unless deferred + ungrabAndFlush)
```

Every other action (switch, fullscreen, tag-move, spawn) is a *different*
hand-rolled variation of the same skeleton. That is the problem §5.3 formalizes.

---

## 5. Why rework

### 5.1 Case study A — un-fullscreen loses borders (regression, root-caused)

Border dedup caches were introduced as a performance fix. But
`applyFullscreenGeometry` sent `BORDER_WIDTH=0` **outside** the cache, and
fullscreen-period sweeps sent pixel 0 around a `c != 0` guard that skipped the
cache write. On exit, `borders.applyWidth` compared against the stale cached
width W ("unchanged" — skip) and the color dedup compared against the stale
cached color C ("unchanged" — skip). Server kept width 0 + pixel 0 → a fully
borderless window. Fix: make every sender record (§13 of the audit follow-up).
The bug was *one forgotten writer among six*.

### 5.2 Case study B — un-minimized window not displayed

After the same dedup rollout, un-minimizing left windows visually broken until
an unrelated event (workspace switch / new window / fullscreen toggle). Root
cause synthesis: the restore path's *geometry* configure was always sent; what
broke was stale border-bookkeeping polluting whole sessions — and the three
"fixing" actions all share one property: they rebuild cache entries from
scratch, forcing unconditional re-sends. Self-healing by accident.

### 5.3 Structural diagnosis

| # | Flaw | Evidence |
|---|---|---|
| D1 | **N writers, 1 trust boundary**: six sites send border/geometry raw; the invariant "cache mirrors server" is a convention spread across all of them | Case study A; M11 list |
| D2 | **Mirror-of-server state**: the cache claims to reflect the server, but clients mutate their own geometry (ConfigureRequest) behind our back | finding 4.2 had to patch this ad hoc |
| D3 | **Imperative action sequences**: every action hand-rolls grab/mutate/sweep/bar/flush; sequences overlap ~80% and diverge in details — where the bugs live | M6 vs M7 vs M5 skeletons |
| D4 | **Scattered mode inference**: "what is this window?" requires consulting ≥5 structures (tiling pool membership, `tiling_index == null`, `g_minimized`, fullscreen records, cache rect validity / replay bits) | minimize/fullscreen/workspaces modules |
| D5 | **Equality-dedup converts any lapse into permanent silent misbehavior far from the cause** | both case studies |

Sixteen audit findings mapped to these flaws: appendix B. Every finding class
is a violated layer boundary that the target architecture makes structurally
impossible.

---

## 6. Design principles and global invariants

Principles:

- **P1 — Model is truth.** One authoritative structure describes every managed
  window's management state. The X server is a render target.
- **P2 — Single writer.** Exactly one module may send geometry/border/map/stack
  requests. Recording is inside the writer, not a caller convention.
- **P3 — Actions are pure.** Transitions are `Model → Model` functions with
  zero XCB. Their correctness argument fits on one screen.
- **P4 — Dedup safe-by-construction.** Skip-if-equal compares desired state vs
  a last-sent shadow owned exclusively by the writer (P2). Bypassing the
  record is structurally impossible.
- **P5 — Clients are inputs, not saboteurs.** ConfigureRequests and property
  notifications enter through the model; nothing mutates server state outside
  the reconcile path.

Global invariants (codified from hard-won runtime lore — **preserve verbatim
behavior**):

- **I1** Never perform a blocking round trip while holding the server grab.
  Prefetch before grabbing, or defer the fetch until after the flush.
- **I2** Atomic operations batch all mutations and flush exactly once at the
  end (`ungrabAndFlush` semantics). A blocking reply may be used deliberately
  *before* the grab to flush a prepared batch (see M6).
- **I3** Pre-fired query cookies are drained or explicitly discarded before
  entering any grab; no cookie may survive a return path.
- **I4** Restore-class transitions (un-minimize, un-fullscreen, switch-in)
  force a full-scene restack (`raiseBar`) so compositors recomposite. Do not
  remove without compositor-specific evidence.
- **I5** An honored ConfigureRequest updates the model *first*; any resulting
  sends derive from reconcile.
- **I6** Dedup compares only against last-sent state owned by the writer (P2).
- **I7** Parking is modeled visibility (`visible=false`), never an emergent
  side effect of whoever last sent a configure.
- **I8** Preserve capacity contracts: `max_minimized` guard refuses cleanly
  before mutating; bounded stack buffers (256) have defined overflow paths;
  check-before-mutate so there is no rollback path.

---

## 7. Target architecture

### 7.1 Layers

```
┌────────────────────────────────────────────────────────────┐
│ events.zig / input.zig / bar clicks   (entry points)       │
│        │ calls                                             │
│        ▼                                                   │
│  actions.zig   pure Model→Model transitions, zero XCB      │
│        │ mutates                                           │
│        ▼                                                   │
│     model.zig   single source of truth                     │
│        ▲ desired-state queries      ▲ client facts in      │
│        │                            │ (ConfigureRequest,   │
│        │                            │  size hints, props)  │
│  layout/ engine.zig (pure)          │                      │
│        │ placements                 │                      │
│        ▼                            │                      │
│     sync/sync.zig   THE ONLY XCB WRITER                    │
│        │  diff vs last-sent · batch · grab discipline      │
│        ▼                                                   │
│     X server ──► compositor ──► screen                     │
└────────────────────────────────────────────────────────────┘
```

Dependency rule: `model` imports std + utils types only. `layout` imports
model types only. `sync` imports model + layout. Actions import model.
Entry points import actions + sync scheduling. **Nothing else may import xcb
request functions** (enforced, §13).

### 7.2 `src/model/model.zig` — FROZEN CONTRACT

```zig
pub const WindowId = u32;
pub const Mask = u64;                       // one bit per workspace

/// Where a window lives when nothing special is happening.
pub const BaseMode = union(enum) {
    tiled,                                  // membership+order = ws.tiled_order position
    floating: utils.Rect,
};

/// Total, exclusive management state. Exactly one variant per window.
pub const Mode = union(enum) {
    base: BaseMode,
    /// Fullscreen on workspace `ws`; `base` is where to return on exit.
    fullscreen: struct { ws: WSId, base: BaseMode },
    /// Parked by user. Remembers how to come back, including an optional
    /// fullscreen geometry to re-enter after restore (BC08).
    minimized: struct { base: BaseMode, fullscreen_saved: ?utils.Rect },
};

pub const Entry = struct {
    mask: Mask,
    mode: Mode,
    size_hints: layouts.SizeHints = .{},    // client-authored fact (P5), not server mirror
};

pub const WsState = struct {
    tiled_order: std.ArrayListUnmanaged(WindowId),
    params: LayoutParams,                   // master_width/count/balance, variant idx, per-ws overrides
    focus_mru: std.ArrayListUnmanaged(WindowId),
};

pub const Model = struct {
    wins: FlatArrayMap(WindowId, Entry),    // same flat-array map family as today's CacheMap
    ws: [MAX_WORKSPACES]WsState,
    current: WSId,
    focused: ?WindowId,
};
```

Frozen transition signatures (all panic-free, capacity-guarded per I8):

```zig
pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) void;
pub fn unregister(m: *Model, win: WindowId) void;          // cleans tiled_order/MRU/minimized refs (BC11)
pub fn minimize(m: *Model, win: WindowId) !void;           // error set: {CapacityFull} (BC26/I8)
pub fn restore(m: *Model, win: WindowId) void;             // pops through fullscreen_saved if present
pub fn restoreAllOnWs(m: *Model, ws: WSId) void;
pub fn toggleFullscreen(m: *Model, win: WindowId) void;
pub fn switchTo(m: *Model, ws: WSId) void;
pub fn moveWindowToWs(m: *Model, win: WindowId, ws: WSId) void;
pub fn pinToggle(m: *Model, win: WindowId) void;
pub fn allViewToggle(m: *Model) void;
pub fn reorderTiled(m: *Model, win: WindowId, new_idx: usize) void;  // replaces moveWindowToFilteredSlot
pub fn swapMaster(m: *Model) void;
pub fn cycleLayout(m: *Model, dir: enum { fwd, rev }) void;
pub fn adjustMasterWidth(m: *Model, delta: f32) void;
pub fn setFloatingRect(m: *Model, win: WindowId, r: utils.Rect) void;    // drag ticks
pub fn honorConfigureRequest(m: *Model, win: WindowId, req: ConfigReq) HonorDecision;
pub fn applyConfigReload(m: *Model, cfg: *const Config) void;
pub fn setFocus(m: *Model, win: WindowId) void;            // focused + MRU bookkeeping only
```

Design decisions and rationale:

1. **Tiled membership is an ordered list per workspace**, not a global pool +
   filtered-index arithmetic. This deletes `addWindowAtFilteredIndex`,
   `getWindowFilteredIndex`, `moveWindowToFilteredSlot`, and the whole class of
   stale-index hazards they invite.
2. **Minimized carries its prior base mode** — kills the
   "float or tiled?" guess from `tiling_index != null` (D4).
3. **Fullscreen is a window mode with a workspace tag**, replacing the
   per-workspace record table; `dropOtherRecordsFor` becomes a structural
   invariant ("a window has one mode") instead of cleanup code.
4. **Mask stays orthogonal to mode** (pinning composes with every mode).
5. **Size hints live in the model as client-authored input data** — distinct
   from last-sent mirror state (which only sync owns). Today minimize loses
   hints because `removeWindow` evicts them; here they survive.

### 7.3 `src/layout/engine.zig` — FROZEN CONTRACT

```zig
pub const Placement = struct {
    win: WindowId,
    rect: utils.Rect,       // hint-adjusted (applyHintsToRect reused as-is)
    visible: bool,          // false ⇒ sync parks it (I7). monocle non-top ⇒ false.
};

pub const View = struct {
    wins: []const WindowId,             // ws.tiled_order slice
    params: *const LayoutParams,
    workarea: utils.Rect,
    hints: *const HintsView,            // reads Entry.size_hints via model
    focused: ?WindowId,
    for_ws: ?WSId,                      // background computation (replaces RetileOpts.for_ws)
};

pub fn compute(kind: LayoutKind, v: View, out: *std.ArrayList(Placement)) void;
```

- Ports of `master/fibonacci/grid/leaf/monocle/scroll` become pure placement
  producers. `showOneHideRest`, `configureWithHints*`, `LayoutCtx.deferred`
  disappear — visibility and raise ordering become Placement flags plus sync
  policy.
- `swap_master`'s defer semantics (BC23) are expressed by ordering placements:
  sync raises/configures the swapped window last within a batch.
- Scroll layout's `prev_focused` restoration moves into `LayoutParams` (open
  question Q-D2, appendix D).

### 7.4 `src/sync/sync.zig` — FROZEN CONTRACT

```zig
/// Shadow of what we believe the X server currently holds. ONLY sync may read
/// or write this; ONLY sync may send geometry/border/map/stack requests.
pub const LastSent = struct {
    rect: utils.Rect,
    border_width: u16,
    pixel: u32,
    parked: bool,
};

pub fn reconcile(m: *const model.Model, ctx: *Ctx) void;

pub fn reconcileUnderGrab(m: *const model.Model, ctx: *Ctx) void;  // grabServer → reconcile → raiseBar? → ungrabAndFlush
pub fn schedule(ctx: *Ctx) void;                                    // coalesced end-of-dispatch reconcile
```

Reconcile algorithm:

1. Compute work area (screen minus bar, existing `workArea()` logic).
2. If any fullscreen-mode window is tagged/current on the shown workspace, its
   placement is `{screen rect, bw=0, visible}` and every other window on that
   workspace is `visible=false` (this replaces enterFullscreenCommit's park
   loop; BC13).
3. Otherwise run `layout.compute` for the shown workspace; windows not in the
   placement list (floating/minimized/foreign-masked) get policy-driven
   desired state below.
4. Desired state per window:

| Field | Policy |
|---|---|
| rect | placement rect; parked ⇒ `offscreen_x_position` |
| border_width | fullscreen ⇒ 0; otherwise `config.tiling.border_width` (scaled at load) |
| pixel | focus/mode color function (today's `borders.color`) incl. fullscreen zero |
| parked | not tagged on shown ws ∨ minimized ∨ `placement.visible == false` |
| stack | focused/top-of-layout ⇒ ABOVE (once per batch); parked ⇒ BELOW; else none |

5. Diff each field vs `LastSent`; emit only deltas into one request batch.
6. Update `LastSent` as each request is queued; counters incremented (bench).
7. Emit restack for restore-class transitions (I4 hook: caller passes
   `.force_restack = true`; sync ORs in a raise of the bar/top window).
8. Caller flushes once (I2): either `ungrabAndFlush` inside
   `reconcileUnderGrab`, or the scheduled end-of-dispatch flush.

### 7.5 Event adapter mapping (who calls what)

| Existing entry point | Becomes |
|---|---|
| `window.zig:handleMapRequest` | property prefetch (unchanged M2 pipeline) → `actions.register` → schedule reconcile |
| `window.zig:handleConfigureRequest` | `model.honorConfigureRequest` → if honored & floating: update mode rect; if tiled: ignore geometry but record BW via model→sync policy; reply ConfigureNotify unchanged |
| Destroy/UnmapNotify | `actions.unregister` → schedule |
| `input.zig` keybinds | direct action calls (+ `reconcileUnderGrab` where atomicity matters: switch/minimize/tag-move) |
| `floating.zig` drag tick | `actions.setFloatingRect` + coalesced immediate reconcile (no grab — matches today's ungrabbed live updates) |
| `focus.zig:setFocus*` | `model.setFocus` + color-only reconcile (scheduled); protocol layer (take-focus cookies) unchanged |
| `bar.zig` clicks | action calls; rendering untouched except reading model snapshots instead of tracking iterators |

### 7.6 Scheduling policy

| Transition class | Mechanism |
|---|---|
| Atomic user ops (switch, minimize/restore, tag-move, fullscreen toggle) | `reconcileUnderGrab` (preserves today's atomicity UX) |
| Focus change (color-only diff) | scheduled end-of-dispatch |
| Drag ticks | immediate, no grab, partial batch flush per tick |
| Background/inactive workspaces | **none** — parked rects are deterministic; replay machinery (`retileInactiveWorkspace`, `bar.retileAllWorkspaces`, valid bits) deleted in WP6 |

---

## 8. Behavioral contract

Every row is a regression-test obligation (section 12.3 maps rows to smoke
scenarios). "Today" references are anchors, not implementation instructions.

| ID | Scenario | Must observe |
|----|----------|--------------|
| BC01 | Spawn window with WM_CLASS workspace rule | Lands on ruled ws, tiled, focused, bordered; pipelined cookie behavior preserved (M2) |
| BC02 | `_NET_WM_PID` fallback path | No leaked cookie when class-rule hits early (fix 7.1) |
| BC03 | ConfigureRequest honored while floating | Requested rect persists across subsequent minimize/restore (fix 4.2 semantics) |
| BC04 | ConfigureRequest while tiled | Geometry ignored; BW changes honored+recorded |
| BC05 | Client changes own border width | Recorded; survives retiles; no dedup skip later |
| BC06 | Minimize | Parks; fallback focus = MRU-tier then first-visible scoped to that ws; retile atomic under one grab |
| BC07 | Un-minimize tiled | Returns to original slot; monocle shows it first frame (`focus_override`) |
| BC08 | Un-minimize from-fullscreen | Slot re-added, THEN re-enters fullscreen with saved rect (minimize.zig:150 branch) |
| BC09 | Un-minimize-all | fs/plain partition; plain sorted by slot; LIFO focus target |
| BC10 | Cross-workspace un-minimize specific | Current ws visuals undisturbed |
| BC11 | Destroy while minimized/fullscreen | All records cleaned; no dangling IDs anywhere (incl. scroll.prev_focused analog) |
| BC12 | Tag-move a minimized window | Record follows new ws (minimize.moveToWorkspace) |
| BC13 | Fullscreen enter | Others parked; their tiled rects invalidated-equivalent; saved geom stored; EWMH set; deferred bar-hide fires |
| BC14 | Fullscreen exit | Border width AND pixel restored (the fixed bug — hard regression gate) |
| BC15 | Switch away/back | Fast replay when eligible; correct full retile otherwise |
| BC16 | Pinned windows during switch | Skip re-map; participate everywhere |
| BC17 | All-view toggle with never-mapped temp windows | They get mapped (fix 8.1) |
| BC18 | Tag-remove / move-to-ws of active window | No layout hole; refocus resolved pre-grab (fix 3.1) |
| BC19 | Pin-toggle | Map happens inside grab (fix 3.2) |
| BC20 | Config reload | Order fanOut→reloadConfig→reloadBorders; BW rescale recorded; no double sends (fix 6.1) |
| BC21 | Float drag + drop onto tiling edge | Live updates; snap; tileWithOffset; finishTilingOp settle sequence |
| BC22 | Monocle spawn/restore | Shown window = focused override on first frame |
| BC23 | Swap-master | Swapped window configured+raised last in batch |
| BC24 | Bar under grabs | No blocking round trips inside grabs (fix 1.1); ping-pong integrity |
| BC25 | Focus change | ≤1 protocol round trip (fix 1.2); correct take-focus dispatch; pointer_sync confirm retry |
| BC26 | Capacity | `max_minimized` overflow refuses cleanly pre-mutation; bounded buffers have defined overflow paths (I8) |

---

## 9. Migration strategy and milestones

### 9.1 Strangler pattern with a runtime flag

New pipeline lives beside the old. Env var `HANA_MODEL_PIPELINE=1` routes
ported actions through actions/sync; unset uses legacy code. Each port item
(§9.2) flips its own entry in a small dispatch table so ports are independent,
reversible, and individually testable. Legacy deletion happens only in WP6.

### 9.2 Port train (strictly sequential; rationale = bug frequency × blast radius)

| Step | Action ported | Why this order |
|------|---------------|----------------|
| a | minimize / restore / restoreAll (M6 skeleton) | Historically buggiest; exercises parking, slots, fs-interplay, grabs — the pilot proves the architecture |
| b | fullscreen enter/exit/toggle (M5) | Second-highest bug count; validates saved-geometry modes |
| c | workspace switch (M7) | Biggest behavioral surface; kills replay machinery |
| d | spawn/map/close lifecycle (M2) | High traffic; validates registration path |
| e | tag-move / pin / all-view | Composes earlier pieces |
| f | drag/resize + tiling op finishing (M10) | Latency-sensitive; do after core is stable |
| g | config reload | Cross-cutting sweep; mostly plumbing |
| h | retire-inactive-ws + delete background retiles | Only meaningful once everything else is synced |

### 9.3 Milestones

| ID | Name | Exit criteria |
|----|------|---------------|
| M0 | Baseline | Smoke harness green against **current** binary; scenario outputs + bench request-counters recorded as golden files |
| M1 | Contracts frozen | `src/model`, `src/layout`, `src/sync` compile with unit tests passing, unused by production code; signatures match §7 exactly; merged to main |
| M2 | Pilot live | Port-train step (a) behind flag; parity harness (§12.4) green on scenarios S01–S10; default remains legacy |
| M3 | Train complete | Steps b–h done; flag defaults ON; full suite green |
| M4 | Old world deleted | WP6/WP7/WP8 done: legacy modules removed, layer guards enforced in build, docs finalized |

---

## 10. Work packages

Each WP is designed to be executable by one agent without knowledge of other
agents' progress. Rules: touch only owned files; respect the dependency
column; finish with `zig build && zig fmt --check` green and your acceptance
criteria demonstrably met; report deviations instead of improvising.

### WP0 — Smoke-test harness & baseline  `[lane A]`
- **Goal:** Make behavior verifiable before anything changes.
- **Depends on:** nothing. **Blocks:** everything (M0).
- **Files owned:** `dev/scripts/**`, new `dev/harness/**`, `build.zig` (additive only).
- **Tasks:**
  1. Fix stale `DISPLAY` in `dev/scripts/xephyr.sh` (`:5` server vs `:2` run line).
  2. Build a headless runner: Xvfb `:99` + `dev/harness/run-scenario.sh` that boots the WM, executes a scenario script, dumps `xwininfo -root -tree`, `xprop -root`, and bench counters into `dev/harness/out/<scenario>/`.
  3. Install tooling assumptions in a bootstrap script (`xdotool`, `wmctrl`, `xwininfo`, `xprop`; document Xvfb fallbacks where a tool is missing).
  4. Implement scenario library S01–S15 (§12.3) as idempotent scripts.
  5. Capture golden outputs for the current binary → `dev/harness/golden/`.
- **Deliverables:** harness scripts + goldens + README.
- **Accept:** every S-script runs to completion against unmodified build and produces deterministic-enough output (normalize window IDs/timestamps).

### WP1 — Model core  `[lane B]`
- **Goal:** `src/model/model.zig` per §7.2 with unit tests.
- **Depends on:** none (uses frozen contract). **Blocks:** WP3, WP4.
- **Files owned:** `src/model/**`.
- **Tasks:**
  1. Port/choose flat-array map (mirror CacheMap's implementation family).
  2. Implement Entry/Mode/WsState/Model + all §7.2 transitions + invariants as `std.debug.assert`s in debug builds.
  3. Unit tests: mode transitions incl. minimize-from-fullscreen round trip, unregister-while-minimized/fullscreen, pin+mode composition, capacity refusal (I8), reorder bounds.
- **Accept:** `zig test src/model/model.zig` green; zero xcb imports (grep).

### WP2 — Pure layout engine  `[lane C]`
- **Goal:** `src/layout/engine.zig` + pure ports of the six algorithms per §7.3.
- **Depends on:** none. **Blocks:** WP3.
- **Files owned:** `src/layout/**`.
- **Tasks:**
  1. Move `applyHintsToRect` & helpers unchanged.
  2. Port each algorithm from `src/window/modules/tiling/modules/*` to placement producers. Read each original fully first; preserve gap/variant semantics exactly (master.zig variants matter).
  3. Monocle ⇒ non-top placements `visible=false`. Scroll: thread prev_focused through `LayoutParams` (Q-D2).
  4. Property tests: placements within workarea; tiled layouts never overlap; full coverage except monocle; determinism.
- **Accept:** `zig test src/layout/…` green; no xcb imports.

### WP3 — Sync layer  `[lane B after WP1]`
- **Goal:** `src/sync/sync.zig` per §7.4 incl. policy tables, LastSent, batch emission, grab helpers, request counters wired to existing `"bench"` option.
- **Depends on:** WP1 + WP2 (contracts). **Blocks:** WP4/WP5.
- **Files owned:** `src/sync/**`.
- **Tasks:**
  1. LastSent table keyed like today's CacheMap.
  2. Reconcile steps 1–8 (§7.4); I1–I8 assertions in debug builds.
  3. `reconcileUnderGrab` / scheduled reconcile plumbing; force_restack hook for I4.
  4. Counters per request class; dump-on-exit helper for parity harness.
- **Accept:** headless unit test driving a fake model produces expected request sequences (golden JSON); no other module sends geometry/border requests once WP6 lands.

### WP4 — Bridge & event adapters  `[lane B]`
- **Goal:** Wire entry points to actions/sync behind the runtime flag (§9.1): dispatch table in a new `src/pipeline.zig` selecting legacy vs new path per port-train step.
- **Depends on:** WP3. **Blocks:** WP5.
- **Files owned:** `src/pipeline.zig` (new), minimal insertion points in `window.zig`, `events.zig`, `input.zig`, `focus.zig`, `bar.zig` (each ≤30 lines, clearly marked `// PIPELINE:`).
- **Tasks:** flag parsing; per-step dispatch entries; keep legacy paths byte-identical when flag off.
- **Accept:** flag off ⇒ behavior identical (harness diff empty vs M0 goldens).

### WP5 — Port train  `[lane B, strictly sequential a→h]`
One PR per step. For each: read the legacy module fully; implement action wiring; map BC rows to scenarios; flip dispatch; parity-run; leave legacy code untouched.
Steps a–h per §9.2. Files touched per step are those the step's adapter needs (within WP4's marked insertion points plus `src/actions.zig` which this WP owns).
- **Accept per step:** scenarios for its BC rows pass under flag=ON; flag=OFF still identical to goldens.

### WP6 — Legacy deletion  `[lane B after M3]`
- **Files owned:** deletions across `src/window/modules/{minimize,fullscreen,workspaces}.zig` legacy bodies, `tiling.zig` replay/dedup machinery, `layouts.zig` emit path, `borders.zig` absorption into sync, unused utils shims.
- **Tasks:** delete per-port-train inverse order; keep `SizeHints` type (moved), keep pure helpers now living in layout/; update imports.
- **Accept:** build green; grep guards (WP7) pass; suite green with flag removed entirely.

### WP7 — Enforcement & documentation  `[lane C, after WP3]`
- **Files owned:** `build.zig` (check step), `scripts/check-layers.sh`, `ARCHITECTURE.md`.
- **Tasks:**
  1. Layer guard script: fail if `xcb_configure_window|XCB_CONFIG_WINDOW_*|xcb_map_window|xcb_change_attributes` appear outside `src/sync/`; `xcb_grab_server` outside sync (+legacy allowlist until M4); model/layout importing xcb.
  2. Hook into `zig build check` target; wire into CI-ish default.
  3. Write ARCHITECTURE.md from §7 + invariants §6.
- **Accept:** deliberately introducing a raw send outside sync fails the build.

### WP8 — Final audit & performance comparison  `[lane A+B, after M4]`
- **Tasks:** re-run the original 16-finding audit checklist against the new architecture (each finding must be structurally resolved or consciously re-accepted); compare bench request-counter distributions old-vs-new per event class; budget ±10% (§12.5); write results into `docs/rework-report.md`.
- **Accept:** report merged; regressions triaged with fixes or documented waivers.

---

## 11. Agent coordination guide

### Lanes

```
Lane A (WP0 ────────────────────────────────► WP8 support)
Lane B (WP1 ─► WP3 ─► WP4 ─► WP5[a..h] ─► WP6 ─► WP8)
Lane C (WP2 ──────────► WP7 ─────────────────────────────►)
```

- Three agents run concurrently through M1. After M1, lane B becomes the
  critical path (port train is strictly sequential); lanes A/C do WP7 then
  assist with scenario authoring for each train step.
- **Contract freeze (M1):** §7 signatures may change only via coordinator
  decision recorded in this file's changelog. Agents code against the frozen
  contracts, not against each other's WIP branches.
- **Ownership matrix** (exclusive writers):

| Path | WP0 | WP1 | WP2 | WP3 | WP4 | WP5 | WP6 | WP7 |
|---|---|---|---|---|---|---|---|---|
| `dev/**` | ✔ | | | | | | | |
| `src/model/**` | | ✔ | | r | r | r | r | |
| `src/layout/**` | | | ✔ | r | | r | r | |
| `src/sync/**` | | | | ✔ | r | r | r | |
| `src/actions.zig`, `src/pipeline.zig` | | | | | ✔ | ✔ | r | |
| `build.zig` | additive | | | | | | | ✔ |
| `scripts/, ARCHITECTURE.md` | | | | | | | | ✔ |
| legacy `src/window/**`, `src/core/**` | read-only | read-only | read-only | read-only | marked insertions | marked insertions | delete-only | |

(`r` = may read, not write.)
- **Conflict protocol:** needing an out-of-ownership edit ⇒ halt, produce a
  written rationale, get coordinator sign-off, then proceed.
- **PR granularity:** one WP (or one port-train step) per PR; message prefix
  `wp<n>: …` / `train(<step>): …`.
- **Shared style:** `zig fmt` clean; comments only for load-bearing invariants
  (match house style); errors via `debug.err` + graceful no-op where today's
  code does the same.

---

## 12. Testing and verification strategy

### 12.1 Harness modes
Headless Xvfb preferred (CI-able); Xephyr for interactive debugging
(fix the stale DISPLAY first). Same scenario scripts drive both.

### 12.2 Tooling
`xdotool` (synthesize input), `wmctrl` (desktop hints), `xwininfo -root -tree`
(geometry/stacking truth), `xprop` (properties/EWMH). Normalize volatile
output (IDs, timestamps) before comparison.

### 12.3 Scenario library (initial set; WP0 grows it)

| ID | Script sketch |
|----|---------------|
| S01 spawn-tiled | open xterm ×3 → assert master/stack rects, borders, focus |
| S02 close | close middle window → assert relayout |
| S03 min-restore | minimize focused → parked + focus fallback; restore → same slot |
| S04 min-from-fs | fullscreen → minimize → restore → fullscreen again w/ saved rect |
| S05 restore-all | three minimized → unminimize-all → partition/LIFO focus |
| S06 switch-basic | two ws, windows on both → switch forth/back, geometry stable |
| S07 pinned | pin a window → switch → visible everywhere; skip-map rule |
| S08 all-view | hidden-ws spawn then all-view toggle → temp windows mapped |
| S09 tag-move | move active to ws2 → atomic refocus, no hole |
| S10 fs-cycle | enter/exit → border width+pixel restored (BC14 gate) |
| S11 configure-honored | floating client resize → persists across min/restore |
| S12 client-bw | client sets own BW → survives retile |
| S13 reload | config border_width change → single-send sweep, correct widths |
| S14 drag-snap | scripted mouse drag float → snap + drop-to-tile |
| S15 monocle-focus | monocle + spawn/restore → override shown first frame |

### 12.4 Parity method
Run scenario against baseline binary and candidate; diff normalized dumps +
request-counter logs. Flag ON must match goldens semantically (stacking ties
and timing jitter allowed); flag OFF must match byte-for-byte.

### 12.5 Performance budget
Per event-class request counts within ±10% of post-audit baseline (bench
counters). Latency-critical: focus change (≤1 protocol round trip), drag tick,
switch-in fast path.

---

## 13. Enforcement

WP7 delivers `scripts/check-layers.sh` wired into `zig build check`:

- Request-emitting xcb calls (`xcb_configure_window`, `XCB_CONFIG_WINDOW_*`,
  `xcb_map_window`, `xcb_change_attributes`) only under `src/sync/`.
- `xcb_grab_server` only under `src/sync/` (+ explicit legacy allowlist file,
  emptied at M4).
- `src/model/`, `src/layout/`: no xcb/core.x11 imports.
- `zig fmt --check` gate.

Rationale: the bug class in §5 was possible because any file could send.
After enforcement, the compiler-adjacent toolchain makes the violation a
build failure instead of a user-visible mystery.

---

## 14. Risk register

| ID | Risk | L×I | Mitigation |
|----|------|-----|------------|
| R1 | Compositor quirk regressions (raiseBar/I4 removal temptation) | M×H | I4 codified; scenario S03/S10 assert restack; only remove with evidence |
| R2 | Focus protocol subtleties lost in translation | M×H | focus.zig protocol layer explicitly out of scope until train step f; BC25 gates |
| R3 | Unread-code unknowns (`scroll.zig` semantics, `floating.zig` details, bar modules) | H×M | Port agents MUST fully read their legacy module first; Q-items appendix D; harness catches drift |
| R4 | Perf regression in reconcile (O(N) rescans where O(diff) existed) | M×M | counters + ±10% budget; batch diffs are field-wise like today |
| R5 | Replay-path deletion slows switch-in | M×M | parked-rect derivation replaces it; measure S06 counters specifically |
| R6 | Flag leakage: dual paths diverge after M3 | M×M | WP6 deletes legacy immediately after default-ON soak |
| R7 | Agent conflicts on shared files | M×L | ownership matrix + conflict protocol §11 |
| R8 | Harness flakiness blocks train | M×M | normalize aggressively; retry budget; Xephyr escape hatch |
| R9 | Drag latency from scheduled reconcile | L×H | drags use immediate no-grab path (§7.6) |
| R10 | Capacity regressions (256 buffers, max_minimized) | L×H | I8 asserts in model; BC26 scenario |

---

## 15. Appendices

### Appendix A — Reading order for port agents

1. This document §§2, 4, 6, 7, 8 (mandatory).
2. Your legacy module end-to-end (e.g., `minimize.zig` for train step a) plus
   its collaborators listed in §4.1.
3. `src/sync/sync.zig` header docs + `src/model/model.zig` tests as usage
   examples.
4. Golden scenario outputs relevant to your BC rows.

### Appendix B — Audit findings ↔ structural resolution

| Finding | Summary | Resolved by |
|---|---|---|
| 1.1 Bar capture blocked inside grabs | round trips under grab | I1 + sync batching; bar reads model snapshots |
| 1.2 Double WM_PROTOCOLS query per focus | latency | protocol layer kept, single-query design retained |
| 1.3 MapRequest serial queries | pipelining | M2 pipeline preserved in adapter |
| 2.1 Float border sweep redundancy | dedup | sync field-diff (P4) supersedes |
| 2.2 Shared-window re-map on switch | redundant | visibility diff skips no-op maps |
| 2.3 Offscreen re-push guards | undecidable then | I7 modeled parking makes it trivial |
| 2.4 BORDER_WIDTH spam | dedup | applied width in LastSent |
| 3.1 moveWindowTo layout hole | atomicity | action purity + reconcileUnderGrab |
| 3.2 Pin-toggle map raced retile | atomicity | same |
| 4.1 Global cache wipes | perf | masked invalidation obsolete — no wipe needed |
| 4.2 ConfigureRequest desync | correctness | P5/I5 honored-request flow |
| 5.1 Blanket invalidation band-aid | correctness/perf | diff-based sends inherent |
| 6.1 Reload double-border send | ordering | single writer + ordered pipeline |
| 7.1 Cookie leak on early return | hygiene | I3 invariant asserted |
| 8.1 All-view unmapped temps | correctness | visibility model (BC17) |

### Appendix D — Open questions (decide during train; record answers here)

- **Q-D1** Should floating windows participate in `tiled_order` history for
  slot restoration after long float periods? (Today: implicit via pool order.)
- **Q-D2** Scroll layout's `prev_focused` restoration: model-owned param vs
  layout-internal state? Owner: WP2 with train-step-a feedback.
- **Q-D3** EWMH workspace hints: emitted from mask changes centrally in sync?
- **Q-D4** Multi-monitor/XRandR: current code assumes one screen; keep assumption, but isolate `workArea()` behind sync so future support lands in one file.

### Changelog

- 2026-08-21: Initial approved plan.

