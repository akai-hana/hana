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

    // Skip if window already mapped
    if (wm.windows.contains(window)) {
        if (builtin.mode == .Debug) {
            std.debug.print("[window] Window {x} already mapped\n", .{window});
        }
        return;
    }

    // Query window geometry asynchronously
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null);
    defer if (geom_reply != null) std.c.free(geom_reply);

    var win = defs.Window{
        .id = window,
        .x = if (geom_reply) |g| g.*.x else 0,
        .y = if (geom_reply) |g| g.*.y else 0,
        .width = if (geom_reply) |g| @intCast(g.*.width) else 800,   // <-- FIXED: Use window's size
        .height = if (geom_reply) |g| @intCast(g.*.height) else 600, // <-- FIXED: Use window's size
        .is_focused = false,
        .properties = .{},
    };

    // Query window properties (async, no flush needed)
    win.properties = queryWindowProperties(wm, window) catch .{};

    // Add to window HashMap
    wm.putWindow(win) catch |err| {
        std.log.err("Failed to track window: {}", .{err});
        return;
    };

    // Configure window geometry before mapping
    const init_values = [_]u32{
        @intCast(win.x),
        @intCast(win.y),
        @intCast(win.width),
        @intCast(win.height),
        0, // border width
    };

    _ = xcb.xcb_configure_window(
        wm.conn,
        window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y | 
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &init_values
    );

    // Map the window
    _ = xcb.xcb_map_window(wm.conn, window);
    
    // Flush only once for the entire map operation
    _ = xcb.xcb_flush(wm.conn);

    if (builtin.mode == .Debug) {
        std.debug.print("[window] Mapped window: {}x{} at ({},{})\n",
            .{win.width, win.height, win.x, win.y});
    }
}

fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const window = event.window;

    // Use the REQUESTED values, not forced fullscreen
    const values = [_]u32{
        if (event.value_mask & xcb.XCB_CONFIG_WINDOW_X != 0) @intCast(event.x) else 0,
        if (event.value_mask & xcb.XCB_CONFIG_WINDOW_Y != 0) @intCast(event.y) else 0,
        if (event.value_mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0) @intCast(event.width) else 800,
        if (event.value_mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0) @intCast(event.height) else 600,
        if (event.value_mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0) @intCast(event.border_width) else 0,
    };

    _ = xcb.xcb_configure_window(
        wm.conn,
        window,
        event.value_mask,
        &values
    );

    // Update tracking
    if (wm.windows.getPtr(window)) |win| {
        win.x = @intCast(values[0]);
        win.y = @intCast(values[1]);
        win.width = @intCast(values[2]);
        win.height = @intCast(values[3]);
    }

    // Send accurate ConfigureNotify
    var notify_event: xcb.xcb_configure_notify_event_t = undefined;
    notify_event.response_type = xcb.XCB_CONFIGURE_NOTIFY;
    notify_event.event = window;
    notify_event.window = window;
    notify_event.above_sibling = xcb.XCB_NONE;
    notify_event.x = @intCast(values[0]);
    notify_event.y = @intCast(values[1]);
    notify_event.width = @intCast(values[2]);
    notify_event.height = @intCast(values[3]);
    notify_event.border_width = @intCast(values[4]);
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
            .{window, values[2], values[3], values[0], values[1]});
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
