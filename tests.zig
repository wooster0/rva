const std = @import("std");

var expected_binary: []const u8 = "";

// Writes all sources to files of the naming 0.asm, 1.asm, 2.asm, etc. to a temporary directory,
// then creates a symbol link for the current working directory's standard directory in the temporary directory,
// and then runs the test by using the current working directory's zig-out/bin/rva assembler on the first source file.
// Additionally also runs the formatter on all source files and makes sure the source code is formatted.
// If the expected state is success, compares using the last line's message.
// If the expected state is failure, compares using the error message.
fn test_sources(sources: []const [:0]const u8, expected_output: []const u8, expected_state: enum { success, failure }) anyerror!void {
    defer expected_binary = "";
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const current_path = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(current_path);
    const standard_path = try std.mem.concat(std.testing.allocator, u8, &.{ current_path, &.{std.fs.path.sep}, "standard" });
    defer std.testing.allocator.free(standard_path);
    try temporary_directory.dir.symLink(standard_path, "standard", .{ .is_directory = true });
    const assembler_executable_path = try std.mem.concat(std.testing.allocator, u8, &.{
        current_path,
        &.{std.fs.path.sep},
        "zig-out",
        &.{std.fs.path.sep},
        "bin",
        &.{std.fs.path.sep},
        "rva",
    });
    defer std.testing.allocator.free(assembler_executable_path);
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("TERM", "dumb");
    var root_source_file_path: []const u8 = undefined;
    std.debug.assert(sources.len != 0);
    for (sources, 0..) |source, index| {
        const source_file_path = try std.fmt.allocPrint(std.testing.allocator, "{d}.asm", .{index});
        defer if (index != 0) std.testing.allocator.free(source_file_path);
        errdefer if (index == 0) std.testing.allocator.free(source_file_path);
        try temporary_directory.dir.writeFile(.{ .sub_path = source_file_path, .data = source });
        if (index == 0) {
            root_source_file_path = source_file_path;
        }
        // Format the source code and make sure it does not change after formatting.
        // This also serves as test coverage for the formatter.
        const before = try temporary_directory.dir.readFileAlloc(std.testing.allocator, source_file_path, std.math.maxInt(usize));
        defer std.testing.allocator.free(before);
        const result = try std.process.Child.run(.{
            .allocator = std.testing.allocator,
            .argv = &.{ assembler_executable_path, "format", source_file_path },
            .cwd_dir = temporary_directory.dir,
            .env_map = &env_map,
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        if (result.term != .Exited or result.stdout.len != 0) {
            std.debug.print("standard output: {s}\n", .{result.stdout});
            std.debug.print("standard error: {s}\n", .{result.stderr});
        }
        const after = try temporary_directory.dir.readFileAlloc(std.testing.allocator, source_file_path, std.math.maxInt(usize));
        defer std.testing.allocator.free(after);
        if (!std.mem.eql(u8, before, after)) {
            std.debug.print("before: {s}\n", .{before});
            std.debug.print("after: {s}\n", .{after});
            return error.failure;
        }
    }
    defer std.testing.allocator.free(root_source_file_path);
    const result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ assembler_executable_path, root_source_file_path },
        .cwd_dir = temporary_directory.dir,
        .env_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    errdefer {
        std.debug.print("standard output: {s}\n", .{result.stdout});
        std.debug.print("standard error: {s}\n", .{result.stderr});
    }
    if (result.term != .Exited) {
        return error.failure;
    }
    const expected_exit_code: u8 = switch (expected_state) {
        .success => 0,
        .failure => 1,
    };
    if (result.term.Exited != expected_exit_code) {
        std.debug.print("exit code: {d}\n", .{result.term.Exited});
        return error.failure;
    }
    var output = switch (expected_state) {
        .success => result.stdout,
        .failure => result.stderr,
    };
    if (expected_output.len != 0) {
        std.debug.assert(std.mem.count(u8, expected_output, "\n") == 0);
        switch (expected_state) {
            .success => {
                if (std.mem.count(u8, output, "\n") != 1) return error.failure;
                output = output[0 .. output.len - "\n".len];
            },
            .failure => {
                if (std.mem.count(u8, output, "\n") != 3) return error.failure;
                // Cut off the source code output.
                output = output[0..std.mem.indexOf(u8, output, "\n").?];
            },
        }
    }
    if (!std.mem.eql(u8, output, expected_output)) {
        return error.failure;
    }
    switch (expected_state) {
        .success => {
            const binary = try temporary_directory.dir.readFileAlloc(std.testing.allocator, "0", std.math.maxInt(usize));
            defer std.testing.allocator.free(binary);
            try std.testing.expectEqualSlices(u8, expected_binary, binary);
            if (result.stderr.len != 0) {
                return error.failure;
            }
        },
        .failure => {
            if (result.stdout.len != 0) {
                return error.failure;
            }
        },
    }
}

fn expect_success(source: [:0]const u8, message: []const u8) anyerror!void {
    try test_sources(&.{source}, message, .success);
}

fn expect_success_multiple(sources: []const [:0]const u8, message: []const u8) anyerror!void {
    try test_sources(sources, message, .success);
}

fn expect_error(source: [:0]const u8, message: []const u8) anyerror!void {
    try test_sources(&.{source}, message, .failure);
}

fn expect_error_multiple(sources: []const [:0]const u8, message: []const u8) anyerror!void {
    try test_sources(sources, message, .failure);
}

test "testing infrastructure" {
    try expect_success(
        \\@log 123
    ,
        "0.asm:1:1: 123",
    );
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            ,
            \\@log 123
        },
        "1.asm:1:1: 123",
    );
    try expect_error(
        \\123
    ,
        "0.asm:1:1: error: expected instruction, assignment, directive, or label",
    );
    try expect_error_multiple(
        &.{
            \\@import "1.asm"
            ,
            \\123
        },
        "1.asm:1:1: error: expected instruction, assignment, directive, or label",
    );
}

