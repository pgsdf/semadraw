const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");
const socket_server = @import("socket_server");
const tcp_server = @import("tcp_server");
const client_session = @import("client_session");
const surface_registry = @import("surface_registry");
const shm = @import("shm");
const sdcs_validator = @import("sdcs_validator");
const compositor = @import("compositor");
const backend = @import("backend");

const log = std.log.scoped(.semadrawd);

/// Poll file descriptor (Zig-native version of pollfd)
const PollFd = extern struct {
    fd: posix.fd_t,
    events: i16,
    revents: i16,
};

/// Daemon configuration
pub const Config = struct {
    socket_path: []const u8 = protocol.DEFAULT_SOCKET_PATH,
    tcp_port: ?u16 = null, // TCP port for remote connections (null = disabled)
    tcp_addr: [4]u8 = .{ 0, 0, 0, 0 }, // TCP bind address
    max_clients: u32 = 256,
    log_level: std.log.Level = .info,
    backend_type: backend.BackendType = .software,
};

/// Remote client session wrapper
const RemoteSession = struct {
    client: tcp_server.RemoteClient,
    id: protocol.ClientId,
    state: client_session.SessionState,
    sdcs_buffer: ?[]u8, // Inline SDCS data for current surface

    pub fn getFd(self: *RemoteSession) posix.fd_t {
        return self.client.getFd();
    }
};

