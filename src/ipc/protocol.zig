const std = @import("std");

/// SemaDraw IPC Protocol
///
/// Wire format for communication between clients and semadrawd.
/// All multi-byte values are little-endian.

pub const PROTOCOL_VERSION_MAJOR: u16 = 0;
pub const PROTOCOL_VERSION_MINOR: u16 = 1;

/// Default socket path
pub const DEFAULT_SOCKET_PATH = "/var/run/semadraw.sock";

/// Default TCP port for remote connections
pub const DEFAULT_TCP_PORT: u16 = 7234;

/// Surface identifier (opaque handle)
pub const SurfaceId = u32;

/// Client identifier (assigned by daemon)
pub const ClientId = u32;

/// Message types
pub const MsgType = enum(u16) {
    // Client -> Daemon requests (0x0xxx)
    hello = 0x0001,
    create_surface = 0x0010,
    destroy_surface = 0x0011,
    attach_buffer = 0x0020,
    commit = 0x0021,
    set_visible = 0x0030,
    set_z_order = 0x0031,
    sync = 0x0040,
    disconnect = 0x00F0,

    // Remote transport messages (for network connections without FD passing)
    attach_buffer_inline = 0x0022, // SDCS data sent inline in message payload

    // Daemon -> Client responses (0x8xxx)
    hello_reply = 0x8001,
    surface_created = 0x8010,
    surface_destroyed = 0x8011,
    buffer_released = 0x8020,
    frame_complete = 0x8021,
    sync_done = 0x8040,
    error_reply = 0x80F0,

    // Daemon -> Client input events (0x9xxx)
    key_press = 0x9001,
};

/// Message header (8 bytes, always present)
pub const MsgHeader = extern struct {
    msg_type: MsgType,
    flags: u16,
    length: u32, // Payload length (excluding this header)

    pub const SIZE: usize = 8;

    pub fn serialize(self: MsgHeader, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u16, buf[0..2], @intFromEnum(self.msg_type), .little);
        std.mem.writeInt(u16, buf[2..4], self.flags, .little);
        std.mem.writeInt(u32, buf[4..8], self.length, .little);
    }

    pub fn deserialize(buf: []const u8) !MsgHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;
        const type_val = std.mem.readInt(u16, buf[0..2], .little);
        return .{
            .msg_type = std.meta.intToEnum(MsgType, type_val) catch return error.InvalidMsgType,
            .flags = std.mem.readInt(u16, buf[2..4], .little),
            .length = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

// ============================================================================
// Client -> Daemon Messages
// ============================================================================

/// Hello request - protocol version negotiation
pub const HelloMsg = extern struct {
    version_major: u16,
    version_minor: u16,
    client_flags: u32, // Reserved

    pub const SIZE: usize = 8;

    pub fn init() HelloMsg {
        return .{
            .version_major = PROTOCOL_VERSION_MAJOR,
            .version_minor = PROTOCOL_VERSION_MINOR,
            .client_flags = 0,
        };
    }

    pub fn serialize(self: HelloMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u16, buf[0..2], self.version_major, .little);
        std.mem.writeInt(u16, buf[2..4], self.version_minor, .little);
        std.mem.writeInt(u32, buf[4..8], self.client_flags, .little);
    }

    pub fn deserialize(buf: []const u8) !HelloMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .version_major = std.mem.readInt(u16, buf[0..2], .little),
            .version_minor = std.mem.readInt(u16, buf[2..4], .little),
            .client_flags = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

/// Create surface request
pub const CreateSurfaceMsg = extern struct {
    logical_width: f32,
    logical_height: f32,
    scale: f32,
    flags: u32, // Reserved

    pub const SIZE: usize = 16;

    pub fn serialize(self: CreateSurfaceMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        @memcpy(buf[0..4], std.mem.asBytes(&self.logical_width));
        @memcpy(buf[4..8], std.mem.asBytes(&self.logical_height));
        @memcpy(buf[8..12], std.mem.asBytes(&self.scale));
        std.mem.writeInt(u32, buf[12..16], self.flags, .little);
    }

    pub fn deserialize(buf: []const u8) !CreateSurfaceMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .logical_width = @bitCast(std.mem.readInt(u32, buf[0..4], .little)),
            .logical_height = @bitCast(std.mem.readInt(u32, buf[4..8], .little)),
            .scale = @bitCast(std.mem.readInt(u32, buf[8..12], .little)),
            .flags = std.mem.readInt(u32, buf[12..16], .little),
        };
    }
};

