//! Enhanced status bar with configurable layout and auto-sizing

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const utils = @import("utils");
const workspaces = @import("workspaces");
const tiling = @import("tiling");

// X11 for XSync (to fix bar toggle lag)
const c = @cImport({
    @cInclude("X11/Xlib.h");
});

// Segment modules
const workspaces_segment = @import("tags");
const layout_segment = @import("layout");
const title_segment = @import("title");
const clock_segment = @import("clock");
const status_segment = @import("status");

// OPTIMIZATION: Share workspace width constant across files
pub const WORKSPACE_WIDTH: u16 = 40;

const State = struct {
    window: u32,
    width: u16,
    height: u16,
    dc: *drawing.DrawContext,
    conn: *xcb.xcb_connection_t,
    config: defs.BarConfig,
    status_text: std.ArrayList(u8),
    cached_title: std.ArrayList(u8),
    cached_title_window: ?u32,
    dirty: bool,
    dirty_clock: bool,
    last_second: i64,
    alive: bool,
    allocator: std.mem.Allocator,
    // OPTIMIZATION: Cache segment widths to avoid recalculation
    cached_clock_width: u16,

    fn init(allocator: std.mem.Allocator, conn: *xcb.xcb_connection_t, window: u32, width: u16, height: u16,
            dc: *drawing.DrawContext, config: defs.BarConfig) !*State {
        const s = try allocator.create(State);
        s.* = .{
            .window = window,
            .width = width,
            .height = height,
            .dc = dc,
            .conn = conn,
            .config = config,
            .status_text = std.ArrayList(u8){},
            .cached_title = std.ArrayList(u8){},
            .cached_title_window = null,
            .dirty = false,
            .dirty_clock = false,
            .last_second = 0,
            .alive = true,
            .allocator = allocator,
            .cached_clock_width = 0,
        };
        try s.status_text.appendSlice(allocator, "hana");
        // OPTIMIZATION: Calculate clock width once during init
        s.cached_clock_width = s.dc.textWidth("0000-00-00 00:00:00") + 2 * s.config.padding;
        return s;
    }

    fn deinit(self: *State) void {
        self.alive = false;
        self.status_text.deinit(self.allocator);
        self.cached_title.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    inline fn markDirty(self: *State) void { self.dirty = true; }
    inline fn markClockDirty(self: *State) void { self.dirty_clock = true; }
    inline fn clearDirty(self: *State) void { 
        self.dirty = false;
        self.dirty_clock = false;
    }
    inline fn isDirty(self: *State) bool { return self.dirty or self.dirty_clock; }
    inline fn isAlive(self: *State) bool { return self.alive; }
};

var state: ?*State = null;

/// Shared font-loading logic used by both init() and calculateBarHeight().
fn loadBarFonts(dc: *drawing.DrawContext, wm: *defs.WM) !void {
    if (wm.config.bar.fonts.items.len > 0) {
        var sized_fonts = std.ArrayList([]const u8){};
        defer {
            for (sized_fonts.items) |s| wm.allocator.free(s);
            sized_fonts.deinit(wm.allocator);
        }
        for (wm.config.bar.fonts.items) |font_name| {
            const sized = if (wm.config.bar.font_size > 0)
                try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ font_name, wm.config.bar.font_size })
            else
                try wm.allocator.dupe(u8, font_name);
            try sized_fonts.append(wm.allocator, sized);
        }
        try dc.loadFonts(sized_fonts.items);
    } else {
        const font_str = if (wm.config.bar.font_size > 0)
            try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ wm.config.bar.font, wm.config.bar.font_size })
        else
            wm.config.bar.font;
        defer if (wm.config.bar.font_size > 0) wm.allocator.free(font_str);
        try dc.loadFont(font_str);
    }
}

