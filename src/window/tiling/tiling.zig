// Central tiling manager - delegates to specific layout algorithms
const std     = @import("std");
const defs    = @import("defs");
const builtin = @import("builtin");
const log     = @import("logging");
const window  = @import("window");
const xcb     = defs.xcb;
const WM      = defs.WM;

// Import shared types
const types = @import("types");
pub const Layout = types.Layout;
pub const TilingState = types.TilingState;

// Import layout modules
const master_left = @import("master-left");
const monocle     = @import("monocle");
const grid        = @import("grid");

var tiling_state: ?*TilingState = null;

fn parseLayout(layout_str: []const u8) Layout {
    if (std.mem.eql(u8, layout_str, "monocle")) return .monocle;
    if (std.mem.eql(u8, layout_str, "grid")) return .grid;
    if (std.mem.eql(u8, layout_str, "master_left")) return .master_left;

    // Try case-insensitive matching
    var buf: [32]u8 = undefined;
    if (layout_str.len > buf.len) return .master_left;

    const lower = std.ascii.lowerString(&buf, layout_str);
    if (std.mem.eql(u8, lower, "monocle")) return .monocle;
    if (std.mem.eql(u8, lower, "grid")) return .grid;

    log.warnTilingUnknownLayout(layout_str);
    return .master_left;
}

pub fn init(wm: *WM) void {
    const state = wm.allocator.create(TilingState) catch {
        log.errorTilingStateAllocationFailed();
        return;
    };

    state.tiled_windows = .{};
    state.enabled = wm.config.tiling.enabled;
    state.layout = parseLayout(wm.config.tiling.layout);
    state.master_width_factor = wm.config.tiling.master_width_factor;
    state.master_count = wm.config.tiling.master_count;
    state.gaps = wm.config.tiling.gaps;
    state.border_width = wm.config.tiling.border_width;
    state.border_focused = wm.config.tiling.border_focused;
    state.border_normal = wm.config.tiling.border_normal;

    tiling_state = state;

    // Print configuration using generic logging functions
    log.debugTilingModuleInit();
    log.debugTilingStateValue("Enabled", "{}", .{state.enabled});
    log.debugTilingStateValue("Layout", "{s} (from config: '{s}')", .{@tagName(state.layout), wm.config.tiling.layout});
    log.debugTilingStateValue("Master count", "{}", .{state.master_count});
    log.debugTilingStateValue("Master width factor", "{d:.2}%", .{state.master_width_factor * 100});
    log.debugTilingStateValue("Gaps", "{}px", .{state.gaps});
    log.debugTilingStateValue("Border width", "{}px", .{state.border_width});
    log.debugTilingStateValue("Border focused", "#0x{x:0>6}", .{state.border_focused});
    log.debugTilingStateValue("Border normal", "#0x{x:0>6}", .{state.border_normal});
    log.debugTilingModuleEnd();
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
            const ev: *const xcb.xcb_map_request_event_t = @ptrCast(@alignCast(event));
            handleMapRequest(ev, wm, state);
        },
        xcb.XCB_CONFIGURE_REQUEST => {
            const ev: *const xcb.xcb_configure_request_event_t = @ptrCast(@alignCast(event));
            handleConfigureRequest(ev, wm, state);
        },
        xcb.XCB_DESTROY_NOTIFY => {
            const ev: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
            handleRemoveWindow(ev.window, wm, state);
        },
        xcb.XCB_UNMAP_NOTIFY => {
            const ev: *const xcb.xcb_unmap_notify_event_t = @ptrCast(@alignCast(event));
            handleRemoveWindow(ev.window, wm, state);
        },
        xcb.XCB_FOCUS_IN => {
            const ev: *const xcb.xcb_focus_in_event_t = @ptrCast(@alignCast(event));
            updateBorderColors(ev.event, wm, state);
        },
        else => {},
    }
}

