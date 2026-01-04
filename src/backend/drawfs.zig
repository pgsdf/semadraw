const std = @import("std");
const posix = std.posix;
const backend = @import("backend");

const log = std.log.scoped(.drawfs_backend);

// ioctl via libc (works on both Linux and FreeBSD)
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

fn doIoctl(fd: posix.fd_t, request: u32, arg: usize) c_int {
    return ioctl(@intCast(fd), @intCast(request), arg);
}

// ============================================================================
// drawfs protocol constants and structures
// ============================================================================

const DRAWFS_MAGIC: u32 = 0x31575244; // 'DRW1' little-endian
const DRAWFS_VERSION: u16 = 0x0100; // v1.0
const DRAWFS_FRAME_HDR_SIZE: usize = 16;
const DRAWFS_MSG_HDR_SIZE: usize = 16;

// Message types
const REQ_HELLO: u16 = 0x0001;
const REQ_DISPLAY_LIST: u16 = 0x0010;
const REQ_DISPLAY_OPEN: u16 = 0x0011;
const REQ_SURFACE_CREATE: u16 = 0x0020;
const REQ_SURFACE_DESTROY: u16 = 0x0021;
const REQ_SURFACE_PRESENT: u16 = 0x0022;

const RPL_HELLO: u16 = 0x8001;
const RPL_DISPLAY_LIST: u16 = 0x8010;
const RPL_DISPLAY_OPEN: u16 = 0x8011;
const RPL_SURFACE_CREATE: u16 = 0x8020;
const RPL_SURFACE_DESTROY: u16 = 0x8021;
const RPL_SURFACE_PRESENT: u16 = 0x8022;
const EVT_SURFACE_PRESENTED: u16 = 0x9002;

// Pixel formats
const FMT_XRGB8888: u32 = 1;

// ioctl for MAP_SURFACE
// FreeBSD ioctl encoding: _IOWR('D', 0x02, struct) = 0xC0104402
// Size = 16 bytes (4 fields * 4 bytes each)
const DRAWFSGIOC_MAP_SURFACE: u32 = 0xC0104402;

const MapSurfaceReq = extern struct {
    status: i32,
    surface_id: u32,
    stride_bytes: u32,
    bytes_total: u32,
};

// ============================================================================
// Protocol helpers
// ============================================================================

fn align4(n: u32) u32 {
    return (n + 3) & ~@as(u32, 3);
}

fn makeFrame(allocator: std.mem.Allocator, frame_id: u32, msg_type: u16, msg_id: u32, payload: []const u8) ![]u8 {
    const msg_bytes = align4(@as(u32, @intCast(DRAWFS_MSG_HDR_SIZE + payload.len)));
    const frame_bytes = align4(@as(u32, @intCast(DRAWFS_FRAME_HDR_SIZE)) + msg_bytes);

    const buf = try allocator.alloc(u8, frame_bytes);
    @memset(buf, 0);

    // Frame header
    std.mem.writeInt(u32, buf[0..4], DRAWFS_MAGIC, .little);
    std.mem.writeInt(u16, buf[4..6], DRAWFS_VERSION, .little);
    std.mem.writeInt(u16, buf[6..8], DRAWFS_FRAME_HDR_SIZE, .little);
    std.mem.writeInt(u32, buf[8..12], frame_bytes, .little);
    std.mem.writeInt(u32, buf[12..16], frame_id, .little);

    // Message header
    std.mem.writeInt(u16, buf[16..18], msg_type, .little);
    std.mem.writeInt(u16, buf[18..20], 0, .little); // flags
    std.mem.writeInt(u32, buf[20..24], msg_bytes, .little);
    std.mem.writeInt(u32, buf[24..28], msg_id, .little);
    std.mem.writeInt(u32, buf[28..32], 0, .little); // reserved

    // Payload
    if (payload.len > 0) {
        @memcpy(buf[32..][0..payload.len], payload);
    }

    return buf;
}

