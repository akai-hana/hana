// Config parser using minimal TOML
const std = @import("std");
const defs = @import("defs");
const error_handling = @import("error");
const toml = @import("toml");
const Config = defs.Config;

// Default values
const DEFAULT_BORDER_WIDTH: u32 = 4;
const DEFAULT_BORDER_COLOR: u32 = 0xff0000;

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Try to open config file
    const file = std.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("Config file '{}s' not found, using defaults\n", .{path});
        return getDefaultConfig();
    };
    defer file.close();

    // Read file content
    const file_size = (try file.stat()).size;
    const content = try file.readToEndAlloc(allocator, file_size);
    defer allocator.free(content);

    // Parse TOML
    var doc = toml.parse(allocator, content) catch |err| {
        std.debug.print("Failed to parse config ({}), using defaults\n", .{err});
        return getDefaultConfig();
    };
    defer doc.deinit();

    // Extract values with fallbacks to defaults
    var border_width = DEFAULT_BORDER_WIDTH;
    var border_color = DEFAULT_BORDER_COLOR;

    // Try to get values from [appearance] section first, then root
    if (doc.getSection("appearance")) |section| {
        if (section.getInt("border_width")) |w| {
            if (w >= 0) {
                border_width = @intCast(w);
            } else {
                std.debug.print("Warning: border_width must be non-negative, using default\n", .{});
            }
        }

        if (section.getColor("border_color")) |c| {
            border_color = c;
        }
    } else {
        // Fallback to root-level keys (backward compatibility)
        if (doc.root.getInt("border_width")) |w| {
            if (w >= 0) {
                border_width = @intCast(w);
            } else {
                std.debug.print("Warning: border_width must be non-negative, using default\n", .{});
            }
        }

        if (doc.root.getColor("border_color")) |c| {
            border_color = c;
        }
    }

    std.debug.print("Loaded config: border_width={}, border_color=0x{x}\n", .{ border_width, border_color });

    return Config{
        .border_width = border_width,
        .border_color = border_color,
    };
}

/// Returns default configuration
fn getDefaultConfig() Config {
    std.debug.print("Using default config: border_width={}, border_color=0x{x}\n", .{ DEFAULT_BORDER_WIDTH, DEFAULT_BORDER_COLOR });
    return Config{
        .border_width = DEFAULT_BORDER_WIDTH,
        .border_color = DEFAULT_BORDER_COLOR,
    };
}
