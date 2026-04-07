# Hana WM — Duplicate Code Analysis Report

## Executive Summary

The codebase is well-structured and heavily documented. Duplicate code falls into
four categories: **structural clones** (identical logic replicated across files),
**semantic echoes** (same concept implemented slightly differently in two places),
**comptime twins** (identical comptime-generated data), and **protocol ceremony**
(repetitive XCB boilerplate that should be a shared helper). Twelve distinct
proposals follow, ordered from highest to lowest impact.

---

## P-01 · `scaleBorderWidth` stub duplicated verbatim in two files

**Severity: High — acknowledged by an in-code comment, prone to drift**

`tiling.zig` and `window.zig` each carry an identical `else struct` fallback for
the `scale` module when `build.has_scale` is false. The formula in both stubs is:

```zig
// tiling.zig  (lines ~55–60)
pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
    if (value.is_percentage) {
        const dim_f: f32 = @floatFromInt(reference_dimension);
        return @intFromFloat(@max(0.0, @round((value.value / 100.0) * 0.5 * dim_f)));
    } else return @intFromFloat(@max(0.0, @round(value.value)));
}

// window.zig  (lines ~45–50)  — byte-for-byte identical
pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
    if (value.is_percentage) {
        const dim_f: f32 = @floatFromInt(reference_dimension);
        return @intFromFloat(@max(0.0, @round((value.value / 100.0) * 0.5 * dim_f)));
    } else return @intFromFloat(@max(0.0, @round(value.value)));
}
```

`window.zig` even contains a comment acknowledging the risk:
> *"NOTE: This fallback stub must stay in sync with the real implementation in
> scale.zig … There is no compile-time enforcement of that sync."*

**Proposed fix:** Move `scaleBorderWidth` (and `scaleMasterWidth`) to
`src/core/utils.zig` or a new always-compiled `src/core/scale_fallback.zig`, then
import it from both `tiling.zig` and `window.zig` unconditionally. The real
`scale.zig` implementation can then call through or override as needed.

---

## P-02 · `workspaceBit()` defined independently in `tiling.zig` and `workspaces.zig`

**Severity: High — silent divergence risk**

```zig
// tiling.zig
inline fn workspaceBit(ws_idx: anytype) u64 { return @as(u64, 1) << @intCast(ws_idx); }

// workspaces.zig
inline fn workspaceBit(ws_idx: u8) u64 { return @as(u64, 1) << @intCast(ws_idx); }
```

The signatures differ marginally (`anytype` vs `u8`), which means a future change
to one — such as adding a bounds check — will not propagate to the other.

**Proposed fix:** Move `workspaceBit` to `src/window/tracking.zig`, which both
files already import and which already owns the bitmask map. `allWorkspacesMask`
in `workspaces.zig` is a natural companion and should move with it.

---

## P-03 · Comptime workspace-name arrays generated twice

**Severity: Medium — maintenance friction**

`tags.zig` and `workspaces.zig` each generate a comptime array of number strings
`"1"` … `"20"` with exactly the same logic:

```zig
// tags.zig
const static_numbers = blk: {
    var nums: [20][]const u8 = undefined;
    for (&nums, 1..) |*num, i| num.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk nums;
};

// workspaces.zig
const WORKSPACE_NAMES = blk: {
    var names: [20][]const u8 = undefined;
    for (&names, 1..) |*name, i| name.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk names;
};
```

**Proposed fix:** Declare `pub const WORKSPACE_LABELS: [20][]const u8` once in
`tracking.zig` (or a new `workspaces_shared.zig`) and import it in both files.

---

## P-04 · EWMH `_NET_WM_STATE_FULLSCREEN` property-change block copy-pasted three times

**Severity: Medium — all three copies need updating together**

In `fullscreen.zig`, the same guard + `xcb_change_property` call appears in
`enterFullscreenCommit`, `exitFullscreenCommit`, and `cleanupFullscreenForMove`:

```zig
// Appears with only the last argument (1 vs 0) differing
if (g_net_wm_state != xcb.XCB_ATOM_NONE and g_net_wm_state_fullscreen != xcb.XCB_ATOM_NONE) {
    _ = xcb.xcb_change_property(
        core.conn, xcb.XCB_PROP_MODE_REPLACE,
        win, g_net_wm_state,
        xcb.XCB_ATOM_ATOM, 32,
        N, &g_net_wm_state_fullscreen,  // N = 1 (enter) or 0 (exit/cleanup)
    );
}
```

**Proposed fix:**

```zig
fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
    if (g_net_wm_state == xcb.XCB_ATOM_NONE or
        g_net_wm_state_fullscreen == xcb.XCB_ATOM_NONE) return;
    const count: u32 = if (is_fullscreen) 1 else 0;
    _ = xcb.xcb_change_property(
        core.conn, xcb.XCB_PROP_MODE_REPLACE,
        win, g_net_wm_state, xcb.XCB_ATOM_ATOM, 32,
        count, if (is_fullscreen) &g_net_wm_state_fullscreen else null,
    );
}
```

---

## P-05 · Duplicate-key array-accumulation logic in `parser.zig`

**Severity: Medium — logic divergence between parse and merge paths**

The same "if existing value is already an array append to it, else wrap both
values in a new 2-element array" logic is written twice. The `parse()` function
does it inline; `mergeSectionsInto()` does it via `appendFlatOrSingle()`.

```zig
// parse() — inline
if (old.* == .array) {
    try old.array.append(allocator, kv[1]);
} else {
    var arr = try std.ArrayList(Value).initCapacity(allocator, 2);
    arr.appendAssumeCapacity(old.*);
    arr.appendAssumeCapacity(kv[1]);
    old.* = .{ .array = arr };
}

// mergeSectionsInto() — via helper
if (old_val.* == .array) {
    try appendFlatOrSingle(allocator, &old_val.array, incoming);
} else {
    var arr = try std.ArrayList(Value).initCapacity(allocator, 2);
    ...
    arr.appendAssumeCapacity(old_val.*);
    try appendFlatOrSingle(allocator, &arr, incoming);
    old_val.* = .{ .array = arr };
}
```

The two paths behave subtly differently: the merge path flattens incoming arrays
while the parse path does not.

**Proposed fix:** Unify behind a single `fn accumulateIntoExisting(allocator, old_val: *Value, incoming: Value, flatten: bool) !void` function and call it from both sites, with `flatten = false` for the parser and `flatten = true` for merge.