fn updateBorderColors(focused_window: u32, wm: *WM, state: *TilingState) void {
    // OPTIMIZATION: Only update borders that actually changed
    for (state.tiled_windows.items) |win| {
        const color = if (win == focused_window) state.border_focused else state.border_normal;
        // Batch all border changes without flushing
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    }
    // Single flush for all border updates
    _ = xcb.xcb_flush(wm.conn);
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM, state: *TilingState) void {
    // Check if window is already in the tiling list
    for (state.tiled_windows.items) |win| {
        if (win == event.window) {
            _ = xcb.xcb_map_window(wm.conn, event.window);
            _ = xcb.xcb_flush(wm.conn);
            return;
        }
    }
    
    // Insert at the beginning (new window becomes master)
    state.tiled_windows.insert(wm.allocator, 0, event.window) catch {
        log.errorTilingWindowAddFailed();
        return;
    };

    // OPTIMIZATION: Batch all window setup operations
    // Set up event mask and border in one go
    const mask_values = [_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW};
    _ = xcb.xcb_change_window_attributes(wm.conn, event.window,
        xcb.XCB_CW_EVENT_MASK, &mask_values);

    const border_values = [_]u32{state.border_focused};
    _ = xcb.xcb_change_window_attributes(wm.conn, event.window,
        xcb.XCB_CW_BORDER_PIXEL, &border_values);

    const border_width_values = [_]u32{state.border_width};
    _ = xcb.xcb_configure_window(wm.conn, event.window,
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &border_width_values);

    // Map the window
    _ = xcb.xcb_map_window(wm.conn, event.window);

    // Set focus to the newly mapped window
    _ = xcb.xcb_set_input_focus(
        wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        event.window,
        xcb.XCB_CURRENT_TIME
    );

    wm.focused_window = event.window;

    // OPTIMIZATION: Retile and flush together
    retile(wm, state);
    
    // Query pointer position after retiling (single round-trip)
    const pointer_cookie = xcb.xcb_query_pointer(wm.conn, wm.root);
    _ = xcb.xcb_flush(wm.conn);  // Flush once after all operations
    
    if (xcb.xcb_query_pointer_reply(wm.conn, pointer_cookie, null)) |reply| {
        defer std.c.free(reply);
        
        if (reply.*.child != 0 and reply.*.child != event.window) {
            window.ignoreWindowForFocus(reply.*.child);
        }
    }

    if (builtin.mode == .Debug) {
        log.debugTilingWindowAdded(event.window, state.tiled_windows.items.len);
    }
}

fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM, state: *TilingState) void {
    // Check if this window is tiled
    var is_tiled = false;
    for (state.tiled_windows.items) |win| {
        if (win == event.window) {
            is_tiled = true;
            break;
        }
    }

    if (is_tiled) {
        // OPTIMIZATION: For tiled windows, we can often skip retiling
        // The layout will handle positioning, so just ignore the request
        if (builtin.mode == .Debug) {
            log.debugTilingConfigIgnored(event.window);
        }
        // Don't retile here - it's wasteful. The window will be positioned correctly already.
    } else {
        // For non-tiled windows, allow the configuration
        const values = [_]u32{
            @as(u32, @intCast(@max(0, event.x))),
            @as(u32, @intCast(@max(0, event.y))),
            event.width,
            event.height,
        };
        _ = xcb.xcb_configure_window(wm.conn, event.window,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
            &values);
        _ = xcb.xcb_flush(wm.conn);
    }
}

