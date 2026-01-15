// Tiling layout manager - automatic window arrangement
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const xcb = defs.xcb;
const WM = defs.WM;
pub const Layout = enum {
    tile, // Master-stack layout
    monocle, // Fullscreen/tabbed
    grid, // Grid layout
};
pub const TilingState = struct {
    enabled: bool = true,
    layout: Layout = .tile,
    master_width_factor: f32 = 0.55, // Master takes 55% of screen
    gaps: u16 = 10,
    border_width: u16 = 2,
    border_focused: u32 = 0x5294E2, // Blue
    border_normal: u32 = 0x383C4A, // Dark gray

    // Track tiled windows in order
    tiled_windows: std.ArrayList(u32),
    master_count: usize = 1, // Number of windows in master area
};
var tiling_state: ?*TilingState = null;
pub fn init(wm: *WM) void {
    const state = wm.allocator.create(TilingState) catch {
        std.log.err("Failed to allocate tiling state", .{});
        return;
    };

    // Explicitly initialize the field
    state.* = .{
        .tiled_windows = .{},
        .master_count = 1,
        .enabled = true,
        .layout = .tile,
    };

    tiling_state = state;

    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Module initialized - layout: tile, gaps: {}px\n",
            .{state.gaps});
    }
}
pub fn deinit(wm: *WM) void {
    if (tiling_state) |state| {
        state.tiled_windows.deinit(wm.allocator);
        wm.allocator.destroy(state);
        tiling_state = null;
    }
}
pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const state = tiling_state orelse return;
    if (!state.enabled) return;

    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => {
            const ev: *const xcb.xcb_map_request_event_t = @ptrCast(@alignCast(event));
            handleMapRequest(ev, wm, state);
        },
        xcb.XCB_DESTROY_NOTIFY => {
            const ev: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
            handleRemoveWindow(ev.window, wm, state);
        },
        xcb.XCB_UNMAP_NOTIFY => {
            const ev: *const xcb.xcb_unmap_notify_event_t = @ptrCast(@alignCast(event));
            handleRemoveWindow(ev.window, wm, state);
        },
        else => {},
    }
}
fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM, state: *TilingState) void {
    // Check if window is already in the tiling list
    for (state.tiled_windows.items) |win| {
        if (win == event.window) {
            // Window already managed, just map it
            _ = xcb.xcb_map_window(wm.conn, event.window);
            return;
        }
    }
    
    // Add window to tiling list
    state.tiled_windows.append(wm.allocator, event.window) catch {
        std.log.err("Failed to add window to tiling list", .{});
        return;
    };

    // Map the window
    _ = xcb.xcb_map_window(wm.conn, event.window);

    // Set border
    _ = xcb.xcb_change_window_attributes(wm.conn, event.window,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{state.border_normal});
    _ = xcb.xcb_configure_window(wm.conn, event.window,
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{state.border_width});

    // Retile all windows
    retile(wm, state);

    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Window {x} added, total windows: {}\n",
            .{event.window, state.tiled_windows.items.len});
    }
}
fn handleRemoveWindow(window: u32, wm: *WM, state: *TilingState) void {
    // Remove from tiling list
    var found = false;
    for (state.tiled_windows.items, 0..) |win, i| {
        if (win == window) {
            _ = state.tiled_windows.orderedRemove(i);
            found = true;
            break;
        }
    }
    if (!found) return;

    // Retile remaining windows
    if (state.tiled_windows.items.len > 0) {
        retile(wm, state);
    }

    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Window {x} removed, remaining: {}\n",
            .{window, state.tiled_windows.items.len});
    }
}
fn retile(wm: *WM, state: *TilingState) void {
    const windows = state.tiled_windows.items;
    if (windows.len == 0) return;

    const screen = wm.screen;
    const screen_width = screen.width_in_pixels;
    const screen_height = screen.height_in_pixels;

    switch (state.layout) {
        .tile => tileMasterStack(wm, state, windows, screen_width, screen_height),
        .monocle => tileMonocle(wm, state, windows, screen_width, screen_height),
        .grid => tileGrid(wm, state, windows, screen_width, screen_height),
    }

    _ = xcb.xcb_flush(wm.conn);
}

