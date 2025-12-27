const std = @import("std");
const sdcs = @import("sdcs");

fn readExact(r: anytype, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try r.read(buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}


/// Minimal limited-reader for Zig 0.15.2.
///
/// Zig 0.15.2 does not expose `std.io.limitedReader`, but we only need a
/// wrapper that prevents reading past a fixed byte count.
const LimitedFileReader = struct {
    file: *std.fs.File,
    remaining: usize,

    fn read(self: *LimitedFileReader, buf: []u8) !usize {
        if (self.remaining == 0) return 0;
        const want = @min(buf.len, self.remaining);
        const n = try self.file.read(buf[0..want]);
        self.remaining -= n;
        return n;
    }

    /// Compatibility shim: many helpers accept an `anytype` with a `read` method.
    /// Returning `self` keeps call sites ergonomic (`lr.reader()`), similar to the
    /// old `std.io.limitedReader(...).reader()` pattern.
    pub fn reader(self: *LimitedFileReader) *LimitedFileReader {
        return self;
    }
};

const StrokeJoin = enum(u32) {
    Miter = 0,
    Bevel = 1,
    Round = 2,
};

const StrokeCap = enum(u32) {
    Butt = 0,
    Square = 1,
    Round = 2,
};


fn clampU8(v: f32) u8 {
    var x = v;
    if (x < 0.0) x = 0.0;
    if (x > 1.0) x = 1.0;
    return @intFromFloat(@round(x * 255.0));
}
fn emitSquareCap(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x: f32,
    y: f32,
    axis: u8,
    sign: i8,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    const half: f32 = sw * 0.5;
    var rx: f32 = 0;
    var ry: f32 = 0;
    var rw: f32 = 0;
    var rh: f32 = 0;

    if (axis == 0) { // horizontal
        rx = x + (if (sign > 0) 0 else -half);
        ry = y - half;
        rw = half;
        rh = sw;
    } else { // vertical
        rx = x - half;
        ry = y + (if (sign > 0) 0 else -half);
        rw = sw;
        rh = half;
    }

    const rr = rectApplyTBounds(t, rx, ry, rw, rh);
    fbFillRectClipped(
        rgba,
        w,
        h,
        rr.x,
        rr.y,
        rr.w,
        rr.h,
        clampU8(cr),
        clampU8(cg),
        clampU8(cb),
        clampU8(ca),
        blend_mode,
        if (clip_enabled) clip_rects else null,
    );
}

fn pointInClips(px: f32, py: f32, clips: ?[]const ClipRect) bool {
    if (clips) |cs| {
        for (cs) |c| {
            if (px >= c.x and py >= c.y and px < c.x + c.w and py < c.y + c.h) return true;
        }
        return false;
    }
    return true;
}

fn emitRoundCap(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x: f32,
    y: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    const r: f32 = sw * 0.5;

    const c = applyT(t, x, y);
    const vx = struct { x: f32, y: f32 }{ .x = t.a * r, .y = t.b * r };
    const vy = struct { x: f32, y: f32 }{ .x = t.c * r, .y = t.d * r };

    const ex = @abs(vx.x) + @abs(vy.x);
    const ey = @abs(vx.y) + @abs(vy.y);

    var minx: isize = @intFromFloat(@floor(c.x - ex));
    var maxx: isize = @intFromFloat(@ceil(c.x + ex));
    var miny: isize = @intFromFloat(@floor(c.y - ey));
    var maxy: isize = @intFromFloat(@ceil(c.y + ey));

    if (minx < 0) minx = 0;
    if (miny < 0) miny = 0;
    if (maxx > @as(isize, @intCast(w))) maxx = @as(isize, @intCast(w));
    if (maxy > @as(isize, @intCast(h))) maxy = @as(isize, @intCast(h));

    const det: f32 = vx.x * vy.y - vx.y * vy.x;
    const use_affine = @abs(det) > 1e-6;

    var iy: isize = miny;
    while (iy < maxy) : (iy += 1) {
        var ix: isize = minx;
        while (ix < maxx) : (ix += 1) {
            const px: f32 = @as(f32, @floatFromInt(ix)) + 0.5;
            const py: f32 = @as(f32, @floatFromInt(iy)) + 0.5;

            if (clip_enabled and !pointInClips(px, py, clip_rects)) continue;

            const dx = px - c.x;
            const dy = py - c.y;

            var inside: bool = false;
            if (use_affine) {
                const u = (dx * vy.y - dy * vy.x) / det;
                const v = (-dx * vx.y + dy * vx.x) / det;
                inside = (u * u + v * v) <= 1.0;
            } else {
                inside = (dx * dx + dy * dy) <= (r * r);
            }

            if (!inside) continue;

            const idx: usize = (@as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix))) * 4;
            fbBlendPixel(rgba, idx, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode);
        }
    }
}


