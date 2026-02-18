// Window lifecycle — map/unmap/destroy, configure, enter/button events.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const constants  = @import("constants");
const filters    = @import("filters");
const focus      = @import("focus");
const tiling     = @import("tiling");
const bar        = @import("bar");
const workspaces = @import("workspaces");
const debug      = @import("debug");

const WINDOW_EVENT_MASK = constants.EventMasks.MANAGED_WINDOW;

// Button grabs ─

/// For unfocused windows we grab all buttons in sync mode so we can intercept
/// the click, focus the window, and replay the event.  For focused windows we
/// ungrab so the window receives clicks directly.
pub fn grabButtons(wm: *WM, win: u32, focused: bool) void {
    _ = xcb.xcb_ungrab_button(wm.conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    if (!focused) {
        _ = xcb.xcb_grab_button(
            wm.conn, 0, win, xcb.XCB_EVENT_MASK_BUTTON_PRESS,
            xcb.XCB_GRAB_MODE_SYNC, xcb.XCB_GRAB_MODE_SYNC,
            xcb.XCB_NONE, xcb.XCB_NONE, xcb.XCB_BUTTON_INDEX_ANY, xcb.XCB_MOD_MASK_ANY,
        );
    }
}

// Workspace rule matching ──────────────────────────────────────────────────

fn matchWorkspaceRule(wm: *WM, win: u32) ?u8 {
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

fn validateWorkspace(target: ?u8, current: u8) u8 {
    const ws = target orelse return current;
    const s  = workspaces.getState() orelse return current;
    return if (ws < s.workspaces.len) ws else current;
}

// Setup helpers 

inline fn setupTiling(wm: *WM, win: u32, on_current: bool) void {
    if (!wm.config.tiling.enabled) return;
    tiling.addWindow(wm, win);
    if (on_current) tiling.retileCurrentWorkspace(wm, false);
}

inline fn setupWindow(wm: *WM, win: u32, workspace_index: u8) !void {
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
    try wm.addWindow(win);
    workspaces.moveWindowTo(wm, win, workspace_index);
}

// Map request ──

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win          = event.window;
    const current_ws   = workspaces.getCurrentWorkspace() orelse 0;
    const validated_ws = validateWorkspace(matchWorkspaceRule(wm, win), current_ws);
    const is_current   = (validated_ws == current_ws);

    setupWindow(wm, win, validated_ws) catch |err| { debug.logError(err, win); return; };

    // Only map immediately for the current workspace.  Windows on inactive
    // workspaces are left unmapped so the compositor never allocates a buffer
    // for off-screen content.  executeSwitch() maps them inside the server grab.
    if (is_current) _ = xcb.xcb_map_window(wm.conn, win);

    utils.cacheWindowFocusProps(wm.conn, win);
    setupTiling(wm, win, is_current);
    utils.flush(wm.conn);

    if (is_current) {
        focus.setFocus(wm, win, .window_spawn);
        // Re-arm POINTER_MOTION_HINT so the next mouse movement generates a
        // fresh MotionNotify.  Without this, the hint consumed before the spawn
        // is never replaced, handleMotionNotify never fires, and
        // suppress_focus_reason stays .window_spawn until the user clicks.
        if (xcb.xcb_query_pointer_reply(
            wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
        )) |reply| std.c.free(reply);
    } else {
        grabButtons(wm, win, false);
    }

    bar.markDirty();
}

// Configure request ────────────────────────────────────────────────────────

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    const win = event.window;
    if ((wm.config.tiling.enabled and tiling.isWindowTiled(win)) or
        wm.fullscreen.isFullscreen(win)) return;

    // Honour only the geometry bits we provide values for.  Passing the raw
    // value_mask unmodified would cause XCB to read past our value array if
    // the client also sets Sibling (0x020) or StackMode (0x040).
    const GEOMETRY_MASK: u16 =
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
    const mask = event.value_mask & GEOMETRY_MASK;
    if (mask == 0) return;

    // XCB reads values in bit-order: for each set bit in mask (lowest first)
    // it consumes values[0], values[1], etc.  Providing all 5 values regardless
    // of which bits are set is wrong — e.g. if only WIDTH|HEIGHT are requested,
    // XCB reads values[0] for width, but we would have stored event.x there.
    var values: [5]u32 = undefined;
    var n: u3 = 0;
    if (mask & xcb.XCB_CONFIG_WINDOW_X != 0)            { values[n] = @bitCast(@as(i32, event.x));            n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_Y != 0)            { values[n] = @bitCast(@as(i32, event.y));            n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0)        { values[n] = event.width;                            n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0)       { values[n] = event.height;                           n += 1; }
    if (mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0) { values[n] = event.border_width;                     n += 1; }
    _ = xcb.xcb_configure_window(wm.conn, win, mask, &values);
    utils.flush(wm.conn);
}

