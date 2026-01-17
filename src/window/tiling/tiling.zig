// Central tiling manager - optimized for performance

const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const log = @import("logging");
const window = @import("window");
const xcb = defs.xcb;
const WM = defs.WM;

const types = @import("types");
pub const Layout = types.Layout;
pub const TilingState = types.TilingState;

const master_left = @import("master-left");
const monocle = @import("monocle");
const grid = @import("grid");

var tiling_state: ?*TilingState = null;

const LAYOUT_MAP = std.StaticStringMap(Layout).initComptime(.{
    .{ "monocle", .monocle },
    .{ "grid", .grid },
    .{ "master_left", .master_left },
});

fn parseLayout(layout_str: []const u8) Layout {
    if (LAYOUT_MAP.get(layout_str)) |layout| return layout;
    
    // Try lowercase
    var buf: [32]u8 = undefined;
    if (layout_str.len <= buf.len) {
        const lower = std.ascii.lowerString(&buf, layout_str);
        if (LAYOUT_MAP.get(lower)) |layout| return layout;
    }
    
    log.warnTilingUnknownLayout(layout_str);
    return .master_left;
}

pub fn init(wm: *WM) void {
    const state = wm.allocator.create(TilingState) catch {
        log.errorTilingStateAllocationFailed();
        return;
    };

    state.* = .{
        .tiled_windows = .{},
        .enabled = wm.config.tiling.enabled,
        .layout = parseLayout(wm.config.tiling.layout),
        .master_width_factor = wm.config.tiling.master_width_factor,
        .master_count = wm.config.tiling.master_count,
        .gaps = wm.config.tiling.gaps,
        .border_width = wm.config.tiling.border_width,
        .border_focused = wm.config.tiling.border_focused,
        .border_normal = wm.config.tiling.border_normal,
    };

    tiling_state = state;

    if (builtin.mode == .Debug) {
        log.debugTilingModuleInit();
        log.debugTilingStateValue("Enabled", "{}", .{state.enabled});
        log.debugTilingStateValue("Layout", "{s}", .{@tagName(state.layout)});
        log.debugTilingStateValue("Master count", "{}", .{state.master_count});
        log.debugTilingStateValue("Master width", "{d:.0}%", .{state.master_width_factor * 100});
        log.debugTilingStateValue("Gaps", "{}px", .{state.gaps});
        log.debugTilingStateValue("Border width", "{}px", .{state.border_width});
        log.debugTilingStateValue("Focused", "0x{x:0>6}", .{state.border_focused});
        log.debugTilingStateValue("Normal", "0x{x:0>6}", .{state.border_normal});
        log.debugTilingModuleEnd();
    }
}

pub fn deinit(wm: *WM) void {
    if (tiling_state) |state| {
        state.tiled_windows.deinit(wm.allocator);
        wm.allocator.destroy(state);
        tiling_state = null;
    }
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const state = tiling_state orelse return;
    if (!state.enabled) return;

    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => {
            const e: *const xcb.xcb_map_request_event_t = @ptrCast(@alignCast(event));
            handleMapRequest(e, wm, state);
        },
        xcb.XCB_CONFIGURE_REQUEST => {
            const e: *const xcb.xcb_configure_request_event_t = @ptrCast(@alignCast(event));
            if (isWindowTiled(e.window)) {
                if (builtin.mode == .Debug) log.debugTilingConfigIgnored(e.window);
            } else {
                // Allow floating window configuration
                _ = xcb.xcb_configure_window(wm.conn, e.window,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
                    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
                    &[_]u32{
                        @intCast(@max(0, e.x)),
                        @intCast(@max(0, e.y)),
                        e.width,
                        e.height,
                    });
                _ = xcb.xcb_flush(wm.conn);
            }
        },
        xcb.XCB_DESTROY_NOTIFY, xcb.XCB_UNMAP_NOTIFY => {
            const e: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
            handleRemoveWindow(e.window, wm, state);
        },
        xcb.XCB_FOCUS_IN => {
            const e: *const xcb.xcb_focus_in_event_t = @ptrCast(@alignCast(event));
            updateBorderColors(e.event, wm, state);
        },
        else => {},
    }
}

fn updateBorderColors(focused_window: u32, wm: *WM, state: *TilingState) void {
    for (state.tiled_windows.items) |win| {
        const color = if (win == focused_window) state.border_focused else state.border_normal;
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    }
    _ = xcb.xcb_flush(wm.conn);
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM, state: *TilingState) void {
    // Check if already tiled
    for (state.tiled_windows.items) |win| {
        if (win == event.window) {
            _ = xcb.xcb_map_window(wm.conn, event.window);
            _ = xcb.xcb_flush(wm.conn);
            return;
        }
    }

    // Add new window at front
    state.tiled_windows.insert(wm.allocator, 0, event.window) catch {
        log.errorTilingWindowAddFailed();
        return;
    };

    // Batch setup operations
    _ = xcb.xcb_change_window_attributes(wm.conn, event.window,
        xcb.XCB_CW_EVENT_MASK, &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});
    _ = xcb.xcb_change_window_attributes(wm.conn, event.window,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{state.border_focused});
    _ = xcb.xcb_configure_window(wm.conn, event.window,
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{state.border_width});
    _ = xcb.xcb_map_window(wm.conn, event.window);
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, event.window, xcb.XCB_CURRENT_TIME);

    wm.focused_window = event.window;

    retile(wm, state);

    if (builtin.mode == .Debug) {
        log.debugTilingWindowAdded(event.window, state.tiled_windows.items.len);
    }
}

