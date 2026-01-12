// Main WM event loop - maximum performance, zero overhead
const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

// core/
const config = @import("config");
const error_handling = @import("error");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
// modules/
const window_module = @import("window");
const input_module = @import("input");

const xcb = defs.xcb;
const WM = defs.WM;

// Signal flag for config reload (atomic for thread-safety)
var should_reload_config: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Pre-computed event mask constant (compile-time)
const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_PROPERTY_CHANGE |
    xcb.XCB_EVENT_MASK_KEY_PRESS |
    xcb.XCB_EVENT_MASK_KEY_RELEASE;

// Cursor setup
fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) !void {
    const cursor_font = xcb.xcb_generate_id(conn);
    const font_name = "cursor";
    _ = xcb.xcb_open_font(
        conn,
        cursor_font,
        @intCast(font_name.len),
        font_name.ptr,
    );

    const cursor_id = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_glyph_cursor(
        conn,
        cursor_id,
        cursor_font,
        cursor_font,
        68,        // left_ptr (standard arrow)
        68 + 1,    // mask character
        0, 0, 0,   // foreground color (black)
        65535, 65535, 65535, // background color (white)
    );

    const mask: u32 = xcb.XCB_CW_CURSOR;
    const values = [_]u32{cursor_id};
    _ = xcb.xcb_change_window_attributes(
        conn,
        screen.*.root,
        mask,
        &values,
    );

    _ = xcb.xcb_close_font(conn, cursor_font);
    _ = xcb.xcb_flush(conn);

    if (builtin.mode == .Debug) {
        std.debug.print("[cursor] Root cursor set successfully\n", .{});
    }
}

