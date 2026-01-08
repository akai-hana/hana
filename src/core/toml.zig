// Minimal TOML parser for hana
// Supports: [sections], key=value, integers, hex colors, strings, comments

const std = @import("std");

/// Represents a parsed value (integer, string, or color)
pub const Value = union(enum) {
    integer: i64,
    string: []const u8,
    color: u32,  // stored as 0xRRGGBB

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asColor(self: Value) ?u32 {
        return switch (self) {
            .color => |c| c,
            else => null,
        };
    }
};

/// A TOML section containing key-value pairs
pub const Section = struct {
    name: []const u8,
    pairs: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Section {
        return .{
            .name = name,
            .pairs = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Section) void {
        self.pairs.deinit();
    }

    /// Get a value from this section
    pub fn get(self: *const Section, key: []const u8) ?Value {
        return self.pairs.get(key);
    }

    /// Get an integer value
    pub fn getInt(self: *const Section, key: []const u8) ?i64 {
        const val = self.get(key) orelse return null;
        return val.asInt();
    }

    /// Get a string value
    pub fn getString(self: *const Section, key: []const u8) ?[]const u8 {
        const val = self.get(key) orelse return null;
        return val.asString();
    }

    /// Get a color value
    pub fn getColor(self: *const Section, key: []const u8) ?u32 {
        const val = self.get(key) orelse return null;
        return val.asColor();
    }
};

/// The parsed TOML document
pub const Document = struct {
    allocator: std.mem.Allocator,
    sections: std.StringHashMap(Section),
    /// Root section for top-level key-value pairs (no section header)
    root: Section,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
            .sections = std.StringHashMap(Section).init(allocator),
            .root = Section.init(allocator, ""),
        };
    }

    pub fn deinit(self: *Document) void {
        var iter = self.sections.valueIterator();
        while (iter.next()) |section| {
            section.deinit();
        }
        self.sections.deinit();
        self.root.deinit();
    }

    /// Get a section by name
    pub fn getSection(self: *const Document, name: []const u8) ?*const Section {
        return self.sections.getPtr(name);
    }

    /// Get a value from root (top-level, no section)
    pub fn get(self: *const Document, key: []const u8) ?Value {
        return self.root.get(key);
    }
};

/// Parse errors with line number context
pub const ParseError = error{
    InvalidSyntax,
    InvalidSection,
    InvalidValue,
    InvalidColor,
    DuplicateKey,
    OutOfMemory,
};

