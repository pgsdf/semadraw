const std = @import("std");
const posix = std.posix;
const backend = @import("backend");

const log = std.log.scoped(.drm_backend);

// ============================================================================
// Evdev input support
// ============================================================================

/// Linux input event structure (from linux/input.h)
const input_event = extern struct {
    time: extern struct {
        tv_sec: isize,
        tv_usec: isize,
    },
    type: u16,
    code: u16,
    value: i32,
};

/// Event types
const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_REL: u16 = 0x02;
const EV_ABS: u16 = 0x03;

/// Relative axis codes
const REL_X: u16 = 0x00;
const REL_Y: u16 = 0x01;
const REL_WHEEL: u16 = 0x08;
const REL_HWHEEL: u16 = 0x06;

/// Key codes for mouse buttons
const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;
const BTN_MIDDLE: u16 = 0x112;
const BTN_SIDE: u16 = 0x113;
const BTN_EXTRA: u16 = 0x114;

/// Modifier key codes
const KEY_LEFTSHIFT: u16 = 42;
const KEY_RIGHTSHIFT: u16 = 54;
const KEY_LEFTCTRL: u16 = 29;
const KEY_RIGHTCTRL: u16 = 97;
const KEY_LEFTALT: u16 = 56;
const KEY_RIGHTALT: u16 = 100;
const KEY_LEFTMETA: u16 = 125;
const KEY_RIGHTMETA: u16 = 126;

/// EVIOCGBIT ioctl for checking device capabilities
fn EVIOCGBIT(ev: u8, len: u13) u32 {
    // _IOC(_IOC_READ, 'E', 0x20 + ev, len)
    return 0x80000000 | (@as(u32, len) << 16) | (@as(u32, 'E') << 8) | (0x20 + @as(u32, ev));
}