// Focus events ─────────────────────────────────────────────────────────────

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    // Filter GRAB/UNGRAB crossings (passive grab activate/deactivate).
    // WHILE_GRABBED must pass through — it fires during active grabs from
    // other clients (GTK, Qt) and represents genuine pointer movement.
    if (event.mode == xcb.XCB_NOTIFY_MODE_GRAB or
        event.mode == xcb.XCB_NOTIFY_MODE_UNGRAB) return;
    if (wm.drag_state.active) return;
    if (wm.suppress_focus_reason == .window_spawn) return;

    const win = if (event.event == wm.root and event.child != 0)
        event.child
    else
        event.event;

    if (filters.isSystemWindow(wm, win)) return;
    if (!wm.hasWindow(win)) return;
    if (!workspaces.isOnCurrentWorkspace(win)) return;
    if (wm.focused_window == win) return;

    focus.setFocus(wm, win, .mouse_enter);
}

/// Root's LeaveNotify fires the instant the pointer enters any child window,
/// including Electron/Chromium which generates no EnterNotify or MotionNotify
/// events visible to root.  This gives us event-driven focus at the same
/// latency as handleEnterNotify for all other windows.
pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    if (event.event != wm.root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (wm.drag_state.active) return;
    if (wm.suppress_focus_reason == .window_spawn) return;

    // event.child is the direct child of root being entered.
    const target: u32 = if (event.child != 0) event.child else blk: {
        const reply = xcb.xcb_query_pointer_reply(
            wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
        ) orelse return;
        defer std.c.free(reply);
        break :blk reply.*.child;
    };
    if (target == 0 or target == wm.root) return;

    if (filters.isSystemWindow(wm, target)) return;
    if (!wm.hasWindow(target)) return;
    if (!workspaces.isOnCurrentWorkspace(target)) return;
    if (wm.focused_window == target) return;

    focus.setFocus(wm, target, .mouse_enter);
}

// Property notify ──────────────────────────────────────────────────────────

/// Keep the focus-property cache coherent when relevant window properties change.
/// WM_PROTOCOLS: Electron sets WM_TAKE_FOCUS after mapping, so a cached false
///               would make us treat it as passive.  Recompute on any change.
/// WM_HINTS:     The input field is stable in practice, but some apps update it.
///               Recomputing is cheap — one property round-trip, done rarely.
pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *WM) void {
    if (!wm.hasWindow(event.window)) return;
    const wm_protocols = utils.getAtomCached("WM_PROTOCOLS") catch return;
    if (event.atom == wm_protocols) {
        utils.recacheTakeFocus(wm.conn, event.window);
        return;
    }
    if (event.atom == xcb.XCB_ATOM_WM_HINTS) {
        utils.recacheHintsInput(wm.conn, event.window);
    }
}

// Unmap / destroy ──────────────────────────────────────────────────────────

fn unmanageWindow(wm: *WM, win: u32) void {
    if (wm.fullscreen.isFullscreen(win)) {
        // window_to_workspace is the reverse index — O(1) lookup rather than
        // iterating per_workspace to find which workspace holds this window.
        if (wm.fullscreen.window_to_workspace.get(win)) |ws| {
            wm.fullscreen.removeForWorkspace(ws);
        }
        bar.setBarState(wm, .show_fullscreen);
    }

    const was_focused = (wm.focused_window == win);

    if (wm.config.tiling.enabled) tiling.removeWindow(win);
    utils.uncacheWindowFocusProps(win);
    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (was_focused) {
        if (wm.config.tiling.enabled) tiling.retileIfDirty(wm);
        focus.clearFocus(wm);
        focusWindowUnderPointer(wm);
    }

    bar.markDirty();
    utils.flush(wm.conn);
}

pub fn handleUnmapNotify(event: *const xcb.xcb_unmap_notify_event_t, wm: *WM) void {
    const win = event.window;
    if (bar.isBarWindow(win) or !wm.hasWindow(win)) return;
    unmanageWindow(wm, win);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;
    if (bar.isBarWindow(win)) return;
    unmanageWindow(wm, win);
}

// Post-unmanage focus recovery ─────────────────────────────────────────────

fn focusWindowUnderPointer(wm: *WM) void {
    const reply = xcb.xcb_query_pointer_reply(
        wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
    ) orelse { focusFallback(wm); return; };
    defer std.c.free(reply);

    const child = reply.*.child;
    if (filters.isValidManagedWindow(wm, child) and workspaces.isOnCurrentWorkspace(child)) {
        focus.setFocus(wm, child, .mouse_enter);
        tiling.updateWindowFocus(wm, null, child);
        return;
    }
    focusFallback(wm);
}

/// Focus the first visible window in the current workspace (last-resort fallback).
fn focusFallback(wm: *WM) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse return;
    for (ws.windows.items()) |win| {
        if (filters.isValidManagedWindow(wm, win)) {
            focus.setFocus(wm, win, .window_destroyed);
            tiling.updateWindowFocus(wm, null, win);
            return;
        }
    }
}
