# hana plugin provider contract & onboarding

**Who this is for:** a developer adding a new window sub-system (feature) to
hana — a minimize-style hide, a fullscreen-style screen claim, a scratchpad,
a raise-on-hover rule, anything that owns per-window state — **or** a new bar
segment (status-bar widget: clock, workspace tags, layout indicator, …) — or a
new tiling layout (placement algorithm: master-stack, monocle, grid, …).

**The one-paragraph architecture:** the WM core is feature-free. Features are
modules living under `src/<owner>/modules/` (today: `src/window/modules/` for
window behaviors, `src/bar/modules/` for bar segments, `src/tiling/modules/`
for tiling layouts); build.zig scans those directories, generates a
`<owner>_modules` registry per owner (a `[N]plugin.<Contract>` array in
deterministic sorted-stem order — `WindowModule` for `window`, `Segment` for
`bar`, `Layout` for `tiling`), and core tiers reach every feature exclusively
by iterating those arrays with uniform dispatch loops. A module is **one file
+ one export** (`pub const module: @import("plugin").<Contract>`). Dropping
the file in, or deleting it, is the entire install/uninstall step — no
registration list, no core edit, no config key (build.zig exposes a
`has_<stem>` option per file, used for optional gating only).

A **module never names the core** and lives at the same import privilege as
core code: `model`, `utils`, `constants`, `plugin`, `build_options` are
always available; other modules are reachable only through the gated-import
rule (§5); XCB through `@import("core").xcb`. Addons that share vocabulary
import it from the layer's shared-vocab file — `@import("segment")` for bar
segments (Frame, Env, DrawCtx, title snapshot types), `@import("engine")` for
tiling layouts (View, List, placement helpers) — never from each other.

Companion artifacts (each a compilable, inert drop-in template implementing
every hook with real code):
`dev/plugin-template/provider.zig` (window behavior),
`dev/plugin-template/segment.zig` (bar segment),
`dev/plugin-template/layout.zig` (tiling layout).

---

## 1. The contract: `plugin.WindowModule`

Every field is an optional hook (`null` = "this module doesn't do that").
Core dispatch loops iterate the registry array and call the hook on each
module that provides it; absent hooks are skipped, so a module binds **only
what it owns**. Dispatch order == the generated array order == sorted file
stem order — do not rely on it for starvation; the contract guarantees
disjoint ownership instead (§3).

Signatures are **stable**: changing one breaks every module and the
generated registry. Keep them verbatim.

### 1.1 Lifecycle

| Hook | Signature | Called by | Bind when |
|---|---|---|---|
| `init` | `fn () anyerror!void` | wire layer, once per boot/re-init (registry order, after the EWMH atom cache is warm) | always-ish. Reset module state (§2). |
| `deinit` | `fn () void` | wire layer, shutdown/restart, same order | always-ish. Same reset as `init`. |

### 1.2 Per-window lifecycle