pub fn init(wm: *defs.WM) !void {
    if (!wm.config.bar.show) return error.BarDisabled;

    utils.flush(wm.conn);
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

    const screen = wm.screen;
    const width = screen.width_in_pixels;
    
    const height = try calculateBarHeight(wm);

    const y_pos: i16 = if (wm.config.bar.vertical_position == .bottom)
        @as(i16, @intCast(screen.height_in_pixels)) - @as(i16, @intCast(height))
    else
        0;

    const window = xcb.xcb_generate_id(wm.conn);
    const values = [_]u32{
        wm.config.bar.bg,
        xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS,
    };

    _ = xcb.xcb_create_window(
        wm.conn, xcb.XCB_COPY_FROM_PARENT, window, screen.root,
        0, y_pos, width, height, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual,
        xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK, &values,
    );

    utils.flush(wm.conn);
    try setWindowProperties(wm, window, height);
    utils.flush(wm.conn);
    _ = xcb.xcb_map_window(wm.conn, window);
    utils.flush(wm.conn);

    const dc = try drawing.DrawContext.init(wm.allocator, window, width, height);
    errdefer dc.deinit();

    try loadBarFonts(dc, wm);

    const s = try State.init(wm.allocator, wm.conn, window, width, height, dc, wm.config.bar);
    try draw(s, wm);
    utils.flush(wm.conn);

    state = s;
}

fn calculateBarHeight(wm: *defs.WM) !u16 {
    if (wm.config.bar.height) |h| {
        return h;
    }
    
    const temp_win = xcb.xcb_generate_id(wm.conn);
    const screen = wm.screen;
    
    _ = xcb.xcb_create_window(
        wm.conn, xcb.XCB_COPY_FROM_PARENT, temp_win, screen.root,
        0, 0, 1, 1, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual,
        0, null,
    );
    defer _ = xcb.xcb_destroy_window(wm.conn, temp_win);
    
    const temp_dc = drawing.DrawContext.init(wm.allocator, temp_win, 1, 1) catch {
        return 24;
    };
    defer temp_dc.deinit();
    
    loadBarFonts(temp_dc, wm) catch {
        return 24;
    };
    
    const ascender: i32 = temp_dc.getAscender();
    const descender: i32 = temp_dc.getDescender();
    const font_height: u32 = @intCast(ascender - descender);
    
    const total_height: u32 = font_height + 2 * wm.config.bar.padding;
    
    return @intCast(std.math.clamp(total_height, 20, 100));
}

pub fn deinit() void {
    if (state) |s| {
        const conn = s.conn;
        const window = s.window;
        s.dc.deinit();
        s.deinit();
        _ = xcb.xcb_destroy_window(conn, window);
        state = null;
    }
}

fn setWindowProperties(wm: *defs.WM, window: u32, height: u16) !void {
    const conn = wm.conn;
    const screen_w = wm.screen.width_in_pixels;

    const wm_strut_partial = try utils.getAtom(conn, "_NET_WM_STRUT_PARTIAL");
    const strut: [12]u32 = if (wm.config.bar.vertical_position == .bottom)
        .{ 0, 0, 0, height,  0, 0, 0, 0,  0, 0,  0, screen_w }
    else
        .{ 0, 0, height, 0,  0, 0, 0, 0,  0, screen_w,  0, 0 };

    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, window,
        wm_strut_partial, xcb.XCB_ATOM_CARDINAL, 32, 12, &strut);

    const wm_window_type = try utils.getAtom(conn, "_NET_WM_WINDOW_TYPE");
    const wm_window_type_dock = try utils.getAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK");
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, window,
        wm_window_type, xcb.XCB_ATOM_ATOM, 32, 1, &[_]u32{wm_window_type_dock});

    const wm_state = try utils.getAtom(conn, "_NET_WM_STATE");
    const wm_state_above = try utils.getAtom(conn, "_NET_WM_STATE_ABOVE");
    const wm_state_sticky = try utils.getAtom(conn, "_NET_WM_STATE_STICKY");
    const state_values = [_]u32{ wm_state_above, wm_state_sticky };
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, window,
        wm_state, xcb.XCB_ATOM_ATOM, 32, 2, &state_values);
}

