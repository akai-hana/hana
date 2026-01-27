//! Main entry point and event loop - Optimized

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const config = @import("config");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const events = @import("events");
const input = @import("input");
const utils = @import("utils");
const bar = @import("bar");
const workspaces = @import("workspaces");
const common = @import("common");

const xcb = defs.xcb;
const WM = defs.WM;

const WM_EVENT_MASK = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
    xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
    xcb.XCB_EVENT_MASK_KEY_PRESS |
    xcb.XCB_EVENT_MASK_ENTER_WINDOW |
    xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

var should_reload = std.atomic.Value(bool).init(false);
var running = std.atomic.Value(bool).init(true);

fn setupSignalHandler() void {
    const handler = struct {
        fn reload(_: posix.SIG) callconv(.c) void {
            should_reload.store(true, .release);
        }
        fn terminate(_: posix.SIG) callconv(.c) void {
            running.store(false, .release);
        }
    };

    var sa_reload = posix.Sigaction{
        .handler = .{ .handler = handler.reload },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.HUP, &sa_reload, null);

    var sa_term = posix.Sigaction{
        .handler = .{ .handler = handler.terminate },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.TERM, &sa_term, null);
    posix.sigaction(posix.SIG.INT, &sa_term, null);
}

fn setupRootCursor(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
    const font = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_open_font(conn, font, 6, "cursor");

    const cursor = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_glyph_cursor(conn, cursor, font, font, 68, 69, 0, 0, 0, 65535, 65535, 65535);
    _ = xcb.xcb_change_window_attributes(conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor});
    _ = xcb.xcb_close_font(conn, font);
}

fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32) !void {
    const cookie = xcb.xcb_change_window_attributes_checked(conn, root, xcb.XCB_CW_EVENT_MASK, &[_]u32{WM_EVENT_MASK});
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        std.c.free(err);
        std.log.err("Another window manager is running", .{});
        return error.AnotherWMRunning;
    }
}

fn setupExistingWindows(conn: *xcb.xcb_connection_t, root: u32) void {
    const cookie = xcb.xcb_query_tree(conn, root);
    const reply = xcb.xcb_query_tree_reply(conn, cookie, null) orelse return;
    defer std.c.free(reply);

    const children = xcb.xcb_query_tree_children(reply);
    const len: usize = @intCast(xcb.xcb_query_tree_children_length(reply));

    for (0..len) |i| {
        const win = children[i];
        const attrs_cookie = xcb.xcb_get_window_attributes(conn, win);
        const attrs = xcb.xcb_get_window_attributes_reply(conn, attrs_cookie, null) orelse continue;
        defer std.c.free(attrs);

        if (attrs.*.override_redirect != 0 or attrs.*.map_state != xcb.XCB_MAP_STATE_VIEWABLE) continue;

        _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});
    }
}

