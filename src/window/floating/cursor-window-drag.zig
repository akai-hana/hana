// Window dragging with mouse cursor
const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const xcb = defs.xcb;
const WM = defs.WM;

// Drag state
const DragState = struct {
    button: u8 = 0,
    window: u32 = 0,
    start_x: i16 = 0,
    start_y: i16 = 0,
    attr_x: i16 = 0,
    attr_y: i16 = 0,
    attr_width: u16 = 0,
    attr_height: u16 = 0,

    fn isDragging(self: *const DragState) bool {
        return self.window != 0;
    }

    fn reset(self: *DragState) void {
        self.window = 0;
    }
};

var drag_state: DragState = .{};

/// Start dragging a window
/// button 1 = move, button 3 = resize
pub fn startDrag(wm: *WM, window: u32, button: u8, root_x: i16, root_y: i16) void {
    // Only allow left button (move) and right button (resize)
    if (button != 1 and button != 3) return;

    // Get window geometry
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null) orelse return;
    defer std.c.free(geom_reply);

    drag_state = .{
        .button = button,
        .window = window,
        .start_x = root_x,
        .start_y = root_y,
        .attr_x = geom_reply.*.x,
        .attr_y = geom_reply.*.y,
        .attr_width = geom_reply.*.width,
        .attr_height = geom_reply.*.height,
    };

    if (@import("builtin").mode == .Debug) {
        const action = if (button == 1) "move" else "resize";
        std.log.info("[drag] Started {} on window {x} at ({}, {})", .{action, window, root_x, root_y});
    }

    // Raise window to top
    _ = xcb.xcb_configure_window(wm.conn, window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE,
        &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

/// Update drag position
pub fn updateDrag(wm: *WM, root_x: i16, root_y: i16) void {
    if (!drag_state.isDragging()) return;

    const dx: i32 = root_x - drag_state.start_x;
    const dy: i32 = root_y - drag_state.start_y;

    const is_move = drag_state.button == 1;

    if (is_move) {
        // Move window
        const new_x: i16 = @intCast(@as(i32, drag_state.attr_x) + dx);
        const new_y: i16 = @intCast(@as(i32, drag_state.attr_y) + dy);

        const geometry = [_]u32{
            @intCast(@as(i32, new_x)),
            @intCast(@as(i32, new_y)),
        };

        _ = xcb.xcb_configure_window(wm.conn, drag_state.window,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &geometry);
    } else {
        // Resize window
        const new_width = @max(50, @as(i32, drag_state.attr_width) + dx);
        const new_height = @max(50, @as(i32, drag_state.attr_height) + dy);

        const geometry = [_]u32{
            @intCast(new_width),
            @intCast(new_height),
        };

        _ = xcb.xcb_configure_window(wm.conn, drag_state.window,
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
            &geometry);
    }
}

/// Stop dragging
pub fn stopDrag(wm: *WM) void {
    if (!drag_state.isDragging()) return;

    if (@import("builtin").mode == .Debug) {
        std.log.info("[drag] Stopped dragging window {x}", .{drag_state.window});
    }

    _ = xcb.xcb_flush(wm.conn);
    drag_state.reset();
}

/// Check if currently dragging
pub fn isDragging() bool {
    return drag_state.isDragging();
}

/// Get the window being dragged
pub fn getDraggedWindow() ?u32 {
    return if (drag_state.isDragging()) drag_state.window else null;
}
