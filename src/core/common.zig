//! Common utilities used across the window manager
//! Consolidates timestamp handling, border management, and other shared operations

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;

/// Get current timestamp in nanoseconds
pub inline fn getTimestampNs() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return 0;
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

/// Sleep for specified number of nanoseconds
pub inline fn sleepNs(ns: u64) void {
    std.posix.nanosleep(0, ns);
}

/// Set window border color
pub inline fn setBorder(conn: *xcb.xcb_connection_t, win: u32, color: u32) void {
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

/// Set window border width and color
pub inline fn configureBorder(conn: *xcb.xcb_connection_t, win: u32, width: u16, color: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{width});
    setBorder(conn, win, color);
}

/// Flush XCB connection
pub inline fn flush(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_flush(conn);
}
