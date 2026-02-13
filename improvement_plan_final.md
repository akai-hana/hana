# Window Manager Codebase — Complete Improvement Plan

This document consolidates all findings from three full passes over the entire codebase.
Issues are organized into three batches by priority.

---

## Batch 1 — Correctness & Critical Bugs

---

### 1.1 Double-free in config reload (`main.zig`, lines 212–220)

**Severity: High — undefined behaviour on every failed reload.**

```zig
errdefer new_config.deinit(wm.allocator);          // (A) fires on any error path
if (new_config.tiling.master_count == 0) {
    new_config.deinit(wm.allocator);               // (B) explicit call
    return error.InvalidConfig;                    // (A) then fires again
}
```

Fix: remove the explicit `deinit` call on line 214 and rely solely on `errdefer`.

---

### 1.2 Window reordering bug — `swapRemove` silently changes master/stack assignment (`tracking.zig`, `tiling.zig`)

**Severity: High — last window silently displaces closed window in tiling order.**

`tiling.removeWindow` calls `s.windows.remove(win)` which uses the unordered
`swapRemove` variant. When a window closes, the last window in the list is moved into
the vacated slot. The master/stack boundary is purely positional, so a window that was
the last slave suddenly becomes, for example, the second master — without any user
action.

Fix: change all tiling removal sites to `s.windows.removeOrdered(win)`.

---

### 1.3 Redundant geometry queries in `enterFullscreen` (`fullscreen.zig`, lines 38–51)

**Severity: Medium — two blocking X11 roundtrips for the same window.**

```zig
const geom = utils.getGeometry(wm.conn, win) orelse return;   // roundtrip 1
// ...
const geom_cookie = xcb.xcb_get_geometry(wm.conn, win);
const geom_reply  = xcb.xcb_get_geometry_reply(...);          // roundtrip 2 (border_width)
```

`xcb_get_geometry_reply` already contains `border_width`. Use it for all fields and
drop the `utils.getGeometry` call entirely.

---

### 1.4 Unsafe `ArrayList` manipulation in `addFront` large-mode path (`tracking.zig`, lines 111–118)

**Severity: Medium — manually increments `items.len` after `ensureUnusedCapacity`,
bypassing ArrayList invariant checks.**

```zig
l.list.items.len += 1;   // fragile: depends on internal ArrayList layout
```

Replace with `std.mem.copyBackwards` or insert via `l.list.insert(0, win)` which is
safe and expresses intent.

---

### 1.5 Floating mode positions every window at the same coordinate (`workspaces.zig`, lines 264–281)

**Severity: High — WM is unusable in floating mode; all windows overlap exactly.**

When tiling is disabled, `executeSwitch` iterates the new workspace's windows and
positions them all at `(screen_w/4, screen_h/4)`. Every window stacks on top of every
other window.

Fix: track `saved_x`/`saved_y` per window (analogous to how fullscreen saves geometry),
or simply skip repositioning floating windows and let them retain their last position
(which is what most floating WMs do).

---

### 1.6 Lossy DPI cache signature — bit-packing overflows for normal monitor sizes (`dpi.zig`, lines 165–169)

**Severity: Medium — cache produces wrong keys for monitors wider than 255 mm.**

```zig
const sig = (@as(u64, screen.width_in_pixels)  << 32) |
            (@as(u64, screen.height_in_pixels) << 16) |
            (@as(u64, screen.width_in_millimeters) << 8) |   // ← only 8 bits
            screen.height_in_millimeters;                     // ← 0 bits
```

