# Hana Self-Containment Architecture

**Status:** Design implemented (Steps 1–6) and `rm -rf` self-containment for all subsystems + individual bar segments verified (see §11).
**Goal:** Every optional subsystem is a fully detachable, comptime-pluggable module. Removing a module's directory leaves **zero references to it anywhere else**, with no runtime branches, no hidden coupling, no performance cost in hot paths, and a production footprint that stays at ~12k LoC (12,412 today).

---

## 0. Scope

Detachable subsystems (each must be removable with zero residue):

| Subsystem | Directory | Currently leaked to |
|-----------|-----------|---------------------|
| Bar (whole) | `src/bar/` | 11 files outside bar |
| Each bar segment | `src/bar/segments/*` | segment.zig, bar.zig, config types/schema |
| Floating | `src/window/behaviors/floating.zig` | window.zig, input.zig, bar.zig |
| Fullscreen | `src/window/behaviors/fullscreen.zig` | window.zig, pipeline.zig, events.zig, actions.zig |
| Minimize | `src/window/behaviors/minimize.zig` | window.zig, bar.zig, input.zig |
| Workspaces | `src/window/behaviors/workspaces.zig` | window.zig, input.zig, bar.zig, segment.zig |
| Tiling (incl. each layout) | `src/tiling/` | 7 files for the config-mapping facade; engine is already behind sync |

**Not detachable** (by design, foundations): `core/`, `model/`, `sync/`, `config/` types, `window/` core (tracking/focus/borders). These are the substrate; model is intentionally imported everywhere.

---

## 1. Core principle: fact ownership

The architecture rests on one rule, applied consistently in every direction:

> **A module owns its own facts. A fact about X lives in the module that manages X. Other modules contribute to or consume those facts over clean, one-way, comptime-resolved signals — never as a named dependency.**

Applied:

| Fact | Owner | Consumers | Direction |
|------|-------|-----------|-----------|
| "which window has focus" | `core` | bar (title tab), borders | bar consumes |
| "window state changed" | `core` | bar (any segment that reflects it) | bar consumes |
| "usable screen area" | `core` | window placement, geometries | bar contributes; core owns |
| "user clicked workspace tag" | bar | `core` (switch workspace) | core consumes |
| "bar window got Expose" | bar | bar (own redraw) | self-contained, vanishes with bar |
| "a layout kind changed" | `core`/tiling | bar (layout/variants segment) | bar consumes |

The dependency arrow always points such that **removing the module removes only its contributions and reactions, and never a core branch** that references it.

---

## 2. Resolving the bar's reverse couplings (screen area)

The bar physically occupies screen space, so core must know about it. This is unavoidable, real coupling — we make it honest and general, not hidden.

**Model: Screen-space claims.** Core owns the fact `work_area: Rect` and the rule for computing it:

```
work_area = full_screen - (sum of claims contributed by active chrome surfaces)
```

- **Core** defines the concept and the math. It holds an ordered list of claims (contributor id → edge → px). It recomputes `work_area` when the claim set changes. This lives in `core` and is core's own vocabulary (usable area). It is *general* — a second bar, a dock, a notification drawer would each add a claim; core doesn't care which.
- **Bar (and any surface)** contributes claims: "I claim N px from the top edge" / "I release my claim." When bar is shown/hidden/resized, it *updates its claim*; that triggers core to recompute `work_area`. Bar never hands core a final number — **Option A**.
- When bar is absent, the claim list is empty, `work_area` = full screen. Core code is identical; there is no bar branch.

**Implementation sketch (Zig, comptime, no runtime registry):**

```zig
// core owns the claim ledger
pub const ScreenArea = struct {
    claims: [max_chrome]Claim,  // comptime-sized; zero-filled when no surfaces
    fn recompute() Rect { ... } // sum of active claims
};

// a surface opts in, at comptime, to participating in the ledger
pub fn claimScreen(comptime id, comptime edge: Edge, px: u16) void;
pub fn releaseScreen(comptime id) void;
```