fn fbBlendPixel(rgba: []u8, idx: usize, sr: u8, sg: u8, sb: u8, sa: u8, mode: u32) void {
    const dr = rgba[idx + 0];
    const dg = rgba[idx + 1];
    const db = rgba[idx + 2];
    const da = rgba[idx + 3];

    switch (mode) {
        1 => { // Src
            rgba[idx + 0] = sr;
            rgba[idx + 1] = sg;
            rgba[idx + 2] = sb;
            rgba[idx + 3] = sa;
        },
        2 => { // Clear
            rgba[idx + 0] = 0;
            rgba[idx + 1] = 0;
            rgba[idx + 2] = 0;
            rgba[idx + 3] = 0;
        },
        3 => { // Add (clamped)
            const rsum: u16 = @as(u16, dr) + @as(u16, sr);
            const gsum: u16 = @as(u16, dg) + @as(u16, sg);
            const bsum: u16 = @as(u16, db) + @as(u16, sb);
            const asum: u16 = @as(u16, da) + @as(u16, sa);
            rgba[idx + 0] = @intCast(@min(rsum, 255));
            rgba[idx + 1] = @intCast(@min(gsum, 255));
            rgba[idx + 2] = @intCast(@min(bsum, 255));
            rgba[idx + 3] = @intCast(@min(asum, 255));
        },
        else => { // SrcOver
            const a: u16 = sa;
            const inva: u16 = 255 - sa;
            const or_: u16 = (@as(u16, sr) * a + @as(u16, dr) * inva) / 255;
            const og_: u16 = (@as(u16, sg) * a + @as(u16, dg) * inva) / 255;
            const ob_: u16 = (@as(u16, sb) * a + @as(u16, db) * inva) / 255;
            const oa_: u16 = a + (@as(u16, da) * inva) / 255;
            rgba[idx + 0] = @intCast(@min(or_, 255));
            rgba[idx + 1] = @intCast(@min(og_, 255));
            rgba[idx + 2] = @intCast(@min(ob_, 255));
            rgba[idx + 3] = @intCast(@min(oa_, 255));
        },
    }
}

fn fbFillRect(rgba: []u8, w: usize, h: usize, x: f32, y: f32, rw: f32, rh: f32, r: u8, g: u8, b: u8, a: u8, mode: u32) void {
    const ix0: isize = @intFromFloat(@floor(x));
    const iy0: isize = @intFromFloat(@floor(y));
    const ix1: isize = @intFromFloat(@ceil(x + rw));
    const iy1: isize = @intFromFloat(@ceil(y + rh));

    var iy: isize = iy0;
    while (iy < iy1) : (iy += 1) {
        if (iy < 0 or iy >= @as(isize, @intCast(h))) continue;
        var ix: isize = ix0;
        while (ix < ix1) : (ix += 1) {
            if (ix < 0 or ix >= @as(isize, @intCast(w))) continue;
            const idx: usize = (@as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix))) * 4;
            fbBlendPixel(rgba, idx, r, g, b, a, mode);
        }
    }
}


fn readF32LE(r: anytype) !f32 {

    var b: [4]u8 = undefined;
    try readExact(r, b[0..]);

    const u: u32 =
        (@as(u32, b[0])) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);

    return @bitCast(u);
}

fn readU32LE(r: anytype) !u32 {
    var b: [4]u8 = undefined;
    try readExact(r, b[0..]);
    return (@as(u32, b[0])) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);
}

const ClipRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