/// Daemon state
pub const Daemon = struct {
    allocator: std.mem.Allocator,
    config: Config,
    server: socket_server.SocketServer,
    tcp: ?tcp_server.TcpServer,
    clients: client_session.ClientManager,
    remote_clients: std.AutoHashMap(protocol.ClientId, *RemoteSession),
    next_remote_id: protocol.ClientId,
    surfaces: surface_registry.SurfaceRegistry,
    comp: compositor.Compositor,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Daemon {
        var server = try socket_server.SocketServer.bind(config.socket_path);
        errdefer server.deinit();

        // Initialize TCP server if port is configured
        var tcp: ?tcp_server.TcpServer = null;
        if (config.tcp_port) |port| {
            tcp = try tcp_server.TcpServer.bindAddr(config.tcp_addr, port);
        }
        errdefer if (tcp) |*t| t.deinit();

        return .{
            .allocator = allocator,
            .config = config,
            .server = server,
            .tcp = tcp,
            .clients = client_session.ClientManager.init(allocator),
            .remote_clients = std.AutoHashMap(protocol.ClientId, *RemoteSession).init(allocator),
            .next_remote_id = 0x80000000, // Remote clients start at high IDs
            .surfaces = surface_registry.SurfaceRegistry.init(allocator),
            .comp = undefined, // Initialized in initCompositor
            .running = false,
        };
    }

    /// Initialize compositor (must be called after init, before run)
    pub fn initCompositor(self: *Daemon) !void {
        self.comp = compositor.Compositor.init(self.allocator, &self.surfaces);

        // Initialize output with default 1920x1080
        try self.comp.initOutput(0, .{
            .width = 1920,
            .height = 1080,
            .format = .rgba8,
            .refresh_hz = 60,
            .backend_type = self.config.backend_type,
        });
    }

    pub fn deinit(self: *Daemon) void {
        // Clean up remote clients
        var iter = self.remote_clients.valueIterator();
        while (iter.next()) |session_ptr| {
            const session = session_ptr.*;
            if (session.sdcs_buffer) |buf| self.allocator.free(buf);
            session.client.close();
            self.allocator.destroy(session);
        }
        self.remote_clients.deinit();

        self.comp.deinit();
        self.surfaces.deinit();
        self.clients.deinit();
        if (self.tcp) |*tcp| tcp.deinit();
        self.server.deinit();
    }

    /// Main event loop using poll()
    pub fn run(self: *Daemon) !void {
        self.running = true;
        log.info("semadrawd starting on {s}", .{self.config.socket_path});
        if (self.tcp) |tcp| {
            log.info("TCP server listening on port {}", .{tcp.port});
        }

        // Poll fd array: [0] = server, [1] = tcp (optional), [...] = clients
        var poll_fds: std.ArrayListUnmanaged(PollFd) = .{};
        defer poll_fds.deinit(self.allocator);

        while (self.running) {
            // Rebuild poll fd list
            poll_fds.clearRetainingCapacity();

            // Add Unix socket server
            try poll_fds.append(self.allocator, .{
                .fd = self.server.getFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            });

            // Add TCP server if enabled
            const tcp_fd: ?posix.fd_t = if (self.tcp) |tcp| tcp.getFd() else null;
            if (tcp_fd) |fd| {
                try poll_fds.append(self.allocator, .{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
            }

            // Add local client sockets
            var client_iter = self.clients.iterator();
            while (client_iter.next()) |session| {
                try poll_fds.append(self.allocator, .{
                    .fd = session.*.getFd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
            }

            // Add remote client sockets
            var remote_iter = self.remote_clients.valueIterator();
            while (remote_iter.next()) |session_ptr| {
                try poll_fds.append(self.allocator, .{
                    .fd = session_ptr.*.getFd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
            }

            // Wait for events (100ms timeout for periodic tasks)
            const poll_slice: []posix.pollfd = @ptrCast(poll_fds.items);
            const n = posix.poll(poll_slice, 100) catch |err| {
                log.err("poll error: {}", .{err});
                continue;
            };

            // Poll backend events (keyboard, window close, etc.)
            if (!self.comp.pollEvents()) {
                log.info("backend requested shutdown", .{});
                self.running = false;
                break;
            }

            if (n == 0) continue; // Timeout, no socket events

            // Process events
            for (poll_fds.items) |*pfd| {
                if (pfd.revents == 0) continue;

                if (pfd.fd == self.server.getFd()) {
                    // New local client connection
                    self.handleNewConnection() catch |err| {
                        log.warn("failed to accept local connection: {}", .{err});
                    };
                } else if (tcp_fd != null and pfd.fd == tcp_fd.?) {
                    // New remote client connection
                    self.handleNewRemoteConnection() catch |err| {
                        log.warn("failed to accept remote connection: {}", .{err});
                    };
                } else if (self.clients.findByFd(pfd.fd)) |session| {
                    // Local client event
                    if (pfd.revents & std.posix.POLL.IN != 0) {
                        self.handleClientMessage(session) catch |err| {
                            log.debug("client {} error: {}, disconnecting", .{ session.id, err });
                            self.disconnectClient(session.id);
                        };
                    }
                    if (pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                        log.debug("client {} disconnected", .{session.id});
                        self.disconnectClient(session.id);
                    }
                } else if (self.findRemoteByFd(pfd.fd)) |session| {
                    // Remote client event
                    if (pfd.revents & std.posix.POLL.IN != 0) {
                        self.handleRemoteClientMessage(session) catch |err| {
                            log.debug("remote client {} error: {}, disconnecting", .{ session.id, err });
                            self.disconnectRemoteClient(session.id);
                        };
                    }
                    if (pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                        log.debug("remote client {} disconnected", .{session.id});
                        self.disconnectRemoteClient(session.id);
                    }
                }
            }
        }

        log.info("semadrawd shutting down", .{});
    }

    fn findRemoteByFd(self: *Daemon, fd: posix.fd_t) ?*RemoteSession {
        var iter = self.remote_clients.valueIterator();
        while (iter.next()) |session_ptr| {
            if (session_ptr.*.getFd() == fd) return session_ptr.*;
        }
        return null;
    }

    fn handleNewRemoteConnection(self: *Daemon) !void {
        var tcp = self.tcp orelse return;
        const remote_client = try tcp.accept();

        const total_clients = self.clients.count() + self.remote_clients.count();
        if (total_clients >= self.config.max_clients) {
            log.warn("max clients reached, rejecting remote connection", .{});
            var client = remote_client;
            client.close();
            return;
        }

        const session = try self.allocator.create(RemoteSession);
        session.* = .{
            .client = remote_client,
            .id = self.next_remote_id,
            .state = .awaiting_hello,
            .sdcs_buffer = null,
        };
        self.next_remote_id += 1;

        try self.remote_clients.put(session.id, session);

        const addr_str = session.client.getAddrString();
        log.info("remote client {} connected from {s}", .{ session.id, std.mem.sliceTo(&addr_str, 0) });
    }

    fn handleRemoteClientMessage(self: *Daemon, session: *RemoteSession) !void {
        var msg = try session.client.readMessage(self.allocator) orelse return;
        defer msg.deinit(self.allocator);

        switch (session.state) {
            .awaiting_hello => {
                if (msg.header.msg_type != .hello) {
                    try self.sendRemoteError(session, .protocol_error, 0);
                    return error.ProtocolError;
                }
                try self.handleRemoteHello(session, msg.payload);
            },
            .connected => {
                try self.handleRemoteRequest(session, msg.header.msg_type, msg.payload);
            },
            .disconnecting => {},
        }
    }

    fn handleRemoteHello(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.HelloMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return error.InvalidPayload;
        }

        const hello = try protocol.HelloMsg.deserialize(payload.?);

        if (hello.version_major != protocol.PROTOCOL_VERSION_MAJOR) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return error.VersionMismatch;
        }

        var reply_buf: [protocol.HelloReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.HelloReplyMsg{
            .version_major = protocol.PROTOCOL_VERSION_MAJOR,
            .version_minor = protocol.PROTOCOL_VERSION_MINOR,
            .client_id = session.id,
            .server_flags = 1, // Flag 1 = remote connection (inline buffers)
        };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.hello_reply, &reply_buf);

        session.state = .connected;
        log.info("remote client {} completed handshake", .{session.id});
    }

    fn handleRemoteRequest(self: *Daemon, session: *RemoteSession, msg_type: protocol.MsgType, payload: ?[]u8) !void {
        switch (msg_type) {
            .create_surface => try self.handleRemoteCreateSurface(session, payload),
            .destroy_surface => try self.handleRemoteDestroySurface(session, payload),
            .attach_buffer_inline => try self.handleRemoteAttachBufferInline(session, payload),
            .commit => try self.handleRemoteCommit(session, payload),
            .set_visible => try self.handleRemoteSetVisible(session, payload),
            .set_z_order => try self.handleRemoteSetZOrder(session, payload),
            .sync => try self.handleRemoteSync(session, payload),
            .disconnect => {
                session.state = .disconnecting;
            },
            else => {
                log.warn("remote client {} sent unexpected message type: {}", .{ session.id, msg_type });
                try self.sendRemoteError(session, .invalid_message, 0);
            },
        }
    }

    fn handleRemoteCreateSurface(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.CreateSurfaceMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.CreateSurfaceMsg.deserialize(payload.?);

        const surface = self.surfaces.createSurface(session.id, msg.logical_width, msg.logical_height) catch {
            try self.sendRemoteError(session, .resource_limit, 0);
            return;
        };

        self.comp.onSurfaceCreated(surface.id) catch {};

        var reply_buf: [protocol.SurfaceCreatedMsg.SIZE]u8 = undefined;
        const reply = protocol.SurfaceCreatedMsg{ .surface_id = surface.id };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.surface_created, &reply_buf);

        log.debug("remote client {} created surface {}", .{ session.id, surface.id });
    }

    fn handleRemoteDestroySurface(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.DestroySurfaceMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.DestroySurfaceMsg.deserialize(payload.?);

        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        self.comp.onSurfaceDestroyed(msg.surface_id);
        self.surfaces.destroySurface(msg.surface_id);
        log.debug("remote client {} destroyed surface {}", .{ session.id, msg.surface_id });
    }

    fn handleRemoteAttachBufferInline(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.AttachBufferInlineMsg.HEADER_SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.AttachBufferInlineMsg.deserialize(payload.?);
        const expected_len = protocol.AttachBufferInlineMsg.HEADER_SIZE + msg.sdcs_length;

        if (payload.?.len < expected_len) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        // Store SDCS data for this session
        if (session.sdcs_buffer) |buf| self.allocator.free(buf);
        session.sdcs_buffer = try self.allocator.alloc(u8, msg.sdcs_length);
        @memcpy(session.sdcs_buffer.?, payload.?[protocol.AttachBufferInlineMsg.HEADER_SIZE..expected_len]);

        // Validate SDCS
        if (!sdcs_validator.validate(session.sdcs_buffer.?)) {
            try self.sendRemoteError(session, .validation_failed, msg.surface_id);
            self.allocator.free(session.sdcs_buffer.?);
            session.sdcs_buffer = null;
            return;
        }

        // Attach to surface
        self.surfaces.attachBuffer(msg.surface_id, session.sdcs_buffer.?) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };

        log.debug("remote client {} attached {} bytes to surface {}", .{ session.id, msg.sdcs_length, msg.surface_id });
    }

    fn handleRemoteCommit(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.CommitMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.CommitMsg.deserialize(payload.?);

        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        const frame_number = self.surfaces.commit(msg.surface_id) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };

        self.comp.onSurfaceCommit(msg.surface_id) catch {};

        var reply_buf: [protocol.FrameCompleteMsg.SIZE]u8 = undefined;
        const reply = protocol.FrameCompleteMsg{
            .surface_id = msg.surface_id,
            .frame_number = frame_number,
            .timestamp_ns = @intCast(std.time.nanoTimestamp()),
        };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.frame_complete, &reply_buf);

        log.debug("remote client {} committed surface {} frame {}", .{ session.id, msg.surface_id, frame_number });
    }

    fn handleRemoteSetVisible(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetVisibleMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.SetVisibleMsg.deserialize(payload.?);

        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        self.surfaces.setVisible(msg.surface_id, msg.visible != 0) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };
    }

    fn handleRemoteSetZOrder(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetZOrderMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.SetZOrderMsg.deserialize(payload.?);

        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        self.surfaces.setZOrder(msg.surface_id, msg.z_order) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };
    }

    fn handleRemoteSync(_: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SyncMsg.SIZE) {
            return error.InvalidPayload;
        }

        const msg = try protocol.SyncMsg.deserialize(payload.?);

        var reply_buf: [protocol.SyncDoneMsg.SIZE]u8 = undefined;
        const reply = protocol.SyncDoneMsg{ .sync_id = msg.sync_id };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.sync_done, &reply_buf);
    }

    fn sendRemoteError(self: *Daemon, session: *RemoteSession, code: protocol.ErrorCode, context: u32) !void {
        _ = self;
        var reply_buf: [protocol.ErrorReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.ErrorReplyMsg{ .code = code, .context = context };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.error_reply, &reply_buf);
    }

    fn disconnectRemoteClient(self: *Daemon, client_id: protocol.ClientId) void {
        if (self.remote_clients.fetchRemove(client_id)) |entry| {
            const session = entry.value;
            self.surfaces.removeClientSurfaces(client_id);
            if (session.sdcs_buffer) |buf| self.allocator.free(buf);
            session.client.close();
            self.allocator.destroy(session);
        }
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

        // Create surface in registry
        const surface = self.surfaces.createSurface(session.id, msg.logical_width, msg.logical_height) catch {
            try session.sendError(.resource_limit, 0);
            return;
        };
        try session.addSurface(surface.id, msg.logical_width, msg.logical_height);

        // Notify compositor
        self.comp.onSurfaceCreated(surface.id) catch {};

        // Send reply
        var reply_buf: [protocol.SurfaceCreatedMsg.SIZE]u8 = undefined;
        const reply = protocol.SurfaceCreatedMsg{ .surface_id = surface.id };
        reply.serialize(&reply_buf);
        try session.send(.surface_created, &reply_buf);

        log.debug("client {} created surface {}", .{ session.id, surface.id });
    }

    fn handleDestroySurface(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.DestroySurfaceMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.DestroySurfaceMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // Get dimensions for usage tracking before destroying
        if (self.surfaces.getSurface(msg.surface_id)) |surface| {
            session.removeSurface(msg.surface_id, surface.logical_width, surface.logical_height);
        }

        // Notify compositor
        self.comp.onSurfaceDestroyed(msg.surface_id);

        self.surfaces.destroySurface(msg.surface_id);
        log.debug("client {} destroyed surface {}", .{ session.id, msg.surface_id });
    }

    fn handleCommit(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.CommitMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.CommitMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // Mark surface as committed in registry
        const frame_number = self.surfaces.commit(msg.surface_id) catch {
            try session.sendError(.invalid_surface, msg.surface_id);
            return;
        };

        // Notify compositor of surface damage
        self.comp.onSurfaceCommit(msg.surface_id) catch {};

        // Send frame_complete
        var reply_buf: [protocol.FrameCompleteMsg.SIZE]u8 = undefined;
        const reply = protocol.FrameCompleteMsg{
            .surface_id = msg.surface_id,
            .frame_number = frame_number,
            .timestamp_ns = @intCast(std.time.nanoTimestamp()),
        };
        reply.serialize(&reply_buf);
        try session.send(.frame_complete, &reply_buf);

        log.debug("client {} committed surface {} frame {}", .{ session.id, msg.surface_id, frame_number });
    }

    fn handleSetVisible(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetVisibleMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SetVisibleMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        self.surfaces.setVisible(msg.surface_id, msg.visible != 0) catch {
            try session.sendError(.invalid_surface, msg.surface_id);
            return;
        };
        log.debug("client {} set surface {} visible={}", .{ session.id, msg.surface_id, msg.visible != 0 });
    }

    fn handleSetZOrder(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetZOrderMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SetZOrderMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.surfaces.isOwner(msg.surface_id, session.id)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        self.surfaces.setZOrder(msg.surface_id, msg.z_order) catch {
            try session.sendError(.invalid_surface, msg.surface_id);
            return;
        };
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
        // Clean up surfaces owned by this client
        self.surfaces.removeClientSurfaces(client_id);
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
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            const backend_name = args[i];
            if (std.mem.eql(u8, backend_name, "software")) {
                config.backend_type = .software;
            } else if (std.mem.eql(u8, backend_name, "headless")) {
                config.backend_type = .headless;
            } else if (std.mem.eql(u8, backend_name, "kms")) {
                config.backend_type = .kms;
            } else if (std.mem.eql(u8, backend_name, "x11")) {
                config.backend_type = .x11;
            } else if (std.mem.eql(u8, backend_name, "vulkan")) {
                config.backend_type = .vulkan;
            } else if (std.mem.eql(u8, backend_name, "wayland")) {
                config.backend_type = .wayland;
            } else {
                log.err("unknown backend: {s} (valid: software, headless, kms, x11, vulkan, wayland)", .{backend_name});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tcp")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            config.tcp_port = std.fmt.parseInt(u16, args[i], 10) catch {
                log.err("invalid TCP port: {s}", .{args[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--tcp-addr")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            // Parse IP address (simple dotted quad parsing)
            var parts: [4]u8 = undefined;
            var part_idx: usize = 0;
            var iter = std.mem.splitScalar(u8, args[i], '.');
            while (iter.next()) |part| {
                if (part_idx >= 4) {
                    log.err("invalid IP address: {s}", .{args[i]});
                    return error.InvalidArgument;
                }
                parts[part_idx] = std.fmt.parseInt(u8, part, 10) catch {
                    log.err("invalid IP address: {s}", .{args[i]});
                    return error.InvalidArgument;
                };
                part_idx += 1;
            }
            if (part_idx != 4) {
                log.err("invalid IP address: {s}", .{args[i]});
                return error.InvalidArgument;
            }
            config.tcp_addr = parts;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            log.info("semadrawd - SemaDraw compositor daemon", .{});
            log.info("Usage: semadrawd [OPTIONS]", .{});
            log.info("Options:", .{});
            log.info("  -s, --socket PATH     Socket path (default: {s})", .{protocol.DEFAULT_SOCKET_PATH});
            log.info("  -b, --backend TYPE    Backend type: software, headless, kms, x11, vulkan, wayland (default: software)", .{});
            log.info("  -t, --tcp PORT        Enable TCP remote connections on PORT (default: disabled)", .{});
            log.info("  --tcp-addr ADDR       TCP bind address (default: 0.0.0.0)", .{});
            log.info("  -h, --help            Show this help", .{});
            return;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    var daemon = try Daemon.init(allocator, config);
    defer daemon.deinit();

    try daemon.initCompositor();

    try daemon.run();
}
