const std = @import("std");
const backend = @import("backend");
const posix = std.posix;

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-client-protocol.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("linux/input-event-codes.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

const log = std.log.scoped(.wayland_backend);

/// Wayland backend for windowed display
pub const WaylandBackend = struct {
    allocator: std.mem.Allocator,

    // Wayland core objects
    display: ?*c.wl_display,
    registry: ?*c.wl_registry,
    compositor: ?*c.wl_compositor,
    shm: ?*c.wl_shm,
    seat: ?*c.wl_seat,
    keyboard: ?*c.wl_keyboard,

    // XDG shell objects
    xdg_wm_base: ?*c.xdg_wm_base,
    xdg_surface: ?*c.xdg_surface,
    xdg_toplevel: ?*c.xdg_toplevel,

    // Surface and buffer
    surface: ?*c.wl_surface,
    buffer: ?*c.wl_buffer,
    shm_data: ?[*]u8,
    shm_size: usize,
    shm_fd: c_int,

    // State
    width: u32,
    height: u32,
    configured: bool,
    closed: bool,
    frame_count: u64,
    ctrl_held: bool,

    // Supported format
    shm_format: u32,
    format_found: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .display = null,
            .registry = null,
            .compositor = null,
            .shm = null,
            .seat = null,
            .keyboard = null,
            .xdg_wm_base = null,
            .xdg_surface = null,
            .xdg_toplevel = null,
            .surface = null,
            .buffer = null,
            .shm_data = null,
            .shm_size = 0,
            .shm_fd = -1,
            .width = 1920,
            .height = 1080,
            .configured = false,
            .closed = false,
            .frame_count = 0,
            .ctrl_held = false,
            .shm_format = c.WL_SHM_FORMAT_ARGB8888,
            .format_found = false,
        };

        // Connect to Wayland display
        self.display = c.wl_display_connect(null);
        if (self.display == null) {
            log.err("failed to connect to Wayland display", .{});
            return error.WaylandConnectionFailed;
        }
        errdefer self.disconnectDisplay();

        // Get registry
        self.registry = c.wl_display_get_registry(self.display);
        if (self.registry == null) {
            return error.WaylandRegistryFailed;
        }

        // Add registry listener
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);

        // Roundtrip to get globals
        _ = c.wl_display_roundtrip(self.display);

        // Verify we have required globals
        if (self.compositor == null) {
            log.err("wl_compositor not available", .{});
            return error.WaylandMissingGlobal;
        }
        if (self.shm == null) {
            log.err("wl_shm not available", .{});
            return error.WaylandMissingGlobal;
        }
        if (self.xdg_wm_base == null) {
            log.err("xdg_wm_base not available", .{});
            return error.WaylandMissingGlobal;
        }

        // Add shm listener to find supported formats
        _ = c.wl_shm_add_listener(self.shm, &shm_listener, self);
        _ = c.wl_display_roundtrip(self.display);

        // Create surface
        self.surface = c.wl_compositor_create_surface(self.compositor);
        if (self.surface == null) {
            return error.WaylandSurfaceCreationFailed;
        }

        // Create XDG surface
        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.xdg_wm_base, self.surface);
        if (self.xdg_surface == null) {
            return error.XdgSurfaceCreationFailed;
        }
        _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);

        // Create toplevel
        self.xdg_toplevel = c.xdg_surface_get_toplevel(self.xdg_surface);
        if (self.xdg_toplevel == null) {
            return error.XdgToplevelCreationFailed;
        }
        _ = c.xdg_toplevel_add_listener(self.xdg_toplevel, &xdg_toplevel_listener, self);

        c.xdg_toplevel_set_title(self.xdg_toplevel, "SemaDraw (Wayland)");
        c.xdg_toplevel_set_app_id(self.xdg_toplevel, "semadraw");

        // Commit surface to trigger configure
        c.wl_surface_commit(self.surface);

        // Wait for configure
        while (!self.configured and !self.closed) {
            if (c.wl_display_dispatch(self.display) < 0) {
                return error.WaylandDispatchFailed;
            }
        }

        // Create initial buffer
        try self.createBuffer(self.width, self.height);

        log.info("Wayland backend initialized: {}x{}", .{ self.width, self.height });

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.destroyBuffer();

        if (self.xdg_toplevel != null) {
            c.xdg_toplevel_destroy(self.xdg_toplevel);
        }
        if (self.xdg_surface != null) {
            c.xdg_surface_destroy(self.xdg_surface);
        }
        if (self.surface != null) {
            c.wl_surface_destroy(self.surface);
        }
        if (self.keyboard != null) {
            c.wl_keyboard_destroy(self.keyboard);
        }
        if (self.seat != null) {
            c.wl_seat_destroy(self.seat);
        }
        if (self.xdg_wm_base != null) {
            c.xdg_wm_base_destroy(self.xdg_wm_base);
        }
        if (self.shm != null) {
            c.wl_shm_destroy(self.shm);
        }
        if (self.compositor != null) {
            c.wl_compositor_destroy(self.compositor);
        }
        if (self.registry != null) {
            c.wl_registry_destroy(self.registry);
        }

        self.disconnectDisplay();
        self.allocator.destroy(self);
    }

    fn disconnectDisplay(self: *Self) void {
        if (self.display != null) {
            c.wl_display_disconnect(self.display);
            self.display = null;
        }
    }

    fn createBuffer(self: *Self, width: u32, height: u32) !void {
        self.destroyBuffer();

        const stride = width * 4;
        const size = stride * height;

        // Create shared memory file
        const name = "/semadraw-shm";
        const fd = c.shm_open(name, c.O_RDWR | c.O_CREAT | c.O_EXCL, 0o600);
        if (fd < 0) {
            // Try with unique name
            return error.ShmOpenFailed;
        }
        _ = c.shm_unlink(name);

        if (c.ftruncate(fd, @intCast(size)) < 0) {
            _ = c.close(fd);
            return error.FtruncateFailed;
        }

        const data = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (data == c.MAP_FAILED) {
            _ = c.close(fd);
            return error.MmapFailed;
        }

        self.shm_data = @ptrCast(data);
        self.shm_size = size;
        self.shm_fd = fd;

        // Create wl_shm_pool and buffer
        const pool = c.wl_shm_create_pool(self.shm, fd, @intCast(size));
        if (pool == null) {
            return error.ShmPoolCreationFailed;
        }
        defer c.wl_shm_pool_destroy(pool);

        self.buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            self.shm_format,
        );
        if (self.buffer == null) {
            return error.BufferCreationFailed;
        }

        self.width = width;
        self.height = height;

        // Clear buffer
        @memset(self.shm_data.?[0..size], 0);
    }

    fn destroyBuffer(self: *Self) void {
        if (self.buffer != null) {
            c.wl_buffer_destroy(self.buffer);
            self.buffer = null;
        }
        if (self.shm_data != null) {
            _ = c.munmap(self.shm_data, self.shm_size);
            self.shm_data = null;
        }
        if (self.shm_fd >= 0) {
            _ = c.close(self.shm_fd);
            self.shm_fd = -1;
        }
    }

    fn present(self: *Self) void {
        if (self.buffer == null or self.surface == null) return;

        c.wl_surface_attach(self.surface, self.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.surface, 0, 0, @intCast(self.width), @intCast(self.height));
        c.wl_surface_commit(self.surface);
    }

    fn processEvents(self: *Self) bool {
        if (self.display == null) return !self.closed;

        // Non-blocking dispatch
        while (c.wl_display_prepare_read(self.display) != 0) {
            _ = c.wl_display_dispatch_pending(self.display);
        }

        if (c.wl_display_flush(self.display) < 0) {
            c.wl_display_cancel_read(self.display);
            return false;
        }

        // Check for events with zero timeout
        var pfd = posix.pollfd{
            .fd = c.wl_display_get_fd(self.display),
            .events = posix.POLL.IN,
            .revents = 0,
        };

        const ready = posix.poll(@as(*[1]posix.pollfd, &pfd), 0) catch 0;
        if (ready > 0) {
            _ = c.wl_display_read_events(self.display);
            _ = c.wl_display_dispatch_pending(self.display);
        } else {
            c.wl_display_cancel_read(self.display);
        }

        return !self.closed;
    }

    // ========================================================================
    // Wayland listeners
    // ========================================================================

    const registry_listener = c.wl_registry_listener{
        .global = registryGlobal,
        .global_remove = registryGlobalRemove,
    };

    fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*:0]const u8, version: u32) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data));
        _ = version;

        const iface = std.mem.span(interface);

        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.xdg_wm_base = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1));
            _ = c.xdg_wm_base_add_listener(self.xdg_wm_base, &xdg_wm_base_listener, self);
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1));
            _ = c.wl_seat_add_listener(self.seat, &seat_listener, self);
        }
    }

    fn registryGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.C) void {}

    const shm_listener = c.wl_shm_listener{
        .format = shmFormat,
    };

    fn shmFormat(data: ?*anyopaque, _: ?*c.wl_shm, format: u32) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data));
        if (format == c.WL_SHM_FORMAT_ARGB8888 or format == c.WL_SHM_FORMAT_XRGB8888) {
            self.shm_format = format;
            self.format_found = true;
        }
    }

    const xdg_wm_base_listener = c.xdg_wm_base_listener{
        .ping = xdgWmBasePing,
    };

    fn xdgWmBasePing(_: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.C) void {
        c.xdg_wm_base_pong(wm_base, serial);
    }

    const xdg_surface_listener = c.xdg_surface_listener{
        .configure = xdgSurfaceConfigure,
    };

    fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data));
        c.xdg_surface_ack_configure(xdg_surface, serial);
        self.configured = true;
    }

    const xdg_toplevel_listener = c.xdg_toplevel_listener{
        .configure = xdgToplevelConfigure,
        .close = xdgToplevelClose,
        .configure_bounds = null,
        .wm_capabilities = null,
    };

    fn xdgToplevelConfigure(data: ?*anyopaque, _: ?*c.xdg_toplevel, width: i32, height: i32, _: ?*c.wl_array) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data));
        if (width > 0 and height > 0) {
            if (@as(u32, @intCast(width)) != self.width or @as(u32, @intCast(height)) != self.height) {
                log.info("resize: {}x{} -> {}x{}", .{ self.width, self.height, width, height });
                self.createBuffer(@intCast(width), @intCast(height)) catch |err| {
                    log.err("failed to resize buffer: {}", .{err});
                };
            }
        }
    }

    fn xdgToplevelClose(data: ?*anyopaque, _: ?*c.xdg_toplevel) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data));
        log.info("window close requested", .{});
        self.closed = true;
    }

    const seat_listener = c.wl_seat_listener{
        .capabilities = seatCapabilities,
        .name = null,
    };

    fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data));

        if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0) {
            if (self.keyboard == null) {
                self.keyboard = c.wl_seat_get_keyboard(seat);
                _ = c.wl_keyboard_add_listener(self.keyboard, &keyboard_listener, self);
            }
        } else {
            if (self.keyboard != null) {
                c.wl_keyboard_destroy(self.keyboard);
                self.keyboard = null;
            }
        }
    }

    const keyboard_listener = c.wl_keyboard_listener{
        .keymap = keyboardKeymap,
        .enter = keyboardEnter,
        .leave = keyboardLeave,
        .key = keyboardKey,
        .modifiers = keyboardModifiers,
        .repeat_info = null,
    };

    fn keyboardKeymap(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: i32, _: u32) callconv(.C) void {}
    fn keyboardEnter(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, _: ?*c.wl_array) callconv(.C) void {}
    fn keyboardLeave(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.C) void {}

    fn keyboardKey(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data));

        // Key pressed
        if (state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
            // KEY_Q = 16
            if (key == 16 and self.ctrl_held) {
                log.info("Ctrl+Q pressed, closing window", .{});
                self.closed = true;
            }
        }
    }

    fn keyboardModifiers(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, mods_depressed: u32, _: u32, _: u32, _: u32) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data));
        // Check for Ctrl (bit 2 in typical xkb layouts)
        self.ctrl_held = (mods_depressed & 4) != 0;
    }

    // ========================================================================
    // Backend interface
    // ========================================================================

    fn getCapabilitiesImpl(_: *anyopaque) backend.Capabilities {
        return .{
            .name = "wayland",
            .max_width = 8192,
            .max_height = 8192,
            .supports_aa = true,
            .hardware_accelerated = false,
            .can_present = true,
        };
    }

    fn initFramebufferImpl(ctx: *anyopaque, config: backend.FramebufferConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (config.width != self.width or config.height != self.height) {
            try self.createBuffer(config.width, config.height);
        }
    }

    fn renderImpl(ctx: *anyopaque, request: backend.RenderRequest) anyerror!backend.RenderResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const start_time = std.time.nanoTimestamp();

        if (!self.processEvents()) {
            return backend.RenderResult.failure(request.surface_id, "window closed");
        }

        const fb = self.shm_data orelse {
            return backend.RenderResult.failure(request.surface_id, "no framebuffer");
        };

        // Clear if requested (ARGB format)
        if (request.clear_color) |color| {
            const a: u8 = @intFromFloat(@min(255.0, @max(0.0, color[3] * 255.0)));
            const r: u8 = @intFromFloat(@min(255.0, @max(0.0, color[0] * 255.0)));
            const g: u8 = @intFromFloat(@min(255.0, @max(0.0, color[1] * 255.0)));
            const b: u8 = @intFromFloat(@min(255.0, @max(0.0, color[2] * 255.0)));

            const pixel: u32 = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);

            const pixels: [*]u32 = @ptrCast(@alignCast(fb));
            const count = self.width * self.height;
            for (0..count) |i| {
                pixels[i] = pixel;
            }
        }

        // TODO: Parse and render SDCS commands
        _ = request.sdcs_data;

        // Present
        self.present();

        self.frame_count += 1;
        const end_time = std.time.nanoTimestamp();

        return backend.RenderResult.success(
            request.surface_id,
            self.frame_count,
            @intCast(end_time - start_time),
        );
    }

    fn getPixelsImpl(ctx: *anyopaque) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.shm_data) |data| {
            return data[0..self.shm_size];
        }
        return null;
    }

    fn resizeImpl(ctx: *anyopaque, width: u32, height: u32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.createBuffer(width, height);
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

/// Create a Wayland backend
pub fn create(allocator: std.mem.Allocator) !backend.Backend {
    const wl = try WaylandBackend.init(allocator);
    return wl.toBackend();
}