fn readFrame(fd: posix.fd_t, buf: []u8) !usize {
    // Read frame header first
    var total: usize = 0;
    while (total < DRAWFS_FRAME_HDR_SIZE) {
        const n = posix.read(fd, buf[total..DRAWFS_FRAME_HDR_SIZE]) catch |err| {
            return err;
        };
        if (n == 0) return error.EndOfFile;
        total += n;
    }

    // Validate magic
    const magic = std.mem.readInt(u32, buf[0..4], .little);
    if (magic != DRAWFS_MAGIC) {
        return error.InvalidMagic;
    }

    // Get frame size and read rest
    const frame_bytes = std.mem.readInt(u32, buf[8..12], .little);
    if (frame_bytes > buf.len) {
        return error.BufferTooSmall;
    }

    while (total < frame_bytes) {
        const n = posix.read(fd, buf[total..frame_bytes]) catch |err| {
            return err;
        };
        if (n == 0) return error.EndOfFile;
        total += n;
    }

    return total;
}

fn parseReply(buf: []const u8) struct { msg_type: u16, msg_id: u32, payload: []const u8 } {
    const msg_type = std.mem.readInt(u16, buf[16..18], .little);
    const msg_bytes = std.mem.readInt(u32, buf[20..24], .little);
    const msg_id = std.mem.readInt(u32, buf[24..28], .little);
    const payload_len = msg_bytes - DRAWFS_MSG_HDR_SIZE;
    const payload = buf[32..][0..payload_len];
    return .{ .msg_type = msg_type, .msg_id = msg_id, .payload = payload };
}

// ============================================================================
// DrawfsBackend
// ============================================================================

