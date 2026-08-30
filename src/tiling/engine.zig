//! Pure tiling placement engine.
//! Reads model types and emits placements; no XCB and no allocation.

const std = @import("std");
const utils = @import("utils");
const model = @import("model");
const build_options = @import("build_options");

pub const hints = @import("hints");
const applyHints = hints.applyHints;

pub const Placement = struct {
    win: model.WindowId,
    rect: utils.Rect,
    visible: bool,
};

/// Sentinel rect for parked placements (formerly layouts.zero_rect). The
/// sync layer derives parked geometry from its own policy, never from this.
pub const parked_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// Frozen size-hint snapshot aligned index-for-index with View.order.
/// The caller materializes one hint per ordered window; lookup is a scan
/// over the (small) order slice only.
///
/// Why not a sorted/binary-search or hash-map optimization:
///   - The order slice is bounded by `model.max_tiled_per_ws` (64 windows),
///     so the worst-case n^2 across all emit() calls is 4096 comparisons,
///     negligible.
///   - HintsView is rebuilt from stack-allocated buffers each layout pass
///     (sync.zig), so there is no persistent data to index.
///   - The struct uses only slices (no allocator); adding a map would break
///     the zero-allocation compute() path.
///   - `forWin` is only called from emit() and master.zig:windowMaxHeight,
///     both per-window within a single layout pass.
pub const HintsView = struct {
    order: []const model.WindowId,
    hints: []const model.SizeHints,

    /// Returns hints BY VALUE with a default fallback.
    pub fn forWin(self: *const HintsView, win: model.WindowId) model.SizeHints {
        std.debug.assert(self.order.len == self.hints.len);
        for (self.order, self.hints) |w, h| {
            if (w == win) return h;
        }
        return .{};
    }
};

/// Caller-resolved environment (one bundled field instead of per-layout
/// booleans/params that each new layout would grow). Resolved from config by
/// sync's caller.
pub const Env = struct {
    margins: utils.Margins = .{ .gap = 0, .border = 0 },
    min_dim: u16 = 0,
    master_on_right: bool = false,
    grid_relaxed: bool = false,
    monocle_gaps: bool = false,
};

pub const View = struct {
    order: []const model.WindowId,
    params: *const model.LayoutParams,
    workarea: utils.Rect,
    hints: *const HintsView,
    focused: ?model.WindowId,
    // Environment resolved by the CALLER from config.
    env: Env = .{},
};

/// Zero-allocation placement buffer (an allocator parameter would break the
/// pure compute() path). Capacity bounds one placement per stored window.
pub const List = utils.BoundedList(Placement, model.store_capacity);

/// Prefer `v.focused` when it appears in `windows`, else `fallback`
/// (verbatim port of layouts.focusedElse).
pub fn focusedElse(v: *const View, windows: []const model.WindowId, fallback: model.WindowId) model.WindowId {
    if (v.focused) |f| if (std.mem.indexOfScalar(model.WindowId, windows, f) != null) return f;
    return fallback;
}

/// Shrinks `dim` by `margin` (gap/border), floored to `min_dim` so a layout
/// never hands a client a zero or negative size (verbatim port).
pub inline fn shrinkClamped(dim: u16, margin: u16, min_dim: u16) u16 {
    return if (dim > margin) dim - margin else min_dim;
}

/// Clamp a signed y coordinate to a non-negative u16 (legacy y_offset
/// threading: every layout positions windows relative to screen top).
inline fn clampYToU16(y: i32) u16 {
    return @intCast(@max(y, 0));
}

/// Work-area rect inset by the outer gap (verbatim port of layouts.outerArea).
/// x/y are i32 (some tiling layouts thread i32 coords through their recursion),
/// w/h u16.
pub inline fn outerArea(wa: utils.Rect, gap: u16) struct { x: i32, y: i32, w: u16, h: u16 } {
    return .{
        .x = @intCast(gap),
        .y = clampYToU16(wa.y) +| gap,
        .w = wa.width -| gap *| 2,
        .h = wa.height -| gap *| 2,
    };
}

/// Work-area origin y clamped to >= 0, as u16 (legacy `y_offset` threading:
/// every layout positioned windows relative to the screen top, not the root).
pub inline fn waY(v: *const View) u16 {
    return clampYToU16(v.workarea.y);
}

