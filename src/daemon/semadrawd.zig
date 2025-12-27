const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");
const socket_server = @import("socket_server");
const client_session = @import("client_session");

const log = std.log.scoped(.semadrawd);

/// Daemon configuration
pub const Config = struct {
    socket_path: []const u8 = protocol.DEFAULT_SOCKET_PATH,
    max_clients: u32 = 256,
    log_level: std.log.Level = .info,
};

/// Daemon state
pub const Daemon = struct {
    allocator: std.mem.Allocator,
    config: Config,
    server: socket_server.SocketServer,
    clients: client_session.ClientManager,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Daemon {
        const server = try socket_server.SocketServer.bind(config.socket_path);
        errdefer server.deinit();

        return .{
            .allocator = allocator,
            .config = config,
            .server = server,
            .clients = client_session.ClientManager.init(allocator),
            .running = false,
        };
    }

    pub fn deinit(self: *Daemon) void {
        self.clients.deinit();
        self.server.deinit();
    }

    /// Main event loop using poll()
    pub fn run(self: *Daemon) !void {
        self.running = true;
        log.info("semadrawd starting on {s}", .{self.config.socket_path});

        // Poll fd array: [0] = server, [1..N] = clients
        var poll_fds = std.ArrayList(posix.pollfd).init(self.allocator);
        defer poll_fds.deinit();

        while (self.running) {
            // Rebuild poll fd list
            poll_fds.clearRetainingCapacity();

            // Add server socket
            try poll_fds.append(.{
                .fd = self.server.getFd(),
                .events = posix.POLL.IN,
                .revents = 0,
            });

            // Add client sockets
            var client_iter = self.clients.iterator();
            while (client_iter.next()) |session| {
                try poll_fds.append(.{
                    .fd = session.*.getFd(),
                    .events = posix.POLL.IN,
                    .revents = 0,
                });
            }

            // Wait for events (100ms timeout for periodic tasks)
            const n = posix.poll(poll_fds.items, 100) catch |err| {
                log.err("poll error: {}", .{err});
                continue;
            };

            if (n == 0) continue; // Timeout, no events

            // Process events
            for (poll_fds.items) |*pfd| {
                if (pfd.revents == 0) continue;

                if (pfd.fd == self.server.getFd()) {
                    // New client connection
                    self.handleNewConnection() catch |err| {
                        log.warn("failed to accept connection: {}", .{err});
                    };
                } else {
                    // Client event
                    if (self.clients.findByFd(pfd.fd)) |session| {
                        if (pfd.revents & posix.POLL.IN != 0) {
                            self.handleClientMessage(session) catch |err| {
                                log.debug("client {} error: {}, disconnecting", .{ session.id, err });
                                self.disconnectClient(session.id);
                            };
                        }
                        if (pfd.revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                            log.debug("client {} disconnected", .{session.id});
                            self.disconnectClient(session.id);
                        }
                    }
                }
            }
        }

        log.info("semadrawd shutting down", .{});
    }

    fn handleNewConnection(self: *Daemon) !void {
        const client_fd = try self.server.accept();

        if (self.clients.count() >= self.config.max_clients) {
            log.warn("max clients reached, rejecting connection", .{});
            posix.close(client_fd);
            return;
        }

        const session = try self.clients.createSession(client_fd);
        log.info("client {} connected", .{session.id});
    }

    fn handleClientMessage(self: *Daemon, session: *client_session.ClientSession) !void {
        var msg = try session.socket.readMessage(self.allocator) orelse return;
        defer msg.deinit(self.allocator);

        switch (session.state) {
            .awaiting_hello => {
                if (msg.header.msg_type != .hello) {
                    try session.sendError(.protocol_error, 0);
                    return error.ProtocolError;
                }
                try self.handleHello(session, msg.payload);
            },
            .connected => {
                try self.handleRequest(session, msg.header.msg_type, msg.payload);
            },
            .disconnecting => {},
        }
    }

    fn handleHello(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.HelloMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return error.InvalidPayload;
        }

        const hello = try protocol.HelloMsg.deserialize(payload.?);

        // Version check
        if (hello.version_major != protocol.PROTOCOL_VERSION_MAJOR) {
            try session.sendError(.protocol_error, 0);
            return error.VersionMismatch;
        }

        // Send reply
        var reply_buf: [protocol.HelloReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.HelloReplyMsg{
            .version_major = protocol.PROTOCOL_VERSION_MAJOR,
            .version_minor = protocol.PROTOCOL_VERSION_MINOR,
            .client_id = session.id,
            .server_flags = 0,
        };
        reply.serialize(&reply_buf);
        try session.send(.hello_reply, &reply_buf);

        session.state = .connected;
        log.info("client {} completed handshake", .{session.id});
    }

    fn handleRequest(self: *Daemon, session: *client_session.ClientSession, msg_type: protocol.MsgType, payload: ?[]u8) !void {
        switch (msg_type) {
            .create_surface => try self.handleCreateSurface(session, payload),
            .destroy_surface => try self.handleDestroySurface(session, payload),
            .commit => try self.handleCommit(session, payload),
            .set_visible => try self.handleSetVisible(session, payload),
            .set_z_order => try self.handleSetZOrder(session, payload),
            .sync => try self.handleSync(session, payload),
            .disconnect => {
                session.state = .disconnecting;
            },
            else => {
                log.warn("client {} sent unexpected message type: {}", .{ session.id, msg_type });
                try session.sendError(.invalid_message, 0);
            },
        }
    }

    fn handleCreateSurface(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.CreateSurfaceMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.CreateSurfaceMsg.deserialize(payload.?);

        // Check resource limits
        if (!session.usage.canCreateSurface(session.limits, msg.logical_width, msg.logical_height)) {
            try session.sendError(.resource_limit, 0);
            return;
        }

        // TODO: Actually create surface in surface registry
        // For now, just assign an ID
        const surface_id: protocol.SurfaceId = @intCast(session.surfaces.items.len + 1);
        try session.addSurface(surface_id, msg.logical_width, msg.logical_height);

        // Send reply
        var reply_buf: [protocol.SurfaceCreatedMsg.SIZE]u8 = undefined;
        const reply = protocol.SurfaceCreatedMsg{ .surface_id = surface_id };
        reply.serialize(&reply_buf);
        try session.send(.surface_created, &reply_buf);

        log.debug("client {} created surface {}", .{ session.id, surface_id });
    }

    fn handleDestroySurface(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.DestroySurfaceMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.DestroySurfaceMsg.deserialize(payload.?);

        if (!session.ownsSurface(msg.surface_id)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // TODO: Get actual surface dimensions from registry
        session.removeSurface(msg.surface_id, 0, 0);

        log.debug("client {} destroyed surface {}", .{ session.id, msg.surface_id });
    }

    fn handleCommit(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.CommitMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.CommitMsg.deserialize(payload.?);

        if (!session.ownsSurface(msg.surface_id)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // TODO: Queue frame for composition
        // For now, immediately send frame_complete
        var reply_buf: [protocol.FrameCompleteMsg.SIZE]u8 = undefined;
        const reply = protocol.FrameCompleteMsg{
            .surface_id = msg.surface_id,
            .frame_number = 0,
            .timestamp_ns = @intCast(std.time.nanoTimestamp()),
        };
        reply.serialize(&reply_buf);
        try session.send(.frame_complete, &reply_buf);

        log.debug("client {} committed surface {}", .{ session.id, msg.surface_id });
    }

    fn handleSetVisible(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.SetVisibleMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SetVisibleMsg.deserialize(payload.?);

        if (!session.ownsSurface(msg.surface_id)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // TODO: Update surface visibility in registry
        log.debug("client {} set surface {} visible={}", .{ session.id, msg.surface_id, msg.visible != 0 });
    }

    fn handleSetZOrder(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.SetZOrderMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SetZOrderMsg.deserialize(payload.?);

        if (!session.ownsSurface(msg.surface_id)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // TODO: Update surface z-order in registry
        log.debug("client {} set surface {} z_order={}", .{ session.id, msg.surface_id, msg.z_order });
    }

    fn handleSync(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.SyncMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SyncMsg.deserialize(payload.?);

        // Send sync done immediately (no pending operations to wait for yet)
        var reply_buf: [protocol.SyncDoneMsg.SIZE]u8 = undefined;
        const reply = protocol.SyncDoneMsg{ .sync_id = msg.sync_id };
        reply.serialize(&reply_buf);
        try session.send(.sync_done, &reply_buf);
    }

    fn disconnectClient(self: *Daemon, client_id: protocol.ClientId) void {
        // TODO: Clean up surfaces owned by this client
        self.clients.destroySession(client_id);
    }

    pub fn stop(self: *Daemon) void {
        self.running = false;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--socket")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            config.socket_path = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const stdout = std.io.getStdOut().writer();
            try stdout.print(
                \\semadrawd - SemaDraw compositor daemon
                \\
                \\Usage: semadrawd [OPTIONS]
                \\
                \\Options:
                \\  -s, --socket PATH   Socket path (default: {s})
                \\  -h, --help          Show this help
                \\
            , .{protocol.DEFAULT_SOCKET_PATH});
            return;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    var daemon = try Daemon.init(allocator, config);
    defer daemon.deinit();

    try daemon.run();
}