/// Check if a bit is set in a byte array
fn testBit(bit: usize, array: []const u8) bool {
    const byte_idx = bit / 8;
    if (byte_idx >= array.len) return false;
    const bit_idx: u3 = @intCast(bit % 8);
    return (array[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

/// Input device types we care about
const InputDeviceType = enum {
    keyboard,
    mouse,
    unknown,
};

/// Maximum number of input devices to track
const MAX_INPUT_DEVICES = 8;

/// DRM ioctl commands
const DRM_IOCTL_BASE: u32 = 'd';

fn DRM_IO(nr: u8) u32 {
    return @as(u32, nr) << 8 | DRM_IOCTL_BASE;
}

fn DRM_IOWR(nr: u8, comptime T: type) u32 {
    return 0xC0000000 | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, nr) << 8) | DRM_IOCTL_BASE;
}

/// Wrapper for DRM ioctl calls that handles the type conversion
fn drm_ioctl(fd: posix.fd_t, request: u32, arg: usize) c_int {
    // Use std.os.linux.ioctl which accepts u32 request directly
    const linux = std.os.linux;
    const rc = linux.ioctl(@intCast(fd), request, arg);
    // Convert result - negative errno comes back as large positive
    const signed_rc: isize = @bitCast(rc);
    return @intCast(signed_rc);
}

const DRM_IOCTL_SET_MASTER = DRM_IO(0x1e);
const DRM_IOCTL_DROP_MASTER = DRM_IO(0x1f);
const DRM_IOCTL_MODE_GETRESOURCES = DRM_IOWR(0xA0, drm_mode_card_res);
const DRM_IOCTL_MODE_GETCONNECTOR = DRM_IOWR(0xA7, drm_mode_get_connector);
const DRM_IOCTL_MODE_GETENCODER = DRM_IOWR(0xA6, drm_mode_get_encoder);
const DRM_IOCTL_MODE_GETCRTC = DRM_IOWR(0xA1, drm_mode_crtc);
const DRM_IOCTL_MODE_SETCRTC = DRM_IOWR(0xA2, drm_mode_crtc);
const DRM_IOCTL_MODE_CREATE_DUMB = DRM_IOWR(0xB2, drm_mode_create_dumb);
const DRM_IOCTL_MODE_MAP_DUMB = DRM_IOWR(0xB3, drm_mode_map_dumb);
const DRM_IOCTL_MODE_DESTROY_DUMB = DRM_IOWR(0xB4, drm_mode_destroy_dumb);
const DRM_IOCTL_MODE_ADDFB = DRM_IOWR(0xAE, drm_mode_fb_cmd);
const DRM_IOCTL_MODE_RMFB = DRM_IOWR(0xAF, u32);
const DRM_IOCTL_MODE_PAGE_FLIP = DRM_IOWR(0xB0, drm_mode_page_flip);

/// DRM mode info structure
const drm_mode_modeinfo = extern struct {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type_: u32,
    name: [32]u8,
};

/// Card resources
const drm_mode_card_res = extern struct {
    fb_id_ptr: u64,
    crtc_id_ptr: u64,
    connector_id_ptr: u64,
    encoder_id_ptr: u64,
    count_fbs: u32,
    count_crtcs: u32,
    count_connectors: u32,
    count_encoders: u32,
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
};

/// Connector info
const drm_mode_get_connector = extern struct {
    encoders_ptr: u64,
    modes_ptr: u64,
    props_ptr: u64,
    prop_values_ptr: u64,
    count_modes: u32,
    count_props: u32,
    count_encoders: u32,
    encoder_id: u32,
    connector_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    connection: u32,
    mm_width: u32,
    mm_height: u32,
    subpixel: u32,
    pad: u32,
};

/// Encoder info
const drm_mode_get_encoder = extern struct {
    encoder_id: u32,
    encoder_type: u32,
    crtc_id: u32,
    possible_crtcs: u32,
    possible_clones: u32,
};

/// CRTC info
const drm_mode_crtc = extern struct {
    set_connectors_ptr: u64,
    count_connectors: u32,
    crtc_id: u32,
    fb_id: u32,
    x: u32,
    y: u32,
    gamma_size: u32,
    mode_valid: u32,
    mode: drm_mode_modeinfo,
};

/// Create dumb buffer
const drm_mode_create_dumb = extern struct {
    height: u32,
    width: u32,
    bpp: u32,
    flags: u32,
    handle: u32,
    pitch: u32,
    size: u64,
};

/// Map dumb buffer
const drm_mode_map_dumb = extern struct {
    handle: u32,
    pad: u32,
    offset: u64,
};

/// Destroy dumb buffer
const drm_mode_destroy_dumb = extern struct {
    handle: u32,
};

/// Framebuffer command
const drm_mode_fb_cmd = extern struct {
    fb_id: u32,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    depth: u32,
    handle: u32,
};

/// Page flip request
const drm_mode_page_flip = extern struct {
    crtc_id: u32,
    fb_id: u32,
    flags: u32,
    reserved: u32,
    user_data: u64,
};

const DRM_MODE_PAGE_FLIP_EVENT = 0x01;

/// Connection status
const DRM_MODE_CONNECTED = 1;
const DRM_MODE_DISCONNECTED = 2;
const DRM_MODE_UNKNOWNCONNECTION = 3;

/// Dumb buffer for double buffering
const DumbBuffer = struct {
    handle: u32,
    fb_id: u32,
    size: u64,
    pitch: u32,
    map: ?[]align(4096) u8,

    fn create(fd: posix.fd_t, width: u32, height: u32) !DumbBuffer {
        // Create dumb buffer
        var create_req = drm_mode_create_dumb{
            .width = width,
            .height = height,
            .bpp = 32,
            .flags = 0,
            .handle = 0,
            .pitch = 0,
            .size = 0,
        };

        const create_result = drm_ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, @intFromPtr(&create_req));
        if (create_result != 0) {
            return error.CreateDumbFailed;
        }

        // Add framebuffer
        var fb_cmd = drm_mode_fb_cmd{
            .fb_id = 0,
            .width = width,
            .height = height,
            .pitch = create_req.pitch,
            .bpp = 32,
            .depth = 24,
            .handle = create_req.handle,
        };

        const fb_result = drm_ioctl(fd, DRM_IOCTL_MODE_ADDFB, @intFromPtr(&fb_cmd));
        if (fb_result != 0) {
            // Clean up handle
            var destroy_dumb = drm_mode_destroy_dumb{ .handle = create_req.handle };
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy_dumb));
            return error.AddFbFailed;
        }

        // Map buffer
        var map_req = drm_mode_map_dumb{
            .handle = create_req.handle,
            .pad = 0,
            .offset = 0,
        };

        const map_result = drm_ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, @intFromPtr(&map_req));
        if (map_result != 0) {
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&fb_cmd.fb_id));
            var destroy_dumb = drm_mode_destroy_dumb{ .handle = create_req.handle };
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy_dumb));
            return error.MapDumbFailed;
        }

        const map_ptr = posix.mmap(
            null,
            @intCast(create_req.size),
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            @intCast(map_req.offset),
        ) catch {
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&fb_cmd.fb_id));
            var destroy_dumb = drm_mode_destroy_dumb{ .handle = create_req.handle };
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy_dumb));
            return error.MmapFailed;
        };

        return .{
            .handle = create_req.handle,
            .fb_id = fb_cmd.fb_id,
            .size = create_req.size,
            .pitch = create_req.pitch,
            .map = @as([*]align(4096) u8, @ptrCast(@alignCast(map_ptr)))[0..@intCast(create_req.size)],
        };
    }

    fn destroy(self: *DumbBuffer, fd: posix.fd_t) void {
        if (self.map) |m| {
            posix.munmap(m);
            self.map = null;
        }
        _ = drm_ioctl(fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&self.fb_id));
        var destroy_req = drm_mode_destroy_dumb{ .handle = self.handle };
        _ = drm_ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy_req));
    }
};

