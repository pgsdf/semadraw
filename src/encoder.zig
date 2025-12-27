const std = @import("std");
const sdcs = @import("sdcs.zig");

fn putU16LE(buf: []u8, off: *usize, v: u16) void {
    buf[off.* + 0] = @intCast(v & 0xff);
    buf[off.* + 1] = @intCast((v >> 8) & 0xff);
    off.* += 2;
}

fn putU32LE(buf: []u8, off: *usize, v: u32) void {
    buf[off.* + 0] = @intCast(v & 0xff);
    buf[off.* + 1] = @intCast((v >> 8) & 0xff);
    buf[off.* + 2] = @intCast((v >> 16) & 0xff);
    buf[off.* + 3] = @intCast((v >> 24) & 0xff);
    off.* += 4;
}

fn putF32LE(buf: []u8, off: *usize, v: f32) void {
    const u: u32 = @bitCast(v);
    putU32LE(buf, off, u);
}

fn appendZeros(list: *std.ArrayList(u8), gpa: std.mem.Allocator, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try list.append(gpa, 0);
}

// NOTE: Zig 0.15+ std.ArrayList APIs require an allocator per call.
// Use appendCmdAlloc for all command emission.

fn appendCmdAlloc(list: *std.ArrayList(u8), gpa: std.mem.Allocator, opcode: u16, payload: []const u8) !void {
    var hdr_bytes: [8]u8 = undefined;
    var off: usize = 0;
    putU16LE(hdr_bytes[0..], &off, opcode);
    putU16LE(hdr_bytes[0..], &off, 0); // flags
    putU32LE(hdr_bytes[0..], &off, @intCast(payload.len));

    try list.appendSlice(gpa, hdr_bytes[0..]);
    if (payload.len != 0) try list.appendSlice(gpa, payload);

    const record_bytes = @sizeOf(sdcs.CmdHdr) + payload.len;
    const pad = sdcs.pad8Len(record_bytes);
    if (pad != 0) try appendZeros(list, gpa, pad);
}

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    cmds: std.ArrayList(u8),

    pub const Rect = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    };

    pub const BlendMode = struct {
        pub const SrcOver: u32 = 0;
        pub const Src: u32 = 1;
        pub const Clear: u32 = 2;
        pub const Add: u32 = 3;
    };

    pub const StrokeJoin = enum(u32) {
        Miter = 0,
        Bevel = 1,
        Round = 2,
    };

    pub const StrokeCap = enum(u32) {
        Butt = 0,
        Square = 1,
        Round = 2,
    };

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator, .cmds = std.ArrayList(u8){} };
    }

    pub fn deinit(self: *Encoder) void {
        self.cmds.deinit(self.allocator);
    }

    pub fn reset(self: *Encoder) !void {
        // Start a new command stream.
        self.cmds.items.len = 0;
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.RESET, &[_]u8{});
    }

    /// Return the encoded command stream as an owned byte slice.
    /// Caller owns the returned memory.
    pub fn finishBytes(self: *Encoder) ![]u8 {
        return try self.cmds.toOwnedSlice(self.allocator);
    }

    pub fn setClipRects(self: *Encoder, rects: []const Rect) !void {
        // Payload: u32 count (little endian) followed by count rects (x,y,w,h) as f32 LE.
        // We cap count for safety in this early implementation.
        if (rects.len > 1024) return error.OutOfMemory;

        const payload_len: usize = 4 + rects.len * 16;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putU32LE(payload, &off, @intCast(rects.len));
        for (rects) |rc| {
            putF32LE(payload, &off, rc.x);
            putF32LE(payload, &off, rc.y);
            putF32LE(payload, &off, rc.w);
            putF32LE(payload, &off, rc.h);
        }

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_CLIP_RECTS, payload);
    }

    pub fn clearClip(self: *Encoder) !void {
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.CLEAR_CLIP, &[_]u8{});
    }

    pub fn strokeRect(
        self: *Encoder,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        stroke_width: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) !void {
        if (!(stroke_width > 0.0)) return error.InvalidArgument;

        var payload: [36]u8 = undefined;
        var off: usize = 0;

        putF32LE(payload[0..], &off, x);
        putF32LE(payload[0..], &off, y);
        putF32LE(payload[0..], &off, w);
        putF32LE(payload[0..], &off, h);
        putF32LE(payload[0..], &off, stroke_width);
        putF32LE(payload[0..], &off, r);
        putF32LE(payload[0..], &off, g);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, a);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.STROKE_RECT, payload[0..]);
    }

    pub fn setBlend(self: *Encoder, mode: u32) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putU32LE(payload[0..], &off, mode);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_BLEND, payload[0..]);
    }

    pub fn setTransform2D(self: *Encoder, a: f32, b: f32, c: f32, d: f32, e: f32, f: f32) !void {
        // Payload: 6 f32 values (a b c d e f), little endian
        var payload: [24]u8 = undefined;
        var off: usize = 0;
        putF32LE(payload[0..], &off, a);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, c);
        putF32LE(payload[0..], &off, d);
        putF32LE(payload[0..], &off, e);
        putF32LE(payload[0..], &off, f);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_TRANSFORM_2D, payload[0..]);
    }

    pub fn resetTransform(self: *Encoder) !void {
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.RESET_TRANSFORM, &[_]u8{});
    }

    pub fn fillRect(self: *Encoder, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) !void {
        var payload: [32]u8 = undefined;
        var off: usize = 0;
        putF32LE(payload[0..], &off, x);
        putF32LE(payload[0..], &off, y);
        putF32LE(payload[0..], &off, w);
        putF32LE(payload[0..], &off, h);
        putF32LE(payload[0..], &off, r);
        putF32LE(payload[0..], &off, g);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, a);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.FILL_RECT, payload[0..]);
    }

    pub fn strokeLine(
        self: *Encoder,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        stroke_width: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) !void {
        if (!(stroke_width > 0.0)) return error.InvalidArgument;

        var payload: [36]u8 = undefined;
        var off: usize = 0;

        putF32LE(payload[0..], &off, x1);
        putF32LE(payload[0..], &off, y1);
        putF32LE(payload[0..], &off, x2);
        putF32LE(payload[0..], &off, y2);
        putF32LE(payload[0..], &off, stroke_width);
        putF32LE(payload[0..], &off, r);
        putF32LE(payload[0..], &off, g);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, a);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.STROKE_LINE, payload[0..]);
    }

    pub fn setStrokeJoin(self: *Encoder, join: StrokeJoin) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putU32LE(payload[0..], &off, @intFromEnum(join));
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_STROKE_JOIN, payload[0..]);
    }

    pub fn setStrokeCap(self: *Encoder, cap: StrokeCap) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putU32LE(payload[0..], &off, @intFromEnum(cap));
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_STROKE_CAP, payload[0..]);
    }

    /// Set the miter limit for stroke joins.
    /// When a miter join would extend beyond miter_limit * stroke_width / 2,
    /// it falls back to a bevel join instead.
    /// Default value is 4.0 (same as SVG default).
    /// Must be >= 1.0; values less than 1.0 are clamped to 1.0.
    pub fn setMiterLimit(self: *Encoder, limit: f32) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putF32LE(payload[0..], &off, limit);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_MITER_LIMIT, payload[0..]);
    }

    /// Blit an RGBA image at the specified destination position.
    /// The image is drawn at 1:1 scale, affected by the current transform.
    /// Payload format: dst_x(f32), dst_y(f32), img_w(u32), img_h(u32), pixels(RGBA bytes)
    pub fn blitImage(
        self: *Encoder,
        dst_x: f32,
        dst_y: f32,
        img_w: u32,
        img_h: u32,
        pixels: []const u8,
    ) !void {
        const expected_len: usize = @as(usize, img_w) * @as(usize, img_h) * 4;
        if (pixels.len != expected_len) return error.InvalidArgument;
        if (img_w == 0 or img_h == 0) return error.InvalidArgument;

        // Header: dst_x, dst_y (f32), img_w, img_h (u32) = 16 bytes
        const header_len: usize = 16;
        const payload_len: usize = header_len + pixels.len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putF32LE(payload, &off, dst_x);
        putF32LE(payload, &off, dst_y);
        putU32LE(payload, &off, img_w);
        putU32LE(payload, &off, img_h);

        @memcpy(payload[header_len..], pixels);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.BLIT_IMAGE, payload);
    }

    pub fn end(self: *Encoder) !void {
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.END, &[_]u8{});
    }

    pub fn writeToFile(self: *Encoder, file: std.fs.File) !void {
        try sdcs.writeHeader(file);

        const chunk_pos = try file.getPos();
        var ch = sdcs.ChunkHeader{
            .type = sdcs.ChunkType.CMDS,
            .flags = 0,
            .offset = chunk_pos,
            .bytes = 0,
            .payload_bytes = 0,
        };
        try file.writeAll(std.mem.asBytes(&ch));

        const payload_start = try file.getPos();
        try file.writeAll(self.cmds.items);

        // Pad chunk payload to 8-byte alignment
        const payload_bytes: u64 = self.cmds.items.len;
        const pad = sdcs.pad8Len(self.cmds.items.len);
        if (pad != 0) {
            const zeros = [_]u8{0} ** 8;
            try file.writeAll(zeros[0..pad]);
        }

        const end_pos = try file.getPos();
        const aligned_payload: u64 = end_pos - payload_start;

        ch.payload_bytes = payload_bytes;
        ch.bytes = @sizeOf(sdcs.ChunkHeader) + aligned_payload;

        try file.seekTo(chunk_pos);
        try file.writeAll(std.mem.asBytes(&ch));
        try file.seekTo(end_pos);
    }
};