| Hook | Signature | Called by | Bind when |
|---|---|---|---|
| `onWindowGone` | `fn (u32) void` | unmanage path (window.zig:1045) and close/respawn handling (events.zig:91), **after the called window's capture point, before the model entry is unregistered** (window.zig:1039) | you store per-window state. Drop every record for the XID here — dangling records are how recycled XIDs inherit stale state (model_test T12 class). |
| `notifyConfigureIfPending` | `fn (u32, u16, u16) void` | ConfigureNotify handler (events.zig:83) | you drive deferred geometry follow-ups (fullscreen's bar-show does). |

### 1.3 Screen-claim (coverage) seam

| Hook | Signature | Called by | Bind when |
|---|---|---|---|
| `coverageOn` | `fn (*const model.Model, model.WSId) ?model.WindowId` | **sync.reconcile, once per pass** (sync.zig STEP 2), through the registry | your feature can own the whole screen on a workspace (fullscreen). |

Semantics, verbatim:
- Return the window that owns `ws`'s screen, or `null`. First non-null across
  the registry wins the workspace.
- A **parked** window must never be returned (return null for
  `presence == .parked`). This is exactly how minimize-from-fullscreen ghosts
  release the screen while keeping their record (Tier-1 parity T35).
- sync does the wire work: the winner is placed at the full-screen rect;
  every other covering window is parked by sync. **Your module sends no
  geometry** for the claim — that is sync's job (§6, "only sync sends").
- State that must be observable (e.g. "which ws is this window fullscreen
  on") is answered by the module's own query fns, which core calls through
  the gated-import rule (§5) — never through this seam.

### 1.4 Session persistence seams

| Hook | Signature | Called by | Bind when |
|---|---|---|---|
| `serializeWindow` | `fn (*anyopaque, u32, std.mem.Allocator) ?[]const u8` | restart_state.save, once per stored window, through the registry | you persist per-window state across restart. |
| `deserializeWindow` | `fn (u32, []const u8, *anyopaque) bool` | window adoption (window.zig:864), once per record with a non-null `ext`, through the registry | you persist per-window state. |

Rules, verbatim:
- **The blob is opaque, module-owned bytes.** restart_state stores it under
  the window's record verbatim; only your module's deserializer may read it.
- **At most one blob per window.** The registry asks modules in order and
  keeps the first `non-null` answer. Ownership is derived from the model's
  `presence`, so the sets are disjoint regardless of order: minimize claims
  only `presence == .parked`; fullscreen claims only non-parked windows that
  hold a record. Your module's serialize must apply the same
  presence-driven exclusivity — deciding from the live model
  (that is why it receives the model).
- **Self-identify.** Byte `[0]` of your blob is a magic tag unique to your
  module (`0x5A`/'Z' = minimize, `0x46`/'F' = fullscreen; pick another).
  `deserializeWindow` checks magic + length, returns `false` for a foreign
  blob so the registry loop continues, and returns `true` only when it
  claimed the blob.
- **Allocator ownership.** A non-null `serializeWindow` result is
  allocator-owned; restart_state frees it after writing. Allocate with the
  passed allocator.
- **Graceful degrade.** Adoption dispatches deserialization for ANY record
  with a non-null `ext` (parked, covering, or a module-claimed state). If no
  module claims a blob — the feature was stripped between runs — the window
  stays in its default present/tiled state and reconciles on-screen. That is
  the contract, not an error.
- **Adoption context.** Your deserializer runs after the window was
  registered (present, tiled, `home_ws` set). Flip `presence`/`anchor` as
  your feature requires. Be idempotent: `findRec(win) != null => return true`
  without re-applying. Capacity checks come **before** any mutation (§2).
- **Versioning.** `restart_state` is tolerant across its OWN format versions
  but your blob versioning is yours: if your blob layout changes, either
  bump your magic (old blobs are simply unclaimed → graceful degrade) or
  length-check and migrate.

### 1.5 Protocol hooks (advisory wire traffic)

| Hook | Signature | Called by | Bind when |
|---|---|---|---|
| `setEwmhFullscreenState` | `fn (u32, bool) void` | the fullscreen toggle command's window-layer wrapper (actions.zig) | you advertise EWMH fullscreen. Resolve atoms in `init` via `utils.getAtomOrZero`; guard on `XCB_ATOM_NONE` before writing. |
| `armPendingBarHide` / `armPendingBarShow` | `fn (u32) void` | the same toggle wrapper, around the transition | you need deferred bar hide/show until the client's ConfigureNotify confirms dimensions. |

### 1.6 Pointer drag/resize command set

| Hook | Signature | Called by | Bind when |
|---|---|---|---|
| `startDrag` | `fn (u32, u8, i16, i16) void` | `actions.startDrag` wrapper (uniform loop) | you own a pointer-drag gesture (floating does). |
| `stopDrag` | `fn () void` | `actions.stopDrag` | same |
| `updateDrag` | `fn (i16, i16) void` | `actions.updateDrag` | same |
| `isDragging` | `fn () bool` | `actions.isDragging` | same |
| `isResizingWindow` | `fn (u32) bool` | `actions.isResizingWindow` | same |
| `getDragLastRect` | `fn () utils.Rect` | `actions.getDragLastRect` | same |
| `cancelDragForWindow` | `fn (u32) void` | `actions.cancelDragForWindow` | same |

Callers route presses/motion/config through these wrappers so the core never
names your module (`input.zig`, `window.zig` drag guards, `bar.zig` snapshot
all go through `actions.*`). A tree without your module simply has no
provider for the hook and the loop no-ops.

### 1.7 The bar-segment contract: `plugin.Segment`

A bar segment is a status-bar widget drawn into the bar's row. Registration:
`src/bar/modules/<your>.zig` exporting `pub const module: @import("plugin").Segment`
→ generates `bar_modules.modules`. The bar names NO segment module; it
dispatches everything through the registry. Shared vocabulary (`Frame`,
`Env`, `DrawCtx`, `BarHandlers`, `TitleRenderContext`, `TitleSnapshot`,
`ClickTarget`, title helpers) lives in `src/bar/segment.zig` (D4) — your
segment imports it and casts the contract's `*anyopaque` seams to it.

| Hook | Signature | Called by | Bind when |
|---|---|---|---|
| `name` / `configurable` | `[]const u8` / `bool` | — | `name` = your config identity (unique in the registry). `configurable = false` ONLY for runtime overlays that must never be config-selected (the prompt; inert templates during development). |
| `init` / `deinit` | `fn (std.mem.Allocator, core.Connection, ?*const anyopaque) anyerror!void` / `fn (std.mem.Allocator) void` | bar lifecycle, once per boot/restart (registry order) | always. Reset ALL module state (§2.2). The `anyopaque` is `*const segment.BarHandlers` when your segment needs bar services (the prompt's present-for-prompt/dismiss/is-bar-window handle, D10) — the bar passes it in, your module never imports the bar. |
| `pollTimeoutMs` | `fn () i32` | bar's join over the whole registry, each frame | you need periodic wakeups (clock). Return `<= 0` for "no wake"; the bar ignores negatives and sleeps when every segment is negative. |
| `onPollWakeup` | `fn () void` | the joined poll tick | you poll (clock). |
| `secondsElapsed` / `invalidate` | `fn ([]const u8) bool` / `fn () void` | bar second-ticker / full redraw | you render time or react to frame resets (clock; segments with caches). `secondsElapsed` returns true when your display changed so the bar redraws. |
| `measureString` | `fn () []const u8` | bar, once per frame | CLOCK ONLY — the bar reserves the clock's measured string width in the row and hands it to other segments as `clock_width`. At most one module may provide it. |
| `naturalWidth` | `fn (*const anyopaque, u16) u16` | bar, once per frame per CONFIGURED segment | your segment reserves a fixed row width (`frame` is `*const segment.Frame`, second arg the measured clock width). |
| `draw` | `fn (*anyopaque, u16) anyerror!u16` | bar, once per frame per configured segment, left-to-right | always (configured). `*anyopaque` is `*segment.DrawCtx` (bar-built per-frame scratch: dc, config, height, conn, allocator, width, minimized_api, frame, title snapshots); your segment casts back, paints with `ctx.dc`, returns its advanced x. |
| `onClick` | `fn (u16, bool, bool, *anyopaque, *const fn (*anyopaque, u16) void, *const fn () void) bool` | bar click routing | you respond to clicks (tags, layout, title). Return true when consumed (mirrors the chrome-surface input routing). |
| `handleKeypress` / `isActive` / `consumeRedrawRequest` / `invalidateReloadCaches` | prompt chrome-surface extras | bar's `Surfaces` hooks (bar binds them to whichever registry entry provides them) | PROMPT OVERLAY ONLY — the bar treats a module that binds these as its chrome-surface input provider. |

Rules, verbatim:
- **The bar calls width/draw/click ONLY on config-selected segments.** The
  config's `[bar] segments` list is a list of NAMES (strings, D7); the bar
  resolves names → registry ids once at init and loops that list for
  width-sum/draw/click. `configurable = false` segments join the uniform
  lifecycle/poll loops but never the draw loop.
- **Clock reservation:** the bar resolves `id("clock")` once at init (D6);
  `measureString` is read only from that module. A second module providing
  `measureString` would be dead code, not a conflict.
- **The prompt is not "special"** — it is a non-configurable segment whose
  poll/lifecycle hooks join the uniform loops; the title addon delegates to it
  while it is active (§5). A tree without prompt.zig simply has no
  chrome-surface input provider.
- **Bar rendering is the bar's; segments render into the shared DrawCtx** and
  the bar blits. Never send wire traffic; never touch the frame's window
  geometry.

### 1.8 The tiling-layout contract: `plugin.Layout`

A tiling layout is a placement algorithm. Registration:
`src/tiling/modules/<your>.zig` exporting `pub const module: @import("plugin").Layout`
→ generates `tiling_modules.modules`. The engine's dispatch is
registry-indexed: `model.LayoutParams.kind: u8` is an index into
`tiling_modules.modules` (D8); config layout NAMES resolve to indices once at
seed (engine.layoutByName); a persisted stale index restores to the master
layout id. Placement machinery (`engine.View`, `engine.List`, emit helpers)
lives in `src/tiling/engine.zig`; your module casts the contract's
`*anyopaque` seams to those types (see monocle.zig / layout.zig template).

| Hook | Signature | Called by | Bind when |
|---|---|---|---|
| `name` | `[]const u8` | engine layoutByName; config cycle order | always. Unique, lowercased config identity ("master", "scroll", …). |
| `compute` | `fn (*const anyopaque, *anyopaque) void` | engine, each reconcile (`engine.compute`) | always. Cast `view`→`*const engine.View`, `out`→`*engine.List`; append EXACTLY one placement per window in `v.order` (real via `engine.emitView`, parked via `engine.emitHidden`). |
| `variant_count` / `has_variants` | `u8` / `bool` | cycle_variant actions, bar variants segment | your layout exposes config-selectable variants (master 2, monocle 2, grid 2; else 1/false). Must match what your `compute` branches on. |
| `fifo_variant` | `?u8` | actions master-fifo spawn placement | ONE variant index toggles fifo spawn behavior (master binds 1). |
| `variant_parse` | `fn ([]const u8) ?u8` | config seed-time resolution | maps a registry-driven VALUE-STRING (from config `variants` words/map) to this layout's variant index; null = unknown string (uses 0). Registry-driven, no closed per-layout enums. |
| `gap_mode` | `?u8` | pipeline env `monocle_gaps` hint | the variant index at which this layout honours gaps (monocle binds 1 = "gaps"); null = gaps never toggle for this layout. Name-free hint derivation. |
| `relax_mode` | `?u8` | pipeline env `grid_relaxed` hint | the variant index at which this layout switches to its relaxed mode (grid binds 1 = "relaxed"); null = no relaxed toggle. Name-free hint derivation. |
| `slotWidth` / `maxOffset` | `fn (u16) i32` / `fn (usize, i32, u16) i32` | actions scrollStep/snapScrollToFocused/scrollContext | SCROLL LAYOUT ONLY. **Presence of these hooks is the definition of a scroll layout** (D5) — no name matching anywhere. |
| `preReconcile` | `fn (*anyopaque, usize, u16) void` | pipeline preReconcileDuties, every reconcile choke point | scroll viewport duties (snap-right on count growth, clamp). `*anyopaque` is `*model.LayoutParams`. |
| `icon` / `indicators` | `?[]const u8` / `?[]const []const u8` | bar layout/variants segments (metadata-driven, D15) | always (bar glyph + variant indicator strings). |

Rules, verbatim:
- **One placement per window, always.** A layout that skips a window leaves
  it un-tiled; park windows you deliberately don't show.
- **Pure compute.** `compute` must be allocation-free and side-effect-free
  (zero-allocation `engine.List`). All wire traffic flows through sync.
- **Names, not enums.** Core never switches over layouts; adding a layout is
  a drop-in file, removing one just shortens the registry (kind restore
  falls back to master). Config list order is the cycle order (engine
  `cycleKind`).

---

## 2. What a module MUST get right (ownership laws)

1. **Module state lives in file-scope `var`s** — static, allocation-free,
   compile-time-bounded (a fixed `[MAX]T` array + length, not a heap
   structure). One WM per process, one module store per module. (Bar segments
   and tiling layouts are the same: their state is static and reset by
   init/deinit.)
2. **`init`/`deinit` reset everything.** They are the same reset function
   (`pub fn init() anyerror!void` → reset + atom re-resolve; `deinit` → the
   same reset). Tests depend on this: a test fixture runs
   `try minimize.init(); defer minimize.deinit();` per test *because the
   store is process-global, not per-model* — model_test T17/T18 fail without
   it. If you add a test suite, make every fixture initiate a clean module
   lifetime (and reset OTHER modules your test touches, e.g. fullscreen's
   store, between replay fixtures).
3. **Capacity checks precede every mutation.** A full store must refuse
   cleanly (return `false`/`error.CapacityFull`) leaving the model and your
   store byte-identical (model_test T17). A refusal must never half-mutate.
4. **The model entry is the source of truth; your store is derived state.**
   Read the model to serialize (presence-driven ownership) and to decide
   coverage. Never write model fields your feature doesn't own.
5. **Presence is your API surface.** `Entry.presence` is
   `union(enum){ present, parked, covering }`:
   - `present` — visible, normal. default.
   - `parked` — hidden by an extension (minimize). invisible to
     `model.visibleOn`, excluded from layouts, parked offscreen by sync.
   - `covering` — holds the screen (fullscreen). Handled by sync's coverage
     winner logic; a covering window that is NOT the winner is parked.
   Your feature flips presence to drive visibility; sync derives all wire
   traffic from it.
6. **Blob exclusivity** (§1.4): parked ⇒ minimize's slot; covering ⇒
   fullscreen's slot; choose a disjoint presence class if you persist.

## 3. The model vocabulary you build on

`model.Entry = { mask, anchor: BaseMode, presence, home_ws, size_hints }`.
- `BaseMode = union(enum){ tiled, floating: utils.Rect }` — the window's
  placement *paradigm*. `anchor` is what survives fullscreen/minimize: both
  leave it untouched and the window returns to it.
- `mask` — the window's tag set (`model.bit(ws)`). `model.visibleOn(m, win, ws)`
  is the visibility predicate (parked ⇒ false; covering ⇒ mask bit).
- Single-membership invariant: every tiled-anchored, present window appears
  in **exactly one** `ws.tiled_order`; floating and parked windows are
  home-free (`home_ws == null`). Preserve it — model_test's
  `assertSingleMembership` enforces it.
- Shared vocabulary types that two modules both need (`RestoreOrder`,
  `ConfigureReq`, `HonorDecision`, …) live in **model.zig**, never in a
  module. Model is layer-0: it imports nothing but std+utils and never
  imports plugin/window_modules.
- Model functions are feature-free: `model.unregister` does NOT touch your
  records. The wire layer fires your `onWindowGone` after it — that dispatch
  is the only teardown contact.

## 4. Discovery, gating, and build options

- build.zig walks `src/` for directories named `modules/`; every `.zig` stem
  becomes an entry in a generated `<owner>_modules` registry module
  (`src/window/modules/` → `window_modules`, `src/bar/modules/` → `bar_modules`,
  `src/tiling/modules/` → `tiling_modules`; the registry element type is the
  per-owner contract: `WindowModule` / `Segment` / `Layout`). It also emits
  `build_options.has_<stem>` for `<owner>/modules/<stem>.zig` files that
  appear in the `hasPathOption` list (build.zig:49-84). Core compiles
  feature-dependent code under `if (build_options.has_<stem>)`.
- **Registering a NEW modules/ owner** (a fourth `src/<x>/modules/`): add the
  owner to build.zig's `ownerContractName` map with its contract.
- Segments keep their probe/option convention too — `has_seg_<stem>` for
  `src/bar/modules/<stem>.zig`, helpers under `src/bar/support/` keep their
  own probes (`has_vim`, `has_seg_carousel`) — all listed in build.zig:49-84.
- Test gating: `zig build test` builds every `src/test/*_test.zig`; each
  suite lists its module requirements in build.zig (e.g. model_test needs
  all four; sync_test needs tiling+minimize+fullscreen). If your feature has
  a test suite that requires it, **add the matching skip line** in build.zig
  next to the others (lines ~174-191).
- Deleting a module file: the whole subtree disappears from the build —
  that's the *modularity contract* enforced by `dev/scripts/check-modularity.sh`.
  Deleting YOUR module must leave the build green (your call sites are
  gated; the model doesn't import you). If `check-modularity` has no
  scenario for your module, that's fine — the full-matrix scenarios cover
  all four modules; the gated-import rule is what keeps new ones safe.

## 5. Feature ⇄ feature interaction

Two features rarely talk; when they do, honor the two rules (they are what
make `rm <module>` always safe):

1. **Gated body-only imports.** `@import("otherfeature")` may appear ONLY
   inside a function body, behind `if (build_options.has_otherfeature)`.
   Never in a signature, top-level `const`, struct/union type, or `test`
   (a comptime-false `@import` at file scope still TYPE-CHECKS the imported
   module and names its files — the whole point of a module is that those
   files are deletable). When a feature is absent, the reference must not
   even resolve.
2. **Shared vocabulary goes to model.** A type/constant two features (or a
   feature and core) both need is defined in model.zig once. Modules never
   export types core consumes through the registry; the registry carries
   function pointers with model-level signatures only.

Cross-feature semantics to study (each is an existing answer to a real
interaction): workspaces move/tag transfer drops a covering window via
`toggleFullscreen` rather than clobbering a resident; minimize's
`latestMinimizedBase` skips fullscreen-record windows via a gated
`isFullscreenMode` query; floating's `honorConfigureRequest` refuses covering
windows.

Same rules apply on the bar and tiling layers:
- **Hook presence replaces name matching** (D5): "is the active layout a
  scroll layout?" == "does it register `slotWidth`/`maxOffset`/`preReconcile`?".
  Never compare names in core.
- **Cross-addon seams live INSIDE the importing addon, gated**:
  title→prompt (overlay delegation, D9), title→carousel (scrolling),
  title→minimize (minimized decorations, D12), prompt→vim (modal
  keybinding, D11), workspaces→fullscreen. The bar core names none of them.
- **Segments receive bar services by handle, not import** (D10): the prompt
  gets `segment.BarHandlers` (present/dismiss/is-bar-window) through its
  `init` argument — the reverse edge (`@import("bar")` inside a segment)
  must never appear.

## 6. What core guarantees you (so you never send wire traffic)

- **Only sync sends.** Geometry, border, map, park, stack — every X request
  for managed windows flows through `sync.reconcile`, which recomputes the
  whole desired state each pass from anchor/presence/coverage. Your module
  mutates the model; sync derives the traffic. (The one carve-out is the
  advisory protocol hooks of §1.5, which post atoms/properties around
  sync-driven geometry.)
- **Coverage winner logistics**: place me, park everyone else — sync's job.
- **Teardown**: the wire fires `onWindowGone` before the model entry goes,
  every time a window dies (destroy, respawn handling).
- **Restart**: `.json` save/load is core-managed; you only marshal/unmarshal
  your blobs (§1.4) and reset in init/deinit.

## 7. Writing a module — step by step

1. `cp dev/plugin-template/provider.zig src/window/modules/<your>.zig` (or
   `segment.zig` → `src/bar/modules/`, or `layout.zig` → `src/tiling/modules/`)
   and edit the TODO markers:
   - define your per-window record + budget (window behaviors);
   - implement your real predicates in `coverageOn` (or delete the binding);
   - replace the demo blob fields with your persisted state (keep the
     self-identifying magic + presence-driven exclusivity);
   - flip `presence` in your feature's own API (minimize-style actions live
     in the module and are invoked through the wire/`actions.*` wrappers).
   - For a segment: set a unique `name`, `configurable = true`, bind the
     width/draw/click hooks you need, keep `configurable = false` while
     developing (the drop-in stays invisible to config).
   - For a layout: set a unique lowercased `name`, implement `compute`
     against `engine.View`/`engine.List` (monocle.zig is the smallest real
     example), set `variant_count`/`fifo_variant`/`icon`/`indicators`; the
     scroll hooks only for a viewport layout.
2. Resolve your build option if core needs to gate on you:
   `hasPathOption(b, build_opts, "has_your", source_root ++ "window/modules/your.zig")`
   and use `if (build_options.has_your) @import("your").query(...)` at call
   sites (body-only, §5.1).
3. Bind your `module` export with exactly the hooks you implement.
4. Add a test suite `src/test/your_test.zig` (mirror model_test's fixture
   discipline: init/deinit per test) and the build.zig skip-line from §4.
5. Run the verification battery (§8).

## 8. Verification battery (run this before claiming done)

```sh
zig fmt --check src/ && zig build
zig build test --summary all          # full config; log the count
dev/scripts/check-layers.sh           # all layer rules pass
dev/scripts/check-modularity.sh       # 2 intentional FAILs (tiling+floating,
                                      #   everything-optional) are the baseline
# deletion variants (each must build + reduced tests pass):
rm src/window/modules/your.zig && zig build && zig build test
# wire-shape parity (your module is inert => zero diff vs goldens):
cd dev/harness && BUILD_DEBUG=1 ./run-scenario.sh --compare S01..S21
```

The template's own "inert" litmus: with `provider.zig` in
`src/window/modules/`, build + tests stay identical (110/110, harness
PASS-set unchanged) — proving the contract adds no coupling.

## 9. Gotchas (each one is a bug we already fixed)

- **Recycled XIDs inherit stale state** if `onWindowGone` misses a path
  (window.zig unmanage vs events.zig close handling — register BOTH
  dispatch reaches you with the same hook, no extra work; just make sure
  your hook handles every window id).
- **A parked window must never be a coverage winner** — else
  minimize-from-fullscreen keeps the screen it shouldn't (FSQ/T35 class).
- **tests that share the module store**: two fixtures in one binary share
  your static state — the init/deinit-per-test rule (§2.2) is what keeps
  them deterministic (T17/T18 class).
- **serialize must read presence from the model, not your store** — a
  record alone is not ownership (a ghost record is parked ⇒ minimize owns
  the slot).
- **byte-exact harness parity**: if your module is present but inert while you
  develop it, the S01..S21 goldens stay byte-identical. Once you wire
  real behavior, capture new goldens deliberately — never by hand-editing.
- **Distinct file stems across owners.** Module discovery registers every
  `.zig` stem flat — `src/bar/modules/inert_probe.zig` and
  `src/tiling/modules/inert_probe.zig` collide. Name your module files
  uniquely.
- **A `configurable = false` segment still joins the loops.** The bar runs
  lifecycle and poll hooks (pollTimeoutMs/onPollWakeup/secondsElapsed/
  invalidate) on EVERY registry entry every frame; return negative from
  pollTimeoutMs when you need no wakeups, and keep your hooks inert while
  developing.
- **Scroll is a hook presence, not a name.** Don't gate on a layout name;
  the engine/actions test the active module's `slotWidth`/`maxOffset`/
  `preReconcile` bindings.
- **Layout kind restore.** A persisted `restart_state` numeric kind that no
  registry entry matches falls back to the master layout id (by name, else
  the first entry) — a removed layout degrades gracefully, never to an
  unresolvable dispatch.