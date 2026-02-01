///! Current layout indicator segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const tiling = @import("tiling");

// OPTIMIZATION: Compile-time constant strings
const LAYOUT_MASTER = "[]=";
const LAYOUT_MONOCLE = "[M]";
const LAYOUT_GRID = "[+]";

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
) !u16 {
    const t_state = tiling.getState() orelse return start_x;

    const layout_str = switch (t_state.layout) {
        .master => LAYOUT_MASTER,
        .monocle => LAYOUT_MONOCLE,
        .grid => LAYOUT_GRID,
    };

    const text_w = dc.textWidth(layout_str);
    const width = text_w + config.padding * 2;

    dc.fillRect(start_x, 0, width, height, config.bg);
    try dc.drawText(start_x + config.padding, dc.baselineY(height), layout_str, config.fg);

    return start_x + width;
}
