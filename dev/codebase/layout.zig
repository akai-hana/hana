///! Current layout indicator segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const tiling = @import("tiling");

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
) !u16 {
    const t_state = tiling.getState() orelse return start_x;

    const layout_str = switch (t_state.layout) {
        .master => "[]=",
        .monocle => "[M]",
        .grid => "[+]",
    };

    const text_w = dc.textWidth(layout_str);
    const width = text_w + config.padding * 2;

    dc.fillRect(start_x, 0, width, height, config.bg);
    try dc.drawText(start_x + config.padding, dc.baselineY(height), layout_str, config.fg);

    return start_x + width;
}