fn grabKeybindings(wm: *WM) !void {
    _ = xcb.xcb_ungrab_key(wm.conn, xcb.XCB_GRAB_ANY, wm.root, xcb.XCB_MOD_MASK_ANY);

    for (wm.config.keybindings.items) |kb| {
        const keycode = kb.keycode orelse continue;

        for ([_]u16{ 0, defs.MOD_LOCK, defs.MOD_2, defs.MOD_LOCK | defs.MOD_2 }) |lock| {
            const cookie = xcb.xcb_grab_key_checked(wm.conn, 0, wm.root, @intCast(kb.modifiers | lock), keycode, xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
            if (xcb.xcb_request_check(wm.conn, cookie)) |err| std.c.free(err);
        }
    }

    common.flush(wm.conn);
}

fn handleConfigReload(wm: *WM) !void {
    std.log.info("[config] Reload requested", .{});

    var new_config = config.loadConfigDefault(wm.allocator) catch |err| {
        std.log.err("[config] Failed to load new config: {}, keeping old config", .{err});
        return err;
    };
    errdefer new_config.deinit(wm.allocator);

    config.resolveKeybindings(new_config.keybindings.items, @ptrCast(@alignCast(wm.xkb_state)));

    var old_config = wm.config;
    wm.config = new_config;

    grabKeybindings(wm) catch |err| {
        std.log.err("[config] Failed to grab keybindings: {}, reverting to old config", .{err});
        new_config.deinit(wm.allocator);
        wm.config = old_config;
        try grabKeybindings(wm);
        return err;
    };

    old_config.deinit(wm.allocator);

    input.rebuildKeybindMap(wm) catch |err| {
        std.log.err("[config] Failed to rebuild keybind map: {}", .{err});
        return err;
    };

    @import("tiling").reloadConfig(wm);

    std.log.info("[config] Reload complete", .{});
}

pub fn main() !void {
    const conn = xcb.xcb_connect(null, null) orelse return error.X11ConnectionFailed;
    defer xcb.xcb_disconnect(conn);

    if (xcb.xcb_connection_has_error(conn) != 0) return error.X11ConnectionFailed;

    const setup = xcb.xcb_get_setup(conn);
    const screen = xcb.xcb_setup_roots_iterator(setup).data orelse return error.X11ScreenFailed;
    const root = screen.*.root;

    try becomeWindowManager(conn, root);
    setupRootCursor(conn, screen);
    input.setupGrabs(conn, root);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    const xkb_state = try allocator.create(xkbcommon.XkbState);
    defer allocator.destroy(xkb_state);
    xkb_state.* = try xkbcommon.XkbState.init(conn);
    defer xkb_state.deinit();

    var user_config = try config.loadConfigDefault(allocator);
    config.resolveKeybindings(user_config.keybindings.items, xkb_state);

    var wm = WM{
        .allocator = allocator,
        .conn = conn,
        .screen = screen,
        .root = root,
        .config = user_config,
        .windows = std.AutoHashMap(u32, defs.Window).init(allocator),
        .focused_window = null,
        .xkb_state = xkb_state,
        .should_reload_config = &should_reload,
        .running = &running,
    };
    defer wm.deinit();

    setupSignalHandler();
    events.initModules(&wm);
    defer events.deinitModules(&wm);

    bar.init(&wm) catch |err| {
        if (err != error.BarDisabled) {
            std.log.err("[bar] Failed to initialize: {}", .{err});
        }
    };
    defer bar.deinit();

    try grabKeybindings(&wm);
    setupExistingWindows(conn, root);
    common.flush(conn);

    std.log.info("[hana] Started", .{});

    var idle_count: usize = 0;

    while (running.load(.acquire)) {
        var events_processed: usize = 0;
        const max_events_per_batch: usize = 32;

        // Process all available events in a batch
        while (events_processed < max_events_per_batch) : (events_processed += 1) {
            const event = xcb.xcb_poll_for_event(conn);
            if (event == null) break;
            defer std.c.free(event.?);

            idle_count = 0;

            const event_type = @as(*u8, @ptrCast(event.?)).*;

            if (should_reload.swap(false, .acq_rel)) {
                handleConfigReload(&wm) catch |err| {
                    std.log.err("[config] Reload failed: {}", .{err});
                };
            }

            events.dispatch(event_type, event.?, &wm);
        }

        // Check connection health
        if (xcb.xcb_connection_has_error(conn) != 0) {
            std.log.err("[main] X11 connection error detected, shutting down", .{});
            break;
        }

        // Single flush per event loop iteration
        if (events_processed > 0) {
            common.flush(conn);

            // Update bar once at end if needed
            bar.updateIfDirty(&wm) catch |err| {
                std.log.err("[main] Failed to update bar: {}", .{err});
            };
        }

        // Adaptive sleep if no events
        if (events_processed == 0) {
            idle_count += 1;
            const sleep_ns = if (idle_count < defs.IDLE_THRESHOLD_SHORT)
                defs.EVENT_POLL_SLEEP_NS
            else if (idle_count < defs.IDLE_THRESHOLD_LONG)
                defs.EVENT_POLL_SLEEP_NS * defs.SLEEP_MULTIPLIER_MEDIUM
            else
                defs.EVENT_POLL_SLEEP_NS * defs.SLEEP_MULTIPLIER_LONG;

            common.sleepNs(sleep_ns);
        }
    }

    std.log.info("[hana] Shutting down gracefully", .{});
}
