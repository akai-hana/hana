//! Workspace tag indicator segment.
//!
//! Owns the workspace segment cache that was previously split across cache.zig
//! and bar.State: label pixel-widths, workspace cell width, and indicator size.
//! All three are measured/derived once and reused across redraws.
//! Call `invalidate()` whenever the font, config, or DPI changes (i.e. on bar
//! reload) so the next draw remeasures everything with the fresh DrawContext.

const std        = @import("std");
const defs       = @import("defs");
const drawing    = @import("drawing");
const workspaces = @import("workspaces");

// Module-level cache 

/// Comptime-generated label strings "1".."20". Never heap-allocated.
const static_numbers = blk: {
    var nums: [20][]const u8 = undefined;
    for (&nums, 1..) |*num, i| num.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk nums;
};

var label_widths:   [20]u16 = [_]u16{0} ** 20;

/// Returns the display label for workspace `i` — configured icon, fallback number, or "?".
inline fn getLabel(i: usize, config: defs.BarConfig) []const u8 {
    if (i < config.workspace_icons.items.len) return config.workspace_icons.items[i];
    if (i < static_numbers.len)               return static_numbers[i];
    return "?";
}
var ws_width:       u16     = 0;
var indicator_size: u16     = 0;
var cache_valid:    bool    = false;

/// Marks the cache stale. Call on bar reload (font/config/DPI change) so the
/// next draw remeasures label widths and re-derives layout constants.
pub fn invalidate() void { cache_valid = false; }

/// Returns the cached workspace cell width (pixels). Valid after first draw.
/// Used by bar.zig for segment width calculation and click hit-testing.
pub fn getCachedWorkspaceWidth() u16 { return ws_width; }

// Private helpers 

/// Populates label_widths, ws_width, and indicator_size from the current
/// DrawContext and config. No-ops when cache_valid is already true.
fn ensureCache(dc: *drawing.DrawContext, config: defs.BarConfig) void {
    if (cache_valid) return;
    for (&label_widths, 0..) |*w, i| w.* = dc.textWidth(getLabel(i, config));
    ws_width       = config.scaledWorkspaceWidth();
    indicator_size = config.scaledIndicatorSize();
    cache_valid    = true;
}

/// Draws a filled or hollow square indicator for workspace activity.
inline fn drawIndicator(dc: *drawing.DrawContext, x: u16, size: u16, filled: bool, fg: u32) void {
    const ix, const iy = .{ x + 3, 3 };
    if (filled) {
        dc.fillRect(ix, iy, size, size, fg);
    } else {
        dc.fillRect(ix, iy,              size, 1,          fg);
        dc.fillRect(ix, iy + size - 1,   size, 1,          fg);
        if (size > 2) {
            dc.fillRect(ix,            iy + 1, 1,      size - 2, fg);
            dc.fillRect(ix + size - 1, iy + 1, 1,      size - 2, fg);
        }
    }
}

// Public draw 

/// Draws all workspace tags starting at `start_x`, returning the next X position.
pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    ensureCache(dc, config);
    var x = start_x;

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == ws_state.current;
        const bg         = if (is_current) config.selected_bg else config.bg;
        const fg         = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, ws_width, height, bg);

        const label   = getLabel(i, config);
        const label_w = if (i < label_widths.len) label_widths[i] else dc.textWidth(label);
        const text_x  = x + (ws_width - label_w) / 2;
        try dc.drawText(text_x, dc.baselineY(height), label, fg);

        if (ws.windows.count() > 0) {
            drawIndicator(dc, x, indicator_size, is_current, fg);
        }

        x += ws_width;
    }
    return x;
}