fn handleRemoveWindow(window_id: u32, wm: *WM, state: *TilingState) void {
    var found = false;
    for (state.tiled_windows.items, 0..) |win, i| {
        if (win == window_id) {
            _ = state.tiled_windows.orderedRemove(i);
            found = true;
            break;
        }
    }
    if (!found) return;

    // If the focused window was removed, try to focus another window
    const was_focused = wm.focused_window == window_id;
    if (was_focused) {
        wm.focused_window = null;
        
        // Focus the first window in the list (the current master)
        if (state.tiled_windows.items.len > 0) {
            const next_window = state.tiled_windows.items[0];
            _ = xcb.xcb_set_input_focus(
                wm.conn,
                xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
                next_window,
                xcb.XCB_CURRENT_TIME
            );
            wm.focused_window = next_window;
        }
    }

    if (state.tiled_windows.items.len > 0) {
        retile(wm, state);
    }
    
    // Single flush after all operations
    _ = xcb.xcb_flush(wm.conn);

    if (builtin.mode == .Debug) {
        log.debugTilingWindowRemoved(window_id, state.tiled_windows.items.len);
    }
}

fn retile(wm: *WM, state: *TilingState) void {
    const windows = state.tiled_windows.items;
    if (windows.len == 0) return;

    const screen = wm.screen;
    const screen_width = screen.width_in_pixels;
    const screen_height = screen.height_in_pixels;

    // Delegate to the active layout
    switch (state.layout) {
        .master_left => master_left.tile(wm, state, windows, screen_width, screen_height),
        .monocle => monocle.tile(wm, state, windows, screen_width, screen_height),
        .grid => grid.tile(wm, state, windows, screen_width, screen_height),
    }

    // Update border colors after retiling
    if (wm.focused_window) |focused| {
        // OPTIMIZATION: Border updates already batch and flush internally
        updateBorderColors(focused, wm, state);
    } else {
        // If no focus, still need to flush the retiling operations
        _ = xcb.xcb_flush(wm.conn);
    }
}

// Public API for keybindings
pub fn toggleLayout(wm: *WM) void {
    const state = tiling_state orelse return;

    state.layout = switch (state.layout) {
        .master_left => .monocle,
        .monocle => .grid,
        .grid => .master_left,
    };

    if (builtin.mode == .Debug) {
        log.debugTilingLayoutChange(@tagName(state.layout));
    }

    retile(wm, state);
}

pub fn increaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    const old_factor = state.master_width_factor;
    state.master_width_factor = @min(0.95, state.master_width_factor + 0.05);
    log.debugTilingMasterWidthChange(old_factor, state.master_width_factor);
    retile(wm, state);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    const old_factor = state.master_width_factor;
    state.master_width_factor = @max(0.05, state.master_width_factor - 0.05);
    log.debugTilingMasterWidthChange(old_factor, state.master_width_factor);
    retile(wm, state);
}

pub fn increaseMasterCount(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_count = @min(state.tiled_windows.items.len, state.master_count + 1);
    retile(wm, state);
}

pub fn decreaseMasterCount(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_count = @max(1, state.master_count - 1);
    retile(wm, state);
}

pub fn toggleTiling(wm: *WM) void {
    const state = tiling_state orelse return;
    state.enabled = !state.enabled;

    if (builtin.mode == .Debug) {
        log.debugTilingStatusChange(state.enabled);
    }

    if (state.enabled) {
        retile(wm, state);
    }
}

// Public API for other modules to notify about focus changes
pub fn updateWindowFocus(wm: *WM, focused_window: u32) void {
    const state = tiling_state orelse return;
    if (!state.enabled) return;
    updateBorderColors(focused_window, wm, state);
}

/// Check if a window is being managed by the tiling system
pub fn isWindowTiled(window_id: u32) bool {
    const state = tiling_state orelse return false;
    if (!state.enabled) return false;

    for (state.tiled_windows.items) |win| {
        if (win == window_id) return true;
    }
    return false;
}

/// Reload configuration - update tiling state from WM config
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

    if (builtin.mode == .Debug) {
        log.debugConfigReloaded();
    }

    // Retile with new settings
    if (state.enabled) {
        retile(wm, state);
    }
}

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_UNMAP_NOTIFY,
    xcb.XCB_FOCUS_IN,
};

pub fn createModule() defs.Module {
    return defs.Module{
        .name = "tiling",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
        .deinit_fn = deinit,
    };
}
