// Partial drawing.zig optimization - showing key changes only
// Full file would be 401 lines → ~380 lines (-21 LoC)

// OPTIMIZATION 1: Simplified openVerified (lines 204-231)
// BEFORE: 28 lines → AFTER: 24 lines (-4 lines)

fn openVerified(self: *DrawContext, pattern: []const u8) ?*c.XftFont {
    const pattern_z = self.allocator.dupeZ(u8, pattern) catch return null;
    defer self.allocator.free(pattern_z);

    const font = c.XftFontOpenName(self.display, 0, pattern_z.ptr) orelse return null;

    var family_cstr: [*:0]const u8 = undefined;
    if (c.FcPatternGetString(font.*.pattern, "family", 0, @ptrCast(&family_cstr)) != 0) {
        std.log.warn("[drawing] Could not verify family for '{s}', accepting anyway", .{pattern});
        return font;
    }
    
    const actual = std.mem.span(family_cstr);
    const colon = std.mem.indexOfScalar(u8, pattern, ':') orelse pattern.len;
    const requested = pattern[0..colon];
    
    const shorter, const longer = if (actual.len < requested.len) 
        .{ actual, requested } else .{ requested, actual };
    
    if (shorter.len == 0 or !std.mem.startsWith(u8, longer, shorter)) {
        c.XftFontClose(self.display, font);
        return null;
    }

    std.log.info("[drawing] Font verified: {s}", .{pattern});
    return font;
}

// OPTIMIZATION 2: Condensed getter methods (lines 381-399)
// BEFORE: 19 lines → AFTER: 13 lines (-6 lines)

pub inline fn getAscender(self: *DrawContext) i16 { return @intCast(self.xft_font.*.ascent); }
pub inline fn getDescender(self: *DrawContext) i16 { return -@as(i16, @intCast(self.xft_font.*.descent)); }
pub inline fn flush(self: *DrawContext) void { _ = c.XFlush(self.display); }

pub inline fn baselineY(self: *DrawContext, bar_height: u16) u16 {
    const asc: i32 = @intCast(self.xft_font.*.ascent);
    const desc: i32 = @intCast(self.xft_font.*.descent);
    const pad: i32 = @divTrunc(@as(i32, bar_height) - (asc + desc), 2);
    return @intCast(@max(asc, pad + asc));
}

// OPTIMIZATION 3: Simplified color cache get (lines 63-74)
// BEFORE: 12 lines → AFTER: 11 lines (-1 line)

fn get(self: *ColorCache, rgb: u32) *c.XftColor {
    const result = self.colors.getOrPut(rgb) catch {
        std.log.warn("[drawing] Color cache allocation failed, using fallback", .{});
        return &self.fallback_color;
    };

    if (!result.found_existing) {
        _ = c.XftColorAllocValue(self.display, self.visual, self.colormap, 
            &rgbToXRenderColor(rgb), result.value_ptr);
    }
    return result.value_ptr;
}

// OPTIMIZATION 4: Simplified textWidth (lines 360-379)
// BEFORE: 20 lines → AFTER: 17 lines (-3 lines)

pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
    if (self.xft_fonts.len <= 1) {
        var extents: c.XGlyphInfo = undefined;
        c.XftTextExtentsUtf8(self.display, self.xft_font, text.ptr, @intCast(text.len), &extents);
        return @intCast(extents.xOff);
    }
    
    var total_width: i32 = 0;
    var iter = FontRunIterator.init(self, text);
    while (iter.next()) |run| {
        var extents: c.XGlyphInfo = undefined;
        const run_text = text[run.start..run.end];
        c.XftTextExtentsUtf8(self.display, run.font, run_text.ptr, @intCast(run_text.len), &extents);
        total_width += extents.xOff;
    }
    return @intCast(total_width);
}

// OPTIMIZATION 5: Simplified drawText multi-font path (lines 288-310)
// BEFORE: 23 lines → AFTER: 21 lines (-2 lines)

pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
    const xft_color = self.color_cache.get(color);
    
    if (self.xft_fonts.len <= 1) {
        c.XftDrawStringUtf8(self.xft_draw, xft_color, self.xft_font,
            @intCast(x), @intCast(y), text.ptr, @intCast(text.len));
        return;
    }
    
    var current_x: i32 = @intCast(x);
    var iter = FontRunIterator.init(self, text);
    while (iter.next()) |run| {
        const run_text = text[run.start..run.end];
        c.XftDrawStringUtf8(self.xft_draw, xft_color, run.font,
            current_x, @intCast(y), run_text.ptr, @intCast(run_text.len));
        
        var extents: c.XGlyphInfo = undefined;
        c.XftTextExtentsUtf8(self.display, run.font, run_text.ptr, @intCast(run_text.len), &extents);
        current_x += extents.xOff;
    }
}

// OPTIMIZATION 6: Simplified loadFont (lines 184-202)
// BEFORE: 19 lines → AFTER: 16 lines (-3 lines)

pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
    const font_name_z = try self.allocator.dupeZ(u8, font_name);
    defer self.allocator.free(font_name_z);
    
    const font = c.XftFontOpenName(self.display, 0, font_name_z.ptr) orelse 
        c.XftFontOpenName(self.display, 0, "monospace:size=10") orelse {
            std.log.warn("[drawing] Failed to load '{s}' and fallback", .{font_name});
            return error.FontLoadFailed;
        };
    
    if (font == null) std.log.warn("[drawing] Failed to load '{s}', trying fallback", .{font_name});
    
    const slice = try self.allocator.alloc(*c.XftFont, 1);
    slice[0] = font;
    self.xft_fonts = slice;
    self.xft_font = slice[0];
    std.log.info("[drawing] Xft font loaded: {s}", .{font_name});
}

// OPTIMIZATION 7: Simplified init (lines 146-173)
// BEFORE: 28 lines → AFTER: 26 lines (-2 lines)

pub fn init(allocator: std.mem.Allocator, drawable: u32, width: u16, height: u16) !*DrawContext {
    const dc = try allocator.create(DrawContext);
    errdefer allocator.destroy(dc);
    
    const display = c.XOpenDisplay(null) orelse return error.DisplayOpenFailed;
    const visual = c.XDefaultVisual(display, 0);
    const colormap = c.XDefaultColormap(display, 0);
    const xft_draw = c.XftDrawCreate(display, drawable, visual, colormap) orelse {
        _ = c.XCloseDisplay(display);
        return error.XftDrawCreateFailed;
    };
    
    dc.* = DrawContext{
        .allocator = allocator, .display = display, .drawable = drawable,
        .xft_draw = xft_draw, .xft_font = undefined, .xft_fonts = &[0]*c.XftFont{},
        .width = width, .height = height,
        .color_cache = ColorCache.init(allocator, display, visual, colormap),
        .visual = visual, .colormap = colormap,
    };
    
    return dc;
}

/*
Total optimizations in drawing.zig:
- Reduced openVerified: -4 lines
- Condensed getters: -6 lines  
- Simplified color cache: -1 line
- Compact textWidth: -3 lines
- Streamlined drawText: -2 lines
- Simplified loadFont: -3 lines
- Compact init: -2 lines
Total: -21 lines (401 → 380)
*/
