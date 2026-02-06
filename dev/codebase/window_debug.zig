// Window event handlers - Optimized for instant window spawning

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const bar = @import("bar");
const batch = @import("batch");
const debug = @import("debug");

const WINDOW_EVENT_MASK = xcb.XCB_EVENT_MASK_ENTER_WINDOW | 
                          xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
                          xcb.XCB_EVENT_MASK_BUTTON_PRESS;

// Grab/ungrab buttons for click-to-focus (DWM approach)
pub fn grabButtons(wm: *WM, win: u32, focused: bool) void {
    // Ungrab all first
    _ = xcb.xcb_ungrab_button(wm.conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    
    // If unfocused, grab all buttons to intercept clicks for focus
    if (!focused) {
        _ = xcb.xcb_grab_button(
            wm.conn,
            0, // owner_events = false
            win,
            xcb.XCB_EVENT_MASK_BUTTON_PRESS,
            xcb.XCB_GRAB_MODE_SYNC, // Freeze pointer until we replay
            xcb.XCB_GRAB_MODE_SYNC, // Freeze keyboard too
            xcb.XCB_NONE,
            xcb.XCB_NONE,
            xcb.XCB_BUTTON_INDEX_ANY,
            xcb.XCB_MOD_MASK_ANY,
        );
    }
}

// OPTIMIZATION: Inline workspace validation function
inline fn validateWorkspace(target_ws: ?usize, current_ws: usize) usize {
    const ws = target_ws orelse return current_ws;
    const ws_state = workspaces.getState() orelse return current_ws;
    
    if (ws >= ws_state.workspaces.len) {
        debug.warn("Rule workspace {} exceeds count, using current {}", .{ ws, current_ws });
        return current_ws;
    }
    return ws;
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    // Bar windows are handled immediately
    if (bar.isBarWindow(win)) {
        _ = xcb.xcb_map_window(wm.conn, win);
        utils.flush(wm.conn);
        return;
    }

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;
    const target_ws = matchWorkspaceRule(wm, win);
    const validated_ws = validateWorkspace(target_ws, current_ws);
    const is_current_ws = (validated_ws == current_ws);

    // OPTIMIZATION: Use batch operations for all XCB calls
    var b = batch.Batch.begin(wm) catch {
        // Fallback to direct calls if batch fails
        handleMapRequestDirect(wm, win, is_current_ws, validated_ws);
        return;
    };
    defer b.deinit();

    // FOCUS PROTECTION: Reset event counter BEFORE mapping to protect new window focus
    // This prevents EnterNotify events generated during mapping from stealing focus
    if (is_current_ws) {
        wm.events_since_programmatic_action = 0;
        debug.info("MapRequest: Reset counter to 0 for window {x}", .{win});
    }

    // Subscribe to enter/leave events
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});

    // DWM APPROACH: Always map window, but position off-screen if not on current workspace
    if (!is_current_ws) {
        // Position window off-screen before mapping
        const off_screen_x: i32 = -4000;
        const values = [_]u32{@bitCast(off_screen_x)};
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_X, &values);
    }
    
    // Always map the window (on-screen if current workspace, off-screen otherwise)
    b.map(win) catch {};

    // Track window
    wm.addWindow(win) catch |err| {
        debug.err("Failed to track window {x}: {}", .{ win, err });
    };

    // Add to workspace
    if (is_current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_ws);
    }

    // Set up tiling
    if (wm.config.tiling.enabled) {
        b.setBorderWidth(win, wm.config.tiling.border_width) catch {};
        if (is_current_ws) {
            b.setBorder(win, wm.config.tiling.border_unfocused) catch {};
        }
        tiling.addWindow(wm, win);
    }

    b.execute();
    
    // Focus new window if it's on the current workspace
    if (is_current_ws) {
        focus.setFocus(wm, win, .tiling_operation);
    } else {
        // Grab buttons for click-to-focus (window starts unfocused)
        grabButtons(wm, win, false);
    }
    
    bar.markDirty();
}

// OPTIMIZATION: Fallback for when batch operations fail
inline fn handleMapRequestDirect(wm: *WM, win: u32, is_current_ws: bool, validated_ws: usize) void {
    // FOCUS PROTECTION: Reset event counter BEFORE mapping to protect new window focus
    if (is_current_ws) {
        wm.events_since_programmatic_action = 0;
        debug.info("MapRequest (direct): Reset counter to 0 for window {x}", .{win});
    }

    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
    
    // DWM APPROACH: Always map, but position off-screen if not current workspace
    if (!is_current_ws) {
        const off_screen_x: i32 = -4000;
        const values = [_]u32{@bitCast(off_screen_x)};
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_X, &values);
    }
    
    _ = xcb.xcb_map_window(wm.conn, win);
    
    wm.addWindow(win) catch |err| {
        debug.err("Failed to track window {x}: {}", .{ win, err });
    };
    
    if (is_current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_ws);
    }
    
    if (wm.config.tiling.enabled) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{wm.config.tiling.border_width});
        if (is_current_ws) {
            _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL,
                &[_]u32{wm.config.tiling.border_unfocused});
        }
        tiling.addWindow(wm, win);
    }
    
    utils.flush(wm.conn);
    
    if (is_current_ws) {
        focus.setFocus(wm, win, .tiling_operation);
    } else {
        grabButtons(wm, win, false);
    }
    
    bar.markDirty();
}