fn tileMasterStack(wm: *WM, state: *TilingState, windows: []const u32,
                   screen_w: u16, screen_h: u16) void {
    const n = windows.len;
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;

    // Determine how many windows in master vs stack
    const m_count = @min(state.master_count, n);
    const s_count = if (n > m_count) n - m_count else 0;
    
    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] tileMasterStack: n={}, master_count={}, m_count={}, s_count={}, screen_w={}\n",
            .{n, state.master_count, m_count, s_count, screen_w});
    }

    // Calculate master column width (in pixels on screen)
    // If no stack, master gets full width; otherwise it gets a percentage
    const master_width: u16 = if (s_count == 0) 
        screen_w
    else 
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    // Calculate stack column width
    const stack_width: u16 = if (s_count > 0) screen_w - master_width else 0;

    for (windows, 0..) |win, idx| {
        var x: u16 = 0;
        var y: u16 = 0;
        var w: u16 = 0;
        var h: u16 = 0;

        if (idx < m_count) {
            // MASTER COLUMN (left side)
            const row_height = screen_h / @as(u16, @intCast(m_count));
            const row = @as(u16, @intCast(idx));
            
            x = gap;
            y = gap + (row * row_height);
            w = if (master_width > 2 * gap + 2 * bw) 
                master_width - 2 * gap - 2 * bw 
            else 1;
            h = if (row_height > 2 * gap + 2 * bw)
                row_height - 2 * gap - 2 * bw
            else 1;
        } else {
            // STACK COLUMN (right side)
            const stack_idx = idx - m_count;
            const row_height = screen_h / @as(u16, @intCast(s_count));
            const row = @as(u16, @intCast(stack_idx));
            
            x = master_width + gap;
            y = gap + (row * row_height);
            w = if (stack_width > 2 * gap + 2 * bw)
                stack_width - 2 * gap - 2 * bw
            else 1;
            h = if (row_height > 2 * gap + 2 * bw)
                row_height - 2 * gap - 2 * bw
            else 1;
        }

        configureWindow(wm, win, x, y, w, h);
        
        if (builtin.mode == .Debug) {
            std.debug.print("[tiling] Window {}: x={}, y={}, w={}, h={} (master={})\n",
                .{idx, x, y, w, h, idx < m_count});
        }
    }
}

fn tileMonocle(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    const bw = state.border_width;
    // All windows fullscreen, stacked (last window on top)
    for (windows) |win| {
        configureWindow(wm, win,
            gap,
            gap,
            screen_w - 2 * gap - 2 * bw,
            screen_h - 2 * gap - 2 * bw);
    }

    // Raise last window to top
    if (windows.len > 0) {
        _ = xcb.xcb_configure_window(wm.conn, windows[windows.len - 1],
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
}
fn tileGrid(wm: *WM, state: *TilingState, windows: []const u32,
            screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    const bw = state.border_width;
    const n = windows.len;

    // Calculate grid dimensions
    const cols_f = @ceil(@sqrt(@as(f32, @floatFromInt(n))));
    const cols = @as(u16, @intFromFloat(cols_f));
    const rows = @as(u16, @intCast((n + cols - 1) / cols));

    const cell_w = screen_w / cols;
    const cell_h = screen_h / rows;

    for (windows, 0..) |win, idx| {
        const col = @as(u16, @intCast(idx % cols));
        const row = @as(u16, @intCast(idx / cols));
        
        const x = gap + (col * cell_w);
        const y = gap + (row * cell_h);
        const w = if (cell_w > 2 * gap + 2 * bw)
            cell_w - 2 * gap - 2 * bw
        else 1;
        const h = if (cell_h > 2 * gap + 2 * bw)
            cell_h - 2 * gap - 2 * bw
        else 1;
        
        configureWindow(wm, win, x, y, w, h);
    }
}
fn configureWindow(wm: *WM, window: u32, x: u16, y: u16, width: u16, height: u16) void {
    const values = [_]u32{
        x,
        y,
        @max(1, width),
        @max(1, height),
    };

    _ = xcb.xcb_configure_window(wm.conn, window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}
// Public API for keybindings
pub fn toggleLayout(wm: *WM) void {
    const state = tiling_state orelse return;

    state.layout = switch (state.layout) {
        .tile => .monocle,
        .monocle => .grid,
        .grid => .tile,
    };

    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Layout changed to: {s}\n", .{@tagName(state.layout)});
    }

    retile(wm, state);
}
pub fn increaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_width_factor = @min(0.95, state.master_width_factor + 0.05);
    retile(wm, state);
}
pub fn decreaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_width_factor = @max(0.05, state.master_width_factor - 0.05);
    retile(wm, state);
}
pub fn increaseMasterCount(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_count = @min(state.tiled_windows.items.len, state.master_count + 1);
    retile(wm, state);
}
pub fn decreaseMasterCount(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_count = @max(1, state.master_count - 1);
    retile(wm, state);
}
pub fn toggleTiling(wm: *WM) void {
    const state = tiling_state orelse return;
    state.enabled = !state.enabled;

    if (builtin.mode == .Debug) {
        const status = if (state.enabled) "enabled" else "disabled";
        std.debug.print("[tiling] Tiling {s}\n", .{status});
    }

    if (state.enabled) {
        retile(wm, state);
    }
}
pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_UNMAP_NOTIFY,
};
pub fn createModule() defs.Module {
    return defs.Module{
        .name = "tiling",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
        .deinit_fn = deinit,
    };
}
