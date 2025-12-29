const std = @import("std");

/// Terminal screen buffer
/// Manages character grid with attributes, cursor, and scrolling
/// Supports alternative screen buffer (mode 1049) for vim, htop, less, etc.
pub const Screen = struct {
    allocator: std.mem.Allocator,
    cols: u32,
    rows: u32,
    cells: []Cell,
    cursor_col: u32,
    cursor_row: u32,
    cursor_visible: bool,
    scroll_top: u32,
    scroll_bottom: u32,
    current_attr: Attr,
    dirty: bool,

    // Alternative screen buffer support
    alt_cells: ?[]Cell,
    using_alt_buffer: bool,

    // Saved cursor state (for DECSC/DECRC and mode 1049)
    saved_cursor_col: u32,
    saved_cursor_row: u32,
    saved_attr: Attr,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cols: u32, rows: u32) !Self {
        const cells = try allocator.alloc(Cell, cols * rows);
        for (cells) |*cell| {
            cell.* = Cell.blank();
        }

        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .cursor_col = 0,
            .cursor_row = 0,
            .cursor_visible = true,
            .scroll_top = 0,
            .scroll_bottom = rows - 1,
            .current_attr = Attr.default(),
            .dirty = true,
            // Alternative buffer initially not allocated
            .alt_cells = null,
            .using_alt_buffer = false,
            // Saved cursor defaults
            .saved_cursor_col = 0,
            .saved_cursor_row = 0,
            .saved_attr = Attr.default(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        if (self.alt_cells) |alt| {
            self.allocator.free(alt);
        }
    }

    /// Get cell at position
    pub fn getCell(self: *const Self, col: u32, row: u32) *const Cell {
        return &self.cells[row * self.cols + col];
    }

    /// Get mutable cell at position
    fn getCellMut(self: *Self, col: u32, row: u32) *Cell {
        return &self.cells[row * self.cols + col];
    }

    /// Write a character at cursor position and advance cursor
    pub fn putChar(self: *Self, c: u21) void {
        self.putCharWithWidth(c, charWidth(c));
    }

    /// Write a character with explicit width
    pub fn putCharWithWidth(self: *Self, c: u21, width: u2) void {
        // Handle line wrap
        if (self.cursor_col + width > self.cols) {
            self.newline();
        }

        const cell = self.getCellMut(self.cursor_col, self.cursor_row);
        cell.char = c;
        cell.attr = self.current_attr;
        cell.width = width;
        self.cursor_col += 1;

        // For wide characters, add continuation cell
        if (width == 2 and self.cursor_col < self.cols) {
            const cont = self.getCellMut(self.cursor_col, self.cursor_row);
            cont.* = Cell.wideContinuation();
            cont.attr = self.current_attr;
            self.cursor_col += 1;
        }

        self.dirty = true;
    }

    /// Determine display width of a Unicode codepoint
    /// Returns 0 for combining chars, 2 for wide chars (CJK), 1 otherwise
    pub fn charWidth(c: u21) u2 {
        // Zero-width characters
        if (c < 0x20) return 0; // Control chars
        if (c >= 0x0300 and c <= 0x036F) return 0; // Combining diacriticals
        if (c >= 0x200B and c <= 0x200F) return 0; // Zero-width spaces/joiners
        if (c >= 0xFE00 and c <= 0xFE0F) return 0; // Variation selectors

        // Wide characters (CJK, fullwidth, etc.)
        if (c >= 0x1100 and c <= 0x115F) return 2; // Hangul Jamo
        if (c >= 0x2E80 and c <= 0x9FFF) return 2; // CJK
        if (c >= 0xAC00 and c <= 0xD7A3) return 2; // Hangul Syllables
        if (c >= 0xF900 and c <= 0xFAFF) return 2; // CJK Compatibility
        if (c >= 0xFE10 and c <= 0xFE1F) return 2; // Vertical forms
        if (c >= 0xFE30 and c <= 0xFE6F) return 2; // CJK Compatibility Forms
        if (c >= 0xFF00 and c <= 0xFF60) return 2; // Fullwidth forms
        if (c >= 0xFFE0 and c <= 0xFFE6) return 2; // Fullwidth symbols
        if (c >= 0x20000 and c <= 0x2FFFF) return 2; // CJK Extension B+

        return 1;
    }

    /// Move cursor to next line
    pub fn newline(self: *Self) void {
        self.cursor_col = 0;
        if (self.cursor_row >= self.scroll_bottom) {
            self.scrollUp(1);
        } else {
            self.cursor_row += 1;
        }
        self.dirty = true;
    }

    /// Carriage return (move cursor to column 0)
    pub fn carriageReturn(self: *Self) void {
        self.cursor_col = 0;
        self.dirty = true;
    }

    /// Tab (move cursor to next 8-column boundary)
    pub fn tab(self: *Self) void {
        const next_tab = (self.cursor_col / 8 + 1) * 8;
        self.cursor_col = @min(next_tab, self.cols - 1);
        self.dirty = true;
    }

    /// Backspace (move cursor left, don't delete)
    pub fn backspace(self: *Self) void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
            self.dirty = true;
        }
    }

    /// Scroll up by n lines within scroll region
    pub fn scrollUp(self: *Self, n: u32) void {
        const lines_to_scroll = @min(n, self.scroll_bottom - self.scroll_top + 1);
        const start_row = self.scroll_top;
        const end_row = self.scroll_bottom;

        // Move lines up
        var row = start_row;
        while (row <= end_row - lines_to_scroll) : (row += 1) {
            const src_start = (row + lines_to_scroll) * self.cols;
            const dst_start = row * self.cols;
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
        }

        // Clear bottom lines
        while (row <= end_row) : (row += 1) {
            const start = row * self.cols;
            for (self.cells[start..][0..self.cols]) |*cell| {
                cell.* = Cell.blank();
            }
        }
        self.dirty = true;
    }

    /// Scroll down by n lines within scroll region
    pub fn scrollDown(self: *Self, n: u32) void {
        const lines_to_scroll = @min(n, self.scroll_bottom - self.scroll_top + 1);
        const start_row = self.scroll_top;
        const end_row = self.scroll_bottom;

        // Move lines down (iterate in reverse)
        var row = end_row;
        while (row >= start_row + lines_to_scroll) : (row -= 1) {
            const src_start = (row - lines_to_scroll) * self.cols;
            const dst_start = row * self.cols;
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
            if (row == start_row + lines_to_scroll) break;
        }

        // Clear top lines
        row = start_row;
        while (row < start_row + lines_to_scroll) : (row += 1) {
            const start = row * self.cols;
            for (self.cells[start..][0..self.cols]) |*cell| {
                cell.* = Cell.blank();
            }
        }
        self.dirty = true;
    }

    /// Set cursor position (0-indexed)
    pub fn setCursor(self: *Self, col: u32, row: u32) void {
        self.cursor_col = @min(col, self.cols - 1);
        self.cursor_row = @min(row, self.rows - 1);
        self.dirty = true;
    }

    /// Move cursor up by n rows
    pub fn cursorUp(self: *Self, n: u32) void {
        if (n <= self.cursor_row) {
            self.cursor_row -= n;
        } else {
            self.cursor_row = 0;
        }
        self.dirty = true;
    }

    /// Move cursor down by n rows
    pub fn cursorDown(self: *Self, n: u32) void {
        self.cursor_row = @min(self.cursor_row + n, self.rows - 1);
        self.dirty = true;
    }

    /// Move cursor right by n columns
    pub fn cursorRight(self: *Self, n: u32) void {
        self.cursor_col = @min(self.cursor_col + n, self.cols - 1);
        self.dirty = true;
    }

    /// Move cursor left by n columns
    pub fn cursorLeft(self: *Self, n: u32) void {
        if (n <= self.cursor_col) {
            self.cursor_col -= n;
        } else {
            self.cursor_col = 0;
        }
        self.dirty = true;
    }

    /// Erase from cursor to end of line
    pub fn eraseToEndOfLine(self: *Self) void {
        var col = self.cursor_col;
        while (col < self.cols) : (col += 1) {
            self.getCellMut(col, self.cursor_row).* = Cell.blank();
        }
        self.dirty = true;
    }

    /// Erase from start of line to cursor
    pub fn eraseToStartOfLine(self: *Self) void {
        var col: u32 = 0;
        while (col <= self.cursor_col) : (col += 1) {
            self.getCellMut(col, self.cursor_row).* = Cell.blank();
        }
        self.dirty = true;
    }

    /// Erase entire line
    pub fn eraseLine(self: *Self) void {
        const start = self.cursor_row * self.cols;
        for (self.cells[start..][0..self.cols]) |*cell| {
            cell.* = Cell.blank();
        }
        self.dirty = true;
    }

    /// Erase from cursor to end of screen
    pub fn eraseToEndOfScreen(self: *Self) void {
        self.eraseToEndOfLine();
        var row = self.cursor_row + 1;
        while (row < self.rows) : (row += 1) {
            const start = row * self.cols;
            for (self.cells[start..][0..self.cols]) |*cell| {
                cell.* = Cell.blank();
            }
        }
        self.dirty = true;
    }

    /// Erase from start of screen to cursor
    pub fn eraseToStartOfScreen(self: *Self) void {
        var row: u32 = 0;
        while (row < self.cursor_row) : (row += 1) {
            const start = row * self.cols;
            for (self.cells[start..][0..self.cols]) |*cell| {
                cell.* = Cell.blank();
            }
        }
        self.eraseToStartOfLine();
        self.dirty = true;
    }

    /// Erase entire screen
    pub fn eraseScreen(self: *Self) void {
        for (self.cells) |*cell| {
            cell.* = Cell.blank();
        }
        self.dirty = true;
    }

    /// Set scroll region
    pub fn setScrollRegion(self: *Self, top: u32, bottom: u32) void {
        self.scroll_top = @min(top, self.rows - 1);
        self.scroll_bottom = @min(bottom, self.rows - 1);
        if (self.scroll_top > self.scroll_bottom) {
            self.scroll_top = 0;
            self.scroll_bottom = self.rows - 1;
        }
    }

    /// Delete n characters at cursor, shift remaining left
    pub fn deleteChars(self: *Self, n: u32) void {
        const row_start = self.cursor_row * self.cols;
        const chars_to_delete = @min(n, self.cols - self.cursor_col);
        const chars_to_shift = self.cols - self.cursor_col - chars_to_delete;

        // Shift characters left
        var col = self.cursor_col;
        while (col < self.cursor_col + chars_to_shift) : (col += 1) {
            self.cells[row_start + col] = self.cells[row_start + col + chars_to_delete];
        }

        // Clear remaining
        while (col < self.cols) : (col += 1) {
            self.cells[row_start + col] = Cell.blank();
        }
        self.dirty = true;
    }

    /// Insert n characters at cursor, shift remaining right
    pub fn insertChars(self: *Self, n: u32) void {
        const row_start = self.cursor_row * self.cols;
        const chars_to_insert = @min(n, self.cols - self.cursor_col);
        const chars_to_keep = self.cols - self.cursor_col - chars_to_insert;

        // Shift characters right (iterate in reverse)
        var col = self.cols - 1;
        while (col >= self.cursor_col + chars_to_insert) : (col -= 1) {
            self.cells[row_start + col] = self.cells[row_start + col - chars_to_insert];
            if (col == self.cursor_col + chars_to_insert) break;
        }

        // Clear inserted area
        col = self.cursor_col;
        while (col < self.cursor_col + chars_to_insert) : (col += 1) {
            self.cells[row_start + col] = Cell.blank();
        }
        _ = chars_to_keep;
        self.dirty = true;
    }

    /// Delete n lines at cursor row, scroll rest up
    pub fn deleteLines(self: *Self, n: u32) void {
        const old_top = self.scroll_top;
        self.scroll_top = self.cursor_row;
        self.scrollUp(n);
        self.scroll_top = old_top;
    }

    /// Insert n lines at cursor row, scroll rest down
    pub fn insertLines(self: *Self, n: u32) void {
        const old_top = self.scroll_top;
        self.scroll_top = self.cursor_row;
        self.scrollDown(n);
        self.scroll_top = old_top;
    }

    // ========================================================================
    // Alternative screen buffer support (DECSET/DECRST modes 47, 1047, 1049)
    // ========================================================================

    /// Switch to alternative screen buffer
    /// If clear is true, clears the alt buffer (mode 1047/1049)
    pub fn enterAltBuffer(self: *Self, clear: bool) !void {
        if (self.using_alt_buffer) return;

        // Allocate alt buffer if not already allocated
        if (self.alt_cells == null) {
            self.alt_cells = try self.allocator.alloc(Cell, self.cols * self.rows);
        }

        // Swap buffers
        const temp = self.cells;
        self.cells = self.alt_cells.?;
        self.alt_cells = temp;

        self.using_alt_buffer = true;

        // Clear if requested (mode 1047/1049)
        if (clear) {
            for (self.cells) |*cell| {
                cell.* = Cell.blank();
            }
        }

        self.dirty = true;
    }

    /// Switch back to main screen buffer
    pub fn exitAltBuffer(self: *Self) void {
        if (!self.using_alt_buffer) return;

        // Swap buffers back
        const temp = self.cells;
        self.cells = self.alt_cells.?;
        self.alt_cells = temp;

        self.using_alt_buffer = false;
        self.dirty = true;
    }

    // ========================================================================
    // Cursor save/restore (DECSC/DECRC - ESC 7/8, CSI s/u)
    // ========================================================================

    /// Save cursor position and attributes (DECSC)
    pub fn saveCursor(self: *Self) void {
        self.saved_cursor_col = self.cursor_col;
        self.saved_cursor_row = self.cursor_row;
        self.saved_attr = self.current_attr;
    }

    /// Restore cursor position and attributes (DECRC)
    pub fn restoreCursor(self: *Self) void {
        self.cursor_col = @min(self.saved_cursor_col, self.cols -| 1);
        self.cursor_row = @min(self.saved_cursor_row, self.rows -| 1);
        self.current_attr = self.saved_attr;
        self.dirty = true;
    }

    /// Enter alternate screen with cursor save (mode 1049)
    /// Saves cursor, switches to alt buffer, and clears it
    pub fn enterAltBufferWithCursorSave(self: *Self) !void {
        self.saveCursor();
        try self.enterAltBuffer(true);
    }

    /// Exit alternate screen with cursor restore (mode 1049)
    /// Switches back to main buffer and restores cursor
    pub fn exitAltBufferWithCursorRestore(self: *Self) void {
        self.exitAltBuffer();
        self.restoreCursor();
    }

    /// Set cursor visibility
    pub fn setCursorVisible(self: *Self, visible: bool) void {
        self.cursor_visible = visible;
        self.dirty = true;
    }
};

