const std = @import("std");
const posix = std.posix;
const backend = @import("backend");

const log = std.log.scoped(.x11_backend);

// ============================================================================
// X11 C Bindings
// ============================================================================

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
});

const Display = *c.Display;
const Window = c.Window;
const GC = c.GC;
const XImage = *c.XImage;
const Atom = c.Atom;
const Visual = *c.Visual;

// ============================================================================
// X11 Backend Implementation
// ============================================================================

/// X11 Backend for windowed display output
pub const X11Backend = struct {
    allocator: std.mem.Allocator,
    display: ?Display,
    screen: c_int,
    window: Window,
    gc: GC,
    ximage: ?XImage,
    visual: ?Visual,
    depth: c_int,
    width: u32,
    height: u32,
    framebuffer: ?[]u8,
    wm_delete_window: Atom,
    frame_count: u64,
    closed: bool,

    const Self = @This();

    /// Initialize X11 backend with a new window
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, title: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .display = null,
            .screen = 0,
            .window = 0,
            .gc = null,
            .ximage = null,
            .visual = null,
            .depth = 0,
            .width = width,
            .height = height,
            .framebuffer = null,
            .wm_delete_window = 0,
            .frame_count = 0,
            .closed = false,
        };

        // Open display
        self.display = c.XOpenDisplay(null);
        if (self.display == null) {
            log.err("failed to open X display", .{});
            return error.DisplayOpenFailed;
        }
        errdefer _ = c.XCloseDisplay(self.display.?);

        self.screen = c.DefaultScreen(self.display.?);
        self.depth = c.DefaultDepth(self.display.?, self.screen);
        self.visual = c.DefaultVisual(self.display.?, self.screen);

        // Create window
        const root = c.RootWindow(self.display.?, self.screen);
        self.window = c.XCreateSimpleWindow(
            self.display.?,
            root,
            0,
            0,
            width,
            height,
            1,
            c.BlackPixel(self.display.?, self.screen),
            c.WhitePixel(self.display.?, self.screen),
        );

        if (self.window == 0) {
            log.err("failed to create window", .{});
            return error.WindowCreateFailed;
        }
        errdefer _ = c.XDestroyWindow(self.display.?, self.window);

        // Set window title
        var title_buf: [256]u8 = undefined;
        const title_len = @min(title.len, title_buf.len - 1);
        @memcpy(title_buf[0..title_len], title[0..title_len]);
        title_buf[title_len] = 0;
        _ = c.XStoreName(self.display.?, self.window, &title_buf);

        // Set up window close handling
        self.wm_delete_window = c.XInternAtom(self.display.?, "WM_DELETE_WINDOW", c.False);
        _ = c.XSetWMProtocols(self.display.?, self.window, &self.wm_delete_window, 1);

        // Select input events
        _ = c.XSelectInput(self.display.?, self.window, c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask);

        // Create graphics context
        self.gc = c.XCreateGC(self.display.?, self.window, 0, null);

        // Allocate framebuffer (BGRA format for X11)
        const fb_size = @as(usize, width) * @as(usize, height) * 4;
        self.framebuffer = try allocator.alloc(u8, fb_size);
        @memset(self.framebuffer.?, 0);

        // Create XImage
        self.ximage = c.XCreateImage(
            self.display.?,
            self.visual.?,
            @intCast(self.depth),
            c.ZPixmap,
            0,
            @ptrCast(self.framebuffer.?.ptr),
            width,
            height,
            32,
            0,
        );

        if (self.ximage == null) {
            log.err("failed to create XImage", .{});
            return error.XImageCreateFailed;
        }

        // Map window
        _ = c.XMapWindow(self.display.?, self.window);
        _ = c.XFlush(self.display.?);

        log.info("X11 window created: {}x{}", .{ width, height });

        return self;
    }

    /// Initialize with default size and title
    pub fn initDefault(allocator: std.mem.Allocator) !*Self {
        return init(allocator, 1280, 720, "SemaDraw");
    }

    pub fn deinit(self: *Self) void {
        if (self.ximage) |img| {
            // Don't free the data - XImage doesn't own it
            img.*.data = null;
            // Call the destroy function directly (XDestroyImage is a macro)
            if (img.*.f.destroy_image) |destroy_fn| {
                _ = destroy_fn(img);
            }
        }

        if (self.framebuffer) |fb| {
            self.allocator.free(fb);
        }

        if (self.display) |disp| {
            if (self.gc != null) {
                _ = c.XFreeGC(disp, self.gc);
            }
            if (self.window != 0) {
                _ = c.XDestroyWindow(disp, self.window);
            }
            _ = c.XCloseDisplay(disp);
        }

        self.allocator.destroy(self);
    }

    /// Present framebuffer to window
    pub fn present(self: *Self) void {
        if (self.display == null or self.ximage == null or self.closed) return;

        _ = c.XPutImage(
            self.display.?,
            self.window,
            self.gc,
            self.ximage.?,
            0,
            0,
            0,
            0,
            self.width,
            self.height,
        );
        _ = c.XFlush(self.display.?);
        self.frame_count += 1;
    }

    /// Process pending X11 events
    pub fn processEvents(self: *Self) bool {
        if (self.display == null) return false;

        while (c.XPending(self.display.?) > 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(self.display.?, &event);

            switch (event.type) {
                c.Expose => {
                    self.present();
                },
                c.ConfigureNotify => {
                    const configure = event.xconfigure;
                    if (configure.width != self.width or configure.height != self.height) {
                        self.handleResize(@intCast(configure.width), @intCast(configure.height)) catch |err| {
                            log.err("resize failed: {}", .{err});
                        };
                    }
                },
                c.ClientMessage => {
                    const client_msg = event.xclient;
                    if (@as(Atom, @intCast(client_msg.data.l[0])) == self.wm_delete_window) {
                        log.info("window close requested", .{});
                        self.closed = true;
                        return false;
                    }
                },
                c.KeyPress => {
                    const key_event = event.xkey;
                    const keysym = c.XLookupKeysym(@constCast(&key_event), 0);
                    // Ctrl+Q to quit (less likely to conflict with applications)
                    const ctrl_held = (key_event.state & c.ControlMask) != 0;
                    if (ctrl_held and (keysym == c.XK_q or keysym == c.XK_Q)) {
                        log.info("Ctrl+Q pressed, closing window", .{});
                        self.closed = true;
                        return false;
                    }
                },
                else => {},
            }
        }

        return !self.closed;
    }

    fn handleResize(self: *Self, new_width: u32, new_height: u32) !void {
        if (new_width == self.width and new_height == self.height) return;

        log.info("resizing: {}x{} -> {}x{}", .{ self.width, self.height, new_width, new_height });

        // Destroy old XImage (but not the data)
        if (self.ximage) |img| {
            img.*.data = null;
            // Call the destroy function directly (XDestroyImage is a macro)
            if (img.*.f.destroy_image) |destroy_fn| {
                _ = destroy_fn(img);
            }
            self.ximage = null;
        }

        // Free old framebuffer
        if (self.framebuffer) |fb| {
            self.allocator.free(fb);
        }

        // Allocate new framebuffer
        const fb_size = @as(usize, new_width) * @as(usize, new_height) * 4;
        self.framebuffer = try self.allocator.alloc(u8, fb_size);
        @memset(self.framebuffer.?, 0);

        self.width = new_width;
        self.height = new_height;

        // Create new XImage
        self.ximage = c.XCreateImage(
            self.display.?,
            self.visual.?,
            @intCast(self.depth),
            c.ZPixmap,
            0,
            @ptrCast(self.framebuffer.?.ptr),
            new_width,
            new_height,
            32,
            0,
        );
    }

    /// Get framebuffer pointer for rendering
    pub fn getFramebuffer(self: *Self) ?[]u8 {
        return self.framebuffer;
    }

    // ========================================================================
    // SDCS Command Execution
    // ========================================================================

    fn executeSdcs(self: *Self, fb: []u8, data: []const u8) !void {
        if (data.len < 64) return error.InvalidSdcs; // Header too small

        // Skip header (64 bytes)
        var offset: usize = 64;

        // Process chunks
        while (offset + 32 <= data.len) {
            // ChunkHeader is 32 bytes
            const chunk_payload_bytes = std.mem.readInt(u64, data[offset + 24 ..][0..8], .little);
            offset += 32;

            if (offset + chunk_payload_bytes > data.len) break;

            // Process commands in chunk
            const chunk_end = offset + @as(usize, @intCast(chunk_payload_bytes));
            try self.executeChunkCommands(fb, data[offset..chunk_end]);

            // Align to 8 bytes for next chunk
            offset = chunk_end;
            offset = std.mem.alignForward(usize, offset, 8);
        }
    }

    fn executeChunkCommands(self: *Self, fb: []u8, commands: []const u8) !void {
        var offset: usize = 0;

        while (offset + 8 <= commands.len) {
            const opcode = std.mem.readInt(u16, commands[offset..][0..2], .little);
            const payload_len = std.mem.readInt(u32, commands[offset + 4 ..][0..4], .little);
            offset += 8;

            if (offset + payload_len > commands.len) break;

            const payload = commands[offset..][0..payload_len];

            // Execute command
            try self.executeCommand(fb, opcode, payload);

            // Align to 8 bytes
            offset += payload_len;
            const record_bytes = 8 + payload_len;
            const pad = (8 - (record_bytes % 8)) % 8;
            offset += pad;

            // Check for END
            if (opcode == 0x00F0) break;
        }
    }

    fn executeCommand(self: *Self, fb: []u8, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            0x0001 => {}, // RESET - no-op for now
            0x0004 => {}, // SET_BLEND - ignored for now (always SRC_OVER)
            0x0010 => { // FILL_RECT
                if (payload.len >= 32) {
                    const x = readF32(payload[0..4]);
                    const y = readF32(payload[4..8]);
                    const w = readF32(payload[8..12]);
                    const h = readF32(payload[12..16]);
                    const r = readF32(payload[16..20]);
                    const g = readF32(payload[20..24]);
                    const b_col = readF32(payload[24..28]);
                    const a = readF32(payload[28..32]);

                    self.fillRect(fb, x, y, w, h, r, g, b_col, a);
                }
            },
            0x0030 => { // DRAW_GLYPH_RUN
                if (payload.len >= 48) {
                    self.drawGlyphRun(fb, payload);
                }
            },
            0x00F0 => {}, // END
            else => {}, // Ignore unknown opcodes for now
        }
    }

    fn drawGlyphRun(self: *Self, fb: []u8, payload: []const u8) void {
        // Parse header (48 bytes)
        const base_x = readF32(payload[0..4]);
        const base_y = readF32(payload[4..8]);
        const r = readF32(payload[8..12]);
        const g = readF32(payload[12..16]);
        const b_col = readF32(payload[16..20]);
        const a = readF32(payload[20..24]);
        const cell_width = std.mem.readInt(u32, payload[24..28], .little);
        const cell_height = std.mem.readInt(u32, payload[28..32], .little);
        const atlas_cols = std.mem.readInt(u32, payload[32..36], .little);
        const atlas_width = std.mem.readInt(u32, payload[36..40], .little);
        const atlas_height = std.mem.readInt(u32, payload[40..44], .little);
        const glyph_count = std.mem.readInt(u32, payload[44..48], .little);

        if (cell_width == 0 or cell_height == 0 or atlas_cols == 0) return;

        // Calculate offsets
        const glyphs_offset: usize = 48;
        const glyphs_size = glyph_count * 12; // 12 bytes per glyph
        const atlas_offset = glyphs_offset + glyphs_size;
        const atlas_size = @as(usize, atlas_width) * @as(usize, atlas_height);

        if (payload.len < atlas_offset + atlas_size) return;

        const atlas_data = payload[atlas_offset..][0..atlas_size];

        // Color components (X11 BGRA format)
        const cr: u8 = clampU8(r);
        const cg: u8 = clampU8(g);
        const cb: u8 = clampU8(b_col);

        // Render each glyph
        var i: u32 = 0;
        while (i < glyph_count) : (i += 1) {
            const glyph_off = glyphs_offset + i * 12;
            if (glyph_off + 12 > payload.len) break;

            const glyph_index = std.mem.readInt(u32, payload[glyph_off..][0..4], .little);
            const x_offset = readF32(payload[glyph_off + 4 ..][0..4]);
            const y_offset = readF32(payload[glyph_off + 8 ..][0..4]);

            // Calculate atlas position for this glyph
            const atlas_col = glyph_index % atlas_cols;
            const atlas_row = glyph_index / atlas_cols;
            const atlas_x = atlas_col * cell_width;
            const atlas_y = atlas_row * cell_height;

            // Render glyph pixels
            self.blitGlyph(
                fb,
                base_x + x_offset,
                base_y + y_offset,
                cell_width,
                cell_height,
                atlas_data,
                atlas_width,
                atlas_x,
                atlas_y,
                cr,
                cg,
                cb,
                a,
            );
        }
    }

    fn blitGlyph(
        self: *Self,
        fb: []u8,
        dst_x: f32,
        dst_y: f32,
        cell_w: u32,
        cell_h: u32,
        atlas: []const u8,
        atlas_w: u32,
        atlas_x: u32,
        atlas_y: u32,
        r: u8,
        g: u8,
        b: u8,
        base_alpha: f32,
    ) void {
        const fb_w = self.width;
        const fb_h = self.height;

        var cy: u32 = 0;
        while (cy < cell_h) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < cell_w) : (cx += 1) {
                const px: i32 = @as(i32, @intFromFloat(dst_x)) + @as(i32, @intCast(cx));
                const py: i32 = @as(i32, @intFromFloat(dst_y)) + @as(i32, @intCast(cy));

                if (px < 0 or py < 0) continue;
                if (px >= @as(i32, @intCast(fb_w)) or py >= @as(i32, @intCast(fb_h))) continue;

                // Get alpha from atlas
                const ax = atlas_x + cx;
                const ay = atlas_y + cy;
                if (ax >= atlas_w or ay * atlas_w + ax >= atlas.len) continue;

                const atlas_alpha = atlas[ay * atlas_w + ax];
                if (atlas_alpha == 0) continue;

                // Calculate final alpha
                const glyph_a: f32 = @as(f32, @floatFromInt(atlas_alpha)) / 255.0;
                const final_a: f32 = glyph_a * base_alpha;
                const ca: u8 = @intFromFloat(final_a * 255.0);

                if (ca == 0) continue;

                const fb_idx = (@as(usize, @intCast(py)) * @as(usize, fb_w) + @as(usize, @intCast(px))) * 4;
                if (fb_idx + 3 >= fb.len) continue;

                // BGRA blend
                if (ca == 255) {
                    fb[fb_idx + 0] = b;
                    fb[fb_idx + 1] = g;
                    fb[fb_idx + 2] = r;
                    fb[fb_idx + 3] = 255;
                } else {
                    const sa: f32 = final_a;
                    const da: f32 = @as(f32, @floatFromInt(fb[fb_idx + 3])) / 255.0;
                    const out_a = sa + da * (1.0 - sa);

                    if (out_a > 0) {
                        fb[fb_idx + 0] = blendChannel(b, fb[fb_idx + 0], sa, da, out_a);
                        fb[fb_idx + 1] = blendChannel(g, fb[fb_idx + 1], sa, da, out_a);
                        fb[fb_idx + 2] = blendChannel(r, fb[fb_idx + 2], sa, da, out_a);
                        fb[fb_idx + 3] = @intFromFloat(@min(255.0, out_a * 255.0));
                    }
                }
            }
        }
    }

    fn fillRect(self: *Self, fb: []u8, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b_col: f32, a: f32) void {
        const fb_w = self.width;
        const fb_h = self.height;

        // Clamp to framebuffer bounds
        const x0: i32 = @intFromFloat(@max(0, x));
        const y0: i32 = @intFromFloat(@max(0, y));
        const x1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(fb_w)), x + w));
        const y1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(fb_h)), y + h));

        if (x0 >= x1 or y0 >= y1) return;

        // X11 uses BGRA format
        const cb: u8 = clampU8(b_col);
        const cg: u8 = clampU8(g);
        const cr: u8 = clampU8(r);
        const ca: u8 = clampU8(a);

        const bytes_per_pixel: usize = 4; // BGRA

        var py: i32 = y0;
        while (py < y1) : (py += 1) {
            var px: i32 = x0;
            while (px < x1) : (px += 1) {
                const idx = (@as(usize, @intCast(py)) * @as(usize, fb_w) + @as(usize, @intCast(px))) * bytes_per_pixel;
                if (idx + 3 < fb.len) {
                    // Simple SRC_OVER blend (BGRA order for X11)
                    if (ca == 255) {
                        fb[idx + 0] = cb;
                        fb[idx + 1] = cg;
                        fb[idx + 2] = cr;
                        fb[idx + 3] = ca;
                    } else if (ca > 0) {
                        const sa: f32 = @as(f32, @floatFromInt(ca)) / 255.0;
                        const da: f32 = @as(f32, @floatFromInt(fb[idx + 3])) / 255.0;
                        const out_a = sa + da * (1.0 - sa);

                        if (out_a > 0) {
                            fb[idx + 0] = blendChannel(cb, fb[idx + 0], sa, da, out_a);
                            fb[idx + 1] = blendChannel(cg, fb[idx + 1], sa, da, out_a);
                            fb[idx + 2] = blendChannel(cr, fb[idx + 2], sa, da, out_a);
                            fb[idx + 3] = @intFromFloat(@min(255.0, out_a * 255.0));
                        }
                    }
                }
            }
        }
    }

    /// Check if window is still open
    pub fn isOpen(self: *Self) bool {
        return !self.closed;
    }

    // ========================================================================
    // Backend interface implementation
    // ========================================================================

    fn getCapabilitiesImpl(ctx: *anyopaque) backend.Capabilities {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .name = "X11",
            .max_width = self.width,
            .max_height = self.height,
            .supports_aa = true,
            .hardware_accelerated = false,
            .can_present = true,
        };
    }

    fn initFramebufferImpl(ctx: *anyopaque, config: backend.FramebufferConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (config.width != self.width or config.height != self.height) {
            try self.handleResize(config.width, config.height);
        }
    }

    fn renderImpl(ctx: *anyopaque, request: backend.RenderRequest) anyerror!backend.RenderResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const start = std.time.nanoTimestamp();

        // Process X11 events (keyboard, window close, etc.)
        if (!self.processEvents()) {
            return backend.RenderResult.failure(request.surface_id, "window closed");
        }

        const buffer = self.getFramebuffer() orelse {
            return backend.RenderResult.failure(request.surface_id, "no framebuffer");
        };

        // Clear if requested (X11 uses BGRA)
        if (request.clear_color) |color| {
            const b: u8 = @intFromFloat(color[2] * 255.0);
            const g: u8 = @intFromFloat(color[1] * 255.0);
            const r: u8 = @intFromFloat(color[0] * 255.0);
            const a: u8 = @intFromFloat(color[3] * 255.0);

            var i: usize = 0;
            while (i < buffer.len) : (i += 4) {
                buffer[i + 0] = b; // Blue
                buffer[i + 1] = g; // Green
                buffer[i + 2] = r; // Red
                buffer[i + 3] = a; // Alpha
            }
        }

        // Execute SDCS commands
        self.executeSdcs(buffer, request.sdcs_data) catch |err| {
            log.warn("SDCS execution failed: {}", .{err});
        };

        // Present to screen
        self.present();

        const end = std.time.nanoTimestamp();
        return backend.RenderResult.success(
            request.surface_id,
            self.frame_count,
            @intCast(end - start),
        );
    }

    fn getPixelsImpl(ctx: *anyopaque) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.getFramebuffer();
    }

    fn resizeImpl(ctx: *anyopaque, width: u32, height: u32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.handleResize(width, height);
    }

    fn pollEventsImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.processEvents();
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    pub const vtable = backend.Backend.VTable{
        .getCapabilities = getCapabilitiesImpl,
        .initFramebuffer = initFramebufferImpl,
        .render = renderImpl,
        .getPixels = getPixelsImpl,
        .resize = resizeImpl,
        .pollEvents = pollEventsImpl,
        .deinit = deinitImpl,
    };

    pub fn toBackend(self: *Self) backend.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Create X11 backend