Because the number of surfaces is known at comptime (it's a build-time union of which modules exist), `claims` has a fixed comptime capacity. When bar is removed, its claim id simply doesn't exist; the slot is absent. There is **no runtime registration and no vtable** — the claim dimension is resolved at compile time. This is not a facade; core genuinely owns "screen space," and surfaces genuinely contribute.

**What named concept to give chrome?** We avoid the word "chrome" (reads as the browser). Candidate names for the screen-area participation concept, owned by core:
- `ScreenArea` (the fact) + `claim screen space` (the verb)
- `ScreenClaim` / `claimScreen` / `releaseScreen`
- `Workspace` area vs `UsableArea`

**Recommended:** `core.screen` module with `ScreenArea`, `claim()`, `release()`; surfaces "claim screen space from an edge." Descriptive, chrome-agnostic, and matches the Option-A semantics.

---

## 3. Resolving the bar's reverse couplings (bar → core commands)

Bar-originated actions (workspace click, layout cycle, prompt open) are directions where **bar tells core to do something**. This is acceptable and clean because:

- The *command vocabulary* (`switchTo`, `cycleLayoutKind`, `stepVariantDir`) is core's. Bar calls into core's existing action layer — the same actions keybindings use.
- Removing bar removes the *callers*, not the core commands. Core is not dirtied with "useless bar directives"; the commands are core's own and are also reachable from keybindings.

**Rule:** a bar-initiated action is expressed as a call into core's *existing* action/command layer (`actions.*`), not a new bar-specific dispatch. This is already largely how bar works today (segment.onClick calls `actions.switchTo` etc.). We formalize it: **bar depends on core's command surface; core has no bar-specific command surface.**

---

## 4. Resolving the bar's event-loop coupling (bar is an X surface)

Bar's window lives in the same X server and shares core's poll loop. Today core has a hardcoded `bar.handleExpose()`, `bar.handlePropertyNotify()`, `bar.updateIfDirty()`, `bar.pollTimeoutMs()`, `bar.onPollWakeup()`, `bar.updateClock()`.

**Model: comptime-registered surface callbacks.** Core's event loop is compiled against a set of registered "UI surface" hooks. Because it's comptime:

```zig
// core/events.zig — the surface hooks are a comptime-known tuple
const surfaces = if (build_options.has_bar)
    .{ .{ .handleExpose = bar.handleExpose, .pollTimeoutMs = bar.pollTimeoutMs, ... } }
else
    .{};
```

When bar is removed, `surfaces` is an empty comptime tuple, and the loop over it **compiles to nothing** — no iteration, no `if (has_bar)` branch at the point of use, no emitted-but-unconsumed call. This is the "notification points exist only if a consumer exists" property, achieved at comptime. The cost is zero in the absent case and zero indirection in the present case (direct comptime-inlined `bar.*` calls).

This is **not** a runtime observer registry and **not** bspwm's socket — it's the existing `has_*` idiom generalized into a tiny comptime tuple per event-loop hook. Core still owns which X events to poll; bar just provides the handlers.

---

## 5. Resolving display-direction coupling (core facts → bar reactions)

The common case: core changes a fact (focus, window state, workspace) and bar reflects it. Today that's `actions.zig: scheduleRedraw()`, `focus.zig: scheduleFocusRedraw()`, scattered `.title` / `.workspaces` dirty marks.

**Model: bar reacts to core facts directly, in bar's own file.** Bar already reads the model/state (`pipeline.model()`). The change is that core stops poking bar for *every* change; instead:

- Core exposes its facts cleanly (focus, per-window state, workspace, a lightweight change-counter/epoch).
- Bar's segments, executing on their own draw poll, diff their inputs against the epoch and redraw the affected segment. Bar already has per-segment dirty tracking and a draw poll — we route *input to that poll* through core's facts rather than via ad-hoc `scheduleRedraw` calls from window code.

**Critical simplicity/performance guard:** we do **not** add an event bus or a generic publish/subscribe framework. That would inflate LoC and add indirection. Instead:

- Core keeps an incremental `epoch`/revision counter bumped when focus/window/workspace facts change.
- Bar, on its existing poll timeout, reads the epoch, compares to its last-seen, and refreshes the segments whose inputs changed (it already knows which inputs feed which segments).
- Removing the scattered `scheduleRedraw()` calls from `actions.zig`/`focus.zig`/`window.zig` means those files stop naming bar entirely.

This keeps the hot path unchanged (poll already exists), adds no event framework, and is entirely bar-local logic. The bar reacts because it *wants* to reflect core's facts — core never has to inform bar by name.

---

## 6. Comptime detachability of bar segments

Today `BarSegment` is a hardcoded enum in `config/types.zig` and many switch arms in `segment.zig`, and segment-specific state lives in `bar.zig`. The bar segment skeleton (`bar.zig` + `segment.zig`) must hand the segment contract over to each segment while keeping a single dispatch.

**Model: comptime segment set.** The set of active segments is a comptime-known tuple derived from the `has_seg_*` flags:

```zig
// bar/segments/segment.zig
pub const Segments = blk: {
    var list: [num_active]Segment = undefined;
    if (build_options.has_seg_tags)   list[tags.i]   = .{...tags module...};
    if (build_options.has_seg_clock)  list[clock.i]  = .{...clock module...};
    if (build_options.has_seg_title)  list[title.i]  = .{...title module...};
    ...
};
```

Each segment provides a uniform contract struct: `min_width`, `draw`, `onClick`, `getCachedWidth`, `invalidate`, and its own config field namespace. Core types gain no `.title` variant when title is absent — the "segments" concept is *owned by bar*, expressed as a comptime tuple, not a global enum in `config/types.zig`.

**Config gating:** segment-specific config lives in a per-segment config struct, gated at comptime:

```zig
// config/types.zig (or, better, owned by bar via comptime composition)
pub const BarSegConfig = if (build_options.has_seg_title) blk: {
    // title_accent_color, carousel_*, etc.
} else void;
```

This removes the flat, always-present `BarConfig` fields (`title_accent_color`, `clock_format`, `workspace_icons`, ...) that today exist even when the segment doesn't.

**Segment state location:** segment-owned mutable state (title's `titles_arena`, `titles_buf`, `focused_title`; clock's width cache) moves **into the segment module** as module state, not into `bar.zig`'s `State`. This makes deleting a segment delete its state with it. `bar.zig` shrinks dramatically and stops being a dumping ground for every segment's machinery.

**The title/prompt special case:** title currently bypasses the normal segment contract (`segment.zig` draw arm is `unreachable`) because it needs bar's scratch buffers and click trampoline. Under this model, those buffers move into `title.zig` itself, and title implements the standard `draw` / `onClick` contract like every other segment. This is the largest single refactor and the highest payoff for bar self-containment.

`scanLiveFrame` (bar.zig:479-522) collects workspace data for both tags and title. It splits into per-segment collectors owned by tags (workspace labels) and title (window titles), each fed by the same core facts, as bar-local code.

---

## 7. Window behavior detachability

The behaviors (floating, fullscreen, minimize, workspaces) are imported by several files outside `window/behaviors/`. Under fact ownership:

**Minimize (already ~self-contained):** pure query over model (`isMinimized`, `collectMinimizedIntoSet`), zero state. Move the query calls to read `model` directly, or as core facts (minimized is a per-window fact already in model's `Entry.mode`). The empty `init`/`deinit` go away. **Minimal work.**

**Workspaces:** `getState()` is consumed by bar and segment to read workspace count/labels — which are core facts (workspaces are a window-management concept, not a bar concept). Move workspace count/labels into `tracking`/core (tracking already has `workspace_labels`). `workspaces.removeWindow` is a passthrough to `tracking.removeWindow` — call tracking directly. The module then owns only the *behavior* (workspace claim rules) and `init/deinit` from config. **Small work.**

**Floating:** retains its drag state (that's core-ish — a drag is a WM operation, not chrome). The external coupling is query-only (`isDragging`, `isResizingWindow`) plus lifecycle commands (`startDrag`/`stopDrag`/`updateDrag`). Expose these through core's window/input action layer so input.zig and window.zig call `actions.startFloatingDrag(...)` rather than importing floating. **Small-medium.**

**Fullscreen (hardest):** the deferred bar-hide/show and EWMH writes are woven into `pipeline.reconcileUnderGrabNowFullscreen`. Under fact ownership: fullscreen is a *window* fact (core owns it: model already tracks `fullscreenWsOf`/`isFullscreenMode`). The EWMH advertisement and the bar-hide request are reactions to that fact. **Restructure:** core owns "window X entered fullscreen"; the *bar-hide* is a screen-claim change (fullscreen raises the bar-release signal / hides chrome) expressed via the Section 2 claim mechanism; EWMH writes are a protocol-side reaction owned by fullscreen but triggered from where core establishes the fact. The goal: core's reconcile establishes the fullscreen fact and emits the claim signal; it does not name "bar." **This is the most involved behavior refactor.**

---

## 8. Tiling detachability

The engine is already behind `sync` (good). The leak is the config-mapping facade `tiling.zig` (`layoutFromString`, `defaultLayout`, `getBorderWidth`, `isEnabled`) imported by 7 files.

- `layoutFromString` / `defaultLayout` are really *config* concerns (parsing a config string into a layout) — move to `config` or keep in tiling but have callers go through pipeline/core fact "current layout."
- `getBorderWidth` is a fact derived from config → expose via core.
- `isEnabled` is a config fact → expose via core.
- The `layout`/`variants` segment must be absent when `has_tiling` is false (comptime segment set already handles this).

Result: tiling's layouts become truly plugin-like, and the only external knowledge needed is "core exposes current layout / layout list / border width facts," which core owns.

---

## 9. Constraint: footprint & performance

**Hard constraints from the brief:**
- Production LoC stays **~12k** (12,412 today). Budget: net-neutral to slightly negative.
- Keep it **simple** — do NOT introduce an event framework, a runtime registry, a virtual dispatch system, or a socket/IPC. Every mechanism above is comptime-tuple + existing-fact + plain module ownership.
- **No performance regression.** The geometry reconcile and event-poll paths must not gain indirection. Comptime inlining is free; hot paths stay direct.

**Levers to stay within budget:**
1. Deleting dead code found in the audit (e.g. `pipeline.tilingOpFinished`, `dragTick`, `debug.logError`) offsets added plumbing.
2. Consolidating the scattered `@import("bar")` into per-module comptime surfaces *reduces* total import/guard boilerplate vs. today's inline `if (has_bar) @import("bar")` scattered throughout function bodies.
3. Moving segment state out of `bar.zig` shrinks `bar.zig` (1214 lines) and removes duplicated stub blocks (~55 lines of title/prompt stubs consolidated into the segment-set model).

**Watch items (explicitly rejected as over-engineering):**
- No pub/sub framework.
- No runtime claim registry (claims are comptime-sized; no alloc, no lookup).
- No `@Type`-generated enums with recursion — the comptime tuple of segments is simpler and sufficient.
- No new abstraction layers beyond what each coupling point genuinely needs.

---

## 10. Proposed module/map changes (target layout)

```
src/
  core/                 # substrate (unchanged role)
    screen.zig          # NEW: ScreenArea fact, claim()/release() — Option A
    facts.zig           # maybe: central epoch/revision for focus/window/ws facts
    events.zig          # comptime surface hook tuple instead of hardcoded bar.*
  config/
    types.zig           # BarSegment enum removed → segments owned by bar comptime set
                        # segment config fields moved into gated per-segment structs
  window/
    actions.zig         # stop importing bar; call core facts + command surface
    focus.zig           # stop importing bar; core owns focus fact
    window.zig          # stop importing bar; surfaces resolve via screen/service
    behaviors/          # each calls core action surface; core owns the facts
  bar/
    bar.zig             # shrinks: segment state + skip_title_refetch move out
    segments/segment.zig# comptime segment set (Segments tuple) — no global enum
    segments/title/title.zig  # owns its own scratch + implements standard contract
    segments/title/prompt.zig # same
  tiling/
    tiling.zig          # keep; callers access layout facts via core
```

---

## 11. Migration order (keeps build green at each step)

### Implementation status (Steps 1–3 DONE; rm-rf verified for all subsystems)

**Step 1 — `core/screen.zig` claim ledger — COMPLETE & VERIFIED.**
- Created `src/core/screen.zig`: `Edge`, `Claim`, comptime-sized `claims` array
  (`max_claims = if (build_options.has_bar) 1 else 0`), `bar_id`
  (`if (has_bar) 0 else null`), `setClaim`/`releaseClaim`, and
  `workArea(screen)` which subtracts claimed pixels from the edge.
- Bar contributes claims: added `syncScreenClaim()` (derives edge from
  `config.bar.bar_position`, px from `is_visible ? render.height : 0`) and
  wired it at `init`, `applyReload`, `setBarState`, `toggleBarSegmentAnchor`;
  `releaseClaim` at `deinit`.
- Migrated all 5 `workAreaRect()` consumers to read the core fact:
  `pipeline.zig` (ctx workarea + scroll path), `actions.zig` (snapScroll +
  scrollContext), `floating.zig` (work area).
- Deleted the now-dead `bar.workAreaRect()`.
- Verified: `zig build` exit 0, `zig build test` exit 0. LoC 12,412 → 12,453.

**Step 2 — `core.Facts` epochs — COMPLETE & VERIFIED.**
- Added `core.Facts` (`focus_rev`/`window_rev`/`layout_rev`) to `State` with
  free `focusRev/bumpFocus/windowRev/bumpWindow/layoutRev/bumpLayout`.
- `bar.updateIfDirty()` now diffs last-seen revisions (layout→force+markDirty,
  window→markDirty, focus→markSegmentDirty(.title)); prompt path preserved.
- Deleted dead `scheduleRedraw/scheduleFullRedraw/scheduleFocusRedraw` and all
  `schedule*` call sites; removed `bar` import from `focus.zig` entirely.

**Step 3 — core-owned surface-window fact — COMPLETE & VERIFIED.**
- Extended `core/screen.zig` with `setSurfaceWindow/clearSurfaceWindow/
  surfaceWindow/isSurfaceWindow/mappedSurfaceWindow`; bar registers its window
  id at `init` and (re)registers on `applyReload`, clears at `deinit`.
- Removed `bar` coupling from `window.zig` (`isInvalidWindow`, adoptRootWindows),
  `floating.zig`, `pipeline.zig` (`.bar_win = screen.mappedSurfaceWindow()`),
  and `focus.zig`.
- Added `Surfaces` hook struct (`bar.surfaces.*`) surfaced through `events.zig`
  and `input.zig` via the single comptime switch point.

**Step 4 — bar segment detachability — COMPLETE & VERIFIED.**
Every individual bar segment (clock, tags, layout, prompt, title, carousel) is
now comptime-detachable: deleting any `src/bar/segments/*` directory (or file)
compiles AND tests green.
- Carousel: gated `@import("carousel")` in `title.zig` behind `has_seg_carousel`
  with an inert stub (no-scroll, zero offset) — the correct degenerate case,
  since `carousel_enabled` config is absent alongside it.
- Title (the §6 "special case"): the caller-data title renderer in
  `bar.zig::drawSegment` is now comptime-eliminated when `has_seg_title=false`
  (previously it forced `bar.title.TitleRenderContext` to be compared against
  `prompt.title.TitleRenderContext`, which diverged once title became a stub).
  This was the only remaining per-segment mis-coupling.
- Removed `carousel_test` from the no-carousel test build (build.zig guard).

**Step 5 — behavior decoupling — COMPLETE & VERIFIED.**
- Added `core.Facts.fullscreen_rev` + `core.fullscreenRev()/bumpFullscreen()`.
- `actions.zig` no longer pokes the bar: the minimize/move/switch/close sites
  that changed the current workspace's fullscreen occupancy now call
  `core.bumpFullscreen()`; `fullscreen.zig` bumps it on ConfigureNotify
  confirmation. The bar reacts in `updateIfDirty()` (a new
  `applyFullscreenVisibility()` that recomputes share-screen hide/show from the
  model fact it already reads) instead of being poked by name. The `Action`
  enum lost its now-dead `hide_fullscreen/show_fullscreen` variants.
- `fullscreen.zig` no longer imports `bar` at all.

**Step 6 — tiling/config-mapping — COMPLETE & VERIFIED.**
- Routed the tiling facade's config facts into `core`:
  `core.tilingEnabled()/borderWidth()/layoutVariants()/layoutFromString()/
  defaultLayout()`.
- Zero external files now `@import("tiling")`: window.zig, borders.zig,
  input.zig, events.zig, actions.zig, bar.zig, variants.zig all read the
  facts from core/config instead of the tiling module. The tiling engine
  (`engine.zig`) remains wired only to `sync.zig`.

**Step 7 — `rm -rf` self-containment VERIFIED for every subsystem.**
Deleting each subsystem director individually compiles AND `zig build test`
exits 0 — confirmed for `bar`, `tiling`, `floating`, `fullscreen`, `minimize`,
`workspaces`, and each individual bar segment (clock/tags/layout/prompt/title/
carousel). Bar-internal and subsystem-internal unit tests are skipped in
`build.zig` when their `has_*` flag is false (matching the pre-existing
`has_seg_clock` precedent). Normal (all-present) `zig build`, `zig build test`,
and `zig build check` (layer guards + `zig fmt`) are all green.

All six steps are implemented. Final verification: production LoC
12,412 → 12,561 (within 11k–13k budget); no performance-sensitive hot path
gains any runtime indirection (all coupling is comptime-selected tuples and
revision counters).

---

## 12. Verification criteria (acceptance)

Per subsystem, the ultimate test: **`rm -rf` the subsystem directory (and drop its `has_*` flag) → project compiles, tests pass, and `rg "<subsystem>" src` returns nothing outside the subsystem.** That is the "zero references" guarantee.

Additionally:
- `tokei src/ --exclude src/test` ≈ 12k (11k–13k budget).
- No new files that are pure indirection/facades; every new file owns a real concept.
- All existing tests pass, updated where surfaces changed.