test "empty source file" {
    try expect_success("", "");
}

test "zero in the middle of the source file" {
    try expect_error(
        \\@log 123\x00456
    ,
        "0.asm:1:9: error: meaningless",
    );
}

test "comments" {
    try expect_success("# hello world", "");
}

test "label scope" {
    try expect_error(
        \\label:
        \\@invoke {
        \\    @log :label
        \\};
    ,
        "0.asm:3:10: error: unknown label",
    );
    try expect_error(
        \\@invoke {
        \\    label:
        \\    @invoke {
        \\        @log :label
        \\    };
        \\};
    ,
        "0.asm:4:14: error: unknown label",
    );
}

test "variable scope" {
    try expect_error(
        \\@invoke {
        \\    variable = 123
        \\    @log variable
        \\};
        \\@log variable
    ,
        "0.asm:5:6: error: unknown variable",
    );
    try expect_error_multiple(
        &.{
            \\@import "1.asm"
            \\
            \\@log variable
            ,
            \\variable = 123
            \\@log variable
        },
        "0.asm:3:6: error: unknown variable",
    );
    try expect_success(
        \\variable = 123
        \\@invoke { @invoke {}; };
        \\@log variable
    ,
        "0.asm:3:1: 123",
    );
    try expect_success(
        \\variable = 123
        \\@invoke {
        \\    @invoke {
        \\        @log variable
        \\    };
        \\};
    ,
        "0.asm:4:9: 123",
    );
    try expect_success(
        \\variable = ?
        \\@invoke {
        \\    variable = 123
        \\};
        \\@log variable
    ,
        "0.asm:5:1: 123",
    );
    try expect_success(
        \\variable = ?
        \\@invoke {
        \\    @invoke {
        \\        variable = 123
        \\    };
        \\};
        \\@log variable
    ,
        "0.asm:7:1: 123",
    );
}

test "constant, instruction, and pseudoinstruction scopes" {
    try expect_error(
        \\@invoke { $constant = 123 };
    ,
        "0.asm:1:11: error: cannot define constant in non-root scope",
    );
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\
            \\@log $constant
            ,
            \\$constant = 123
        },
        "0.asm:3:1: 123",
    );
    try expect_error(
        \\@invoke { @instruction instruction x [] };
        \\instruction;
    ,
        "0.asm:1:11: error: cannot define instruction in non-root scope",
    );
    expected_binary = &.{ 0x00, 0x00, 0x00, 0x00 };
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\
            \\instruction;
            ,
            \\@instruction instruction x [0, 0]
        },
        "",
    );
    try expect_error(
        \\@invoke { @pseudoinstruction pseudoinstruction {} };
        \\pseudoinstruction;
    ,
        "0.asm:1:11: error: cannot define pseudoinstruction in non-root scope",
    );
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\
            \\pseudoinstruction;
            ,
            \\@pseudoinstruction pseudoinstruction {}
        },
        "",
    );
    try expect_error(
        \\@pseudoinstruction name {
        \\    @instruction name i []
        \\}
        \\name;
    ,
        "0.asm:2:5: error: cannot define instruction in non-root scope",
    );
}

test "unused variable" {
    try expect_error(
        \\variable = 123
    ,
        "0.asm:1:1: error: unused variable",
    );
    try expect_error(
        \\variable = 123
        \\variable = 123
    ,
        "0.asm:1:1: error: unused variable",
    );
    try expect_success(
        \\variable = 123
        \\variable = variable + 1
    ,
        "",
    );
}

test "unused label" {
    try expect_error(
        \\label:
    ,
        "0.asm:1:1: error: unused label",
    );
    try expect_error(
        \\block = {
        \\    label:
        \\}
        \\@invoke block;
    ,
        "0.asm:2:5: error: unused label",
    );
}

