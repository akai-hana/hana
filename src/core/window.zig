// Window management
// Handles window lifecycle: creation, configuration, destruction, focus

const std     = @import("std");
const defs    = @import("defs");
const builtin = @import("builtin");
const xcb     = defs.xcb;
const WM      = defs.WM;
const Module  = defs.Module;

// Events this module handles
pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_ENTER_NOTIFY,
    xcb.XCB_FOCUS_IN,
};

// Cached atoms (initialized at startup)
var cached_wm_name_atom: u32  = 0;
var cached_wm_class_atom: u32 = 0;

pub fn init(wm: *WM) void {
    // Cache commonly-used atoms to avoid repeated X11 round trips
    cached_wm_name_atom  = getAtom(wm, "WM_NAME");
    cached_wm_class_atom = getAtom(wm, "WM_CLASS");
    
    if (builtin.mode == .Debug) {
        std.debug.print("[window] Module initialized\n", .{});
    }
}

pub const deinit = defs.defaultModuleDeinit;

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_MAP_REQUEST => {
            const ev = @as(*xcb.xcb_map_request_event_t, @alignCast(@ptrCast(event)));
            handleMapRequest(ev, wm);
        },
        xcb.XCB_CONFIGURE_REQUEST => {
            const ev = @as(*xcb.xcb_configure_request_event_t, @alignCast(@ptrCast(event)));
            handleConfigureRequest(ev, wm);
        },
        xcb.XCB_DESTROY_NOTIFY => {
            const ev = @as(*xcb.xcb_destroy_notify_event_t, @alignCast(@ptrCast(event)));
            handleDestroyNotify(ev, wm);
        },
        xcb.XCB_ENTER_NOTIFY => {
            const ev = @as(*xcb.xcb_enter_notify_event_t, @alignCast(@ptrCast(event)));
            handleEnterNotify(ev, wm);
        },
        xcb.XCB_FOCUS_IN => {
            const ev = @as(*xcb.xcb_focus_in_event_t, @alignCast(@ptrCast(event)));
            handleFocusIn(ev, wm);
        },
        else => {},
    }
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const window = event.window;

    if (builtin.mode == .Debug) {
        std.debug.print("[window] Map request for window {x}\n", .{window});
    }

    if (wm.windows.contains(window)) {
        if (builtin.mode == .Debug) {
            std.debug.print("[window] Window {x} already mapped\n", .{window});
        }
        return;
    }

    // Query window geometry
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null);
    defer if (geom_reply != null) std.c.free(geom_reply);

    var win = defs.Window{
        .id = window,
        .x = if (geom_reply) |g| g.*.x else 0,
        .y = if (geom_reply) |g| g.*.y else 0,
        .width = if (geom_reply) |g| @intCast(g.*.width) else 800,
        .height = if (geom_reply) |g| @intCast(g.*.height) else 600,
        .is_focused = false,
        .properties = .{},
    };

    win.properties = queryWindowProperties(wm, window) catch .{};

    wm.putWindow(win) catch |err| {
        std.log.err("Failed to track window: {}", .{err});
        return;
    };

    // Just map the window - don't force configure!
    _ = xcb.xcb_map_window(wm.conn, window);

    _ = xcb.xcb_flush(wm.conn);

    if (builtin.mode == .Debug) {
        std.debug.print("[window] Mapped window: {}x{} at ({},{})\n",
            .{win.width, win.height, win.x, win.y});
    }
}

fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const window = event.window;

    // Get CURRENT window state for fields not in value_mask
    var current_x: i16 = 0;
    var current_y: i16 = 0;
    var current_width: u16 = 800;
    var current_height: u16 = 600;
    const current_border: u16 = 0;  // <-- Changed to const

    if (wm.windows.get(window)) |win| {
        current_x = @intCast(win.x);
        current_y = @intCast(win.y);
        current_width = @intCast(win.width);
        current_height = @intCast(win.height);
    }

    // Use REQUESTED values if present, otherwise keep CURRENT values
    const final_x = if (event.value_mask & xcb.XCB_CONFIG_WINDOW_X != 0) event.x else current_x;
    const final_y = if (event.value_mask & xcb.XCB_CONFIG_WINDOW_Y != 0) event.y else current_y;
    const final_width = if (event.value_mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0) event.width else current_width;
    const final_height = if (event.value_mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0) event.height else current_height;
    const final_border = if (event.value_mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0) event.border_width else current_border;

    const values = [_]u32{
        @intCast(final_x),
        @intCast(final_y),
        @intCast(final_width),
        @intCast(final_height),
        @intCast(final_border),
    };

    _ = xcb.xcb_configure_window(
        wm.conn,
        window,
        event.value_mask,
        &values
    );

    // Update tracking with ACTUAL values
    if (wm.windows.getPtr(window)) |win| {
        win.x = @intCast(final_x);
        win.y = @intCast(final_y);
        win.width = @intCast(final_width);
        win.height = @intCast(final_height);
    }

    // Send ConfigureNotify with ACTUAL values
    var notify_event: xcb.xcb_configure_notify_event_t = undefined;
    notify_event.response_type = xcb.XCB_CONFIGURE_NOTIFY;
    notify_event.event = window;
    notify_event.window = window;
    notify_event.above_sibling = xcb.XCB_NONE;
    notify_event.x = final_x;
    notify_event.y = final_y;
    notify_event.width = final_width;
    notify_event.height = final_height;
    notify_event.border_width = final_border;
    notify_event.override_redirect = 0;

    _ = xcb.xcb_send_event(
        wm.conn,
        0,
        window,
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
        @ptrCast(&notify_event)
    );

    if (builtin.mode == .Debug) {
        std.debug.print("[window] Configure: window {x} -> {}x{} at ({},{})\n",
            .{window, final_width, final_height, final_x, final_y});
    }
}

fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    if (builtin.mode == .Debug) {
        std.debug.print("[window] Window {x} destroyed\n", .{event.window});
    }

    // Remove from window HashMap
    _ = wm.windows.remove(event.window);

    // Clear focus if this was the focused window
    if (wm.focused_window) |fid| {
        if (fid == event.window) {
            wm.focused_window = null;
        }
    }
}

fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    const window = event.event;
    if (window == wm.root) return;

    focusWindow(wm, window);
}

fn handleFocusIn(event: *const xcb.xcb_focus_in_event_t, wm: *WM) void {
    const window = event.event;
    if (window == wm.root) return;

    if (builtin.mode == .Debug) {
        std.debug.print("[window] Focus in: {x}\n", .{window});
    }
}

fn focusWindow(wm: *WM, window: u32) void {
    // Update focus state
    if (wm.focused_window) |old| {
        if (wm.windows.getPtr(old)) |old_win| {
            old_win.is_focused = false;
        }
    }
    
    if (wm.windows.getPtr(window)) |new_win| {
        new_win.is_focused = true;
    }

    wm.focused_window = window;
    _ = xcb.xcb_set_input_focus(
        wm.conn, 
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT, 
        window, 
        xcb.XCB_CURRENT_TIME
    );
    
    // Flush to ensure focus change is immediate
    _ = xcb.xcb_flush(wm.conn);
}

fn queryWindowProperties(wm: *WM, window: u32) !defs.WindowProperties {
    var props = defs.WindowProperties{};

    // Query WM_NAME (async, using cached atom)
    const name_cookie = xcb.xcb_get_property(
        wm.conn, 0, window, cached_wm_name_atom, 
        xcb.XCB_GET_PROPERTY_TYPE_ANY, 0, 1024
    );
    const name_reply = xcb.xcb_get_property_reply(wm.conn, name_cookie, null);
    if (name_reply) |reply| {
        defer std.c.free(reply);
        const len = xcb.xcb_get_property_value_length(reply);
        if (len > 0) {
            const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
            props.name = try wm.allocator.dupe(u8, value[0..@intCast(len)]);
        }
    }

    // Query WM_CLASS (async, using cached atom)
    const class_cookie = xcb.xcb_get_property(
        wm.conn, 0, window, cached_wm_class_atom, 
        xcb.XCB_GET_PROPERTY_TYPE_ANY, 0, 1024
    );
    const class_reply = xcb.xcb_get_property_reply(wm.conn, class_cookie, null);
    if (class_reply) |reply| {
        defer std.c.free(reply);
        const len = xcb.xcb_get_property_value_length(reply);
        if (len > 0) {
            const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
            props.class = try wm.allocator.dupe(u8, value[0..@intCast(len)]);
        }
    }

    return props;
}

fn getAtom(wm: *WM, name: []const u8) u32 {
    const cookie = xcb.xcb_intern_atom(wm.conn, 0, @intCast(name.len), name.ptr);
    const reply = xcb.xcb_intern_atom_reply(wm.conn, cookie, null);
    if (reply) |r| {
        defer std.c.free(r);
        return r.*.atom;
    }
    return 0;
}

pub fn createModule() Module {
    return Module{
        .name = "window",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
