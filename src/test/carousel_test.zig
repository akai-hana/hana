//! Unit tests for the title-carousel state machine (carousel.zig).
//!
//! The module is pure deadline/offset math driven by an injected monotonic
//! clock, so every scenario below is deterministic: no sleeps, no rendering.

const std = @import("std");
const testing = std.testing;

const carousel = @import("carousel");

const short_title = "Short";
const long_title = "A window title long enough to overflow any reasonable bar slot";

fn reset() void {
    carousel.resetForTesting();
}

/// Convenience wrapper: enabled scroll of `text_w` in an `avail_w` slot.
fn tick(win: u32, text_w: u16, avail_w: u16, speed: u16, now_ms: i64) u16 {
    return carousel.offsetFor(win, long_title, text_w, avail_w, true, speed, now_ms);
}

test "fitting title stays static and inactive" {
    reset();
    const off = carousel.offsetFor(1, short_title, 40, 100, true, 30, 1000);
    try testing.expectEqual(@as(u16, 0), off);
    try testing.expect(!carousel.scrollingActive());
}

test "disabled carousel never scrolls" {
    reset();
    const off = carousel.offsetFor(1, long_title, 500, 100, false, 30, 1000);
    try testing.expectEqual(@as(u16, 0), off);
    try testing.expect(!carousel.scrollingActive());
}

test "overflow starts at zero and advances with elapsed time" {
    reset();
    // First frame of a new cell: head of the title, motion begins next frame.
    try testing.expectEqual(@as(u16, 0), tick(1, 500, 100, 30, 1000));
    try testing.expect(carousel.scrollingActive());

    // 30 px/s for one second.
    try testing.expectEqual(@as(u16, 30), tick(1, 500, 100, 30, 2000));
    // Another half second adds 15 more.
    try testing.expectEqual(@as(u16, 45), tick(1, 500, 100, 30, 2500));
}

test "offset wraps modulo text width plus gap" {
    reset();
    // cycle = 100 + gap_px = 148. Advance 1500 px: 1500 mod 148 = 20.
    _ = tick(1, 100, 50, 1, 0);
    const off = tick(1, 100, 50, 1500, 1000); // speed*dt = 1500 px
    try testing.expectEqual(@as(u16, 20), off);
}

test "focus change resets the scroll" {
    reset();
    _ = tick(1, 500, 100, 30, 0);
    _ = tick(1, 500, 100, 30, 10_000);
    // Different window: restart from the head.
    try testing.expectEqual(@as(u16, 0), tick(2, 500, 100, 30, 10_001));
    // Same window again: restarts once more (identity flipped back).
    try testing.expectEqual(@as(u16, 0), tick(1, 500, 100, 30, 10_002));
}

test "title content change resets the scroll" {
    reset();
    _ = carousel.offsetFor(1, long_title, 500, 100, true, 30, 0);
    _ = carousel.offsetFor(1, long_title, 500, 100, true, 30, 5_000);
    // Renamed title (same window): restart from the head.
    try testing.expectEqual(@as(u16, 0), carousel.offsetFor(1, long_title ++ " (edited)", 500, 100, true, 30, 5_001));
}

test "re-enabling after a fit title starts over" {
    reset();
    // Overflowing, scrolled partway.
    _ = tick(1, 500, 100, 30, 0);
    _ = tick(1, 500, 100, 30, 1_000);
    // Title shrinks to fit: marquee deactivates.
    try testing.expectEqual(@as(u16, 0), tick(1, 80, 100, 30, 2_000));
    try testing.expect(!carousel.scrollingActive());
    // Overflows again: fresh start at zero.
    try testing.expectEqual(@as(u16, 0), tick(1, 500, 100, 30, 3_000));
}

test "poll deadline only fires while scrolling" {
    reset();
    try testing.expectEqual(@as(i32, -1), carousel.pollDeadlineMs(1000, true));

    _ = tick(1, 500, 100, 30, 1000);
    // Just before the frame interval elapses: wake lands within it.
    const soon = carousel.pollDeadlineMs(1000 + 20, true);
    try testing.expect(soon >= 1 and soon <= carousel.frame_interval_ms);
    // Long idle: clamp to an immediate wake.
    try testing.expectEqual(@as(i32, 1), carousel.pollDeadlineMs(1000 + 9999, true));
    // Config-disabled: no contribution even mid-scroll.
    try testing.expectEqual(@as(i32, -1), carousel.pollDeadlineMs(1000 + 20, false));
}
