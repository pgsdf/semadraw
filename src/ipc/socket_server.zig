const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");

/// Unix domain socket server for semadrawd
pub const SocketServer = struct {
    fd: posix.socket_t,
    path: []const u8,

    pub const AcceptError = posix.AcceptError || error{Unexpected};

    /// Bind and listen on a Unix domain socket
    pub fn bind(path: []const u8) !SocketServer {
        // Create socket
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        // Remove existing socket file if present
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Bind to path
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Set socket permissions (owner+group read/write)
        // Mode 0660 = rw-rw----
        posix.fchmodat(posix.AT.FDCWD, path, 0o660, 0) catch {};

        // Listen with reasonable backlog
        try posix.listen(fd, 16);

        return .{
            .fd = fd,
            .path = path,
        };
    }

    /// Accept a new client connection
    pub fn accept(self: *SocketServer) AcceptError!posix.socket_t {
        const client_fd = try posix.accept(self.fd, null, null, posix.SOCK.CLOEXEC);
        return client_fd;
    }

    /// Get the file descriptor for use with kqueue/poll
    pub fn getFd(self: *SocketServer) posix.socket_t {
        return self.fd;
    }

    /// Close the server socket and remove the socket file
    pub fn deinit(self: *SocketServer) void {
        posix.close(self.fd);
        std.fs.cwd().deleteFile(self.path) catch {};
    }
};

/// Client connection wrapper with buffered I/O
pub const ClientSocket = struct {
    fd: posix.socket_t,
    recv_buf: [8192]u8,
    recv_len: usize,

    pub fn init(fd: posix.socket_t) ClientSocket {
        return .{
            .fd = fd,
            .recv_buf = undefined,
            .recv_len = 0,
        };
    }

    /// Read a complete message (header + payload)
    /// Returns null if not enough data available yet
    pub fn readMessage(self: *ClientSocket, allocator: std.mem.Allocator) !?Message {
        // Try to read more data
        const space = self.recv_buf.len - self.recv_len;
        if (space > 0) {
            const n = posix.read(self.fd, self.recv_buf[self.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n == 0 and self.recv_len == 0) return error.ConnectionClosed;
            self.recv_len += n;
        }

        // Check if we have a complete header
        if (self.recv_len < protocol.MsgHeader.SIZE) return null;

        const header = try protocol.MsgHeader.deserialize(self.recv_buf[0..protocol.MsgHeader.SIZE]);
        const total_len = protocol.MsgHeader.SIZE + header.length;

        // Check if we have the complete message
        if (self.recv_len < total_len) return null;

        // Extract payload
        var payload: ?[]u8 = null;
        if (header.length > 0) {
            payload = try allocator.alloc(u8, header.length);
            @memcpy(payload.?, self.recv_buf[protocol.MsgHeader.SIZE..total_len]);
        }

        // Shift remaining data
        if (self.recv_len > total_len) {
            std.mem.copyForwards(u8, self.recv_buf[0..], self.recv_buf[total_len..self.recv_len]);
        }
        self.recv_len -= total_len;

        return .{
            .header = header,
            .payload = payload,
        };
    }

    /// Send a message
    pub fn sendMessage(self: *ClientSocket, msg_type: protocol.MsgType, payload: []const u8) !void {
        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };

        var hdr_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        header.serialize(&hdr_buf);

        // Send header
        _ = try posix.write(self.fd, &hdr_buf);

        // Send payload
        if (payload.len > 0) {
            _ = try posix.write(self.fd, payload);
        }
    }

    /// Send a message with a file descriptor (SCM_RIGHTS)
    pub fn sendMessageWithFd(self: *ClientSocket, msg_type: protocol.MsgType, payload: []const u8, fd_to_send: posix.fd_t) !void {
        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };

        var hdr_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        header.serialize(&hdr_buf);

        // Combine header and payload for sendmsg
        var iov = [_]posix.iovec_const{
            .{ .base = &hdr_buf, .len = hdr_buf.len },
            .{ .base = payload.ptr, .len = payload.len },
        };

        // Set up control message for SCM_RIGHTS
        var cmsg_buf: [posix.CMSG_SPACE(@sizeOf(posix.fd_t))]u8 align(@alignOf(posix.cmsghdr)) = undefined;
        const cmsg: *posix.cmsghdr = @ptrCast(&cmsg_buf);
        cmsg.level = posix.SOL.SOCKET;
        cmsg.type = posix.SCM.RIGHTS;
        cmsg.len = posix.CMSG_LEN(@sizeOf(posix.fd_t));

        const fd_ptr: *posix.fd_t = @ptrCast(@alignCast(posix.CMSG_DATA(cmsg)));
        fd_ptr.* = fd_to_send;

        var msg = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &cmsg_buf,
            .controllen = cmsg_buf.len,
            .flags = 0,
        };

        _ = try posix.sendmsg(self.fd, &msg, 0);
    }

    /// Receive a message that may include a file descriptor
    pub fn recvMessageWithFd(self: *ClientSocket, allocator: std.mem.Allocator) !?MessageWithFd {
        // For simplicity, we'll handle this when we have a complete message
        const maybe_msg = try self.readMessage(allocator);
        if (maybe_msg) |msg| {
            // TODO: Implement fd receiving via recvmsg when needed
            return .{
                .message = msg,
                .fd = null,
            };
        }
        return null;
    }

    pub fn close(self: *ClientSocket) void {
        posix.close(self.fd);
    }

    pub fn getFd(self: *ClientSocket) posix.socket_t {
        return self.fd;
    }
};

/// Parsed message
pub const Message = struct {
    header: protocol.MsgHeader,
    payload: ?[]u8,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.payload) |p| allocator.free(p);
    }
};

/// Message with optional file descriptor
pub const MessageWithFd = struct {
    message: Message,
    fd: ?posix.fd_t,

    pub fn deinit(self: *MessageWithFd, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        if (self.fd) |f| posix.close(f);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SocketServer can be created with temp path" {
    const path = "/tmp/semadraw_test.sock";
    var server = try SocketServer.bind(path);
    defer server.deinit();

    try std.testing.expect(server.fd >= 0);
}

test "ClientSocket message serialization" {
    // This is a unit test for the message format, not actual socket I/O
    var buf: [protocol.MsgHeader.SIZE + protocol.HelloMsg.SIZE]u8 = undefined;

    const header = protocol.MsgHeader{
        .msg_type = .hello,
        .flags = 0,
        .length = protocol.HelloMsg.SIZE,
    };
    header.serialize(buf[0..protocol.MsgHeader.SIZE]);

    const hello = protocol.HelloMsg.init();
    hello.serialize(buf[protocol.MsgHeader.SIZE..]);

    // Verify header
    const decoded_hdr = try protocol.MsgHeader.deserialize(&buf);
    try std.testing.expectEqual(protocol.MsgType.hello, decoded_hdr.msg_type);
    try std.testing.expectEqual(@as(u32, protocol.HelloMsg.SIZE), decoded_hdr.length);
}
