# Refactor Plan: Plugin-Based Subsystem Architecture

## Problem Statement

The current hook system (`src/core/hooks.zig`) is a 576-line central registry of 81 nullable
function pointers. When an optional subsystem (bar, tiling, floating, drag, vim prompt) is
removed by deleting its source directory, its hooks, accessors, and shared types **remain**
in `hooks.zig`. 166 call sites across 17 files still reference these hooks. The core event
loop embeds subsystem-specific dispatch logic. Adding a new subsystem requires touching the
central registry in three places (struct fields, accessors, shared types).

**Goal:** Make each optional subsystem fully self-contained. Removing a subsystem's source
directory should leave zero references to it anywhere in the remaining codebase.

---

## Architecture Overview

### Current Design
```
hooks.zig (central registry, 81 fields, 576 lines)
  ├── bar hooks (25 fields + 25 accessors + BarAction type)
  ├── tiling hooks (45 fields + 45 accessors + TilingRetileOpts type)
  ├── carousel hooks (4 fields + 4 accessors)
  ├── prompt hooks (4 fields + 4 accessors)
  ├── drag hooks (7 fields + 7 accessors)
  └── floating hooks (1 field + 1 accessor)

main.zig calls hooks.registerHooks() for each module
events.zig calls hooks.* by name (bar, tiling, prompt)
17 consumer files import hooks and call hooks.*BySubsystem()
```

### New Design
```
hooks.zig (plugin interface only, ~60 lines)
  └── Plugin struct: lifecycle + XCB event + event-loop integration points

Each optional subsystem module is self-contained:
  bar.zig     → exports `pub const plugin: hooks.Plugin = .{...};`
                  exports pub functions: workAreaRect(), isBarWindow(), scheduleRedraw(), etc.
                  owns BarAction type, all bar-specific logic

  tiling.zig  → exports `pub const plugin: hooks.Plugin = .{...};`
                  exports pub functions: addWindow(), removeWindow(), isWindowTiled(), etc.
                  owns TilingRetileOpts, TilingLayoutVariants, all tiling-specific types

  drag.zig    → exports `pub const plugin: hooks.Plugin = .{...};`
                  exports pub functions: start(), stop(), isDragging(), etc.

  floating.zig→ exports `pub const plugin: hooks.Plugin = .{...};`
                  exports pub functions: tileWithOffset()

  carousel.zig→ exports `pub const plugin: hooks.Plugin = .{...};`
                  exports pub functions: setEnabled(), notifyFocusChanged(), etc.

  prompt.zig  → exports `pub const plugin: hooks.Plugin = .{...};`
                  exports pub functions: handleKeypress(), toggle(), blinkPollTimeoutMs(), etc.

plugins.zig (comptime-generated plugin list)
  → conditionally includes each subsystem's plugin based on build_options
  → provides: list (comptime array), count, initAll(), deinitAll()

Consumer files import subsystem modules directly:
  const bar = @import("bar");
  bar.workAreaRect()   // instead of hooks.barWorkAreaRect()
  bar.scheduleRedraw() // instead of hooks.barScheduleRedraw()
```

---

## Phase 0: Create the Plugin Interface

### Step 0.1: Define `hooks.Plugin` in `src/core/hooks.zig`

**File:** `src/core/hooks.zig`

Replace the entire file. The new file should contain:

1. **Imports** (same as before: std, core, xcb, utils, types, layouts, constants)
2. **The Plugin struct** — every optional integration point as an optional function pointer
3. **Shared types that multiple subsystems depend on** — these stay here ONLY if they are
   used across subsystem boundaries. See Step 0.2 for what stays and what moves.
4. **Default values for types used in Plugin signatures** (e.g., fullScreenRect)

The Plugin struct fields (determined by auditing where the core event loop and cross-subsystem
calls need optional integration):

```zig
pub const Plugin = struct {
    // -- Lifecycle --
    init: ?*const fn () anyerror!void = null,
    deinit: ?*const fn () void = null,
    reload: ?*const fn () void = null,

    // -- XCB event handlers (core event loop dispatches to these) --
    on_expose: ?*const fn (*const xcb.xcb_expose_event_t) void = null,
    on_property_notify: ?*const fn (*const xcb.xcb_property_notify_event_t) void = null,
    on_button_press: ?*const fn (*const xcb.xcb_button_press_event_t) void = null,

    // -- Event-loop integration (called per batch/iteration) --
    post_batch: ?*const fn () anyerror!void = null,
    iteration_end: ?*const fn () bool = null,

    // -- Poll integration --
    poll_timeout_ms: ?*const fn () i32 = null,
    on_poll_wakeup: ?*const fn () void = null,
};
```

**Rationale for each field:**

| Field | Replaces | Used by |
|-------|----------|---------|
| `init` / `deinit` | `bar_init` / `bar_deinit`, `tiling_init` / `tiling_deinit` | main.zig plugin lifecycle |
| `reload` | `bar_reload`, `tiling_reload_config` | events.zig handleConfigReload |
| `on_expose` | `bar_handle_expose` | events.zig dispatch table |
| `on_property_notify` | `bar_handle_property_notify` | events.zig handlePropertyNotify |
| `on_button_press` | `bar_handle_button_press` | input.zig handleButtonPress |
| `post_batch` | `bar_update_if_dirty`, `tiling_retile_if_dirty` | events.zig handleXcbEvents |
| `iteration_end` | `bar_update_clock` | events.zig run loop |
| `poll_timeout_ms` | `prompt_blink_poll_timeout_ms` | events.zig run loop |
| `on_poll_wakeup` | `prompt_blink_tick` + `bar_submit_draw` | events.zig run loop (poll timeout) |

**Keep the following in hooks.zig** (used by Plugin struct signature):

```zig
// Shared defaults for Plugin return values
fn fullScreenRect() utils.Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = @intCast(core.getState().screen.width_in_pixels),
        .height = @intCast(core.getState().screen.height_in_pixels),
    };
}
```

### Step 0.2: Determine shared type ownership

These types are currently defined in `hooks.zig` and used across subsystem boundaries:

