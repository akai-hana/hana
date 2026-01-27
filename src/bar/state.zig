//! Bar state management

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");

pub const BarState = struct {
    window: u32,
    width: u16,
    height: u16,
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    status_text: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cached_title: std.ArrayList(u8),
    cached_title_window: ?u32,
    last_draw_time: i64,
    update_pending: std.atomic.Value(bool),
    alive: std.atomic.Value(bool),
    /// Dirty flag; marks bar as needing redraw
    dirty: std.atomic.Value(bool),
    /// Minimum time between updates - reduced to 8ms for snappier feel (~120fps)
    min_update_interval_ns: i64 = 8 * std.time.ns_per_ms,

    pub fn init(allocator: std.mem.Allocator, window: u32, width: u16, height: u16, dc: *drawing.DrawContext, config: defs.BarConfig) !*BarState {
        const state = try allocator.create(BarState);
        errdefer allocator.destroy(state);

        state.* = .{
            .window = window,
            .width = width,
            .height = height,
            .dc = dc,
            .config = config,
            .status_text = std.ArrayList(u8){},
            .allocator = allocator,
            .cached_title = std.ArrayList(u8){},
            .cached_title_window = null,
            .last_draw_time = 0,
            .update_pending = std.atomic.Value(bool).init(false),
            .alive = std.atomic.Value(bool).init(true),
            .dirty = std.atomic.Value(bool).init(false),
        };

        try state.status_text.appendSlice(allocator, "hana");

        return state;
    }

    pub fn deinit(self: *BarState) void {
        self.alive.store(false, .release);
        self.status_text.deinit(self.allocator);
        self.cached_title.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn requestUpdate(self: *BarState) void {
        if (self.alive.load(.acquire)) {
            self.update_pending.store(true, .release);
        }
    }

    pub fn hasPendingUpdate(self: *BarState) bool {
        return self.update_pending.load(.acquire);
    }

    pub fn clearPendingUpdate(self: *BarState) void {
        self.update_pending.store(false, .release);
    }

    pub fn invalidateTitleCache(self: *BarState) void {
        self.cached_title_window = null;
    }

    pub fn isAlive(self: *BarState) bool {
        return self.alive.load(.acquire);
    }

    /// Mark bar as dirty (needs redraw)
    pub fn markDirty(self: *BarState) void {
        self.dirty.store(true, .release);
    }

    /// Clear dirty flag
    pub fn clearDirty(self: *BarState) void {
        self.dirty.store(false, .release);
    }

    /// Check if bar needs redraw
    pub fn isDirty(self: *BarState) bool {
        return self.dirty.load(.acquire);
    }

    /// Check if enough time has passed since last update
    pub fn shouldUpdate(self: *BarState) bool {
        if (!self.isDirty()) return false;

        const now = if (std.posix.clock_gettime(std.posix.CLOCK.REALTIME)) |ts|
            ts.sec * std.time.ns_per_s + ts.nsec
        else |_|
            return true; // If we can't get time, just update

        const elapsed = now - (self.last_draw_time * std.time.ns_per_s);
        return elapsed >= self.min_update_interval_ns;
    }

    /// Redraw bar if dirty and enough time has passed
    pub fn updateIfDirty(self: *BarState, wm: *defs.WM) !void {
        if (!self.isDirty()) return;

        const now = if (std.posix.clock_gettime(std.posix.CLOCK.REALTIME)) |ts|
            ts.sec * std.time.ns_per_s + ts.nsec
        else |_|
            0;

        const elapsed = now - (self.last_draw_time * std.time.ns_per_s);

        // Only update if enough time has passed OR if it's been too long
        if (elapsed >= self.min_update_interval_ns or elapsed > 100 * std.time.ns_per_ms) {
            const render = @import("render");
            try render.draw(self, wm);
            self.clearDirty();
        }
    }
};
