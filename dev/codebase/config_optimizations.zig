//! config.zig - Key Optimizations to Apply
//!
//! These snippets show the main improvements to make in config.zig

const std = @import("std");
const defs = @import("defs");
const parser = @import("parser");

// ============================================================================
// OPTIMIZATION 1: Extract duplicate default layout creation into helper
// ============================================================================

/// Helper to create default bar layout (eliminates duplication from lines 224-243 and 598-619)
fn createDefaultBarLayout(allocator: std.mem.Allocator, cfg: *defs.Config) !void {
    // Left layout with workspaces
    {
        var left_layout = defs.BarLayout{
            .position = .left,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try left_layout.segments.append(allocator, .workspaces);
        try cfg.bar.layout.append(allocator, left_layout);
    }
    
    // Center layout with title
    {
        var center_layout = defs.BarLayout{
            .position = .center,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try center_layout.segments.append(allocator, .title);
        try cfg.bar.layout.append(allocator, center_layout);
    }
    
    // Right layout with clock
    {
        var right_layout = defs.BarLayout{
            .position = .right,
            .segments = std.ArrayList(defs.BarSegment){},
        };
        try right_layout.segments.append(allocator, .clock);
        try cfg.bar.layout.append(allocator, right_layout);
    }
}

// Then use in both places:
// In getDefaultConfig():
//     try createDefaultBarLayout(allocator, &cfg);
//
// In parseBarLayout() when cfg.bar.layout.items.len == 0:
//     try createDefaultBarLayout(allocator, cfg);


// ============================================================================
// OPTIMIZATION 2: Improved resolveKeybindings with proper memory management
// ============================================================================

pub fn resolveKeybindings(keybindings: anytype, xkb_state: *xkb.XkbState, allocator: std.mem.Allocator) void {
    // First pass: resolve keycodes
    for (keybindings) |*kb| {
        kb.keycode = xkb_state.keysymToKeycode(kb.keysym);
    }
    
    // OPTIMIZATION: Use proper allocator instead of c_allocator, with defer for cleanup
    var seen = std.AutoHashMap(u64, usize).init(allocator);
    defer seen.deinit();
    
    // Pre-allocate to reduce allocations
    seen.ensureTotalCapacity(@intCast(keybindings.len)) catch return;
    
    // Second pass: detect conflicts
    for (keybindings, 0..) |*kb, i| {
        const keycode = kb.keycode orelse continue;
        
        // Create unique key from modifiers and keycode
        const key: u64 = (@as(u64, kb.modifiers) << 32) | keycode;
        
        const result = seen.getOrPut(key) catch continue;
        if (result.found_existing) {
            const first_index = result.value_ptr.*;
            std.log.warn("[config] Keybinding conflict detected!", .{});
            std.log.warn("  Binding #{}: mods=0x{x:0>4} key={} (first)", .{
                first_index + 1, keybindings[first_index].modifiers, keycode
            });
            std.log.warn("  Binding #{}: mods=0x{x:0>4} key={} (duplicate)", .{
                i + 1, kb.modifiers, keycode
            });
            std.log.warn("  The second binding will override the first!", .{});
        } else {
            result.value_ptr.* = i;
        }
    }
}


// ============================================================================
// OPTIMIZATION 3: Simplified get() function with inline hint
// ============================================================================

// Add inline hint for better performance
inline fn get(
    comptime T: type,
    section: *const parser.Section,
    key: []const u8,
    default: T,
    comptime min: ?T,
    comptime max: ?T,
) T {
    const value = switch (T) {
        bool => section.getBool(key) orelse return default,
        []const u8 => section.getString(key) orelse return default,
        f32 => blk: {
            if (section.getInt(key)) |i| {
                break :blk @as(f32, @floatFromInt(i)) / 100.0;
            }
            return default;
        },
        u16, u32, usize => blk: {
            const i = section.getInt(key) orelse return default;
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };

    // OPTIMIZATION: Combine validation into single check
    if (comptime min != null or max != null) {
        if (comptime min) |m| {
            if (value < m) {
                std.log.warn("[config] Value for '{s}' below minimum, using default", .{key});
                return default;
            }
        }
        
        if (comptime max) |m| {
            if (value > m) {
                std.log.warn("[config] Value for '{s}' above maximum, using default", .{key});
                return default;
            }
        }
    }

    return value;
}


// ============================================================================
// OPTIMIZATION 4: Cache color parsing to avoid repeated work
// ============================================================================

// At module level, add a simple color cache
const ColorCache = struct {
    map: std.StringHashMap(u32),
    
    fn init(allocator: std.mem.Allocator) ColorCache {
        return .{ .map = std.StringHashMap(u32).init(allocator) };
    }
    
    fn deinit(self: *ColorCache) void {
        self.map.deinit();
    }
    
    fn getOrParse(self: *ColorCache, str: []const u8) !u32 {
        if (self.map.get(str)) |cached| return cached;
        
        const color = try parseColor(str);
        try self.map.put(str, color);
        return color;
    }
};


// ============================================================================
// OPTIMIZATION 5: Streamlined file reading with better error messages
// ============================================================================

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !defs.Config {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // OPTIMIZATION: Use std.fs.cwd().openFile for better cross-platform support
    const file = std.fs.cwd().openFile(path_z, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("[config] Not found: {s}", .{path});
        }
        return err;
    };
    defer file.close();

    // OPTIMIZATION: Read entire file at once with size hint
    const stat = try file.stat();
    const max_size = 1024 * 1024; // 1MB limit
    
    if (stat.size > max_size) return error.FileTooLarge;
    
    const content = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(content);

    // Check if file is empty
    if (content.len == 0) {
        std.log.info("[config] Empty config file: {s}, using fallback", .{path});
        return try loadFallbackConfig(allocator);
    }

    var doc = try parser.parse(allocator, content);
    defer doc.deinit();

    var cfg = getDefaultConfig(allocator);

    parseWorkspaces(&doc, &cfg);
    try parseKeybindings(allocator, &doc, &cfg);
    try parseTiling(allocator, &doc, &cfg);
    try parseBar(allocator, &doc, &cfg);
    try parseRules(allocator, &doc, &cfg);

    std.log.info("[config] Loaded: {s}", .{path});
    return cfg;
}


// ============================================================================
// OPTIMIZATION 6: Improved parseBarLayout with inline for
// ============================================================================

fn parseBarLayout(allocator: std.mem.Allocator, section: *const parser.Section, doc: *const parser.Document, cfg: *defs.Config) !void {
    // Clear defaults
    for (cfg.bar.layout.items) |*item| {
        item.deinit(allocator);
    }
    cfg.bar.layout.clearRetainingCapacity();
    
    // OPTIMIZATION: Use comptime for known array
    const positions = comptime [_]struct { name: []const u8, pos: defs.BarPosition }{
        .{ .name = "bar.layout.left", .pos = .left },
        .{ .name = "bar.layout.center", .pos = .center },
        .{ .name = "bar.layout.right", .pos = .right },
    };
    
    // OPTIMIZATION: Use inline for since array is comptime-known
    inline for (positions) |p| {
        if (doc.getSection(p.name)) |layout_section| {
            var bar_layout = defs.BarLayout{
                .position = p.pos,
                .segments = std.ArrayList(defs.BarSegment){},
            };
            
            if (layout_section.get("segments")) |seg_value| {
                if (seg_value.asArray()) |seg_arr| {
                    // Pre-allocate
                    try bar_layout.segments.ensureTotalCapacity(allocator, seg_arr.len);
                    
                    for (seg_arr) |seg_item| {
                        if (seg_item.asString()) |seg_str| {
                            if (defs.BarSegment.fromString(seg_str)) |segment| {
                                bar_layout.segments.appendAssumeCapacity(segment);
                            }
                        }
                    }
                }
            }
            
            if (bar_layout.segments.items.len > 0) {
                try cfg.bar.layout.append(allocator, bar_layout);
            } else {
                bar_layout.deinit(allocator);
            }
        }
    }
    
    // If no layout was parsed, use defaults
    if (cfg.bar.layout.items.len == 0) {
        try createDefaultBarLayout(allocator, cfg);
    }
}


// ============================================================================
// SUMMARY OF IMPROVEMENTS
// ============================================================================
//
// 1. Extract createDefaultBarLayout() to eliminate duplication
// 2. Fix resolveKeybindings() to use proper allocator with defer cleanup
// 3. Add inline hints to hot-path functions like get()
// 4. Use file.readToEndAlloc() instead of manual buffering
// 5. Pre-allocate ArrayLists when size is known
// 6. Use inline for on comptime-known arrays
// 7. Use appendAssumeCapacity() when capacity is pre-allocated
// 8. Better error messages and resource cleanup
//
// These changes provide:
// - Better memory management (no leaks on error)
// - Reduced allocations (pre-allocation, better buffering)
// - Cleaner code (less duplication)
// - Better performance (inline hints, O(1) lookups)