fn fbFillRectClipped(rgba: []u8, w: usize, h: usize, rx: f32, ry: f32, rw: f32, rh: f32, r: u8, g: u8, b: u8, a: u8, mode: u32, clips: ?[]const ClipRect) void {
    if (clips) |cs| {
        // Apply union of clip rects by filling each intersection.
        for (cs) |c| {
            const ix = @max(rx, c.x);
            const iy = @max(ry, c.y);
            const ix2 = @min(rx + rw, c.x + c.w);
            const iy2 = @min(ry + rh, c.y + c.h);
            const iw = ix2 - ix;
            const ih = iy2 - iy;
            if (iw <= 0.0 or ih <= 0.0) continue;
            fbFillRect(rgba, w, h, ix, iy, iw, ih, r, g, b, a, mode);
        }
    } else {
        fbFillRect(rgba, w, h, rx, ry, rw, rh, r, g, b, a, mode);
    }
}

const Transform2D = struct {
    a: f32 = 1.0,
    b: f32 = 0.0,
    c: f32 = 0.0,
    d: f32 = 1.0,
    e: f32 = 0.0,
    f: f32 = 0.0,
};



fn applyT(t: Transform2D, x: f32, y: f32) struct { x: f32, y: f32 } {
    return .{
        .x = t.a * x + t.c * y + t.e,
        .y = t.b * x + t.d * y + t.f,
    };
}

fn rectApplyTBounds(t: Transform2D, x: f32, y: f32, w: f32, h: f32) struct { x: f32, y: f32, w: f32, h: f32 } {
    // Transform 4 corners and return axis aligned bounds
    const p0 = applyT(t, x, y);
    const p1 = applyT(t, x + w, y);
    const p2 = applyT(t, x, y + h);
    const p3 = applyT(t, x + w, y + h);

    var minx = p0.x;
    var miny = p0.y;
    var maxx = p0.x;
    var maxy = p0.y;

    inline for ([_]@TypeOf(p0){ p1, p2, p3 }) |p| {
        if (p.x < minx) minx = p.x;
        if (p.y < miny) miny = p.y;
        if (p.x > maxx) maxx = p.x;
        if (p.y > maxy) maxy = p.y;
    }

    return .{ .x = minx, .y = miny, .w = (maxx - minx), .h = (maxy - miny) };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 5) {
        std.log.err("usage: {s} file.sdcs out.ppm width height", .{args[0]});
        return error.InvalidArgument;
    }

    const in_path = args[1];
    const out_path = args[2];
    const w = try std.fmt.parseInt(usize, args[3], 10);
    const h = try std.fmt.parseInt(usize, args[4], 10);

    var rgba = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(rgba);

    var clip_rects = std.ArrayList(ClipRect){};
    defer clip_rects.deinit(alloc);
    var clip_enabled: bool = false;
    var t = Transform2D{};
    var blend_mode: u32 = 0;
var stroke_join: StrokeJoin = .Miter;
var stroke_cap: StrokeCap = .Butt;
var miter_limit: f32 = 4.0; // SVG default

var last_line_valid: bool = false;

