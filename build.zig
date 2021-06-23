const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});

    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("servicetest", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.install();

    const sample_app = b.addExecutable("sample", "src/apps/sample.zig");
    sample_app.setTarget(std.zig.CrossTarget.parse(.{ .arch_os_abi = "native-freestanding" }) catch unreachable);
    sample_app.setBuildMode(mode);
    sample_app.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
