//! hana's entry point and main loop.
//!
//! Handles the X server connection and all of hana's modules

// Zig stdlib
const std     = @import("std");
const builtin = @import("builtin");

// core/
const utils     = @import("utils");
const constants = @import("constants");
const events    = @import("events");
const dpi       = @import("dpi");

// config/
const config  = @import("config");
const defs    = @import("defs");
    const WM  = defs.WM;
    const xcb = defs.xcb;

// input/
const input     = @import("input");
const focus     = @import("focus");

// tiling/
const layouts = @import("layouts");

// bar/
const bar = @import("bar");

// debug/
const debug = @import("debug");

/// hana's startup sequence and event-loop entry point.
pub fn main() !void {
    // Initial X server connection
    const conn = xcb.xcb_connect(
        null, // display number (N:);   Pass null so XCB reads $DISPLAY and figures out the display itself
        null  // monitor number (N.M:); Short answer: Old legacy X parameter, just pass null
              //
              // Long answer: In old X11, a single X server could manage multiple physical monitors,
              // but each one was a completely separate screen (e.g. :0.1 -> "display 0, second monitor").
              // In modern multi-monitor setups (Xrandr, Xinerama), all monitors are exposed in X as
              // one big unified screen, so this parameter is now mostly irrelevant.
    ).?;
    defer xcb.xcb_disconnect(conn);

    if (xcb.xcb_connection_has_error(conn) != 0) {
        debug.err("X11 connection failed with following errors:", .{});
        return error.X11ConnectionFailed;
    }

    const setup  = xcb.xcb_get_setup(conn);                 // Fetch screen info
    const screen = xcb.xcb_setup_roots_iterator(setup).data // .data is screen 0
        orelse return error.X11ScreenFailed;
    const root   = screen.*.root;

    // Register hana as the window manager.
    const wm_reg_cookie = xcb.xcb_change_window_attributes_checked(
        conn, root, xcb.XCB_CW_EVENT_MASK,
        &[_]u32{constants.EventMasks.ROOT_WINDOW},
    );

    // Fail if another WM is already running.
    if (xcb.xcb_request_check(conn, wm_reg_cookie)) |err| {
        debug.err("Error. A window manager is already running: {}", .{err});
        std.c.free(err);
        return error.AnotherWMRunning;
    }

    // Initialize user input grabbing and custom cursor
    input.setup(conn, screen, root);

    // Initialize memory resources
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator =
        if (builtin.mode == .Debug) gpa.allocator() // In a debug build, pick GPA allocator to track every memory allocation
        else std.heap.c_allocator;                  // In release builds, the C allocator is faster and has less overhead

    // Detect display's DPI
    const dpi_info = dpi.detect(conn, screen);
    debug.info("DPI Detection - DPI: {d:.1}, Scale: {d:.2}x",
             .{ dpi_info.dpi, dpi_info.scale_factor });

    // Initialize XKB context, keymap, and key state from the server's current keyboard config.
    // Owned by input; heap-free, stable pointer exposed via input.getXkbState().
    try input.initXkb(conn, allocator);
    defer input.deinitXkb();

    // Load and finalize user config
    const user_config = try config.load(allocator, screen, input.getXkbState());

    // hana's central states container
    var wm = WM {
        .allocator  = allocator,
        .conn       = conn,
        .screen     = screen,
        .root       = root,
        .config     = user_config,
        .dpi_info   = dpi_info,
    };

    // Initialize global caches
    try initGlobalCaches(conn, allocator);
    // Defers run in LIFO order: wm.deinit() must execute before deinitGlobalCaches(),
    // since wm cleanup may still reference focus state, layout hints, etc.
    defer deinitGlobalCaches(allocator);
    defer wm.deinit();

    // Setup Unix signals (for graceful shutdown)
    const signal_fd = try events.setupSignalPipe();
    defer {
        std.posix.close(signal_fd);
        events.deinitSignalPipe();
    }

    // Register keybinds with the server.
    try events.grabKeybindings(&wm);

    // Initialize event-handling modules (layout, focus, hotkey dispatch...)
    try events.initModules(&wm);
    defer events.deinitModules();

    // Initialize bar (if it isn't disabled or removed)
    //
    // if/else used instead of switch because bar.init's error set is inferred/anyerror,
    // so BarDisabled and BarNotFound are not statically declared members and can't be switch arms.
    bar.init(&wm) catch |err| {
        if (err == error.BarDisabled) {
            debug.info("Bar disabled on user config.", .{});
        } else if (err == error.BarNotFound) {
            debug.info("Bar not found; either purposefully removed by user, or changed bar.zig's name/path from defaults (src/bar/bar.zig).", .{});
        } else {
            debug.err("Bar init failed with following error: {}", .{err});
        }
    };
    defer bar.deinit();

    // Seed the bar's timer before the loop starts
    bar.updateTimerState();

    // XCB batches requests; flush now so every setup call above reaches the server
    // before hana blocks in the event loop waiting for replies/events
    _ = xcb.xcb_flush(conn);
    debug.info("hana booted up successfully!", .{});

    // Block calls until user exits hana
    try events.run(&wm, signal_fd);

    debug.info("Shutting down gracefully...", .{});
}

/// Initializes global utility caches.
fn initGlobalCaches(conn: *xcb.xcb_connection_t, allocator: std.mem.Allocator) !void {
    try utils.initAtomCache(conn);        // Intern frequently used X atoms
    utils.initInputModelCache(allocator); // Build keysym to keycode lookup tables
    focus.init(allocator);
}

/// Cleans up global utility caches.
fn deinitGlobalCaches(allocator: std.mem.Allocator) void {
    utils.deinitInputModelCache();
    layouts.deinitSizeHintsCache(allocator); // Also frees cached ICCCM size hints
    focus.deinit();
}
