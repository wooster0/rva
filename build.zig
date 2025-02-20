const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .unwind_tables = .none,
    });

    const executable = b.addExecutable(.{
        .name = "rva",
        .root_module = module,
    });
    executable.error_limit = 0xff;
    b.installArtifact(executable);

    // if (optimize == .ReleaseSmall) {
    //     const strip_section_headers = b.addSystemCommand(&.{
    //         "objcopy",
    //         "--strip-section-headers",
    //     });
    //     strip_section_headers.addArg("zig-out/bin/rva");
    //     strip_section_headers.step.dependOn(&executable.step);
    //     b.getInstallStep().dependOn(&strip_section_headers.step);
    // }

    const test_step = b.step("test", "Run tests");
    // Make sure we can build for these architectures.
    const riscv32_executable = b.addExecutable(.{
        .name = "rva",
        .root_source_file = b.path("main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .riscv32 }),
    });
    test_step.dependOn(&riscv32_executable.step);
    const riscv64_executable = b.addExecutable(.{
        .name = "rva",
        .root_source_file = b.path("main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64 }),
    });
    test_step.dependOn(&riscv64_executable.step);
    const tests = b.addTest(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_tests.step);
}