test "block labels" {
    try expect_error(
        \\block = { label: @log ::label }
        \\@invoke block;
    ,
        "0.asm:1:23: error: cannot use absolute label reference in block",
    );
    expected_binary = &.{ 0x00, 0x00, 0x00, 0x00 };
    try expect_success(
        \\@word 0
        \\block = { label: @log :label }
        \\@invoke block;
    ,
        "0.asm:2:18: 0",
    );
    expected_binary = &.{ 0x00, 0x00 };
    try expect_success(
        \\block = {
        \\    label: @byte :label
        \\}
        \\@inline block;
        \\@inline block;
    ,
        "",
    );
    try expect_success(
        \\block = {
        \\    label: @byte :label
        \\}
        \\@invoke block;
        \\@invoke block;
    ,
        "",
    );
    expected_binary = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x07 };
    try expect_success(
        \\@word 0
        \\block = { label: @origin 1 @byte :label }
        \\@word 0
        \\@inline block;
        \\@word 0
        \\@inline block;
    ,
        "",
    );
}

test "unused block operand" {
    try expect_error(
        \\@invoke {} 123
    ,
        "0.asm:1:12: error: block does not take operand",
    );
}

test "pseudoinstruction operands" {
    try expect_error(
        \\@pseudoinstruction pseudoinstruction {}
        \\pseudoinstruction 1, 2, 3
    ,
        "0.asm:2:19: error: block does not take operand",
    );
}

test "aliasing values" {
    try expect_success(
        \\string = "hello"
        \\alias = string
        \\string.0 = 'H'
        \\@log alias
    ,
        "0.asm:4:1: [72, 101, 108, 108, 111 / Hello]",
    );
    try expect_success(
        \\string = "abc"
        \\copy = [string.0, string.1, string.2]
        \\string.0 = 'A'
        \\@log copy
    ,
        "0.asm:4:1: [97, 98, 99 / abc]",
    );
}

test "pseudoinstructions" {
    try expect_success(
        \\@pseudoinstruction pseudoinstruction {}
        \\pseudoinstruction;
    ,
        "",
    );
    // TODO
    //expected_binary = &.{ 0x13, 0x10, 0x00, 0x00 };
    //try expect_success(
    //    \\@bits 32
    //    \\@import "pseudoinstructions"
    //    \\slli x0, x0, 0
    //,
    //    "",
    //);
    // TODO: need to research the 64 bit variant
    // expected_binary = &.{ 0x13, 0x10, 0x00, 0x00 };
    // try expect_success(
    //     \\@bits 64
    //     \\@import "pseudoinstructions"
    //     \\slli x0, x0, 4096
    // ,
    //     "",
    // );
}

test "instruction" {
    try expect_error(
        \\@instruction instruction x []
        \\instruction;
    ,
        "0.asm:2:1: error: instruction definition provides no operation code",
    );
}

test "label addresses" {
    expected_binary = &.{ 0x00, 0x00, 0x00 };
    try expect_success(
        \\label:
        \\@byte 0
        \\@byte 0
        \\@byte 0
        \\@log :label
    ,
        "0.asm:5:1: 18446744073709551613 / -3",
    );
    expected_binary = &.{ 0x00, 0x00, 0x00 };
    try expect_success(
        \\@log :label
        \\@byte 0
        \\@byte 0
        \\@byte 0
        \\label:
    ,
        "0.asm:1:1: 3",
    );
    expected_binary = &.{ 0x00, 0x00, 0x00, 0x00 };
    try expect_success(
        \\@word 0
        \\label:
        \\@log ::label
    ,
        "0.asm:3:1: 4",
    );
    expected_binary = &.{ 0x13, 0x00, 0x00, 0x00, 0x13, 0x40, 0xF0, 0xFF };
    try expect_success(
        \\@bits 32
        \\@import "rv32i"
        \\@import "pseudoinstructions"
        \\
        \\addi x0, x0, 0
        \\not x0, x0
        \\label:
        \\@log ::label
    ,
        "0.asm:8:1: 8",
    );
    expected_binary = &.{ 0x01, 0x02, 0x03 };
    try expect_success(
        \\@bytes [1, 2, 3]
        \\label:
        \\@log ::label
    ,
        "0.asm:3:1: 3",
    );
}

test "directives" {
    try expect_error("@abc", "0.asm:1:1: error: unknown directive");
}

test "constant, instruction, and pseudoinstruction redefinition" {
    try expect_error(
        \\$constant = 123
        \\$constant = 123
    ,
        "0.asm:2:1: error: constant already exists",
    );
    try expect_error(
        \\@instruction instruction x []
        \\@instruction instruction x []
    ,
        "0.asm:2:1: error: instruction already exists",
    );
    try expect_error(
        \\@pseudoinstruction x {}
        \\@pseudoinstruction x {}
    ,
        "0.asm:2:1: error: pseudoinstruction already exists",
    );
}

