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
    set_position = 0x0032,
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

    // Clipboard operations (0x005x)
    clipboard_set = 0x0050, // Client -> Daemon: set clipboard content
    clipboard_request = 0x0051, // Client -> Daemon: request clipboard content

    // Daemon -> Client input events (0x9xxx)
    key_press = 0x9001,
    mouse_event = 0x9002,

    // Daemon -> Client clipboard events (0x905x)
    clipboard_data = 0x9050, // Daemon -> Client: clipboard content
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

/// Set position request
pub const SetPositionMsg = extern struct {
    surface_id: SurfaceId,
    x: f32,
    y: f32,

    pub const SIZE: usize = 12;

    pub fn serialize(self: SetPositionMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], @bitCast(self.x), .little);
        std.mem.writeInt(u32, buf[8..12], @bitCast(self.y), .little);
    }

    pub fn deserialize(buf: []const u8) !SetPositionMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .x = @bitCast(std.mem.readInt(u32, buf[4..8], .little)),
            .y = @bitCast(std.mem.readInt(u32, buf[8..12], .little)),
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

/// Mouse event types
pub const MouseEventType = enum(u8) {
    press = 0,
    release = 1,
    motion = 2,
};

/// Mouse button identifiers
pub const MouseButtonId = enum(u8) {
    left = 0,
    middle = 1,
    right = 2,
    scroll_up = 3,
    scroll_down = 4,
    scroll_left = 5,
    scroll_right = 6,
    button4 = 7,
    button5 = 8,
};

/// Mouse event message
pub const MouseEventMsg = extern struct {
    surface_id: SurfaceId, // Target surface (focused surface)
    x: i32, // X coordinate in pixels
    y: i32, // Y coordinate in pixels
    button: MouseButtonId, // Button involved
    event_type: MouseEventType, // Press, release, or motion
    modifiers: u8, // Modifier state: bit 0=shift, bit 1=alt, bit 2=ctrl, bit 3=meta
    _reserved: u8 = 0,

    pub const SIZE: usize = 16;

    pub fn serialize(self: MouseEventMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(i32, buf[4..8], self.x, .little);
        std.mem.writeInt(i32, buf[8..12], self.y, .little);
        buf[12] = @intFromEnum(self.button);
        buf[13] = @intFromEnum(self.event_type);
        buf[14] = self.modifiers;
        buf[15] = self._reserved;
    }

    pub fn deserialize(buf: []const u8) !MouseEventMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .x = std.mem.readInt(i32, buf[4..8], .little),
            .y = std.mem.readInt(i32, buf[8..12], .little),
            .button = @enumFromInt(buf[12]),
            .event_type = @enumFromInt(buf[13]),
            .modifiers = buf[14],
            ._reserved = buf[15],
        };
    }
};

// ============================================================================
// Clipboard Messages
// ============================================================================

/// Clipboard selection type
pub const ClipboardSelection = enum(u8) {
    clipboard = 0, // CLIPBOARD (Ctrl+C/V)
    primary = 1, // PRIMARY (mouse selection)
};

