//! Centralized focus management

const std = @import("std");
const builtin = @import("builtin");
const defs = @import("defs");
const tiling = @import("tiling");
const utils = @import("utils");
const bar = @import("bar");
const common = @import("common");
const xcb = defs.xcb;
const WM = defs.WM;

pub const Reason = enum {
    mouse_click,
    mouse_enter,
    window_destroyed,
    workspace_switch,
    user_command,
    tiling_operation,
};

// Track last explicit focus change to prevent mouse stealing focus
var last_explicit_focus_time: i64 = 0;
const FOCUS_GRACE_PERIOD_NS: i64 = 150 * std.time.ns_per_ms;

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    if (win == wm.root) {
        std.log.err("[CRITICAL] Attempted to focus ROOT window (0x{x})! Reason: {s}. Aborting.", .{ win, @tagName(reason) });
        if (builtin.mode == .Debug) {
            @panic("Root window focus attempted - this is a bug!");
        }
        return;
    }

    if (bar.isBarWindow(win)) return;

    // Ignore mouse_enter during grace period
    if (reason == .mouse_enter) {
        const now = common.getTimestampNs();
        if (now > 0 and now - last_explicit_focus_time < FOCUS_GRACE_PERIOD_NS) {
            return;
        }
    }

    if (wm.focused_window == win) return;

    // Record timestamp for explicit focus changes
    if (reason != .mouse_enter) {
        last_explicit_focus_time = common.getTimestampNs();
    }

    const old = wm.focused_window;
    wm.focused_window = win;

    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);

    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    tiling.updateWindowFocusFast(wm, old, win);
    common.flush(wm.conn);
}

pub fn clearFocus(wm: *WM) void {
    const old = wm.focused_window;
    wm.focused_window = null;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);

    if (old) |old_win| {
        tiling.updateWindowFocusFast(wm, old_win, null);
    }
    common.flush(wm.conn);

    bar.markDirty();
}
