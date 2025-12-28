const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");

/// Surface state
pub const Surface = struct {
    id: protocol.SurfaceId,
    owner: protocol.ClientId,

    // Geometry
    logical_width: f32,
    logical_height: f32,
    position_x: f32 = 0,
    position_y: f32 = 0,
    z_order: i32 = 0,
    visible: bool = false,

    // Attached buffer (if any)
    buffer: ?AttachedBuffer = null,

    // Frame state
    pending_commit: bool = false,
    frame_number: u64 = 0,

    pub fn getPixelCount(self: *const Surface) u64 {
        return @intFromFloat(@abs(self.logical_width * self.logical_height));
    }
};

/// Attached shared memory buffer
pub const AttachedBuffer = struct {
    /// Shared memory file descriptor
    shm_fd: posix.fd_t,
    /// Size of the shared memory region
    shm_size: usize,
    /// Mapped memory pointer (null if not yet mapped)
    mapped: ?[*]align(std.mem.page_size) u8 = null,
    /// Offset into shm where SDCS data starts
    offset: usize = 0,
    /// Length of SDCS data
    length: usize,

    pub fn map(self: *AttachedBuffer) ![]u8 {
        if (self.mapped) |ptr| {
            return ptr[self.offset..][0..self.length];
        }

        const ptr = try posix.mmap(
            null,
            self.shm_size,
            posix.PROT.READ,
            .{ .TYPE = .SHARED },
            self.shm_fd,
            0,
        );
        self.mapped = @alignCast(ptr);
        return self.mapped.?[self.offset..][0..self.length];
    }

    pub fn unmap(self: *AttachedBuffer) void {
        if (self.mapped) |ptr| {
            posix.munmap(ptr[0..self.shm_size]);
            self.mapped = null;
        }
    }

    pub fn deinit(self: *AttachedBuffer) void {
        self.unmap();
        posix.close(self.shm_fd);
    }
};