/// Clipboard set message - client sets clipboard content
/// Variable length: header followed by text data
pub const ClipboardSetMsg = extern struct {
    selection: ClipboardSelection,
    _reserved: [3]u8 = .{ 0, 0, 0 },
    length: u32, // Length of text data that follows

    pub const HEADER_SIZE: usize = 8;

    pub fn serialize(self: ClipboardSetMsg, buf: []u8) void {
        std.debug.assert(buf.len >= HEADER_SIZE);
        buf[0] = @intFromEnum(self.selection);
        buf[1] = 0;
        buf[2] = 0;
        buf[3] = 0;
        std.mem.writeInt(u32, buf[4..8], self.length, .little);
    }

    pub fn deserialize(buf: []const u8) !ClipboardSetMsg {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
        return .{
            .selection = @enumFromInt(buf[0]),
            ._reserved = .{ buf[1], buf[2], buf[3] },
            .length = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

/// Clipboard request message - client requests clipboard content
pub const ClipboardRequestMsg = extern struct {
    selection: ClipboardSelection,
    _reserved: [3]u8 = .{ 0, 0, 0 },

    pub const SIZE: usize = 4;

    pub fn serialize(self: ClipboardRequestMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        buf[0] = @intFromEnum(self.selection);
        buf[1] = 0;
        buf[2] = 0;
        buf[3] = 0;
    }

    pub fn deserialize(buf: []const u8) !ClipboardRequestMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .selection = @enumFromInt(buf[0]),
            ._reserved = .{ buf[1], buf[2], buf[3] },
        };
    }
};

/// Clipboard data message - daemon sends clipboard content to client
/// Variable length: header followed by text data
pub const ClipboardDataMsg = extern struct {
    selection: ClipboardSelection,
    _reserved: [3]u8 = .{ 0, 0, 0 },
    length: u32, // Length of text data that follows

    pub const HEADER_SIZE: usize = 8;

    pub fn serialize(self: ClipboardDataMsg, buf: []u8) void {
        std.debug.assert(buf.len >= HEADER_SIZE);
        buf[0] = @intFromEnum(self.selection);
        buf[1] = 0;
        buf[2] = 0;
        buf[3] = 0;
        std.mem.writeInt(u32, buf[4..8], self.length, .little);
    }

    pub fn deserialize(buf: []const u8) !ClipboardDataMsg {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
        return .{
            .selection = @enumFromInt(buf[0]),
            ._reserved = .{ buf[1], buf[2], buf[3] },
            .length = std.mem.readInt(u32, buf[4..8], .little),
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

// ============================================================================
// Extended Protocol Validation Tests (P3.3)
// ============================================================================

test "AttachBufferMsg serialize/deserialize roundtrip" {
    const msg = AttachBufferMsg{
        .surface_id = 42,
        .shm_size = 1024 * 1024,
        .sdcs_offset = 0,
        .sdcs_length = 4096,
    };
    var buf: [AttachBufferMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try AttachBufferMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
    try std.testing.expectEqual(msg.shm_size, decoded.shm_size);
    try std.testing.expectEqual(msg.sdcs_offset, decoded.sdcs_offset);
    try std.testing.expectEqual(msg.sdcs_length, decoded.sdcs_length);
}

test "HelloReplyMsg serialize/deserialize roundtrip" {
    const msg = HelloReplyMsg{
        .version_major = 0,
        .version_minor = 1,
        .client_id = 12345,
        .server_flags = 0xFF,
    };
    var buf: [HelloReplyMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try HelloReplyMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.version_major, decoded.version_major);
    try std.testing.expectEqual(msg.version_minor, decoded.version_minor);
    try std.testing.expectEqual(msg.client_id, decoded.client_id);
    try std.testing.expectEqual(msg.server_flags, decoded.server_flags);
}

test "KeyPressMsg serialize/deserialize roundtrip" {
    const msg = KeyPressMsg{
        .surface_id = 1,
        .key_code = 0x1E, // KEY_A
        .modifiers = KeyPressMsg.MOD_SHIFT | KeyPressMsg.MOD_CTRL,
        .pressed = 1,
    };
    var buf: [KeyPressMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try KeyPressMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
    try std.testing.expectEqual(msg.key_code, decoded.key_code);
    try std.testing.expectEqual(msg.modifiers, decoded.modifiers);
    try std.testing.expectEqual(msg.pressed, decoded.pressed);
}

test "MouseEventMsg serialize/deserialize roundtrip" {
    const msg = MouseEventMsg{
        .surface_id = 2,
        .x = -100,
        .y = 200,
        .button = .left,
        .event_type = .press,
        .modifiers = 0,
    };
    var buf: [MouseEventMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try MouseEventMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
    try std.testing.expectEqual(msg.x, decoded.x);
    try std.testing.expectEqual(msg.y, decoded.y);
    try std.testing.expectEqual(msg.button, decoded.button);
    try std.testing.expectEqual(msg.event_type, decoded.event_type);
}

test "ErrorReplyMsg serialize/deserialize roundtrip" {
    const msg = ErrorReplyMsg{
        .code = .invalid_surface,
        .context = 999,
    };
    var buf: [ErrorReplyMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try ErrorReplyMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.code, decoded.code);
    try std.testing.expectEqual(msg.context, decoded.context);
}

test "ClipboardSetMsg serialize/deserialize roundtrip" {
    const msg = ClipboardSetMsg{
        .selection = .primary,
        .length = 1024,
    };
    var buf: [ClipboardSetMsg.HEADER_SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try ClipboardSetMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.selection, decoded.selection);
    try std.testing.expectEqual(msg.length, decoded.length);
}

test "reply message type convention" {
    // Replies use 0x8xxx (high bit set)
    try std.testing.expect(@intFromEnum(MsgType.hello_reply) & 0x8000 != 0);
    try std.testing.expect(@intFromEnum(MsgType.surface_created) & 0x8000 != 0);
    try std.testing.expect(@intFromEnum(MsgType.error_reply) & 0x8000 != 0);
    try std.testing.expect(@intFromEnum(MsgType.sync_done) & 0x8000 != 0);

    // Requests use 0x0xxx (high bit clear)
    try std.testing.expect(@intFromEnum(MsgType.hello) & 0x8000 == 0);
    try std.testing.expect(@intFromEnum(MsgType.create_surface) & 0x8000 == 0);
    try std.testing.expect(@intFromEnum(MsgType.disconnect) & 0x8000 == 0);

    // Events use 0x9xxx
    try std.testing.expect(@intFromEnum(MsgType.key_press) >= 0x9000);
    try std.testing.expect(@intFromEnum(MsgType.mouse_event) >= 0x9000);
}

test "message type values match protocol spec" {
    // Verify against shared/protocol_constants.json values
    try std.testing.expectEqual(@as(u16, 0x0001), @intFromEnum(MsgType.hello));
    try std.testing.expectEqual(@as(u16, 0x0010), @intFromEnum(MsgType.create_surface));
    try std.testing.expectEqual(@as(u16, 0x0011), @intFromEnum(MsgType.destroy_surface));
    try std.testing.expectEqual(@as(u16, 0x0020), @intFromEnum(MsgType.attach_buffer));
    try std.testing.expectEqual(@as(u16, 0x0021), @intFromEnum(MsgType.commit));
    try std.testing.expectEqual(@as(u16, 0x0040), @intFromEnum(MsgType.sync));
    try std.testing.expectEqual(@as(u16, 0x00F0), @intFromEnum(MsgType.disconnect));

    try std.testing.expectEqual(@as(u16, 0x8001), @intFromEnum(MsgType.hello_reply));
    try std.testing.expectEqual(@as(u16, 0x8010), @intFromEnum(MsgType.surface_created));
    try std.testing.expectEqual(@as(u16, 0x80F0), @intFromEnum(MsgType.error_reply));

    try std.testing.expectEqual(@as(u16, 0x9001), @intFromEnum(MsgType.key_press));
    try std.testing.expectEqual(@as(u16, 0x9002), @intFromEnum(MsgType.mouse_event));
}

test "MsgHeader size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), MsgHeader.SIZE);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(MsgHeader));
}

test "error code values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(ErrorCode.none));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(ErrorCode.invalid_message));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(ErrorCode.validation_failed));
}
