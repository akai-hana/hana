// Input handling - captures keyboard and mouse events

const std = @import("std");
const defs = @import("defs");

const c = @cImport({
    @cInclude("unistd.h");
});

// Use xcb from defs to avoid type conflicts
const xcb = defs.xcb;

const WM = defs.WM;
const Module = defs.Module;

// Events this module handles
pub const EVENT_TYPES = [_]u8{
    xcb.XCB_KEY_PRESS,
    xcb.XCB_KEY_RELEASE,
    xcb.XCB_BUTTON_PRESS,
    xcb.XCB_BUTTON_RELEASE,
    xcb.XCB_MOTION_NOTIFY,
};

pub fn init(_: *WM) void {
    std.debug.print("[input] Module initialized\n", .{});
}

pub const deinit = defs.defaultModuleDeinit;

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    switch (response_type) {
        xcb.XCB_KEY_PRESS => {
            const ev = @as(*const xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event)));
            handleKeyPress(ev, wm);
        },

        xcb.XCB_KEY_RELEASE => {
            const ev = @as(*const xcb.xcb_key_release_event_t, @alignCast(@ptrCast(event)));
            handleKeyRelease(ev, wm);
        },

        xcb.XCB_BUTTON_PRESS => {
            const ev = @as(*const xcb.xcb_button_press_event_t, @alignCast(@ptrCast(event)));
            handleButtonPress(ev, wm);
        },

        xcb.XCB_BUTTON_RELEASE => {
            const ev = @as(*const xcb.xcb_button_release_event_t, @alignCast(@ptrCast(event)));
            handleButtonRelease(ev, wm);
        },

        xcb.XCB_MOTION_NOTIFY => {
            const ev = @as(*const xcb.xcb_motion_notify_event_t, @alignCast(@ptrCast(event)));
            handleMotion(ev, wm);
        },

        else => {},
    }
}

fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    const keycode = event.detail;
    const modifiers: u16 = @intCast(event.state);

    // Check if this matches any keybinding
    for (wm.config.keybindings.items) |keybind| {
        if (keybind.matches(modifiers, keycode)) {
            std.debug.print("[input] Keybinding matched: mod=0x{x} key={}\n", .{ modifiers, keycode });
            executeAction(&keybind.action, wm) catch |err| {
                std.debug.print("[input] Failed to execute action: {}\n", .{err});
            };
            return;
        }
    }

    std.debug.print("[input] Unbound key press: keycode={} modifiers=0x{x}\n", .{ keycode, modifiers });
}

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .exec => |cmd| {
            std.debug.print("[input] Executing command: {s}\n", .{cmd});

            // Fork and exec using C functions
            const pid = c.fork();
            if (pid == 0) {
                // Child process
                const cmd_z = try wm.allocator.dupeZ(u8, cmd);
                defer wm.allocator.free(cmd_z);

                const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
                _ = c.execvp("/bin/sh", @ptrCast(&argv));
                
                // If exec fails, exit
                std.debug.print("[input] Failed to exec: {s}\n", .{cmd});
                std.process.exit(1);
            } else if (pid < 0) {
                std.debug.print("[input] Fork failed\n", .{});
            }
        },
        .close_window => {
            if (wm.focused_window) |win_id| {
                std.debug.print("[input] Closing window {}\n", .{win_id});
                _ = xcb.xcb_destroy_window(wm.conn, win_id);
                _ = xcb.xcb_flush(wm.conn);
            }
        },
        .reload_config => {
            std.debug.print("[input] Reload config action triggered\n", .{});
            // Signal will be handled in main loop
        },
        .focus_next, .focus_prev => {
            std.debug.print("[input] Focus navigation not yet implemented\n", .{});
        },
    }
}

fn handleKeyRelease(event: *const xcb.xcb_key_release_event_t, _: *WM) void {
    const keycode = event.detail;
    std.debug.print("[input] Key release: keycode={}\n", .{keycode});
}

fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    const button = event.detail;
    const x = event.event_x;
    const y = event.event_y;
    const window = event.child;

    const button_name: []const u8 = switch (button) {
        1 => "left",
        2 => "middle",
        3 => "right",
        4 => "scroll up",
        5 => "scroll down",
        else => "unknown",
    };

    std.debug.print("[input] Mouse {s} click at ({}, {}) window={}\n", .{ button_name, x, y, window });

    // Handle window focus and raising
    if (window != 0) {
        // Focus the clicked window
        wm.focused_window = window;
        _ = xcb.xcb_set_input_focus(
            wm.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            window,
            xcb.XCB_CURRENT_TIME,
        );

        // Raise the window to the top of the stack
        const values = [_]u32{xcb.XCB_STACK_MODE_ABOVE};
        _ = xcb.xcb_configure_window(
            wm.conn,
            window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &values,
        );

        // CRITICAL: Replay the pointer event so the application receives it
        // Without this, clicks are swallowed by the WM and apps can't respond to them
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, event.time);
        _ = xcb.xcb_flush(wm.conn);

        // TODO: Check for Mod+Button1 to initiate window move
        // TODO: Check for Mod+Button3 to initiate window resize
    } else {
        // Clicked on root window
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, event.time);
    }
}

fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t, wm: *WM) void {
    const button = event.detail;
    std.debug.print("[input] Mouse button {} released\n", .{button});

    // TODO: End window drag/resize operations here
    // For now, just allow the event to continue
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
    _ = xcb.xcb_flush(wm.conn);
}

fn handleMotion(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    // TODO: Add drag state tracking to WM struct:
    //   - is_dragging: bool
    //   - drag_window: xcb_window_t
    //   - drag_start_x/y: i16
    //   - window_start_x/y: i16
    
    const is_dragging = false; // Replace with: wm.drag_state.is_dragging
    
    if (is_dragging) {
        // TODO: Calculate new window position and update
        // const dx = event.root_x - wm.drag_state.start_x;
        // const dy = event.root_y - wm.drag_state.start_y;
        // Update window geometry...
        std.debug.print("[input] Drag motion: ({}, {})\n", .{ event.root_x, event.root_y });
    }

    // CRITICAL: Allow motion events to continue
    // Without this, the cursor will feel laggy/frozen when the WM has grabbed pointer events
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_POINTER, event.time);
    
    // Only flush if we're actually dragging to reduce overhead
    if (is_dragging) {
        _ = xcb.xcb_flush(wm.conn);
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