`width_in_millimeters` is a `u16`; shifting it by only 8 bits causes it to overlap
`height_in_millimeters`. A 340 mm wide monitor (common 27" display) corrupts the key.

Fix: use non-overlapping 16-bit boundaries:
```zig
const sig = (@as(u64, screen.width_in_pixels)       << 48) |
            (@as(u64, screen.height_in_pixels)      << 32) |
            (@as(u64, screen.width_in_millimeters)  << 16) |
            (@as(u64, screen.height_in_millimeters));
```

---

### 1.7 Wasted pointer query in `handleDestroyNotify` (`window.zig`, lines 302–305)

**Severity: Low — extra X11 roundtrip discarded immediately.**

```zig
_ = getCachedPointer(wm);      // result unused
focusWindowUnderPointer(wm);   // always queries fresh
```

`focusWindowUnderPointer` unconditionally calls `xcb_query_pointer` and updates
the cache itself. The `getCachedPointer` call on the line before it is fully redundant.
Remove it.

---

### 1.8 `handleDestroyNotify`, `setupTiling`, and `handleConfigureRequest` gate tiling on `wm.config.tiling.enabled` instead of `State.enabled` (`window.zig`, lines 153, 207–208, 278–293)

**Severity: High — runtime tiling toggle desynchronizes the window list.**

`toggleTiling` flips `State.enabled`, not `wm.config.tiling.enabled`. After the user
toggles tiling off at runtime:
- `handleDestroyNotify` still calls `tiling.removeWindow` (line 279)
- `setupTiling` skips `tiling.addWindow` (line 153)
- The tiling window list diverges from reality; re-enabling tiling produces wrong layouts

All three sites must read from `tiling.getState()?.enabled`, not the config flag.
`executeSwitch` already has the correct pattern and comment; apply it consistently.

---

### 1.9 `focusSecondLast` unconditionally dereferences `current_focused.?` without a null guard (`tiling.zig`, line 743)

**Severity: High — guaranteed panic when invoked with no focused window.**

```zig
const current_focused = wm.focused_window;   // ?u32
// ...
if (hist_win == current_focused.?) {          // panics if null
```

The `windows.len < 2` guard at line 737 does not protect against a null focus. If the
user presses the focusSecondLast keybinding on an empty workspace, the WM crashes.

Fix: add `const current_focused = wm.focused_window orelse return;` at line 734.

---

### 1.10 `tiling.init` leaks `tracking` and `geometry_cache` on `StateManager.init` failure (`tiling.zig`, lines 280–299)

**Severity: Medium — memory leak when init is called twice (e.g. hot-reload path).**

```zig
StateManager.init(wm.allocator, .{
    .windows        = tracking.init(wm.allocator),     // constructed before catch
    .geometry_cache = std.AutoHashMap(...).init(...),  // constructed before catch
    ...
}) catch |err| { return; };                            // both sub-objects leaked
```

Fix: construct sub-objects separately with `errdefer` before passing them in.

---

### 1.11 `handleEnterNotify` calls `tiling.updateWindowFocus` after `focus.setFocus`, which already calls it (`window.zig`, lines 246–247)

**Severity: Medium — 4 redundant XCB calls and an extra flush on every mouse-over.**

`setFocusImpl` (focus.zig line 60) already calls `tiling.updateWindowFocusFast`.
`handleEnterNotify` then calls the non-fast variant (which re-sends both border
attributes and issues a flush) on top of the completed focus change.

Remove line 247 (`tiling.updateWindowFocus(wm, old_focus, win)`).

---

### 1.12 `grabKeybindings` diagnostic path re-grabs all keybindings, including already-succeeded ones (`main.zig`, lines 185–198)

**Severity: Low — unnecessary duplicate grabs sent to X11 on every partial failure.**

When any grab fails the diagnostic loop unconditionally retries every keybinding.
Successful grabs are grabbed a second time. X11 ignores duplicate grabs, so this
does not corrupt state, but it floods the X11 connection with O(n × lock_modifiers)
extra requests and produces imprecise diagnostic output.

Fix: track per-keybinding pass/fail during the initial cookie batch check and only
log failures, without re-attempting any grabs.

---

### 1.13 `drawing.deinitFontCache` is never called, leaking the font name conversion cache (`drawing.zig`, `bar.zig`)

**Severity: Low — memory leak at shutdown.**

`drawing.deinitFontCache(allocator)` frees the module-level `font_conversion_cache`
and all its heap-allocated converted Pango font name strings. It is never called from
`bar.deinit` or `main`.

Fix: call `drawing.deinitFontCache(allocator)` from `bar.deinit`.

---

### 1.14 `drag.startDrag` uses `wm.config.tiling.enabled` instead of `State.enabled` (`drag.zig`, line 35)

**Severity: Medium — dragging a window does not remove it from tiling after runtime toggle.**

Same class as 1.8. After the user toggles tiling off at runtime, dragging a tiled window
still calls `tiling.removeWindow` (which is fine), but if tiling is toggled back on the
window may be permanently absent from the tiling list if the drag happened while state
was inconsistent.

Fix: read from `tiling.getState()?.enabled`.

---

### 1.15 `input.handleButtonPress` calls `tiling.updateWindowFocus` after `focus.setFocus` (`input.zig`, line 146)

**Severity: Medium — same double-border-update and redundant flush as 1.11.**

```zig
focus.setFocus(wm, event.child, .mouse_click);         // calls updateWindowFocusFast internally
tiling.updateWindowFocus(wm, null, event.child);       // does it again + flushes
```

Remove line 146.

---

### 1.16 `tiling.switchFocus` sets `wm.focused_window` redundantly and triggers a second `updateWindowFocus` after `focus.setFocus` already handled both (`tiling.zig`, lines 665–668)

**Severity: Low — 2 redundant XCB calls and 1 redundant flush per tiling focus switch.**

```zig
focus.setFocus(wm, to, .tiling_operation);   // sets wm.focused_window, calls updateWindowFocusFast, flushes
wm.focused_window = to;                      // already set above
s.updateFocusHistory(to);
updateWindowFocus(wm, from, to);             // calls updateWindowFocusFast again + xcb_flush again
```

Fix: remove `wm.focused_window = to` (it is set inside `setFocusImpl`) and replace
`updateWindowFocus` with `s.updateFocusHistory(to)` only, since `setFocus` already
updated borders and flushed.

---

### 1.17 `setWindowProperties` silently discards two of its own parameters (`bar.zig`, lines 177–179)

**Severity: Low — dead parameters make the API misleading.**

```zig
fn setWindowProperties(wm: ..., window: u32, height: u16, want_transparency: bool, alpha: u16) !void {
    _ = want_transparency;   // immediately discarded
    _ = alpha;               // immediately discarded
```

These parameters are passed at every call site but have no effect. Either remove them
from the signature, or implement the functionality they suggest.

---

### 1.18 `setupRootCursor` leaks an X11 cursor resource (`main.zig`, lines 76–82)

**Severity: Low — X11 cursor resource is never freed for the WM's lifetime.**

```zig
const cursor = xcb.xcb_generate_id(conn);
_ = xcb.xcb_create_glyph_cursor(conn, cursor, ...);
_ = xcb.xcb_change_window_attributes(conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor});
// xcb_free_cursor never called
```

Add `_ = xcb.xcb_free_cursor(conn, cursor)` after the `xcb_change_window_attributes`
call. The server retains the cursor for the window even after the client-side ID is
freed.

---

### 1.19 `XCB_UNMAP_NOTIFY` is absent from the dispatch table — windows that self-unmap are silently ignored (`events.zig`)

**Severity: Medium — applications that unmap their own window (e.g. minimise) leave tiling state stale.**

Some applications (Java/Swing apps, certain dialog libraries) call `XUnmapWindow` on
themselves without destroying the window. The WM currently has no handler for
`XCB_UNMAP_NOTIFY`. The window remains in the tiling and workspace lists, occupying a
tile slot with nothing drawn in it.

Fix: add an `XCB_UNMAP_NOTIFY` handler that removes the window from tiling and
workspace tracking (without calling `wm.removeWindow`, since the window still exists
and should be re-added when it maps again via a future `MapRequest`).

---

### 1.20 `tracking` struct type shares its name with the module (`tracking.zig`, line 25)

**Severity: Low — `tracking.tracking` is needed to reference the type from outside.**

```zig
pub const tracking = struct { ... };   // type and module both named "tracking"
```

Callers must write `tracking.tracking` or import with an alias. Rename to
`pub const WindowList = struct { ... }` (or `WindowTracker`) per Zig's PascalCase
convention for types.

---

### 1.21 `xcb_create_gc` result is discarded; the GC is unconditionally freed even if creation failed (`drawing.zig`, lines 144–145)

**Severity: Low — spurious `xcb_free_gc` on GC ID 0 if creation fails.**

```zig
dc.gc = defs.xcb.xcb_generate_id(conn);
_ = defs.xcb.xcb_create_gc(conn, dc.gc, drawable, 0, null);   // error ignored
```

If `xcb_create_gc` fails (e.g. invalid drawable), `dc.gc` holds an ID for which no
server-side GC was created. `deinit` then calls `xcb_free_gc(conn, dc.gc)`, which sends
a request to free a non-existent GC — the server returns an error that is silently
ignored but wastes a roundtrip.

Fix: use `xcb_create_gc_checked` + `xcb_request_check`, and on failure set `dc.gc = 0`
and guard the `free_gc` call.

---

## Batch 2 — Performance Optimizations

---

### 2.1 `supportsWMTakeFocus` is an uncached synchronous X11 roundtrip on every focus change (`utils.zig`, `focus.zig`)

**Impact: High — ~50 µs per focus event.**

The `WM_PROTOCOLS` property is immutable after window creation, so the result only
needs to be queried once per window. Add a `std.AutoHashMap(u32, bool)` cache (keyed
by window ID, valued by whether WM_TAKE_FOCUS is supported) and populate it on
`MapRequest`. Clear the entry on `DestroyNotify`.

---

### 2.2 `drawClockOnly` recalculates all segment widths from scratch every second (`bar.zig`, lines 516–533)

**Impact: Low-Medium — unnecessary work on a 1 Hz update path.**

The clock position only changes when the bar layout changes, which is already signalled
by `markDirty()`. Add a `cached_clock_x: ?u16` field to `State`, populate it on each
full `draw()`, and use it in `drawClockOnly` directly — skipping the full right-to-left
segment width scan on clock-only redraws.

---

### 2.3 `calculateBarHeight` creates a temporary X11 window and `DrawContext` solely to measure font metrics (`bar.zig`, lines 205–228)

**Impact: Low-Medium — 2 extra X11 roundtrips + full Cairo/Pango init cycle at startup.**

Font metrics are accessible from the real bar's `DrawContext` after it is created.
Restructure `init()` to create the actual bar window first (with a provisional height),
then load fonts on the real `DrawContext`, measure metrics, and resize the window if
needed with a single `xcb_configure_window`. This eliminates the temporary window
entirely.

---

### 2.4 `updateWindowBorders` calls `xcb_flush` redundantly (`tiling.zig`, lines 437–450)

**Impact: Low — one extra flush per retile cycle.**

`updateWindowBorders` flushes at line 449. `retile` calls `updateWindowBorders`, then
`retileIfDirty` returns to the main loop which calls `utils.flush` again. Two flushes
per retile. Remove the flush from `updateWindowBorders` and let the main loop handle it.

---

### 2.5 `moveWindowToIndex` is O(n²): removes all windows and re-adds them (`tiling.zig`, lines 627–648)

**Impact: Medium — quadratic cost for swap-with-master with large window counts;
uses a fixed 256-entry stack buffer.**

```zig
for (items) |win| _ = s.windows.remove(win);         // O(n) × n removes
for (temp[0..len]) |win| s.windows.add(win) catch …;  // O(n) × n adds
```

Expose a `tracking.moveElement(from_idx, to_idx)` that performs an in-place
`std.mem.rotate` on the backing slice. This is O(n) with no allocations and no stack
buffer limit.

---

### 2.6 Blocking geometry queries inside a server grab (`workspaces.zig`, lines 264–281)

**Impact: Medium — compositor stall during workspace switch.**

`xcb_get_geometry_reply` is called per-window while `xcb_grab_server` is active. Any
window that is slow to respond stalls the entire server. Pre-batch the geometry cookies
before `xcb_grab_server`, collect all replies, then enter the grab and use the
pre-fetched data.

---

### 2.7 `handleButtonPress` workspace click calculation assumes workspaces start at x=0 (`bar.zig`, line 568)

**Impact: Low — incorrect click target if any left-side bar segments exist.**

```zig
const clicked_ws = @divFloor(event.event_x, scaled_ws_width);
```

This is correct only if the workspace segment starts at pixel 0. If a layout places a
left-side status or title segment before the workspace segment, clicks are mapped to the
wrong workspace. Cache `workspace_segment_x_offset` during `draw()` and subtract it
from `event.event_x` here.

---

### 2.8 `sizeFont` always heap-allocates even when the stack buffer path succeeds (`bar.zig`, lines 140–150)

**Impact: Low — unnecessary allocator call for every font load.**

```zig
const result = std.fmt.bufPrint(&buf, ...) catch { return allocPrint(...); };
return try alloc.dupe(u8, result);   // ← always heap-allocates
```

The successful stack-buffer path still copies the result to the heap via `dupe`. The
caller always frees the returned slice, so it must be heap-owned — but consider whether
the API can return a stack slice for the common case (e.g. caller can own a fixed buffer
and the function writes into it).

---

### 2.9 `tiling.addWindow` issues 3 separate XCB calls where 2 would suffice (`tiling.zig`, lines 335–341)

**Impact: Low — one extra XCB call per managed window at map time.**

Both `xcb_change_window_attributes` calls can be merged:

```zig
const attr_values = [_]u32{ WINDOW_EVENT_MASK, border_color };
_ = xcb.xcb_change_window_attributes(wm.conn, window_id,
    xcb.XCB_CW_EVENT_MASK | xcb.XCB_CW_BORDER_PIXEL, &attr_values);
_ = xcb.xcb_configure_window(wm.conn, window_id, XCB_CONFIG_WINDOW_BORDER_WIDTH, &s.border_width);
```

---

### 2.10 `FocusRing.push` scans the ring twice: once for the head check, once for duplicate removal

**Impact: Low-Medium — double scan on every focus change.**

Combine into a single linear scan that simultaneously checks for the head (early return)
and finds the existing position to remove.

---

### 2.11 `updateClockIfNeeded` issues a `clock_gettime` syscall on every X11 event batch (`bar.zig`, lines 125–137)

**Impact: Low-Medium — unnecessary syscall in the hot event path.**

`updateClockIfNeeded` is called from `updateIfDirty` on every event cycle. The timerfd
already fires exactly once per second; the syscall here is redundant. Remove
`updateClockIfNeeded` from `updateIfDirty` and rely entirely on the timer-fd path
(`checkClockUpdate`). The only scenario where this matters (missed timer tick) cannot
occur since the timer fd stays readable until drained.

---

### 2.12 `DrawBatch` is fully implemented but never used (`drawing.zig`, lines 330–379)

**Impact: Positive if used, wasted code otherwise.**

`DrawBatch` batches rectangle draws into a single `xcb_poly_fill_rectangle` — exactly
the optimization needed for bar segment backgrounds. Wire it into the segment drawing
path or remove the dead code.

---

### 2.13 `isOnCurrentWorkspace` uses O(n) linear scan when O(1) lookup is available (`workspaces.zig`, lines 313–316)

**Impact: Low-Medium — this is on the hot retile path.**

```zig
return s.workspaces[s.current].contains(win);   // O(n) scan
```

`window_to_workspace` is a `HashMap(u32, u8)` that maps directly to the workspace
index. Replace with:

```zig
const ws_idx = s.window_to_workspace.get(win) orelse return false;
return ws_idx == s.current;   // O(1)
```

---

### 2.14 Duplicate color conversion caches: `DrawContext.color_cache` and `CacheManager.colors` (`drawing.zig`, `cache.zig`)

**Impact: Low — wasted memory; two caches can diverge.**

Both store `u32 → {r, g, b}` with identical conversion logic. Eliminate one and route
all callers through the survivor.

---

### 2.15 `retile` invalidates the geometry cache for every workspace window on every retile, negating the cache's purpose (`tiling.zig`, lines 406–409)

**Impact: Low-Medium — O(n) cache invalidation before every layout pass.**

The cache is meant to avoid redundant X11 geometry queries. But the code clears it
for all windows at the top of `retile`, which means every subsequent `getOrQueryGeometry`
call re-queries X11 anyway. Either:
- Populate the cache *after* positioning windows (so it stores the newly-assigned geometry), or
- Only invalidate windows whose geometry is actually being changed (i.e., those in the workspace being retiled), or
- Remove the pre-retile invalidation loop entirely if it serves no purpose.

---

### 2.16 `xkbcommon.retryKeymap` validates keymaps with hardcoded keycodes that are layout-dependent (`xkbcommon.zig`, line 151)

**Impact: Low — may falsely reject valid keymaps on non-standard hardware.**

```zig
for ([_]u8{ 36, 65, 38 }) |keycode| {   // Enter, Space, 'A' on US QWERTY
```

Keycodes 36, 65, and 38 are standard on most setups, but X server configurations exist
where these are remapped. A safer validation is to check whether the total number of
keysyms in the map is above a minimum threshold (e.g. 20+), rather than relying on
specific keycodes.

---

## Batch 3 — Design & Maintainability

---

### 3.1 Replace dual-optional `small`/`large` fields with a tagged union (`tracking.zig`)

**Severity: Medium — invalid state (both null) is currently representable.**

```zig
small: ?struct { ... },
large: ?struct { ... },
```

A tagged union makes invalid state unrepresentable:
```zig
mode: union(enum) {
    small: struct { items: [16]u32, len: u8 },
    large: struct { list: ArrayListUnmanaged(u32), set: AutoHashMap(u32, void) },
},
```

---

### 3.2 `drag.flushPendingUpdate` is a no-op with no callers (`drag.zig`, lines 74–77)

Remove the function. Leaving empty exported functions creates false impressions about
the code path.

---

### 3.3 `utils.configureWindow` and `layouts.configure` are identical (`utils.zig`, `layouts.zig`)

Two functions that call `xcb_configure_window` with the same four-field mask and the
same value array. Keep `utils.configureWindow`; have `layouts.configure` call it;
give `layouts.configureSafe` the validation wrapper as it does today.

---

### 3.4 `getMilliTimestamp` accesses unstable internal fields of `std.time.Instant` (`window.zig`, lines 91–107)

`instant.timestamp.sec` and `instant.timestamp.nsec` are implementation details.
Use `std.time.milliTimestamp()` (returns `i64` milliseconds since epoch, stable public API)
and cache the value in WM state as a plain `i64`.

---

### 3.5 `tracking.remove` (unordered) vs `tracking.removeOrdered` naming is confusing (`tracking.zig`)

The public API should default to the safe, ordered variant. Rename:
- `remove` → `removeUnordered` (explicit fast path, caller acknowledges ordering loss)
- `removeOrdered` → `remove` (default safe path)

---

### 3.6 `parseLayout` uses chained `std.mem.eql` instead of `std.meta.stringToEnum` (`tiling.zig`, lines 309–319)

```zig
// current
if (std.mem.eql(u8, layout_str, "monocle")) return .monocle;
// ...

// improved
return std.meta.stringToEnum(Layout, layout_str) orelse .master;
```

The enum variant approach is compile-time exhaustive and won't silently miss a new
layout added in the future.

---

### 3.7 `focused_window` is set before the server grab in `executeSwitch` (`workspaces.zig`, line 236)

Between the assignment and `xcb_grab_server`, X11 events can fire and observe an
inconsistent state (focused_window points to a window that has not yet been positioned).
Move the assignment inside the grab block.

---

### 3.8 `has_clock_segment` is detected at bar init but never refreshed on config reload (`bar.zig`, lines 110–117)

If the user adds or removes a clock segment in the config and triggers a reload, the
stale `has_clock_segment` value causes the timer to be enabled or disabled incorrectly.
`handleConfigReload` should call `bar.reloadConfig(wm)` which re-runs
`State.detectClockSegment` and updates the timer state accordingly.

---

### 3.9 `module.init` swallows `AlreadyInitialized` errors silently (`module.zig`)

`tiling.init` and `workspaces.init` call `StateManager.init` and log an error if it
fails, but return normally. If init fails mid-startup, every subsequent `StateManager.get`
returns null and the subsystem is silently absent. Either:
- Change the init functions to return `!void` and propagate the error, or
- Add a `reinit` path for hot-reload that calls `deinit` then `init`.

---

### 3.10 Style inconsistency — river/dwm alignment style mixed with `zig fmt` style

The codebase mixes aligned declarations (DWM-style, e.g. `const a    = …`) with
standard `zig fmt` output. `zig fmt` should be the single source of truth, applied
uniformly. River-style manual alignment becomes stale on refactors and is overridden
whenever `zig fmt` is run as part of CI.

---

### 3.11 `RGBColor` is defined identically in both `drawing.zig` and `cache.zig` (`drawing.zig` line 39, `cache.zig` line 9)

```zig
const RGBColor = struct { r: f64, g: f64, b: f64 };
```

They are different types at the Zig type system level, preventing code that operates on
one from accepting the other. Define `pub const RGBColor` in one canonical location
(e.g. `drawing.zig`) and import it in `cache.zig`.

---

### 3.12 `addWindowToCurrentWorkspace` appears to be dead code (`workspaces.zig`, line 112)

All call sites use `workspaces.moveWindowTo(wm, win, workspace_index)` instead.
Either remove it, or document when it should be preferred and use it at the appropriate
call sites.

---

### 3.13 `tiling.onFocusChange` is exported but never called (`tiling.zig`, line 476)

Its logic (`updateFocusHistory` + `updateWindowFocus`) is duplicated inline at every
call site. Remove it or use it consistently to consolidate focus-change sequencing.

---

### 3.14 `grabButtons` uses `XCB_GRAB_MODE_SYNC` for the keyboard mode (`window.zig`, line 66)

**Severity: Medium — can freeze keyboard input if the WM crashes or misses an `allow_events` call.**

```zig
_ = xcb.xcb_grab_button(
    wm.conn, 0, win, ...,
    xcb.XCB_GRAB_MODE_SYNC,   // pointer: intentional, needed for click replay
    xcb.XCB_GRAB_MODE_SYNC,   // keyboard: NOT needed and dangerous
    ...
);
```

Change keyboard mode to `XCB_GRAB_MODE_ASYNC`. Only pointer sync is needed for
`xcb_allow_events` replay.

---

### 3.15 `drawText` and `drawTextEllipsis` use different baseline computations, causing vertical text misalignment (`drawing.zig`, lines 256–260, 271–275)

`drawText` uses `pango_layout_get_baseline()` (accurate, per-text).
`drawTextEllipsis` uses `getMetrics().ascent` (font-level, may differ for mixed scripts
or fallback fonts).

Standardize both on `pango_layout_get_baseline()` for consistent vertical positioning.

---

### 3.16 `cleanupStaleGeometryCache` allocates a temporary `ArrayListUnmanaged` when `workspace_windows_buffer` already exists for this purpose (`tiling.zig`, lines 200–201)

Replace the per-call allocation with a fixed-size stack buffer (the geometry cache for
32+ entries is already unusual):

```zig
var to_remove: [64]u32 = undefined;
var count: usize = 0;
```

---

### 3.17 `workspaces.removeWindow` uses unordered swap-remove on the workspace's `tracking` (`workspaces.zig`, line 131)

Same concern as 1.2 for the tiling window list. Workspace window order affects
iteration order during workspace switches and label rendering. Use `removeOrdered`.

---

### 3.18 `getWMClass` allocates two separate heap strings where one allocation would suffice (`utils.zig`, lines 313–342)

Instance and class are adjacent in the X11 property data, separated by a null byte.
A single allocation of `instance_len + class_len` bytes with two slices pointing into
it halves allocator overhead. `deinit` would free the single buffer via
`allocator.free(self.instance.ptr[0..self.instance.len + self.class.len])`.
This is called on every `MapRequest` when workspace rules are configured.

---

### 3.19 `geometry_cache` comment acknowledges it never shrinks, but the shrink code is a no-op comment (`tiling.zig`, lines 218–229)

The comment says "the allocator will handle fragmentation" without any action. After
a burst of windows, the hash table capacity stays elevated indefinitely. Implement the
acknowledged shrink path: when capacity exceeds 4× active window count and exceeds 32,
clear-and-rebuild the map with only the live entries.

---

### 3.20 `cache.CacheManager.computeConfigHash` omits key fields from the config hash (`cache.zig`, lines 150–159)

```zig
h.update(std.mem.asBytes(&config.bg));
h.update(std.mem.asBytes(&config.fg));
h.update(std.mem.asBytes(&config.font_size));
h.update(std.mem.asBytes(&config.padding));
h.update(std.mem.asBytes(&config.segment_spacing));
// "Add more fields as needed" — but workspace_icons and font names are missing
```

If a user changes workspace icon labels or font names without changing any of the
hashed fields, the cache is not invalidated. Add `config.fonts`, `config.workspace_icons`,
and `config.layout` to the hash input.

---

### 3.21 `bar.State.init` appends `"hana"` as the initial status text — likely a debug leftover (`bar.zig`, line 90)

```zig
try s.status_text.appendSlice(allocator, "hana");
```

This string will be displayed in the status bar segment until the first
`XCB_ATOM_WM_NAME` property notify event updates it. Replace with an empty string or
a meaningful placeholder like the WM name.

---

### 3.22 `drawing.loadFonts` silently discards all fonts after the first one (`drawing.zig`, lines 182–192)

```zig
if (font_names.len > 0) {
    try self.loadFont(font_names[0]);    // only first font loaded
    if (font_names.len > 1) {
        debug.info("More than one font detected ...", .{});  // rest silently ignored
    }
}
```

Pango supports a comma-separated font fallback list natively via its font description
string. Compose all font names into a single fallback string before passing to
`pango_font_description_from_string` so that multi-font configs work as intended.

---

### 3.23 `dpi_cache` is a module-level global with no reset path (`dpi.zig`, lines 22–25)

If a monitor hotplug event occurs (screen geometry changes), `dpi.detect` returns the
stale cached result indefinitely because the screen signature only changes if pixel or
millimetre dimensions change, and those fields are read once at startup. Expose a
`dpi.invalidateCache()` function and call it from the `RRScreenChangeNotify` event
handler (or add that handler if it does not exist).

---

### 3.24 `WorkspaceLabelCache` is hardcoded to 20 workspaces while the actual workspace count is dynamic (`cache.zig`, line 30)

```zig
label_widths: [20]u16 = [_]u16{0} ** 20,
```

If the user configures more than 20 workspaces, `getWorkspaceLabelWidth` silently
returns 0 for any index ≥ 20. Replace the fixed array with an `ArrayListUnmanaged(u16)`
sized to the actual workspace count, or use the `MAX_WORKSPACES` constant if one exists.

---

### 3.25 `tracking.large.list` is typed as `std.ArrayList(u32)` but used as `std.ArrayListUnmanaged(u32)` (`tracking.zig`, lines 33, 84, 109, 194)

Methods are called with an explicit allocator argument (`l.list.append(self.allocator, win)`),
and the initializer is `.empty` — both are `ArrayListUnmanaged` semantics. Using
`std.ArrayList` (which stores its own allocator) with explicit allocator arguments will
compile only in Zig versions where the managed and unmanaged APIs overlap. Change the
type annotation to `std.ArrayListUnmanaged(u32)` for correctness and clarity.

---

## Summary Table

| # | File(s) | Description | Severity | Batch |
|---|---------|-------------|----------|-------|
| 1.1 | `main.zig` | Double-free in config reload | **High** | 1 |
| 1.2 | `tracking.zig`, `tiling.zig` | swapRemove corrupts tiling order | **High** | 1 |
| 1.3 | `fullscreen.zig` | Redundant geometry queries | Medium | 1 |
| 1.4 | `tracking.zig` | Unsafe addFront via raw len increment | Medium | 1 |
| 1.5 | `workspaces.zig` | All floating windows overlap | **High** | 1 |
| 1.6 | `dpi.zig` | Lossy DPI cache signature | Medium | 1 |
| 1.7 | `window.zig` | Wasted getCachedPointer call | Low | 1 |
| 1.8 | `window.zig` | config.enabled vs State.enabled in destroy | **High** | 1 |
| 1.9 | `tiling.zig` | Null deref in focusSecondLast | **High** | 1 |
| 1.10 | `tiling.zig` | Sub-objects leaked on init failure | Medium | 1 |
| 1.11 | `window.zig` | Double border update in handleEnterNotify | Medium | 1 |
| 1.12 | `main.zig` | Diagnostic re-grabs succeed keys | Low | 1 |
| 1.13 | `drawing.zig`, `bar.zig` | Font cache never freed | Low | 1 |
| 1.14 | `drag.zig` | config.enabled vs State.enabled in drag | Medium | 1 |
| 1.15 | `input.zig` | Double border update in handleButtonPress | Medium | 1 |
| 1.16 | `tiling.zig` | switchFocus redundant state sets | Low | 1 |
| 1.17 | `bar.zig` | Dead parameters in setWindowProperties | Low | 1 |
| 1.18 | `main.zig` | Cursor resource never freed | Low | 1 |
| 1.19 | `events.zig` | No XCB_UNMAP_NOTIFY handler | Medium | 1 |
| 1.20 | `tracking.zig` | Type/module name collision | Low | 1 |
| 1.21 | `drawing.zig` | xcb_create_gc result discarded | Low | 1 |
| 2.1 | `utils.zig`, `focus.zig` | WM_TAKE_FOCUS uncached (~50 µs/focus) | **High** | 2 |
| 2.2 | `bar.zig` | Clock position recalculated every second | Low-Med | 2 |
| 2.3 | `bar.zig` | Temp window for font metrics at startup | Low-Med | 2 |
| 2.4 | `tiling.zig` | Redundant flush in updateWindowBorders | Low | 2 |
| 2.5 | `tiling.zig` | O(n²) moveWindowToIndex | Medium | 2 |
| 2.6 | `workspaces.zig` | Geometry queries inside server grab | Medium | 2 |
| 2.7 | `bar.zig` | Workspace click offset ignores left segments | Low | 2 |
| 2.8 | `bar.zig` | sizeFont always heap-allocates | Low | 2 |
| 2.9 | `tiling.zig` | 3 XCB calls → 2 in addWindow | Low | 2 |
| 2.10 | `tiling.zig` | FocusRing.push double-scans ring | Low-Med | 2 |
| 2.11 | `bar.zig` | clock_gettime syscall on every event | Low-Med | 2 |
| 2.12 | `drawing.zig` | DrawBatch implemented but unused | Low | 2 |
| 2.13 | `workspaces.zig` | isOnCurrentWorkspace O(n) → O(1) | Low-Med | 2 |
| 2.14 | `drawing.zig`, `cache.zig` | Duplicate color caches | Low | 2 |
| 2.15 | `tiling.zig` | retile clears cache it was meant to use | Low-Med | 2 |
| 2.16 | `xkbcommon.zig` | Hardcoded keycodes for keymap validation | Low | 2 |
| 3.1 | `tracking.zig` | Dual-optional → tagged union | Medium | 3 |
| 3.2 | `drag.zig` | Dead flushPendingUpdate | Low | 3 |
| 3.3 | `utils.zig`, `layouts.zig` | Duplicate configure functions | Low | 3 |
| 3.4 | `window.zig` | Unstable Instant internal field access | Medium | 3 |
| 3.5 | `tracking.zig` | Confusing remove/removeOrdered naming | Low | 3 |
| 3.6 | `tiling.zig` | Manual string matching → stringToEnum | Low | 3 |
| 3.7 | `workspaces.zig` | focused_window set before server grab | Medium | 3 |
| 3.8 | `bar.zig` | has_clock_segment stale after reload | Medium | 3 |
| 3.9 | `module.zig` | AlreadyInitialized silently swallowed | Medium | 3 |
| 3.10 | all | Style inconsistency zig fmt vs river align | Low | 3 |
| 3.11 | `drawing.zig`, `cache.zig` | Duplicate RGBColor type | Medium | 3 |
| 3.12 | `workspaces.zig` | Dead addWindowToCurrentWorkspace | Low | 3 |
| 3.13 | `tiling.zig` | Dead onFocusChange export | Low | 3 |
| 3.14 | `window.zig` | Keyboard SYNC grab mode | Medium | 3 |
| 3.15 | `drawing.zig` | Inconsistent text baseline method | Medium | 3 |
| 3.16 | `tiling.zig` | Temp alloc in cleanupStaleGeometryCache | Low | 3 |
| 3.17 | `workspaces.zig` | removeWindow uses unordered remove | Low | 3 |
| 3.18 | `utils.zig` | Two allocations for one WMClass string | Low | 3 |
| 3.19 | `tiling.zig` | geometry_cache never shrunk | Low | 3 |
| 3.20 | `cache.zig` | computeConfigHash misses key fields | Medium | 3 |
| 3.21 | `bar.zig` | "hana" debug leftover in status text | Low | 3 |
| 3.22 | `drawing.zig` | loadFonts discards all but first font | Medium | 3 |
| 3.23 | `dpi.zig` | dpi_cache has no invalidation path | Low | 3 |
| 3.24 | `cache.zig` | WorkspaceLabelCache hardcoded to 20 | Low | 3 |
| 3.25 | `tracking.zig` | ArrayList typed as managed, used as unmanaged | Medium | 3 |