pub const DrawfsBackend = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    frame_id: u32,
    msg_id: u32,

    // Display info
    display_id: u32,
    display_handle: u32,
    display_width: u32,
    display_height: u32,

    // Surface info
    surface_id: u32,
    surface_stride: u32,
    surface_bytes: u32,
    surface_map: ?[]align(4096) u8,

    // Render state
    width: u32,
    height: u32,
    frame_count: u64,

    // Read buffer for protocol
    read_buf: [4096]u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .fd = -1,
            .frame_id = 1,
            .msg_id = 1,
            .display_id = 0,
            .display_handle = 0,
            .display_width = 0,
            .display_height = 0,
            .surface_id = 0,
            .surface_stride = 0,
            .surface_bytes = 0,
            .surface_map = null,
            .width = 0,
            .height = 0,
            .frame_count = 0,
            .read_buf = undefined,
        };

        // Open device
        self.fd = posix.open(device_path, .{ .ACCMODE = .RDWR }, 0) catch {
            log.err("failed to open {s}", .{device_path});
            return error.OpenFailed;
        };
        errdefer posix.close(self.fd);

        // Protocol handshake
        try self.doHello();
        try self.doDisplayList();
        try self.doDisplayOpen();

        log.info("connected to drawfs: display {}x{}", .{ self.display_width, self.display_height });

        return self;
    }

    pub fn initDefault(allocator: std.mem.Allocator) !*Self {
        return init(allocator, "/dev/draw");
    }

    fn nextFrameId(self: *Self) u32 {
        const id = self.frame_id;
        self.frame_id +%= 1;
        return id;
    }

    fn nextMsgId(self: *Self) u32 {
        const id = self.msg_id;
        self.msg_id +%= 1;
        return id;
    }

    fn sendAndRecv(self: *Self, msg_type: u16, payload: []const u8, expected_reply: u16) ![]const u8 {
        const frame_id = self.nextFrameId();
        const msg_id = self.nextMsgId();

        const frame = try makeFrame(self.allocator, frame_id, msg_type, msg_id, payload);
        defer self.allocator.free(frame);

        // Send
        var sent: usize = 0;
        while (sent < frame.len) {
            sent += posix.write(self.fd, frame[sent..]) catch |err| {
                return err;
            };
        }

        // Read reply (may need to skip events)
        while (true) {
            const n = try readFrame(self.fd, &self.read_buf);
            const reply = parseReply(self.read_buf[0..n]);

            // Skip events
            if (reply.msg_type == EVT_SURFACE_PRESENTED) {
                continue;
            }

            if (reply.msg_type != expected_reply) {
                log.err("expected reply 0x{x:04}, got 0x{x:04}", .{ expected_reply, reply.msg_type });
                return error.UnexpectedReply;
            }

            return reply.payload;
        }
    }

    fn doHello(self: *Self) !void {
        var payload: [12]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], 1, .little); // client_major
        std.mem.writeInt(u16, payload[2..4], 0, .little); // client_minor
        std.mem.writeInt(u32, payload[4..8], 0, .little); // client_flags
        std.mem.writeInt(u32, payload[8..12], 4096, .little); // max_reply_bytes

        const reply = try self.sendAndRecv(REQ_HELLO, &payload, RPL_HELLO);

        const server_major = std.mem.readInt(u16, reply[0..2], .little);
        const server_minor = std.mem.readInt(u16, reply[2..4], .little);
        log.info("drawfs protocol v{}.{}", .{ server_major, server_minor });
    }

    fn doDisplayList(self: *Self) !void {
        const reply = try self.sendAndRecv(REQ_DISPLAY_LIST, &[_]u8{}, RPL_DISPLAY_LIST);

        if (reply.len < 4) return error.InvalidReply;

        const count = std.mem.readInt(u32, reply[0..4], .little);
        if (count == 0) return error.NoDisplays;

        // Parse first display descriptor (20 bytes each)
        if (reply.len < 4 + 20) return error.InvalidReply;

        self.display_id = std.mem.readInt(u32, reply[4..8], .little);
        self.display_width = std.mem.readInt(u32, reply[8..12], .little);
        self.display_height = std.mem.readInt(u32, reply[12..16], .little);
        const refresh_mhz = std.mem.readInt(u32, reply[16..20], .little);

        log.info("display {}: {}x{}@{}mHz", .{
            self.display_id,
            self.display_width,
            self.display_height,
            refresh_mhz,
        });
    }

    fn doDisplayOpen(self: *Self) !void {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.display_id, .little);

        const reply = try self.sendAndRecv(REQ_DISPLAY_OPEN, &payload, RPL_DISPLAY_OPEN);

        if (reply.len < 12) return error.InvalidReply;

        const status = std.mem.readInt(i32, reply[0..4], .little);
        if (status != 0) {
            log.err("DISPLAY_OPEN failed: status={}", .{status});
            return error.DisplayOpenFailed;
        }

        self.display_handle = std.mem.readInt(u32, reply[4..8], .little);
        log.info("display opened: handle={}", .{self.display_handle});
    }

    fn createSurface(self: *Self, width: u32, height: u32) !void {
        var payload: [16]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], width, .little);
        std.mem.writeInt(u32, payload[4..8], height, .little);
        std.mem.writeInt(u32, payload[8..12], FMT_XRGB8888, .little);
        std.mem.writeInt(u32, payload[12..16], 0, .little); // flags

        const reply = try self.sendAndRecv(REQ_SURFACE_CREATE, &payload, RPL_SURFACE_CREATE);

        if (reply.len < 16) return error.InvalidReply;

        const status = std.mem.readInt(i32, reply[0..4], .little);
        if (status != 0) {
            log.err("SURFACE_CREATE failed: status={}", .{status});
            return error.SurfaceCreateFailed;
        }

        self.surface_id = std.mem.readInt(u32, reply[4..8], .little);
        self.surface_stride = std.mem.readInt(u32, reply[8..12], .little);
        self.surface_bytes = std.mem.readInt(u32, reply[12..16], .little);
        self.width = width;
        self.height = height;

        log.info("surface created: id={} stride={} bytes={}", .{
            self.surface_id,
            self.surface_stride,
            self.surface_bytes,
        });

        // Map the surface
        try self.mapSurface();
    }

    fn mapSurface(self: *Self) !void {
        var req = MapSurfaceReq{
            .status = 0,
            .surface_id = self.surface_id,
            .stride_bytes = 0,
            .bytes_total = 0,
        };

        // Call ioctl
        const result = doIoctl(self.fd, DRAWFSGIOC_MAP_SURFACE, @intFromPtr(&req));
        if (result < 0) {
            log.err("MAP_SURFACE ioctl failed: {}", .{result});
            return error.MapSurfaceFailed;
        }

        if (req.status != 0) {
            log.err("MAP_SURFACE status={}", .{req.status});
            return error.MapSurfaceFailed;
        }

        // mmap the surface
        const map = posix.mmap(
            null,
            self.surface_bytes,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            0,
        ) catch |err| {
            log.err("mmap failed: {}", .{err});
            return error.MmapFailed;
        };

        self.surface_map = @as([*]align(4096) u8, @ptrCast(@alignCast(map)))[0..self.surface_bytes];
        log.info("surface mapped: {} bytes at {*}", .{ self.surface_bytes, self.surface_map.?.ptr });
    }

    fn destroySurface(self: *Self) void {
        if (self.surface_map) |m| {
            posix.munmap(m);
            self.surface_map = null;
        }

        if (self.surface_id != 0) {
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], self.surface_id, .little);

            _ = self.sendAndRecv(REQ_SURFACE_DESTROY, &payload, RPL_SURFACE_DESTROY) catch {};
            self.surface_id = 0;
        }
    }

    fn present(self: *Self) !void {
        if (self.surface_id == 0) return error.NoSurface;

        var payload: [16]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, payload[4..8], 0, .little); // flags
        std.mem.writeInt(u64, payload[8..16], self.frame_count, .little); // cookie

        const reply = try self.sendAndRecv(REQ_SURFACE_PRESENT, &payload, RPL_SURFACE_PRESENT);

        if (reply.len < 4) return error.InvalidReply;

        const status = std.mem.readInt(i32, reply[0..4], .little);
        if (status != 0) {
            log.warn("SURFACE_PRESENT status={}", .{status});
        }
    }

    pub fn deinit(self: *Self) void {
        self.destroySurface();

        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }

        self.allocator.destroy(self);
    }

    // ========================================================================
    // Backend interface implementation
    // ========================================================================

    fn getCapabilitiesImpl(ctx: *anyopaque) backend.Capabilities {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .name = "drawfs",
            .max_width = if (self.display_width > 0) self.display_width else 8192,
            .max_height = if (self.display_height > 0) self.display_height else 8192,
            .supports_aa = true,
            .hardware_accelerated = false,
            .can_present = true,
        };
    }

    fn initFramebufferImpl(ctx: *anyopaque, config: backend.FramebufferConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Destroy existing surface if different size
        if (self.surface_id != 0 and (self.width != config.width or self.height != config.height)) {
            self.destroySurface();
        }

        // Create surface if needed
        if (self.surface_id == 0) {
            try self.createSurface(config.width, config.height);
        }
    }

    fn renderImpl(ctx: *anyopaque, request: backend.RenderRequest) anyerror!backend.RenderResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const start = std.time.nanoTimestamp();

        const buffer = self.surface_map orelse {
            return backend.RenderResult.failure(request.surface_id, "no surface mapped");
        };

        // Clear if requested (XRGB8888 format: B, G, R, X)
        if (request.clear_color) |color| {
            const r: u8 = @intFromFloat(@min(1.0, @max(0.0, color[0])) * 255.0);
            const g: u8 = @intFromFloat(@min(1.0, @max(0.0, color[1])) * 255.0);
            const b: u8 = @intFromFloat(@min(1.0, @max(0.0, color[2])) * 255.0);

            var i: usize = 0;
            while (i + 3 < buffer.len) : (i += 4) {
                buffer[i] = b;
                buffer[i + 1] = g;
                buffer[i + 2] = r;
                buffer[i + 3] = 0xFF; // X = opaque
            }
        }

        // Execute SDCS commands
        // For now, minimal SDCS parsing - just look for FILL_RECT
        self.executeSdcs(buffer, request.sdcs_data) catch |err| {
            return backend.RenderResult.failure(request.surface_id, @errorName(err));
        };

        // Present to drawfs
        self.present() catch |err| {
            log.warn("present failed: {}", .{err});
        };

        self.frame_count += 1;
        const end = std.time.nanoTimestamp();

        return backend.RenderResult.success(
            request.surface_id,
            self.frame_count,
            @intCast(end - start),
        );
    }

    fn executeSdcs(self: *Self, fb: []u8, data: []const u8) !void {
        if (data.len < 64) return; // Header too small

        // Skip SDCS header (64 bytes)
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
            switch (opcode) {
                0x0001 => {}, // RESET
                0x0010 => { // FILL_RECT
                    if (payload.len >= 32) {
                        const x = readF32(payload[0..4]);
                        const y = readF32(payload[4..8]);
                        const w = readF32(payload[8..12]);
                        const h = readF32(payload[12..16]);
                        const r = readF32(payload[16..20]);
                        const g = readF32(payload[20..24]);
                        const b_val = readF32(payload[24..28]);
                        const a = readF32(payload[28..32]);

                        self.fillRect(fb, x, y, w, h, r, g, b_val, a);
                    }
                },
                0x00F0 => return, // END
                else => {}, // Ignore unknown
            }

            // Align to 8 bytes
            offset += payload_len;
            const record_bytes = 8 + payload_len;
            const pad = (8 - (record_bytes % 8)) % 8;
            offset += pad;
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

        const cr = clampU8(r);
        const cg = clampU8(g);
        const cb = clampU8(b_col);
        const ca = clampU8(a);

        const stride = self.surface_stride;

        var py: i32 = y0;
        while (py < y1) : (py += 1) {
            var px: i32 = x0;
            while (px < x1) : (px += 1) {
                const idx = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 4;
                if (idx + 3 < fb.len) {
                    // XRGB8888: B, G, R, X
                    if (ca == 255) {
                        fb[idx + 0] = cb;
                        fb[idx + 1] = cg;
                        fb[idx + 2] = cr;
                        fb[idx + 3] = 0xFF;
                    } else if (ca > 0) {
                        // Alpha blend
                        const sa: f32 = @as(f32, @floatFromInt(ca)) / 255.0;
                        const inv_sa = 1.0 - sa;
                        fb[idx + 0] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(cb)) * sa + @as(f32, @floatFromInt(fb[idx + 0])) * inv_sa));
                        fb[idx + 1] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(cg)) * sa + @as(f32, @floatFromInt(fb[idx + 1])) * inv_sa));
                        fb[idx + 2] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(cr)) * sa + @as(f32, @floatFromInt(fb[idx + 2])) * inv_sa));
                        fb[idx + 3] = 0xFF;
                    }
                }
            }
        }
    }

    fn getPixelsImpl(ctx: *anyopaque) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.surface_map;
    }

    fn resizeImpl(ctx: *anyopaque, width: u32, height: u32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (self.width == width and self.height == height) return;

        // Destroy old surface and create new one
        self.destroySurface();
        try self.createSurface(width, height);
    }

    fn pollEventsImpl(_: *anyopaque) bool {
        // drawfs doesn't have input events (yet)
        return true;
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

// ============================================================================
// Public API
// ============================================================================

/// Create drawfs backend with default device path (/dev/draw)
pub fn create(allocator: std.mem.Allocator) !backend.Backend {
    const drawfs_backend = try DrawfsBackend.initDefault(allocator);
    return drawfs_backend.toBackend();
}

/// Create drawfs backend with specific device path
pub fn createWithDevice(allocator: std.mem.Allocator, device_path: []const u8) !backend.Backend {
    const drawfs_backend = try DrawfsBackend.init(allocator, device_path);
    return drawfs_backend.toBackend();
}

// ============================================================================
// Tests
// ============================================================================

test "DrawfsBackend struct size" {
    try std.testing.expect(@sizeOf(DrawfsBackend) > 0);
}

test "align4" {
    try std.testing.expectEqual(@as(u32, 0), align4(0));
    try std.testing.expectEqual(@as(u32, 4), align4(1));
    try std.testing.expectEqual(@as(u32, 4), align4(4));
    try std.testing.expectEqual(@as(u32, 8), align4(5));
}

test "clampU8" {
    try std.testing.expectEqual(@as(u8, 0), clampU8(-1.0));
    try std.testing.expectEqual(@as(u8, 0), clampU8(0.0));
    try std.testing.expectEqual(@as(u8, 128), clampU8(0.5));
    try std.testing.expectEqual(@as(u8, 255), clampU8(1.0));
    try std.testing.expectEqual(@as(u8, 255), clampU8(2.0));
}