/// Character cell
pub const Cell = struct {
    char: u21, // Unicode codepoint
    attr: Attr,
    /// Width of this character (1 for most, 2 for wide chars, 0 for continuation)
    width: u2,

    pub fn blank() Cell {
        return .{
            .char = ' ',
            .attr = Attr.default(),
            .width = 1,
        };
    }

    /// Create a cell for a wide character's continuation
    pub fn wideContinuation() Cell {
        return .{
            .char = 0,
            .attr = Attr.default(),
            .width = 0,
        };
    }
};

/// Character attributes
pub const Attr = struct {
    fg: Color,
    bg: Color,
    bold: bool,
    dim: bool,
    italic: bool,
    underline: bool,
    blink: bool,
    reverse: bool,
    hidden: bool,

    pub fn default() Attr {
        return .{
            .fg = Color.default_fg,
            .bg = Color.default_bg,
            .bold = false,
            .dim = false,
            .italic = false,
            .underline = false,
            .blink = false,
            .reverse = false,
            .hidden = false,
        };
    }

    /// Get effective foreground color (considering reverse video)
    pub fn effectiveFg(self: Attr) Color {
        return if (self.reverse) self.bg else self.fg;
    }

    /// Get effective background color (considering reverse video)
    pub fn effectiveBg(self: Attr) Color {
        return if (self.reverse) self.fg else self.bg;
    }
};

