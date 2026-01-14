// Main event loop - clean and minimal

const std     = @import("std");
const posix   = std.posix;
const builtin = @import("builtin");

const config         = @import("config");
const defs           = @import("defs");
const xkbcommon      = @import("xkbcommon");
const window_module = @import("window");
const input_module  = @import("input");
const error_handling = @import("error_handling");
const logging        = @import("logging");

const xcb = defs.xcb;
const WM  = defs.WM;

const XCB_CURSOR_LEFT_PTR: u16 = 68;

var should_reload_config: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Only select events we absolutely need on root - NO MOUSE EVENTS
const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_KEY_PRESS;

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) !void {
    const cursor_font = xcb.xcb_generate_id(conn);
    const font_name = "cursor";

    _ = xcb.xcb_open_font(conn, cursor_font, @intCast(font_name.len), font_name.ptr);

    const cursor_id = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_glyph_cursor(
        conn, cursor_id, cursor_font, cursor_font,
        XCB_CURSOR_LEFT_PTR, XCB_CURSOR_LEFT_PTR + 1,
        0, 0, 0, 65535, 65535, 65535,
    );

    const mask: u32 = xcb.XCB_CW_CURSOR;
    const values = [_]u32{cursor_id};
    _ = xcb.xcb_change_window_attributes(conn, screen.*.root, mask, &values);
    _ = xcb.xcb_close_font(conn, cursor_font);
}

fn resolveKeybindings(keybindings: anytype, xkb_state: *xkbcommon.XkbState) void {
    for (keybindings) |*keybind| {
        keybind.keycode = xkb_state.keysymToKeycode(keybind.keysym);
        if (keybind.keycode == null) {
            std.log.warn("Could not find keycode for keysym 0x{x}", .{keybind.keysym});
        }
    }
}

fn setupSignalHandler() void {
    const sig_handler = struct {
        fn handler(_: posix.SIG) callconv(.c) void {
            should_reload_config.store(true, .release);
        }
    }.handler;

    var sa = posix.Sigaction{
        .handler = .{ .handler = sig_handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.HUP, &sa, null);
}

pub fn main() !void {
    const conn = try error_handling.connectToX11();
    defer xcb.xcb_disconnect(@ptrCast(conn));

    const screen = try error_handling.getX11Screen(conn);
    const root = screen.*.root;

    try error_handling.becomeWindowManager(conn, root, WM_EVENT_MASK);
    try setupRootCursor(conn, screen);

    // Setup input grabs (currently disabled for testing)
    input_module.setupGrabs(conn, root);

    logging.debugWMStarted();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug)
        gpa.allocator()
    else
        std.heap.c_allocator;

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    errdefer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn);
    errdefer xkb_state.deinit();

    var user_config = try config.loadConfig(allocator, "config.toml");
    resolveKeybindings(user_config.keybindings.items, xkb_state);

    var wm = WM{
        .allocator = allocator,
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .windows = std.AutoHashMap(u32, defs.Window).init(allocator),
        .focused_window = null,
        .xkb_state = xkb_state,
    };
    defer wm.deinit();

    setupSignalHandler();

    window_module.init(&wm);
    input_module.init(&wm);

    defer {
        window_module.deinit(&wm);
        input_module.deinit(&wm);
    }

    try grabKeybindings(&wm);

    _ = xcb.xcb_flush(conn);

    // Clean event loop - all handling delegated to modules
    while (true) {
        // CRITICAL: Flush before waiting - XCB doesn't auto-flush like Xlib
        _ = xcb.xcb_flush(conn);

        if (should_reload_config.load(.acquire)) {
            should_reload_config.store(false, .release);
            handleConfigReload(&wm) catch |err| {
                std.log.err("Config reload failed: {}", .{err});
            };
        }

        const event = xcb.xcb_wait_for_event(conn) orelse break;
        defer std.c.free(event);

        const event_type = @as(*u8, @ptrCast(event)).*;
        const response_type = event_type & 0x7F;

        // Route events to appropriate modules
        switch (response_type) {
            // Input module handles all keyboard and mouse events
            xcb.XCB_KEY_PRESS,
            xcb.XCB_BUTTON_PRESS,
            xcb.XCB_MOTION_NOTIFY,
            xcb.XCB_BUTTON_RELEASE => {
                input_module.handleEvent(event_type, event, &wm);
            },

            // Window module handles window lifecycle events
            xcb.XCB_MAP_REQUEST,
            xcb.XCB_CONFIGURE_REQUEST,
            xcb.XCB_DESTROY_NOTIFY => {
                window_module.handleEvent(event_type, event, &wm);
            },

            else => {},
        }
    }
}

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    // Define irrelevant lock modifiers to ignore (Caps Lock, Num Lock, and combo)
    // Add MOD_3 (Scroll Lock) if needed for your keyboard
    const irrelevant_mods = [_]u16{
        0,  // Base (no locks)
        defs.MOD_LOCK,  // Caps Lock
        defs.MOD_2,     // Num Lock
        defs.MOD_LOCK | defs.MOD_2,  // Both
    };

    for (wm.config.keybindings.items) |keybind| {
        const keycode = keybind.keycode orelse continue;
        for (irrelevant_mods) |irr_mod| {
            const grab_mods: u16 = @intCast(keybind.modifiers | irr_mod);
            _ = xcb.xcb_grab_key(
                wm.conn, 0, wm.root,
                grab_mods, keycode,
                xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
            );
        }
    }
    _ = xcb.xcb_flush(wm.conn);
    
    logging.debugKeybindingsGrabbed(wm.config.keybindings.items.len);
}

fn handleConfigReload(wm: *WM) !void {
    logging.debugConfigReloading();
    var new_config = try config.loadConfig(wm.allocator, "config.toml");
    errdefer new_config.deinit(wm.allocator);

    const xkb_state: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state));
    resolveKeybindings(new_config.keybindings.items, xkb_state);

    wm.config.deinit(wm.allocator);
    wm.config = new_config;

    try grabKeybindings(wm);
    logging.debugConfigReloaded();
}