/// Surface registry - manages all surfaces
pub const SurfaceRegistry = struct {
    allocator: std.mem.Allocator,
    surfaces: std.AutoHashMap(protocol.SurfaceId, *Surface),
    next_id: protocol.SurfaceId,

    // Composition order cache (sorted by z_order)
    composition_order: std.ArrayListUnmanaged(*Surface),
    order_dirty: bool,

    pub fn init(allocator: std.mem.Allocator) SurfaceRegistry {
        return .{
            .allocator = allocator,
            .surfaces = std.AutoHashMap(protocol.SurfaceId, *Surface).init(allocator),
            .next_id = 1,
            .composition_order = .{},
            .order_dirty = false,
        };
    }

    pub fn deinit(self: *SurfaceRegistry) void {
        var it = self.surfaces.valueIterator();
        while (it.next()) |surface_ptr| {
            if (surface_ptr.*.buffer) |*buf| {
                buf.deinit();
            }
            self.allocator.destroy(surface_ptr.*);
        }
        self.surfaces.deinit();
        self.composition_order.deinit(self.allocator);
    }

    /// Create a new surface
    pub fn createSurface(
        self: *SurfaceRegistry,
        owner: protocol.ClientId,
        width: f32,
        height: f32,
    ) !*Surface {
        const id = self.next_id;
        self.next_id += 1;

        const surface = try self.allocator.create(Surface);
        surface.* = .{
            .id = id,
            .owner = owner,
            .logical_width = width,
            .logical_height = height,
        };

        try self.surfaces.put(id, surface);
        self.order_dirty = true;

        return surface;
    }

    /// Destroy a surface
    pub fn destroySurface(self: *SurfaceRegistry, id: protocol.SurfaceId) void {
        if (self.surfaces.fetchRemove(id)) |kv| {
            const surface = kv.value;
            if (surface.buffer) |*buf| {
                buf.deinit();
            }
            self.allocator.destroy(surface);
            self.order_dirty = true;
        }
    }

    /// Get a surface by ID
    pub fn getSurface(self: *SurfaceRegistry, id: protocol.SurfaceId) ?*Surface {
        return self.surfaces.get(id);
    }

    /// Check if a client owns a surface
    pub fn isOwner(self: *SurfaceRegistry, id: protocol.SurfaceId, client: protocol.ClientId) bool {
        if (self.getSurface(id)) |surface| {
            return surface.owner == client;
        }
        return false;
    }

    /// Attach a buffer to a surface
    pub fn attachBuffer(
        self: *SurfaceRegistry,
        surface_id: protocol.SurfaceId,
        shm_fd: posix.fd_t,
        shm_size: usize,
        offset: usize,
        length: usize,
    ) !void {
        const surface = self.getSurface(surface_id) orelse return error.SurfaceNotFound;

        // Clean up old buffer if present
        if (surface.buffer) |*old_buf| {
            old_buf.deinit();
        }

        surface.buffer = .{
            .shm_fd = shm_fd,
            .shm_size = shm_size,
            .offset = offset,
            .length = length,
        };
    }

    /// Set surface visibility
    pub fn setVisible(self: *SurfaceRegistry, id: protocol.SurfaceId, visible: bool) !void {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.visible = visible;
    }

    /// Set surface z-order
    pub fn setZOrder(self: *SurfaceRegistry, id: protocol.SurfaceId, z_order: i32) !void {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.z_order = z_order;
        self.order_dirty = true;
    }

    /// Set surface position
    pub fn setPosition(self: *SurfaceRegistry, id: protocol.SurfaceId, x: f32, y: f32) !void {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.position_x = x;
        surface.position_y = y;
    }

    /// Mark surface as having a pending commit
    pub fn commit(self: *SurfaceRegistry, id: protocol.SurfaceId) !u64 {
        const surface = self.getSurface(id) orelse return error.SurfaceNotFound;
        surface.pending_commit = true;
        surface.frame_number += 1;
        return surface.frame_number;
    }

    /// Get surfaces in composition order (back to front)
    pub fn getCompositionOrder(self: *SurfaceRegistry) ![]*Surface {
        if (self.order_dirty) {
            self.composition_order.clearRetainingCapacity();

            var it = self.surfaces.valueIterator();
            while (it.next()) |surface| {
                if (surface.*.visible) {
                    try self.composition_order.append(self.allocator, surface.*);
                }
            }

            // Sort by z_order (ascending = back to front)
            std.mem.sort(*Surface, self.composition_order.items, {}, struct {
                fn lessThan(_: void, a: *Surface, b: *Surface) bool {
                    return a.z_order < b.z_order;
                }
            }.lessThan);

            self.order_dirty = false;
        }

        return self.composition_order.items;
    }

    /// Remove all surfaces owned by a client
    pub fn removeClientSurfaces(self: *SurfaceRegistry, client: protocol.ClientId) void {
        var to_remove = std.ArrayListUnmanaged(protocol.SurfaceId){};
        defer to_remove.deinit(self.allocator);

        var it = self.surfaces.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.owner == client) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |id| {
            self.destroySurface(id);
        }
    }

    /// Get count of surfaces
    pub fn count(self: *SurfaceRegistry) usize {
        return self.surfaces.count();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SurfaceRegistry create and destroy" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const surface = try registry.createSurface(1, 1920, 1080);
    try std.testing.expectEqual(@as(protocol.SurfaceId, 1), surface.id);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    registry.destroySurface(surface.id);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "SurfaceRegistry ownership" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const surface = try registry.createSurface(42, 800, 600);
    try std.testing.expect(registry.isOwner(surface.id, 42));
    try std.testing.expect(!registry.isOwner(surface.id, 99));
}

test "SurfaceRegistry z-order sorting" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const s1 = try registry.createSurface(1, 100, 100);
    const s2 = try registry.createSurface(1, 100, 100);
    const s3 = try registry.createSurface(1, 100, 100);

    try registry.setZOrder(s1.id, 10);
    try registry.setZOrder(s2.id, 5);
    try registry.setZOrder(s3.id, 15);

    try registry.setVisible(s1.id, true);
    try registry.setVisible(s2.id, true);
    try registry.setVisible(s3.id, true);

    const order = try registry.getCompositionOrder();
    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqual(s2.id, order[0].id); // z=5
    try std.testing.expectEqual(s1.id, order[1].id); // z=10
    try std.testing.expectEqual(s3.id, order[2].id); // z=15
}
