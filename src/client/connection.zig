const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");

const log = std.log.scoped(.semadraw_client);

/// Connection state
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

/// Event types received from the daemon
pub const Event = union(enum) {
    surface_created: protocol.SurfaceCreatedMsg,
    buffer_released: protocol.BufferReleasedMsg,
    frame_complete: protocol.FrameCompleteMsg,
    sync_done: protocol.SyncDoneMsg,
    error_reply: protocol.ErrorReplyMsg,
    key_press: protocol.KeyPressMsg,
    mouse_event: protocol.MouseEventMsg,
    disconnected: void,
};

/// Connection to semadrawd
pub const Connection = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    fd: posix.fd_t,
    state: ConnectionState,
    client_id: protocol.ClientId,
    server_version_major: u16,
    server_version_minor: u16,
    next_sync_id: u32,
    recv_buf: [4096]u8,
    recv_len: usize,

    const Self = @This();

    /// Connect to the daemon at the default socket path
    pub fn connect(allocator: std.mem.Allocator) !*Self {
        return connectTo(allocator, protocol.DEFAULT_SOCKET_PATH);
    }

    /// Connect to the daemon at a specific socket path
    pub fn connectTo(allocator: std.mem.Allocator, socket_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .socket_path = socket_path,
            .fd = -1,
            .state = .disconnected,
            .client_id = 0,
            .server_version_major = 0,
            .server_version_minor = 0,
            .next_sync_id = 1,
            .recv_buf = undefined,
            .recv_len = 0,
        };

        try self.doConnect();
        return self;
    }

    fn doConnect(self: *Self) !void {
        self.state = .connecting;

        // Create socket
        self.fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
            self.state = .error_state;
            return err;
        };
        errdefer {
            posix.close(self.fd);
            self.fd = -1;
        }

        // Connect to daemon
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes = self.socket_path;
        if (path_bytes.len >= addr.path.len) {
            self.state = .error_state;
            return error.PathTooLong;
        }
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        posix.connect(self.fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
            self.state = .error_state;
            return err;
        };

        // Send hello
        try self.sendHello();

        // Wait for hello reply
        try self.waitForHelloReply();

        self.state = .connected;
        log.info("connected to semadrawd, client_id={}", .{self.client_id});
    }

    fn sendHello(self: *Self) !void {
        const hello = protocol.HelloMsg.init();
        var payload: [protocol.HelloMsg.SIZE]u8 = undefined;
        hello.serialize(&payload);
        try self.sendMessage(.hello, &payload);
    }

    fn waitForHelloReply(self: *Self) !void {
        const msg = try self.recvMessage();
        if (msg.header.msg_type != .hello_reply) {
            return error.UnexpectedMessage;
        }
        if (msg.payload) |p| {
            const reply = try protocol.HelloReplyMsg.deserialize(p);
            self.client_id = reply.client_id;
            self.server_version_major = reply.version_major;
            self.server_version_minor = reply.version_minor;
        } else {
            return error.InvalidPayload;
        }
    }

    /// Disconnect from the daemon
    pub fn disconnect(self: *Self) void {
        if (self.fd >= 0) {
            // Send disconnect message (best effort)
            self.sendMessage(.disconnect, &.{}) catch {};
            posix.close(self.fd);
            self.fd = -1;
        }
        self.state = .disconnected;
        self.allocator.destroy(self);
    }

    /// Create a new surface
    pub fn createSurface(self: *Self, width: f32, height: f32) !protocol.SurfaceId {
        return self.createSurfaceWithScale(width, height, 1.0);
    }

    /// Create a new surface with explicit scale
    pub fn createSurfaceWithScale(self: *Self, width: f32, height: f32, scale: f32) !protocol.SurfaceId {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.CreateSurfaceMsg{
            .logical_width = width,
            .logical_height = height,
            .scale = scale,
            .flags = 0,
        };
        var payload: [protocol.CreateSurfaceMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.create_surface, &payload);

        // Wait for response
        const response = try self.recvMessage();
        switch (response.header.msg_type) {
            .surface_created => {
                if (response.payload) |p| {
                    const created = try protocol.SurfaceCreatedMsg.deserialize(p);
                    return created.surface_id;
                }
                return error.InvalidPayload;
            },
            .error_reply => {
                if (response.payload) |p| {
                    const err = try protocol.ErrorReplyMsg.deserialize(p);
                    log.err("create_surface failed: {}", .{err.code});
                }
                return error.ServerError;
            },
            else => return error.UnexpectedMessage,
        }
    }

    /// Destroy a surface
    pub fn destroySurface(self: *Self, surface_id: protocol.SurfaceId) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.DestroySurfaceMsg{ .surface_id = surface_id };
        var payload: [protocol.DestroySurfaceMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.destroy_surface, &payload);
    }

    /// Commit a surface (present its contents)
    pub fn commit(self: *Self, surface_id: protocol.SurfaceId) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.CommitMsg{
            .surface_id = surface_id,
            .flags = 0,
        };
        var payload: [protocol.CommitMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.commit, &payload);
    }

    /// Attach buffer data inline (SDCS data sent in message payload)
    pub fn attachBufferInline(self: *Self, surface_id: protocol.SurfaceId, sdcs_data: []const u8) !void {
        if (self.state != .connected) return error.NotConnected;

        // Create message with AttachBufferInlineMsg header + SDCS data
        const msg_buf = try self.allocator.alloc(u8, protocol.AttachBufferInlineMsg.HEADER_SIZE + sdcs_data.len);
        defer self.allocator.free(msg_buf);

        // Serialize header
        const msg = protocol.AttachBufferInlineMsg{
            .surface_id = surface_id,
            .sdcs_length = sdcs_data.len,
            .flags = 0,
        };
        msg.serialize(msg_buf[0..protocol.AttachBufferInlineMsg.HEADER_SIZE]);

        // Copy SDCS data
        @memcpy(msg_buf[protocol.AttachBufferInlineMsg.HEADER_SIZE..], sdcs_data);

        try self.sendMessage(.attach_buffer_inline, msg_buf);
    }

    /// Set surface visibility
    pub fn setVisible(self: *Self, surface_id: protocol.SurfaceId, visible: bool) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.SetVisibleMsg{
            .surface_id = surface_id,
            .visible = if (visible) 1 else 0,
        };
        var payload: [protocol.SetVisibleMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.set_visible, &payload);
    }

    /// Set surface z-order
    pub fn setZOrder(self: *Self, surface_id: protocol.SurfaceId, z_order: i32) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.SetZOrderMsg{
            .surface_id = surface_id,
            .z_order = z_order,
        };
        var payload: [protocol.SetZOrderMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.set_z_order, &payload);
    }

    /// Set surface position (in pixels)
    pub fn setPosition(self: *Self, surface_id: protocol.SurfaceId, x: f32, y: f32) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.SetPositionMsg{
            .surface_id = surface_id,
            .x = x,
            .y = y,
        };
        var payload: [protocol.SetPositionMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.set_position, &payload);
    }

    /// Synchronization barrier - wait for all pending operations
    pub fn sync(self: *Self) !void {
        if (self.state != .connected) return error.NotConnected;

        const sync_id = self.next_sync_id;
        self.next_sync_id +%= 1;

        const msg = protocol.SyncMsg{ .sync_id = sync_id };
        var payload: [protocol.SyncMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.sync, &payload);

        // Wait for sync_done
        while (true) {
            const response = try self.recvMessage();
            if (response.header.msg_type == .sync_done) {
                if (response.payload) |p| {
                    const done = try protocol.SyncDoneMsg.deserialize(p);
                    if (done.sync_id == sync_id) return;
                }
            }
            // Handle other messages that might arrive before sync_done
        }
    }

    /// Poll for events (non-blocking)
    pub fn poll(self: *Self) !?Event {
        if (self.state != .connected) return null;

        // Check if data is available
        var pfd = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const n = posix.poll(&pfd, 0) catch return null;
        if (n == 0) return null;

        if (pfd[0].revents & posix.POLL.IN != 0) {
            const msg = self.recvMessage() catch |err| {
                if (err == error.EndOfStream) {
                    self.state = .disconnected;
                    return .disconnected;
                }
                return err;
            };
            return self.msgToEvent(msg);
        }

        if (pfd[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            self.state = .disconnected;
            return .disconnected;
        }

        return null;
    }

    /// Wait for an event (blocking)
    pub fn waitEvent(self: *Self) !Event {
        if (self.state != .connected) return .disconnected;

        const msg = try self.recvMessage();
        return self.msgToEvent(msg) orelse error.UnexpectedMessage;
    }

    fn msgToEvent(self: *Self, msg: RecvMessage) ?Event {
        _ = self;
        switch (msg.header.msg_type) {
            .surface_created => {
                if (msg.payload) |p| {
                    if (protocol.SurfaceCreatedMsg.deserialize(p)) |m| {
                        return .{ .surface_created = m };
                    } else |_| {}
                }
            },
            .buffer_released => {
                if (msg.payload) |p| {
                    if (protocol.BufferReleasedMsg.deserialize(p)) |m| {
                        return .{ .buffer_released = m };
                    } else |_| {}
                }
            },
            .frame_complete => {
                if (msg.payload) |p| {
                    if (protocol.FrameCompleteMsg.deserialize(p)) |m| {
                        return .{ .frame_complete = m };
                    } else |_| {}
                }
            },
            .sync_done => {
                if (msg.payload) |p| {
                    if (protocol.SyncDoneMsg.deserialize(p)) |m| {
                        return .{ .sync_done = m };
                    } else |_| {}
                }
            },
            .error_reply => {
                if (msg.payload) |p| {
                    if (protocol.ErrorReplyMsg.deserialize(p)) |m| {
                        return .{ .error_reply = m };
                    } else |_| {}
                }
            },
            .key_press => {
                if (msg.payload) |p| {
                    if (protocol.KeyPressMsg.deserialize(p)) |m| {
                        return .{ .key_press = m };
                    } else |_| {}
                }
            },
            .mouse_event => {
                if (msg.payload) |p| {
                    if (protocol.MouseEventMsg.deserialize(p)) |m| {
                        return .{ .mouse_event = m };
                    } else |_| {}
                }
            },
            else => {},
        }
        return null;
    }

    /// Get file descriptor for external polling
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.fd;
    }

    /// Get current connection state
    pub fn getState(self: *const Self) ConnectionState {
        return self.state;
    }

    /// Get client ID assigned by daemon
    pub fn getClientId(self: *const Self) protocol.ClientId {
        return self.client_id;
    }

    // ========================================================================
    // Internal message I/O
    // ========================================================================

    const RecvMessage = struct {
        header: protocol.MsgHeader,
        payload: ?[]const u8,
    };

    fn sendMessage(self: *Self, msg_type: protocol.MsgType, payload: []const u8) !void {
        var header_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };
        header.serialize(&header_buf);

        // Send header (small, should complete in one write)
        try self.sendAll(&header_buf);

        // Send payload if any
        if (payload.len > 0) {
            try self.sendAll(payload);
        }
    }

    /// Write all bytes, handling partial writes
    fn sendAll(self: *Self, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = posix.write(self.fd, data[sent..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };
            if (n == 0) return error.BrokenPipe;
            sent += n;
        }
    }

    fn recvMessage(self: *Self) !RecvMessage {
        // Read header
        var header_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        try self.recvExact(&header_buf);

        const header = try protocol.MsgHeader.deserialize(&header_buf);

        // Read payload if any
        var payload: ?[]const u8 = null;
        if (header.length > 0) {
            if (header.length > self.recv_buf.len) {
                return error.PayloadTooLarge;
            }
            try self.recvExact(self.recv_buf[0..header.length]);
            payload = self.recv_buf[0..header.length];
        }

        return .{ .header = header, .payload = payload };
    }

    fn recvExact(self: *Self, buf: []u8) !void {
        var received: usize = 0;
        while (received < buf.len) {
            const n = posix.read(self.fd, buf[received..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };
            if (n == 0) return error.EndOfStream;
            received += n;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Connection struct size" {
    // Ensure Connection can be created
    try std.testing.expect(@sizeOf(Connection) > 0);
}