pub fn main() !void {
    // Connect to X11
    const conn = try error_handling.connectToX11();
    defer xcb.xcb_disconnect(@ptrCast(conn));

    const screen = try error_handling.getX11Screen(conn);
    const root = screen.*.root;

    // Become window manager
    try error_handling.becomeWindowManager(conn, root, WM_EVENT_MASK);
    
    // test output
    if (builtin.mode == .Debug) {
        std.debug.print("[cursor] About to call root cursor...\n", .{});
    }
    // Set up cursor so it's visible
    try setupRootCursor(conn, screen);

    if (builtin.mode == .Debug) {
        std.debug.print("hana window manager started\n", .{});
    }

    // GPA for runtime allocations
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize XKB state (needed for keysym<->keycode conversion)
    const xkb_state_ptr = try allocator.create(xkbcommon.XkbState);
    errdefer allocator.destroy(xkb_state_ptr);
    xkb_state_ptr.* = try xkbcommon.XkbState.init(conn);
    errdefer xkb_state_ptr.deinit();

    // Load config using the GPA allocator (not startup_allocator!)
    var user_config = try config.loadConfig(allocator, "config.toml");

    // Resolve keysyms to keycodes for all keybindings
    for (user_config.keybindings.items) |*keybind| {
        keybind.keycode = xkb_state_ptr.keysymToKeycode(keybind.keysym);
        if (keybind.keycode == null) {
            std.log.warn("Could not find keycode for keysym {x}", .{keybind.keysym});
        }
    }

    // Initialize WM with HashMap for O(1) window lookups
    var wm = WM{
        .allocator = allocator,
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .windows = std.AutoHashMap(u32, defs.Window).init(allocator),
        .focused_window = null,
        .xkb_state = xkb_state_ptr,
    };
    defer wm.deinit();

    // Setup signal handler
    const sig_handler = struct {
        fn handler(_: posix.SIG) callconv(.c) void {
            should_reload_config.store(true, .release);
        }
    }.handler;

    var sa = posix.Sigaction{
        .handler = .{ .handler = sig_handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.HUP, &sa, null);

    // Initialize modules - direct initialization, no function pointers
    window_module.init(&wm);
    input_module.init(&wm);
    
    defer {
        window_module.deinit(&wm);
        input_module.deinit(&wm);
    }

    // Grab keybindings
    try grabKeybindings(&wm);

    // Build dispatch table - reduced size based on actual X11 event range
    // XCB_GE_GENERIC (35) is the highest standard event type
    const MAX_EVENT_TYPE = 36;
    var event_handlers = [_]EventHandlers{.{ .window = false, .input = false }} ** MAX_EVENT_TYPE;
    
    // Register window module handlers
    for (window_module.EVENT_TYPES) |event_type| {
        if (event_type < MAX_EVENT_TYPE) {
            event_handlers[event_type].window = true;
        }
    }
    
    // Register input module handlers  
    for (input_module.EVENT_TYPES) |event_type| {
        if (event_type < MAX_EVENT_TYPE) {
            event_handlers[event_type].input = true;
        }
    }

    // Main event loop - absolutely minimal overhead
    _ = xcb.xcb_flush(conn);
    
    while (true) {
        // Check config reload (fast atomic load)
        if (should_reload_config.swap(false, .acquire)) {
            handleConfigReload(&wm) catch {};
        }

        // Wait for event (blocks, zero CPU when idle)
        const event = xcb.xcb_wait_for_event(conn) orelse break;
        defer std.c.free(event);

        // Fast event dispatch - single array lookup, no function pointers
        const event_type = @as(*u8, @ptrCast(event)).*;
        const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

        // Bounds check once, then dispatch
        if (response_type < MAX_EVENT_TYPE) {
            dispatchEvent(response_type, event_type, event, &wm, &event_handlers);
        }

        // Immediate flush for maximum responsiveness
        // For a WM, we prioritize low latency over batching efficiency
        _ = xcb.xcb_flush(conn);
    }
}

// Compact handler flags - 2 bytes, stack allocated
const EventHandlers = packed struct {
    window: bool,
    input: bool,
};

/// Hot path: dispatch events with zero overhead
/// Force inline to eliminate function call overhead
inline fn dispatchEvent(
    response_type: u8,
    event_type: u8,
    event: *anyopaque,
    wm: *WM,
    handlers: []const EventHandlers,
) void {
    // Array access is guaranteed safe (bounds checked by caller)
    const handler = handlers[response_type];
    
    // Direct function calls (no function pointers)
    // Branch hints help CPU predict common paths
    if (handler.window) {
        @branchHint(.likely); // Window events are common
        window_module.handleEvent(event_type, event, wm);
    }
    
    if (handler.input) {
        @branchHint(.likely); // Input events are common
        input_module.handleEvent(event_type, event, wm);
    }
}

/// Grab keybindings - minimized syscalls
fn grabKeybindings(wm: *WM) !void {
    // Single ungrab call
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    var grabbed: usize = 0;

    // Grab each keybinding
    for (wm.config.keybindings.items) |keybind| {
        // Skip if we couldn't resolve keycode
        const keycode = keybind.keycode orelse {
            std.log.warn("Skipping keybinding with unresolved keycode (keysym={x})", .{keybind.keysym});
            continue;
        };

        const cookie = xcb.xcb_grab_key_checked(
            wm.conn,
            0,
            wm.root,
            @intCast(keybind.modifiers),
            keycode,
            xcb.XCB_GRAB_MODE_ASYNC,
            xcb.XCB_GRAB_MODE_ASYNC,
        );

        // Only check errors on failure path
        if (xcb.xcb_request_check(wm.conn, cookie)) |err| {
            if (builtin.mode == .Debug) {
                std.debug.print("Warning: Failed to grab key (mod={x} key={}): error code {}\n", 
                    .{ keybind.modifiers, keycode, err.*.error_code });
            }
            std.c.free(err);
        } else {
            grabbed += 1;
        }
    }

    if (builtin.mode == .Debug) {
        std.debug.print("Grabbed {} keybindings\n", .{grabbed});
    }
}

/// Config reload handler
fn handleConfigReload(wm: *WM) !void {
    if (builtin.mode == .Debug) {
        std.debug.print("Reloading configuration...\n", .{});
    }

    var new_config = config.loadConfig(wm.allocator, "config.toml") catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("Config reload failed: {}\n", .{err});
        }
        return err;
    };

    // Get XKB state for keycode resolution
    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));

    // Resolve keysyms to keycodes for all new keybindings
    for (new_config.keybindings.items) |*keybind| {
        keybind.keycode = xkb_ptr.keysymToKeycode(keybind.keysym);
        if (keybind.keycode == null) {
            std.log.warn("Could not find keycode for keysym {x}", .{keybind.keysym});
        }
    }

    wm.config.deinit(wm.allocator);
    wm.config = new_config;
    try grabKeybindings(wm);

    if (builtin.mode == .Debug) {
        std.debug.print("Configuration reloaded successfully\n", .{});
    }
}