/// Emit a placement with the window's size hints applied to `rect`.
inline fn emit(v: *const View, out: *List, win: model.WindowId, rect: utils.Rect, visible: bool) void {
    const ok = out.append(.{
        .win = win,
        .rect = if (visible) applyHints(rect, v.hints.forWin(win)) else parked_rect,
        .visible = visible,
    });
    if (std.debug.runtime_safety) {
        std.debug.assert(ok);
    }
}

/// Emit a parked placement (the pushWindowOffscreenAndInvalidate transform).
inline fn emitParked(out: *List, win: model.WindowId) void {
    const ok = out.append(.{ .win = win, .rect = parked_rect, .visible = false });
    if (std.debug.runtime_safety) {
        std.debug.assert(ok);
    }
}

/// Dispatch registry (build-generated, alphabetical stems). The active layout
/// is a `u8` index into this table; the engine never owns a closed enum.
const tiling_mods = @import("tiling_modules").modules;

/// Lowercased-name lookup over the registry (exact match on module names).
fn indexOfName(lower: []const u8) ?usize {
    for (tiling_mods, 0..) |m, i| {
        if (std.mem.eql(u8, lower, m.name)) return i;
    }
    return null;
}

/// Resolve a config layout name (case-insensitive) to its registry index.
/// Config-parsed names are canonicalized at the config boundary
/// (config.canonicalLayoutName), so this is an exact lowercased match on
/// module names; the legacy "master-stack"/"master_stack" spellings never
/// reach the engine.
pub fn layoutByName(name: []const u8) ?usize {
    if (name.len > 64) return null;
    var buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    return indexOfName(lower);
}

/// Neutral last-resort default layout: the first registered module (index 0).
/// The effective default is config-driven (cfg.tiling.layout resolves at every
/// seeding site); this only stands in when that name fails to resolve (a
/// removed/unknown module), keeping dispatch ids always resolvable.
pub fn defaultKind() u8 {
    return 0;
}

/// The registry module name for `kind` ("" when out of range).
pub fn moduleName(kind: u8) []const u8 {
    if (kind >= tiling_mods.len) return "";
    return tiling_mods[kind].name;
}

/// Variant count for `kind` (cycle_variant actions/mod bar). Registry-driven.
pub fn variantCount(kind: u8) u8 {
    if (kind >= tiling_mods.len) return 1;
    return tiling_mods[kind].variant_count;
}

/// Step a layout within the config layout-name list (config order is the
/// cycle order). Each name resolves to a registry index (unresolvable names
/// are skipped); `cur`'s position steps by `dir` and wraps modulo the list.
/// When `cur` is not in the list (safety net — defaults/overrides always come
/// from config names) it lands on the first/last edge by direction.
pub fn cycleKind(cur: u8, dir: i32, names: []const []const u8) u8 {
    var indices: [256]u8 = undefined;
    var n: usize = 0;
    for (names) |nm| {
        if (layoutByName(nm)) |idx| {
            if (n < indices.len) {
                indices[n] = @intCast(idx);
                n += 1;
            }
        }
    }
    if (n == 0) return cur;
    var pos: usize = 0;
    var found = false;
    for (indices[0..n], 0..) |idx, i| {
        if (idx == cur) {
            pos = i;
            found = true;
            break;
        }
    }
    const next: usize = if (found)
        @intCast(@mod(@as(i32, @intCast(pos)) + dir, @as(i32, @intCast(n))))
    else if (dir >= 0)
        0
    else
        n - 1;
    return indices[next];
}

/// Compute `kind`'s layout into `out` (cleared first). Each layout module
/// binds its `compute` hook to the module's placement function and must
/// append exactly one placement per window in `v.order` (off-viewport/hidden
/// windows are parked via emitHidden). The caller sorts afterwards, so
/// layout emission order is only pinned by tests, not by sync.
pub fn compute(kind: u8, v: View, out: *List) void {
    out.clear();
    if (kind >= tiling_mods.len) return;
    if (tiling_mods[kind].compute) |f| f(&v, out);
}

// Algo modules share this file's private emit helpers via pub re-exports.
pub const emitView = emit;
pub const emitHidden = emitParked;