/// Terminal color (16 basic + 256 extended + RGB)
pub const Color = union(enum) {
    indexed: u8, // 0-255
    rgb: struct { r: u8, g: u8, b: u8 },

    pub const default_fg = Color{ .indexed = 7 }; // white/light gray
    pub const default_bg = Color{ .indexed = 0 }; // black

    // Standard 16 colors
    pub const black = Color{ .indexed = 0 };
    pub const red = Color{ .indexed = 1 };
    pub const green = Color{ .indexed = 2 };
    pub const yellow = Color{ .indexed = 3 };
    pub const blue = Color{ .indexed = 4 };
    pub const magenta = Color{ .indexed = 5 };
    pub const cyan = Color{ .indexed = 6 };
    pub const white = Color{ .indexed = 7 };
    pub const bright_black = Color{ .indexed = 8 };
    pub const bright_red = Color{ .indexed = 9 };
    pub const bright_green = Color{ .indexed = 10 };
    pub const bright_yellow = Color{ .indexed = 11 };
    pub const bright_blue = Color{ .indexed = 12 };
    pub const bright_magenta = Color{ .indexed = 13 };
    pub const bright_cyan = Color{ .indexed = 14 };
    pub const bright_white = Color{ .indexed = 15 };

    /// Convert indexed color to RGB (standard VGA palette)
    pub fn toRgb(self: Color) struct { r: u8, g: u8, b: u8 } {
        switch (self) {
            .rgb => |c| return .{ .r = c.r, .g = c.g, .b = c.b },
            .indexed => |idx| {
                if (idx < 16) {
                    // Standard 16 colors (VGA palette)
                    const palette = [16][3]u8{
                        .{ 0, 0, 0 }, // black
                        .{ 170, 0, 0 }, // red
                        .{ 0, 170, 0 }, // green
                        .{ 170, 85, 0 }, // yellow/brown
                        .{ 0, 0, 170 }, // blue
                        .{ 170, 0, 170 }, // magenta
                        .{ 0, 170, 170 }, // cyan
                        .{ 170, 170, 170 }, // white
                        .{ 85, 85, 85 }, // bright black (gray)
                        .{ 255, 85, 85 }, // bright red
                        .{ 85, 255, 85 }, // bright green
                        .{ 255, 255, 85 }, // bright yellow
                        .{ 85, 85, 255 }, // bright blue
                        .{ 255, 85, 255 }, // bright magenta
                        .{ 85, 255, 255 }, // bright cyan
                        .{ 255, 255, 255 }, // bright white
                    };
                    return .{ .r = palette[idx][0], .g = palette[idx][1], .b = palette[idx][2] };
                } else if (idx < 232) {
                    // 216-color cube (indices 16-231)
                    const cube_idx = idx - 16;
                    const b_val: u8 = @intCast(cube_idx % 6);
                    const g_val: u8 = @intCast((cube_idx / 6) % 6);
                    const r_val: u8 = @intCast(cube_idx / 36);
                    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
                    return .{ .r = levels[r_val], .g = levels[g_val], .b = levels[b_val] };
                } else {
                    // Grayscale (indices 232-255)
                    const gray_level: u8 = @intCast(8 + (idx - 232) * 10);
                    return .{ .r = gray_level, .g = gray_level, .b = gray_level };
                }
            },
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Screen basic operations" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    try std.testing.expectEqual(@as(u32, 0), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 0), scr.cursor_row);

    scr.putChar('H');
    scr.putChar('i');

    try std.testing.expectEqual(@as(u32, 2), scr.cursor_col);
    try std.testing.expectEqual(@as(u21, 'H'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), scr.getCell(1, 0).char);
}

test "Screen Unicode support" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // Test ASCII
    scr.putChar('A');
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u2, 1), scr.getCell(0, 0).width);

    // Test accented character (single-width)
    scr.putChar(0x00E9); // é
    try std.testing.expectEqual(@as(u21, 0x00E9), scr.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u2, 1), scr.getCell(1, 0).width);

    // Test CJK character (double-width)
    scr.putChar(0x4E2D); // 中
    try std.testing.expectEqual(@as(u21, 0x4E2D), scr.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u2, 2), scr.getCell(2, 0).width);
    try std.testing.expectEqual(@as(u2, 0), scr.getCell(3, 0).width); // continuation
    try std.testing.expectEqual(@as(u32, 4), scr.cursor_col);
}

