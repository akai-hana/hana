//! Error handling and validation utilities

const std = @import("std");
const defs = @import("defs");
const workspaces = @import("workspaces");
const colors = @import("colors");
const WM = defs.WM;

// ============================================================================
// WINDOW DESTRUCTION ERRORS
// ============================================================================

pub const DestroyWindowError = error{
    IsRootWindow,
    NotManaged,
    NotOnCurrentWorkspace,
};

/// Validate that a window can be safely destroyed
pub fn validateWindowDestroy(wm: *WM, win: u32) DestroyWindowError!void {
    // CRITICAL: Never destroy root window
    if (win == wm.root) {
        std.log.err("[CRITICAL] Attempted to destroy ROOT window! Aborting.", .{});
        return DestroyWindowError.IsRootWindow;
    }

    // CRITICAL: Verify this window is actually in our managed windows
    if (!wm.windows.contains(win)) {
        std.log.err("[CRITICAL] Attempted to destroy unmanaged window 0x{x}! Aborting.", .{win});
        return DestroyWindowError.NotManaged;
    }

    // CRITICAL: Only destroy if on current workspace
    if (!workspaces.isOnCurrentWorkspace(win)) {
        std.log.err("[CRITICAL] Attempted to destroy window 0x{x} not on current workspace! Aborting.", .{win});
        return DestroyWindowError.NotOnCurrentWorkspace;
    }
}

/// Validate that focus target is not the root window
pub fn validateFocusTarget(root: u32, win: u32, reason: []const u8) !void {
    if (win == root) {
        std.log.err("[CRITICAL] Attempted to focus ROOT window (0x{x})! Reason: {s}. Aborting.", .{ win, reason });
        return error.FocusRootWindow;
    }
}

// ============================================================================
// CONFIG ERROR HANDLING
// ============================================================================

/// Loads config with fallback to defaults and user-friendly error messages
pub fn loadConfigOrDefault(
    loadConfig: fn (std.mem.Allocator, []const u8) anyerror!defs.Config,
    allocator: std.mem.Allocator,
    path: []const u8,
    default_config: defs.Config,
) defs.Config {
    return loadConfig(allocator, path) catch |err| {
        handleConfigError(err, path);
        return default_config;
    };
}

/// Prints user-friendly error message for config loading failures
fn handleConfigError(err: anyerror, path: []const u8) void {
    const msg = switch (err) {
        error.FileNotFound => "not found",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory, not a file",
        else => "unknown error",
    };
    const color = if (err == error.FileNotFound) colors.YELLOW else colors.RED;
    std.debug.print("{s}Warning{s}: Config file '{s}' {s}, falling back to defaults\n", .{ color, colors.RESET, path, msg });
}

// ============================================================================
// CONFIG WARNING FUNCTIONS
// ============================================================================

pub fn warnEmptyValue(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Empty value for '{s}', falling back to defaults\n", .{ colors.YELLOW, colors.RESET, line, key });
}

pub fn warnInvalidBorderWidth(line: usize, value: []const u8, err: anyerror) void {
    std.debug.print("{s}Warning{s} (line {}): Invalid border_width '{s}' ({}), falling back to defaults\n", .{ colors.YELLOW, colors.RESET, line, value, err });
}

pub fn warnInvalidBorderColor(line: usize, value: []const u8, err: anyerror) void {
    std.debug.print("{s}Warning{s} (line {}): Invalid border_color '{s}' ({}), falling back to defaults\n", .{ colors.YELLOW, colors.RESET, line, value, err });
}

pub fn warnDuplicateKey(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Duplicate key '{s}', last value will be used\n", .{ colors.YELLOW, colors.RESET, line, key });
}

pub fn warnColorOutOfRange(line: usize, value: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Color value '{s}' exceeds 24-bit RGB range (0x000000-0xFFFFFF), falling back to defaults\n", .{ colors.YELLOW, colors.RESET, line, value });
}

pub fn warnUnknownConfigKey(line: usize, key: []const u8) void {
    std.debug.print("{s}Warning{s} (line {}): Unknown config key '{s}' (ignored)\n", .{ colors.YELLOW, colors.RESET, line, key });
}

// ============================================================================
// X11 ERROR HANDLING
// ============================================================================

pub fn connectToX11() !*defs.xcb.xcb_connection_t {
    const conn = defs.xcb.xcb_connect(null, null) orelse {
        std.debug.print("{s}Error{s}: Failed to connect to X11 display server (null connection)\n", .{ colors.RED, colors.RESET });
        return error.X11ConnectionFailed;
    };
    if (defs.xcb.xcb_connection_has_error(conn) != 0) {
        std.debug.print("{s}Error{s}: Failed to connect to X11 display server (connection error)\n", .{ colors.RED, colors.RESET });
        return error.X11ConnectionFailed;
    }
    return conn;
}

pub fn getX11Screen(conn: *defs.xcb.xcb_connection_t) !*defs.xcb.xcb_screen_t {
    const setup = defs.xcb.xcb_get_setup(conn);
    const screen = defs.xcb.xcb_setup_roots_iterator(setup).data orelse {
        std.debug.print("{s}Error{s}: Failed to get X11 screen\n", .{ colors.RED, colors.RESET });
        return error.X11ScreenFailed;
    };
    return screen;
}

pub fn becomeWindowManager(conn: *defs.xcb.xcb_connection_t, root: u32, event_mask: u32) !void {
    const cookie = defs.xcb.xcb_change_window_attributes_checked(conn, root, defs.xcb.XCB_CW_EVENT_MASK, &[_]u32{event_mask});
    if (defs.xcb.xcb_request_check(conn, cookie)) |err| {
        std.c.free(err);
        std.debug.print("{s}Error{s}: Another window manager is already running\n", .{ colors.RED, colors.RESET });
        return error.AnotherWMRunning;
    }
}

/// Check XCB request for errors and log them
pub fn xcbCheckError(conn: *defs.xcb.xcb_connection_t, cookie: defs.xcb.xcb_void_cookie_t, operation: []const u8) bool {
    if (defs.xcb.xcb_request_check(conn, cookie)) |err| {
        std.log.err("[XCB] {s} failed: error_code={}", .{ operation, err.*.error_code });
        std.c.free(err);
        return false;
    }
    return true;
}

// ============================================================================
// GENERAL ERROR HELPERS
// ============================================================================

/// Assert that a condition is true, with a custom error message
pub inline fn assert(condition: bool, comptime message: []const u8) void {
    if (!condition) {
        std.log.err("[ASSERT FAILED] {s}", .{message});
        @panic(message);
    }
}

/// Check if a pointer is null and log error if so
pub inline fn checkNull(comptime T: type, ptr: ?*T, comptime name: []const u8) ?*T {
    if (ptr == null) {
        std.log.err("[NULL CHECK] {s} is null", .{name});
    }
    return ptr;
}
