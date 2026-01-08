// Core type definitions
const std = @import("std");
const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

// X11 uses bit 7 to mark synthetic events
pub const X11_SYNTHETIC_EVENT_FLAG: u8 = 0x80;

pub const Config = struct {
    border_width: u32,
    border_color: u32,
};

pub const WM = struct {
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    config: Config,
    allocator: std.mem.Allocator,
    root: u32,
};

pub const Module = struct {
    name: []const u8,
    /// List of XCB event types this module handles (e.g. XCB_KEY_PRESS, XCB_BUTTON_PRESS)
    /// Used to filter events before calling handle_fn (performance optimization)
    events: []const u8,
    init_fn: *const fn (*WM) void,
    handle_fn: *const fn (u8, *anyopaque, *WM) void,
};
