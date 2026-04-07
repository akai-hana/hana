# Hana WM — Duplicate Code Analysis Report

## Executive Summary

The codebase is well-structured and heavily documented. Duplicate code falls into
four categories: **structural clones** (identical logic replicated across files),
**semantic echoes** (same concept implemented slightly differently in two places),
**comptime twins** (identical comptime-generated data), and **protocol ceremony**
(repetitive XCB boilerplate that should be a shared helper). Twelve distinct
proposals follow, ordered from highest to lowest impact.

---

## P-06 · `getWsState` / `getWsCurrentWorkspace` redefined in three modules

**Severity: Medium — boilerplate, inconsistent naming**

Three files define effectively the same two helper functions:

| File | Helper 1 | Helper 2 |
|---|---|---|
| `tiling.zig` | `fn getWsState() ?*WsState` | `fn getWsCurrentWorkspace() ?*WsWorkspace` |
| `window.zig` | `fn getWsState() ?*workspaces.State` | `fn getWsCurrentWorkspace() ?*WsWorkspace` |
| `bar.zig` | `fn getWorkspaceState() ?*WorkspaceState` | *(inline at call sites)* |

All three are just `if (comptime build.has_workspaces) workspaces.getState() else null`.

**Proposed fix:** Promote `getState()` and `getCurrentWorkspaceObject()` on the
`workspaces` module to have stable `pub` signatures that are safe to call even
when workspaces are disabled (returning null). Remove all per-file wrappers.

---

## P-07 · `fromString` pattern duplicated in `MasterSide` and `IndicatorLocation`

**Severity: Low-medium — copy-paste with identical structure**

Both enums implement the same lowercase-into-stack-buffer-then-map-lookup pattern:

```zig
pub inline fn fromString(str: []const u8) ?MasterSide {
    var buf: [16]u8 = undefined;
    if (str.len > buf.len) return null;
    return string_map.get(std.ascii.lowerString(&buf, str));
}
// … identical in IndicatorLocation
```

**Proposed fix:** A small comptime helper in `types.zig`:

```zig
fn fromStringCI(comptime T: type, str: []const u8) ?T {
    const map = comptime T.string_map; // convention: each enum exposes string_map
    var buf: [32]u8 = undefined;
    if (str.len > buf.len) return null;
    return map.get(std.ascii.lowerString(&buf, str));
}
```

Both enums then reduce to `pub inline fn fromString(s: []const u8) ?@This() { return fromStringCI(@This(), s); }`.

---

## P-08 · Monotonic clock read duplicated with different units

**Severity: Low-medium — unit mismatch risk**

`carousel.zig` exposes `fn monotonicMs() i64` (milliseconds). `bar.zig` defines a
private `inline fn monotonicNowNs() u64` (nanoseconds). Both use the same
`clock_gettime(.MONOTONIC, &ts)` syscall:

```zig
// carousel.zig
fn monotonicMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// bar.zig
inline fn monotonicNowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
```

**Proposed fix:** Move both to `core/utils.zig` as `pub fn monotonicMs() i64` and
`pub fn monotonicNs() u64`. Having both in one place makes the unit difference
explicit and avoids future callers adding a third variant.

---

## P-09 · `pushOffscreen` / `hideWindow` scattered across four modules

**Severity: Low-medium — identical one-liners with risk of constant drift**

Four different files express the same "move window to `OFFSCREEN_X_POSITION`"
operation using different wrapper names:

| Location | Wrapper |
|---|---|
| `workspaces.zig` | `inline fn pushOffscreen(conn, win)` |
| `minimize.zig` | `inline fn hideWindow(win)` |
| `fullscreen.zig` | bare `xcb_configure_window` in `enterFullscreenCommit` and `PushCtx.call` |
| `monocle.zig` | bare `xcb_configure_window` in `pushBackgroundWindowsOffscreen` |

All produce the exact same XCB call with `XCB_CONFIG_WINDOW_X` and `OFFSCREEN_X_POSITION`.

**Proposed fix:** Add `pub inline fn pushWindowOffscreen(conn: *xcb.xcb_connection_t, win: u32) void` to `src/core/utils.zig` and replace all four usages.

---

## P-10 · `submitDraw` and `submitDrawBlocking` share unextracted snapshot logic

**Severity: Low — code smell within a single file**

