const std = @import("std");

/// Terminal screen buffer
/// Manages character grid with attributes, cursor, and scrolling
/// Supports alternative screen buffer (mode 1049) for vim, htop, less, etc.
/// Supports scrollback history for viewing past output
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

    // Scrollback buffer (ring buffer of saved lines)
    scrollback: ?[][]Cell, // Array of saved lines (each line is cols cells)
    scrollback_max: u32, // Maximum number of lines to save
    scrollback_count: u32, // Current number of lines in scrollback
    scrollback_start: u32, // Ring buffer start index
    scroll_view_offset: u32, // How many lines we're scrolled back (0 = at bottom)

    // Terminal title (set via OSC 0/1/2)
    title: [256]u8, // Window/icon title (null-terminated)
    title_len: u8,
    icon_name: [256]u8, // Icon name (separate from title)
    icon_name_len: u8,

    // Color palette customization (OSC 4/10/11)
    custom_palette: ?*[256][3]u8, // Custom 256-color palette (null = use default)
    custom_fg: ?[3]u8, // Custom foreground color (OSC 10)
    custom_bg: ?[3]u8, // Custom background color (OSC 11)

    // Mouse tracking configuration (DECSET modes)
    mouse_tracking: MouseTrackingMode,
    mouse_encoding: MouseEncodingMode,
    mouse_focus_events: bool, // Mode 1004: Report focus in/out

    /// Mouse tracking modes
    pub const MouseTrackingMode = enum(u8) {
        none = 0, // No mouse tracking
        x10 = 9, // X10 mode: Only report button presses
        vt200 = 1000, // VT200 mode: Report presses and releases
        vt200_highlight = 1001, // VT200 highlight mode
        btn_event = 1002, // Button-event mode: presses, releases, and motion with button down
        any_event = 1003, // Any-event mode: all motion events
    };

    /// Mouse encoding modes (how coordinates are reported)
    pub const MouseEncodingMode = enum(u8) {
        x10 = 0, // Default X10: CSI M Cb Cx Cy (limited to 223 columns/rows)
        utf8 = 1005, // UTF-8 encoding for coordinates
        sgr = 1006, // SGR extended: CSI < Pb ; Px ; Py M/m
        urxvt = 1015, // URXVT style: CSI Pb ; Px ; Py M
    };

    /// Default scrollback buffer size (lines)
    pub const DEFAULT_SCROLLBACK_LINES: u32 = 1000;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cols: u32, rows: u32) !Self {
        return initWithScrollback(allocator, cols, rows, DEFAULT_SCROLLBACK_LINES);
    }

    pub fn initWithScrollback(allocator: std.mem.Allocator, cols: u32, rows: u32, scrollback_lines: u32) !Self {
        const cells = try allocator.alloc(Cell, cols * rows);
        for (cells) |*cell| {
            cell.* = Cell.blank();
        }

        // Allocate scrollback buffer if enabled
        var scrollback: ?[][]Cell = null;
        if (scrollback_lines > 0) {
            scrollback = try allocator.alloc([]Cell, scrollback_lines);
            for (scrollback.?) |*line| {
                line.* = &[_]Cell{};
            }
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
            // Scrollback buffer
            .scrollback = scrollback,
            .scrollback_max = scrollback_lines,
            .scrollback_count = 0,
            .scrollback_start = 0,
            .scroll_view_offset = 0,
            // Terminal title
            .title = [_]u8{0} ** 256,
            .title_len = 0,
            .icon_name = [_]u8{0} ** 256,
            .icon_name_len = 0,
            // Color palette
            .custom_palette = null,
            .custom_fg = null,
            .custom_bg = null,
            // Mouse tracking
            .mouse_tracking = .none,
            .mouse_encoding = .x10,
            .mouse_focus_events = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        if (self.alt_cells) |alt| {
            self.allocator.free(alt);
        }
        // Free scrollback buffer
        if (self.scrollback) |sb| {
            for (sb) |line| {
                if (line.len > 0) {
                    self.allocator.free(line);
                }
            }
            self.allocator.free(sb);
        }
        // Free custom palette if allocated
        if (self.custom_palette) |palette| {
            self.allocator.destroy(palette);
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
    /// Lines scrolling off the top are saved to scrollback (main buffer only)
    pub fn scrollUp(self: *Self, n: u32) void {
        const lines_to_scroll = @min(n, self.scroll_bottom - self.scroll_top + 1);
        const start_row = self.scroll_top;
        const end_row = self.scroll_bottom;

        // Save lines to scrollback (only from main buffer, not alt buffer)
        // Only save when scroll region is at the top of screen
        if (!self.using_alt_buffer and start_row == 0) {
            self.saveLinesToScrollback(lines_to_scroll);
        }

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

        // Reset scroll view when new content is added
        if (self.scroll_view_offset > 0) {
            self.scroll_view_offset = 0;
        }
    }

    /// Save lines from the top of screen to scrollback buffer
    fn saveLinesToScrollback(self: *Self, count: u32) void {
        const sb = self.scrollback orelse return;
        if (self.scrollback_max == 0) return;

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            // Calculate the index in the ring buffer
            var idx: u32 = undefined;
            if (self.scrollback_count < self.scrollback_max) {
                // Buffer not full yet, append
                idx = self.scrollback_count;
                self.scrollback_count += 1;
            } else {
                // Buffer full, overwrite oldest
                idx = self.scrollback_start;
                self.scrollback_start = (self.scrollback_start + 1) % self.scrollback_max;
            }

            // Free old line if any
            if (sb[idx].len > 0) {
                self.allocator.free(sb[idx]);
            }

            // Allocate and copy the line
            const new_line = self.allocator.alloc(Cell, self.cols) catch {
                sb[idx] = &[_]Cell{};
                continue;
            };
            const src_start = i * self.cols;
            @memcpy(new_line, self.cells[src_start..][0..self.cols]);
            sb[idx] = new_line;
        }
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

    // ========================================================================
    // Terminal title (OSC 0/1/2)
    // ========================================================================

    /// Set window title (OSC 2) or both title and icon name (OSC 0)
    pub fn setTitle(self: *Self, text: []const u8) void {
        const len = @min(text.len, 255);
        @memcpy(self.title[0..len], text[0..len]);
        self.title_len = @intCast(len);
        self.title[len] = 0; // Null terminate
    }

    /// Set icon name (OSC 1)
    pub fn setIconName(self: *Self, text: []const u8) void {
        const len = @min(text.len, 255);
        @memcpy(self.icon_name[0..len], text[0..len]);
        self.icon_name_len = @intCast(len);
        self.icon_name[len] = 0; // Null terminate
    }

    /// Get current window title as a slice
    pub fn getTitle(self: *const Self) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Get current icon name as a slice
    pub fn getIconName(self: *const Self) []const u8 {
        return self.icon_name[0..self.icon_name_len];
    }

    // ========================================================================
    // Color palette customization (OSC 4/10/11)
    // ========================================================================

    /// Set a custom palette color (OSC 4)
    pub fn setPaletteColor(self: *Self, index: u8, r: u8, g: u8, b: u8) !void {
        // Allocate custom palette on first use
        if (self.custom_palette == null) {
            self.custom_palette = try self.allocator.create([256][3]u8);
            // Initialize with default palette
            for (0..256) |i| {
                const default_rgb = (Color{ .indexed = @intCast(i) }).toRgb();
                self.custom_palette.?[i] = .{ default_rgb.r, default_rgb.g, default_rgb.b };
            }
        }
        self.custom_palette.?[index] = .{ r, g, b };
    }

    /// Set custom foreground color (OSC 10)
    pub fn setForegroundColor(self: *Self, r: u8, g: u8, b: u8) void {
        self.custom_fg = .{ r, g, b };
    }

    /// Set custom background color (OSC 11)
    pub fn setBackgroundColor(self: *Self, r: u8, g: u8, b: u8) void {
        self.custom_bg = .{ r, g, b };
    }

    /// Reset palette color to default (OSC 104)
    pub fn resetPaletteColor(self: *Self, index: u8) void {
        if (self.custom_palette) |palette| {
            const default_rgb = (Color{ .indexed = index }).toRgb();
            palette[index] = .{ default_rgb.r, default_rgb.g, default_rgb.b };
        }
    }

    /// Reset all palette colors to default (OSC 104 with no args)
    pub fn resetPalette(self: *Self) void {
        if (self.custom_palette) |palette| {
            self.allocator.destroy(palette);
            self.custom_palette = null;
        }
    }

    /// Reset foreground color to default (OSC 110)
    pub fn resetForegroundColor(self: *Self) void {
        self.custom_fg = null;
    }

    /// Reset background color to default (OSC 111)
    pub fn resetBackgroundColor(self: *Self) void {
        self.custom_bg = null;
    }

    /// Get effective palette color (custom if set, else default)
    pub fn getPaletteColor(self: *const Self, index: u8) struct { r: u8, g: u8, b: u8 } {
        if (self.custom_palette) |palette| {
            return .{ .r = palette[index][0], .g = palette[index][1], .b = palette[index][2] };
        }
        return (Color{ .indexed = index }).toRgb();
    }

    /// Get effective foreground color (custom if set, else default)
    pub fn getEffectiveForeground(self: *const Self) struct { r: u8, g: u8, b: u8 } {
        if (self.custom_fg) |fg| {
            return .{ .r = fg[0], .g = fg[1], .b = fg[2] };
        }
        return Color.default_fg.toRgb();
    }

    /// Get effective background color (custom if set, else default)
    pub fn getEffectiveBackground(self: *const Self) struct { r: u8, g: u8, b: u8 } {
        if (self.custom_bg) |bg| {
            return .{ .r = bg[0], .g = bg[1], .b = bg[2] };
        }
        return Color.default_bg.toRgb();
    }

    // ========================================================================
    // Mouse tracking (DECSET modes 9, 1000-1006, 1015)
    // ========================================================================

    /// Set mouse tracking mode
    pub fn setMouseTracking(self: *Self, mode: MouseTrackingMode) void {
        self.mouse_tracking = mode;
    }

    /// Get current mouse tracking mode
    pub fn getMouseTracking(self: *const Self) MouseTrackingMode {
        return self.mouse_tracking;
    }

    /// Set mouse encoding mode
    pub fn setMouseEncoding(self: *Self, mode: MouseEncodingMode) void {
        self.mouse_encoding = mode;
    }

    /// Get current mouse encoding mode
    pub fn getMouseEncoding(self: *const Self) MouseEncodingMode {
        return self.mouse_encoding;
    }

    /// Enable/disable focus event reporting (mode 1004)
    pub fn setFocusEvents(self: *Self, enabled: bool) void {
        self.mouse_focus_events = enabled;
    }

    /// Check if focus event reporting is enabled
    pub fn getFocusEvents(self: *const Self) bool {
        return self.mouse_focus_events;
    }

    /// Check if any mouse tracking is enabled
    pub fn isMouseTrackingEnabled(self: *const Self) bool {
        return self.mouse_tracking != .none;
    }

    // ========================================================================
    // Scrollback buffer navigation
    // ========================================================================

    /// Scroll view up (into history) by n lines
    /// Returns true if scroll position changed
    pub fn scrollViewUp(self: *Self, n: u32) bool {
        if (self.scrollback_count == 0) return false;

        const max_offset = self.scrollback_count;
        const new_offset = @min(self.scroll_view_offset + n, max_offset);

        if (new_offset != self.scroll_view_offset) {
            self.scroll_view_offset = new_offset;
            self.dirty = true;
            return true;
        }
        return false;
    }

    /// Scroll view down (toward present) by n lines
    /// Returns true if scroll position changed
    pub fn scrollViewDown(self: *Self, n: u32) bool {
        if (self.scroll_view_offset == 0) return false;

        if (n >= self.scroll_view_offset) {
            self.scroll_view_offset = 0;
        } else {
            self.scroll_view_offset -= n;
        }
        self.dirty = true;
        return true;
    }

    /// Reset scroll view to bottom (present)
    pub fn resetScrollView(self: *Self) void {
        if (self.scroll_view_offset > 0) {
            self.scroll_view_offset = 0;
            self.dirty = true;
        }
    }

    /// Check if currently viewing scrollback
    pub fn isViewingScrollback(self: *const Self) bool {
        return self.scroll_view_offset > 0;
    }

    /// Get cell at visible position (considering scroll offset)
    /// This returns the cell that should be displayed at the given screen position
    pub fn getVisibleCell(self: *const Self, col: u32, row: u32) Cell {
        if (self.scroll_view_offset == 0) {
            // Not scrolled, return normal cell
            return self.cells[row * self.cols + col];
        }

        // Calculate which line this row maps to in the combined view
        // scroll_view_offset = how many lines of scrollback we're viewing
        // The visible area is: [scrollback history] + [screen buffer]
        // With scroll_view_offset, we're looking at an earlier slice

        const scrollback_lines_visible = @min(self.scroll_view_offset, self.scrollback_count);
        const screen_lines_visible = self.rows - scrollback_lines_visible;

        if (row < scrollback_lines_visible) {
            // This row is from scrollback
            const sb = self.scrollback orelse return Cell.blank();

            // Calculate which scrollback line to show
            // scrollback_count - scroll_view_offset + row gives us the line index
            // We need to account for the ring buffer
            const lines_from_end = self.scroll_view_offset - row;
            if (lines_from_end > self.scrollback_count) {
                return Cell.blank();
            }
            const line_idx = self.scrollback_count - lines_from_end;

            // Convert to ring buffer index
            const ring_idx = (self.scrollback_start + line_idx) % self.scrollback_max;
            const line = sb[ring_idx];
            if (line.len == 0 or col >= line.len) {
                return Cell.blank();
            }
            return line[col];
        } else {
            // This row is from screen buffer
            const screen_row = row - scrollback_lines_visible;
            if (screen_row >= screen_lines_visible) {
                return Cell.blank();
            }
            return self.cells[screen_row * self.cols + col];
        }
    }

    /// Get the number of lines available in scrollback
    pub fn getScrollbackCount(self: *const Self) u32 {
        return self.scrollback_count;
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

test "Scrollback buffer saves lines" {
    const allocator = std.testing.allocator;
    // Create a small screen with scrollback enabled
    var scr = try Screen.initWithScrollback(allocator, 10, 3, 10);
    defer scr.deinit();

    // Fill the screen
    scr.setCursor(0, 0);
    scr.putChar('L');
    scr.putChar('1');
    scr.setCursor(0, 1);
    scr.putChar('L');
    scr.putChar('2');
    scr.setCursor(0, 2);
    scr.putChar('L');
    scr.putChar('3');

    try std.testing.expectEqual(@as(u32, 0), scr.scrollback_count);

    // Scroll up (this should save L1 to scrollback)
    scr.setCursor(0, 2);
    scr.newline(); // This triggers scrollUp

    try std.testing.expectEqual(@as(u32, 1), scr.scrollback_count);
    // L2 should now be on row 0, L3 on row 1
    try std.testing.expectEqual(@as(u21, 'L'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '2'), scr.getCell(1, 0).char);
}

test "Scrollback view navigation" {
    const allocator = std.testing.allocator;
    var scr = try Screen.initWithScrollback(allocator, 10, 3, 10);
    defer scr.deinit();

    // Fill with multiple lines and scroll them into history
    var line_num: u8 = '0';
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        scr.setCursor(0, 2);
        scr.putChar('L');
        scr.putChar(line_num);
        line_num += 1;
        scr.newline();
    }

    // Should have 4 lines in scrollback (lines 0-3 scrolled off)
    // Current screen shows lines 4, 5, and new blank line
    try std.testing.expectEqual(@as(u32, 4), scr.scrollback_count);
    try std.testing.expectEqual(@as(u32, 0), scr.scroll_view_offset);

    // Scroll view up into history
    try std.testing.expect(scr.scrollViewUp(2));
    try std.testing.expectEqual(@as(u32, 2), scr.scroll_view_offset);
    try std.testing.expect(scr.isViewingScrollback());

    // Scroll view down
    try std.testing.expect(scr.scrollViewDown(1));
    try std.testing.expectEqual(@as(u32, 1), scr.scroll_view_offset);

    // Reset scroll view
    scr.resetScrollView();
    try std.testing.expectEqual(@as(u32, 0), scr.scroll_view_offset);
    try std.testing.expect(!scr.isViewingScrollback());
}

test "Scrollback getVisibleCell" {
    const allocator = std.testing.allocator;
    var scr = try Screen.initWithScrollback(allocator, 10, 3, 10);
    defer scr.deinit();

    // Put 'A' on first line, scroll it into history
    scr.putChar('A');
    scr.setCursor(0, 2);
    scr.newline();

    // Now 'A' is in scrollback, screen is empty
    try std.testing.expectEqual(@as(u32, 1), scr.scrollback_count);

    // Without scrollback view, we see the current screen
    try std.testing.expectEqual(@as(u21, ' '), scr.getVisibleCell(0, 0).char);

    // Scroll up to view history
    _ = scr.scrollViewUp(1);

    // Now we should see the scrollback line
    try std.testing.expectEqual(@as(u21, 'A'), scr.getVisibleCell(0, 0).char);
}

test "Scrollback not saved from alt buffer" {
    const allocator = std.testing.allocator;
    var scr = try Screen.initWithScrollback(allocator, 10, 3, 10);
    defer scr.deinit();

    // Put something on main screen
    scr.putChar('M');

    // Switch to alt buffer
    try scr.enterAltBuffer(true);
    try std.testing.expect(scr.using_alt_buffer);

    // Scroll in alt buffer - should NOT save to scrollback
    scr.putChar('A');
    scr.setCursor(0, 2);
    scr.newline();

    try std.testing.expectEqual(@as(u32, 0), scr.scrollback_count);

    // Exit alt buffer
    scr.exitAltBuffer();
    try std.testing.expectEqual(@as(u32, 0), scr.scrollback_count);
}
