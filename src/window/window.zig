// Window event handlers - IMPROVED: Intelligent focus-follows-mouse

const std        = @import("std");
const defs       = @import("defs");
    const xcb    = defs.xcb;
    const WM     = defs.WM;
const utils      = @import("utils");

const focus      = @import("focus");
const tiling     = @import("tiling");

const bar        = @import("bar");
const workspaces = @import("workspaces");

const debug      = @import("debug");

//TODO: add short comment on what this does
const WINDOW_EVENT_MASK = xcb.XCB_EVENT_MASK_ENTER_WINDOW | 
                          xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
                          xcb.XCB_EVENT_MASK_BUTTON_PRESS;

// Grab/ungrab buttons for click-to-focus (DWM approach)
pub fn grabButtons(wm: *WM, win: u32, focused: bool) void {
    _ = xcb.xcb_ungrab_button(wm.conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    
    //TODO: comment on what this segment below does.
    if (!focused) {
        _ = xcb.xcb_grab_button(
            wm.conn, 0, win, xcb.XCB_EVENT_MASK_BUTTON_PRESS,
            xcb.XCB_GRAB_MODE_SYNC, xcb.XCB_GRAB_MODE_SYNC,
            xcb.XCB_NONE, xcb.XCB_NONE, xcb.XCB_BUTTON_INDEX_ANY, xcb.XCB_MOD_MASK_ANY,
        );
    }
}

inline fn validateWorkspace(target_workspace: ?u8, current_workspace: u8) u8 {
    const workspace = target_workspace orelse return current_workspace;
    const ws_state  = workspaces.getState() orelse return current_workspace;
    
    if (workspace >= ws_state.workspaces.len) return current_workspace;

    return workspace;
}

// Extract common pointer query logic
// TODO: it isn't very clear to me as to what this does.
// please clarify a bit more.
inline fn queryAndCachePointer(wm: *WM) void {
    const pointer_query = xcb.xcb_query_pointer(wm.conn, wm.root);
    const pointer_reply = xcb.xcb_query_pointer_reply(wm.conn, pointer_query, null);

    if (pointer_reply) |reply| {
        defer std.c.free(reply); //TODO: what does this do?

        wm.last_pointer_x = reply.*.root_x;
        wm.last_pointer_y = reply.*.root_y;
    }
}

// Extract off-screen positioning
// TODO: it isn't very clear to me as to what this does.
// please clarify a bit more.
inline fn positionOffScreen(conn: *xcb.xcb_connection_t, win: u32) void {
    const off_screen_x: i32 = -4000; //TODO: what does this do?
    const values = [_]u32{@bitCast(off_screen_x)};

    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_X, &values);
}

// Extract window setup logic
// TODO: be a bit more in depth: whats the purpose of this?
fn setupWindow(wm: *WM, win: u32, is_current_workspace: bool, validated_ws: u8) !void {
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
    
    if (!is_current_workspace) positionOffScreen(wm.conn, win);
    
    wm.addWindow(win) catch |err| {
        debug.err("Failed to track window {x}: {}", .{ win, err });
        return err;
    };
    
    if (is_current_workspace) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_ws);
    }
}

// Extract tiling setup logic
// TODO: be a bit more in depth: whats the purpose of this?
fn setupTiling(wm: *WM, win: u32, is_current_workspace: bool) void {
    if (!wm.config.tiling.enabled) return;
    
    const border_width = wm.config.tiling.border_width;
    _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &[_]u32{@intFromFloat(border_width.value)});
    if (is_current_workspace) {
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL,
            &[_]u32{wm.config.tiling.border_unfocused});
    }
    tiling.addWindow(wm, win);
}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) {
        _ = xcb.xcb_map_window(wm.conn, win);
        utils.flush(wm.conn);
        return;
    }

    const current_workspace = workspaces.getCurrentWorkspace() orelse 0;
    const target_workspace = matchWorkspaceRule(wm, win);
    const validated_ws = validateWorkspace(target_workspace, current_workspace);
    const is_current_workspace = (validated_ws == current_workspace);

    // Query pointer position BEFORE mapping to establish baseline
    if (is_current_workspace) queryAndCachePointer(wm);

    setupWindow(wm, win, is_current_workspace, validated_ws) catch return;
    _ = xcb.xcb_map_window(wm.conn, win);
    setupTiling(wm, win, is_current_workspace);
    utils.flush(wm.conn);
    
    // Focus new window if on current workspace
    if (is_current_workspace) {
        wm.suppress_focus_reason = .window_spawn;
        focus.setFocus(wm, win, .tiling_operation);
    } else {
        grabButtons(wm, win, false);
    }
    
    bar.markDirty();
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const win = event.window;
    
    if (wm.config.tiling.enabled and tiling.isWindowTiled(win)
    or wm.fullscreen.isFullscreen(win))
        return;

    const values = [_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    };
    _ = xcb.xcb_configure_window(wm.conn, win, event.value_mask, &values);
    
    // Invalidate cached geometry after configuration change
    //TODO: try to make this process a bit simpler,
    // or at least change the naming. "invalidating window geometry"
    // is a bit too obtusely worded or over-complex
    tiling.invalidateWindowGeometry(win);
    
    utils.flush(wm.conn);
}