fn handleRemoveWindow(window_id: u32, wm: *WM, state: *TilingState) void {
    var found_idx: ?usize = null;
    for (state.tiled_windows.items, 0..) |win, i| {
        if (win == window_id) {
            found_idx = i;
            break;
        }
    }
    
    const idx = found_idx orelse return;
    _ = state.tiled_windows.orderedRemove(idx);

    const was_focused = wm.focused_window == window_id;
    if (was_focused and state.tiled_windows.items.len > 0) {
        const next_window = state.tiled_windows.items[0];
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, next_window, xcb.XCB_CURRENT_TIME);
        wm.focused_window = next_window;
    } else if (was_focused) {
        wm.focused_window = null;
    }

    if (state.tiled_windows.items.len > 0) {
        retile(wm, state);
    } else {
        _ = xcb.xcb_flush(wm.conn);
    }

    if (builtin.mode == .Debug) {
        log.debugTilingWindowRemoved(window_id, state.tiled_windows.items.len);
    }
}

fn retile(wm: *WM, state: *TilingState) void {
    const windows = state.tiled_windows.items;
    if (windows.len == 0) return;

    const screen = wm.screen;

    // Dispatch to layout implementation
    switch (state.layout) {
        .master_left => master_left.tile(wm, state, windows, screen.width_in_pixels, screen.height_in_pixels),
        .monocle => monocle.tile(wm, state, windows, screen.width_in_pixels, screen.height_in_pixels),
        .grid => grid.tile(wm, state, windows, screen.width_in_pixels, screen.height_in_pixels),
    }

    // Update borders after layout
    if (wm.focused_window) |focused| {
        updateBorderColors(focused, wm, state);
    } else {
        _ = xcb.xcb_flush(wm.conn);
    }
}

// Public API
pub fn toggleLayout(wm: *WM) void {
    const state = tiling_state orelse return;
    state.layout = switch (state.layout) {
        .master_left => .monocle,
        .monocle => .grid,
        .grid => .master_left,
    };
    if (builtin.mode == .Debug) log.debugTilingLayoutChange(@tagName(state.layout));
    retile(wm, state);
}

pub fn increaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    const old = state.master_width_factor;
    state.master_width_factor = @min(0.95, old + 0.05);
    log.debugTilingMasterWidthChange(old, state.master_width_factor);
    retile(wm, state);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    const old = state.master_width_factor;
    state.master_width_factor = @max(0.05, old - 0.05);
    log.debugTilingMasterWidthChange(old, state.master_width_factor);
    retile(wm, state);
}

pub fn increaseMasterCount(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_count = @min(state.tiled_windows.items.len, state.master_count + 1);
    retile(wm, state);
}

pub fn decreaseMasterCount(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_count = @max(1, state.master_count -| 1);
    retile(wm, state);
}

pub fn toggleTiling(wm: *WM) void {
    const state = tiling_state orelse return;
    state.enabled = !state.enabled;
    if (builtin.mode == .Debug) log.debugTilingStatusChange(state.enabled);
    if (state.enabled) retile(wm, state);
}

pub fn updateWindowFocus(wm: *WM, focused_window: u32) void {
    const state = tiling_state orelse return;
    if (!state.enabled) return;
    updateBorderColors(focused_window, wm, state);
}

pub fn isWindowTiled(window_id: u32) bool {
    const state = tiling_state orelse return false;
    if (!state.enabled) return false;
    for (state.tiled_windows.items) |win| {
        if (win == window_id) return true;
    }
    return false;
}

pub fn reloadConfig(wm: *WM) void {
    const state = tiling_state orelse return;
    
    state.enabled = wm.config.tiling.enabled;
    state.layout = parseLayout(wm.config.tiling.layout);
    state.master_width_factor = wm.config.tiling.master_width_factor;
    state.master_count = wm.config.tiling.master_count;
    state.gaps = wm.config.tiling.gaps;
    state.border_width = wm.config.tiling.border_width;
    state.border_focused = wm.config.tiling.border_focused;
    state.border_normal = wm.config.tiling.border_normal;

    if (builtin.mode == .Debug) log.debugConfigReloaded();
    if (state.enabled) retile(wm, state);
}

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_UNMAP_NOTIFY,
    xcb.XCB_FOCUS_IN,
};
