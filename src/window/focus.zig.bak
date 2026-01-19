//! Centralized focus management with protection against focus stealing during layout
//! OPTIMIZED: Minimal XCB calls, incremental border updates
const std = @import("std");
const builtin = @import("builtin");
const defs = @import("defs");
const tiling = @import("tiling");
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

/// Grace period in nanoseconds after layout operations to ignore mouse focus changes
const FOCUS_PROTECTION_GRACE_NS: u64 = 150 * std.time.ns_per_ms; // 150ms

/// Timer to track time since last layout operation
var layout_timer: ?std.time.Timer = null;

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    if (wm.focused_window == win) return;

    const old = wm.focused_window;
    wm.focused_window = win;

    // OPTIMIZATION: Single XCB call for focus
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
    
    // OPTIMIZATION: Only raise window on explicit user actions, not mouse enter
    // This reduces XCB traffic significantly during cursor sweeps
    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    // OPTIMIZATION: Incremental border update - only old and new window
    tiling.updateWindowFocusIncremental(wm, old, win);

    if (builtin.mode == .Debug) {
        std.log.debug("[focus] {?} → 0x{x} ({s})", .{old, win, @tagName(reason)});
    }
}

pub fn clearFocus(wm: *WM) void {
    const old = wm.focused_window;
    wm.focused_window = null;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);
    
    // Update border of previously focused window
    if (old) |old_win| {
        tiling.updateWindowFocusIncremental(wm, old_win, null);
    }
}

/// Check if we're still in the grace period after a layout operation
pub fn shouldSuppressMouseFocus() bool {
    if (layout_timer) |*timer| {
        const elapsed = timer.read();

        if (elapsed < FOCUS_PROTECTION_GRACE_NS) {
            if (builtin.mode == .Debug) {
                const elapsed_ms = elapsed / std.time.ns_per_ms;
                std.log.debug("[focus] Suppressing mouse focus ({}ms since layout)", .{elapsed_ms});
            }
            return true;
        }

        layout_timer = null;
        return false;
    }

    return false;
}

/// Mark that a layout operation just occurred
pub fn markLayoutOperation() void {
    layout_timer = std.time.Timer.start() catch {
        layout_timer = null;
        return;
    };

    if (builtin.mode == .Debug) {
        std.log.debug("[focus] Layout operation marked, starting grace period", .{});
    }
}
