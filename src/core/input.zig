// Input handling - keyboard and mouse events

const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const logging = @import("logging");

const c = @cImport({
    @cInclude("unistd.h");
});

const xcb = defs.xcb;
const WM = defs.WM;
const Module = defs.Module;

// Handle both keyboard and mouse events
pub const EVENT_TYPES = [_]u8{
    xcb.XCB_KEY_PRESS,
    xcb.XCB_BUTTON_PRESS,
    xcb.XCB_BUTTON_RELEASE,
    xcb.XCB_MOTION_NOTIFY,
};

var keybind_map: std.AutoHashMap(u64, *const defs.Action) = undefined;
var keybind_initialized = false;

// TinyWM-style drag state
var start_button: u8 = 0;
var start_subwindow: u32 = 0;
var start_x: i16 = 0;
var start_y: i16 = 0;
var attr_x: i16 = 0;
var attr_y: i16 = 0;
var attr_width: u16 = 0;
var attr_height: u16 = 0;

pub fn init(wm: *WM) void {
    keybind_map = std.AutoHashMap(u64, *const defs.Action).init(wm.allocator);
    buildKeybindMap(wm) catch |err| {
        std.log.err("Failed to build keybind map: {}", .{err});
        return;
    };
    keybind_initialized = true;
    logging.debugInputModuleInit(keybind_map.count());
}

pub fn deinit(_: *WM) void {
    if (keybind_initialized) {
        keybind_map.deinit();
        keybind_initialized = false;
    }
}

fn buildKeybindMap(wm: *WM) !void {
    keybind_map.clearRetainingCapacity();

    for (wm.config.keybindings.items) |*keybind| {
        const key = makeKeybindKey(keybind.modifiers, keybind.keysym);
        try keybind_map.put(key, &keybind.action);
    }
}

inline fn makeKeybindKey(modifiers: u16, keysym: u32) u64 {
    return (@as(u64, modifiers) << 32) | keysym;
}

/// Setup TinyWM-style mouse grabs (currently disabled for testing)
pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    // Don't grab anything - let's test if grabs are the problem
    _ = conn;
    _ = root;

    // If this fixes the jank, then the grabs are interfering
    // If jank persists, the problem is elsewhere
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_KEY_PRESS => handleKeyPress(
            @as(*const xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event))),
            wm
        ),
        xcb.XCB_BUTTON_PRESS => handleButtonPress(
            @as(*const xcb.xcb_button_press_event_t, @alignCast(@ptrCast(event))),
            wm
        ),
        xcb.XCB_MOTION_NOTIFY => handleMotionNotify(
            @as(*const xcb.xcb_motion_notify_event_t, @alignCast(@ptrCast(event))),
            wm
        ),
        xcb.XCB_BUTTON_RELEASE => handleButtonRelease(
            @as(*const xcb.xcb_button_release_event_t, @alignCast(@ptrCast(event))),
            wm
        ),
        else => {},
    }
}

fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    // TinyWM: raise window on keypress
    if (event.child != 0) {
        const values = [_]u32{xcb.XCB_STACK_MODE_ABOVE};
        _ = xcb.xcb_configure_window(
            wm.conn, event.child, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &values,
        );
    }

    // Handle keybinding
    const keycode = event.detail;
    const raw_modifiers: u16 = @intCast(event.state);
    const modifiers = raw_modifiers & defs.MOD_MASK_RELEVANT;

    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));
    const keysym = xkb_ptr.keycodeToKeysym(keycode);

    const key = makeKeybindKey(modifiers, keysym);

    if (keybind_map.get(key)) |action| {
        logging.debugKeybindingMatched(modifiers, keysym);
        executeAction(action, wm) catch |err| {
            std.log.err("Failed to execute keybinding action: {}", .{err});
        };
        return;
    }

    logging.debugUnboundKey(keycode, keysym, modifiers, raw_modifiers);
}

fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    if (event.child == 0) return;

    logging.debugMouseButtonClick(event.detail, event.root_x, event.root_y, event.child);

    // TinyWM: Get window geometry and save start position
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, event.child);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null);
    if (geom_reply) |g| {
        defer std.c.free(g);
        attr_x = g.*.x;
        attr_y = g.*.y;
        attr_width = g.*.width;
        attr_height = g.*.height;
    }

    start_subwindow = event.child;
    start_button = event.detail;
    start_x = event.root_x;
    start_y = event.root_y;
}

fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    if (start_subwindow == 0) return;

    logging.debugDragMotion(event.root_x, event.root_y);

    // TinyWM: calculate diff and move/resize
    const xdiff: i32 = @as(i32, event.root_x) - @as(i32, start_x);
    const ydiff: i32 = @as(i32, event.root_y) - @as(i32, start_y);

    const new_x = if (start_button == 1) attr_x + @as(i16, @intCast(xdiff)) else attr_x;
    const new_y = if (start_button == 1) attr_y + @as(i16, @intCast(ydiff)) else attr_y;
    const new_w = if (start_button == 3) @max(1, @as(i32, attr_width) + xdiff) else attr_width;
    const new_h = if (start_button == 3) @max(1, @as(i32, attr_height) + ydiff) else attr_height;

    _ = xcb.xcb_configure_window(
        wm.conn, start_subwindow,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &[_]u32{
            @intCast(new_x), @intCast(new_y),
            @intCast(new_w), @intCast(new_h),
        },
    );
}

fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t, wm: *WM) void {
    _ = event;
    _ = wm;
    
    logging.debugMouseButtonRelease(start_button);
    start_subwindow = 0; // TinyWM: start.subwindow = None
}

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .exec => |cmd| {
            logging.debugExecutingCommand(cmd);

            const pid = c.fork();
            if (pid == 0) {
                _ = c.setsid();

                const cmd_z = try wm.allocator.dupeZ(u8, cmd);
                defer wm.allocator.free(cmd_z);

                const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
                _ = c.execvp("/bin/sh", @ptrCast(&argv));

                std.log.err("Failed to exec: {s}", .{cmd});
                std.process.exit(1);
            } else if (pid < 0) {
                std.log.err("Fork failed for command: {s}", .{cmd});
            }
        },
        .close_window => {
            if (wm.focused_window) |win_id| {
                logging.debugClosingWindow(win_id);
                _ = xcb.xcb_destroy_window(wm.conn, win_id);
                _ = xcb.xcb_flush(wm.conn);
            }
        },
        .reload_config => {
            logging.debugConfigReloadTriggered();
            buildKeybindMap(wm) catch |err| {
                std.log.err("Failed to rebuild keybind map: {}", .{err});
            };
        },
        .focus_next, .focus_prev => {
            logging.debugFocusNotImplemented();
        },
    }
}

pub fn createModule() Module {
    return Module{
        .name = "input",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