var pending_cap_valid: bool = false;
var pending_end_x: f32 = 0;
var pending_end_y: f32 = 0;
var pending_dir_axis: u8 = 0; // 0=h,1=v
var pending_dir_sign: i8 = 0; // +1 or -1
var pending_sw: f32 = 0;
var pending_cr: f32 = 0;
var pending_cg: f32 = 0;
var pending_cb: f32 = 0;
var pending_ca: f32 = 0;
var pending_t: Transform2D = .{ .a=1, .b=0, .c=0, .d=1, .e=0, .f=0 };
var last_x1: f32 = 0;
var last_y1: f32 = 0;
var last_x2: f32 = 0;
var last_y2: f32 = 0;
var last_sw: f32 = 0;
var last_cr: f32 = 0;
var last_cg: f32 = 0;
var last_cb: f32 = 0;
var last_ca: f32 = 0;

    // background 0x102030
    for (0..h) |yy| {
        for (0..w) |xx| {
            const i = (yy * w + xx) * 4;
            rgba[i + 0] = 16;
            rgba[i + 1] = 32;
            rgba[i + 2] = 48;
            rgba[i + 3] = 255;
        }
    }

    var file = try std.fs.cwd().openFile(in_path, .{});
    defer file.close();

    // Validate before executing
    try sdcs.validateFile(file);
    try file.seekTo(0);

    // Zig 0.15.x: use `fs.File` directly (fs.File.Reader does not expose `.read()`).
    var file_r = file;

    var header: sdcs.Header = undefined;
    try readExact(file_r, std.mem.asBytes(&header));
    if (!std.mem.eql(u8, header.magic[0..], sdcs.Magic)) return error.Protocol;

    while (true) {
        var ch: sdcs.ChunkHeader = undefined;
        const got = file_r.read(std.mem.asBytes(&ch)) catch return;
        if (got == 0) break;
        if (got != @sizeOf(sdcs.ChunkHeader)) break;

        if (ch.type != sdcs.ChunkType.CMDS) {
            try file.seekBy(@intCast(ch.payload_bytes));
            continue;
        }

        var remaining: usize = @intCast(ch.payload_bytes);
        while (remaining >= @sizeOf(sdcs.CmdHdr)) {
            var cmd: sdcs.CmdHdr = undefined;
            try readExact(file_r, std.mem.asBytes(&cmd));
            remaining -= @sizeOf(sdcs.CmdHdr);

            // Padding marker: allow trailing zeroed records
            // flush pending end cap if the next command cannot connect to the previous segment
if (pending_cap_valid and cmd.opcode != sdcs.Op.STROKE_LINE) {
    if (stroke_cap == .Square) {
        emitSquareCap(
            rgba,
            w,
            h,
            pending_t,
            clip_enabled,
            clip_rects.items,
            blend_mode,
            pending_end_x,
            pending_end_y,
            pending_dir_axis,
            pending_dir_sign,
            pending_sw,
            pending_cr,
            pending_cg,
            pending_cb,
            pending_ca,
        );
    }
else if (stroke_cap == .Round) {
    emitRoundCap(
        rgba,
        w,
        h,
        pending_t,
        clip_enabled,
        clip_rects.items,
        blend_mode,
        pending_end_x,
        pending_end_y,
        pending_sw,
        pending_cr,
        pending_cg,
        pending_cb,
        pending_ca,
    );
}

    pending_cap_valid = false;
}

if (cmd.opcode == 0 and cmd.flags == 0 and cmd.payload_bytes == 0) {
                break;
            }


            const pb: usize = @intCast(cmd.payload_bytes);
            if (pb > remaining) break;

            var lr = LimitedFileReader{ .file = &file, .remaining = pb };
            const r = lr.reader();

            if (cmd.opcode == sdcs.Op.SET_BLEND) {
                blend_mode = try readU32LE(r);
            } else if (cmd.opcode == sdcs.Op.SET_TRANSFORM_2D) {
                t.a = try readF32LE(r);
                t.b = try readF32LE(r);
                t.c = try readF32LE(r);
                t.d = try readF32LE(r);
                t.e = try readF32LE(r);
                t.f = try readF32LE(r);
            } else if (cmd.opcode == sdcs.Op.RESET_TRANSFORM) {
                t = Transform2D{};
            } else if (cmd.opcode == sdcs.Op.SET_CLIP_RECTS) {
                // payload: u32 count + rects
                const count = try readU32LE(r);
                clip_rects.clearRetainingCapacity();
                clip_enabled = (count != 0);
                // consume bytes: count + rects
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const cx = try readF32LE(r);
                    const cy = try readF32LE(r);
                    const cw = try readF32LE(r);
                    const ch2 = try readF32LE(r);
                    try clip_rects.append(alloc, .{ .x = cx, .y = cy, .w = cw, .h = ch2 });
                }

            } else if (cmd.opcode == sdcs.Op.CLEAR_CLIP) {
                clip_rects.clearRetainingCapacity();
                clip_enabled = false;
            } else if (cmd.opcode == sdcs.Op.SET_STROKE_JOIN) {
                const join_u = try readU32LE(r);
                if (join_u == 0) {
                    stroke_join = .Miter;
                } else if (join_u == 1) {
                    stroke_join = .Bevel;
                } else {
                    stroke_join = .Miter;
                }
                last_line_valid = false;
            } else if (cmd.opcode == sdcs.Op.SET_STROKE_CAP) {
                const cap_u = try readU32LE(r);
                if (cap_u == 0) {
                    stroke_cap = .Butt;
                } else if (cap_u == 1) {
                    stroke_cap = .Square;
                } else if (cap_u == 2) {
                    stroke_cap = .Round;
                } else {
                    stroke_cap = .Butt;
                }
                last_line_valid = false;
                pending_cap_valid = false;
            } else if (cmd.opcode == sdcs.Op.SET_MITER_LIMIT) {
                const limit = try readF32LE(r);
                // Clamp to minimum of 1.0 (values below 1.0 don't make geometric sense)
                miter_limit = if (limit < 1.0) 1.0 else limit;
            } else if (cmd.opcode == sdcs.Op.STROKE_LINE) {
    // x1,y1,x2,y2,stroke_width,r,g,b,a (9 x f32 = 36 bytes)
    const x1 = try readF32LE(r);
    const y1 = try readF32LE(r);
    const x2 = try readF32LE(r);
    const y2 = try readF32LE(r);
    const sw = try readF32LE(r);
    const cr = try readF32LE(r);
    const cg = try readF32LE(r);
    const cb = try readF32LE(r);
    const ca = try readF32LE(r);
            // caps v1: manage pending end caps and emit start caps when not connected
            const eps: f32 = 0.0001;

            const cur_h = (@abs(y1 - y2) < eps);
            const cur_v = (@abs(x1 - x2) < eps);

            // If the new segment starts at the previous end, suppress the previous end cap.
            if (pending_cap_valid) {
                const connects_prev =
                    (@abs(pending_end_x - x1) < eps and @abs(pending_end_y - y1) < eps) or
                    (@abs(pending_end_x - x2) < eps and @abs(pending_end_y - y2) < eps);

                if (!connects_prev) {
                    if (stroke_cap == .Square) {
                        emitSquareCap(
                            rgba,
                            w,
                            h,
                            pending_t,
                            clip_enabled,
                            clip_rects.items,
                            blend_mode,
                            pending_end_x,
                            pending_end_y,
                            pending_dir_axis,
                            pending_dir_sign,
                            pending_sw,
                            pending_cr,
                            pending_cg,
                            pending_cb,
                            pending_ca,
                        );
                    }
else if (stroke_cap == .Round) {
    emitRoundCap(
        rgba,
        w,
        h,
        pending_t,
        clip_enabled,
        clip_rects.items,
        blend_mode,
        pending_end_x,
        pending_end_y,
        pending_sw,
        pending_cr,
        pending_cg,
        pending_cb,
        pending_ca,
    );
}

                }
                pending_cap_valid = false;
            }

            // Start cap at (x1,y1) if not connected to last segment.
            if (stroke_cap == .Square) {
                var start_connected: bool = false;
                if (last_line_valid) {
                    start_connected =
                        (@abs(last_x2 - x1) < eps and @abs(last_y2 - y1) < eps) or
                        (@abs(last_x1 - x1) < eps and @abs(last_y1 - y1) < eps);
                }
                if (!start_connected) {
                    var axis: u8 = 0;
                    var sign: i8 = 0;
                    if (cur_h) {
                        axis = 0;
                        sign = if (x2 >= x1) 1 else -1;
                    } else if (cur_v) {
                        axis = 1;
                        sign = if (y2 >= y1) 1 else -1;
                    }
                    if (sign != 0) {
                        emitSquareCap(
                            rgba,
                            w,
                            h,
                            t,
                            clip_enabled,
                            clip_rects.items,
                            blend_mode,
                            x1,
                            y1,
                            axis,
                            -sign,
                            sw,
                            cr,
                            cg,
                            cb,
                            ca,
                        );
                    }
                }
            }

            // Defer end cap for this segment to the next command
            if (stroke_cap == .Square) {
                pending_cap_valid = true;
                pending_end_x = x2;
                pending_end_y = y2;
                pending_sw = sw;
                pending_cr = cr;
                pending_cg = cg;
                pending_cb = cb;
                pending_ca = ca;
                pending_t = t;

                if (cur_h) {
                    pending_dir_axis = 0;
                    pending_dir_sign = if (x2 >= x1) 1 else -1;
                } else if (cur_v) {
                    pending_dir_axis = 1;
                    pending_dir_sign = if (y2 >= y1) 1 else -1;
                } else {
                    pending_dir_axis = 0;
                    pending_dir_sign = 0;
                    pending_cap_valid = false;
                }
            }

            // Joins: for now we only emit additional geometry when we can reliably
            // detect an axis aligned right angle between consecutive STROKE_LINE
            // segments that share an endpoint and share style parameters.
            if (last_line_valid and sw == last_sw and cr == last_cr and cg == last_cg and cb == last_cb and ca == last_ca) {
                const last_h = (@abs(last_y1 - last_y2) < eps);
                const last_v = (@abs(last_x1 - last_x2) < eps);

                // Only right angle joins between axis aligned segments.
                if ((last_h and cur_v) or (last_v and cur_h)) {
                    const jx: f32 = x1;
                    const jy: f32 = y1;
                    const connects =
                        (@abs(last_x2 - jx) < eps and @abs(last_y2 - jy) < eps) or
                        (@abs(last_x1 - jx) < eps and @abs(last_y1 - jy) < eps);

                    if (connects) {
                        if (stroke_join == .Round) {
                            // Round join is approximated by a filled disk at the join point.
                            emitRoundCap(
                                rgba,
                                w,
                                h,
                                t,
                                clip_enabled,
                                clip_rects.items,
                                blend_mode,
                                jx,
                                jy,
                                sw,
                                cr,
                                cg,
                                cb,
                                ca,
                            );
                        } else if (stroke_join == .Miter) {
                            // Miter join v1: emit an extra sw x sw corner block on the outer corner.
                            // For 90-degree (right angle) joins, the miter ratio is sqrt(2) ≈ 1.414.
                            // If miter_limit < sqrt(2), fall back to bevel (no extra geometry).
                            const sqrt2: f32 = 1.41421356237;
                            if (miter_limit >= sqrt2) {
                                var sx: f32 = 0;
                                var sy: f32 = 0;

                                if (last_h) {
                                    if (@abs(last_x2 - jx) < eps) sx = if (last_x2 > last_x1) 1 else -1 else sx = if (last_x1 > last_x2) 1 else -1;
                                } else if (cur_h) {
                                    if (@abs(x2 - jx) < eps) sx = if (x2 > x1) 1 else -1 else sx = if (x1 > x2) 1 else -1;
                                }

                                if (last_v) {
                                    if (@abs(last_y2 - jy) < eps) sy = if (last_y2 > last_y1) 1 else -1 else sy = if (last_y1 > last_y2) 1 else -1;
                                } else if (cur_v) {
                                    if (@abs(y2 - jy) < eps) sy = if (y2 > y1) 1 else -1 else sy = if (y1 > y2) 1 else -1;
                                }

                                if (sx != 0 and sy != 0) {
                                    const px = jx + (if (sx > 0) 0 else -sw);
                                    const py = jy + (if (sy > 0) 0 else -sw);
                                    const patch = rectApplyTBounds(t, px, py, sw, sw);
                                    fbFillRectClipped(rgba, w, h, patch.x, patch.y, patch.w, patch.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
                                }
                            }
                            // else: miter_limit < sqrt(2), fall back to bevel (no extra geometry)
                        }
                    }
                }
            }


    // Payload length already accounted for by outer loop.

    if (sw <= 0.0) continue;

    // v1 semantics: only axis aligned lines in user space
    const s2: f32 = sw / 2.0;

    if (x1 == x2) {
        const yy0 = @min(y1, y2);
        const yy1 = @max(y1, y2);
        const rect = rectApplyTBounds(t, x1 - s2, yy0, sw, yy1 - yy0);
        fbFillRectClipped(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
    } else if (y1 == y2) {
        const xx0 = @min(x1, x2);
        const xx1 = @max(x1, x2);
        const rect = rectApplyTBounds(t, xx0, y1 - s2, xx1 - xx0, sw);
        fbFillRectClipped(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
    } else {
        // Not supported in v1. Ignore.
        continue;
    }
            // update last segment info for join detection
            last_line_valid = true;
            last_x1 = x1;
            last_y1 = y1;
            last_x2 = x2;
            last_y2 = y2;
            last_sw = sw;
            last_cr = cr;
            last_cg = cg;
            last_cb = cb;
            last_ca = ca;

}

else if (cmd.opcode == sdcs.Op.STROKE_RECT) {
    // x,y,w,h,stroke_width,r,g,b,a (9 x f32 = 36 bytes)
    const rx = try readF32LE(r);
    const ry = try readF32LE(r);
    const rw2 = try readF32LE(r);
    const rh2 = try readF32LE(r);
    const sw = try readF32LE(r);
    const cr = try readF32LE(r);
    const cg = try readF32LE(r);
    const cb = try readF32LE(r);
    const ca = try readF32LE(r);

    // Payload length already accounted for by outer loop.

    if (sw <= 0.0) continue;

    const s2: f32 = sw / 2.0;

    // Build four edge rectangles in user space
    const top = rectApplyTBounds(t, rx - s2, ry - s2, rw2 + sw, sw);
    const bottom = rectApplyTBounds(t, rx - s2, ry + rh2 - s2, rw2 + sw, sw);
    const left = rectApplyTBounds(t, rx - s2, ry + s2, sw, @max(0.0, rh2 - sw));
    const right = rectApplyTBounds(t, rx + rw2 - s2, ry + s2, sw, @max(0.0, rh2 - sw));

    fbFillRectClipped(rgba, w, h, top.x, top.y, top.w, top.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
    fbFillRectClipped(rgba, w, h, bottom.x, bottom.y, bottom.w, bottom.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
    fbFillRectClipped(rgba, w, h, left.x, left.y, left.w, left.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
    fbFillRectClipped(rgba, w, h, right.x, right.y, right.w, right.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
}

else if (cmd.opcode == sdcs.Op.FILL_RECT) {
                if (pb != 32) return error.Protocol;
                const rx = try readF32LE(r);
                const ry = try readF32LE(r);
                const rw2 = try readF32LE(r);
                const rh2 = try readF32LE(r);
                const cr = try readF32LE(r);
                const cg = try readF32LE(r);
                const cb = try readF32LE(r);
                const ca = try readF32LE(r);
                const tb = rectApplyTBounds(t, rx, ry, rw2, rh2);
                fbFillRectClipped(rgba, w, h, tb.x, tb.y, tb.w, tb.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);

            } else {
                try file.seekBy(@intCast(pb));

            }
            const left = lr.remaining;
            if (left != 0) try file.seekBy(@intCast(left));
            remaining -= pb;

            const pad = sdcs.pad8Len(@sizeOf(sdcs.CmdHdr) + pb);
            if (pad > remaining) return error.Protocol;
            if (pad != 0) try file.seekBy(@intCast(pad));
            remaining -= pad;
            file_r = file;

            if (cmd.opcode == sdcs.Op.END) break;
        }
        break;
    }

    var out = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out.close();
    
// flush final pending cap
if (pending_cap_valid) {
    if (stroke_cap == .Square) {
        emitSquareCap(
            rgba,
            w,
            h,
            pending_t,
            clip_enabled,
            clip_rects.items,
            blend_mode,
            pending_end_x,
            pending_end_y,
            pending_dir_axis,
            pending_dir_sign,
            pending_sw,
            pending_cr,
            pending_cg,
            pending_cb,
            pending_ca,
        );
    }
else if (stroke_cap == .Round) {
    emitRoundCap(
        rgba,
        w,
        h,
        pending_t,
        clip_enabled,
        clip_rects.items,
        blend_mode,
        pending_end_x,
        pending_end_y,
        pending_sw,
        pending_cr,
        pending_cg,
        pending_cb,
        pending_ca,
    );
}

    pending_cap_valid = false;
}

// PPM header (P6)
// Zig 0.15+ uses the new std.Io Writer API and std.fmt.format expects a
// compatible writer adapter. std.fs.File.Writer does not provide that adapter,
// so format into a small buffer and write the bytes.
var ppm_hdr_buf: [64]u8 = undefined;
const ppm_hdr = try std.fmt.bufPrint(&ppm_hdr_buf, "P6\n{d} {d}\n255\n", .{ w, h });
try out.writeAll(ppm_hdr);

    // Convert RGBA framebuffer to RGB for PPM output.
    // PPM P6 is 3 bytes per pixel (RGB)
    var rgb_out = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(rgb_out);
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        rgb_out[i * 3 + 0] = rgba[i * 4 + 0];
        rgb_out[i * 3 + 1] = rgba[i * 4 + 1];
        rgb_out[i * 3 + 2] = rgba[i * 4 + 2];
    }
    try out.writeAll(rgb_out);
}
