const std = @import("std");
const screen = @import("screen");

/// VT100/ANSI escape sequence parser
/// Processes input bytes and performs terminal operations on a Screen
pub const Parser = struct {
    state: State,
    params: [16]u32,
    param_count: u8,
    intermediate: [4]u8,
    intermediate_count: u8,
    scr: *screen.Screen,

    const Self = @This();

    const State = enum {
        ground,
        escape,
        escape_intermediate,
        csi_entry,
        csi_param,
        csi_intermediate,
        osc_string,
        dcs_entry,
        ignore,
    };

    pub fn init(scr: *screen.Screen) Self {
        return .{
            .state = .ground,
            .params = [_]u32{0} ** 16,
            .param_count = 0,
            .intermediate = [_]u8{0} ** 4,
            .intermediate_count = 0,
            .scr = scr,
        };
    }

    /// Process a single input byte
    pub fn feed(self: *Self, c: u8) void {
        switch (self.state) {
            .ground => self.handleGround(c),
            .escape => self.handleEscape(c),
            .escape_intermediate => self.handleEscapeIntermediate(c),
            .csi_entry => self.handleCsiEntry(c),
            .csi_param => self.handleCsiParam(c),
            .csi_intermediate => self.handleCsiIntermediate(c),
            .osc_string => self.handleOscString(c),
            .dcs_entry => self.handleDcsEntry(c),
            .ignore => self.handleIgnore(c),
        }
    }

    /// Process multiple bytes
    pub fn feedSlice(self: *Self, data: []const u8) void {
        for (data) |c| {
            self.feed(c);
        }
    }

    fn reset(self: *Self) void {
        self.state = .ground;
        self.params = [_]u32{0} ** 16;
        self.param_count = 0;
        self.intermediate = [_]u8{0} ** 4;
        self.intermediate_count = 0;
    }

    fn handleGround(self: *Self, c: u8) void {
        if (c == 0x1B) {
            // ESC
            self.state = .escape;
        } else if (c < 0x20) {
            // Control character
            self.handleControl(c);
        } else if (c >= 0x20 and c < 0x7F) {
            // Printable
            self.scr.putChar(c);
        }
        // Ignore 0x7F (DEL) and high bytes for now
    }

    fn handleControl(self: *Self, c: u8) void {
        switch (c) {
            0x07 => {}, // Bell (ignore for now)
            0x08 => self.scr.backspace(),
            0x09 => self.scr.tab(),
            0x0A, 0x0B, 0x0C => self.scr.newline(), // LF, VT, FF
            0x0D => self.scr.carriageReturn(),
            else => {},
        }
    }

    fn handleEscape(self: *Self, c: u8) void {
        if (c == '[') {
            // CSI
            self.state = .csi_entry;
            self.params = [_]u32{0} ** 16;
            self.param_count = 0;
            self.intermediate = [_]u8{0} ** 4;
            self.intermediate_count = 0;
        } else if (c == ']') {
            // OSC
            self.state = .osc_string;
        } else if (c == 'P') {
            // DCS
            self.state = .dcs_entry;
        } else if (c >= 0x20 and c <= 0x2F) {
            // Intermediate
            self.state = .escape_intermediate;
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c >= 0x30 and c <= 0x7E) {
            // Final character
            self.handleEscapeSequence(c);
            self.reset();
        } else if (c == 0x1B) {
            // Another ESC, restart
            self.state = .escape;
        } else {
            self.reset();
        }
    }

    fn handleEscapeIntermediate(self: *Self, c: u8) void {
        if (c >= 0x20 and c <= 0x2F) {
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c >= 0x30 and c <= 0x7E) {
            self.handleEscapeSequence(c);
            self.reset();
        } else {
            self.reset();
        }
    }

    fn handleEscapeSequence(self: *Self, c: u8) void {
        _ = self;
        switch (c) {
            'c' => {}, // RIS - Full reset (TODO)
            'D' => {}, // IND - Index (TODO)
            'E' => {}, // NEL - Next line (TODO)
            'H' => {}, // HTS - Tab set (TODO)
            'M' => {}, // RI - Reverse index (TODO)
            '7' => {}, // DECSC - Save cursor (TODO)
            '8' => {}, // DECRC - Restore cursor (TODO)
            else => {},
        }
    }

    fn handleCsiEntry(self: *Self, c: u8) void {
        if (c >= '0' and c <= '9') {
            self.state = .csi_param;
            self.params[0] = c - '0';
            self.param_count = 1;
        } else if (c == ';') {
            self.state = .csi_param;
            self.param_count = 1;
        } else if (c >= 0x40 and c <= 0x7E) {
            // Final character with no params
            self.executeCsi(c);
            self.reset();
        } else if (c >= 0x20 and c <= 0x2F) {
            self.state = .csi_intermediate;
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c == 0x1B) {
            self.state = .escape;
        } else {
            self.reset();
        }
    }

    fn handleCsiParam(self: *Self, c: u8) void {
        if (c >= '0' and c <= '9') {
            if (self.param_count == 0) self.param_count = 1;
            const idx = self.param_count - 1;
            self.params[idx] = self.params[idx] * 10 + (c - '0');
        } else if (c == ';') {
            if (self.param_count < 16) {
                self.param_count += 1;
            }
        } else if (c >= 0x40 and c <= 0x7E) {
            // Final character
            self.executeCsi(c);
            self.reset();
        } else if (c >= 0x20 and c <= 0x2F) {
            self.state = .csi_intermediate;
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c == 0x1B) {
            self.state = .escape;
        } else {
            self.reset();
        }
    }

    fn handleCsiIntermediate(self: *Self, c: u8) void {
        if (c >= 0x20 and c <= 0x2F) {
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c >= 0x40 and c <= 0x7E) {
            self.executeCsi(c);
            self.reset();
        } else {
            self.reset();
        }
    }

    fn handleOscString(self: *Self, c: u8) void {
        // OSC ends with BEL (0x07) or ST (ESC \)
        if (c == 0x07) {
            self.reset();
        } else if (c == 0x1B) {
            self.state = .escape; // May be ST
        }
        // Otherwise consume the string (we don't handle OSC for now)
    }

    fn handleDcsEntry(self: *Self, c: u8) void {
        // DCS ends with ST (ESC \)
        if (c == 0x1B) {
            self.state = .escape;
        }
        // Consume until end
    }

    fn handleIgnore(self: *Self, c: u8) void {
        _ = c;
        self.reset();
    }

    fn getParam(self: *Self, idx: usize, default: u32) u32 {
        if (idx < self.param_count and self.params[idx] != 0) {
            return self.params[idx];
        }
        return default;
    }

    fn executeCsi(self: *Self, c: u8) void {
        switch (c) {
            'A' => {
                // CUU - Cursor up
                const n = self.getParam(0, 1);
                self.scr.cursorUp(n);
            },
            'B' => {
                // CUD - Cursor down
                const n = self.getParam(0, 1);
                self.scr.cursorDown(n);
            },
            'C' => {
                // CUF - Cursor forward
                const n = self.getParam(0, 1);
                self.scr.cursorRight(n);
            },
            'D' => {
                // CUB - Cursor back
                const n = self.getParam(0, 1);
                self.scr.cursorLeft(n);
            },
            'E' => {
                // CNL - Cursor next line
                const n = self.getParam(0, 1);
                self.scr.cursorDown(n);
                self.scr.carriageReturn();
            },
            'F' => {
                // CPL - Cursor previous line
                const n = self.getParam(0, 1);
                self.scr.cursorUp(n);
                self.scr.carriageReturn();
            },
            'G' => {
                // CHA - Cursor horizontal absolute
                const col = self.getParam(0, 1);
                self.scr.setCursor(col -| 1, self.scr.cursor_row);
            },
            'H', 'f' => {
                // CUP/HVP - Cursor position
                const row = self.getParam(0, 1);
                const col = self.getParam(1, 1);
                self.scr.setCursor(col -| 1, row -| 1);
            },
            'J' => {
                // ED - Erase in display
                const mode = self.getParam(0, 0);
                switch (mode) {
                    0 => self.scr.eraseToEndOfScreen(),
                    1 => self.scr.eraseToStartOfScreen(),
                    2, 3 => self.scr.eraseScreen(),
                    else => {},
                }
            },
            'K' => {
                // EL - Erase in line
                const mode = self.getParam(0, 0);
                switch (mode) {
                    0 => self.scr.eraseToEndOfLine(),
                    1 => self.scr.eraseToStartOfLine(),
                    2 => self.scr.eraseLine(),
                    else => {},
                }
            },
            'L' => {
                // IL - Insert lines
                const n = self.getParam(0, 1);
                self.scr.insertLines(n);
            },
            'M' => {
                // DL - Delete lines
                const n = self.getParam(0, 1);
                self.scr.deleteLines(n);
            },
            'P' => {
                // DCH - Delete characters
                const n = self.getParam(0, 1);
                self.scr.deleteChars(n);
            },
            '@' => {
                // ICH - Insert characters
                const n = self.getParam(0, 1);
                self.scr.insertChars(n);
            },
            'S' => {
                // SU - Scroll up
                const n = self.getParam(0, 1);
                self.scr.scrollUp(n);
            },
            'T' => {
                // SD - Scroll down
                const n = self.getParam(0, 1);
                self.scr.scrollDown(n);
            },
            'd' => {
                // VPA - Line position absolute
                const row = self.getParam(0, 1);
                self.scr.setCursor(self.scr.cursor_col, row -| 1);
            },
            'm' => {
                // SGR - Select graphic rendition
                self.executeSgr();
            },
            'r' => {
                // DECSTBM - Set scrolling region
                const top = self.getParam(0, 1);
                const bottom = self.getParam(1, self.scr.rows);
                self.scr.setScrollRegion(top -| 1, bottom -| 1);
            },
            's' => {
                // SCP - Save cursor position (TODO)
            },
            'u' => {
                // RCP - Restore cursor position (TODO)
            },
            else => {},
        }
    }

    fn executeSgr(self: *Self) void {
        if (self.param_count == 0) {
            // No params = reset
            self.scr.current_attr = screen.Attr.default();
            return;
        }

        var i: usize = 0;
        while (i < self.param_count) {
            const p = self.params[i];
            switch (p) {
                0 => self.scr.current_attr = screen.Attr.default(),
                1 => self.scr.current_attr.bold = true,
                2 => self.scr.current_attr.dim = true,
                3 => self.scr.current_attr.italic = true,
                4 => self.scr.current_attr.underline = true,
                5, 6 => self.scr.current_attr.blink = true,
                7 => self.scr.current_attr.reverse = true,
                8 => self.scr.current_attr.hidden = true,
                21, 22 => {
                    self.scr.current_attr.bold = false;
                    self.scr.current_attr.dim = false;
                },
                23 => self.scr.current_attr.italic = false,
                24 => self.scr.current_attr.underline = false,
                25 => self.scr.current_attr.blink = false,
                27 => self.scr.current_attr.reverse = false,
                28 => self.scr.current_attr.hidden = false,
                30...37 => self.scr.current_attr.fg = screen.Color{ .indexed = @intCast(p - 30) },
                38 => {
                    // Extended foreground color
                    i += 1;
                    if (i < self.param_count) {
                        const mode = self.params[i];
                        if (mode == 5 and i + 1 < self.param_count) {
                            // 256 color
                            i += 1;
                            self.scr.current_attr.fg = screen.Color{ .indexed = @intCast(self.params[i]) };
                        } else if (mode == 2 and i + 3 < self.param_count) {
                            // RGB color
                            self.scr.current_attr.fg = screen.Color{ .rgb = .{
                                .r = @intCast(self.params[i + 1]),
                                .g = @intCast(self.params[i + 2]),
                                .b = @intCast(self.params[i + 3]),
                            } };
                            i += 3;
                        }
                    }
                },
                39 => self.scr.current_attr.fg = screen.Color.default_fg,
                40...47 => self.scr.current_attr.bg = screen.Color{ .indexed = @intCast(p - 40) },
                48 => {
                    // Extended background color
                    i += 1;
                    if (i < self.param_count) {
                        const mode = self.params[i];
                        if (mode == 5 and i + 1 < self.param_count) {
                            // 256 color
                            i += 1;
                            self.scr.current_attr.bg = screen.Color{ .indexed = @intCast(self.params[i]) };
                        } else if (mode == 2 and i + 3 < self.param_count) {
                            // RGB color
                            self.scr.current_attr.bg = screen.Color{ .rgb = .{
                                .r = @intCast(self.params[i + 1]),
                                .g = @intCast(self.params[i + 2]),
                                .b = @intCast(self.params[i + 3]),
                            } };
                            i += 3;
                        }
                    }
                },
                49 => self.scr.current_attr.bg = screen.Color.default_bg,
                90...97 => self.scr.current_attr.fg = screen.Color{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.scr.current_attr.bg = screen.Color{ .indexed = @intCast(p - 100 + 8) },
                else => {},
            }
            i += 1;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Parser basic text" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);
    parser.feedSlice("Hello");

    try std.testing.expectEqual(@as(u32, 5), scr.cursor_col);
    try std.testing.expectEqual(@as(u8, 'H'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u8, 'o'), scr.getCell(4, 0).char);
}

test "Parser cursor movement" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Move cursor to (10, 5)
    parser.feedSlice("\x1b[6;11H");
    try std.testing.expectEqual(@as(u32, 10), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 5), scr.cursor_row);

    // Move up 2
    parser.feedSlice("\x1b[2A");
    try std.testing.expectEqual(@as(u32, 3), scr.cursor_row);

    // Move right 5
    parser.feedSlice("\x1b[5C");
    try std.testing.expectEqual(@as(u32, 15), scr.cursor_col);
}

test "Parser clear screen" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Write something
    parser.feedSlice("Hello");

    // Clear screen
    parser.feedSlice("\x1b[2J");

    try std.testing.expectEqual(@as(u8, ' '), scr.getCell(0, 0).char);
}

test "Parser colors" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Set red foreground
    parser.feedSlice("\x1b[31mR");
    const cell = scr.getCell(0, 0);
    try std.testing.expectEqual(@as(u8, 'R'), cell.char);
    try std.testing.expectEqual(screen.Color{ .indexed = 1 }, cell.attr.fg);

    // Reset
    parser.feedSlice("\x1b[0mN");
    const cell2 = scr.getCell(1, 0);
    try std.testing.expectEqual(screen.Color.default_fg, cell2.attr.fg);
}
