const std = @import("std");
const CodeAlloc = @This();

const buffer_size = 1024 * 1024 * 4;
const slab_size = 1024 * 8;
const slab_count = @divExact(buffer_size, slab_size);

const min_alloc = 16;
const log2_min_alloc = std.math.log2(min_alloc);
const min_align: std.mem.Alignment = .fromByteUnits(16);
const max_alloc = 1024 * 2;
const max_size_class = sizeClass(max_alloc, .@"1");
const size_class_count = max_size_class + 1;

memfd: std.posix.fd_t,
map: [*]align(std.heap.page_size_min) u8,
slab_descs: [*]SlabDesc,
free_slab_bump: u32 = 0,
first_free_slab: OptIndex = .none,
first_slab_with_free: [size_class_count]OptIndex = @splat(.none),

const SlabDesc = struct {
    prev: OptIndex,
    next: OptIndex,

    bump: u32,
    first_free: OptIndex,
};

const OptIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    fn wrap(opt: ?u32) OptIndex {
        return if (opt) |x| @enumFromInt(x) else .none;
    }

    fn unwrap(opt: OptIndex) ?u32 {
        if (opt == .none) return null;
        return @intFromEnum(opt);
    }
};

pub fn init(code_alloc: *CodeAlloc, gpa: std.mem.Allocator) !void {
    const slab_descs = try gpa.alloc(SlabDesc, slab_count);
    errdefer gpa.free(slab_descs);

    const MFD_EXEC = 0x0010;
    const memfd = std.posix.memfd_createZ("host-code", MFD_EXEC) catch
        try std.posix.memfd_createZ("host-code", 0);
    errdefer _ = std.os.linux.close(memfd);
    if (std.posix.errno(std.os.linux.ftruncate(memfd, buffer_size)) != .SUCCESS)
        return error.TruncateFailed;

    const map = try std.posix.mmap(null, buffer_size * 2, .{}, .{ .TYPE = .PRIVATE, .NORESERVE = true, .ANONYMOUS = true }, -1, 0);
    errdefer std.posix.munmap(map);

    _ = try std.posix.mmap(map.ptr, buffer_size, .{ .READ = true, .EXEC = true }, .{ .TYPE = .SHARED, .FIXED = true }, memfd, 0);
    _ = try std.posix.mmap(map.ptr + buffer_size, buffer_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .FIXED = true }, memfd, 0);

    code_alloc.* = .{
        .memfd = memfd,
        .map = map.ptr,
        .slab_descs = slab_descs.ptr,
    };
}

pub fn deinit(code_alloc: *CodeAlloc, gpa: std.mem.Allocator) void {
    std.posix.munmap(code_alloc.map[0 .. buffer_size * 2]);
    _ = std.os.linux.close(code_alloc.memfd);
    gpa.free(@as([]SlabDesc, code_alloc.slab_descs[0..slab_count]));
}

pub fn allocator(code_alloc: *CodeAlloc) std.mem.Allocator {
    return .{
        .ptr = @ptrCast(code_alloc),
        .vtable = &.{
            .alloc = &alloc,
            .resize = &resize,
            .remap = &remap,
            .free = &free,
        },
    };
}

