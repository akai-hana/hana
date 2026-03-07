//! WM entry point and main event loop.
//!
//! Inits the X11 connection, loads configuration, and drives all I/O through `poll`.

// Zig stdlib
const std     = @import("std");
const builtin = @import("builtin");

// core/
const utils     = @import("utils");
const constants = @import("constants");
const events    = @import("events");
const dpi       = @import("dpi");

// config/
const config    = @import("config");
const defs      = @import("defs");
const WM    = defs.WM;
const xcb   = defs.xcb;

// input/
const input     = @import("input");
const xkbcommon = @import("xkbcommon");

// tiling/
const layouts = @import("layouts");

// bar/
const bar     = @import("bar");

// debug/
const debug     = @import("debug");

/// hana's main WM loop
pub fn main() !void {
    // 1. CONNECT TO X11

    // Establish initial connection to the X server
    const conn = xcb.xcb_connect(null, null) orelse {
        debug.err("Failed to connect to X11 server", .{});
        return error.X11ConnectionFailed;
    };
    defer xcb.xcb_disconnect(conn);

    // Check for any errors in the connection
    if (xcb.xcb_connection_has_error(conn) != 0) {
        debug.err("X11 connection failed with following errors:", .{});
        return error.X11ConnectionFailed;
    }

    // 2. GET DISPLAY INFORMATION

    // Fetch screen and root window information, needed for subsequent XCB calls
    const setup  = xcb.xcb_get_setup(conn);
    const screen = xcb.xcb_setup_roots_iterator(setup).data orelse return error.X11ScreenFailed;
    const root   = screen.*.root;

    // 3. CLAIM WINDOW CONTROL

    // Attempt to become the WM. Fail if another WM is running.
    // Subscribes to SubstructureRedirect events.
    if (xcb.xcb_request_check(conn, xcb.xcb_change_window_attributes_checked(
                conn, root, xcb.XCB_CW_EVENT_MASK, &[_]u32{constants.EventMasks.ROOT_WINDOW}))) |err| {
        std.c.free(err);
        debug.err("Another window manager is running", .{});
        return error.AnotherWMRunning;
    }

    // Initialize the environment (custom cursor) and global input grabs.
    XcbCursor.setupRoot(conn, screen);
    input.setupGrabs(conn, root);

    // 4. MEMORY & RESOURCE INITIALIZATION
    // GPA tracks every allocation in debug builds so leaks surface at exit;
    // in release builds the C allocator is faster and avoids the overhead.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    // 5. SYSTEM & CONFIGURATION SETUP
    // Detect High-DPI settings and initialize the keyboard state (XKB).
    const dpi_info = dpi.detect(conn, screen);
    debug.info("DPI Detection - DPI: {d:.1}, Scale: {d:.2}x", .{ dpi_info.dpi, dpi_info.scale_factor });

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn, allocator);
    defer xkb_state.deinit();

    // Load user preferences and resolve keybindings against current XKB map.
    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state, allocator);
    config.finalizeConfig(&user_config, screen);

    // 6. CORE WM STATE INITIALIZATION
    // Create the central WM state container and initialize global caches.
    var wm = WM{
        .allocator  = allocator,
        .conn       = conn,
        .screen     = screen,
        .root       = root,
        .config     = user_config,
        .dpi_info   = dpi_info,
    };
    defer wm.deinit();

    try initGlobalCaches(conn, allocator);
    defer deinitGlobalCaches(allocator);

    // 7. MODULE & UI SETUP
    // Setup Unix signals (for graceful shutdown) and initialize UI components.
    const signal_fd = try events.setupSignalPipe();
    defer {
        std.posix.close(signal_fd);
        events.deinitSignalPipe();
    }

    try events.initModules(&wm, xkb_state);
    defer events.deinitModules();

    // Initialize the status bar if enabled.
    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
    };
    defer bar.deinit();

    // 8. START EVENT LOOP
    // Register hotkeys, flush the XCB request buffer, and enter the blocking loop.
    bar.updateTimerState();
    try events.grabKeybindings(&wm);

    // XCB batches requests; flush now so every setup call above reaches the
    // server before we block in the event loop waiting for replies/events.
    _ = xcb.xcb_flush(conn);
    debug.info("Started", .{});

    // This call blocks until the WM is terminated.
    try events.run(&wm, signal_fd);

    debug.info("Shutting down gracefully", .{});
}

// HELPER FUNCTIONS

/// Initializes global utility caches.
fn initGlobalCaches(conn: *xcb.xcb_connection_t, allocator: std.mem.Allocator) !void {
    try utils.initAtomCache(conn);
    utils.initInputModelCache(allocator);
}

/// Cleans up global utility caches.
fn deinitGlobalCaches(allocator: std.mem.Allocator) void {
    utils.deinitInputModelCache();
    layouts.deinitSizeHintsCache(allocator);
}

// XCB CURSOR NAMESPACE

/// xcb-cursor extern declarations and helpers.
///
/// Declared manually instead of via cImport because xcb_cursor_load_name is a static
/// inline function in some versions of the header, which Zig's cImport silently drops.
const XcbCursor = struct {
    const Context = opaque {};

    extern fn xcb_cursor_context_new(
        conn:   *xcb.xcb_connection_t,
        screen: *xcb.xcb_screen_t,
        ctx:    *?*Context,
    ) c_int;

    extern fn xcb_cursor_load_cursor(ctx: *Context, name: [*:0]const u8) u32;
    extern fn xcb_cursor_context_free(ctx: ?*Context) void;

    /// Sets the root window cursor to the standard left-pointer shape.
    /// Prefers a themed cursor via xcb-cursor; falls back to X11's built-in
    /// cursor font (always present on a conforming server) if loading fails.
    fn setupRoot(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
        var cursor_ctx: ?*Context = null;
        if (xcb_cursor_context_new(conn, screen, &cursor_ctx) >= 0) {
            defer xcb_cursor_context_free(cursor_ctx);
            const cursor = xcb_cursor_load_cursor(cursor_ctx.?, "left_ptr");
            if (cursor != xcb.XCB_NONE) {
                _ = xcb.xcb_change_window_attributes(
                    conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor},
                );
                _ = xcb.xcb_free_cursor(conn, cursor);
                return;
            }
        }
    }
};
