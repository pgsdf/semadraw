const std = @import("std");
const semadraw = @import("semadraw");
const screen = @import("screen");
const font = @import("font");

/// Terminal renderer - converts screen buffer to SDCS commands
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    encoder: semadraw.Encoder,
    atlas: [font.Font.ATLAS_WIDTH * font.Font.ATLAS_HEIGHT]u8,
    scr: *screen.Screen,
    width_px: u32,
    height_px: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, scr: *screen.Screen) Self {
        return .{
            .allocator = allocator,
            .encoder = semadraw.Encoder.init(allocator),
            .atlas = font.Font.generateAtlas(),
            .scr = scr,
            .width_px = scr.cols * font.Font.GLYPH_WIDTH,
            .height_px = scr.rows * font.Font.GLYPH_HEIGHT,
        };
    }

    pub fn deinit(self: *Self) void {
        self.encoder.deinit();
    }

    /// Render the screen to SDCS and return the encoded data
    pub fn render(self: *Self) ![]u8 {
        self.encoder.reset() catch {};
        try self.encoder.reset();

        // Draw background
        try self.encoder.setBlend(semadraw.Encoder.BlendMode.Src);
        try self.encoder.fillRect(
            0,
            0,
            @floatFromInt(self.width_px),
            @floatFromInt(self.height_px),
            0.0,
            0.0,
            0.0,
            1.0, // Black background
        );

        try self.encoder.setBlend(semadraw.Encoder.BlendMode.SrcOver);

        // Group cells by color for efficient rendering
        try self.renderCells();

        // Draw cursor
        if (self.scr.cursor_visible) {
            try self.renderCursor();
        }

        try self.encoder.end();

        // Return the encoded data
        return self.encoder.toOwnedSlice();
    }

    fn renderCells(self: *Self) !void {
        // For simplicity, render each row as potentially multiple glyph runs
        // (different colors require separate runs)

        var row: u32 = 0;
        while (row < self.scr.rows) : (row += 1) {
            try self.renderRow(row);
        }
    }

    fn renderRow(self: *Self, row: u32) !void {
        var col: u32 = 0;

        while (col < self.scr.cols) {
            const start_col = col;
            const start_cell = self.scr.getCell(col, row);
            const start_fg = start_cell.attr.effectiveFg();
            const start_bg = start_cell.attr.effectiveBg();

            // Collect consecutive cells with same attributes
            var glyphs = std.ArrayList(semadraw.Encoder.Glyph).init(self.allocator);
            defer glyphs.deinit();

            while (col < self.scr.cols) {
                const cell = self.scr.getCell(col, row);
                const fg = cell.attr.effectiveFg();
                const bg = cell.attr.effectiveBg();

                // Check if attributes match
                if (!colorEqual(fg, start_fg) or !colorEqual(bg, start_bg)) {
                    break;
                }

                // Skip spaces with default background (optimization)
                if (cell.char != ' ' or !colorEqual(bg, screen.Color.default_bg)) {
                    if (font.Font.charToIndex(cell.char)) |glyph_idx| {
                        try glyphs.append(.{
                            .index = glyph_idx,
                            .x_offset = @floatFromInt((col - start_col) * font.Font.GLYPH_WIDTH),
                            .y_offset = 0,
                        });
                    }
                }

                col += 1;
            }

            if (glyphs.items.len == 0) continue;

            // Draw background if not default
            if (!colorEqual(start_bg, screen.Color.default_bg)) {
                const bg_rgb = start_bg.toRgb();
                const run_width = (col - start_col) * font.Font.GLYPH_WIDTH;
                try self.encoder.fillRect(
                    @floatFromInt(start_col * font.Font.GLYPH_WIDTH),
                    @floatFromInt(row * font.Font.GLYPH_HEIGHT),
                    @floatFromInt(run_width),
                    @floatFromInt(font.Font.GLYPH_HEIGHT),
                    @as(f32, @floatFromInt(bg_rgb.r)) / 255.0,
                    @as(f32, @floatFromInt(bg_rgb.g)) / 255.0,
                    @as(f32, @floatFromInt(bg_rgb.b)) / 255.0,
                    1.0,
                );
            }

            // Draw glyphs
            const fg_rgb = start_fg.toRgb();
            try self.encoder.drawGlyphRun(
                @floatFromInt(start_col * font.Font.GLYPH_WIDTH),
                @floatFromInt(row * font.Font.GLYPH_HEIGHT),
                @as(f32, @floatFromInt(fg_rgb.r)) / 255.0,
                @as(f32, @floatFromInt(fg_rgb.g)) / 255.0,
                @as(f32, @floatFromInt(fg_rgb.b)) / 255.0,
                1.0,
                font.Font.GLYPH_WIDTH,
                font.Font.GLYPH_HEIGHT,
                font.Font.ATLAS_COLS,
                font.Font.ATLAS_WIDTH,
                font.Font.ATLAS_HEIGHT,
                glyphs.items,
                &self.atlas,
            );
        }
    }

    fn renderCursor(self: *Self) !void {
        const cursor_x = self.scr.cursor_col * font.Font.GLYPH_WIDTH;
        const cursor_y = self.scr.cursor_row * font.Font.GLYPH_HEIGHT;

        // Draw a block cursor
        try self.encoder.fillRect(
            @floatFromInt(cursor_x),
            @floatFromInt(cursor_y),
            @floatFromInt(font.Font.GLYPH_WIDTH),
            @floatFromInt(font.Font.GLYPH_HEIGHT),
            0.7,
            0.7,
            0.7,
            0.8, // Semi-transparent white
        );
    }

    fn colorEqual(a: screen.Color, b: screen.Color) bool {
        switch (a) {
            .indexed => |ai| {
                switch (b) {
                    .indexed => |bi| return ai == bi,
                    .rgb => return false,
                }
            },
            .rgb => |ar| {
                switch (b) {
                    .indexed => return false,
                    .rgb => |br| return ar.r == br.r and ar.g == br.g and ar.b == br.b,
                }
            },
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Renderer basic" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    scr.putChar('H');
    scr.putChar('i');

    var renderer = Renderer.init(allocator, &scr);
    defer renderer.deinit();

    const data = try renderer.render();
    defer allocator.free(data);

    // Just check that we got some data
    try std.testing.expect(data.len > 0);
}
