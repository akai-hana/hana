// Window management
// This is the minimum code needed to make windows appear inside the WM.

// It handles the following events:
// - When an app wants to create a window (`MAP_REQUEST`)
// - When a window is closed (`DESTROY_NOTIFY`)
// - When mouse enters a window (`ENTER_NOTIFY`)
// - When a window gains focus (`FOCUS_IN`)

const std = @import("std");
const defs = @import("defs");

// Use xcb from defs to avoid type conflicts
const xcb = defs.xcb;

const WM = defs.WM;
const Module = defs.Module;

// Events this module handles
pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_ENTER_NOTIFY,
    xcb.XCB_FOCUS_IN,
};

pub fn init(_: *WM) void {
    std.debug.print("[window] Module initialized\n", .{});
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

    std.debug.print("[window] Map request for window {x}\n", .{window});

    // Query window geometry
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null);
    defer if (geom_reply != null) std.c.free(geom_reply);

    var win = defs.Window{
        .id = window,
        .x = if (geom_reply) |g| g.*.x else 0,
        .y = if (geom_reply) |g| g.*.y else 0,
        .width = 2560, // Minimal default, will be set by ConfigureRequest
        .height = 1600,
        .is_focused = false,
        .properties = .{},
    };

    // Query window properties
    win.properties = queryWindowProperties(wm, window) catch .{};

    // Add to window HashMap O(1) insertion
    wm.putWindow(win) catch |err| {
        std.debug.print("[window] Failed to track window: {}\n", .{err});
    };

    // Give the window its initial geometry BEFORE mapping
    // This ensures it knows its size before doing any pointer grabs
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

    // Map the window (make it visible)
    _ = xcb.xcb_map_window(wm.conn, window);
    _ = xcb.xcb_flush(wm.conn);

    std.debug.print("[window] Mapped window with initial geometry: {}x{} at ({},{})\n",
    .{win.width, win.height, win.x, win.y});
}

fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const window = event.window;

    // Override the application's request with our own geometry
    // Force fullscreen for now (you'll add tiling logic later)
    const forced_x: i16 = 0;
    const forced_y: i16 = 0;
    const forced_width: u16 = 2560;
    const forced_height: u16 = 1600;

    const values = [_]u32{
        @intCast(forced_x),
        @intCast(forced_y),
        @intCast(forced_width),
        @intCast(forced_height),
        0, // border width
    };

    // Apply OUR geometry, not what the app requested
    _ = xcb.xcb_configure_window(
        wm.conn,
        window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &values
    );

    // Update our tracking
    if (wm.windows.getPtr(window)) |win| {
        win.x = forced_x;
        win.y = forced_y;
        win.width = forced_width;
        win.height = forced_height;
    }

    // Send a synthetic ConfigureNotify with OUR geometry
    var notify_event: xcb.xcb_configure_notify_event_t = undefined;
    notify_event.response_type = xcb.XCB_CONFIGURE_NOTIFY;
    notify_event.event = window;
    notify_event.window = window;
    notify_event.above_sibling = xcb.XCB_NONE;
    notify_event.x = forced_x;
    notify_event.y = forced_y;
    notify_event.width = forced_width;
    notify_event.height = forced_height;
    notify_event.border_width = 0;
    notify_event.override_redirect = 0;

    _ = xcb.xcb_send_event(
        wm.conn,
        0,
        window,
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
        @ptrCast(&notify_event)
    );

    _ = xcb.xcb_flush(wm.conn);

    std.debug.print("[window] Configure request for window {x}: forced to {}x{} at ({},{})\n",
        .{window, forced_width, forced_height, forced_x, forced_y});
}

fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    std.debug.print("[window] Window {x} destroyed\n", .{event.window});

    // Remove from window HashMap - O(1) removal with cleanup
    wm.removeWindow(event.window);

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

    std.debug.print("[window] Focus in: {x}\n", .{window});
}

fn focusWindow(wm: *WM, window: u32) void {
    // Update focused state in all windows - iterate HashMap
    var iter = wm.windows.valueIterator();
    while (iter.next()) |win| {
        win.is_focused = (win.id == window);
    }

    wm.focused_window = window;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, window, xcb.XCB_CURRENT_TIME);
}

fn queryWindowProperties(wm: *WM, window: u32) !defs.WindowProperties {
    var props = defs.WindowProperties{};

    // Query WM_NAME
    const name_atom = getAtom(wm, "WM_NAME");
    const name_cookie = xcb.xcb_get_property(wm.conn, 0, window, name_atom, xcb.XCB_GET_PROPERTY_TYPE_ANY, 0, 1024);
    const name_reply = xcb.xcb_get_property_reply(wm.conn, name_cookie, null);
    if (name_reply) |reply| {
        defer std.c.free(reply);
        const len = xcb.xcb_get_property_value_length(reply);
        if (len > 0) {
            const value: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
            props.name = try wm.allocator.dupe(u8, value[0..@intCast(len)]);
        }
    }

    // Query WM_CLASS
    const class_atom = getAtom(wm, "WM_CLASS");
    const class_cookie = xcb.xcb_get_property(wm.conn, 0, window, class_atom, xcb.XCB_GET_PROPERTY_TYPE_ANY, 0, 1024);
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
