///! Layout icon bar segment — shows the current tiling layout symbol.
///! For the variation indicator see variations.zig.

const defs    = @import("defs");
const drawing = @import("drawing");
const tiling  = @import("tiling");

const layout_icons = [_][]const u8{ "[]=", "[M]", "[+]", "[@]" };

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getState() orelse return start_x;
    const layout_idx = @intFromEnum(t_state.layout);

    const safe_idx  = @min(layout_idx, layout_icons.len - 1);
    const icon      = layout_icons[safe_idx];

    return dc.drawSegment(start_x, height, icon, config.scaledPadding(), config.bg, config.fg);
}
