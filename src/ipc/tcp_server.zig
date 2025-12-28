const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");

/// TCP server for remote semadraw connections
pub const TcpServer = struct {
    fd: posix.socket_t,
    port: u16,
    bound_addr: posix.sockaddr.in,

    pub const AcceptError = posix.AcceptError || error{Unexpected};

    /// Bind and listen on a TCP port
    pub fn bind(port: u16) !TcpServer {
        return bindAddr(.{ 0, 0, 0, 0 }, port);
    }

    /// Bind and listen on a specific address and port
    pub fn bindAddr(addr: [4]u8, port: u16) !TcpServer {
        // Create socket
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        // Enable address reuse
        const optval: c_int = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));

        // Bind to address
        var bind_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.bytesToValue(u32, &addr),
            .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };

        try posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in));

        // Listen with reasonable backlog
        try posix.listen(fd, 16);

        return .{
            .fd = fd,
            .port = port,
            .bound_addr = bind_addr,
        };
    }

    /// Accept a new client connection
    pub fn accept(self: *TcpServer) AcceptError!RemoteClient {
        var client_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const client_fd = try posix.accept(self.fd, @ptrCast(&client_addr), &addr_len, posix.SOCK.CLOEXEC);

        return RemoteClient.init(client_fd, client_addr);
    }

    /// Get the file descriptor for use with poll/kqueue
    pub fn getFd(self: *TcpServer) posix.socket_t {
        return self.fd;
    }

    /// Close the server socket
    pub fn deinit(self: *TcpServer) void {
        posix.close(self.fd);
    }
};

/// Remote client connection with buffered I/O
pub const RemoteClient = struct {
    fd: posix.socket_t,
    addr: posix.sockaddr.in,
    recv_buf: [65536]u8, // Larger buffer for inline SDCS data
    recv_len: usize,

    pub fn init(fd: posix.socket_t, addr: posix.sockaddr.in) RemoteClient {
        return .{
            .fd = fd,
            .addr = addr,
            .recv_buf = undefined,
            .recv_len = 0,
        };
    }

    /// Get client IP address as string
    pub fn getAddrString(self: *const RemoteClient) [16]u8 {
        var buf: [16]u8 = undefined;
        const addr_bytes = std.mem.toBytes(self.addr.addr);
        _ = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{
            addr_bytes[0],
            addr_bytes[1],
            addr_bytes[2],
            addr_bytes[3],
        }) catch {
            @memcpy(buf[0..7], "0.0.0.0");
            buf[7] = 0;
        };
        return buf;
    }

    /// Read a complete message (header + payload)
    /// Returns null if not enough data available yet
    pub fn readMessage(self: *RemoteClient, allocator: std.mem.Allocator) !?Message {
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

        // Safety check for message size
        if (total_len > self.recv_buf.len) {
            return error.MessageTooLarge;
        }

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
    pub fn sendMessage(self: *RemoteClient, msg_type: protocol.MsgType, payload: []const u8) !void {
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

    pub fn close(self: *RemoteClient) void {
        posix.close(self.fd);
    }

    pub fn getFd(self: *RemoteClient) posix.socket_t {
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

// ============================================================================
// Tests
// ============================================================================

test "TcpServer can be created" {
    // Use a high port that's less likely to conflict
    var server = TcpServer.bind(0) catch |err| {
        // Skip test if binding fails (e.g., in restricted environment)
        if (err == error.AddressInUse or err == error.AccessDenied) return;
        return err;
    };
    defer server.deinit();

    try std.testing.expect(server.fd >= 0);
}

test "RemoteClient address string" {
    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, 1234),
        .addr = std.mem.bytesToValue(u32, &[4]u8{ 192, 168, 1, 100 }),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const client = RemoteClient.init(-1, addr);
    const addr_str = client.getAddrString();

    // Check that the string starts with the expected address
    try std.testing.expect(addr_str[0] == '1');
    try std.testing.expect(addr_str[1] == '9');
    try std.testing.expect(addr_str[2] == '2');
}
