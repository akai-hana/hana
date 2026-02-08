// parser.zig - Enhanced parseValue function to handle decimal numbers
// Location: Around line 280-340 in the parseValue function

fn parseValue(self: *Parser, allocator: std.mem.Allocator) ParseError!Value {
    self.skipWhitespace();
    const c = self.peek() orelse return ParseError.InvalidValue;

    if (c == '[') return .{ .array = try self.parseArray(allocator) };
    if (c == '"' or c == '\'') return .{ .string = try self.parseString(allocator) };

    const start = self.pos;
    while (self.pos < self.content.len and self.content[self.pos] != '\n' and self.content[self.pos] != '#') {
        self.pos += 1;
    }

    const raw = std.mem.trim(u8, self.content[start..self.pos], " \t\r");
    if (raw.len == 0) return ParseError.InvalidValue;

    // OPTIMIZATION: Use static map for boolean lookup
    if (BOOLEANS.get(raw)) |boolean| return .{ .boolean = boolean };

    // Check for percentage suffix
    if (raw.len > 1 and raw[raw.len - 1] == '%') {
        const num_part = raw[0..raw.len - 1];
        if (std.fmt.parseFloat(f32, num_part)) |float_val| {
            return .{ .scalable = ScalableValue.percentage(float_val) };
        } else |_| {
            return ParseError.InvalidValue;
        }
    }

    // OPTIMIZATION: Early detection of color values
    const looks_like_color = raw[0] == '#' or 
        (raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) or
        blk: {
            // Quick scan for hex letters
            for (raw) |ch| {
                if ((ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')) break :blk true;
            }
            break :blk false;
        };

    if (looks_like_color) {
        if (self.parseColor(raw)) |color| {
            return .{ .color = color };
        } else |_| {
            // Fallback: try as integer
            if (std.fmt.parseInt(i64, raw, 10)) |int_val| {
                return .{ .integer = int_val };
            } else |_| {
                debug.warn("Invalid color '{s}' at line {}", .{ raw, self.line });
                return ParseError.InvalidColor;
            }
        }
    } else {
        // NEW: Try integer first, then float
        if (std.fmt.parseInt(i64, raw, 10)) |int_val| {
            return .{ .integer = int_val };
        } else |_| {
            // If integer parsing fails, check if it's a valid float
            // (e.g., 0.5, 0.75, 1.0)
            if (std.fmt.parseFloat(f32, raw)) |_| {
                // Store as string - config.zig will parse it
                return .{ .string = try allocator.dupe(u8, raw) };
            } else |_| {
                return ParseError.InvalidValue;
            }
        }
    }
}
