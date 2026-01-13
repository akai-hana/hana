// Input handling - FIXED: Don't intercept client window clicks!

const std            = @import("std");
const defs           = @import("defs");
const xkbcommon      = @import("xkbcommon");
const error_handling = @import("error_handling");
const logging        = @import("logging");

const c = @cImport({
    @cInclude("unistd.h");
});

const xcb = defs.xcb;
const WM = defs.WM;
const Module = defs.Module;

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_KEY_PRESS,
    xcb.XCB_KEY_RELEASE,
    xcb.XCB_BUTTON_PRESS,
};

var keybind_map: std.AutoHashMap(u64, *const defs.Action) = undefined;
var keybind_initialized = false;

var last_motion_time: u32 = 0;

pub fn init(wm: *WM) void {
    keybind_map = std.AutoHashMap(u64, *const defs.Action).init(wm.allocator);
    buildKeybindMap(wm) catch |err| {
        std.log.err("Failed to build keybind map: {}", .{err});
        return;
    };
    keybind_initialized = true;

    // FIX: Grab modifier+button on root for WM operations
    // This allows unmodified clicks to go directly to client windows
    grabMouseBindings(wm);

    logging.debugInputModuleInit(keybind_map.count());
}

pub fn deinit(_: *WM) void {
    if (keybind_initialized) {
        keybind_map.deinit();
        keybind_initialized = false;
    }
}

// NEW: Grab only modified button presses on root (like TinyWM)
fn grabMouseBindings(wm: *WM) void {
    // Example: Alt+Button1 for move, Alt+Button3 for resize
    // Adjust modifiers to match your needs
    const mod_mask = xcb.XCB_MOD_MASK_1; // Alt key
    
    // Grab Alt+LeftClick for window move
    _ = xcb.xcb_grab_button(
        wm.conn,
        0, // owner_events = false
        wm.root,
        xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.XCB_EVENT_MASK_POINTER_MOTION,
        xcb.XCB_GRAB_MODE_ASYNC,
        xcb.XCB_GRAB_MODE_ASYNC,
        xcb.XCB_NONE,
        xcb.XCB_NONE,
        1, // button 1 (left click)
        @intCast(mod_mask),
    );
    
    // Grab Alt+RightClick for window resize
    _ = xcb.xcb_grab_button(
        wm.conn,
        0,
        wm.root,
        xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.XCB_EVENT_MASK_POINTER_MOTION,
        xcb.XCB_GRAB_MODE_ASYNC,
        xcb.XCB_GRAB_MODE_ASYNC,
        xcb.XCB_NONE,
        xcb.XCB_NONE,
        3, // button 3 (right click)
        @intCast(mod_mask),
    );
    
    _ = xcb.xcb_flush(wm.conn);
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

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_KEY_PRESS => {
            const ev = @as(*const xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event)));
            handleKeyPress(ev, wm);
        },

        xcb.XCB_KEY_RELEASE => {
            // Key releases rarely need handling
        },

        xcb.XCB_BUTTON_PRESS => {
            const ev = @as(*const xcb.xcb_button_press_event_t, @alignCast(@ptrCast(event)));
            handleButtonPress(ev, wm);
        },

        else => {},
    }
}

fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
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

fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    const button = event.detail;
    const window = event.child;

    logging.debugMouseButtonClick(button, event.event_x, event.event_y, window);

    // FIX: We only receive modified clicks now (Alt+Button)
    // These are WM operations, not client clicks
    
    if (window == 0) {
        // Click on root/background - could launch menu, etc.
        return;
    }

    // This is a modified click on a client window
    // Raise and focus the window
    if (window != 0) {
        wm.focused_window = window;

        _ = xcb.xcb_set_input_focus(
            wm.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            window,
            xcb.XCB_CURRENT_TIME,
        );

        const values = [_]u32{xcb.XCB_STACK_MODE_ABOVE};
        _ = xcb.xcb_configure_window(
            wm.conn,
            window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &values,
        );

        _ = xcb.xcb_flush(wm.conn);
    }
    
    // Note: No xcb_allow_events needed - we're not grabbing unmodified clicks!
}

pub fn createModule() Module {
    return Module{
        .name = "input",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
