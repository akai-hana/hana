//! Bar state management

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const common = @import("common");

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
    dirty: std.atomic.Value(bool),
    alive: std.atomic.Value(bool),
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
            .dirty = std.atomic.Value(bool).init(false),
            .alive = std.atomic.Value(bool).init(true),
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

    pub fn invalidateTitleCache(self: *BarState) void {
        self.cached_title_window = null;
    }

    pub inline fn isAlive(self: *BarState) bool {
        return self.alive.load(.acquire);
    }

    pub inline fn markDirty(self: *BarState) void {
        self.dirty.store(true, .release);
    }

    pub inline fn clearDirty(self: *BarState) void {
        self.dirty.store(false, .release);
    }

    pub inline fn isDirty(self: *BarState) bool {
        return self.dirty.load(.acquire);
    }

    pub fn shouldUpdate(self: *BarState) bool {
        if (!self.isDirty()) return false;

        const now = common.getTimestampNs();
        const elapsed = now - (self.last_draw_time * std.time.ns_per_s);
        return elapsed >= self.min_update_interval_ns;
    }

    pub fn updateIfDirty(self: *BarState, wm: *defs.WM) !void {
        if (!self.shouldUpdate()) return;

        const render = @import("render");
        try render.draw(self, wm);
        self.clearDirty();
    }
};
