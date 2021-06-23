const std = @import("std");

const SyscallNumber = enum(usize) {
    load_library = 0,
    connect_to_service = 1,
    hello_world = 2,
    exit = 3,
};

pub fn syscall2(number: SyscallNumber, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize)
        : [number] "{rax}" (@enumToInt(number)),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2)
        : "rcx", "r11", "memory"
    );
}

export fn _start() noreturn {
    const hwtext: []const u8 = "Hello, World!";
    _ = syscall2(.hello_world, @ptrToInt(hwtext.ptr), hwtext.len);
    _ = syscall2(.exit, 0, 0);
    unreachable;
}