test "accessing register and block operand in @invoke after @invoke" {
    try expect_success(
        \\@invoke {
        \\    <x1> = 123
        \\    @invoke {};
        \\    @log <x1>
        \\};
    ,
        "0.asm:4:5: 123",
    );
    try expect_success(
        \\@invoke {
        \\    @invoke {};
        \\    @log $$
        \\} 123
    ,
        "0.asm:3:5: 123",
    );
}

test "integers" {
    try expect_success("@log 123", "0.asm:1:1: 123");
    try expect_success("@log 0xA", "0.asm:1:1: 10");
    try expect_success("@log 0xa", "0.asm:1:1: 10");
    try expect_success("@log 0b1010", "0.asm:1:1: 10");
    try expect_success("@log 'A'", "0.asm:1:1: 65");
    try expect_error("@log 0b_1010", "0.asm:1:6: error: leading digit separator");
    try expect_error("@log 0b1010_", "0.asm:1:6: error: trailing digit separator");
    try expect_error("@log 0b_", "0.asm:1:6: error: leading digit separator");
    try expect_success("@log 0b10_10", "0.asm:1:1: 10");
    try expect_error("@log 99999999999999999999", "0.asm:1:6: error: expected integer literal not bigger than 64 bits");
    try expect_success("@log - 123", "0.asm:1:1: 18446744073709551493 / -123");
    try expect_success("@log - 123456789", "0.asm:1:1: 18446744073586094827 / -123456789");
}

test "registers" {
    try expect_success("@log x0", "0.asm:1:1: x0");
}

test "blocks" {
    try expect_success("@log {}", "0.asm:1:1: {}");
    try expect_success(
        \\@log {
        \\
        \\}
    ,
        "0.asm:1:1: {}",
    );
    try expect_success("@log { @byte 123 }", "0.asm:1:1: {...}");
}