fn matchWorkspaceRule(wm: *WM, win: u32) ?usize {
    const class = utils.getWindowClass(wm.conn, win) orelse return null;
    defer wm.allocator.free(class);

    for (wm.config.workspaces.rules.items) |rule| {
        if (std.mem.eql(u8, rule.class_name, class)) {
            return rule.workspace;
        }
    }
    return null;
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    const win = event.event;
    
    if (win == wm.root or win == 0 or bar.isBarWindow(win)) return;
    if (!wm.hasWindow(win)) return;
    
    // FIX: Only filter UNGRAB mode - allow NORMAL and GRAB modes
    // This fixes Firefox focus issues when moving quickly between windows
    // UNGRAB events are still artifacts that should be filtered
    if (event.mode == xcb.XCB_NOTIFY_MODE_UNGRAB) return;
    
    // FIX: Allow inferior/ancestor events for Firefox compatibility
    // Only filter strictly virtual events (nonlinear virtual)
    if (event.detail == xcb.XCB_NOTIFY_DETAIL_NONLINEAR_VIRTUAL) return;

    // FOCUS PROTECTION: Ignore mouse-enter focus changes for a short time after
    // programmatic focus changes (e.g., window creation, user commands)
    // Using sequence-based protection: ignore EnterNotify for N events after programmatic action
    if (wm.events_since_programmatic_action < defs.FOCUS_PROTECTION_EVENT_COUNT) {
        debug.info("EnterNotify BLOCKED: counter={} window={x}", .{wm.events_since_programmatic_action, win});
        return;
    }

    debug.info("EnterNotify ALLOWED: counter={} window={x}", .{wm.events_since_programmatic_action, win});
    const old_focus = wm.focused_window;
    focus.setFocus(wm, win, .mouse_enter);
    tiling.updateWindowFocus(wm, old_focus, win);
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    const win = event.event;
    
    if (win == wm.root or win == 0 or bar.isBarWindow(win)) return;
    
    // Always replay the click to the window
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, xcb.XCB_CURRENT_TIME);
    
    if (!wm.hasWindow(win)) return;
    
    const old = wm.focused_window;
    focus.setFocus(wm, win, .mouse_click);
    tiling.updateWindowFocus(wm, old, win);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    
    if (win == wm.root or win == 0 or bar.isBarWindow(win)) return;
    if (!wm.hasWindow(win)) return;
    
    wm.removeWindow(win);
    
    if (wm.fullscreen.isFullscreen(win)) {
        const fs_info = wm.fullscreen.getForWorkspace(workspaces.getCurrentWorkspace() orelse 0);
        if (fs_info != null and fs_info.?.window == win) {
            wm.fullscreen.removeForWorkspace(workspaces.getCurrentWorkspace() orelse 0);
        }
    }
    
    workspaces.removeWindowFromCurrentWorkspace(wm, win);
    
    if (wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }
    
    if (wm.focused_window == win) {
        wm.focused_window = null;
        const new_focus = tiling.getNextFocus(wm);
        if (new_focus) |next_win| {
            focus.setFocus(wm, next_win, .window_destroyed);
        }
    }
    
    bar.markDirty();
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t, wm: *WM) void {
    const win = event.window;
    
    if (win == wm.root or win == 0 or bar.isBarWindow(win)) return;
    if (!wm.hasWindow(win)) return;
    
    if (event.from_configure != 0) return;
    
    wm.removeWindow(win);
    
    if (wm.fullscreen.isFullscreen(win)) {
        const fs_info = wm.fullscreen.getForWorkspace(workspaces.getCurrentWorkspace() orelse 0);
        if (fs_info != null and fs_info.?.window == win) {
            wm.fullscreen.removeForWorkspace(workspaces.getCurrentWorkspace() orelse 0);
        }
    }
    
    workspaces.removeWindowFromCurrentWorkspace(wm, win);
    
    if (wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }
    
    if (wm.focused_window == win) {
        wm.focused_window = null;
        const new_focus = tiling.getNextFocus(wm);
        if (new_focus) |next_win| {
            focus.setFocus(wm, next_win, .window_destroyed);
        }
    }
    
    bar.markDirty();
}