In `bar.zig`, both `submitDraw()` and `submitDrawBlocking()` open with identical
snapshot preparation code before diverging only at the blocking wait:

```zig
// submitDraw
const s = gBar.state orelse return;
if (!s.is_visible) return;
const idx = gBar.channel.write_index;
const forced = gBar.channel.pending_force_full_redraw;
gBar.channel.pending_force_full_redraw = false;
captureStateIntoSlot(s, &gBar.channel.slots[idx], ..., forced) catch |e| { ... return; };
gBar.channel.mutex.lock();
// … differs here

// submitDrawBlocking — identical preamble, then adds the wait loop
```

**Proposed fix:** Extract the shared preamble into a private `fn prepareSnapshot(s: *State) ?u1` that returns the `read_idx` on success and null on failure. Both callers then lock, signal, and diverge on blocking behaviour.

---

## P-11 · `ungrabAndFlush` duplicated as bare two-liner everywhere except `bar.zig`

**Severity: Low — noise, consistent pattern**

`bar.zig` defines:
```zig
inline fn ungrabAndFlush() void {
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}
```

But `fullscreen.zig`, `minimize.zig`, `tiling.zig`, `workspaces.zig`, `drag.zig`,
and `events.zig` all repeat the two-liner bare. The `ungrabAndFlush` name only
exists inside `bar.zig`.

**Proposed fix:** Move `ungrabAndFlush` to `src/core/utils.zig` as a `pub inline` function and replace the ~12 bare two-liners codebase-wide.

---

## P-12 · `sendWMTakeFocus` re-scans WM_PROTOCOLS instead of reusing `scanProtocolAtoms`

**Severity: Low — internal inconsistency in `window.zig`**

`window.zig` has a private helper `scanProtocolAtoms()` used by
`queryWMProtocolsProps` and `populateFocusCacheFromCookies`. However,
`sendWMTakeFocus` performs its own inline atom scan without calling it:

```zig
// sendWMTakeFocus — manual scan
for (proto_list[0..@intCast(proto_reply.*.value_len)]) |a| {
    if (a == take_focus_atom) { has_take_focus = true; break; }
}

// scanProtocolAtoms — existing helper doing the same thing
inline fn scanProtocolAtoms(protocol_atoms: []const u32, ...) WMProtocolsProps {
    for (protocol_atoms) |atom| {
        if (atom == take_focus_atom) props.take_focus = true;
        ...
    }
    return props;
}
```

**Proposed fix:**

```zig
// In sendWMTakeFocus, replace the loop with:
const take_focus_atom = utils.getAtomCached("WM_TAKE_FOCUS") catch return;
const wm_delete_atom  = utils.getAtomCached("WM_DELETE_WINDOW") catch return;
const props = scanProtocolAtoms(
    raw[0..@intCast(proto_reply.*.value_len)],
    take_focus_atom, wm_delete_atom,
);
if (!props.take_focus) return;
```

---

## Summary Table

| # | Files affected | Type | Effort |
|---|---|---|---|
| P-01 | `tiling.zig`, `window.zig` | Structural clone | Small |
| P-02 | `tiling.zig`, `workspaces.zig` | Structural clone | Small |
| P-03 | `tags.zig`, `workspaces.zig` | Comptime twin | Trivial |
| P-04 | `fullscreen.zig` (×3 sites) | Copy-paste | Small |
| P-05 | `parser.zig` (parse + merge) | Semantic echo | Medium |
| P-06 | `tiling.zig`, `window.zig`, `bar.zig` | Boilerplate | Small |
| P-07 | `types.zig` (MasterSide + IndicatorLocation) | Copy-paste | Small |
| P-08 | `carousel.zig`, `bar.zig` | Semantic echo | Trivial |
| P-09 | `workspaces.zig`, `minimize.zig`, `fullscreen.zig`, `monocle.zig` | Protocol ceremony | Small |
| P-10 | `bar.zig` | Single-file duplication | Small |
| P-11 | All files using XCB server grab | Protocol ceremony | Small |
| P-12 | `window.zig` | Internal inconsistency | Trivial |

**Recommended order of implementation:** P-11 (highest reach, lowest risk) →
P-01 (removes an acknowledged comment-debt) → P-02 → P-04 → P-03 → P-09 →
P-08 → P-06 → P-12 → P-07 → P-10 → P-05 (most semantically nuanced).