test "lists" {
    try expect_success("@log [1, 2, 3]", "0.asm:1:1: [1, 2, 3]");
    try expect_success("@log \"hello\"", "0.asm:1:1: [104, 101, 108, 108, 111 / hello]");
    try expect_error("@log \"hello\n", "0.asm:1:12: error: newline");
    try expect_error("@log \"hello", "0.asm:1:12: error: meaningless");
    try expect_success(
        \\@log
        \\```
        \\
        \\
        \\
        \\```
    ,
        "0.asm:1:1: [10, 10, 10]",
    );
    try expect_success(
        \\@log
        \\```
        \\A
        \\```
    ,
        "0.asm:1:1: [65, 10]",
    );
    try expect_success(
        \\@log ```
        \\     hello
        \\     world
        \\     ```
    ,
        "0.asm:1:1: [104, 101, 108, 108, 111, 10, 119, 111, 114, 108, 100, 10]",
    );
    try expect_success(
        \\@log ```
        \\     a
        \\
        \\     b
        \\     ```
    ,
        "0.asm:1:1: [97, 10, 10, 98, 10]",
    );
    try expect_success(
        \\@log ```
        \\
        \\     a
        \\
        \\     b
        \\
        \\     ```
    ,
        "0.asm:1:1: [10, 97, 10, 10, 98, 10, 10]",
    );
    try expect_success(
        \\@log ```
        \\     hello
        \\
        \\     world
        \\     ```.@
    ,
        "0.asm:1:1: 13",
    );
    try expect_success(
        \\@log ```
        \\
        \\     ```
    ,
        "0.asm:1:1: [10]",
    );
    try expect_success(
        \\@log ```
        \\     ```
    ,
        "0.asm:1:1: []",
    );
    try expect_success(
        \\@log
        \\```
        \\
        \\```
    ,
        "0.asm:1:1: [10]",
    );
    try expect_success(
        \\@log
        \\```
        \\```
    ,
        "0.asm:1:1: []",
    );
    try expect_error(
        \\@log
        \\```
        \\``
    ,
        "0.asm:3:3: error: expected grave accent",
    );
    try expect_error(
        \\@log
        \\```A
        \\```
    ,
        "0.asm:2:4: error: expected newline",
    );
    try expect_error(
        \\@log
        \\```
        \\``` A
    ,
        "0.asm:3:5: error: expected value",
    );
    try expect_error(
        \\@log ```
        \\     hello
        \\    A```
    ,
        "0.asm:3:5: error: expected matching indentation",
    );
    try expect_success(
        \\list = [1, 2, 3]
        \\@log list.0
    ,
        "0.asm:2:1: 1",
    );
    try expect_success(
        \\list = [1, 2, 3]
        \\@invoke {
        \\    <x1> = 0
        \\    element = (list.<x1>) - 1
        \\    @log element
        \\};
    ,
        "0.asm:5:5: 0",
    );
}

test "unknown" {
    try expect_success("@log ?", "0.asm:1:1: ?");
    try expect_success(
        \\variable = ?
        \\variable = 123
        \\@log variable
    ,
        "0.asm:3:1: 123",
    );
    try expect_error("@log ? + 1", "0.asm:1:6: error: expected integer");
}

test "redundancy in operations" {
    try expect_error("@log ((1 + 1) + (1 + 1))", "0.asm:1:6: error: redundant");
    try expect_error("@log (1 + 1)", "0.asm:1:6: error: redundant");
    try expect_error("@log (1)", "0.asm:1:8: error: redundant");
    try expect_error("@log (((1)))", "0.asm:1:10: error: redundant");
    try expect_error("@log 1 + (((1)))", "0.asm:1:14: error: redundant");
    try expect_error("@log 1 + (1)", "0.asm:1:12: error: redundant");
    try expect_error("@log (((1))) + 1", "0.asm:1:10: error: redundant");
    try expect_error("@log (1) + 1", "0.asm:1:8: error: redundant");
}

test "integer operations" {
    try expect_success("@log ((50 + 50) * 100) / 2", "0.asm:1:1: 5000");
    try expect_error("@log 1 + 1 + 1", "0.asm:1:12: error: expected instruction, assignment, directive, or label");
    try expect_success("@log [].@ + 1", "0.asm:1:1: 1");
    try expect_success("@log - 50 - 50", "0.asm:1:1: 18446744073709551516 / -100");
    try expect_success("@log 1 + [].@", "0.asm:1:1: 1");
    try expect_success(
        \\signed = - 32
        \\@log 32 + signed
    ,
        "0.asm:2:1: 0",
    );
    try expect_success(
        \\@import "rv32i"
        \\@invoke {
        \\    <x2> = 32
        \\    addi x1, x2, - 32
        \\    @log <x1>
        \\};
    ,
        "0.asm:5:5: 0",
    );
    try expect_success(
        \\@import "rv32i"
        \\@invoke {
        \\    <x2> = 32
        \\    <x3> = - 32
        \\    add x1, x2, x3
        \\    @log <x1>
        \\};
    ,
        "0.asm:6:5: 0",
    );
    try expect_success(
        \\@import "rv64i"
        \\@invoke {
        \\    <x2> = 32
        \\    <x3> = - 32
        \\    addw x1, x2, x3
        \\    @log <x1>
        \\};
    ,
        "0.asm:6:5: 0",
    );
    try expect_success(
        \\@import "rv32i"
        \\@invoke {
        \\    <x2> = 32
        \\    <x3> = - 32
        \\    sub x1, x2, x3
        \\    @log <x1>
        \\};
    ,
        "0.asm:6:5: 64",
    );
    try expect_success(
        \\@import "rv64i"
        \\@invoke {
        \\    <x2> = 32
        \\    <x3> = - 32
        \\    subw x1, x2, x3
        \\    @log <x1>
        \\};
    ,
        "0.asm:6:5: 64",
    );
}

test "list operations" {
    try expect_success("@log [1, 2, 3] ++ [4, 5, 6]", "0.asm:1:1: [1, 2, 3, 4, 5, 6]");
    try expect_success("@log [1, 2, 3] ** 2", "0.asm:1:1: [1, 2, 3, 1, 2, 3]");
    try expect_success("@log [] ** 0", "0.asm:1:1: []");
    try expect_success("@log [] ++ []", "0.asm:1:1: []");
    try expect_success("@log [1, 2, 3].@", "0.asm:1:1: 3");
    try expect_success(
        \\list = [1, 2, 3]
        \\list.0 = (list.0) * 10
        \\list.1 = (list.1) * 10
        \\list.2 = (list.2) * 10
        \\@log list
    ,
        "0.asm:5:1: [10, 20, 30]",
    );
}

test "block operand" {
    // TODO
    //try expect_success(
    //    \\block = {
    //    \\    $$.0 = 1
    //    \\    @log $$
    //    \\}
    //    \\list = [0, 2, 3]
    //    \\@invoke block list
    //,
    //    "0.asm:3:5: [1, 2, 3]",
    //);
    try expect_error(
        \\@import "rv32i"
        \\@pseudoinstruction pseudoinstruction {
        \\    instruction = { addi $$.0, $$.1, $$.2 }
        \\    @inline instruction;
        \\}
        \\pseudoinstruction x0, x0, 0
    ,
        "0.asm:3:26: error: no block operand",
    );
    expected_binary = &.{ 0x13, 0x00, 0x00, 0x00 };
    try expect_success(
        \\@import "rv32i"
        \\@pseudoinstruction pseudoinstruction {
        \\    instruction = { addi $$.0, $$.1, $$.2 }
        \\    @inline instruction $$
        \\}
        \\pseudoinstruction x0, x0, 0
    ,
        "",
    );
}

test "not taking an operand" {
    try expect_error("@invoke {}", "0.asm:1:10: error: expected value");
    try expect_success("@invoke {};", "");
    try expect_error("@import \"rv32i\"\necall", "0.asm:2:5: error: expected value");
    expected_binary = &.{ 0x73, 0x00, 0x00, 0x00 };
    try expect_success("@import \"rv32i\"\necall;", "");
}

test "case insensitivity" {
    try expect_success("VARIABLE = 123\n@log variable", "0.asm:2:1: 123");
    try expect_success("variable = 123\n@log VARIABLE", "0.asm:2:1: 123");
    try expect_success("$CONSTANT = 123\n@log $constant", "0.asm:2:1: 123");
    try expect_success("$constant = 123\n@log $CONSTANT", "0.asm:2:1: 123");
    try expect_success("LABEL:\n@log :label", "0.asm:2:1: 0");
    try expect_success("label:\n@log :LABEL", "0.asm:2:1: 0");
    try expect_success("@LOG 123", "0.asm:1:1: 123");
    try expect_success("@log ZERO", "0.asm:1:1: x0");
    expected_binary = &.{ 0x73, 0x00, 0x00, 0x00 };
    try expect_success("@import \"rv32i\"\nECALL;", "");
    expected_binary = &.{ 0x13, 0x40, 0xF0, 0xFF };
    try expect_success("@bits 32\n@import \"rv32i\"\n@import \"pseudoinstructions\"\nNOT x0, x0", "");
    expected_binary = &.{ 0x73, 0x00, 0x00, 0x00 };
    try expect_success("@import \"RV32I\"\necall;", "");
}

test "invocation" {
    try expect_success(
        \\@import "rv32i"
        \\
        \\@invoke {
        \\    <x1> = 100
        \\    addi x1, x1, 100
        \\    @log <x1>
        \\};
    ,
        "0.asm:6:5: 200",
    );
    try expect_success(
        \\@import "rv32i"
        \\
        \\@invoke {
        \\    times = x1
        \\    <times> = 5
        \\    index = x2
        \\    <index> = 0
        \\    loop:
        \\    beq index, times, :end
        \\    <index> = <index> + 1
        \\    jal zero, :loop
        \\    end:
        \\    @log <index>
        \\};
    ,
        "0.asm:13:5: 5",
    );
    try expect_success(
        \\@invoke {
        \\    @import "rv32i"
        \\    jal zero, :end
        \\    end:
        \\};
    ,
        "",
    );
    try expect_success(
        \\@invoke {
        \\    @import "rv32i"
        \\    count = 0
        \\    loop:
        \\    jal zero, :end
        \\    count = count + 1
        \\    end:
        \\    @byte :loop
        \\    @byte :end
        \\};
    ,
        "",
    );
    try expect_success(
        \\@invoke {
        \\    @import "rv32i"
        \\    @word 123
        \\    jal x1, :label
        \\    label:
        \\    @log <x1>
        \\};
    ,
        "0.asm:6:5: 8",
    );
    try expect_success(
        \\@invoke {
        \\    @import "rv32i"
        \\    @word 123
        \\    @origin 0
        \\    jal x1, :label
        \\    label:
        \\    @log <x1>
        \\};
    ,
        "0.asm:7:5: 4",
    );
    try expect_error(
        \\@import "rv32i"
        \\@invoke {
        \\    jal zero, 0
        \\};
    ,
        "0.asm:3:5: error: cannot jump to a relative address without relative label reference in invoke context",
    );
    try expect_error(
        \\@import "rv32i"
        \\@invoke {
        \\    <x1> = 123456789
        \\    jalr zero, x1, 0
        \\};
    ,
        "0.asm:4:5: error: cannot jump to an absolute address in invoke context",
    );
    try expect_error(
        \\@bits 32
        \\@import "pseudoinstructions"
        \\@invoke {
        \\    call :function
        \\    function:
        \\};
    ,
        "standard/pseudoinstructions.asm:64:5: error: cannot jump to an absolute address in invoke context",
    );
}

test "initial register value in invocation" {
    try expect_success("@invoke { @log <x1> };", "0.asm:1:11: 0");
    try expect_success("@invoke { @log <x31> };", "0.asm:1:11: 0");
}

test "zero register in invocation" {
    try expect_success(
        \\@invoke {
        \\    <x0> = 123
        \\    @log <x0>
        \\};
    ,
        "0.asm:3:5: 0",
    );
}

test "registers outside of invocation" {
    try expect_error("@log <x0>", "0.asm:1:6: error: outside invoke context");
    try expect_error("@log <x31>", "0.asm:1:6: error: outside invoke context");
}

test "wrong type of value passed" {
    try expect_error("@log 0 + []", "0.asm:1:10: error: expected integer");
    try expect_error("@log [] + 0", "0.asm:1:6: error: expected integer");
    try expect_error("@log ~ {}", "0.asm:1:6: error: expected integer");
    try expect_error("@origin 1 + 1", "0.asm:1:9: error: expected integer literal");
    try expect_error("label:\n@origin :label", "0.asm:2:9: error: expected integer literal");
    try expect_error("label:\n@origin ::label", "0.asm:2:9: error: expected integer literal");
    try expect_error("@bytes 0", "0.asm:1:8: error: expected list literal");
    try expect_error("@bytes [] ** 1", "0.asm:1:8: error: expected list literal");
    try expect_error("@byte {}", "0.asm:1:7: error: expected integer");
    try expect_error("@half {}", "0.asm:1:7: error: expected integer");
    try expect_error("@word {}", "0.asm:1:7: error: expected integer");
    try expect_error("@double {}", "0.asm:1:9: error: expected integer");
    try expect_error("@invoke 0;", "0.asm:1:9: error: expected block");
    try expect_error("@inline 0;", "0.asm:1:9: error: expected block");
    try expect_error("@pseudoinstruction 0", "0.asm:1:20: error: expected identifier");
    try expect_error("@pseudoinstruction x 0\nx;", "0.asm:1:22: error: expected block");
    try expect_error("@instruction 0", "0.asm:1:14: error: expected identifier");
    try expect_error("@instruction x A", "0.asm:1:16: error: unknown type");
    try expect_error("@instruction x r 0\nx;", "0.asm:2:1: error: expected list");
    try expect_error("@import 0", "0.asm:1:9: error: expected list literal");
    try expect_error("@log", "0.asm:1:4: error: expected value");
}

test "importing root scope code" {
    expected_binary = &.{ 0x13, 0x00, 0x00, 0x00 };
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            ,
            \\@import "rv32i"
            \\
            \\addi x0, x0, 0
        },
        "",
    );
}

test "importing instructions" {
    try expect_success_multiple(
        &.{
            \\@import "rv32i"
            \\@import "1.asm"
            ,
            \\@import "rv32i"
        },
        "",
    );
    expected_binary = &.{ 0x00, 0x00, 0x00, 0x00 };
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\instruction;
            ,
            \\@instruction instruction x [0, 0]
        },
        "",
    );
    try expect_error_multiple(
        &.{
            \\@import "1.asm"
            \\instruction;
            ,
            \\@import "2.asm"
            ,
            \\@instruction instruction x []
        },
        "0.asm:2:1: error: unknown instruction or pseudoinstruction",
    );
}

test "importing pseudoinstructions" {
    try expect_success_multiple(
        &.{
            \\@bits 32
            \\@import "pseudoinstructions"
            \\@import "1.asm"
            ,
            \\@import "pseudoinstructions"
        },
        "",
    );
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\pseudoinstruction;
            ,
            \\@pseudoinstruction pseudoinstruction {}
        },
        "",
    );
    try expect_error_multiple(
        &.{
            \\@import "1.asm"
            \\pseudoinstruction;
            ,
            \\@import "2.asm"
            ,
            \\@pseudoinstruction pseudoinstruction {}
        },
        "0.asm:2:1: error: unknown instruction or pseudoinstruction",
    );
}

test "importing constants" {
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\@log $constant
            ,
            \\$constant = 123
        },
        "0.asm:2:1: 123",
    );
    try expect_error_multiple(
        &.{
            \\$constant = 123
            \\@import "1.asm"
            ,
            \\$constant = 123
        },
        "1.asm:1:1: error: constant already exists",
    );
    expected_binary = &.{ 0x00, 0x01, 0x02 };
    try expect_success_multiple(
        &.{
            \\@byte 0
            \\@import "1.asm"
            \\
            \\@log $constant
            ,
            \\@byte 1
            \\@import "2.asm"
            ,
            \\@byte 2
            \\$constant = 123
        },
        "0.asm:4:1: 123",
    );
}

test "@inline in @invoke" {
    try expect_success(
        \\block = {
        \\    @byte 123
        \\}
        \\
        \\@invoke { @inline block; };
    ,
        "",
    );
}

test "@invoke in @inline" {
    try expect_success(
        \\block = {
        \\    @byte 123
        \\}
        \\
        \\@inline { @invoke block; };
    ,
        "",
    );
}

test "@bits and $bits" {
    try expect_error(
        \\@log $bits
    ,
        "0.asm:1:6: error: unknown bit size",
    );
    try expect_error(
        \\@bits $bits
    ,
        "0.asm:1:7: error: unknown bit size",
    );
    try expect_error(
        \\@bits 16
    ,
        "0.asm:1:7: error: expected 32 or 64",
    );
    try expect_success(
        \\@bits 32
        \\@log $bits
    ,
        "0.asm:2:1: 32",
    );
    try expect_success(
        \\@bits 32
        \\@bits 64
        \\@log $bits
    ,
        "0.asm:3:1: 64",
    );
    try expect_error(
        \\$bits = 123
    ,
        "0.asm:1:1: error: cannot define $bits without @bits",
    );
}

test "shadowing variable" {
    try expect_error(
        \\name = 123
        \\@instruction name x []
    ,
        "0.asm:2:1: error: variable with this name already exists",
    );
    try expect_error(
        \\name = 123
        \\@pseudoinstruction name {}
    ,
        "0.asm:2:1: error: variable with this name already exists",
    );
    try expect_error_multiple(
        &.{
            \\name = 123
            \\@import "1.asm"
            ,
            \\@instruction name x []
        },
        "0.asm:1:1: error: variable with this name already exists",
    );
    try expect_error_multiple(
        &.{
            \\name = 123
            \\@import "1.asm"
            ,
            \\@pseudoinstruction name {}
        },
        "0.asm:1:1: error: variable with this name already exists",
    );
}

test "shadowing instruction or pseudoinstruction" {
    try expect_error(
        \\@instruction name x []
        \\@pseudoinstruction name {}
    ,
        "0.asm:2:1: error: instruction with this name already exists",
    );
    try expect_error(
        \\@pseudoinstruction name {}
        \\@instruction name x []
    ,
        "0.asm:2:1: error: pseudoinstruction with this name already exists",
    );
    try expect_error_multiple(
        &.{
            \\@import "1.asm"
            \\name = 123
            ,
            \\@instruction name x []
        },
        "0.asm:2:1: error: instruction with this name already exists",
    );
    try expect_error_multiple(
        &.{
            \\@import "1.asm"
            \\name = 123
            ,
            \\@pseudoinstruction name {}
        },
        "0.asm:2:1: error: pseudoinstruction with this name already exists",
    );
    try expect_error_multiple(
        &.{
            \\@import "1.asm"
            \\@instruction name x []
            ,
            \\@pseudoinstruction name {}
        },
        "0.asm:2:1: error: pseudoinstruction with this name already exists",
    );
    try expect_error_multiple(
        &.{
            \\@import "1.asm"
            \\@pseudoinstruction name {}
            ,
            \\@instruction name x []
        },
        "0.asm:2:1: error: instruction with this name already exists",
    );
    try expect_error_multiple(
        &.{
            \\@instruction name x []
            \\@import "1.asm"
            ,
            \\@pseudoinstruction name {}
        },
        "0.asm:1:1: error: instruction with this name already exists",
    );
    try expect_error_multiple(
        &.{
            \\@pseudoinstruction name {}
            \\@import "1.asm"
            ,
            \\@instruction name x []
        },
        "0.asm:1:1: error: pseudoinstruction with this name already exists",
    );
}

test "shadowing register" {
    try expect_error(
        \\x1 = 123
    ,
        "0.asm:1:1: error: expected instruction, assignment, directive, or label",
    );
    try expect_error(
        \\@instruction x1 x []
    ,
        "0.asm:1:14: error: expected identifier",
    );
    try expect_error(
        \\@pseudoinstruction x1 {}
    ,
        "0.asm:1:20: error: expected identifier",
    );
}

test "importing the same instruction or pseudoinstruction again" {
    try expect_success_multiple(
        &.{
            \\@instruction name x []
            \\@import "1.asm"
            ,
            \\@instruction name x []
        },
        "",
    );
    try expect_success_multiple(
        &.{
            \\@pseudoinstruction name {}
            \\@import "1.asm"
            ,
            \\@pseudoinstruction name {}
        },
        "",
    );
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\@instruction name x []
            ,
            \\@instruction name x []
        },
        "",
    );
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\@pseudoinstruction name {}
            ,
            \\@pseudoinstruction name {}
        },
        "",
    );
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\@import "1.asm"
            ,
            \\@instruction name x []
        },
        "",
    );
    try expect_success_multiple(
        &.{
            \\@import "1.asm"
            \\@import "1.asm"
            ,
            \\@pseudoinstruction name {}
        },
        "",
    );
}

test "accessing memory" {
    // TODO: not sure
    //try expect_success(
    //    \\@import "rv32i"
    //    \\@import "rv64i"
    //    \\
    //    \\@invoke {
    //    \\    <x1> = 123
    //    \\    sw x0, x1, 0
    //    \\    lwu x2, x0, 0
    //    \\    @log <x2>
    //    \\};
    //,
    //    "123",
    //);
    // TODO: not sure
    //try expect_success(
    //    \\@import "rv32i"
    //    \\@import "rv64i"
    //    \\
    //    \\@invoke {
    //    \\    memory: @word 123
    //    \\    lwu x2, x0, :memory
    //    \\    @log <x2>
    //    \\};
    //,
    //    "123",
    //);
}

test "@origin" {
    try expect_success(
        \\@origin 1000
        \\label:
        \\@log ::label
    ,
        "0.asm:3:1: 1000",
    );
    try expect_success(
        \\@origin 1000
        \\label:
        \\@origin 500
        \\@log ::label
    ,
        "0.asm:4:1: 1000",
    );
}
