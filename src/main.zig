const std = @import("std");
const c = @cImport({
    @cInclude("sys/ptrace.h");
    @cInclude("sys/user.h");
});

pub fn ptrace(a0: usize, a1: std.os.pid_t, a2: usize, a3: usize) !void {
    const res = std.os.linux.syscall4(.ptrace, a0, @bitCast(usize, @as(isize, a1)), a2, a3);
    if (res != 0) return error.PtraceError;
}

// !noreturn but that doesn't work atm I think
pub fn launchChildProcess() !void {
    try ptrace(c.PTRACE_TRACEME, 0, 0, 0);
    return std.os.execveZ("zig-out/bin/sample", &[0:null]?[*:0]const u8{}, &[0:null]?[*:0]const u8{});
}

const Reg = enum {
    syscall,
    a0,
    a1,
    pub fn name(comptime reg: Reg) []const u8 {
        return comptime switch (reg) {
            .syscall => "orig_rax",
            .a0 => "rdi",
            .a1 => "rsi",
        };
    }
};
const RegSet = struct {
    raw_regs: c.user_regs_struct,
    pub fn get(rset: RegSet, comptime reg: Reg) usize {
        return @field(rset.raw_regs, comptime reg.name());
    }
    pub fn set(rset: *RegSet, comptime reg: Reg, value: usize) void {
        @field(rset.raw_regs, comptime reg.name()) = value;
    }
    // pub fn isInSyscall(rset: RegSet) bool {
    //     return rset.raw_regs.rax == -std.os.ENOSYS;
    // }
};

// note that if the child process recieves a signal, waitForSyscall will run too
pub fn waitForSyscall(pid: std.os.pid_t) !void {
    try ptrace(c.PTRACE_SYSCALL, pid, 0, 0);
    _ = std.os.waitpid(pid, 0);
}

pub fn getRegs(pid: std.os.pid_t) !RegSet {
    var regs: c.user_regs_struct = undefined;
    try ptrace(c.PTRACE_GETREGS, pid, 0, @ptrToInt(&regs));

    return RegSet{
        .raw_regs = regs,
    };
}
pub fn setRegs(pid: std.os.pid_t, regs: RegSet) !void {
    try ptrace(c.PTRACE_SETREGS, pid, 0, @ptrToInt(&regs.raw_regs));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = &gpa.allocator;

    const fork_pid = try std.os.fork();
    // wow this is probably slow if it has to copy the entire current process and then just replace the whole thing
    // because of execve
    if (fork_pid == 0) {
        try launchChildProcess();
        unreachable;
    }

    {
        const wait_res = std.os.waitpid(fork_pid, 0);
        std.log.info("Wait res: {}", .{wait_res});
    }

    try ptrace(c.PTRACE_SETOPTIONS, fork_pid, 0, c.PTRACE_O_EXITKILL);

    std.log.info("Application has started", .{});

    const process_memory_file = blk: {
        const process_memory_file_name = try std.fmt.allocPrint0(alloc, "/proc/{d}/mem", .{fork_pid});
        defer alloc.free(process_memory_file_name);
        break :blk try std.os.openZ(process_memory_file_name, std.os.O_LARGEFILE, std.os.O_RDONLY);
    };
    defer std.os.close(process_memory_file);

    while (true) {
        try waitForSyscall(fork_pid);
        var regs = try getRegs(fork_pid);
        const syscall = regs.get(.syscall);
        std.log.info("Regs: syscall: {}, a0: {}, a1: {}", .{ regs.get(.syscall), regs.get(.a0), regs.get(.a1) });

        regs.set(.syscall, @bitCast(usize, @as(isize, -1)));

        switch (syscall) {
            else => {},
            3 => {
                // exit
                regs.set(.syscall, @enumToInt(std.os.SYS.exit));
                regs.set(.a0, 0);
                std.log.info("Process requested to exit.", .{});
            },
        }

        // uuh if we need to run a syscall as the child process what do we do
        // like this is fine for syscalls with ≤2 args but what about >2 args

        // ah I can read memory from /proc/{pid}/mem
        // rather than using ptrace to look at individual bytes

        try waitForSyscall(fork_pid);

        switch (syscall) {
            else => {},
            2 => {
                // log
                std.log.info("Process has requested to log stuff.", .{});
                regs.set(.syscall, 0);

                const mem_addr = regs.get(.a0);
                const mem_len = regs.get(.a1);
                try std.os.lseek_SET(process_memory_file, mem_addr);

                var read_v: usize = 0;
                while (read_v < mem_len) {
                    const MAX_READ_COUNT = 100;
                    var read_block = [_]u8{undefined} ** MAX_READ_COUNT;
                    const read_count = std.math.min(MAX_READ_COUNT, mem_len - read_v);

                    const did_read_count = try std.os.read(process_memory_file, read_block[0..read_count]);

                    std.log.info("Process logged: {s}", .{read_block[0..did_read_count]});

                    read_v += did_read_count;
                }
            },
            3 => {
                std.log.info("Process has exited.", .{});
                break;
            },
        }
    }
}

// ok the goal
// create a system service that has some stuff
// - debug printing
// - opening a screen that you can write pixels to
// - launching more processes/creating services
// - safe multiprocess support
//   - one process can't hang forever and prevent other processes from running
//   - one process can't use up all the memory and crash the vm
//   - one process can't instruct another process to use up all the memory and crash it
//   - processes can run other processes with limited permissions or eg have permission
//     dialogs and stuff
//   - even the root process can't crash the vm (without an explicit call to crash the vm)