fn alloc(ctx: *anyopaque, size: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (size > max_alloc) return null;
    if (alignment.toByteUnits() > max_alloc) return null;

    const code_alloc: *CodeAlloc = @ptrCast(@alignCast(ctx));
    const size_class = sizeClass(size, alignment);
    const slot_size = classSize(size_class);
    const class_slots = classSlots(size_class);

    if (code_alloc.first_slab_with_free[size_class].unwrap()) |slab_i| {
        const desc = &code_alloc.slab_descs[slab_i];

        if (desc.bump < class_slots) {
            const slot_i = desc.bump;
            desc.bump += 1;

            if (desc.bump == class_slots and desc.first_free == .none) {
                if (desc.prev.unwrap()) |prev| {
                    code_alloc.slab_descs[prev].next = desc.next;
                } else {
                    code_alloc.first_slab_with_free[size_class] = desc.next;
                }

                if (desc.next.unwrap()) |next| {
                    code_alloc.slab_descs[next].prev = desc.prev;
                }
            }

            return code_alloc.mapRw().ptr + (slab_i * slab_size) + (slot_i * slot_size);
        }

        const slot_i = desc.first_free.unwrap() orelse unreachable;
        const slot: [*]u8 = code_alloc.mapRw().ptr + (slab_i * slab_size) + (slot_i * slot_size);
        const link: *OptIndex = @ptrCast(@alignCast(slot));
        desc.first_free = link.*;

        if (link.* == .none) {
            if (desc.prev.unwrap()) |prev| {
                code_alloc.slab_descs[prev].next = desc.next;
            } else {
                code_alloc.first_slab_with_free[size_class] = desc.next;
            }

            if (desc.next.unwrap()) |next| {
                code_alloc.slab_descs[next].prev = desc.prev;
            }
        }

        return slot;
    }

    const slab_i = if (code_alloc.free_slab_bump < slab_count) blk: {
        const i = code_alloc.free_slab_bump;
        code_alloc.free_slab_bump += 1;
        break :blk i;
    } else if (code_alloc.first_free_slab.unwrap()) |i| blk: {
        code_alloc.first_free_slab = code_alloc.slab_descs[i].next;
        break :blk i;
    } else return null;

    const desc = &code_alloc.slab_descs[slab_i];
    desc.* = .{
        .prev = .none,
        .next = code_alloc.first_slab_with_free[size_class],

        .bump = 1,
        .first_free = .none,
    };

    if (code_alloc.first_slab_with_free[size_class].unwrap()) |other| {
        code_alloc.slab_descs[other].prev = .wrap(slab_i);
    }
    code_alloc.first_slab_with_free[size_class] = .wrap(slab_i);

    return code_alloc.mapRw().ptr + (slab_i * slab_size);
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_size: usize, _: usize) bool {
    if (new_size > max_alloc) return false;
    const old_class = sizeClass(memory.len, alignment);
    const new_class = sizeClass(new_size, alignment);

    return new_class == old_class;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_size: usize, _: usize) ?[*]u8 {
    return if (resize(undefined, memory, alignment, new_size, undefined)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    const code_alloc: *CodeAlloc = @ptrCast(@alignCast(ctx));
    std.debug.assert(@intFromPtr(memory.ptr) >= @intFromPtr(code_alloc.mapRw().ptr));
    std.debug.assert(@intFromPtr(memory.ptr) + memory.len <= @intFromPtr(code_alloc.mapRw().ptr + buffer_size));
    const class = sizeClass(memory.len, alignment);
    const slot_size = classSize(class);
    const slot_count = classSlots(class);

    const buffer_offset = @intFromPtr(memory.ptr) - @intFromPtr(code_alloc.mapRw().ptr);
    const slab_i: u32 = @intCast(buffer_offset / slab_size);
    const slot_i: u32 = @intCast((buffer_offset % slab_size) / slot_size);

    const desc = &code_alloc.slab_descs[slab_i];
    const link: *OptIndex = @ptrCast(@alignCast(memory.ptr));

    if (desc.first_free == .none and desc.bump == slot_count) {
        desc.prev = .none;
        desc.next = code_alloc.first_slab_with_free[class];

        if (code_alloc.first_slab_with_free[class].unwrap()) |other| {
            code_alloc.slab_descs[other].prev = .wrap(slab_i);
        }
        code_alloc.first_slab_with_free[class] = .wrap(slab_i);
    }

    link.* = desc.first_free;
    desc.first_free = .wrap(slot_i);
}

pub fn mapRx(code_alloc: CodeAlloc) []align(std.heap.page_size_min) u8 {
    return code_alloc.map[0..buffer_size];
}

pub fn mapRw(code_alloc: CodeAlloc) []align(std.heap.page_size_min) u8 {
    return code_alloc.map[buffer_size..][0..buffer_size];
}

pub fn toRx(ptr: [*]u8) [*]u8 {
    return ptr - buffer_size;
}

pub fn toRw(ptr: [*]u8) [*]u8 {
    return ptr + buffer_size;
}

fn sizeClass(size: usize, alignment: std.mem.Alignment) usize {
    std.debug.assert(size != 0);
    std.debug.assert(size <= max_alloc);

    const align_or_min = alignment.max(min_align);
    const size_or_min = @max(size, align_or_min.toByteUnits(), min_alloc);
    const log2 = @as(usize, @bitSizeOf(usize)) - @clz(size_or_min - 1);
    const half = @as(usize, 1) << @intCast(log2 - 1);
    const three_quarters = half + (half >> 1);
    const class = (log2 - log2_min_alloc) * 2;
    return if (size_or_min <= three_quarters and align_or_min.check(three_quarters)) class - 1 else class;
}

fn classSize(class: usize) usize {
    std.debug.assert(class <= max_size_class);

    const has_half = class % 2 == 1;
    const log2 = class / 2 + log2_min_alloc;
    const power_of_2 = @as(usize, 1) << @intCast(log2);
    const half = power_of_2 >> 1;
    return if (has_half) power_of_2 + half else power_of_2;
}

fn classSlots(class: usize) usize {
    return slab_size / classSize(class);
}