test "Screen newline and scroll" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 3);
    defer scr.deinit();

    scr.setCursor(0, 2);
    scr.putChar('A');
    scr.newline();
    scr.putChar('B');

    // A should have scrolled up
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'B'), scr.getCell(0, 2).char);
}

test "Color RGB conversion" {
    const black = Color.black.toRgb();
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);

    const white = Color.bright_white.toRgb();
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);
}

test "Screen alternative buffer" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // Write to main buffer
    scr.putChar('M');
    scr.putChar('a');
    scr.putChar('i');
    scr.putChar('n');
    try std.testing.expectEqual(@as(u21, 'M'), scr.getCell(0, 0).char);
    try std.testing.expect(!scr.using_alt_buffer);

    // Switch to alt buffer (with clear)
    try scr.enterAltBuffer(true);
    try std.testing.expect(scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 0).char);

    // Write to alt buffer
    scr.putChar('A');
    scr.putChar('l');
    scr.putChar('t');
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);

    // Switch back to main buffer
    scr.exitAltBuffer();
    try std.testing.expect(!scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u21, 'M'), scr.getCell(0, 0).char);
}

test "Screen cursor save/restore" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // Move cursor and set attribute
    scr.setCursor(10, 5);
    scr.current_attr.bold = true;

    // Save cursor
    scr.saveCursor();

    // Move cursor and change attribute
    scr.setCursor(30, 20);
    scr.current_attr.bold = false;
    scr.current_attr.italic = true;

    try std.testing.expectEqual(@as(u32, 30), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 20), scr.cursor_row);

    // Restore cursor
    scr.restoreCursor();

    try std.testing.expectEqual(@as(u32, 10), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 5), scr.cursor_row);
    try std.testing.expect(scr.current_attr.bold);
    try std.testing.expect(!scr.current_attr.italic);
}

test "Screen mode 1049 (alt buffer with cursor save)" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // Set up initial state
    scr.setCursor(15, 10);
    scr.putChar('X');
    scr.current_attr.underline = true;

    // Enter alt buffer with cursor save (mode 1049)
    try scr.enterAltBufferWithCursorSave();
    try std.testing.expect(scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 0).char); // cleared

    // Move cursor in alt buffer
    scr.setCursor(5, 3);
    scr.putChar('Y');
    scr.current_attr.underline = false;

    // Exit alt buffer with cursor restore (mode 1049)
    scr.exitAltBufferWithCursorRestore();
    try std.testing.expect(!scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u32, 16), scr.cursor_col); // restored after 'X' was written
    try std.testing.expectEqual(@as(u32, 10), scr.cursor_row);
    try std.testing.expect(scr.current_attr.underline);
    try std.testing.expectEqual(@as(u21, 'X'), scr.getCell(15, 10).char); // main buffer preserved
}
