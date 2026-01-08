// Error handling utilities

const std = @import("std");
const defs = @import("defs");
const Config = defs.Config;

// Use xcb from defs to avoid type conflicts
const xcb = defs.xcb;

/// Loads config with fallback to defaults and user-friendly error messages
pub fn loadConfigOrDefault(
    loadConfig: fn (std.mem.Allocator, []const u8) anyerror!Config,
    allocator: std.mem.Allocator,
    path: []const u8,
    default_config: Config,
) Config {
    return loadConfig(allocator, path) catch |err| {
        handleConfigError(err, path);
        return default_config;
    };
}

/// Prints user-friendly error message for config loading failures
fn handleConfigError(err: anyerror, path: []const u8) void {
    switch (err) {
        error.FileNotFound => {
            std.debug.print("Config file '{s}' not found, falling back to defaultss\n", .{path});
        },
        error.AccessDenied => {
            std.debug.print("Cannot access config file '{s}' (permission denied), falling back to defaultss\n", .{path});
        },
        error.IsDir => {
            std.debug.print("Config path '{s}' is a directory, not a file, falling back to defaultss\n", .{path});
        },
        else => {
            std.debug.print("Failed to load config '{s}' ({}), falling back to defaultss\n", .{ path, err });
        },
    }
}

/// Warns about empty config value
pub fn warnEmptyValue(line: usize, key: []const u8) void {
    std.debug.print("Warning (line {}): Empty value for '{s}', falling back to defaults\n", .{ line, key });
}

/// Warns about invalid border_width value
pub fn warnInvalidBorderWidth(line: usize, value: []const u8, err: anyerror) void {
    std.debug.print("Warning (line {}): Invalid border_width '{s}' ({}), falling back to defaults\n", .{ line, value, err });
}

/// Warns about negative border_width
pub fn warnNegativeBorderWidth(line: usize) void {
    std.debug.print("Warning (line {}): border_width cannot be a negative number (<0), falling back to defaults\n", .{line});
}

/// Warns about invalid border_color value
pub fn warnInvalidBorderColor(line: usize, value: []const u8, err: anyerror) void {
    std.debug.print("Warning (line {}): Invalid border_color '{s}' ({}), falling back to defaults\n", .{ line, value, err });
}

/// Warns about unknown config key (potential typo)
pub fn warnUnknownConfigKey(line: usize, key: []const u8) void {
    std.debug.print("Warning (line {}): Unknown config key '{s}' (ignored)\n", .{ line, key });
}

/// Connects to X11 display server with error handling
pub fn connectToX11() !*xcb.xcb_connection_t {
    const conn = xcb.xcb_connect(null, null) orelse {
        std.debug.print("Failed to connect to X11 display server (null connection)\n", .{});
        return error.X11ConnectionFailed;
    };

    if (xcb.xcb_connection_has_error(conn) != 0) {
        std.debug.print("Failed to connect to X11 display server (connection error)\n", .{});
        return error.X11ConnectionFailed;
    }

    return conn;
}

/// Gets X11 screen with error handling
pub fn getX11Screen(conn: *xcb.xcb_connection_t) !*xcb.xcb_screen_t {
    const setup = xcb.xcb_get_setup(conn);
    const screen_iter = xcb.xcb_setup_roots_iterator(setup);
    const screen = screen_iter.data;

    if (screen == null) {
        std.debug.print("Failed to get X11 screen\n", .{});
        return error.X11ScreenFailed;
    }

    return screen;
}

/// Attempts to become the window manager by claiming root window control
pub fn becomeWindowManager(conn: *xcb.xcb_connection_t, root: u32, event_mask: u32) !void {
    const mask = xcb.XCB_CW_EVENT_MASK;
    const values = [_]u32{event_mask};

    const cookie = xcb.xcb_change_window_attributes_checked(conn, root, mask, &values);
    const err = xcb.xcb_request_check(conn, cookie);

    if (err != null) {
        std.debug.print("Another window manager is already running\n", .{});
        return error.AnotherWMRunning;
    }
}

// Future error handling utilities can go here:
// - handleModuleError()
// - handleKeybindError()
// etc.
