// Window management - optimized and simplified

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const tiling = @import("tiling");
const xcb = defs.xcb;
const WM = defs.WM;

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_ENTER_NOTIFY,
};

pub fn init(_: *WM) void {
    log.debugWindowModuleInit();
}

pub fn deinit(_: *WM) void {}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => {
            const e: *const xcb.xcb_map_request_event_t = @ptrCast(@alignCast(event));
            log.debugWindowMapRequest(e.window);
            _ = xcb.xcb_map_window(wm.conn, e.window);
        },
        xcb.XCB_CONFIGURE_REQUEST => {
            const e: *const xcb.xcb_configure_request_event_t = @ptrCast(@alignCast(event));
            log.debugWindowConfigure(e.window, e.width, e.height, e.x, e.y);
            
            // Let tiling module handle tiled windows
            if (wm.config.tiling.enabled and tiling.isWindowTiled(e.window)) return;
            
            // Apply configuration for floating windows
            _ = xcb.xcb_configure_window(wm.conn, e.window, e.value_mask, &[_]u32{
                @intCast(e.x),
                @intCast(e.y),
                @intCast(e.width),
                @intCast(e.height),
                @intCast(e.border_width),
            });
        },
        xcb.XCB_ENTER_NOTIFY => {
            const e: *const xcb.xcb_enter_notify_event_t = @ptrCast(@alignCast(event));
            if (e.event == wm.root or e.event == 0) return;
            
            // Focus follows mouse
            _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, e.event, xcb.XCB_CURRENT_TIME);
            _ = xcb.xcb_configure_window(wm.conn, e.event, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
            
            const old_focus = wm.focused_window;
            wm.focused_window = e.event;
            
            log.debugWindowFocusChanged(e.event);
            
            if (old_focus != e.event) {
                tiling.updateWindowFocus(wm, e.event);
            }
        },
        xcb.XCB_DESTROY_NOTIFY => {
            const e: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
            log.debugWindowDestroyed(e.window);
            
            const was_focused = wm.focused_window == e.window;
            wm.removeWindow(e.window);
            
            if (was_focused) {
                wm.focused_window = null;
                // Try to focus any remaining window
                var iter = wm.windows.keyIterator();
                if (iter.next()) |window_id| {
                    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, window_id.*, xcb.XCB_CURRENT_TIME);
                    wm.focused_window = window_id.*;
                }
            }
        },
        else => {},
    }
}
