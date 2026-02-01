///! Tag workspace indicators segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const workspaces = @import("workspaces");
const bar = @import("bar");

// OPTIMIZATION: Use shared workspace width constant
const WORKSPACE_WIDTH = bar.WORKSPACE_WIDTH;

// OPTIMIZATION: Compile-time constant array avoids recreation on each call
const static_numbers = [_][]const u8{
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
    "11", "12", "13", "14", "15", "16", "17", "18", "19", "20"
};

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    
    var x = start_x;
    // OPTIMIZATION: Calculate baseline once instead of per-workspace
    const text_y = dc.baselineY(height);

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = (i == ws_state.current);
        const has_windows = ws.windows.items.len > 0;

        const bg = if (is_current) config.selected_bg else config.bg;
        const fg = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, WORKSPACE_WIDTH, height, bg);

        const label = getWorkspaceLabel(config, i);
        const text_x = x + (WORKSPACE_WIDTH - dc.textWidth(label)) / 2;
        try dc.drawText(text_x, text_y, label, fg);

        if (has_windows) {
            drawIndicator(dc, config, x, is_current, fg);
        }

        x += WORKSPACE_WIDTH;
    }

    return x;
}

fn getWorkspaceLabel(config: defs.BarConfig, index: usize) []const u8 {
    if (index < config.workspace_icons.items.len) {
        return config.workspace_icons.items[index];
    }
    
    return if (index < static_numbers.len) static_numbers[index] else "?";
}

fn drawIndicator(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    ws_x: u16,
    is_current: bool,
    color: u32,
) void {
    const size = @max(config.indicator_size, 2);
    const x = ws_x + 3;
    const y: u16 = 3;

    if (is_current) {
        dc.fillRect(x, y, size, size, color);
    } else {
        // OPTIMIZATION: Hollow rect with fewer calls (merged horizontal and vertical edges)
        // Top and bottom edges
        dc.fillRect(x, y, size, 1, color);
        dc.fillRect(x, y + size - 1, size, 1, color);
        // Left and right edges (excluding corners already drawn)
        if (size > 2) {
            dc.fillRect(x, y + 1, 1, size - 2, color);
            dc.fillRect(x + size - 1, y + 1, 1, size - 2, color);
        }
    }
}
