//! Window event handlers - FIXED: instant spawning

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const bar = @import("bar");
const batch = @import("batch");

pub fn init(_: *WM) void {}
pub fn deinit(_: *WM) void {}

pub fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) {
        _ = xcb.xcb_map_window(wm.conn, win);
        return;
    }

    const target_ws = if (wm.config.workspaces.rules.items.len > 0)
        matchWorkspaceRule(wm, win)
    else
        null;

    const current_ws = workspaces.getCurrentWorkspace() orelse 0;

    const validated_target_ws = if (target_ws) |ws| blk: {
        const ws_state = workspaces.getState() orelse break :blk current_ws;
        if (ws >= ws_state.workspaces.len) {
            std.log.warn("[window] Rule workspace {} exceeds count, using current", .{ws});
            break :blk current_ws;
        }
        break :blk ws;
    } else current_ws;

    var b = batch.Batch.begin(wm) catch {
        handleMapRequestSlow(wm, win, validated_target_ws, current_ws);
        return;
    };
    defer b.deinit();

    b.map(win) catch {};
    wm.addWindow(win) catch {};

    if (validated_target_ws == current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_target_ws);
    }

    if (wm.config.tiling.enabled) {
        if (validated_target_ws == current_ws) {
            b.setBorderWidth(win, wm.config.tiling.border_width) catch {};
            b.setBorder(win, wm.config.tiling.border_normal) catch {};
        }
    }

    b.execute();

    // FIXED: Add to tiling and retile immediately
    if (wm.config.tiling.enabled and validated_target_ws == current_ws) {
        tiling.addWindow(wm, win);
        // Immediately retile instead of waiting for event loop
        tiling.retileCurrentWorkspace(wm);
    }

    bar.markDirty();
}

fn handleMapRequestSlow(wm: *WM, win: u32, validated_target_ws: usize, current_ws: usize) void {
    _ = xcb.xcb_map_window(wm.conn, win);
    wm.addWindow(win) catch {};

    if (validated_target_ws == current_ws) {
        workspaces.addWindowToCurrentWorkspace(wm, win);
    } else {
        workspaces.moveWindowTo(wm, win, validated_target_ws);
    }

    if (wm.config.tiling.enabled) {
        const attrs = utils.WindowAttrs{
            .border_width = wm.config.tiling.border_width,
            .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
        };
        attrs.configure(wm.conn, win);

        if (validated_target_ws == current_ws) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
    } else {
        utils.flush(wm.conn);
    }

    bar.markDirty();
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM) void {
    if (wm.config.tiling.enabled and tiling.isWindowTiled(event.window)) return;

    _ = xcb.xcb_configure_window(wm.conn, event.window, event.value_mask, &[_]u32{
        @intCast(event.x),
        @intCast(event.y),
        @intCast(event.width),
        @intCast(event.height),
        @intCast(event.border_width),
    });
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t, wm: *WM) void {
    if (event.event == wm.root or event.event == 0) return;
    if (bar.isBarWindow(event.event)) return;
    if (utils.isProtected()) return;

    const old_focus = wm.focused_window;
    utils.setFocus(wm, event.event, false);

    tiling.updateWindowFocus(wm, old_focus, event.event);
}

pub fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM) void {
    const win = event.window;

    if (bar.isBarWindow(win)) return;

    if (wm.config.tiling.enabled) {
        tiling.removeWindow(wm, win);
    }

    workspaces.removeWindow(win);
    wm.removeWindow(win);

    if (wm.focused_window == win) {
        utils.clearFocus(wm);
    }

    bar.markDirty();
}

fn matchWorkspaceRule(wm: *WM, win: u32) ?usize {
    if (wm.config.workspaces.rules.items.len == 0) return null;

    const wm_class = utils.getWMClass(wm.conn, win, wm.allocator) orelse return null;
    defer wm_class.deinit(wm.allocator);

    for (wm.config.workspaces.rules.items) |rule| {
        if (std.mem.eql(u8, rule.class_name, wm_class.class) or
            std.mem.eql(u8, rule.class_name, wm_class.instance))
        {
            return rule.workspace;
        }
    }

    return null;
}
