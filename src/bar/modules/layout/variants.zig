//! Layout variants indicator bar segment
//! Displays the active tiling layout variant as a short indicator string on the bar.

const core = @import("core");
const types = @import("types");

const drawing = @import("drawing");
const hooks = @import("hooks");

/// Draws the layout variants icon on the bar.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    if (!core.getState().config.tiling.enabled) return start_x;
    const layout = hooks.tilingGetCurrentLayout();
    const variants = hooks.tilingGetLayoutVariants();
    const indicator = getIndicator(layout, &variants);
    if (indicator.len == 0) return start_x;
    return dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
}

/// Accessor for the icon of each layout's variants.
fn getIndicator(layout: hooks.TilingLayout, v: *const hooks.TilingLayoutVariants) []const u8 {
    return switch (layout) {
        .master => switch (v.master) {
            .lifo => "[N]",
            .fifo => "=N=",
        },

        .monocle => switch (v.monocle) {
            .gaps => ">-<",
            .gapless => "<->",
        },

        .grid => switch (v.grid) {
            .relaxed => "[~]",
            .rigid => "[#]",
        },

        else => "",
    };
}
