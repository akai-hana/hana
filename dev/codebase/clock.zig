///! Clock segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
) !u16 {
    var time_buf: [64]u8 = undefined;
    const time_str = try formatTime(&time_buf);

    const text_w = dc.textWidth(time_str);
    const width = text_w + config.padding * 2;

    dc.fillRect(start_x, 0, width, height, config.bg);

    const text_y = calculateTextY(dc, height);
    try dc.drawText(start_x + config.padding, text_y, time_str, config.fg);

    return start_x + width;
}

fn calculateTextY(dc: *drawing.DrawContext, height: u16) u16 {
    const ascender: i32 = dc.getAscender();
    const descender: i32 = dc.getDescender();

    const font_height: i32 = ascender - descender;
    const vertical_padding: i32 = @divTrunc(@as(i32, height) - font_height, 2);
    const baseline_y: i32 = vertical_padding + ascender;

    return @intCast(@max(ascender, baseline_y));
}

fn formatTime(buf: []u8) ![]const u8 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
        return try std.fmt.bufPrint(buf, "????-??-?? ??:??:??", .{});
    };

    // Get local timezone offset
    const local_ts = std.c.localtime(&ts.sec) orelse {
        // Fallback to UTC if localtime fails
        const epoch_seconds: i64 = ts.sec;
        const epoch_day = @divFloor(epoch_seconds, std.time.s_per_day);
        const day_seconds = @mod(epoch_seconds, std.time.s_per_day);

        const civil_day = std.time.epoch.EpochDay{ .day = @intCast(epoch_day) };
        const year_day = civil_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        const hours: u32 = @intCast(@divFloor(day_seconds, std.time.s_per_hour));
        const minutes: u32 = @intCast(@divFloor(@mod(day_seconds, std.time.s_per_hour), std.time.s_per_min));
        const seconds: u32 = @intCast(@mod(day_seconds, std.time.s_per_min));

        return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            hours,
            minutes,
            seconds,
        });
    };

    // Use localtime which respects system timezone
    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        local_ts.tm_year + 1900,
        local_ts.tm_mon + 1,
        local_ts.tm_mday,
        local_ts.tm_hour,
        local_ts.tm_min,
        local_ts.tm_sec,
    });
}
