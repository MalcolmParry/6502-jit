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

    printHex(code);

    const block = try compileBlock(.{
        .gpa = gpa,
        .code_alloc = &code_alloc,
        .addr_space = @ptrCast(addr_space.ptr),
    }, 0x600);

    printHex(block.host_code_rx);
    // try printRaw(io, block.host_code_rx);

    const Func = fn () callconv(.{ .x86_64_sysv = .{} }) void;
    const func: *const Func = @ptrCast(block.host_code_rx.ptr);

    func();
    std.log.info("{}", .{addr_space[0x200]});
}

const State = struct {
    gpa: std.mem.Allocator,
    code_alloc: *CodeAlloc,
    addr_space: *[64 * 1024]u8,
};

const BlockDesc = struct {
    guest_ptr: u16,
    guest_len: u16,
    host_code_rx: []u8,
};

fn compileBlock(state: State, guest_ptr: u16) !BlockDesc {
    const gpa = state.gpa;
    const code_alloc = state.code_alloc.allocator();
    var host_code: std.Io.Writer.Allocating = .init(code_alloc);
    errdefer host_code.deinit();

    var relocs: std.ArrayList(Relocation) = .empty;
    defer relocs.deinit(gpa);

    var i: u16 = 0;
    while (i < 128) {
        const start_ptr = guest_ptr +% i;
        const op_code: OpCode = @enumFromInt(state.addr_space[start_ptr]);

        switch (op_code) {
            .hlt => {
                try host_code.writer.writeByte(0xc3);
                i += 1;
                break;
            },
            .clc => {
                try host_code.writer.writeByte(0xf8);
                i += 1;
            },
            .adc => {
                // TODO: support bcd mode
                try host_code.writer.writeAll(&.{
                    0x14, state.addr_space[start_ptr +% 1],
                });

                i += 2;
                continue;
            },
            .sta => {
                const low = state.addr_space[start_ptr +% 1];
                const high = state.addr_space[start_ptr +% 2];
                const guest_addr = (@as(u16, high) << 8) | low;
                const host_addr = &state.addr_space[guest_addr];

                // TODO: handle mmio
                try relocs.append(gpa, .{
                    .offset = host_code.writer.end + 2,
                    .next_inst = host_code.writer.end + 6,
                    .addr = @intFromPtr(host_addr),
                });

                try host_code.writer.writeAll(&.{
                    0x88, 0x05, 0, 0, 0, 0,
                });

                i += 3;
                continue;
            },
            .lda_imm => {
                try host_code.writer.writeAll(&.{
                    0xb0, state.addr_space[start_ptr +% 1],
                });

                i += 2;
                continue;
            },
            else => @panic("instruction not implemented"),
        }
    }

    const host_code_final = try host_code.toOwnedSlice();
    const host_code_rx = CodeAlloc.toRx(host_code_final.ptr)[0..host_code_final.len];

    for (relocs.items) |reloc| {
        const offset_ptr: *align(1) i32 = @ptrCast(host_code_final.ptr + reloc.offset);
        const rip: isize = @intCast(@intFromPtr(host_code_rx.ptr) + reloc.next_inst);
        const addr: isize = @intCast(reloc.addr);
        offset_ptr.* = @intCast(addr - rip);
    }

    return .{
        .guest_ptr = guest_ptr,
        .guest_len = i,
        .host_code_rx = host_code_rx,
    };
}

const Relocation = struct {
    offset: usize,
    next_inst: usize,
    addr: usize,
};

const HostReg = enum(u4) {
    // zig fmt: off
    ax, cx, dx,  bx,  sp,  bp,  si,  di,
    r8, r9, r10, r11, r12, r13, r14, r15,
    // zig fmt: on
};

const GuestReg = enum { ac, x, y, sp };

const OpCode = enum(u8) {
    hlt = 0x02,
    clc = 0x18,
    adc = 0x69,
    sta = 0x8d,
    lda_imm = 0xa9,
    _,
};

fn printRaw(io: std.Io, data: []const u8) !void {
    const stdout = std.Io.File.stdout();
    var writer = stdout.writer(io, &.{});
    try writer.interface.writeAll(data);
}

fn printHex(data: []const u8) void {
    for (data) |byte| {
        std.debug.print("{x:0>2} ", .{byte});
    }
    std.debug.print("\n", .{});
}
