const std = @import("std");
const semadraw = @import("semadraw");
const screen = @import("screen");
const font = @import("font");

/// Terminal renderer - converts screen buffer to SDCS commands
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    encoder: semadraw.Encoder,
    /// Pointer to compile-time generated font atlas (no per-instance copy needed)
    atlas: *const [font.Font.ATLAS_WIDTH * font.Font.ATLAS_HEIGHT]u8,
    scr: *screen.Screen,
    width_px: u32,
    height_px: u32,
    // Reusable buffer for glyph runs to avoid per-row allocations
    glyph_buffer: std.ArrayList(semadraw.Encoder.Glyph),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, scr: *screen.Screen) Self {
        return .{
            .allocator = allocator,
            .encoder = semadraw.Encoder.init(allocator),
            .atlas = &font.Font.ATLAS,
            .scr = scr,
            .width_px = scr.cols * font.Font.GLYPH_WIDTH,
            .height_px = scr.rows * font.Font.GLYPH_HEIGHT,
            .glyph_buffer = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.encoder.deinit();
    }

    /// Menu overlay parameters for chord menu rendering
    pub const MenuOverlay = struct {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        item_height: u32,
        labels: []const []const u8,
        selected_idx: ?usize,
    };

    /// Render the screen to SDCS and return the encoded data
    /// Uses dirty row tracking to skip re-rendering unchanged rows
    pub fn render(self: *Self) ![]u8 {
        return self.renderWithOverlay(null);
    }

    /// Render the screen with an optional menu overlay
    pub fn renderWithOverlay(self: *Self, menu: ?MenuOverlay) ![]u8 {
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

        // Render all cells - each SDCS frame replaces surface content entirely,
        // so dirty row optimization cannot be used (content is not preserved between commits)
        try self.renderCells();

        // Draw cursor (hidden when viewing scrollback history)
        if (self.scr.cursor_visible and !self.scr.isViewingScrollback()) {
            try self.renderCursor();
        }

        // Draw menu overlay if present
        if (menu) |m| {
            try self.renderChordMenu(m.x, m.y, m.width, m.height, m.item_height, m.labels, m.selected_idx);
        }

        try self.encoder.end();

        // Clear dirty flags after successful render
        self.scr.clearDirtyRows();

        // Return the encoded data with SDCS header for daemon validation
        return self.encoder.finishBytesWithHeader();
    }

    /// Render a full frame (all rows) regardless of dirty state
    /// Use this when you need to guarantee a complete redraw
    pub fn renderFull(self: *Self) ![]u8 {
        // Mark all rows dirty to force full render
        self.scr.markAllRowsDirty();
        return self.render();
    }

    fn renderCells(self: *Self) !void {
        // For simplicity, render each row as potentially multiple glyph runs
        // (different colors require separate runs)

        var row: u32 = 0;
        while (row < self.scr.rows) : (row += 1) {
            try self.renderRow(row);
        }
    }

    fn renderDirtyCells(self: *Self) !void {
        // Only render rows that have been marked as dirty
        // This significantly reduces rendering cost when only a few rows change

        var row: u32 = 0;
        while (row < self.scr.rows) : (row += 1) {
            if (self.scr.isRowDirty(row)) {
                try self.renderRow(row);
            }
        }
    }

    fn renderRow(self: *Self, row: u32) !void {
        var col: u32 = 0;

        while (col < self.scr.cols) {
            const start_col = col;
            // Use getVisibleCell to support scrollback viewing
            const start_cell = self.scr.getVisibleCell(col, row);

            // Skip continuation cells (part of wide character)
            if (start_cell.width == 0) {
                col += 1;
                continue;
            }

            // Check if this cell is selected (for highlight)
            const start_selected = self.scr.isCellSelected(col, row);

            // Get effective colors (swap if selected for highlight effect)
            var start_fg = start_cell.attr.effectiveFg();
            var start_bg = start_cell.attr.effectiveBg();
            if (start_selected) {
                const tmp = start_fg;
                start_fg = start_bg;
                start_bg = tmp;
            }

            const start_underline = start_cell.attr.underline;
            const start_strikethrough = start_cell.attr.strikethrough;
            const start_overline = start_cell.attr.overline;

            // Clear and reuse the glyph buffer (avoids per-run allocation)
            self.glyph_buffer.clearRetainingCapacity();

            while (col < self.scr.cols) {
                // Use getVisibleCell to support scrollback viewing
                const cell = self.scr.getVisibleCell(col, row);

                // Skip continuation cells
                if (cell.width == 0) {
                    col += 1;
                    continue;
                }

                // Check selection state
                const selected = self.scr.isCellSelected(col, row);

                // Get effective colors (swap if selected)
                var fg = cell.attr.effectiveFg();
                var bg = cell.attr.effectiveBg();
                if (selected) {
                    const tmp = fg;
                    fg = bg;
                    bg = tmp;
                }

                // Check if attributes match (including text decorations and selection state)
                if (!colorEqual(fg, start_fg) or !colorEqual(bg, start_bg) or
                    cell.attr.underline != start_underline or
                    cell.attr.strikethrough != start_strikethrough or
                    cell.attr.overline != start_overline or
                    selected != start_selected)
                {
                    break;
                }

                // Skip spaces with default background (optimization)
                if (cell.char != ' ' or !colorEqual(bg, screen.Color.default_bg)) {
                    // Use cached glyph index from cell (computed once when character was written)
                    try self.glyph_buffer.append(self.allocator, .{
                        .index = cell.glyph_idx,
                        .x_offset = @floatFromInt((col - start_col) * font.Font.GLYPH_WIDTH),
                        .y_offset = 0,
                    });
                }

                col += 1;
            }

            if (self.glyph_buffer.items.len == 0) continue;

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
                self.glyph_buffer.items,
                self.atlas,
            );

            // Draw text decorations
            const x1: f32 = @floatFromInt(start_col * font.Font.GLYPH_WIDTH);
            const x2: f32 = @floatFromInt(col * font.Font.GLYPH_WIDTH);
            const row_y: f32 = @floatFromInt(row * font.Font.GLYPH_HEIGHT);
            const dec_r = @as(f32, @floatFromInt(fg_rgb.r)) / 255.0;
            const dec_g = @as(f32, @floatFromInt(fg_rgb.g)) / 255.0;
            const dec_b = @as(f32, @floatFromInt(fg_rgb.b)) / 255.0;

            // Line thickness (1 pixel for decorations)
            const line_thickness: f32 = 1.0;

            // Underline: draw at bottom of cell
            if (start_underline != .none) {
                const underline_y = row_y + @as(f32, @floatFromInt(font.Font.GLYPH_HEIGHT)) - 1.0;
                try self.encoder.strokeLine(x1, underline_y, x2, underline_y, line_thickness, dec_r, dec_g, dec_b, 1.0);

                // Double underline: draw second line 2 pixels above
                if (start_underline == .double) {
                    const underline_y2 = underline_y - 2.0;
                    try self.encoder.strokeLine(x1, underline_y2, x2, underline_y2, line_thickness, dec_r, dec_g, dec_b, 1.0);
                }
            }

            // Strikethrough: draw at middle of cell
            if (start_strikethrough) {
                const strike_y = row_y + @as(f32, @floatFromInt(font.Font.GLYPH_HEIGHT)) / 2.0;
                try self.encoder.strokeLine(x1, strike_y, x2, strike_y, line_thickness, dec_r, dec_g, dec_b, 1.0);
            }

            // Overline: draw at top of cell
            if (start_overline) {
                const overline_y = row_y + 1.0;
                try self.encoder.strokeLine(x1, overline_y, x2, overline_y, line_thickness, dec_r, dec_g, dec_b, 1.0);
            }
        }
    }

    fn renderCursor(self: *Self) !void {
        const cursor_x: f32 = @floatFromInt(self.scr.cursor_col * font.Font.GLYPH_WIDTH);
        const cursor_y: f32 = @floatFromInt(self.scr.cursor_row * font.Font.GLYPH_HEIGHT);
        const glyph_w: f32 = @floatFromInt(font.Font.GLYPH_WIDTH);
        const glyph_h: f32 = @floatFromInt(font.Font.GLYPH_HEIGHT);

        // Cursor color (semi-transparent white)
        const r: f32 = 0.7;
        const g: f32 = 0.7;
        const b: f32 = 0.7;
        const a: f32 = 0.8;

        // Draw cursor based on style
        switch (self.scr.getCursorShape()) {
            .block => {
                // Full block cursor
                try self.encoder.fillRect(cursor_x, cursor_y, glyph_w, glyph_h, r, g, b, a);
            },
            .underline => {
                // Underline cursor: thin line at bottom of cell (2 pixels high)
                const underline_height: f32 = 2.0;
                const underline_y = cursor_y + glyph_h - underline_height;
                try self.encoder.fillRect(cursor_x, underline_y, glyph_w, underline_height, r, g, b, a);
            },
            .bar => {
                // Bar/beam cursor: thin vertical line on left side (2 pixels wide)
                const bar_width: f32 = 2.0;
                try self.encoder.fillRect(cursor_x, cursor_y, bar_width, glyph_h, r, g, b, a);
            },
        }
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

    /// Render a chord menu overlay
    pub fn renderChordMenu(
        self: *Self,
        menu_x: i32,
        menu_y: i32,
        menu_width: u32,
        menu_height: u32,
        item_height: u32,
        labels: []const []const u8,
        selected_idx: ?usize,
    ) !void {
        const x: f32 = @floatFromInt(menu_x);
        const y: f32 = @floatFromInt(menu_y);
        const w: f32 = @floatFromInt(menu_width);
        const h: f32 = @floatFromInt(menu_height);

        // Draw menu background (dark gray with border)
        try self.encoder.fillRect(x, y, w, h, 0.2, 0.2, 0.25, 0.95);

        // Draw border
        try self.encoder.strokeLine(x, y, x + w, y, 1.0, 0.5, 0.5, 0.5, 1.0); // Top
        try self.encoder.strokeLine(x, y + h, x + w, y + h, 1.0, 0.5, 0.5, 0.5, 1.0); // Bottom
        try self.encoder.strokeLine(x, y, x, y + h, 1.0, 0.5, 0.5, 0.5, 1.0); // Left
        try self.encoder.strokeLine(x + w, y, x + w, y + h, 1.0, 0.5, 0.5, 0.5, 1.0); // Right

        // Draw each menu item
        const ih: f32 = @floatFromInt(item_height);
        for (labels, 0..) |label, i| {
            const item_y = y + 2 + @as(f32, @floatFromInt(i)) * ih;

            // Draw highlight for selected item
            if (selected_idx) |sel| {
                if (sel == i) {
                    try self.encoder.fillRect(x + 2, item_y, w - 4, ih, 0.3, 0.5, 0.7, 0.9);
                }
            }

            // Draw text - build glyph run for the label
            self.glyph_buffer.clearRetainingCapacity();
            for (label, 0..) |char, ci| {
                const glyph_idx = font.Font.getGlyphIndex(char);
                try self.glyph_buffer.append(self.allocator, .{
                    .index = glyph_idx,
                    .x_offset = @floatFromInt(ci * font.Font.GLYPH_WIDTH),
                    .y_offset = 0,
                });
            }

            // Draw the text (white)
            const text_y = item_y + 2;
            try self.encoder.drawGlyphRun(
                x + 4,
                text_y,
                1.0,
                1.0,
                1.0,
                1.0, // White text
                font.Font.GLYPH_WIDTH,
                font.Font.GLYPH_HEIGHT,
                font.Font.ATLAS_COLS,
                font.Font.ATLAS_WIDTH,
                font.Font.ATLAS_HEIGHT,
                self.glyph_buffer.items,
                self.atlas,
            );
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
