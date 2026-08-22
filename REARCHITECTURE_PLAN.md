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