pub inline fn getBarWindow() u32 {
    return if (state) |s| s.window else 0;
}

pub inline fn isBarWindow(win: u32) bool {
    return if (state) |s| s.window == win else false;
}

pub inline fn markDirty() void {
    if (state) |s| s.markDirty();
}

pub inline fn raiseBar() void {
    if (state) |s| {
        _ = xcb.xcb_configure_window(s.conn, s.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
}

pub fn toggleBar(wm: *defs.WM) void {
    if (state) |s| {
        wm.config.bar.show = !wm.config.bar.show;
        
        if (wm.config.bar.show) {
            _ = xcb.xcb_map_window(s.conn, s.window);
            utils.flush(wm.conn);
            
            _ = c.XSync(@ptrCast(s.dc.display), 0);
            
            draw(s, wm) catch {};
            std.log.info("[bar] Bar shown", .{});
        } else {
            _ = xcb.xcb_unmap_window(s.conn, s.window);
            std.log.info("[bar] Bar hidden", .{});
        }
        
        utils.flush(wm.conn);
        @import("tiling").retileCurrentWorkspace(wm);
    }
}

pub fn isBarVisible() bool {
    return state != null;
}

pub fn hideForFullscreen(wm: *defs.WM) void {
    if (state) |s| {
        _ = xcb.xcb_unmap_window(s.conn, s.window);
        utils.flush(wm.conn);
        std.log.info("[bar] Bar hidden (fullscreen)", .{});
        @import("tiling").retileCurrentWorkspace(wm);
    }
}

pub fn showForFullscreen(wm: *defs.WM) void {
    if (state) |s| {
        if (wm.config.bar.show) {
            _ = xcb.xcb_map_window(s.conn, s.window);
            draw(s, wm) catch {};
            utils.flush(wm.conn);
            std.log.info("[bar] Bar shown (exit fullscreen)", .{});
            @import("tiling").retileCurrentWorkspace(wm);
        }
    }
}

pub fn getBarHeight() u16 {
    return if (state) |s| s.height else 0;
}

pub fn updateIfDirty(wm: *defs.WM) !void {
    if (state) |s| {
        checkClockUpdateInternal(s);
        
        if (s.isDirty()) {
            if (s.dirty) {
                try draw(s, wm);
            } else if (s.dirty_clock) {
                try drawClockOnly(s, wm);
            }
            s.clearDirty();
        }
    }
}

fn checkClockUpdateInternal(s: *State) void {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return;
    const current_second = ts.sec;
    
    if (current_second != s.last_second) {
        s.last_second = current_second;
        s.markClockDirty();
    }
}

pub fn checkClockUpdate() !void {
    if (state) |s| {
        checkClockUpdateInternal(s);
    }
}

fn drawClockOnly(s: *State, wm: *defs.WM) !void {
    for (s.config.layout.items) |layout| {
        if (layout.position == .right) {
            var right_x: u16 = s.width;
            var i: usize = layout.segments.items.len;
            while (i > 0) {
                i -= 1;
                const segment = layout.segments.items[i];
                const seg_width = calculateSegmentWidth(s, wm, segment);
                right_x -= seg_width;
                
                if (segment == .clock) {
                    _ = try clock_segment.draw(s.dc, s.config, s.height, right_x);
                    s.dc.flush();
                    return;
                }
                
                if (i > 0) {
                    right_x -= s.config.spacing;
                }
            }
        }
    }
    
    try draw(s, wm);
}

pub inline fn getHeight() u16 {
    return if (state) |s| s.height else 0;
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t, wm: *defs.WM) void {
    if (state) |s| {
        if (event.window == s.window and event.count == 0) {
            draw(s, wm) catch {};
        }
    }
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void {
    if (state) |s| {
        if (event.window == wm.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
            status_segment.update(wm, &s.status_text, s.allocator) catch {};
            s.markDirty();
        }
    }
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void {
    if (state) |s| {
        if (event.event == s.window) {
            handleClick(s, wm, event.event_x);
        }
    }
}

fn handleClick(s: *State, wm: *defs.WM, x: i16) void {
    const ws_state = workspaces.getState() orelse return;
    const ws_count = ws_state.workspaces.len;

    const clicked_ws: usize = @intCast(@max(0, @divFloor(x, WORKSPACE_WIDTH)));

    if (clicked_ws < ws_count) {
        workspaces.switchTo(wm, clicked_ws);
        s.markDirty();
    }
}

// OPTIMIZATION: Single-pass layout rendering with cached widths
fn draw(s: *State, wm: *defs.WM) !void {
    if (!s.isAlive()) return error.BarNotAlive;

    s.dc.fillRect(0, 0, s.width, s.height, s.config.bg);

    // OPTIMIZATION: Calculate all widths in single pass
    var left_width: u16 = 0;
    var right_width: u16 = 0;
    
    for (s.config.layout.items) |layout| {
        switch (layout.position) {
            .left => {
                for (layout.segments.items) |segment| {
                    left_width += calculateSegmentWidth(s, wm, segment) + s.config.spacing;
                }
                if (layout.segments.items.len > 0) left_width -= s.config.spacing;
            },
            .right => {
                for (layout.segments.items) |segment| {
                    right_width += calculateSegmentWidth(s, wm, segment) + s.config.spacing;
                }
                if (layout.segments.items.len > 0) right_width -= s.config.spacing;
            },
            .center => {},
        }
    }

    // Draw all segments
    var x: u16 = 0;
    for (s.config.layout.items) |layout| {
        switch (layout.position) {
            .left => {
                for (layout.segments.items) |segment| {
                    x = try drawSegment(s, wm, segment, x, s.config.getWorkspaceAccent(), null);
                    x += s.config.spacing;
                }
            },
            .center => {
                const space_for_right = if (right_width > 0) right_width + s.config.spacing else 0;
                const remaining = if (s.width > x + space_for_right) s.width - x - space_for_right else 100;
                
                for (layout.segments.items) |segment| {
                    if (segment == .title) {
                        _ = try drawSegment(s, wm, segment, x, s.config.getTitleAccent(), remaining);
                    } else {
                        const w = calculateSegmentWidth(s, wm, segment);
                        x = try drawSegment(s, wm, segment, x, s.config.getTitleAccent(), w);
                        x += s.config.spacing;
                    }
                }
            },
            .right => {
                var right_x: u16 = s.width;
                var i = layout.segments.items.len;
                while (i > 0) : (i -= 1) {
                    const segment = layout.segments.items[i - 1];
                    const w = calculateSegmentWidth(s, wm, segment);
                    right_x -= w;
                    _ = try drawSegment(s, wm, segment, right_x, s.config.getClockAccent(), w);
                    if (i > 1) right_x -= s.config.spacing;
                }
            },
        }
    }

    s.dc.flush();
}

fn calculateSegmentWidth(s: *State, wm: *defs.WM, segment: defs.BarSegment) u16 {
    _ = wm;
    return switch (segment) {
        .workspaces => blk: {
            const ws_state = workspaces.getState() orelse break :blk 270;
            break :blk @intCast(ws_state.workspaces.len * WORKSPACE_WIDTH);
        },
        .layout => 60,
        .title => 100,
        .clock => s.cached_clock_width,
    };
}

fn drawSegment(s: *State, wm: *defs.WM, segment: defs.BarSegment, x: u16, accent: u32, width: ?u16) !u16 {
    _ = accent;
    const seg_width = width orelse calculateSegmentWidth(s, wm, segment);
    return switch (segment) {
        .workspaces => try workspaces_segment.draw(s.dc, s.config, s.height, x),
        .layout => try layout_segment.draw(s.dc, s.config, s.height, x),
        .title => try title_segment.draw(s.dc, s.config, s.height, x, seg_width, wm, &s.cached_title, &s.cached_title_window, s.allocator),
        .clock => try clock_segment.draw(s.dc, s.config, s.height, x),
    };
}
