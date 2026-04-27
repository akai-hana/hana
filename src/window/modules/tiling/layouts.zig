//! Shared tiling layout infrastructure: geometry constraints and layout config entry point.

const std     = @import("std");
const core    = @import("core");
    const xcb = core.xcb;
const utils   = @import("utils");

const debug = @import("debug");


// WM_NORMAL_HINTS size constraint cache — populated at handleMapRequest, evicted on unmanage.

/// ICCCM WM_NORMAL_HINTS constraints for a single window.
pub const SizeHints = struct {
    /// PMaxSize: 0 = unconstrained.
    max_width:  u16 = 0,
    max_height: u16 = 0,
    /// PResizeInc: w = base_width + N*inc_width; 0 = unconstrained.
    inc_width:  u16 = 0,
    inc_height: u16 = 0,
    /// PAspect (dwm convention): 0.0 = unconstrained.
    min_aspect: f32 = 0.0,
    max_aspect: f32 = 0.0,
};

/// Per-window cache entry: last geometry, last border color, and WM_NORMAL_HINTS constraints.
pub const WindowData = struct {
    /// Zeroed rect = "stale / not yet computed"; layout never produces 0×0. Use `hasValidRect()`.
    rect:   utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    border: u32 = 0,
    /// Populated at map time via `CacheMap.cacheHints`; all-zero means unconstrained.
    hints:  SizeHints = .{},

    /// Both dimensions must be non-zero; a rect with only one zero is still degenerate.
    pub fn hasValidRect(self: WindowData) bool {
        return self.rect.width != 0 and self.rect.height != 0;
    }
};

// Hash table parameters
const cache_capacity:  usize = 256; // max live entries; overflow_sentinel fires above this
const hash_table_cap:  usize = 512; // power-of-two slot count; load factor ≤ 0.5
const hash_table_mask: usize = hash_table_cap - 1;
const hash_shift:      u5    = 23;  // 32 - log2(512)
const EMPTY_WIN:       u32   = 0;   // XCB_NONE; never a real window ID


/// Open-addressing hash table mapping window IDs → geometry + border color + WM_NORMAL_HINTS.
/// Zero-initializable: `CacheMap{}` is an empty table because EMPTY_WIN = 0.
pub const CacheMap = struct {
    const Slot = struct {
        win:  u32        = EMPTY_WIN,
        data: WindowData = .{},
    };

    pub const GetOrPutResult = struct {
        found_existing: bool,
        value_ptr: *WindowData,
    };

    slots: [hash_table_cap]Slot = std.mem.zeroes([hash_table_cap]Slot),
    count: usize = 0,

    /// Per-instance overflow sink for `getOrPut`. Instance-scoped (vs. module-level) so
    /// concurrent overflows in the same call chain don't alias. Affected window misses
    /// dedup and gets a redundant configure_window — correct.
    overflow_sentinel: WindowData = .{},

    /// Knuth multiplicative hash for 32-bit keys → 9-bit slot index.
    /// Distributes XCB's near-sequential window IDs uniformly.
    inline fn hashSlot(win: u32) usize {
        return @intCast((win *% 2654435761) >> hash_shift);
    }

    /// Locate or insert the entry for `win`. Always succeeds (no allocator, no error union).
    /// Routes to `overflow_sentinel` and logs an error if `cache_capacity` is exceeded.
    pub fn getOrPut(self: *CacheMap, win: u32) GetOrPutResult {
        std.debug.assert(win != EMPTY_WIN); // XCB never assigns ID 0
        var idx = hashSlot(win);
        while (true) : (idx = (idx + 1) & hash_table_mask) {
            const slot = &self.slots[idx];
            if (slot.win == win)
                return .{ .found_existing = true, .value_ptr = &slot.data };
            if (slot.win == EMPTY_WIN) {
                if (self.count >= cache_capacity) {
                    debug.err("CacheMap: capacity exceeded, dropping cache for 0x{x}", .{win});
                    self.overflow_sentinel = .{};
                    return .{ .found_existing = false, .value_ptr = &self.overflow_sentinel };
                }
                slot.* = .{ .win = win, .data = .{} };
                self.count += 1;
                return .{ .found_existing = false, .value_ptr = &slot.data };
            }
        }
    }

    /// Returns a mutable pointer to the cached WindowData for `win`, or null if absent.
    pub fn getPtr(self: *CacheMap, win: u32) ?*WindowData {
        var idx = hashSlot(win);
        while (true) : (idx = (idx + 1) & hash_table_mask) {
            const slot = &self.slots[idx];
            if (slot.win == win)       return &slot.data;
            if (slot.win == EMPTY_WIN) return null;
        }
    }

    /// Remove the entry for `win` (no-op when absent).
    /// Uses backward-shift deletion to maintain the linear-probe invariant without tombstones.
    /// Shift condition: entry at j (ideal r) moves to hole h when (j-r) mod cap >= (j-h) mod cap.
    pub fn remove(self: *CacheMap, win: u32) void {
        // Locate the entry.
        var hole: usize = hashSlot(win);
        while (true) : (hole = (hole + 1) & hash_table_mask) {
            if (self.slots[hole].win == EMPTY_WIN) return; // not present
            if (self.slots[hole].win == win)       break;
        }
        self.count -= 1;

        // Backward-shift: pull subsequent entries toward the hole until an empty slot.
        var j = (hole + 1) & hash_table_mask;
        while (self.slots[j].win != EMPTY_WIN) {
            const r = hashSlot(self.slots[j].win);
            // Can entry at j (ideal r) move to hole?
            // Yes when (j-r) mod cap >= (j-hole) mod cap.
            if (((j -% r) & hash_table_mask) >= ((j -% hole) & hash_table_mask)) {
                self.slots[hole] = self.slots[j];
                hole = j;
            }
            j = (j + 1) & hash_table_mask;
        }
        self.slots[hole] = .{}; // clear the final hole (original or shifted)
    }

    /// Reset the cache to empty in O(count) time by visiting only occupied slots.
    pub fn clearRetainingCapacity(self: *CacheMap) void {
        var i: usize = 0;
        var cleared: usize = 0;
        while (cleared < self.count) : (i = (i + 1) & hash_table_mask) {
            if (self.slots[i].win != EMPTY_WIN) {
                self.slots[i] = .{};
                cleared += 1;
            }
        }
        self.count = 0;
    }

    /// Store WM_NORMAL_HINTS for `win`; no-op when all fields are zero.
    /// Creates the entry if absent; auto-evicted by `remove()` at unmanage time.
    pub fn cacheHints(self: *CacheMap, win: u32, hints: SizeHints) void {
        if (isEmptySizeHints(hints)) return;
        self.getOrPut(win).value_ptr.hints = hints;
    }
};

