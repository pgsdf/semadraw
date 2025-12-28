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

        // TODO: Execute SDCS commands
        _ = request.sdcs_data;

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
// Tests
// ============================================================================

test "X11Backend struct size" {
    try std.testing.expect(@sizeOf(X11Backend) > 0);
}