| Type | Defined in | Used by | New home |
|------|-----------|---------|----------|
| `BarAction` | hooks.zig | bar.zig (re-exports), events.zig (via hooks) | **bar.zig** — only bar uses it |
| `TilingRetileOpts` | hooks.zig | tiling.zig (hook_map cast), workspaces.zig (via hooks) | **tiling.zig** — tiling's interface type |
| `TilingLayout` | hooks.zig (re-export of types.Layout) | layout.zig, variants.zig, workspaces.zig, tiling.zig | **types.zig** (canonical: `types.Layout`) — already defined there |
| `TilingLayoutVariants` | hooks.zig | variants.zig (via hooks) | **tiling.zig** — tiling's interface type |
| `MasterVariant` | hooks.zig (re-export of types.MasterVariant) | embedded in TilingLayoutVariants | **types.zig** (canonical) — already defined there |
| `MonocleVariant` | hooks.zig (re-export of types.MonocleVariant) | embedded in TilingLayoutVariants | **types.zig** (canonical) — already defined there |
| `GridVariant` | hooks.zig (re-export of types.GridVariant) | embedded in TilingLayoutVariants | **types.zig** (canonical) — already defined there |

**Migration plan for types:**

1. `TilingLayout` → consumers import `types.Layout` directly (it's already the canonical definition).
   Remove the `hooks.TilingLayout` re-export. Consumers that currently write
   `const TilingLayout = hooks.TilingLayout` change to `const TilingLayout = types.Layout`.

2. `TilingLayoutVariants` → move to `tiling.zig` as `pub const LayoutVariants = struct { ... };`.
   Consumers that need it import tiling directly.

3. `TilingRetileOpts` → move to `tiling.zig` as `pub const RetileOpts = struct { ... };`.
   Consumers that need it import tiling directly.

4. `BarAction` → move to `bar.zig` as `pub const Action = enum { ... };`.
   Consumers that need it import bar directly.

5. `MasterVariant`, `MonocleVariant`, `GridVariant` → already canonically defined in
   `config/types.zig`. Remove the re-exports from hooks.zig. Consumers import `types` directly.

### Step 0.3: Create `src/plugins.zig`

**File:** `src/plugins.zig` (new file)

This module composes the plugin list at comptime:

```zig
const build_options = @import("build_options");
const hooks = @import("hooks");

/// Maximum number of simultaneous plugins. Increase if more optional subsystems are added.
const MAX_PLUGINS = 8;

/// Comptime-built list of registered plugins. Only includes subsystems that exist.
pub const list: [MAX_PLUGINS]hooks.Plugin = comptime blk: {
    var result: [MAX_PLUGINS]hooks.Plugin = .{.{}} ** MAX_PLUGINS;
    var n: usize = 0;

    if (build_options.has_bar) {
        result[n] = @import("bar").plugin;
        n += 1;
    }
    if (build_options.has_tiling) {
        result[n] = @import("tiling").plugin;
        n += 1;
    }
    if (build_options.has_drag) {
        result[n] = @import("drag").plugin;
        n += 1;
    }
    if (build_options.has_floating) {
        result[n] = @import("floating").plugin;
        n += 1;
    }

    break :blk result;
};

/// Number of active plugins.
pub const count: usize = comptime count: {
    var n: usize = 0;
    if (build_options.has_bar) n += 1;
    if (build_options.has_tiling) n += 1;
    if (build_options.has_drag) n += 1;
    if (build_options.has_floating) n += 1;
    break :count n;
};

/// Initialize all plugins in order. Called from main.zig.
pub fn initAll() void {
    inline for (list[0..count]) |p| {
        if (p.init) |f| f() catch |err| {
            // log error, continue — same as current bar.init behavior
        };
    }
}

/// Deinitialize all plugins in reverse order. Called from main.zig.
pub fn deinitAll() void {
    var i = count;
    while (i > 0) {
        i -= 1;
        if (list[i].deinit) |f| f();
    }
}

/// Fan-out: call a Plugin field on all plugins that have it.
/// Used for events that multiple plugins need to observe.
pub fn fanOut(comptime field: anytype, args: anytype) void {
    inline for (list[0..count]) |p| {
        if (@field(p, field)) |f| {
            @call(.auto, f, args);
        }
    }
}
```

**Note on `fanOut`:** This is a convenience for the event loop. For example,
`plugins.fanOut(.post_batch, .{})` calls `post_batch` on every plugin that has it.
This replaces the explicit `hooks.tilingRetileIfDirty(); hooks.barUpdateIfDirty();` calls.

### Step 0.4: Update `build.zig`

**File:** `build.zig`

Add `plugins` to the auto-discovered modules. Since `build.zig` already auto-discovers every
`.zig` file under `src/`, and `plugins.zig` will live at `src/plugins.zig`, it will be
discovered automatically. **No build.zig changes needed** — the existing module discovery
handles this.

Verify: after creating `src/plugins.zig`, run `zig build` and confirm the `plugins` module
is importable from other modules.

---

## Phase 1: Migrate the Bar Subsystem

The bar is the largest subsystem (25 hooks) and the most interconnected. Migrating it first
establishes the pattern for all others.

### Step 1.1: Add `pub const plugin` to `src/bar/bar.zig`

**File:** `src/bar/bar.zig`

Add at the top of the file (after imports):

```zig
const hooks = @import("hooks");

pub const plugin = hooks.Plugin{
    .init = init,
    .deinit = deinit,
    .reload = reload,
    .on_expose = handleExpose,
    .on_property_notify = handlePropertyNotify,
    .on_button_press = handleButtonPress,
    .post_batch = updateIfDirty,
    .iteration_end = updateClock,
    .on_poll_wakeup = struct {
        fn f() void {
            submitDraw();
        }
    }.f,
};
```

**Note on `.on_poll_wakeup`:** The current event loop calls both `promptBlinkTick()` and
`barSubmitDraw()` on poll wakeup. The prompt's blink tick is handled by prompt's plugin.
The bar's `submitDraw()` is a bar concern and belongs here. See Step 1.6 for how the
event loop wires this.

### Step 1.2: Move `BarAction` into `src/bar/bar.zig`

**File:** `src/bar/bar.zig`

Add the type definition:

```zig
pub const Action = enum { toggle, hide_fullscreen, show_fullscreen };
```

Remove the re-export `pub const BarAction = hooks.BarAction;` (line 37).

### Step 1.3: Ensure all bar public functions exist

The bar module already has these public functions that consumers call. Verify they exist
and are `pub`:

From the current hook_map and accessors, the bar must export:

| Current hooks.zig accessor | New direct call | Signature |
|---------------------------|-----------------|-----------|
| `barInit()` | `bar.init()` | `fn () !void` |
| `barDeinit()` | `bar.deinit()` | `fn () void` |
| `barReload()` | `bar.reload()` | `fn () void` |
| `barSubmitDraw()` | `bar.submitDraw()` | `fn () void` |
| `barToggleSegmentAnchor()` | `bar.toggleSegmentAnchor()` | `fn () void` |
| `barScheduleFocusRedraw(?u32)` | `bar.scheduleFocusRedraw(?u32)` | `fn (?u32) void` |
| `isBarWindow(u32)` | `bar.isBarWindow(u32)` | `fn (u32) bool` |
| `barGetBarHeight()` | `bar.getBarHeight()` | `fn () u16` |
| `barWorkAreaRect()` | `bar.workAreaRect()` | `fn () utils.Rect` |
| `barScheduleRedraw()` | `bar.scheduleRedraw()` | `fn () void` |
| `barScheduleFullRedraw()` | `bar.scheduleFullRedraw()` | `fn () void` |
| `barScheduleTitleRedraw()` | `bar.scheduleTitleRedraw()` | `fn () void` |
| `barIsVisible()` | `bar.isVisible()` | `fn () bool` |
| `barRedrawInsideGrab()` | `bar.redrawInsideGrab()` | `fn () void` |
| `barCommitInsideGrab()` | `bar.commitInsideGrab()` | `fn () void` |
| `barRaiseBar()` | `bar.raiseBar()` | `fn () void` |
| `barPresentForPrompt()` | `bar.presentForPrompt()` | `fn () void` |
| `barDismissAfterPrompt()` | `bar.dismissAfterPrompt()` | `fn () void` |
| `barSetBarState(BarAction)` | `bar.setBarState(Action)` | `fn (Action) void` |
| `barUpdateIfDirty()` | `bar.updateIfDirty()` | `fn () !void` |
| `barUpdateClock()` | `bar.updateClock()` | `fn () bool` |
| `barTickCarousel()` | `bar.tickCarousel()` | `fn () void` |
| `barHandleExpose(*const xcb_expose_event_t)` | `bar.handleExpose(...)` | already pub |
| `barHandlePropertyNotify(...)` | `bar.handlePropertyNotify(...)` | already pub |
| `barHandleButtonPress(...)` | `bar.handleButtonPress(...)` | already pub |

Most of these should already be `pub` in bar.zig since they were referenced by the hook_map.
Verify each one. If any are not `pub`, make them `pub`.

### Step 1.4: Remove bar's `hook_map` from `src/bar/bar.zig`

**File:** `src/bar/bar.zig`

Delete the entire `pub const hook_map = .{ ... };` block (lines 1587-1613).
This is no longer needed — the plugin struct replaces it.

### Step 1.5: Migrate carousel and prompt into bar's plugin

Carousel and prompt are bar sub-modules. They currently have their own hook_maps.
In the new design, they are **internal to bar** and don't need separate plugins.

**carousel.zig:** Keep its public functions. Bar calls them directly.
Remove `pub const hook_map = .{ ... };` from carousel.zig.

**prompt.zig:** Keep its public functions. Bar calls them directly.
Remove `pub const hook_map = .{ ... };` from prompt.zig.

Bar's plugin `.on_poll_wakeup` should call both `submitDraw()` (bar's own) and
`prompt.blinkTick()` (prompt's own). Since carousel and prompt are bar sub-modules
that bar imports directly, this works without any central registry.

If prompt's `blinkPollTimeoutMs()` is needed by the event loop, expose it through
bar:

```zig
// bar.zig
pub fn promptBlinkPollTimeoutMs() i32 {
    return prompt.blinkPollTimeoutMs();
}
```

Then the event loop calls `bar.promptBlinkPollTimeoutMs()` instead of
`hooks.promptBlinkPollTimeoutMs()`. This keeps the bar as the single integration
point for all bar-related functionality.

### Step 1.6: Migrate all bar consumer call sites

**166 total call sites.** Bar-specific ones to migrate:

#### `src/core/events.zig` (6 bar calls)

| Line | Current | New |
|------|---------|-----|
| 57 | `hooks.barHandleExpose(...)` | Remove this wrapper function. See Step 2.2 for how events.zig dispatches to plugins. |
| 63 | `hooks.barHandlePropertyNotify(e)` | Remove from handlePropertyNotify. See Step 2.2. |
| 263 | `hooks.barReload()` | `plugins.fanOut(.reload, .{})` — bar's reload fires through the plugin |
| 310 | `hooks.barUpdateIfDirty() catch ...` | Remove — handled by `plugins.fanOut(.post_batch, .{})` in Step 2.2 |
| 347 | `hooks.barSubmitDraw()` | Handled by `on_poll_wakeup` fan-out in Step 2.2 |
| 367 | `hooks.barUpdateClock()` | Handled by `iteration_end` fan-out in Step 2.2 |

#### `src/core/input/input.zig` (5 bar calls)

| Line | Current | New |
|------|---------|-----|
| 167 | `hooks.barHandleButtonPress(event)` | Handled by plugin fan-out in Step 2.2 |
| 297 | `hooks.barSetBarState(.toggle)` | `bar.setBarState(.toggle)` — import bar directly |
| 298 | `hooks.barToggleSegmentAnchor()` | `bar.toggleSegmentAnchor()` |
| 716 | `hooks.barRedrawInsideGrab()` | `bar.redrawInsideGrab()` |

Remove `const hooks = @import("hooks");` from input.zig if no other hooks remain.
Add `const bar = if (build_options.has_bar) @import("bar") else null;` and guard calls:

```zig
if (bar) |b| b.setBarState(.toggle);
```

#### `src/window/window.zig` (4 bar calls)

| Line | Current | New |
|------|---------|-----|
| 164 | `hooks.barRedrawInsideGrab()` | `bar.redrawInsideGrab()` (with build_options guard) |
| 934 | `hooks.barScheduleRedraw()` | `bar.scheduleRedraw()` |
| 1053 | `hooks.barSetBarState(.show_fullscreen)` | `bar.setBarState(.show_fullscreen)` |

Add `const bar = if (build_options.has_bar) @import("bar") else null;` and guard all calls.

#### `src/window/focus.zig` (2 bar calls)

| Line | Current | New |
|------|---------|-----|
| 276 | `hooks.barScheduleFocusRedraw(win)` | `bar.scheduleFocusRedraw(win)` |
| 523 | `hooks.barScheduleFocusRedraw(null)` | `bar.scheduleFocusRedraw(null)` |

#### `src/window/modules/workspaces.zig` (9 bar calls)

| Line | Current | New |
|------|---------|-----|
| 261 | `hooks.barScheduleRedraw()` | `bar.scheduleRedraw()` |
| 289 | `hooks.barCommitInsideGrab()` | `bar.commitInsideGrab()` |
| 374 | `hooks.barScheduleRedraw()` | `bar.scheduleRedraw()` |
| 441 | `hooks.barRaiseBar()` | `bar.raiseBar()` |
| 442 | `hooks.barCommitInsideGrab()` | `bar.commitInsideGrab()` |
| 472 | `hooks.barScheduleRedraw()` | `bar.scheduleRedraw()` |
| 653 | `hooks.barSetBarState(.hide_fullscreen)` / `.show_fullscreen` | `bar.setBarState(...)` |
| 678 | `hooks.barRaiseBar()` | `bar.raiseBar()` |
| 679 | `hooks.barCommitInsideGrab()` | `bar.commitInsideGrab()` |

#### `src/window/modules/fullscreen.zig` (4 bar calls)

| Line | Current | New |
|------|---------|-----|
| 393 | `hooks.barSetBarState(.show_fullscreen)` | `bar.setBarState(.show_fullscreen)` |
| 490 | `hooks.barSetBarState(.hide_fullscreen)` | `bar.setBarState(.hide_fullscreen)` |
| 495 | `hooks.barSetBarState(.show_fullscreen)` | `bar.setBarState(.show_fullscreen)` |
| 507 | `hooks.barSetBarState(.show_fullscreen)` | `bar.setBarState(.show_fullscreen)` |

#### `src/window/modules/minimize.zig` (5 bar calls)

| Line | Current | New |
|------|---------|-----|
| 140 | `hooks.barSetBarState(.show_fullscreen)` | `bar.setBarState(.show_fullscreen)` |
| 144 | `hooks.barCommitInsideGrab()` | `bar.commitInsideGrab()` |
| 169 | `hooks.barScheduleRedraw()` | `bar.scheduleRedraw()` |
| 199 | `hooks.barCommitInsideGrab()` | `bar.commitInsideGrab()` |
| 346 | `hooks.barCommitInsideGrab()` | `bar.commitInsideGrab()` |

#### `src/window/modules/tiling/tiling.zig` (9 bar calls)

| Line | Current | New |
|------|---------|-----|
| 225 | `hooks.barRedrawInsideGrab()` | `bar.redrawInsideGrab()` |
| 403 | `hooks.barWorkAreaRect()` | `bar.workAreaRect()` |
| 433 | `hooks.barWorkAreaRect()` | `bar.workAreaRect()` |
| 460 | `hooks.barWorkAreaRect()` | `bar.workAreaRect()` |
| 478 | `hooks.barWorkAreaRect()` | `bar.workAreaRect()` |
| 646 | `hooks.barWorkAreaRect()` | `bar.workAreaRect()` |
| 669 | `hooks.barWorkAreaRect()` | `bar.workAreaRect()` |
| 1129 | `hooks.barScheduleTitleRedraw()` | `bar.scheduleTitleRedraw()` |
| 1214 | `hooks.barScheduleFullRedraw()` | `bar.scheduleFullRedraw()` |

**Important for tiling.zig:** When bar is absent, `bar.workAreaRect()` doesn't exist.
Use the build_options guard pattern:

```zig
const bar = if (build_options.has_bar) @import("bar") else null;

// In functions that need work area:
const work_area = if (bar) |b| b.workAreaRect() else hooks.fullScreenRect();
```

Move `fullScreenRect()` to a shared location accessible by tiling (it can live in `core.zig`
or `utils.zig`). Currently it's in hooks.zig.

#### `src/window/modules/floating/drag.zig` (2 bar calls)

| Line | Current | New |
|------|---------|-----|
| 67 | `hooks.barWorkAreaRect()` | `bar.workAreaRect()` with guard |

#### `src/window/modules/floating/floating.zig` (1 bar call)

| Line | Current | New |
|------|---------|-----|
| 29 | `hooks.barWorkAreaRect()` | `bar.workAreaRect()` with guard |

#### `src/bar/modules/prompt/prompt.zig` (3 bar calls)

| Line | Current | New |
|------|---------|-----|
| 417 | `hooks.barPresentForPrompt()` | `bar.presentForPrompt()` — prompt imports bar directly |
| 435 | `hooks.barDismissAfterPrompt()` | `bar.dismissAfterPrompt()` |

Prompt is a bar sub-module, so it can import bar directly without build_options guards.

### Step 1.7: Remove bar from `src/core/main.zig`

**File:** `src/core/main.zig`

Remove:
- Lines 59-63: `if (build_options.has_bar) { hooks.registerHooks(@import("bar").hook_map); hooks.registerHooks(@import("carousel").hook_map); hooks.registerHooks(@import("prompt").hook_map); }`
- Lines 78-82: `const bar_enabled = ... if (build_options.has_bar and bar_enabled) { ... bar.init() ... }`
- Lines 83-86: `defer if (build_options.has_bar) { ... bar.deinit() ... }`

Replace with plugin-based lifecycle (see Phase 2 for the full main.zig rewrite).

---

## Phase 2: Migrate the Event Loop and Main

### Step 2.1: Rewrite `src/core/main.zig`

**File:** `src/core/main.zig`

Replace the hook registration and bar init/deinit with plugin lifecycle:

```zig
const plugins = @import("plugins");

pub fn main() !void {
    // ... existing core init (connectToX, atom cache, DPI, input, config, signals) ...

    // Initialize plugins
    plugins.initAll();
    defer plugins.deinitAll();

    // ... rest of startup (grabKeybindings, window.init, xcb_flush) ...

    try events.run();
}
```

Remove all `hooks.registerHooks(...)` calls. Remove all bar-specific init/deinit.
The `plugins.initAll()` call handles all plugin initialization in order.

### Step 2.2: Rewrite `src/core/events.zig` dispatch and event loop

**File:** `src/core/events.zig`

#### 2.2.1: Update the dispatch table

Remove the bar-specific wrapper functions:

- Delete `dispatchBarHandleExpose` (line 56-58)
- Simplify `handlePropertyNotify` to remove bar fan-out (line 61-65)

Replace the dispatch table entries with a comptime plugin-aware dispatch:

For XCB_EXPOSE: Instead of routing through `dispatchBarHandleExpose`, create a
comptime-built dispatch that calls `on_expose` on all plugins:

```zig
fn dispatchExpose(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_expose_event_t, event);
    inline for (plugins.list[0..plugins.count]) |p| {
        if (p.on_expose) |f| f(e);
    }
}
```

For XCB_PROPERTY_NOTIFY: similarly fan out to plugins:

```zig
fn handlePropertyNotify(event: *anyopaque) void {
    const e = eventCast(*xcb.xcb_property_notify_event_t, event);
    inline for (plugins.list[0..plugins.count]) |p| {
        if (p.on_property_notify) |f| f(e);
    }
    window.handlePropertyNotify(e);
}
```

Update the dispatch table:
```zig
table[xcb.XCB_EXPOSE] = asHandler(dispatchExpose);
// table[xcb.XCB_PROPERTY_NOTIFY] uses the updated handlePropertyNotify
```

#### 2.2.2: Update `handleXcbEvents` (post-batch processing)

Replace:
```zig
hooks.tilingRetileIfDirty();
// ...
hooks.barUpdateIfDirty() catch |err| debug.err("Failed to update bar: {}", .{err});
```

With:
```zig
inline for (plugins.list[0..plugins.count]) |p| {
    if (p.post_batch) |f| f() catch |err| debug.err("Plugin post_batch failed: {}", .{err});
}
```

#### 2.2.3: Update `run()` event loop

Replace:
```zig
const blink_ms = hooks.promptBlinkPollTimeoutMs();
```

With:
```zig
var blink_ms: i32 = -1;
inline for (plugins.list[0..plugins.count]) |p| {
    if (p.poll_timeout_ms) |f| {
        const ms = f();
        if (ms >= 0) blink_ms = if (blink_ms < 0) ms else @min(blink_ms, ms);
    }
}
```

Replace the poll wakeup block:
```zig
if (cursor_is_blinking) {
    hooks.promptBlinkTick();
    hooks.barSubmitDraw();
    _ = xcb.xcb_flush(core.getState().conn);
}
```

With:
```zig
if (cursor_is_blinking) {
    inline for (plugins.list[0..plugins.count]) |p| {
        if (p.on_poll_wakeup) |f| f();
    }
    _ = xcb.xcb_flush(core.getState().conn);
}
```

Replace end-of-iteration:
```zig
_ = hooks.barUpdateClock();
```

With:
```zig
inline for (plugins.list[0..plugins.count]) |p| {
    if (p.iteration_end) |f| _ = f();
}
```

#### 2.2.4: Update `handleConfigReload`

Replace:
```zig
hooks.tilingReloadConfig();
hooks.barReload();
```

With:
```zig
inline for (plugins.list[0..plugins.count]) |p| {
    if (p.reload) |f| f();
}
```

#### 2.2.5: Remove `const hooks = @import("hooks");` from events.zig

After all hook.* calls are replaced with plugin fan-outs, events.zig no longer
needs to import hooks. It imports plugins instead.

### Step 2.3: Migrate `src/core/input/input.zig`

**File:** `src/core/input/input.zig`

Input is the second-heaviest consumer of bar hooks (5 calls) and the heaviest
consumer of tiling hooks (19 calls).

#### 2.3.1: Remove bar hook calls

Already covered in Step 1.6 (input.zig bar calls).

#### 2.3.2: Migrate tiling hook calls (19 calls)

All tiling action functions in input.zig call tiling hooks directly. Replace
each with a direct tiling import:

```zig
const tiling = @import("tiling");

fn tilingIncreaseMaster() void { tiling.adjustMasterWidth(0.025); }
fn tilingDecreaseMaster() void { tiling.adjustMasterWidth(-0.025); }
// ... etc for all 19 tiling calls
```

Since tiling is an optional module, wrap in build_options guard:

```zig
const tiling = if (build_options.has_tiling) @import("tiling") else null;

fn tilingIncreaseMaster() void {
    if (tiling) |t| t.adjustMasterWidth(0.025);
}
```

#### 2.3.3: Migrate drag hook calls (5 calls)

```zig
const drag = if (build_options.has_drag) @import("drag") else null;
```

Replace `hooks.dragStart(...)` with `if (drag) |d| d.start(...)`, etc.

#### 2.3.4: Migrate prompt hook calls (2 calls)

The prompt is a bar sub-module. Since input already conditionally imports bar:

```zig
if (bar) |b| {
    if (b.promptHandleKeypress(event, matched)) return;
    // ...
}
```

Or expose prompt functions through bar as public wrappers if preferred.

### Step 2.4: Move `fullScreenRect` out of hooks.zig

The `fullScreenRect()` default is used by tiling and other modules when bar
is absent. Move it to `src/core/core.zig` or `src/core/utils/utils.zig`:

```zig
// In core.zig or utils.zig:
pub fn fullScreenRect() utils.Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = @intCast(core.getState().screen.width_in_pixels),
        .height = @intCast(core.getState().screen.height_in_pixels),
    };
}
```

---

## Phase 3: Migrate the Tiling Subsystem

### Step 3.1: Add `pub const plugin` to `src/window/modules/tiling/tiling.zig`

```zig
pub const plugin = hooks.Plugin{
    .init = init,
    .deinit = deinit,
    .reload = reloadConfig,
    .post_batch = retileIfDirty,
};
```

Tiling only needs lifecycle + post_batch (retileIfDirty). It doesn't handle
XCB events directly.

### Step 3.2: Move shared types into tiling.zig

```zig
pub const RetileOpts = struct {
    for_ws: ?u8 = null,
    defer_win: ?u32 = null,
    focus_override: ?u32 = null,
};

pub const LayoutVariants = struct {
    master: types.MasterVariant = .lifo,
    monocle: types.MonocleVariant = .gapless,
    grid: types.GridVariant = .rigid,
};
```

Remove these from hooks.zig.

### Step 3.3: Ensure all tiling public functions exist

Tiling must export (as `pub` functions):

| Current hooks.zig accessor | New direct call |
|---------------------------|-----------------|
| `tilingAddWindow(u32)` | `tiling.addWindow(u32)` |
| `tilingRemoveWindow(u32)` | `tiling.removeWindow(u32)` |
| `tilingToggleWindowFloat(u32)` | `tiling.toggleWindowFloat(u32)` |
| `tilingGetWindowFilteredIndex(u32)` | `tiling.getWindowFilteredIndex(u32)` |
| `tilingAddWindowAtFilteredIndex(u32, usize)` | `tiling.addWindowAtFilteredIndex(u32, usize)` |
| `tilingSaveWindowGeom(u32, Rect)` | `tiling.saveWindowGeom(u32, Rect)` |
| `tilingGetWindowGeom(u32)` | `tiling.getWindowGeom(u32)` |
| `tilingInvalidateGeomCache(u32)` | `tiling.invalidateGeomCache(u32)` |
| `tilingInvalidateWsGeomBit(u8)` | `tiling.invalidateWsGeomBit(u8)` |
| `tilingMarkDirty()` | `tiling.markDirty()` |
| `tilingRetileCurrentWorkspaceWithOpts(RetileOpts)` | `tiling.retileCurrentWorkspaceWithOpts(RetileOpts)` |
| `tilingRetileCurrentWorkspace()` | `tiling.retileCurrentWorkspace()` |
| `tilingRetileIfDirty()` | `tiling.retileIfDirty()` |
| `tilingRetileInactiveWorkspace(u8)` | `tiling.retileInactiveWorkspace(u8)` |
| `tilingRetileForRestore()` | `tiling.retileForRestore()` |
| `tilingRestoreWorkspaceGeom()` | `tiling.restoreWorkspaceGeom()` |
| `tilingToggleLayout()` | `tiling.toggleLayout()` |
| `tilingToggleLayoutReverse()` | `tiling.toggleLayoutReverse()` |
| `tilingStepLayoutVariant()` | `tiling.stepLayoutVariant()` |
| `tilingStepLayoutVariantReverse()` | `tiling.stepLayoutVariantReverse()` |
| `tilingApplyWorkspaceLayout(*const anyopaque)` | `tiling.applyWorkspaceLayout(*const anyopaque)` |
| `tilingDefaultLayout()` | `tiling.defaultLayout()` |
| `tilingLayoutFromString([]const u8)` | `tiling.layoutFromString([]const u8)` |
| `tilingAdjustMasterCount(i8)` | `tiling.adjustMasterCount(i8)` |
| `tilingAdjustMasterWidth(f32)` | `tiling.adjustMasterWidth(f32)` |
| `tilingAdjustStackBalance(f32)` | `tiling.adjustStackBalance(f32)` |
| `tilingStepScrollView(i32)` | `tiling.stepScrollView(i32)` |
| `tilingSnapScrollToFocused()` | `tiling.snapScrollToFocused()` |
| `tilingSwapWithMaster()` | `tiling.swapWithMaster()` |
| `tilingSwapWindowsById(u32, u32)` | `tiling.swapWindowsById(u32, u32)` |
| `tilingIsWindowTiled(u32)` | `tiling.isWindowTiled(u32)` |
| `tilingIsFloatingLayout()` | `tiling.isFloatingLayout()` |
| `tilingIsWindowActiveTiled(u32)` | `tiling.isWindowActiveTiled(u32)` |
| `tilingUpdateWindowFocus(?u32, ?u32)` | `tiling.updateWindowFocus(?u32, ?u32)` |
| `tilingTakePrevFocusedForScroll()` | `tiling.takePrevFocusedForScroll()` |
| `tilingSendBorderColorIfChanged(u32, u32)` | `tiling.sendBorderColorIfChanged(u32, u32)` |
| `tilingIsEnabled()` | `tiling.isEnabled()` |
| `tilingGetBorderWidth()` | `tiling.getBorderWidth()` |
| `tilingGetCurrentLayout()` | `tiling.getCurrentLayout()` |
| `tilingGetLayoutVariants()` | `tiling.getLayoutVariants()` |
| `tilingGetTiledWindows()` | `tiling.getTiledWindows()` |
| `tilingCacheSizeHints(u32, SizeHints)` | `tiling.cacheSizeHints(u32, SizeHints)` |

Most of these should already be `pub` since they were referenced in the hook_map.
The tiling module already imports bar for `barWorkAreaRect()` etc. — verify these
work with direct imports.

### Step 3.4: Remove tiling's `hook_map`

Delete `pub const hook_map = .{ ... };` (lines 1255-1301).

### Step 3.5: Migrate all tiling consumer call sites

**~100 call sites across ~15 files.** The pattern is the same for every file:

1. Add `const tiling = if (build_options.has_tiling) @import("tiling") else null;`
2. Replace `hooks.tilingXxx(...)` with `if (tiling) |t| t.xxx(...)`
3. For return-value hooks, use `if (tiling) |t| t.xxx() else <default>`

**Files to migrate (with tiling call counts):**

| File | Calls | Notes |
|------|-------|-------|
| `src/core/events.zig` | 2 | Handled by plugin post_batch/reload fan-out (Step 2.2) |
| `src/core/input/input.zig` | 19 | Step 2.3.2 |
| `src/bar/bar.zig` | 8 | Bar imports tiling directly (no guard needed — bar is optional) |
| `src/bar/modules/layout/layout.zig` | 1 | Import tiling directly |
| `src/bar/modules/layout/variants.zig` | 2 | Import tiling directly |
| `src/bar/modules/title/title.zig` | 1 | Import tiling directly |
| `src/window/window.zig` | 18 | Add tiling import with guard |
| `src/window/focus.zig` | 6 | Add tiling import with guard |
| `src/window/tracking.zig` | 1 | Add tiling import with guard |
| `src/window/modules/workspaces.zig` | 21 | Add tiling import with guard |
| `src/window/modules/minimize.zig` | 10 | Add tiling import with guard |
| `src/window/modules/fullscreen.zig` | 7 | Add tiling import with guard |
| `src/window/modules/floating/drag.zig` | 4 | Add tiling import with guard |
| `src/window/modules/floating/floating.zig` | 0 | (no tiling calls) |

**Example migration for window.zig:**

```zig
// Before:
const hooks = @import("hooks");
// ...
hooks.tilingAddWindow(win);
hooks.tilingRetileCurrentWorkspaceWithOpts(.{ .focus_override = win });

// After:
const tiling = if (build_options.has_tiling) @import("tiling") else null;
// ...
if (tiling) |t| t.addWindow(win);
if (tiling) |t| t.retileCurrentWorkspaceWithOpts(.{ .focus_override = win });
```

**Type migration for workspaces.zig:**

```zig
// Before:
const TilingLayout = hooks.TilingLayout;

// After:
const TilingLayout = types.Layout;
```

**Type migration for layout.zig and variants.zig:**

```zig
// Before:
fn getIcon(layout: hooks.TilingLayout) []const u8 {

// After:
const TilingLayout = types.Layout;
fn getIcon(layout: TilingLayout) []const u8 {
```

For `variants.zig` which uses `hooks.TilingLayoutVariants`:
```zig
// Before:
fn getIndicator(layout: hooks.TilingLayout, v: *const hooks.TilingLayoutVariants) []const u8 {

// After:
const tiling = @import("tiling");
fn getIndicator(layout: types.Layout, v: *const tiling.LayoutVariants) []const u8 {
```

---

## Phase 4: Migrate Remaining Subsystems

### Step 4.1: Migrate drag (`src/window/modules/floating/drag.zig`)

**7 hooks, ~11 consumer call sites.**

1. Add plugin struct:
```zig
pub const plugin = hooks.Plugin{
    .init = init,   // if drag has init; check current code
    .deinit = deinit, // if drag has deinit; check current code
};
```

Actually, drag currently has no init/deinit in hook_map. Check what lifecycle it needs.
Looking at the hook_map (line 288-296):
```zig
pub const hook_map = .{
    .drag_start = start,
    .drag_update = update,
    .drag_stop = stop,
    .drag_cancel_for_window = cancelForWindow,
    .drag_is_dragging = isDragging,
    .drag_is_resizing_window = isResizingWindow,
    .drag_get_last_rect = getLastRect,
};
```

Drag has no lifecycle hooks. Its plugin would be:
```zig
pub const plugin = hooks.Plugin{}; // empty — drag has no core integration points
```

Drag is purely called by consumers (input.zig, window.zig, bar.zig). It doesn't
need to participate in the plugin event system. Its functions are just called directly.

2. Ensure all functions are `pub`:
   - `start(u32, u8, i16, i16)` — make pub if not
   - `update(i16, i16)` — make pub if not
   - `stop()` — make pub if not
   - `cancelForWindow(u32)` — make pub if not
   - `isDragging()` — make pub if not
   - `isResizingWindow(u32)` — make pub if not
   - `getLastRect()` — make pub if not

3. Remove `pub const hook_map` from drag.zig.

4. Migrate consumers:
   - `input.zig`: `const drag = if (build_options.has_drag) @import("drag") else null;`
   - `window.zig`: same pattern
   - `bar.zig`: same pattern

### Step 4.2: Migrate floating (`src/window/modules/floating/floating.zig`)

**1 hook, called from tiling.zig.**

1. Add plugin struct:
```zig
pub const plugin = hooks.Plugin{}; // no core integration points
```

2. Ensure `tileWithOffset` is `pub`.

3. Remove `pub const hook_map` from floating.zig.

4. Tiling.zig already imports floating for the layout dispatch:
```zig
// tiling.zig already has:
const floating = @import("floating");
// ...
.floating => hooks.floatingTileWithOffset(ctx, @ptrCast(s), wins, w, h, y),

// Change to:
.floating => floating.tileWithOffset(ctx, @ptrCast(s), wins, w, h, y),
```

### Step 4.3: Migrate config consumer (`src/config/config.zig`)

**3 carousel calls at lines 810-812:**

```zig
// Before:
hooks.carouselSetEnabled(cfg.bar.carousel_enabled);
hooks.carouselSetScrollSpeed(@as(f64, @floatFromInt(cfg.bar.scroll_speed)));
hooks.carouselSetRefreshRateOverride(@as(f64, @floatFromInt(cfg.bar.carousel_refresh_rate)));

// After — carousel is a bar sub-module, import through bar:
if (bar) |b| {
    b.carouselSetEnabled(cfg.bar.carousel_enabled);
    b.carouselSetScrollSpeed(@as(f64, @floatFromInt(cfg.bar.scroll_speed)));
    b.carouselSetRefreshRateOverride(@as(f64, @floatFromInt(cfg.bar.carousel_refresh_rate)));
}
```

Or expose these through bar as public wrappers. See Step 1.5.

---

## Phase 5: Clean Up hooks.zig

### Step 5.1: Final `hooks.zig` contents

After all migrations, `hooks.zig` should contain ONLY:

```zig
//! Plugin interface for optional subsystems.
//!
//! Defines the Plugin struct that optional modules implement to integrate
//! with the core event loop and lifecycle. Each optional subsystem exports
//! a `pub const plugin: hooks.Plugin = .{...};` struct.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");

pub const Plugin = struct {
    // Lifecycle
    init: ?*const fn () anyerror!void = null,
    deinit: ?*const fn () void = null,
    reload: ?*const fn () void = null,

    // XCB event handlers
    on_expose: ?*const fn (*const xcb.xcb_expose_event_t) void = null,
    on_property_notify: ?*const fn (*const xcb.xcb_property_notify_event_t) void = null,
    on_button_press: ?*const fn (*const xcb.xcb_button_press_event_t) void = null,

    // Event-loop integration
    post_batch: ?*const fn () anyerror!void = null,
    iteration_end: ?*const fn () bool = null,

    // Poll integration
    poll_timeout_ms: ?*const fn () i32 = null,
    on_poll_wakeup: ?*const fn () void = null,
};
```

**Estimated size: ~30 lines** (down from 576).

### Step 5.2: Verify zero remaining `hooks.*` calls

After all phases, run:

```bash
grep -rn 'hooks\.' src/ --include='*.zig' | grep -v 'src/core/hooks.zig' | grep -v '@import("hooks")'
```

This should return **zero results**. Every `hooks.*` call should have been replaced with
a direct subsystem import.

The only remaining `@import("hooks")` should be in:
- `src/plugins.zig` (imports hooks for the Plugin type)
- `src/core/main.zig` (if it still imports hooks for any reason — it shouldn't after Phase 2)

### Step 5.3: Verify zero `hook_map` exports

```bash
grep -rn 'hook_map' src/ --include='*.zig'
```

Should return **zero results**.

---

## Phase 6: Verification

### Step 6.1: Build with all subsystems present

```bash
zig build
```

This must compile cleanly. All subsystems are present, all cross-references resolve.

### Step 6.2: Build without bar

```bash
mv src/bar src/bar.bak
zig build
rm -rf src/bar.bak
```

Verify:
- Zero references to bar in compiled output
- All `build_options.has_bar` guards evaluate to false
- The `if (bar) |b| ...` patterns compile to dead code
- The WM runs in tiling-only mode (no bar)

### Step 6.3: Build without tiling

```bash
mv src/window/modules/tiling src/window/modules/tiling.bak
zig build
rm -rf src/window/modules/tiling.bak
```

Verify:
- Zero references to tiling in compiled output
- The WM runs in floating-only mode

### Step 6.4: Build without drag

```bash
mv src/window/modules/floating/drag.zig src/window/modules/floating/drag.zig.bak
zig build
rm -rf src/window/modules/floating/drag.zig.bak
```

### Step 6.5: Build without floating

```bash
mv src/window/modules/floating src/window/modules/floating.bak
zig build
rm -rf src/window/modules/floating.bak
```

### Step 6.6: Build minimal (no optional subsystems)

Remove bar, tiling, floating, and drag simultaneously:

```bash
mv src/bar src/bar.bak
mv src/window/modules/tiling src/window/modules/tiling.bak
mv src/window/modules/floating src/window/modules/floating.bak
zig build
# Restore all
mv src/bar.bak src/bar
mv src/window/modules/tiling.bak src/window/modules/tiling
mv src/window/modules/floating.bak src/window/modules/floating
```

### Step 6.7: Run the linter/typechecker

```bash
zig build check
```

---

## Migration Pattern Reference

For every file that currently does `const hooks = @import("hooks");` and calls
`hooks.subsystemXxx(...)`, apply this transformation:

### For void-returning hooks (no return value):
```zig
// Before:
hooks.barScheduleRedraw();

// After (with build_options guard):
const bar = if (build_options.has_bar) @import("bar") else null;
// ...
if (bar) |b| b.scheduleRedraw();
```

### For bool-returning hooks:
```zig
// Before:
if (hooks.isBarWindow(win)) return;

// After:
if (bar) |b| {
    if (b.isBarWindow(win)) return;
}
// Or: const is_bar = if (bar) |b| b.isBarWindow(win) else false;
//     if (is_bar) return;
```

### For hooks with return values:
```zig
// Before:
const rect = hooks.barWorkAreaRect();

// After:
const rect = if (bar) |b| b.workAreaRect() else fullScreenRect();
```

### For error-returning hooks:
```zig
// Before:
hooks.barUpdateIfDirty() catch |err| debug.err("Failed: {}", .{err});

// After:
if (bar) |b| b.updateIfDirty() catch |err| debug.err("Failed: {}", .{err});
```

### For hooks with safe defaults:
```zig
// Before:
const geom = hooks.tilingGetWindowGeom(win); // returns ?utils.Rect

// After:
const geom = if (tiling) |t| t.getWindowGeom(win) else null;
```

---

## Shared Infrastructure Changes

### `fullScreenRect()` relocation

Currently in `hooks.zig`. Used as default when bar is absent.

Move to `src/core/core.zig`:
```zig
pub fn fullScreenRect() utils.Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = @intCast(getState().screen.width_in_pixels),
        .height = @intCast(getState().screen.height_in_pixels),
    };
}
```

Consumers that need this default: tiling.zig, floating.zig, drag.zig.
They already import `core`, so `core.fullScreenRect()` is accessible.

### Static defaults relocation

Currently in `hooks.zig`:
```zig
var static_drag_last_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
var static_empty_windows: [0]u32 = .{};
```

- `static_drag_last_rect` → move to `drag.zig` (it's drag's fallback)
- `static_empty_windows` → move to `tiling.zig` (it's tiling's fallback)

---

## File Change Summary

| File | Action |
|------|--------|
| `src/core/hooks.zig` | **Rewrite** — Plugin struct only (~30 lines) |
| `src/plugins.zig` | **Create** — comptime plugin list |
| `src/core/main.zig` | **Edit** — replace hook registration with plugin lifecycle |
| `src/core/events.zig` | **Edit** — replace hook calls with plugin fan-outs |
| `src/core/input/input.zig` | **Edit** — replace hook calls with direct imports |
| `src/core/core.zig` | **Edit** — add `fullScreenRect()` |
| `src/config/config.zig` | **Edit** — replace carousel hook calls with bar import |
| `src/bar/bar.zig` | **Edit** — add plugin struct, move BarAction, remove hook_map |
| `src/bar/modules/title/carousel.zig` | **Edit** — remove hook_map |
| `src/bar/modules/prompt/prompt.zig` | **Edit** — remove hook_map, import bar directly |
| `src/bar/modules/layout/layout.zig` | **Edit** — import tiling/types directly |
| `src/bar/modules/layout/variants.zig` | **Edit** — import tiling/types directly |
| `src/bar/modules/title/title.zig` | **Edit** — import tiling directly |
| `src/window/window.zig` | **Edit** — replace hook calls with direct imports |
| `src/window/focus.zig` | **Edit** — replace hook calls with direct imports |
| `src/window/tracking.zig` | **Edit** — replace hook call with direct import |
| `src/window/modules/workspaces.zig` | **Edit** — replace hook calls with direct imports |
| `src/window/modules/minimize.zig` | **Edit** — replace hook calls with direct imports |
| `src/window/modules/fullscreen.zig` | **Edit** — replace hook calls with direct imports |
| `src/window/modules/tiling/tiling.zig` | **Edit** — add plugin, move shared types, remove hook_map |
| `src/window/modules/floating/floating.zig` | **Edit** — add plugin, remove hook_map |
| `src/window/modules/floating/drag.zig` | **Edit** — add plugin, remove hook_map |

**Total: 1 rewrite, 1 new file, 20 edits**

---

## Ordering and Dependencies

The phases must be executed in order because later phases depend on earlier ones:

1. **Phase 0** (infrastructure) — creates the Plugin type and plugins.zig that everything else uses
2. **Phase 1** (bar) — establishes the migration pattern; bar is the most interconnected
3. **Phase 2** (event loop) — depends on bar being migrated (the event loop's bar calls go through plugins)
4. **Phase 3** (tiling) — depends on Phase 2 (event loop uses plugin fan-outs for tiling)
5. **Phase 4** (remaining) — depends on Phases 1-3 for the patterns and shared infrastructure
6. **Phase 5** (cleanup) — depends on all migrations being complete
7. **Phase 6** (verification) — depends on everything

Within each phase, steps can be done in order as listed.

**Estimated total effort:** This is a significant refactor touching 22 files. The mechanical
changes (replacing `hooks.xxx()` with `if (mod) |m| m.xxx()`) are repetitive but each must
be done carefully to get the build_options guards right. The architectural changes (Plugin
struct, plugins.zig, event loop rewrite) are the creative core.