// Layout context and the configureWithHints entry point

/// Context passed to every layout module's `tileWithOffset` call.
/// Carries XCB connection and cache by pointer — no module-level globals.
pub const LayoutCtx = struct {
    conn: *xcb.xcb_connection_t,
    /// Pointer into tiling.State.cache; always non-null during a retile pass.
    cache: *CacheMap,
    /// When non-null, emits a border-color change in the same cache probe as geometry,
    /// eliminating the separate updateBorders pass. Null when border info is unavailable.
    get_border_color: ?*const fn (win: u32) u32 = null,
    /// When non-null, this window's configure_window call is emitted last within its group.
    /// Used by swap_master to prevent a one-frame wallpaper gap during master/stack swaps.
    defer_configure: ?u32 = null,
    /// When non-null, BORDER_WIDTH is merged into the geometry request (3 XCB requests → 2).
    /// Set only during reloadConfig; null for normal retile passes.
    border_width: ?u16 = null,
    /// Focused window for monocle's raise logic. Null outside the normal retile path;
    /// monocle falls back to list tail in that case.
    focused_win: ?u32 = null,
};

/// Shared impl for configureWithHints and configureWithHintsAndRaise.
/// `raise` is comptime — dead branch is eliminated; codegen matches two-function approach.
/// When `ctx.border_width` is non-null, BORDER_WIDTH is merged into the geometry call (reloadConfig only).
fn configureWithHintsImpl(comptime raise: bool, ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    // Single probe: value_ptr.hints holds WM_NORMAL_HINTS alongside geometry/border dedup data.
    const gop = ctx.cache.getOrPut(win);
    const effective = applyHintsToRect(rect, gop.value_ptr.hints);

    if (!effective.isValid()) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}",
            .{ win, effective.width, effective.height, effective.x, effective.y });
        if (comptime raise) {
            _ = xcb.xcb_configure_window(ctx.conn, win,
                xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
        }
        // Update border even on degenerate rect — otherwise hints-zeroed windows
        // never escape this early exit and get a permanently stale border color.
        if (ctx.get_border_color) |getBorderColor| {
            const color = getBorderColor(win);
            if (!gop.found_existing or gop.value_ptr.border != color) {
                gop.value_ptr.border = color;
                _ = xcb.xcb_change_window_attributes(ctx.conn, win,
                    xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
            }
        }
        return;
    }

    const is_rect_changed = !gop.found_existing or !rectsEqual(gop.value_ptr.rect, effective);
    if (is_rect_changed) {
        gop.value_ptr.rect = effective;
        if (comptime raise) {
            _ = xcb.xcb_configure_window(ctx.conn, win,
                xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
                xcb.XCB_CONFIG_WINDOW_STACK_MODE,
                &[_]u32{
                    @bitCast(@as(i32, effective.x)),
                    @bitCast(@as(i32, effective.y)),
                    effective.width,
                    effective.height,
                    xcb.XCB_STACK_MODE_ABOVE,
                });
        } else if (ctx.border_width) |bw| {
            // Merge BORDER_WIDTH — saves one XCB round-trip per window during reloadConfig.
            _ = xcb.xcb_configure_window(ctx.conn, win,
                xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
                xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
                &[_]u32{
                    @bitCast(@as(i32, effective.x)),
                    @bitCast(@as(i32, effective.y)),
                    effective.width,
                    effective.height,
                    bw,
                });
        } else {
            utils.configureWindow(ctx.conn, win, effective);
        }
    } else if (comptime raise) {
        // Geometry unchanged (cache hit) — only raise.
        _ = xcb.xcb_configure_window(ctx.conn, win,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    const getBorderColor = ctx.get_border_color orelse return;
    const color = getBorderColor(win);
    if (gop.found_existing and gop.value_ptr.border == color) return;
    gop.value_ptr.border = color;
    _ = xcb.xcb_change_window_attributes(ctx.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

/// Apply geometry to `win`, clamped to WM_NORMAL_HINTS. Skips XCB when rect is unchanged;
/// updates border color in the same probe when `ctx.get_border_color` is set.
pub fn configureWithHints(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    configureWithHintsImpl(false, ctx, win, rect);
}

/// Like configureWithHints, but also raises the window atomically.
/// Combines geometry + STACK_MODE in one request so the compositor sees no intermediate frame.
pub fn configureWithHintsAndRaise(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    configureWithHintsImpl(true, ctx, win, rect);
}

/// Apply ICCCM §4.1.2.3 hint passes to a raw rect.
///
/// Pass 1 (min-size) is omitted: honoring it would pin the effective rect to the declared
/// minimum on every retile, making dedup always a hit and breaking mod_h/mod_l resizing.
/// Consistent with floating drag, which also ignores declared minimums.
///
/// Pass 2 (resize-increment snap) is kept so terminals align to character cell boundaries;
/// base is 0 rather than min_width since min-size is not enforced.
fn applyHintsToRect(rect: utils.Rect, h: SizeHints) utils.Rect {
    var w:  u16 = rect.width;
    var ht: u16 = rect.height;

    // Pass 2: snap to resize increments (base = 0): effective = floor(dim / inc) * inc
    w  = snapDimToIncrement(w,  0, h.inc_width);
    ht = snapDimToIncrement(ht, 0, h.inc_height);

    // Pass 3: clamp to declared maximum (after snap so we never exceed it after rounding).
    if (h.max_width  > 0) w  = @min(w,  h.max_width);
    if (h.max_height > 0) ht = @min(ht, h.max_height);

    // Pass 4: aspect ratio (ICCCM §4.1.2.3, matching dwm).
    // Cross-multiply to avoid two FP divides per window per retile:
    //   fw/fh > max_aspect  →  fw > fh * max_aspect
    //   fh/fw > min_aspect  →  fh > fw * min_aspect
    if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(ht);
        if (fw > fh * h.max_aspect) {
            w = @intFromFloat(@round(fh * h.max_aspect));
            if (h.max_width > 0) w = @min(w, h.max_width);
        } else if (fh > fw * h.min_aspect) {
            ht = @intFromFloat(@round(fw * h.min_aspect));
            if (h.max_height > 0) ht = @min(ht, h.max_height);
        }
    }

    return .{ .x = rect.x, .y = rect.y, .width = w, .height = ht };
}

/// Snap `dim` to the nearest multiple of `inc` above `base`.
/// Returns `dim` unchanged when `inc` is zero or dim does not exceed `base`.
inline fn snapDimToIncrement(dim: u16, base: u16, inc: u16) u16 {
    if (inc == 0 or dim <= base) return dim;
    const excess = dim - base;
    return base + (excess / inc) * inc;
}

/// Returns true when all hint fields are zero (client published no constraints).
inline fn isEmptySizeHints(h: SizeHints) bool {
    return h.max_width == 0 and h.max_height == 0 and
           h.inc_width == 0 and h.inc_height == 0 and
           h.min_aspect == 0.0 and h.max_aspect == 0.0;
}
