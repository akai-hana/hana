// Config parser
const std            = @import("std");
const defs           = @import("defs");
const error_handling = @import("error");
const Config         = defs.Config;

// Default values
const DEFAULT_BORDER_WIDTH: u32 = 4;
const DEFAULT_BORDER_COLOR: u32 = 0xff0000;

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Try to open config file first
    const file = std.fs.cwd().openFile(path, .{}) catch {
        // Config doesn't exist, use all defaults
        return getDefaultConfig();
    };
    defer file.close();

    // Config exists, try to parse it
    const file_size = (try file.stat()).size;
    const content = try file.readToEndAlloc(allocator, file_size);
    defer allocator.free(content);

    // Track parsed values (null means not yet set)
    var border_width: ?u32 = null;
    var border_color: ?u32 = null;

    // Parse TOML
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;

        // Strip inline comments
        const line_without_comment = if (std.mem.indexOfScalar(u8, line, '#')) |comment_pos|
            line[0..comment_pos]
            else
                line;

            const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                // Strip quotes from value if present
                if (value.len >= 2 and 
                    ((value[0] == '"' and value[value.len - 1] == '"') or
                     (value[0] == '\'' and value[value.len - 1] == '\''))) {
                    value = value[1..value.len - 1];
                }

                // Handle empty values
                if (value.len == 0) {
                    error_handling.warnEmptyValue(line_number, key);
                    continue;
                }

                if (std.mem.eql(u8, key, "border_width")) {
                    border_width = parseBorderWidth(line_number, value);
                } else if (std.mem.eql(u8, key, "border_color")) {
                    border_color = parseBorderColor(line_number, value);
                } else {
                    error_handling.warnUnknownConfigKey(line_number, key);
                }
            }
    }

    // Return config with parsed values or defaults for any missing/invalid values
    return Config{
        .border_width = border_width orelse DEFAULT_BORDER_WIDTH,
        .border_color = border_color orelse DEFAULT_BORDER_COLOR,
    };
}

/// Returns default configuration
fn getDefaultConfig() Config {
    return Config{
        .border_width = DEFAULT_BORDER_WIDTH,
        .border_color = DEFAULT_BORDER_COLOR,
    };
}

/// Parse border_width value with validation
fn parseBorderWidth(line_number: usize, value: []const u8) ?u32 {
    const width = std.fmt.parseInt(u32, value, 10) catch |err| {
        error_handling.warnInvalidBorderWidth(line_number, value, err);
        return null;
    };

    // Validate: no negative borders
    if (width < 0) {
        error_handling.warnNegativeBorderWidth(line_number);
        return null;
    }

    return width;
}

/// Parse border_color value (supports #RRGGBB, 0xRRGGBB, and RRGGBB formats)
fn parseBorderColor(line_number: usize, value: []const u8) ?u32 {
    // Strip prefix if present (both # and 0x)
    const hex_value = if (value.len == 0)
        value
    else switch (value[0]) {
        '#' => value[1..],
        '0' => if (value.len > 1 and value[1] == 'x') value[2..] else value,
        else => value,
    };
    
    const color = std.fmt.parseInt(u32, hex_value, 16) catch |err| {
        error_handling.warnInvalidBorderColor(line_number, value, err);
        return null;
    };
    
    return color;
}