/// Parser state
const Parser = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    pos: usize,
    line: usize,

    fn init(allocator: std.mem.Allocator, content: []const u8) Parser {
        return .{
            .allocator = allocator,
            .content = content,
            .pos = 0,
            .line = 1,
        };
    }

    /// Skip whitespace but not newlines
    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.content.len) {
            const c = self.content[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    /// Skip to end of line (for comments)
    fn skipLine(self: *Parser) void {
        while (self.pos < self.content.len and self.content[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.content.len) {
            self.pos += 1;
            self.line += 1;
        }
    }

    /// Check if we're at end of file
    fn isEof(self: *const Parser) bool {
        return self.pos >= self.content.len;
    }

    /// Peek current character without consuming
    fn peek(self: *const Parser) ?u8 {
        if (self.isEof()) return null;
        return self.content[self.pos];
    }

    /// Consume and return current character
    fn consume(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        if (c == '\n') self.line += 1;
        return c;
    }

    /// Parse a section header: [section_name]
    fn parseSection(self: *Parser) ![]const u8 {
        _ = self.consume(); // consume '['
        self.skipWhitespace();

        const start = self.pos;
        while (self.peek()) |c| {
            if (c == ']') break;
            if (c == '\n') {
                std.debug.print("Error (line {}): Section header not closed\n", .{self.line});
                return ParseError.InvalidSection;
            }
            _ = self.consume();
        }

        if (self.peek() != ']') {
            std.debug.print("Error (line {}): Expected ']' to close section\n", .{self.line});
            return ParseError.InvalidSection;
        }

        const name = std.mem.trim(u8, self.content[start..self.pos], " \t");
        _ = self.consume(); // consume ']'

        if (name.len == 0) {
            std.debug.print("Error (line {}): Empty section name\n", .{self.line});
            return ParseError.InvalidSection;
        }

        return try self.allocator.dupe(u8, name);
    }

    /// Parse a key (identifier before '=')
    fn parseKey(self: *Parser) ![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '=' or c == ' ' or c == '\t' or c == '\n') break;
            _ = self.consume();
        }

        const key = std.mem.trim(u8, self.content[start..self.pos], " \t");
        if (key.len == 0) {
            std.debug.print("Error (line {}): Empty key\n", .{self.line});
            return ParseError.InvalidSyntax;
        }

        return try self.allocator.dupe(u8, key);
    }

    /// Parse a quoted string value
    fn parseString(self: *Parser) ![]const u8 {
        const quote = self.consume().?; // consume opening quote
        const start = self.pos;

        while (self.peek()) |c| {
            if (c == quote) break;
            if (c == '\n') {
                std.debug.print("Error (line {}): Unterminated string\n", .{self.line});
                return ParseError.InvalidValue;
            }
            _ = self.consume();
        }

        const value = self.content[start..self.pos];
        _ = self.consume(); // consume closing quote

        return try self.allocator.dupe(u8, value);
    }

    /// Parse a hex color value (supports #RRGGBB, 0xRRGGBB, RRGGBB)
    fn parseColor(self: *Parser, value: []const u8) !u32 {
        // Strip prefix if present
        const hex_value = if (value.len == 0)
            value
            else switch (value[0]) {
                '#' => value[1..],
                '0' => if (value.len > 1 and value[1] == 'x') value[2..] else value,
                else => value,
            };

            const color = std.fmt.parseInt(u32, hex_value, 16) catch {
                std.debug.print("Error (line {}): Invalid color format '{}s'\n", .{ self.line, value });
                return ParseError.InvalidColor;
            };

            return color;
    }

    /// Parse a value (string, integer, or color)
    fn parseValue(self: *Parser) !Value {
        self.skipWhitespace();

        const c = self.peek() orelse {
            std.debug.print("Error (line {}): Expected value\n", .{self.line});
            return ParseError.InvalidValue;
        };

        // String value
        if (c == '"' or c == '\'') {
            const str = try self.parseString();
            return Value{ .string = str };
        }

        // Collect raw value (integer or color)
        const start = self.pos;
        while (self.peek()) |ch| {
            if (ch == '\n' or ch == '#') break;
            _ = self.consume();
        }

        const raw = std.mem.trim(u8, self.content[start..self.pos], " \t\r");
        if (raw.len == 0) {
            std.debug.print("Error (line {}): Empty value\n", .{self.line});
            return ParseError.InvalidValue;
        }

        // Try to detect if it's a color (contains hex prefix or letters)
        const is_color = blk: {
            if (raw[0] == '#') break :blk true;
            if (raw.len > 2 and raw[0] == '0' and raw[1] == 'x') break :blk true;
            for (raw) |ch| {
                if ((ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (is_color) {
            const color = try self.parseColor(raw);
            return Value{ .color = color };
        }

        // Try parsing as integer
        const int = std.fmt.parseInt(i64, raw, 10) catch {
            std.debug.print("Error (line {}): Invalid value '{}s'\n", .{ self.line, raw });
            return ParseError.InvalidValue;
        };

        return Value{ .integer = int };
    }

    /// Parse a key-value pair
    fn parseKeyValue(self: *Parser) !struct { []const u8, Value } {
        const key = try self.parseKey();
        self.skipWhitespace();

        if (self.consume() != '=') {
            std.debug.print("Error (line {}): Expected '=' after key '{}s'\n", .{ self.line, key });
            return ParseError.InvalidSyntax;
        }

        const value = try self.parseValue();
        return .{ key, value };
    }
};

/// Parse a TOML string into a Document
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Document {
    var doc = Document.init(allocator);
    errdefer doc.deinit();

    var parser = Parser.init(allocator, content);
    var current_section: *Section = &doc.root;

    while (!parser.isEof()) {
        parser.skipWhitespace();

        const c = parser.peek() orelse break;

        // Skip empty lines
        if (c == '\n') {
            _ = parser.consume();
            continue;
        }

        // Skip comments
        if (c == '#') {
            parser.skipLine();
            continue;
        }

        // Parse section header
        if (c == '[') {
            const section_name = try parser.parseSection();

            // Check for duplicate section
            if (doc.sections.contains(section_name)) {
                std.debug.print("Error (line {}): Duplicate section '{}s'\n", .{ parser.line, section_name });
                return ParseError.DuplicateKey;
            }

            const section = Section.init(allocator, section_name);
            try doc.sections.put(section_name, section);
            current_section = doc.sections.getPtr(section_name).?;

            parser.skipWhitespace();
            if (parser.peek() == '\n') _ = parser.consume();
            continue;
        }

        // Parse key-value pair
        const kv = try parser.parseKeyValue();
        const key = kv[0];
        const value = kv[1];

        // Check for duplicate key in current section
        if (current_section.pairs.contains(key)) {
            std.debug.print("Error (line {}): Duplicate key '{}s' in section '{}s'\n", .{ parser.line, key, current_section.name });
            return ParseError.DuplicateKey;
        }

        try current_section.pairs.put(key, value);

        parser.skipWhitespace();
        if (parser.peek() == '\n') _ = parser.consume();
    }

    return doc;
}