/// DRM/KMS Backend for direct display output
pub const DrmBackend = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    connector_id: u32,
    crtc_id: u32,
    mode: drm_mode_modeinfo,
    width: u32,
    height: u32,
    buffers: [2]?DumbBuffer,
    front_buffer: u8,
    frame_count: u64,
    saved_crtc: ?drm_mode_crtc,

    // Input device handling
    input_fds: [MAX_INPUT_DEVICES]posix.fd_t,
    input_types: [MAX_INPUT_DEVICES]InputDeviceType,
    input_count: usize,

    // Mouse state
    mouse_x: i32,
    mouse_y: i32,
    mouse_buttons: u8, // Bit flags: 0=left, 1=middle, 2=right

    // Modifier key state
    modifiers: u8, // Bit flags: 0=shift, 1=alt, 2=ctrl, 3=meta

    // Event queues
    key_events: [backend.MAX_KEY_EVENTS]backend.KeyEvent,
    key_event_count: usize,
    mouse_events: [backend.MAX_MOUSE_EVENTS]backend.MouseEvent,
    mouse_event_count: usize,

    const Self = @This();

    /// Open DRM device and set up display
    pub fn init(allocator: std.mem.Allocator, device_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .fd = -1,
            .connector_id = 0,
            .crtc_id = 0,
            .mode = undefined,
            .width = 0,
            .height = 0,
            .buffers = .{ null, null },
            .front_buffer = 0,
            .frame_count = 0,
            .saved_crtc = null,
            // Input initialization
            .input_fds = [_]posix.fd_t{-1} ** MAX_INPUT_DEVICES,
            .input_types = [_]InputDeviceType{.unknown} ** MAX_INPUT_DEVICES,
            .input_count = 0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_buttons = 0,
            .modifiers = 0,
            .key_events = undefined,
            .key_event_count = 0,
            .mouse_events = undefined,
            .mouse_event_count = 0,
        };

        // Open device
        self.fd = posix.open(device_path, .{ .ACCMODE = .RDWR }, 0) catch {
            return error.OpenFailed;
        };
        errdefer posix.close(self.fd);

        // Try to become master
        _ = drm_ioctl(self.fd, DRM_IOCTL_SET_MASTER, @as(usize, 0));

        // Get resources and find connector
        try self.findConnector();

        // Initialize input devices
        self.initInputDevices();

        return self;
    }

    /// Scan and open available input devices
    fn initInputDevices(self: *Self) void {
        // Scan /dev/input/event* for keyboards and mice
        var i: usize = 0;
        while (i < 32 and self.input_count < MAX_INPUT_DEVICES) : (i += 1) {
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/dev/input/event{}", .{i}) catch continue;
            // Null-terminate for open
            const path_z = path_buf[0..path.len];
            path_buf[path.len] = 0;

            const fd = posix.open(
                @ptrCast(path_z.ptr),
                .{ .ACCMODE = .RDONLY, .NONBLOCK = true },
                0,
            ) catch continue;

            const dev_type = self.detectInputDeviceType(fd);
            if (dev_type == .unknown) {
                posix.close(fd);
                continue;
            }

            self.input_fds[self.input_count] = fd;
            self.input_types[self.input_count] = dev_type;
            self.input_count += 1;

            log.info("opened input device /dev/input/event{} as {s}", .{
                i,
                @tagName(dev_type),
            });
        }

        if (self.input_count == 0) {
            log.warn("no input devices found - keyboard and mouse input disabled", .{});
            log.warn("ensure /dev/input/event* is readable (root or input group)", .{});
        }
    }

    /// Detect what type of input device this is
    fn detectInputDeviceType(self: *Self, fd: posix.fd_t) InputDeviceType {
        _ = self;
        const linux = std.os.linux;

        // Check for supported event types
        var ev_bits: [4]u8 = undefined;
        const ev_result = linux.ioctl(@intCast(fd), EVIOCGBIT(0, ev_bits.len), @intFromPtr(&ev_bits));
        if (@as(isize, @bitCast(ev_result)) < 0) {
            return .unknown;
        }

        const has_key = testBit(EV_KEY, &ev_bits);
        const has_rel = testBit(EV_REL, &ev_bits);

        if (has_rel) {
            // Check for mouse buttons
            var key_bits: [64]u8 = undefined;
            const key_result = linux.ioctl(@intCast(fd), EVIOCGBIT(EV_KEY, key_bits.len), @intFromPtr(&key_bits));
            if (@as(isize, @bitCast(key_result)) >= 0) {
                if (testBit(BTN_LEFT, &key_bits)) {
                    return .mouse;
                }
            }
        }

        if (has_key) {
            // Check for keyboard-like keys (letters, etc.)
            var key_bits: [64]u8 = undefined;
            const key_result = linux.ioctl(@intCast(fd), EVIOCGBIT(EV_KEY, key_bits.len), @intFromPtr(&key_bits));
            if (@as(isize, @bitCast(key_result)) >= 0) {
                // Check for letter keys (KEY_Q = 16 through KEY_P = 25)
                if (testBit(16, &key_bits) and testBit(17, &key_bits)) {
                    return .keyboard;
                }
            }
        }

        return .unknown;
    }

    /// Open default DRM device
    pub fn initDefault(allocator: std.mem.Allocator) !*Self {
        // Try common device paths
        const paths = [_][]const u8{
            "/dev/dri/card0",
            "/dev/dri/card1",
            "/dev/drm0", // FreeBSD
        };

        var last_err: ?anyerror = null;
        var had_resources_failed = false;
        for (paths) |path| {
            if (init(allocator, path)) |self| {
                return self;
            } else |err| {
                log.warn("failed to open {s}: {}", .{ path, err });
                if (err == error.GetResourcesFailed) {
                    had_resources_failed = true;
                }
                last_err = err;
                continue;
            }
        }

        // Provide helpful error message
        if (had_resources_failed) {
            log.err("KMS backend requires exclusive display access.", .{});
            log.err("If running under X11/Wayland, use '--backend x11' or '--backend wayland' instead.", .{});
            log.err("For KMS, switch to a virtual console (Ctrl+Alt+F2) and run without a display server.", .{});
        }

        if (last_err) |err| {
            return err;
        }
        return error.NoDeviceFound;
    }

    fn findConnector(self: *Self) !void {
        // Get resource counts first
        var res = std.mem.zeroes(drm_mode_card_res);
        var result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETRESOURCES, @intFromPtr(&res));
        if (result != 0) {
            return error.GetResourcesFailed;
        }

        if (res.count_connectors == 0) {
            return error.NoConnectors;
        }

        // Allocate arrays
        const connector_ids = try self.allocator.alloc(u32, res.count_connectors);
        defer self.allocator.free(connector_ids);
        const crtc_ids = try self.allocator.alloc(u32, res.count_crtcs);
        defer self.allocator.free(crtc_ids);
        const encoder_ids = try self.allocator.alloc(u32, res.count_encoders);
        defer self.allocator.free(encoder_ids);

        res.connector_id_ptr = @intFromPtr(connector_ids.ptr);
        res.crtc_id_ptr = @intFromPtr(crtc_ids.ptr);
        res.encoder_id_ptr = @intFromPtr(encoder_ids.ptr);

        result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETRESOURCES, @intFromPtr(&res));
        if (result != 0) {
            return error.GetResourcesFailed;
        }

        // Find connected connector with mode
        for (connector_ids) |conn_id| {
            var conn = std.mem.zeroes(drm_mode_get_connector);
            conn.connector_id = conn_id;

            result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETCONNECTOR, @intFromPtr(&conn));
            if (result != 0) continue;

            if (conn.connection != DRM_MODE_CONNECTED or conn.count_modes == 0) {
                continue;
            }

            // Get modes
            const modes = try self.allocator.alloc(drm_mode_modeinfo, conn.count_modes);
            defer self.allocator.free(modes);
            conn.modes_ptr = @intFromPtr(modes.ptr);

            result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETCONNECTOR, @intFromPtr(&conn));
            if (result != 0) continue;

            // Get encoder
            var encoder = std.mem.zeroes(drm_mode_get_encoder);
            encoder.encoder_id = conn.encoder_id;
            result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETENCODER, @intFromPtr(&encoder));
            if (result != 0) continue;

            // Found a valid connector
            self.connector_id = conn_id;
            self.crtc_id = encoder.crtc_id;
            self.mode = modes[0]; // Use preferred/first mode
            self.width = modes[0].hdisplay;
            self.height = modes[0].vdisplay;

            // Save current CRTC
            var saved = std.mem.zeroes(drm_mode_crtc);
            saved.crtc_id = self.crtc_id;
            if (drm_ioctl(self.fd, DRM_IOCTL_MODE_GETCRTC, @intFromPtr(&saved)) == 0) {
                self.saved_crtc = saved;
            }

            log.info("found connector {}: {}x{}@{}Hz", .{
                conn_id,
                self.width,
                self.height,
                self.mode.vrefresh,
            });

            return;
        }

        return error.NoConnectedDisplay;
    }

    pub fn deinit(self: *Self) void {
        // Close input devices
        for (self.input_fds[0..self.input_count]) |fd| {
            if (fd >= 0) {
                posix.close(fd);
            }
        }

        // Restore saved CRTC
        if (self.saved_crtc) |*saved| {
            _ = drm_ioctl(self.fd, DRM_IOCTL_MODE_SETCRTC, @intFromPtr(saved));
        }

        // Destroy buffers
        for (&self.buffers) |*buf| {
            if (buf.*) |*b| {
                b.destroy(self.fd);
                buf.* = null;
            }
        }

        // Drop master and close
        _ = drm_ioctl(self.fd, DRM_IOCTL_DROP_MASTER, @as(usize, 0));
        if (self.fd >= 0) {
            posix.close(self.fd);
        }

        self.allocator.destroy(self);
    }

    /// Create double buffers
    pub fn createBuffers(self: *Self) !void {
        for (&self.buffers, 0..) |*buf, i| {
            buf.* = DumbBuffer.create(self.fd, self.width, self.height) catch |err| {
                log.err("failed to create buffer {}: {}", .{ i, err });
                return err;
            };
        }
    }

    /// Set mode on display
    pub fn setMode(self: *Self) !void {
        if (self.buffers[0] == null) {
            try self.createBuffers();
        }

        var connector_id = self.connector_id;
        var crtc = drm_mode_crtc{
            .set_connectors_ptr = @intFromPtr(&connector_id),
            .count_connectors = 1,
            .crtc_id = self.crtc_id,
            .fb_id = self.buffers[0].?.fb_id,
            .x = 0,
            .y = 0,
            .gamma_size = 0,
            .mode_valid = 1,
            .mode = self.mode,
        };

        const result = drm_ioctl(self.fd, DRM_IOCTL_MODE_SETCRTC, @intFromPtr(&crtc));
        if (result != 0) {
            return error.SetCrtcFailed;
        }

        log.info("mode set: {}x{}@{}Hz", .{ self.width, self.height, self.mode.vrefresh });
    }

    /// Get back buffer for rendering
    pub fn getBackBuffer(self: *Self) ?[]u8 {
        const back = (self.front_buffer + 1) % 2;
        if (self.buffers[back]) |*buf| {
            return buf.map;
        }
        return null;
    }

    /// Flip buffers (swap front/back)
    pub fn flip(self: *Self) !void {
        const back = (self.front_buffer + 1) % 2;
        const buf = self.buffers[back] orelse return error.NoBuffer;

        var flip_req = drm_mode_page_flip{
            .crtc_id = self.crtc_id,
            .fb_id = buf.fb_id,
            .flags = DRM_MODE_PAGE_FLIP_EVENT,
            .reserved = 0,
            .user_data = self.frame_count,
        };

        const result = drm_ioctl(self.fd, DRM_IOCTL_MODE_PAGE_FLIP, @intFromPtr(&flip_req));
        if (result != 0) {
            return error.PageFlipFailed;
        }

        self.front_buffer = back;
        self.frame_count += 1;
    }

    /// Wait for vsync (page flip completion)
    pub fn waitVsync(self: *Self) !void {
        // Poll for DRM events
        var pfd = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        _ = posix.poll(&pfd, 1000) catch return error.PollFailed;

        if (pfd[0].revents & posix.POLL.IN != 0) {
            // Read event (simplified - just drain the fd)
            var buf: [256]u8 = undefined;
            _ = posix.read(self.fd, &buf) catch {};
        }
    }

    // ========================================================================
    // Backend interface implementation
    // ========================================================================

    fn getCapabilitiesImpl(ctx: *anyopaque) backend.Capabilities {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .name = "DRM/KMS",
            .max_width = self.width,
            .max_height = self.height,
            .supports_aa = true,
            .hardware_accelerated = false, // Dumb buffers are CPU-rendered
            .can_present = true,
        };
    }

    fn initFramebufferImpl(ctx: *anyopaque, config: backend.FramebufferConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Check if mode needs to change
        if (config.width != self.width or config.height != self.height) {
            // Would need to find a matching mode - for now, just use current
            log.warn("requested size {}x{} differs from display {}x{}", .{
                config.width,
                config.height,
                self.width,
                self.height,
            });
        }

        try self.createBuffers();
        try self.setMode();
    }

    fn renderImpl(ctx: *anyopaque, request: backend.RenderRequest) anyerror!backend.RenderResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const start = std.time.nanoTimestamp();

        const buffer = self.getBackBuffer() orelse {
            return backend.RenderResult.failure(request.surface_id, "no back buffer");
        };

        // Clear if requested
        if (request.clear_color) |color| {
            const r: u8 = @intFromFloat(color[0] * 255.0);
            const g: u8 = @intFromFloat(color[1] * 255.0);
            const b: u8 = @intFromFloat(color[2] * 255.0);
            const a: u8 = @intFromFloat(color[3] * 255.0);

            var i: usize = 0;
            while (i < buffer.len) : (i += 4) {
                buffer[i] = b; // BGRA format for most DRM
                buffer[i + 1] = g;
                buffer[i + 2] = r;
                buffer[i + 3] = a;
            }
        }

        // TODO: Execute SDCS commands (would integrate with software renderer)
        _ = request.sdcs_data;

        const end = std.time.nanoTimestamp();
        return backend.RenderResult.success(
            request.surface_id,
            self.frame_count,
            @intCast(end - start),
        );
    }

    fn getPixelsImpl(ctx: *anyopaque) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.getBackBuffer();
    }

    fn resizeImpl(ctx: *anyopaque, width: u32, height: u32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = width;
        _ = height;
        // DRM mode is fixed to display - can't resize arbitrarily
        log.warn("resize not supported for DRM backend", .{});
        _ = self;
    }

    fn pollEventsImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Clear event queues for this poll cycle
        self.key_event_count = 0;
        self.mouse_event_count = 0;

        // Track mouse motion for batching
        var mouse_dx: i32 = 0;
        var mouse_dy: i32 = 0;
        var had_motion = false;

        // Read events from all input devices
        for (self.input_fds[0..self.input_count], self.input_types[0..self.input_count]) |fd, dev_type| {
            if (fd < 0) continue;

            // Read events in a loop until EAGAIN
            while (true) {
                var ev: input_event = undefined;
                const bytes_read = posix.read(fd, std.mem.asBytes(&ev)) catch |err| {
                    if (err == error.WouldBlock) break;
                    break;
                };
                if (bytes_read != @sizeOf(input_event)) break;

                // Process event based on device type
                switch (dev_type) {
                    .keyboard => self.processKeyboardEvent(&ev),
                    .mouse => {
                        const motion = self.processMouseEvent(&ev);
                        if (motion) |delta| {
                            mouse_dx += delta[0];
                            mouse_dy += delta[1];
                            had_motion = true;
                        }
                    },
                    .unknown => {},
                }
            }
        }

        // Emit batched mouse motion event
        if (had_motion) {
            self.mouse_x = @max(0, @min(self.mouse_x + mouse_dx, @as(i32, @intCast(self.width)) - 1));
            self.mouse_y = @max(0, @min(self.mouse_y + mouse_dy, @as(i32, @intCast(self.height)) - 1));

            if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                self.mouse_events[self.mouse_event_count] = .{
                    .x = self.mouse_x,
                    .y = self.mouse_y,
                    .button = .left, // Doesn't matter for motion
                    .event_type = .motion,
                    .modifiers = self.modifiers,
                };
                self.mouse_event_count += 1;
            }
        }

        return true;
    }

    /// Process a keyboard event
    fn processKeyboardEvent(self: *Self, ev: *const input_event) void {
        if (ev.type != EV_KEY) return;

        const pressed = ev.value != 0; // 1 = press, 0 = release, 2 = repeat

        // Update modifier state
        switch (ev.code) {
            KEY_LEFTSHIFT, KEY_RIGHTSHIFT => {
                if (pressed) self.modifiers |= 0x01 else self.modifiers &= ~@as(u8, 0x01);
            },
            KEY_LEFTALT, KEY_RIGHTALT => {
                if (pressed) self.modifiers |= 0x02 else self.modifiers &= ~@as(u8, 0x02);
            },
            KEY_LEFTCTRL, KEY_RIGHTCTRL => {
                if (pressed) self.modifiers |= 0x04 else self.modifiers &= ~@as(u8, 0x04);
            },
            KEY_LEFTMETA, KEY_RIGHTMETA => {
                if (pressed) self.modifiers |= 0x08 else self.modifiers &= ~@as(u8, 0x08);
            },
            else => {},
        }

        // Queue key event
        if (self.key_event_count < backend.MAX_KEY_EVENTS) {
            self.key_events[self.key_event_count] = .{
                .key_code = ev.code,
                .modifiers = self.modifiers,
                .pressed = pressed,
            };
            self.key_event_count += 1;
        }
    }

    /// Process a mouse event, returns motion delta if any
    fn processMouseEvent(self: *Self, ev: *const input_event) ?[2]i32 {
        switch (ev.type) {
            EV_REL => {
                // Relative motion
                switch (ev.code) {
                    REL_X => return .{ ev.value, 0 },
                    REL_Y => return .{ 0, ev.value },
                    REL_WHEEL => {
                        // Scroll wheel - emit as button press/release
                        const button: backend.MouseButton = if (ev.value > 0) .scroll_up else .scroll_down;
                        if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                            self.mouse_events[self.mouse_event_count] = .{
                                .x = self.mouse_x,
                                .y = self.mouse_y,
                                .button = button,
                                .event_type = .press,
                                .modifiers = self.modifiers,
                            };
                            self.mouse_event_count += 1;
                        }
                    },
                    else => {},
                }
            },
            EV_KEY => {
                // Mouse button
                const button: ?backend.MouseButton = switch (ev.code) {
                    BTN_LEFT => .left,
                    BTN_RIGHT => .right,
                    BTN_MIDDLE => .middle,
                    BTN_SIDE => .button4,
                    BTN_EXTRA => .button5,
                    else => null,
                };

                if (button) |btn| {
                    const pressed = ev.value != 0;
                    const event_type: backend.MouseEventType = if (pressed) .press else .release;

                    // Update button state
                    const bit: u8 = switch (btn) {
                        .left => 0x01,
                        .middle => 0x02,
                        .right => 0x04,
                        else => 0,
                    };
                    if (pressed) {
                        self.mouse_buttons |= bit;
                    } else {
                        self.mouse_buttons &= ~bit;
                    }

                    if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                        self.mouse_events[self.mouse_event_count] = .{
                            .x = self.mouse_x,
                            .y = self.mouse_y,
                            .button = btn,
                            .event_type = event_type,
                            .modifiers = self.modifiers,
                        };
                        self.mouse_event_count += 1;
                    }
                }
            },
            else => {},
        }
        return null;
    }

    fn getKeyEventsImpl(ctx: *anyopaque) []const backend.KeyEvent {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.key_events[0..self.key_event_count];
    }

    fn getMouseEventsImpl(ctx: *anyopaque) []const backend.MouseEvent {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.mouse_events[0..self.mouse_event_count];
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
        .getKeyEvents = getKeyEventsImpl,
        .getMouseEvents = getMouseEventsImpl,
        .deinit = deinitImpl,
    };

    pub fn toBackend(self: *Self) backend.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Create DRM backend
pub fn create(allocator: std.mem.Allocator) !backend.Backend {
    const drm = try DrmBackend.initDefault(allocator);
    return drm.toBackend();
}

/// Create DRM backend with specific device
pub fn createWithDevice(allocator: std.mem.Allocator, device_path: []const u8) !backend.Backend {
    const drm = try DrmBackend.init(allocator, device_path);
    return drm.toBackend();
}

// ============================================================================
// Tests
// ============================================================================

test "DrmBackend struct size" {
    try std.testing.expect(@sizeOf(DrmBackend) > 0);
}

test "DumbBuffer struct size" {
    try std.testing.expect(@sizeOf(DumbBuffer) > 0);
}