/// Destroy surface request
pub const DestroySurfaceMsg = extern struct {
    surface_id: SurfaceId,

    pub const SIZE: usize = 4;

    pub fn serialize(self: DestroySurfaceMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !DestroySurfaceMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Attach buffer request (file descriptor passed via SCM_RIGHTS)
pub const AttachBufferMsg = extern struct {
    surface_id: SurfaceId,
    shm_size: u64,
    sdcs_offset: u64,
    sdcs_length: u64,

    pub const SIZE: usize = 28;

    pub fn serialize(self: AttachBufferMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u64, buf[4..12], self.shm_size, .little);
        std.mem.writeInt(u64, buf[12..20], self.sdcs_offset, .little);
        std.mem.writeInt(u64, buf[20..28], self.sdcs_length, .little);
    }

    pub fn deserialize(buf: []const u8) !AttachBufferMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .shm_size = std.mem.readInt(u64, buf[4..12], .little),
            .sdcs_offset = std.mem.readInt(u64, buf[12..20], .little),
            .sdcs_length = std.mem.readInt(u64, buf[20..28], .little),
        };
    }
};

/// Attach buffer inline request (for remote connections without FD passing)
/// The SDCS data follows immediately after the header in the payload
pub const AttachBufferInlineMsg = extern struct {
    surface_id: SurfaceId,
    sdcs_length: u64, // Length of SDCS data that follows this header
    flags: u32, // Reserved

    pub const HEADER_SIZE: usize = 16;

    pub fn serialize(self: AttachBufferInlineMsg, buf: []u8) void {
        std.debug.assert(buf.len >= HEADER_SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u64, buf[4..12], self.sdcs_length, .little);
        std.mem.writeInt(u32, buf[12..16], self.flags, .little);
    }

    pub fn deserialize(buf: []const u8) !AttachBufferInlineMsg {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .sdcs_length = std.mem.readInt(u64, buf[4..12], .little),
            .flags = std.mem.readInt(u32, buf[12..16], .little),
        };
    }
};

/// Commit request - present the attached buffer
pub const CommitMsg = extern struct {
    surface_id: SurfaceId,
    flags: u32, // Reserved

    pub const SIZE: usize = 8;

    pub fn serialize(self: CommitMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], self.flags, .little);
    }

    pub fn deserialize(buf: []const u8) !CommitMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .flags = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

/// Set visibility request
pub const SetVisibleMsg = extern struct {
    surface_id: SurfaceId,
    visible: u32, // 0 = hidden, 1 = visible

    pub const SIZE: usize = 8;

    pub fn serialize(self: SetVisibleMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], self.visible, .little);
    }

    pub fn deserialize(buf: []const u8) !SetVisibleMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .visible = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

/// Set Z-order request
pub const SetZOrderMsg = extern struct {
    surface_id: SurfaceId,
    z_order: i32,

    pub const SIZE: usize = 8;

    pub fn serialize(self: SetZOrderMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(i32, buf[4..8], self.z_order, .little);
    }

    pub fn deserialize(buf: []const u8) !SetZOrderMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .z_order = std.mem.readInt(i32, buf[4..8], .little),
        };
    }
};

/// Sync request (barrier)
pub const SyncMsg = extern struct {
    sync_id: u32,

    pub const SIZE: usize = 4;

    pub fn serialize(self: SyncMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.sync_id, .little);
    }

    pub fn deserialize(buf: []const u8) !SyncMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .sync_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

// ============================================================================
// Daemon -> Client Messages
// ============================================================================

/// Hello reply - confirms connection and capabilities
pub const HelloReplyMsg = extern struct {
    version_major: u16,
    version_minor: u16,
    client_id: ClientId,
    server_flags: u32, // Capability flags

    pub const SIZE: usize = 12;

    pub fn serialize(self: HelloReplyMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u16, buf[0..2], self.version_major, .little);
        std.mem.writeInt(u16, buf[2..4], self.version_minor, .little);
        std.mem.writeInt(u32, buf[4..8], self.client_id, .little);
        std.mem.writeInt(u32, buf[8..12], self.server_flags, .little);
    }

    pub fn deserialize(buf: []const u8) !HelloReplyMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .version_major = std.mem.readInt(u16, buf[0..2], .little),
            .version_minor = std.mem.readInt(u16, buf[2..4], .little),
            .client_id = std.mem.readInt(u32, buf[4..8], .little),
            .server_flags = std.mem.readInt(u32, buf[8..12], .little),
        };
    }
};

