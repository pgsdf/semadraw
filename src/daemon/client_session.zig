const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");
const socket = @import("socket_server");

/// Client session state
pub const SessionState = enum {
    /// Waiting for HELLO message
    awaiting_hello,
    /// Fully connected and operational
    connected,
    /// Disconnecting (cleanup in progress)
    disconnecting,
};

/// Per-client resource limits
pub const ResourceLimits = struct {
    max_surfaces: u32 = 64,
    max_total_pixels: u64 = 256 * 1024 * 1024, // ~256 megapixels
    max_sdcs_bytes: u64 = 64 * 1024 * 1024, // 64 MB per stream
    max_shm_bytes: u64 = 512 * 1024 * 1024, // 512 MB total shm
};

/// Per-client resource usage tracking
pub const ResourceUsage = struct {
    surface_count: u32 = 0,
    total_pixels: u64 = 0,
    shm_bytes: u64 = 0,

    pub fn canCreateSurface(self: *ResourceUsage, limits: ResourceLimits, width: f32, height: f32) bool {
        const pixels: u64 = @intFromFloat(@abs(width * height));
        return self.surface_count < limits.max_surfaces and
            self.total_pixels + pixels <= limits.max_total_pixels;
    }

    pub fn canAttachBuffer(self: *ResourceUsage, limits: ResourceLimits, size: u64) bool {
        return size <= limits.max_sdcs_bytes and
            self.shm_bytes + size <= limits.max_shm_bytes;
    }

    pub fn addSurface(self: *ResourceUsage, width: f32, height: f32) void {
        const pixels: u64 = @intFromFloat(@abs(width * height));
        self.surface_count += 1;
        self.total_pixels += pixels;
    }

    pub fn removeSurface(self: *ResourceUsage, width: f32, height: f32) void {
        const pixels: u64 = @intFromFloat(@abs(width * height));
        self.surface_count -|= 1;
        self.total_pixels -|= pixels;
    }
};

/// Client session - represents a connected client
pub const ClientSession = struct {
    id: protocol.ClientId,
    socket: socket.ClientSocket,
    state: SessionState,
    limits: ResourceLimits,
    usage: ResourceUsage,
    surfaces: std.ArrayList(protocol.SurfaceId),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: protocol.ClientId, fd: posix.socket_t) ClientSession {
        return .{
            .id = id,
            .socket = socket.ClientSocket.init(fd),
            .state = .awaiting_hello,
            .limits = .{},
            .usage = .{},
            .surfaces = std.ArrayList(protocol.SurfaceId).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClientSession) void {
        self.socket.close();
        self.surfaces.deinit();
    }

    pub fn getFd(self: *ClientSession) posix.socket_t {
        return self.socket.getFd();
    }

    /// Send a protocol message to this client
    pub fn send(self: *ClientSession, msg_type: protocol.MsgType, payload: []const u8) !void {
        try self.socket.sendMessage(msg_type, payload);
    }

    /// Send an error to this client
    pub fn sendError(self: *ClientSession, code: protocol.ErrorCode, context: u32) !void {
        var buf: [protocol.ErrorReplyMsg.SIZE]u8 = undefined;
        const msg = protocol.ErrorReplyMsg{ .code = code, .context = context };
        msg.serialize(&buf);
        try self.send(.error_reply, &buf);
    }

    /// Track a new surface owned by this client
    pub fn addSurface(self: *ClientSession, surface_id: protocol.SurfaceId, width: f32, height: f32) !void {
        try self.surfaces.append(surface_id);
        self.usage.addSurface(width, height);
    }

    /// Remove a surface from this client
    pub fn removeSurface(self: *ClientSession, surface_id: protocol.SurfaceId, width: f32, height: f32) void {
        for (self.surfaces.items, 0..) |sid, i| {
            if (sid == surface_id) {
                _ = self.surfaces.swapRemove(i);
                break;
            }
        }
        self.usage.removeSurface(width, height);
    }

    /// Check if this client owns a surface
    pub fn ownsSurface(self: *ClientSession, surface_id: protocol.SurfaceId) bool {
        for (self.surfaces.items) |sid| {
            if (sid == surface_id) return true;
        }
        return false;
    }
};

/// Client session manager - tracks all connected clients
pub const ClientManager = struct {
    allocator: std.mem.Allocator,
    sessions: std.AutoHashMap(protocol.ClientId, *ClientSession),
    fd_to_client: std.AutoHashMap(posix.socket_t, protocol.ClientId),
    next_id: protocol.ClientId,

    pub fn init(allocator: std.mem.Allocator) ClientManager {
        return .{
            .allocator = allocator,
            .sessions = std.AutoHashMap(protocol.ClientId, *ClientSession).init(allocator),
            .fd_to_client = std.AutoHashMap(posix.socket_t, protocol.ClientId).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *ClientManager) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |session_ptr| {
            session_ptr.*.deinit();
            self.allocator.destroy(session_ptr.*);
        }
        self.sessions.deinit();
        self.fd_to_client.deinit();
    }

    /// Create a new client session for an accepted connection
    pub fn createSession(self: *ClientManager, fd: posix.socket_t) !*ClientSession {
        const id = self.next_id;
        self.next_id += 1;

        const session = try self.allocator.create(ClientSession);
        session.* = ClientSession.init(self.allocator, id, fd);

        try self.sessions.put(id, session);
        try self.fd_to_client.put(fd, id);

        return session;
    }

    /// Remove and clean up a client session
    pub fn destroySession(self: *ClientManager, id: protocol.ClientId) void {
        if (self.sessions.fetchRemove(id)) |kv| {
            const session = kv.value;
            _ = self.fd_to_client.remove(session.getFd());
            session.deinit();
            self.allocator.destroy(session);
        }
    }

    /// Find a session by file descriptor
    pub fn findByFd(self: *ClientManager, fd: posix.socket_t) ?*ClientSession {
        if (self.fd_to_client.get(fd)) |id| {
            return self.sessions.get(id);
        }
        return null;
    }

    /// Find a session by client ID
    pub fn findById(self: *ClientManager, id: protocol.ClientId) ?*ClientSession {
        return self.sessions.get(id);
    }

    /// Get the number of connected clients
    pub fn count(self: *ClientManager) usize {
        return self.sessions.count();
    }

    /// Iterate over all sessions
    pub fn iterator(self: *ClientManager) std.AutoHashMap(protocol.ClientId, *ClientSession).ValueIterator {
        return self.sessions.valueIterator();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ResourceUsage tracking" {
    var usage = ResourceUsage{};
    const limits = ResourceLimits{};

    try std.testing.expect(usage.canCreateSurface(limits, 1920, 1080));

    usage.addSurface(1920, 1080);
    try std.testing.expectEqual(@as(u32, 1), usage.surface_count);

    usage.removeSurface(1920, 1080);
    try std.testing.expectEqual(@as(u32, 0), usage.surface_count);
}

test "ClientManager create and destroy" {
    var manager = ClientManager.init(std.testing.allocator);
    defer manager.deinit();

    // We can't test with real sockets in unit tests, but we can verify the structure
    try std.testing.expectEqual(@as(usize, 0), manager.count());
}