// Minimal filtering for basic focus-follows-mouse
pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    const win = event.event;
    
    // Only basic sanity checks
    if (win == wm.root or win == 0 or bar.isBarWindow(win)) return;
    if (!wm.hasWindow(win)) return;

    //TODO: why are both "win == 0" and "!wm.hasWindow(win)" checked for?
    //      don't they do the same thing?

    // Only focus windows on the current workspace
    if (!workspaces.isOnCurrentWorkspace(win)) return;
    
    // Change focus
    if (wm.focused_window == win) return;
        const old_focus = wm.focused_window;
        focus.setFocus(wm, win, .mouse_enter);
        tiling.updateWindowFocus(wm, old_focus, win);
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    const win = event.event;
    
    if (win == wm.root or win == 0 or bar.isBarWindow(win)) return;
    
    // CRITICAL: Only focus windows on the current workspace
    if (!workspaces.isOnCurrentWorkspace(win)) return;
    
    // Focus window and replay the event
    focus.setFocus(wm, win, .mouse_click);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, xcb.XCB_CURRENT_TIME);
    utils.flush(wm.conn);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) return;

    // Clean up fullscreen state
    if (wm.fullscreen.isFullscreen(win)) {
        cleanupFullscreenWindow(wm, win);
        bar.setBarState(wm, .show_fullscreen);
    }

    const was_focused = (wm.focused_window == win);

    if (wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }
    
    // OPTIMIZATION: Invalidate cached geometry when window is destroyed
    tiling.invalidateWindowGeometry(win);

    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (was_focused) {
        // Retile FIRST to position windows correctly
        if (wm.config.tiling.enabled) {
            tiling.retileIfDirty(wm);
            utils.flush(wm.conn);
        }
        
        focus.clearFocus(wm);
        
        // IMPROVED: Explicitly enable focus-follows-mouse after window destruction
        // This is the OPPOSITE of window spawn behavior
        wm.suppress_focus_reason = .none;
        
        // Query and update pointer position for accurate tracking
        const pointer_query = xcb.xcb_query_pointer(wm.conn, wm.root);
        const pointer_reply = xcb.xcb_query_pointer_reply(wm.conn, pointer_query, null);
        if (pointer_reply) |reply| {
            defer std.c.free(reply);
            wm.last_pointer_x = reply.*.root_x;
            wm.last_pointer_y = reply.*.root_y;
        }
        
        // Now focus window under pointer (focus SHOULD steal here)
        focusWindowUnderPointer(wm);
    }

    bar.markDirty();
    utils.flush(wm.conn);
}

// Focus the window currently under the pointer
fn focusWindowUnderPointer(wm: *WM) void {
    const pointer_query = xcb.xcb_query_pointer(wm.conn, wm.root);
    const pointer_reply = xcb.xcb_query_pointer_reply(wm.conn, pointer_query, null);
    
    if (pointer_reply) |reply| {
        defer std.c.free(reply);
        
        const child_win = reply.*.child;
        
        // If pointer is over a valid window, focus it
        if (child_win != 0 and child_win != wm.root and !bar.isBarWindow(child_win)) {
            if (wm.windows.contains(child_win) and workspaces.isOnCurrentWorkspace(child_win)) {
                focus.setFocus(wm, child_win, .mouse_enter);
                tiling.updateWindowFocus(wm, null, child_win);
                return;
            }
        }
    }
    
    // Fallback: focus first window in workspace if pointer isn't over anything valid
    if (workspaces.getCurrentWorkspaceObject()) |ws| {
        const windows = ws.windows.items();
        for (windows) |workspace_win| {
            if (workspace_win != 0 and workspace_win != wm.root and 
                !bar.isBarWindow(workspace_win) and wm.windows.contains(workspace_win)) {
                focus.setFocus(wm, workspace_win, .window_destroyed);
                tiling.updateWindowFocus(wm, null, workspace_win);
                return;
            }
        }
    }
}

inline fn cleanupFullscreenWindow(wm: *WM, win: u32) void {
    var it = wm.fullscreen.per_workspace.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.window == win) {
            wm.fullscreen.removeForWorkspace(entry.key_ptr.*);
            break;
        }
    }
}

inline fn matchWorkspaceRule(wm: *WM, win: u32) ?u8 {
    const rules = wm.config.workspaces.rules.items;
    if (rules.len == 0) return null;

    const wm_class = utils.getWMClass(wm.conn, win, wm.allocator) orelse return null;
    defer wm_class.deinit(wm.allocator);

    for (rules) |rule| {
        if (std.mem.eql(u8, rule.class_name, wm_class.class) or
            std.mem.eql(u8, rule.class_name, wm_class.instance))
        {
            return rule.workspace;
        }
    }

    return null;
}