pub fn create(allocator: std.mem.Allocator) !backend.Backend {
    const x11 = try X11Backend.initDefault(allocator);
    return x11.toBackend();
}

/// Create X11 backend with specific size
pub fn createWithSize(allocator: std.mem.Allocator, width: u32, height: u32, title: []const u8) !backend.Backend {
    const x11 = try X11Backend.init(allocator, width, height, title);
    return x11.toBackend();
}

// ============================================================================
// Helper functions
// ============================================================================

fn clampU8(v: f32) u8 {
    var x = v;
    if (x < 0.0) x = 0.0;
    if (x > 1.0) x = 1.0;
    return @intFromFloat(@round(x * 255.0));
}

fn readF32(bytes: *const [4]u8) f32 {
    const u = std.mem.readInt(u32, bytes, .little);
    return @bitCast(u);
}

fn blendChannel(src: u8, dst: u8, sa: f32, da: f32, out_a: f32) u8 {
    const s: f32 = @floatFromInt(src);
    const d: f32 = @floatFromInt(dst);
    const result = (s * sa + d * da * (1.0 - sa)) / out_a;
    return @intFromFloat(@min(255.0, @max(0.0, result)));
}

// ============================================================================
// Tests
// ============================================================================

test "X11Backend struct size" {
    try std.testing.expect(@sizeOf(X11Backend) > 0);
}