/// Surface created reply
pub const SurfaceCreatedMsg = extern struct {
    surface_id: SurfaceId,

    pub const SIZE: usize = 4;

    pub fn serialize(self: SurfaceCreatedMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !SurfaceCreatedMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Buffer released - client can reuse the buffer
pub const BufferReleasedMsg = extern struct {
    surface_id: SurfaceId,

    pub const SIZE: usize = 4;

    pub fn serialize(self: BufferReleasedMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !BufferReleasedMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Frame complete - frame was presented
pub const FrameCompleteMsg = extern struct {
    surface_id: SurfaceId,
    frame_number: u64,
    timestamp_ns: u64, // Presentation timestamp (nanoseconds since epoch)

    pub const SIZE: usize = 20;

    pub fn serialize(self: FrameCompleteMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u64, buf[4..12], self.frame_number, .little);
        std.mem.writeInt(u64, buf[12..20], self.timestamp_ns, .little);
    }

    pub fn deserialize(buf: []const u8) !FrameCompleteMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .frame_number = std.mem.readInt(u64, buf[4..12], .little),
            .timestamp_ns = std.mem.readInt(u64, buf[12..20], .little),
        };
    }
};

/// Sync done reply
pub const SyncDoneMsg = extern struct {
    sync_id: u32,

    pub const SIZE: usize = 4;

    pub fn serialize(self: SyncDoneMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.sync_id, .little);
    }

    pub fn deserialize(buf: []const u8) !SyncDoneMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .sync_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Error codes
pub const ErrorCode = enum(u32) {
    none = 0,
    invalid_message = 1,
    invalid_surface = 2,
    invalid_buffer = 3,
    permission_denied = 4,
    resource_limit = 5,
    protocol_error = 6,
    internal_error = 7,
    validation_failed = 8,
};

/// Error reply
pub const ErrorReplyMsg = extern struct {
    code: ErrorCode,
    context: u32, // Context-specific value (e.g., surface_id)

    pub const SIZE: usize = 8;

    pub fn serialize(self: ErrorReplyMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], @intFromEnum(self.code), .little);
        std.mem.writeInt(u32, buf[4..8], self.context, .little);
    }

    pub fn deserialize(buf: []const u8) !ErrorReplyMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        const code_val = std.mem.readInt(u32, buf[0..4], .little);
        return .{
            .code = std.meta.intToEnum(ErrorCode, code_val) catch .internal_error,
            .context = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

// ============================================================================
// Input Events
// ============================================================================

/// Key press/release event
pub const KeyPressMsg = extern struct {
    surface_id: SurfaceId, // Target surface (focused surface)
    key_code: u32, // Platform key code (evdev on Linux)
    modifiers: u8, // Modifier state: bit 0=shift, bit 1=alt, bit 2=ctrl, bit 3=meta
    pressed: u8, // 1 = pressed, 0 = released
    _reserved: u16 = 0,

    pub const SIZE: usize = 12;

    // Modifier bit masks
    pub const MOD_SHIFT: u8 = 0x01;
    pub const MOD_ALT: u8 = 0x02;
    pub const MOD_CTRL: u8 = 0x04;
    pub const MOD_META: u8 = 0x08;

    pub fn serialize(self: KeyPressMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], self.key_code, .little);
        buf[8] = self.modifiers;
        buf[9] = self.pressed;
        std.mem.writeInt(u16, buf[10..12], self._reserved, .little);
    }

    pub fn deserialize(buf: []const u8) !KeyPressMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .key_code = std.mem.readInt(u32, buf[4..8], .little),
            .modifiers = buf[8],
            .pressed = buf[9],
            ._reserved = std.mem.readInt(u16, buf[10..12], .little),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MsgHeader serialize/deserialize roundtrip" {
    const hdr = MsgHeader{
        .msg_type = .create_surface,
        .flags = 0x1234,
        .length = 16,
    };
    var buf: [MsgHeader.SIZE]u8 = undefined;
    hdr.serialize(&buf);
    const decoded = try MsgHeader.deserialize(&buf);
    try std.testing.expectEqual(hdr.msg_type, decoded.msg_type);
    try std.testing.expectEqual(hdr.flags, decoded.flags);
    try std.testing.expectEqual(hdr.length, decoded.length);
}

test "CreateSurfaceMsg serialize/deserialize roundtrip" {
    const msg = CreateSurfaceMsg{
        .logical_width = 1280.0,
        .logical_height = 720.0,
        .scale = 2.0,
        .flags = 0,
    };
    var buf: [CreateSurfaceMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try CreateSurfaceMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.logical_width, decoded.logical_width);
    try std.testing.expectEqual(msg.logical_height, decoded.logical_height);
    try std.testing.expectEqual(msg.scale, decoded.scale);
}

test "HelloMsg version check" {
    const msg = HelloMsg.init();
    try std.testing.expectEqual(PROTOCOL_VERSION_MAJOR, msg.version_major);
    try std.testing.expectEqual(PROTOCOL_VERSION_MINOR, msg.version_minor);
}
