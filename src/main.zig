const std = @import("std");
const CodeAlloc = @import("CodeAllocator.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var code_alloc: CodeAlloc = undefined;
    try code_alloc.init(gpa);
    defer code_alloc.deinit(gpa);

    const code = blk: {
        const file = try std.Io.Dir.cwd().openFile(io, "prog.bin", .{});
        const buffer = try arena.alloc(u8, try file.length(io));
        var reader = file.reader(io, &.{});
        try reader.interface.readSliceAll(buffer);
        break :blk buffer;
    };

    const addr_space = try std.posix.mmap(null, 64 * 1024, .{}, .{
        .TYPE = .PRIVATE,
        .ANONYMOUS = true,
        .NORESERVE = true,
    }, 0, 0);
    defer std.posix.munmap(addr_space);

    if (std.os.linux.mprotect(addr_space.ptr, 4 * 1024, .{
        .READ = true,
        .WRITE = true,
    }) != 0) return error.MapFailed;

    @memcpy(addr_space[0x600..][0..code.len], code);

    const host_code_rw = try code_alloc.allocator().alloc(u8, 6);
    host_code_rw[0..6].* = .{
        0xb8, 0x0a, 0x00, 0x00, 0x00,
        0xc3,
    };

    const Func = fn () callconv(.{ .x86_64_sysv = .{} }) usize;
    const func: *const Func = @ptrCast(CodeAlloc.toRx(host_code_rw.ptr));

    std.log.info("{}", .{func()});
}

const OpCode = enum(u8) {
    hlt = 0x02,
    clc = 0x18,
    adc = 0x69,
    sta = 0x8d,
    _,
};
