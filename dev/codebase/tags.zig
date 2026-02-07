///! Tag workspace indicators segment

const std        = @import("std");
const defs       = @import("defs");
const drawing    = @import("drawing");
const workspaces = @import("workspaces");
const bar        = @import("bar");

const WORKSPACE_WIDTH = bar.WORKSPACE_WIDTH;

const static_numbers = blk: {
    var nums: [20][]const u8 = undefined;
    for (&nums, 1..) |*num, i| num.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk nums;
};

inline fn drawIndicator(dc: *drawing.DrawContext, x: u16, size: u16, filled: bool, fg: u32) void {
    const ix, const iy = .{ x + 3, 3 };
    if (filled) {
        dc.fillRect(ix, iy, size, size, fg);
    } else {
        dc.fillRect(ix, iy, size, 1, fg);
        dc.fillRect(ix, iy + size - 1, size, 1, fg);
        if (size > 2) {
            dc.fillRect(ix, iy + 1, 1, size - 2, fg);
            dc.fillRect(ix + size - 1, iy + 1, 1, size - 2, fg);
        }
    }
}

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    var x = start_x;
    const scaled_ws_width = config.scaledWorkspaceWidth();
    const scaled_indicator_size = config.scaledIndicatorSize();
    
    // Get font metrics for centering calculation
    const asc = dc.getAscender();
    const desc = -dc.getDescender(); // getDescender returns negative

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == ws_state.current;
        const bg = if (is_current) config.selected_bg else config.bg;
        const fg = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, scaled_ws_width, height, bg);
        
        const label = if (i < config.workspace_icons.items.len) 
            config.workspace_icons.items[i]
        else if (i < static_numbers.len) 
            static_numbers[i] 
        else "?";
        
        // For CJK characters, use actual rendered height to find visual center
        const actual_height = dc.textHeight(label);
        const font_height: i32 = asc + desc;
        
        // If actual height differs from font height, adjust centering
        const height_diff: i32 = font_height - @as(i32, actual_height);
        const adjustment: i32 = @divTrunc(height_diff, 2);
        
        const base_y: i32 = @intCast(dc.baselineY(height));
        const text_y: u16 = @intCast(base_y - adjustment);
        
        try dc.drawText(x + (scaled_ws_width - dc.textWidth(label)) / 2, text_y, label, fg);

        // Draw window presence indicator
        if (ws.windows.list.items.len > 0) {
            drawIndicator(dc, x, scaled_indicator_size, is_current, fg);
        }
        
        x += scaled_ws_width;
    }
    return x;
}
