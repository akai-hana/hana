///! Clock segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");

const c = @cImport({
    @cInclude("time.h");
});

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
) !u16 {
    // OPTIMIZATION: Reduced buffer size from 64 to exactly what we need (19 chars + null)
    var time_buf: [20]u8 = undefined;
    const time_str = try formatTime(&time_buf);

    const text_w = dc.textWidth(time_str);
    const width = text_w + config.padding * 2;

    dc.fillRect(start_x, 0, width, height, config.bg);
    try dc.drawText(start_x + config.padding, dc.baselineY(height), time_str, config.fg);

    return start_x + width;
}

fn formatTime(buf: []u8) ![]const u8 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
        return try std.fmt.bufPrint(buf, "????-??-?? ??:??:??", .{});
    };

    var raw_sec: c.time_t = @intCast(ts.sec);
    const local_ts = c.localtime(&raw_sec) orelse {
        return formatUtc(buf, ts.sec);
    };

    // OPTIMIZATION: Direct cast from c_int to u32, avoiding intermediate steps
    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(local_ts.*.tm_year + 1900)),
        @as(u32, @intCast(local_ts.*.tm_mon + 1)),
        @as(u32, @intCast(local_ts.*.tm_mday)),
        @as(u32, @intCast(local_ts.*.tm_hour)),
        @as(u32, @intCast(local_ts.*.tm_min)),
        @as(u32, @intCast(local_ts.*.tm_sec)),
    });
}

fn formatUtc(buf: []u8, epoch_sec: i64) ![]const u8 {
    const epoch_day  = @divFloor(epoch_sec, std.time.s_per_day);
    const day_sec    = @mod(epoch_sec, std.time.s_per_day);

    const civil_day  = std.time.epoch.EpochDay{ .day = @intCast(epoch_day) };
    const year_day   = civil_day.calculateYearDay();
    const month_day  = year_day.calculateMonthDay();

    const hours:   u32 = @intCast(@divFloor(day_sec, std.time.s_per_hour));
    const minutes: u32 = @intCast(@divFloor(@mod(day_sec, std.time.s_per_hour), std.time.s_per_min));
    const seconds: u32 = @intCast(@mod(day_sec, std.time.s_per_min));

    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        hours, minutes, seconds,
    });
}
