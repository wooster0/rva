// Resolves label references, handles block invocation, and emits machine code.

const std = @import("std");
const builtin = @import("builtin");

const Command = @import("main.zig").Command;
const Source = @import("main.zig").Source;
const MaximumBitSize = @import("main.zig").MaximumBitSize;
const MaximumBitSizeSigned = @import("main.zig").MaximumBitSizeSigned;
const RegisterIndex = @import("main.zig").RegisterIndex;
const SourceBundle = @import("main.zig").SourceBundle;
const SourceSize = @import("main.zig").SourceSize;
const SourceRange = @import("main.zig").SourceRange;
const error_with_source_range = @import("main.zig").error_with_source_range;
const error_with_out_of_memory = @import("main.zig").error_with_out_of_memory;
const compare_ignore_case = @import("main.zig").compare_ignore_case;
const cast_or_null = @import("main.zig").cast_or_null;
const abort = @import("main.zig").abort;
const index_commands_tag = @import("main.zig").index_commands_tag;
const index_commands_operand = @import("main.zig").index_commands_operand;
const index_commands_tag_pointer = @import("main.zig").index_commands_tag_pointer;
const index_commands_operand_pointer = @import("main.zig").index_commands_operand_pointer;
const log_terminal_config = &@import("main.zig").log_terminal_config;

const Assembler = @This();

commands: std.MultiArrayList(Command).Slice,
values: []Value = undefined,
sources: []const Source,
invoke_contexts: std.ArrayListUnmanaged(InvokeContext) = .{},
block_operand: Command.Index = Command.special.none,
output: std.ArrayListUnmanaged(u8) = .{},
allocator: std.mem.Allocator,

const InvokeContext = struct {
    registers: [32]MaximumBitSize = @splat(initial),
    memory: Memory = .{},
    address: MaximumBitSize = 0,
    target_relative_label: ?SourceBundle = null,

    const initial = 0;

    fn read_register(context: InvokeContext, register: RegisterIndex) MaximumBitSize {
        return context.registers[register];
    }

    fn write_register(context: *InvokeContext, register: RegisterIndex, operand: MaximumBitSize) void {
        context.registers[register] = operand;
        context.registers[0] = 0;
    }

    const Memory = struct {
        bytes: std.AutoArrayHashMapUnmanaged(MaximumBitSize, u8) = .{},

        fn store(memory: *Memory, allocator: std.mem.Allocator, address: MaximumBitSize, integer: anytype) void {
            const byte_count = @sizeOf(@TypeOf(integer));
            var byte_index: u8 = 0;
            const offset_end: MaximumBitSize = @intCast(@as(MaximumBitSizeSigned, @bitCast(address)) + byte_count);
            var offset = address;
            while (offset < offset_end) : (offset += 1) {
                const byte = @as([byte_count]u8, @bitCast(integer))[byte_index];
                memory.bytes.put(allocator, offset, byte) catch error_with_out_of_memory();
                byte_index += 1;
            }
        }

        fn load(memory: Memory, byte_count: comptime_int, address: MaximumBitSize) @Type(.{ .int = .{ .signedness = .unsigned, .bits = byte_count * 8 } }) {
            var read_bytes: [byte_count]u8 = undefined;
            var byte_index: u8 = 0;
            const offset_end: MaximumBitSize = @intCast(@as(MaximumBitSizeSigned, @bitCast(address)) + byte_count);
            var offset = address;
            while (offset < offset_end) : (offset += 1) {
                read_bytes[byte_index] = memory.bytes.get(offset) orelse initial;
                byte_index += 1;
            }
            return @bitCast(read_bytes);
        }
    };
};

const Value = union(Type) {
    integer: Command.Operand.Integer,
    register: Command.Operand.Register,
    block: Command.Operand.Block,
    list: Command.Operand.List,
    unknown,

    const Type = enum {
        integer,
        register,
        block,
        list,
        unknown,
    };
};

fn resolve(
    assembler: *Assembler,
    index: Command.Index,
    comptime expected_type: ?Value.Type,
    source_bundle: SourceBundle,
) if (expected_type) |@"type"| switch (@"type") {
    .integer => Command.Operand.Integer,
    .register => Command.Operand.Register,
    .block => Command.Operand.Block,
    .list => Command.Operand.List,
    .unknown => unreachable,
} else Value {
    const value: Value = switch (index) {
        Command.special.none => unreachable,
        Command.special.bytes_start...Command.special.bytes_end => .{ .integer = index - Command.special.bytes_start },
        Command.special.registers_start...Command.special.registers_end => .{ .register = @intCast(index - Command.special.registers_start) },
        Command.special.empty_block => .{ .block = .{ .length = 0, .resolved = true } },
        Command.special.empty_list => .{ .list = &.{} },
        Command.special.unknown => .unknown,
        else => assembler.values[index],
    };
    if (expected_type) |@"type"| {
        if (value != @"type") {
            assembler.error_with_source_bundle(source_bundle, "{s}", .{@tagName(value)}, "expected " ++ @tagName(@"type"), .{});
        }
        return switch (@"type") {
            .integer => value.integer,
            .register => value.register,
            .block => value.block,
            .list => value.list,
            .unknown => unreachable,
        };
    } else {
        return value;
    }
}

fn error_with_source_bundle(
    assembler: *Assembler,
    source_bundle: SourceBundle,
    comptime item_format: []const u8,
    item_arguments: anytype,
    comptime message_format: []const u8,
    message_arguments: anytype,
) noreturn {
    @branchHint(.cold);
    const source = assembler.sources[source_bundle.index];
    error_with_source_range(
        source.source,
        source.file_path,
        source_bundle.range,
        item_format,
        item_arguments,
        message_format,
        message_arguments,
    );
}

fn look_up_label_definition_name(assembler: Assembler, source_bundle: SourceBundle) []const u8 {
    return assembler.sources[source_bundle.index].source[source_bundle.range.start .. source_bundle.range.end - ":".len];
}

fn look_up_relative_label_reference_name(assembler: Assembler, source_bundle: SourceBundle) []const u8 {
    return assembler.sources[source_bundle.index].source[source_bundle.range.start + ":".len .. source_bundle.range.end];
}

fn look_up_absolute_label_reference_name(assembler: Assembler, source_bundle: SourceBundle) []const u8 {
    return assembler.sources[source_bundle.index].source[source_bundle.range.start + "::".len .. source_bundle.range.end];
}

fn resolve_label_references(assembler: *Assembler, address: *MaximumBitSize, start: Command.Index, end: Command.Index, in_block: bool) void {
    const LabelDefinition = struct {
        address: MaximumBitSize,
        source_bundle: SourceBundle,
        used: bool,
    };
    var labels: std.StringArrayHashMapUnmanaged(LabelDefinition) = .{};
    // Figure out the addresses of all label definitions.
    {
        var command_index: Command.Index = start;
        while (command_index < end) : (command_index += 1) {
            const tag = index_commands_tag_pointer(assembler.commands, command_index) orelse continue;
            const operand = index_commands_operand_pointer(assembler.commands, command_index).?;
            assembler.print_command("resolve", tag.*, operand.*, command_index, Command.special.none);
            switch (tag.*) {
                .block => {
                    command_index += operand.block.length;
                },
                .here => {
                    // This can be fixed up immediately.
                    tag.* = .integer;
                    operand.* = .{ .integer = address.* };
                },
                .label_definition => {
                    const source = assembler.sources[operand.source_bundle.index].source;
                    const key = std.ascii.allocLowerString(
                        assembler.allocator,
                        source[operand.source_bundle.range.start .. operand.source_bundle.range.end - ":".len],
                    ) catch error_with_out_of_memory();
                    const result = labels.getOrPut(assembler.allocator, key) catch error_with_out_of_memory();
                    if (result.found_existing) {
                        assembler.error_with_source_bundle(operand.source_bundle, "label", .{}, "label already exists", .{});
                    }
                    result.value_ptr.* = .{
                        .address = address.*,
                        .source_bundle = operand.source_bundle,
                        .used = false,
                    };
                },
                .relative_label_reference => {
                    // This command will be fixed up to an .integer below.
                    // Note the address of this reference in order to make the address relative.
                    operand.label_reference.address = address.*;
                },
                .absolute_label_reference => {
                    if (in_block) {
                        assembler.error_with_source_bundle(operand.label_reference.source_bundle, "absolute label reference", .{}, "cannot use absolute label reference in block", .{});
                    }
                    // This command will be fixed up to an .integer below.
                },
                .instruction => address.* += @sizeOf(EncodedInstruction),
                .directive_inline, .directive_invoke => {
                    const block_tag = index_commands_tag(assembler.commands, operand.block_and_operand.block);
                    if (block_tag != .block) {
                        assembler.error_with_source_bundle(operand.block_and_operand.block_source_bundle, "non-block", .{}, "expected block", .{});
                    }
                    const block_operand = index_commands_operand_pointer(assembler.commands, operand.block_and_operand.block) orelse {
                        // It is the empty block which does not need to be resolved.
                        continue;
                    };
                    // Add one to skip the .block instruction itself.
                    const block_start = operand.block_and_operand.block + 1;
                    const block_end = block_start + block_operand.block.length;
                    if (!block_operand.block.resolved) {
                        assembler.resolve_label_references(address, block_start, block_end, true);
                        block_operand.block.resolved = true;
                    }
                },
                .directive_origin => {
                    const operand_tag = index_commands_tag(assembler.commands, operand.unary.operand);
                    if (operand_tag != .integer) {
                        assembler.error_with_source_bundle(operand.unary.source_bundle, "non-integer literal", .{}, "expected integer literal", .{});
                    }
                    const operand_operand = index_commands_operand(assembler.commands, operand.unary.operand);
                    address.* = operand_operand.integer;
                },
                .directive_bytes => {
                    const operand_tag = index_commands_tag(assembler.commands, operand.unary.operand);
                    if (operand_tag != .list) {
                        assembler.error_with_source_bundle(operand.unary.source_bundle, "non-list literal", .{}, "expected list literal", .{});
                    }
                    // Whether these are actually bytes will be checked later on.
                    const operand_operand = index_commands_operand(assembler.commands, operand.unary.operand);
                    const list = operand_operand.list;
                    address.* += list.len;
                },
                .directive_byte => address.* += 1,
                .directive_half => address.* += 2,
                .directive_word => address.* += 4,
                .directive_double => address.* += 8,
                else => {},
            }
        }
    }
    // Fix up all label references.
    {
        var command_index: Command.Index = start;
        while (command_index < end) : (command_index += 1) {
            const tag = index_commands_tag_pointer(assembler.commands, command_index) orelse continue;
            const operand = index_commands_operand_pointer(assembler.commands, command_index).?;
            assembler.print_command("fixup", tag.*, operand.*, command_index, Command.special.none);
            switch (tag.*) {
                .block => {
                    command_index += operand.block.length;
                },
                .relative_label_reference => {
                    const label_reference = index_commands_operand(assembler.commands, command_index).label_reference;
                    const key = std.ascii.allocLowerString(
                        assembler.allocator,
                        assembler.look_up_relative_label_reference_name(label_reference.source_bundle),
                    ) catch error_with_out_of_memory();
                    const label = labels.getPtr(key) orelse {
                        assembler.error_with_source_bundle(label_reference.source_bundle, "label", .{}, "unknown label", .{});
                    };
                    const offset = @as(MaximumBitSizeSigned, @intCast(label.address)) - @as(MaximumBitSizeSigned, @intCast(label_reference.address));
                    tag.* = .integer;
                    operand.* = .{ .integer = @bitCast(offset) };
                    label.used = true;
                },
                .absolute_label_reference => {
                    const label_reference = index_commands_operand(assembler.commands, command_index).label_reference;
                    const key = std.ascii.allocLowerString(
                        assembler.allocator,
                        assembler.look_up_absolute_label_reference_name(label_reference.source_bundle),
                    ) catch error_with_out_of_memory();
                    const label = labels.getPtr(key) orelse {
                        assembler.error_with_source_bundle(label_reference.source_bundle, "label", .{}, "unknown label", .{});
                    };
                    tag.* = .integer;
                    operand.* = .{ .integer = label.address };
                    label.used = true;
                },
                else => {},
            }
        }
    }
    for (labels.values()) |label| {
        if (!label.used) {
            assembler.error_with_source_bundle(label.source_bundle, "label", .{}, "unused label", .{});
        }
    }
}

fn print_command(assembler: Assembler, label: []const u8, tag: Command.Tag, operand: Command.Operand, index: Command.Index, block_operand: Command.Index) void {
    if (builtin.mode != .Debug) return;
    // Use standard input to allow this output to be separated from standard output and standard error output when testing.
    const standard_input = std.io.getStdIn();
    var buffered_writer = std.io.bufferedWriter(standard_input.writer());
    const writer = buffered_writer.writer();
    var buffer: [32]u8 = undefined;
    writer.print("{s}: {s} = {s}(", .{ label, Command.format(index, &buffer), @tagName(tag) }) catch abort();
    switch (tag) {
        .integer => writer.print("{d}", .{operand.integer}) catch abort(),
        .register => {
            // This always uses a special representation.
            unreachable;
        },
        .block => writer.print("length={d}", .{operand.block.length}) catch abort(),
        .list => {
            for (operand.list, 0..) |value, list_index| {
                writer.writeAll(Command.format(value, &buffer)) catch abort();
                if (list_index != operand.list.len - 1) {
                    writer.writeAll(", ") catch return;
                }
            }
        },
        .label_definition => {
            writer.writeAll(
                assembler.sources[operand.source_bundle.index].source[operand.source_bundle.range.start .. operand.source_bundle.range.end - ":".len],
            ) catch abort();
        },
        .relative_label_reference => writer.writeAll(assembler.look_up_relative_label_reference_name(operand.label_reference.source_bundle)) catch abort(),
        .absolute_label_reference => writer.writeAll(assembler.look_up_absolute_label_reference_name(operand.label_reference.source_bundle)) catch abort(),
        .block_operand => writer.writeAll(Command.format(block_operand, &buffer)) catch abort(),
        .instruction => {
            writer.print("{s}, {s}, {s}", .{
                @tagName(operand.instruction.type),
                Command.format(operand.instruction.bits, &buffer),
                Command.format(operand.instruction.operands, &buffer),
            }) catch abort();
        },
        .list_element_write => {
            writer.print("{s}, {s}, {s}", .{
                Command.format(operand.list_element_write.list, &buffer),
                Command.format(operand.list_element_write.index, &buffer),
                Command.format(operand.list_element_write.element, &buffer),
            }) catch abort();
        },
        .register_write => {
            writer.print("{s}, {s}", .{ Command.format(operand.register_write.register, &buffer), Command.format(operand.register_write.value, &buffer) }) catch abort();
        },
        .directive_inline,
        .directive_invoke,
        => {
            writer.print("{s}, {s}", .{ Command.format(operand.block_and_operand.block, &buffer), Command.format(operand.block_and_operand.operand, &buffer) }) catch abort();
        },
        .directive_log => writer.writeAll(Command.format(operand.directive_log.operand, &buffer)) catch abort(),
        .here,
        .unknown,
        => {},
        .register_read,
        .directive_origin,
        .directive_bytes,
        .directive_byte,
        .directive_half,
        .directive_word,
        .directive_double,
        .bitwise_not,
        .negation,
        .list_length,
        => writer.writeAll(Command.format(operand.unary.operand, &buffer)) catch abort(),
        .addition,
        .subtraction,
        .multiplication,
        .division,
        .modulo,
        .concatenation,
        .duplication,
        .bitwise_and,
        .bitwise_or,
        .bitwise_xor,
        .bitwise_left_shift,
        .bitwise_right_shift,
        .index,
        => writer.print("{s}, {s}", .{ Command.format(operand.binary.left, &buffer), Command.format(operand.binary.right, &buffer) }) catch abort(),
    }
    writer.writeAll(")\n") catch abort();
    buffered_writer.flush() catch abort();
}

// Checks whether the given integer fits within the given amount of bits, either signed or unsigned, and returns the casted result.
fn cast(assembler: *Assembler, integer: MaximumBitSize, bit_count: comptime_int, source_bundle: SourceBundle) @Type(.{ .int = .{ .signedness = .unsigned, .bits = bit_count } }) {
    return cast_or_null(integer, bit_count) orelse {
        assembler.error_with_source_bundle(source_bundle, "integer", .{}, "expected integer not bigger than {d} bits", .{bit_count});
    };
}

fn invoke_context(assembler: *Assembler) ?*InvokeContext {
    if (assembler.invoke_contexts.items.len == 0) return null;
    return &assembler.invoke_contexts.items[assembler.invoke_contexts.items.len - 1];
}

pub fn assemble(assembler: *Assembler) void {
    var address: MaximumBitSize = 0;
    assembler.resolve_label_references(&address, 0, @intCast(assembler.commands.len), false);
    assembler.values = assembler.allocator.alloc(Value, assembler.commands.len) catch error_with_out_of_memory();
    var command_index: Command.Index = 0;
    while (command_index < assembler.commands.len) : (command_index += 1) {
        const tag = index_commands_tag(assembler.commands, command_index);
        const operand = index_commands_operand(assembler.commands, command_index);
        assembler.print_command("root", tag, operand, command_index, Command.special.none);
        const value_index = command_index;
        const value = assembler.assemble_command(tag, operand, &command_index, Command.special.none);
        assembler.values[value_index] = value;
    }
}

fn assemble_command(assembler: *Assembler, tag: Command.Tag, operand: Command.Operand, command_index: *Command.Index, block_operand: Command.Index) Value {
    switch (tag) {
        .integer => {
            return .{ .integer = operand.integer };
        },
        .register => {
            // This always uses a special representation.
            unreachable;
        },
        .block => {
            command_index.* += operand.block.length;
            return .{ .block = operand.block };
        },
        .list => {
            return .{ .list = operand.list };
        },
        // Handled in resolve_label_references.
        .here => unreachable,
        .block_operand => {
            if (block_operand == Command.special.none) {
                assembler.error_with_source_bundle(operand.source_bundle, "block operand", .{}, "no block operand", .{});
            }
            // The type can be any.
            return assembler.resolve(block_operand, null, undefined);
        },
        // Handled in resolve_label_references.
        .label_definition => {},
        // Handled in resolve_label_references.
        .relative_label_reference => unreachable,
        // Handled in resolve_label_references.
        .absolute_label_reference => unreachable,
        .instruction => assembler.assemble_instruction(operand.instruction),
        .list_element_write => assembler.assemble_list_element_write(operand.list_element_write),
        .register_read => return assembler.assemble_register_read(operand.unary),
        .register_write => assembler.assemble_register_write(operand.register_write),
        .directive_origin => {
            if (assembler.invoke_context()) |context| {
                // Type check already done in resolve_label_references.
                const address = assembler.resolve(operand.unary.operand, null, undefined).integer;
                context.address = address;
            } else {
                // Handled in resolve_label_references.
            }
        },
        .directive_inline => assembler.assemble_directive_inline(operand.block_and_operand),
        .directive_invoke => assembler.assemble_directive_invoke(operand.block_and_operand),
        .directive_log => assembler.assemble_directive_log(operand.directive_log),
        .directive_bytes => assembler.assemble_directive_bytes(operand.unary),
        .directive_byte => assembler.assemble_directive_size(operand.unary, u8),
        .directive_half => assembler.assemble_directive_size(operand.unary, u16),
        .directive_word => assembler.assemble_directive_size(operand.unary, u32),
        .directive_double => assembler.assemble_directive_size(operand.unary, u64),
        .addition => {
            const binary = operand.binary;
            const left_integer = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const right_integer = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            return .{ .integer = left_integer +% right_integer };
        },
        .subtraction => {
            const binary = operand.binary;
            const left_integer = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const right_integer = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            return .{ .integer = left_integer -% right_integer };
        },
        .multiplication => {
            const binary = operand.binary;
            const left_integer = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const right_integer = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            return .{ .integer = left_integer *% right_integer };
        },
        .division => {
            const binary = operand.binary;
            const dividend = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const divisor = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            if (builtin.target.cpu.arch.isRISCV()) {
                @setRuntimeSafety(false);
                return .{ .integer = dividend / divisor };
            } else {
                // Obey RISC-V division semantics.
                // For division by zero, the quotient (the result of division) has all bits set.
                if (divisor == 0) {
                    return .{ .integer = std.math.maxInt(MaximumBitSize) };
                } else {
                    return .{ .integer = dividend / divisor };
                }
            }
        },
        .modulo => {
            const binary = operand.binary;
            const dividend = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const divisor = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            if (builtin.target.cpu.arch.isRISCV()) {
                @setRuntimeSafety(false);
                return .{ .integer = dividend % divisor };
            } else {
                // Obey RISC-V division semantics.
                // For division by zero, the remainder (the result of modulo) equals the dividend.
                if (divisor == 0) {
                    return .{ .integer = dividend };
                } else {
                    return .{ .integer = dividend % divisor };
                }
            }
        },
        .concatenation => {
            const binary = operand.binary;
            const left_list = assembler.resolve(binary.left, .list, binary.left_source_bundle());
            const right_list = assembler.resolve(binary.right, .list, binary.right_source_bundle());
            const length = std.math.add(usize, left_list.len, right_list.len) catch {
                assembler.error_with_source_bundle(
                    binary.operation_source_bundle(),
                    "concatenation",
                    .{},
                    "resulting list is too long",
                    .{},
                );
            };
            const result = assembler.allocator.alloc(Command.Index, length) catch error_with_out_of_memory();
            @memcpy(result[0..left_list.len], left_list);
            @memcpy(result[left_list.len..][0..right_list.len], right_list);
            return .{ .list = result };
        },
        .duplication => {
            const binary = operand.binary;
            const list = assembler.resolve(binary.left, .list, binary.left_source_bundle());
            const duplicand = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            if (list.len == 0) return .{ .list = &.{} };
            const length = std.math.cast(usize, std.math.mulWide(MaximumBitSize, @as(MaximumBitSize, list.len), duplicand)) orelse {
                assembler.error_with_source_bundle(
                    binary.operation_source_bundle(),
                    "duplication",
                    .{},
                    "resulting list is too long",
                    .{},
                );
            };
            const result = assembler.allocator.alloc(Command.Index, length) catch error_with_out_of_memory();
            for (0..@intCast(duplicand)) |offset| {
                @memcpy(result[offset * list.len ..][0..list.len], list);
            }
            return .{ .list = result };
        },
        .bitwise_and => {
            const binary = operand.binary;
            const left_integer = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const right_integer = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            return .{ .integer = left_integer & right_integer };
        },
        .bitwise_or => {
            const binary = operand.binary;
            const left_integer = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const right_integer = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            return .{ .integer = left_integer | right_integer };
        },
        .bitwise_xor => {
            const binary = operand.binary;
            const left_integer = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const right_integer = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            return .{ .integer = left_integer ^ right_integer };
        },
        .bitwise_left_shift => {
            const binary = operand.binary;
            const left_integer = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const right_integer = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            return .{ .integer = left_integer << @truncate(right_integer) };
        },
        .bitwise_right_shift => {
            const binary = operand.binary;
            const left_integer = assembler.resolve(binary.left, .integer, binary.left_source_bundle());
            const right_integer = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            return .{ .integer = left_integer >> @truncate(right_integer) };
        },
        .index => {
            const binary = operand.binary;
            const list = assembler.resolve(binary.left, .list, binary.left_source_bundle());
            const index = assembler.resolve(binary.right, .integer, binary.right_source_bundle());
            if (index >= list.len) {
                assembler.error_with_source_bundle(
                    binary.operation_source_bundle(),
                    "index operation",
                    .{},
                    "index {d} is out of bounds of list with length {d}",
                    .{ index, list.len },
                );
            }
            // The type can be any.
            return assembler.resolve(list[@intCast(index)], null, undefined);
        },
        .bitwise_not => {
            const unary = operand.unary;
            const integer = assembler.resolve(unary.operand, .integer, unary.source_bundle);
            return .{ .integer = ~integer };
        },
        .negation => {
            const unary = operand.unary;
            const integer = assembler.resolve(unary.operand, .integer, unary.source_bundle);
            return .{ .integer = @bitCast(-@as(MaximumBitSizeSigned, @bitCast(integer))) };
        },
        .list_length => {
            const unary = operand.unary;
            const list = assembler.resolve(unary.operand, .list, unary.source_bundle);
            return .{ .integer = list.len };
        },
        .unknown => {
            return .{ .unknown = {} };
        },
    }
    // This command does not have a result.
    return undefined;
}

fn assemble_directive_bytes(assembler: *Assembler, unary: Command.Operand.Unary) void {
    // Type check already done in resolve_label_references.
    const list = assembler.resolve(unary.operand, null, undefined).list;
    for (list) |list_value| {
        const uncasted_integer = assembler.resolve(list_value, .integer, unary.source_bundle);
        const byte = cast_or_null(uncasted_integer, 8) orelse {
            assembler.error_with_source_bundle(unary.source_bundle, "non-byte list", .{}, "expected byte list", .{});
        };
        if (assembler.invoke_context()) |context| {
            context.memory.store(assembler.allocator, context.address, byte);
            context.address += 1;
        } else {
            assembler.output.writer(assembler.allocator).writeByte(byte) catch error_with_out_of_memory();
        }
    }
}

fn assemble_directive_size(assembler: *Assembler, unary: Command.Operand.Unary, Size: type) void {
    const uncasted_integer = assembler.resolve(unary.operand, .integer, unary.source_bundle);
    const integer = assembler.cast(uncasted_integer, @bitSizeOf(Size), unary.source_bundle);
    if (assembler.invoke_context()) |context| {
        context.memory.store(assembler.allocator, context.address, integer);
        context.address += @sizeOf(Size);
    } else {
        assembler.output.writer(assembler.allocator).writeInt(Size, integer, .little) catch error_with_out_of_memory();
    }
}

fn assemble_instruction(assembler: *Assembler, instruction: Command.Operand.Instruction) void {
    const bits = assembler.resolve(instruction.bits, .list, instruction.source_bundle);
    // This is always a list.
    const operands = assembler.resolve(instruction.operands, null, undefined).list;
    if (bits.len == 0) {
        assembler.error_with_source_bundle(instruction.source_bundle, "instruction", .{}, "instruction definition provides no operation code", .{});
    }
    const operation_code_uncasted = assembler.resolve(bits[0], .integer, instruction.source_bundle);
    const operation_code = assembler.cast(operation_code_uncasted, 7, instruction.source_bundle);
    var function3: u3 = undefined;
    var function7: u7 = undefined;
    var destination_register: RegisterIndex = undefined;
    var source_register: RegisterIndex = undefined;
    var source_register1: RegisterIndex = undefined;
    var source_register2: RegisterIndex = undefined;
    var immediate: MaximumBitSize = undefined;
    var other: u25 = undefined;
    switch (instruction.type) {
        .r => {
            if (operands.len != 3) {
                assembler.error_with_source_bundle(instruction.source_bundle, "instruction", .{}, "expected 1 destination register and 2 source registers", .{});
            }
            if (bits.len != 3) {
                assembler.error_with_source_bundle(
                    instruction.source_bundle,
                    "instruction",
                    .{},
                    "expected instruction definition to provide 1 operation code, 3 function bits, and 7 function bits",
                    .{},
                );
            }
            const uncasted_function3 = assembler.resolve(bits[1], .integer, instruction.source_bundle);
            function3 = assembler.cast(uncasted_function3, 3, instruction.source_bundle);
            const uncasted_function7 = assembler.resolve(bits[2], .integer, instruction.source_bundle);
            function7 = assembler.cast(uncasted_function7, 7, instruction.source_bundle);
            destination_register = assembler.resolve(operands[0], .register, instruction.source_bundle);
            source_register1 = assembler.resolve(operands[1], .register, instruction.source_bundle);
            source_register2 = assembler.resolve(operands[2], .register, instruction.source_bundle);
        },
        .i => {
            if (operands.len != 3) {
                assembler.error_with_source_bundle(instruction.source_bundle, "instruction", .{}, "expected 1 destination register, 1 source register, and 1 immediate", .{});
            }
            if (bits.len != 2) {
                assembler.error_with_source_bundle(
                    instruction.source_bundle,
                    "instruction",
                    .{},
                    "expected instruction definition to provide 1 operation code and 3 function bits",
                    .{},
                );
            }
            const uncasted_function3 = assembler.resolve(bits[1], .integer, instruction.source_bundle);
            function3 = assembler.cast(uncasted_function3, 3, instruction.source_bundle);
            destination_register = assembler.resolve(operands[0], .register, instruction.source_bundle);
            source_register = assembler.resolve(operands[1], .register, instruction.source_bundle);
            immediate = assembler.resolve(operands[2], .integer, instruction.source_bundle);
        },
        .s => {
            if (operands.len != 3) {
                assembler.error_with_source_bundle(instruction.source_bundle, "instruction", .{}, "expected 2 source registers and 1 immediate", .{});
            }
            if (bits.len != 2) {
                assembler.error_with_source_bundle(
                    instruction.source_bundle,
                    "instruction",
                    .{},
                    "expected instruction definition to provide 1 operation code and 3 function bits",
                    .{},
                );
            }
            const uncasted_function3 = assembler.resolve(bits[1], .integer, instruction.source_bundle);
            function3 = assembler.cast(uncasted_function3, 3, instruction.source_bundle);
            source_register1 = assembler.resolve(operands[0], .register, instruction.source_bundle);
            source_register2 = assembler.resolve(operands[1], .register, instruction.source_bundle);
            immediate = assembler.resolve(operands[2], .integer, instruction.source_bundle);
        },
        .b => {
            if (operands.len != 3) {
                assembler.error_with_source_bundle(instruction.source_bundle, "instruction", .{}, "expected 2 source registers and 1 immediate", .{});
            }
            if (bits.len != 2) {
                assembler.error_with_source_bundle(
                    instruction.source_bundle,
                    "instruction",
                    .{},
                    "expected instruction definition to provide 1 operation code and 3 function bits",
                    .{},
                );
            }
            const uncasted_function3 = assembler.resolve(bits[1], .integer, instruction.source_bundle);
            function3 = assembler.cast(uncasted_function3, 3, instruction.source_bundle);
            source_register1 = assembler.resolve(operands[0], .register, instruction.source_bundle);
            source_register2 = assembler.resolve(operands[1], .register, instruction.source_bundle);
            immediate = assembler.resolve(operands[2], .integer, instruction.source_bundle);
        },
        .u => {
            if (operands.len != 2) {
                assembler.error_with_source_bundle(instruction.source_bundle, "instruction", .{}, "expected 1 destination register and 1 immediate", .{});
            }
            destination_register = assembler.resolve(operands[0], .register, instruction.source_bundle);
            immediate = assembler.resolve(operands[1], .integer, instruction.source_bundle);
        },
        .j => {
            if (operands.len != 2) {
                assembler.error_with_source_bundle(instruction.source_bundle, "instruction", .{}, "expected 1 destination register and 1 immediate", .{});
            }
            destination_register = assembler.resolve(operands[0], .register, instruction.source_bundle);
            immediate = assembler.resolve(operands[1], .integer, instruction.source_bundle);
        },
        .other => {
            if (operands.len != 0) {
                assembler.error_with_source_bundle(instruction.source_bundle, "instruction", .{}, "expected no operands", .{});
            }
            if (bits.len != 2) {
                assembler.error_with_source_bundle(
                    instruction.source_bundle,
                    "instruction",
                    .{},
                    "expected instruction definition to provide 1 operation code and 25 other bits",
                    .{},
                );
            }
            const uncasted_other = assembler.resolve(bits[1], .integer, instruction.source_bundle);
            other = assembler.cast(uncasted_other, 25, instruction.source_bundle);
        },
    }
    if (assembler.invoke_context()) |context| {
        assembler.invoke_instruction(
            context,
            instruction.type,
            instruction.source_bundle,
            instruction.relative_label_reference,
            operation_code,
            function3,
            function7,
            destination_register,
            source_register,
            source_register1,
            source_register2,
            immediate,
            other,
        );
        context.address += @sizeOf(EncodedInstruction);
    } else {
        assembler.emit_instruction(
            instruction.type,
            instruction.source_bundle,
            operation_code,
            function3,
            function7,
            destination_register,
            source_register,
            source_register1,
            source_register2,
            immediate,
            other,
        );
    }
}

fn invoke_instruction(
    assembler: *Assembler,
    context: *InvokeContext,
    @"type": Command.Operand.Instruction.Type,
    source_bundle: SourceBundle,
    relative_label_reference: SourceBundle,
    operation_code: u7,
    function3: u3,
    function7: u7,
    destination_register: RegisterIndex,
    source_register: RegisterIndex,
    source_register1: RegisterIndex,
    source_register2: RegisterIndex,
    immediate: MaximumBitSize,
    other: u25,
) void {
    var source: MaximumBitSize = undefined;
    var source1: MaximumBitSize = undefined;
    var source2: MaximumBitSize = undefined;
    switch (@"type") {
        .r => {
            source1 = context.read_register(source_register1);
            source2 = context.read_register(source_register2);
        },
        .i => {
            source = context.read_register(source_register);
        },
        .s => {
            source1 = context.read_register(source_register1);
            source2 = context.read_register(source_register2);
        },
        .b => {
            source1 = context.read_register(source_register1);
            source2 = context.read_register(source_register2);
        },
        .u => {},
        .j => {},
        .other => {},
    }
    // These are all instructions included in RV32I, RV64I, RV32M, and RV64M.
    // This is based on the encoded representation of the instructions instead of mnemonics because only that matches with the semantics at runtime.
    switch (operation_code) {
        0b0110111 => { // LUI (RV32I)
            context.write_register(destination_register, immediate << 12);
        },
        0b0010111 => { // AUIPC (RV32I)
            const offset = immediate << 12;
            context.write_register(destination_register, offset +% context.address);
        },
        0b1101111 => { // JAL (RV32I)
            _ = assembler.cast(immediate, 12, source_bundle);
            context.write_register(destination_register, context.address +% @sizeOf(EncodedInstruction));
            if (relative_label_reference.is_none()) {
                assembler.error_with_source_bundle(source_bundle, "jal", .{}, "cannot jump to a relative address without relative label reference in invoke context", .{});
            } else {
                context.target_relative_label = relative_label_reference;
            }
        },
        0b1100111 => {
            switch (function3) {
                0b000 => { // JALR (RV32I)
                    assembler.error_with_source_bundle(source_bundle, "jalr", .{}, "cannot jump to an absolute address in invoke context", .{});
                },
                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
            }
        },
        0b1100011 => {
            _ = assembler.cast(immediate, 12, source_bundle);
            const branch = branch: switch (function3) {
                0b000 => { // BEQ (RV32I)
                    break :branch source1 == source2;
                },
                0b001 => { // BNE (RV32I)
                    break :branch source1 != source2;
                },
                0b100 => { // BLT (RV32I)
                    break :branch @as(MaximumBitSizeSigned, @bitCast(source1)) < @as(MaximumBitSizeSigned, @bitCast(source2));
                },
                0b101 => { // BGE (RV32I)
                    break :branch @as(MaximumBitSizeSigned, @bitCast(source1)) >= @as(MaximumBitSizeSigned, @bitCast(source2));
                },
                0b110 => { // BLTU (RV32I)
                    break :branch source1 < source2;
                },
                0b111 => { // BGEU (RV32I)
                    break :branch source1 >= source2;
                },
                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
            };
            if (branch) {
                if (relative_label_reference.is_none()) {
                    assembler.error_with_source_bundle(
                        source_bundle,
                        "branch instruction",
                        .{},
                        "cannot jump to a relative address without relative label reference in invoke context",
                        .{},
                    );
                } else {
                    context.target_relative_label = relative_label_reference;
                }
            }
        },
        0b0000011 => {
            const sized_immediate: i12 = @bitCast(assembler.cast(immediate, 12, source_bundle));
            const address: MaximumBitSize = @bitCast(@as(MaximumBitSizeSigned, @bitCast(context.address)) +% @as(MaximumBitSizeSigned, @bitCast(source)) +% sized_immediate);
            switch (function3) {
                0b000 => { // LB (RV32I)
                    context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, @as(i8, @bitCast(context.memory.load(1, address))))));
                },
                0b001 => { // LH (RV32I)
                    context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, @as(i16, @bitCast(context.memory.load(2, address))))));
                },
                0b010 => { // LW (RV32I)
                    context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, @as(i32, @bitCast(context.memory.load(4, address))))));
                },
                0b100 => { // LBU (RV32I)
                    context.write_register(destination_register, context.memory.load(1, address));
                },
                0b101 => { // LHU (RV32I)
                    context.write_register(destination_register, context.memory.load(2, address));
                },
                0b110 => { // LWU (RV64I)
                    context.write_register(destination_register, context.memory.load(4, address));
                },
                0b011 => { // LD (RV64I)
                    context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, @as(i64, @bitCast(context.memory.load(8, address))))));
                },
                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
            }
        },
        0b0100011 => {
            const sized_immediate: i12 = @bitCast(assembler.cast(immediate, 12, source_bundle));
            const address: MaximumBitSize = @bitCast(@as(MaximumBitSizeSigned, @bitCast(context.address)) +% @as(MaximumBitSizeSigned, @bitCast(source)) +% sized_immediate);
            switch (function3) {
                0b000 => { // SB (RV32I)
                    context.memory.store(assembler.allocator, address, @as(u8, @truncate(source2)));
                },
                0b001 => { // SH (RV32I)
                    context.memory.store(assembler.allocator, address, @as(u16, @truncate(source2)));
                },
                0b010 => { // SW (RV32I)
                    context.memory.store(assembler.allocator, address, @as(u32, @truncate(source2)));
                },
                0b011 => { // SD (RV64I)
                    context.memory.store(assembler.allocator, address, source2);
                },
                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
            }
        },
        0b0010011 => {
            const sized_immediate: i12 = @bitCast(assembler.cast(immediate, 12, source_bundle));
            switch (function3) {
                0b000 => { // ADDI (RV32I)
                    context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, @bitCast(source)) +% sized_immediate));
                },
                0b10 => { // SLTI (RV32I)
                    context.write_register(
                        destination_register,
                        @intFromBool(@as(MaximumBitSizeSigned, @bitCast(source)) < sized_immediate),
                    );
                },
                0b011 => { // SLTIU (RV32I)
                    context.write_register(destination_register, @intFromBool(source < sized_immediate));
                },
                0b100 => { // XORI (RV32I)
                    context.write_register(destination_register, source ^ @as(u12, @bitCast(sized_immediate)));
                },
                0b110 => { // ORI (RV32I)
                    context.write_register(destination_register, source | @as(u12, @bitCast(sized_immediate)));
                },
                0b111 => { // ANDI (RV32I)
                    context.write_register(destination_register, source & @as(u12, @bitCast(sized_immediate)));
                },
                0b001 => {
                    switch (function7) {
                        0b000000 => { // SLLI (RV32I, RV64I)
                            context.write_register(destination_register, source << @as(u6, @truncate(immediate)));
                        },
                        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                    }
                },
                0b101 => {
                    switch (function7) {
                        0b000000 => { // SRLI (RV32I, RV64I)
                            context.write_register(destination_register, source >> @as(u6, @truncate(immediate)));
                        },
                        0b010000 => { // SRAI (RV32I, RV64I)
                            context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, @bitCast(source)) >> @as(u6, @truncate(immediate))));
                        },
                        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                    }
                },
            }
        },
        0b0110011 => {
            switch (function7) {
                0b0000000 => {
                    switch (function3) {
                        0b000 => { // ADD (RV32I)
                            context.write_register(destination_register, source1 +% source2);
                        },
                        0b001 => { // SLL (RV32I)
                            context.write_register(destination_register, source1 << @as(u6, @truncate(source2)));
                        },
                        0b010 => { // SLT (RV32I)
                            context.write_register(
                                destination_register,
                                @intFromBool(@as(MaximumBitSizeSigned, @bitCast(source1)) < @as(MaximumBitSizeSigned, @bitCast(source2))),
                            );
                        },
                        0b011 => { // SLTU (RV32I)
                            context.write_register(destination_register, @intFromBool(source1 < source2));
                        },
                        0b100 => { // XOR (RV32I)
                            context.write_register(destination_register, source1 ^ source2);
                        },
                        0b101 => { // SRL (RV32I)
                            context.write_register(destination_register, source1 >> @as(u6, @truncate(source2)));
                        },
                        0b110 => { // OR (RV32I)
                            context.write_register(destination_register, source1 | source2);
                        },
                        0b111 => { // AND (RV32I)
                            context.write_register(destination_register, source1 & source2);
                        },
                    }
                },
                0b0100000 => {
                    switch (function3) {
                        0b000 => { // SUB (RV32I)
                            context.write_register(destination_register, source1 -% source2);
                        },
                        0b101 => { // SRA (RV32I)
                            context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, @bitCast(source1)) >> @as(u6, @truncate(source2))));
                        },
                        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                    }
                },
                0b0000001 => {
                    const ExtendedBitSize = @Type(.{ .int = .{ .signedness = .unsigned, .bits = @bitSizeOf(MaximumBitSize) * 2 } });
                    const ExtendedBitSizeSigned = @Type(.{ .int = .{ .signedness = .signed, .bits = @bitSizeOf(MaximumBitSize) * 2 } });
                    switch (function3) {
                        0b000 => { // MUL (RV32M)
                            context.write_register(destination_register, source1 *% source2);
                        },
                        0b001 => { // MULH (RV32M)
                            context.write_register(destination_register, @truncate(@as(ExtendedBitSize, @bitCast(
                                @as(ExtendedBitSizeSigned, @as(MaximumBitSizeSigned, @bitCast(source1)) *% @as(ExtendedBitSizeSigned, @as(MaximumBitSizeSigned, @bitCast(source2)))),
                            ))));
                        },
                        0b010 => { // MULHSU (RV32M)
                            context.write_register(destination_register, @truncate(@as(ExtendedBitSize, source1) *% @as(ExtendedBitSize, source2)));
                        },
                        0b011 => { // MULHU (RV32M)
                            context.write_register(destination_register, @truncate(@as(ExtendedBitSize, source1) *% @as(ExtendedBitSize, source2)));
                        },
                        0b100 => { // DIV (RV32M)
                            if (source2 == 0) {
                                context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, -1)));
                            } else {
                                context.write_register(
                                    destination_register,
                                    @bitCast(@divTrunc(@as(MaximumBitSizeSigned, @bitCast(source1)), @as(MaximumBitSizeSigned, @bitCast(source2)))),
                                );
                            }
                        },
                        0b101 => { // DIVU (RV32M)
                            if (source2 == 0) {
                                context.write_register(destination_register, std.math.maxInt(MaximumBitSize));
                            } else {
                                context.write_register(destination_register, source1 / source2);
                            }
                        },
                        0b110 => { // REM (RV32M)
                            if (source2 == 0) {
                                context.write_register(destination_register, source1);
                            } else {
                                context.write_register(
                                    destination_register,
                                    @bitCast(@rem(@as(MaximumBitSizeSigned, @bitCast(source1)), @as(MaximumBitSizeSigned, @bitCast(source2)))),
                                );
                            }
                        },
                        0b111 => { // REMU (RV32M)
                            if (source2 == 0) {
                                context.write_register(destination_register, source1);
                            } else {
                                context.write_register(destination_register, source1 % source2);
                            }
                        },
                    }
                },
                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
            }
        },
        0b0001111 => {
            switch (other) {
                0b1000_0011_0011_00000_000_00000 => { // FENCE.TSO (RV32I)
                    assembler.error_with_source_bundle(source_bundle, "fence", .{}, "instruction not invokable", .{});
                },
                0b0000_0001_0000_00000_000_00000 => { // PAUSE (RV32I)
                    assembler.error_with_source_bundle(source_bundle, "pause", .{}, "instruction not invokable", .{});
                },
                else => {
                    switch (function3) {
                        0b000 => { // FENCE (RV32I)
                            assembler.error_with_source_bundle(source_bundle, "fence", .{}, "instruction not invokable", .{});
                        },
                        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                    }
                },
            }
        },
        0b1110011 => {
            switch (other) {
                0b000000000000_00000_000_00000 => { // ECALL (RV32I)
                    assembler.error_with_source_bundle(source_bundle, "environment call", .{}, "instruction not invokable", .{});
                },
                0b000000000001_00000_000_00000 => { // EBREAK (RV32I)
                    assembler.error_with_source_bundle(source_bundle, "environment break", .{}, "break", .{});
                },
                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
            }
        },
        0b0011011 => {
            switch (function3) {
                0b000 => { // ADDIW (RV64I)
                    const sized_immediate: i12 = @bitCast(assembler.cast(immediate, 12, source_bundle));
                    context.write_register(destination_register, @as(u32, @bitCast(@as(i32, @bitCast(@as(u32, @truncate(source)))) +% sized_immediate)));
                },
                else => {
                    switch (function7) {
                        0b0000000 => {
                            switch (function3) {
                                0b001 => { // SLLIW (RV64I)
                                    context.write_register(destination_register, @as(u32, @truncate(source)) << @as(u5, @truncate(immediate)));
                                },
                                0b101 => { // SRLIW (RV64I)
                                    context.write_register(destination_register, @as(u32, @truncate(source)) >> @as(u5, @truncate(immediate)));
                                },
                                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                            }
                        },
                        0b0100000 => {
                            switch (function3) {
                                0b101 => { // SRAIW (RV64I)
                                    context.write_register(
                                        destination_register,
                                        @as(u32, @bitCast(@as(i32, @truncate(@as(MaximumBitSizeSigned, @bitCast(source1)))) >> @as(u5, @truncate(immediate)))),
                                    );
                                },
                                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                            }
                        },
                        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                    }
                },
            }
        },
        0b0111011 => {
            switch (function7) {
                0b0000000 => {
                    switch (function3) {
                        0b000 => { // ADDW (RV64I)
                            context.write_register(destination_register, @as(u32, @truncate(source1)) +% @as(u32, @truncate(source2)));
                        },
                        0b001 => { // SLLW (RV64I)
                            context.write_register(destination_register, @as(u32, @truncate(source1)) << @as(u5, @truncate(source2)));
                        },
                        0b101 => { // SRLW (RV64I)
                            context.write_register(destination_register, @as(u32, @truncate(source1)) >> @as(u5, @truncate(source2)));
                        },
                        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                    }
                },
                0b0100000 => {
                    switch (function3) {
                        0b000 => { // SUBW (RV64I)
                            context.write_register(destination_register, @as(u32, @truncate(source1)) -% @as(u32, @truncate(source2)));
                        },
                        0b101 => { // SRAW (RV64I)
                            context.write_register(
                                destination_register,
                                @as(u32, @bitCast(@as(i32, @truncate(@as(MaximumBitSizeSigned, @bitCast(source1)))) >> @as(u5, @truncate(source2)))),
                            );
                        },
                        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                    }
                },
                0b0000001 => {
                    switch (function3) {
                        0b000 => { // MULW (RV64M)
                            context.write_register(
                                destination_register,
                                @bitCast(@as(MaximumBitSizeSigned, @as(i32, @bitCast(@as(u32, @truncate(source1)) *% @as(u32, @truncate(source2)))))),
                            );
                        },
                        0b100 => { // DIVW (RV64M)
                            if (source2 == 0) {
                                context.write_register(destination_register, @bitCast(@as(MaximumBitSizeSigned, -1)));
                            } else {
                                context.write_register(
                                    destination_register,
                                    @as(u32, @bitCast(@divTrunc(@as(i32, @bitCast(@as(u32, @truncate(source1)))), @as(i32, @bitCast(@as(u32, @truncate(source2))))))),
                                );
                            }
                        },
                        0b101 => { // DIVUW (RV64M)
                            if (source2 == 0) {
                                context.write_register(destination_register, std.math.maxInt(MaximumBitSize));
                            } else {
                                context.write_register(destination_register, @as(u32, @truncate(source1)) / @as(u32, @truncate(source2)));
                            }
                        },
                        0b110 => { // REMW (RV64M)
                            if (source2 == 0) {
                                context.write_register(destination_register, source1);
                            } else {
                                context.write_register(
                                    destination_register,
                                    @as(u32, @bitCast(@rem(@as(i32, @bitCast(@as(u32, @truncate(source1)))), @as(i32, @bitCast(@as(u32, @truncate(source2))))))),
                                );
                            }
                        },
                        0b111 => { // REMUW (RV64M)
                            if (source2 == 0) {
                                context.write_register(destination_register, source1);
                            } else {
                                context.write_register(destination_register, @as(u32, @truncate(source1)) % @as(u32, @truncate(source2)));
                            }
                        },
                        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
                    }
                },
                else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
            }
        },
        else => assembler.error_with_source_bundle(source_bundle, "instruction", .{}, "instruction not invokable", .{}),
    }
}

fn emit_instruction(
    assembler: *Assembler,
    @"type": Command.Operand.Instruction.Type,
    source_bundle: SourceBundle,
    operation_code: u7,
    function3: u3,
    function7: u7,
    destination_register: RegisterIndex,
    source_register: RegisterIndex,
    source_register1: RegisterIndex,
    source_register2: RegisterIndex,
    immediate: MaximumBitSize,
    other: u25,
) void {
    const encoded_instruction = EncodedInstruction{
        .operation_code = operation_code,
        .operand = operand: switch (@"type") {
            .r => {
                break :operand .{ .r_type = .{
                    .destination_register = destination_register,
                    .function3 = function3,
                    .source_register1 = source_register1,
                    .source_register2 = source_register2,
                    .function7 = function7,
                } };
            },
            .i => {
                const sized_immediate = assembler.cast(immediate, 12, source_bundle);
                break :operand .{ .i_type = .{
                    .destination_register = destination_register,
                    .function3 = function3,
                    .source_register = source_register,
                    .immediate_11_0 = sized_immediate,
                } };
            },
            .s => {
                const sized_immediate = assembler.cast(immediate, 12, source_bundle);
                const immediate_bits: packed struct(u12) {
                    immediate_4_0: u5,
                    immediate_11_5: u7,
                } = @bitCast(sized_immediate);
                break :operand .{ .s_type = .{
                    .immediate_4_0 = immediate_bits.immediate_4_0,
                    .function3 = function3,
                    .source_register1 = source_register1,
                    .source_register2 = source_register2,
                    .immediate_11_5 = immediate_bits.immediate_11_5,
                } };
            },
            .b => {
                const sized_immediate = assembler.cast(immediate, 12, source_bundle);
                const immediate_bits: packed struct(u12) {
                    immediate_11: u1,
                    immediate_4_1: u4,
                    immediate_10_5: u6,
                    immediate_12: u1,
                } = @bitCast(sized_immediate);
                break :operand .{ .b_type = .{
                    .immediate_11 = immediate_bits.immediate_11,
                    .immediate_4_1 = immediate_bits.immediate_4_1,
                    .function3 = function3,
                    .source_register1 = source_register1,
                    .source_register2 = source_register2,
                    .immediate_10_5 = immediate_bits.immediate_10_5,
                    .immediate_12 = immediate_bits.immediate_12,
                } };
            },
            .u => {
                const sized_immediate = assembler.cast(immediate, 20, source_bundle);
                break :operand .{ .u_type = .{
                    .destination_register = destination_register,
                    .immediate_31_12 = sized_immediate,
                } };
            },
            .j => {
                const sized_immediate = assembler.cast(immediate, 20, source_bundle);
                const immediate_bits: packed struct(u20) {
                    immediate_19_12: u8,
                    immediate_11: u1,
                    immediate_10_1: u10,
                    immediate_20: u1,
                } = @bitCast(sized_immediate);
                break :operand .{ .j_type = .{
                    .destination_register = destination_register,
                    .immediate_19_12 = immediate_bits.immediate_19_12,
                    .immediate_11 = immediate_bits.immediate_11,
                    .immediate_10_1 = immediate_bits.immediate_10_1,
                    .immediate_20 = immediate_bits.immediate_20,
                } };
            },
            .other => .{ .other = other },
        },
    };
    assembler.output.writer(assembler.allocator).writeInt(u32, @bitCast(encoded_instruction), .little) catch error_with_out_of_memory();
}

fn assemble_list_element_write(assembler: *Assembler, list_element_write: Command.Operand.ListElementWrite) void {
    const list = assembler.resolve(list_element_write.list, .list, list_element_write.list_source_bundle());
    const index = assembler.resolve(list_element_write.index, .integer, list_element_write.index_source_bundle());
    if (index >= list.len) {
        assembler.error_with_source_bundle(
            list_element_write.operation_source_bundle(),
            "index operation",
            .{},
            "index {d} is out of bounds of list with length {d}",
            .{ index, list.len },
        );
    }
    list[@intCast(index)] = list_element_write.element;
}

fn assemble_register_read(assembler: *Assembler, unary: Command.Operand.Unary) Value {
    if (assembler.invoke_context()) |context| {
        const register = assembler.resolve(unary.operand, .register, unary.source_bundle);
        return .{ .integer = context.read_register(register) };
    } else {
        assembler.error_with_source_bundle(unary.source_bundle, "register access", .{}, "outside invoke context", .{});
    }
}

fn assemble_register_write(assembler: *Assembler, register_write: Command.Operand.RegisterWrite) void {
    if (assembler.invoke_context()) |context| {
        const register = assembler.resolve(register_write.register, .register, register_write.register_source_bundle());
        const value = assembler.resolve(register_write.value, .integer, register_write.value_source_bundle());
        context.write_register(register, value);
    } else {
        assembler.error_with_source_bundle(register_write.operation_source_bundle(), "register access", .{}, "outside invoke context", .{});
    }
}

fn assemble_directive_inline(assembler: *Assembler, block_and_operand: Command.Operand.BlockAndOperand) void {
    const block = block_and_operand.block;
    // Type check already done in resolve_label_references.
    const block_value = assembler.resolve(block, null, undefined).block;
    var uses_block_operand = false;
    // Add one to skip the .block instruction itself.
    const block_start = block + 1;
    const block_end = block_start + block_value.length;
    var command_index: Command.Index = block_start;
    while (command_index < block_end) : (command_index += 1) {
        const tag = index_commands_tag(assembler.commands, command_index);
        const operand = index_commands_operand(assembler.commands, command_index);
        assembler.print_command("@inline", tag, operand, command_index, block_and_operand.operand);
        const value_index = command_index;
        const value = assembler.assemble_command(tag, operand, &command_index, block_and_operand.operand);
        assembler.values[value_index] = value;
        if (tag == .block_operand) uses_block_operand = true;
    }
    if (!uses_block_operand and block_and_operand.operand != Command.special.none) {
        assembler.error_with_source_bundle(block_and_operand.operand_source_bundle, "block operand", .{}, "block does not take operand", .{});
    }
}

fn assemble_directive_invoke(assembler: *Assembler, block_and_operand: Command.Operand.BlockAndOperand) void {
    const block = block_and_operand.block;
    // Type check already done in resolve_label_references.
    const block_value = assembler.resolve(block, null, undefined).block;
    assembler.invoke_contexts.append(assembler.allocator, .{}) catch error_with_out_of_memory();
    defer _ = assembler.invoke_contexts.pop();
    const context = assembler.invoke_context().?;
    var uses_block_operand = false;
    // Add one to skip the .block instruction itself.
    const block_start = block + 1;
    const block_end = block_start + block_value.length;
    var command_index: Command.Index = block_start;
    while (command_index < block_end) {
        {
            const tag = index_commands_tag(assembler.commands, command_index);
            const operand = index_commands_operand(assembler.commands, command_index);
            assembler.print_command("@invoke", tag, operand, command_index, block_and_operand.operand);
            const value_index = command_index;
            const value = assembler.assemble_command(tag, operand, &command_index, block_and_operand.operand);
            assembler.values[value_index] = value;
            if (tag == .block_operand) uses_block_operand = true;
        }
        if (context.target_relative_label) |relative_label| {
            // The check to make sure the referenced label exists was already done
            // which means we are guaranteed to find the target label in the block.
            command_index = 0;
            while (true) : (command_index += 1) {
                const tag = index_commands_tag(assembler.commands, command_index);
                const operand = index_commands_operand(assembler.commands, command_index);
                if (tag == .label_definition) {
                    if (compare_ignore_case(
                        true,
                        assembler.look_up_label_definition_name(operand.source_bundle),
                        assembler.look_up_relative_label_reference_name(relative_label),
                    )) {
                        break;
                    }
                }
            }
            context.target_relative_label = null;
        } else {
            command_index += 1;
        }
    }
    if (!uses_block_operand and block_and_operand.operand != Command.special.none) {
        assembler.error_with_source_bundle(block_and_operand.operand_source_bundle, "block operand", .{}, "block does not take operand", .{});
    }
}

fn assemble_directive_log(assembler: *Assembler, directive_log: Command.Operand.DirectiveLog) void {
    // Use standard output to allow this output to be redirected.
    const standard_output = std.io.getStdOut();
    var buffered_writer = std.io.bufferedWriter(standard_output.writer());
    const writer = buffered_writer.writer();

    const source = assembler.sources[directive_log.source_index];

    var row: SourceSize = 1;
    var column: SourceSize = 1;
    for (0..directive_log.source_range_start) |index| {
        switch (source.source[index]) {
            '\n' => {
                row += 1;
                column = 1;
            },
            else => column += 1,
        }
    }
    log_terminal_config.setColor(writer, .bright_white) catch return;
    writer.print("{s}:{d}:{d}: ", .{ source.file_path, row, column }) catch return;

    assembler.log_value(writer, directive_log.operand);
    writer.writeAll("\n") catch return;
    log_terminal_config.setColor(writer, .reset) catch return;
    buffered_writer.flush() catch return;
}

fn log_value(assembler: *Assembler, writer: anytype, command_index: Command.Index) void {
    // The type can be any.
    const value = assembler.resolve(command_index, null, undefined);
    switch (value) {
        .integer => |integer| {
            log_terminal_config.setColor(writer, .blue) catch return;
            writer.print("{d}", .{integer}) catch return;
            const integer_signed: MaximumBitSizeSigned = @bitCast(integer);
            if (integer_signed < 0) writer.print(" / {d}", .{integer_signed}) catch return;
            log_terminal_config.setColor(writer, .bright_white) catch return;
        },
        .list => |list| {
            writer.writeAll("[") catch return;
            var printable = list.len != 0;
            for (list, 0..) |list_value, index| {
                // The type can be any.
                const element = assembler.resolve(list_value, null, undefined);
                if (element == .integer) {
                    switch (element.integer) {
                        ' '...'~' => {},
                        else => printable = false,
                    }
                } else printable = false;
                assembler.log_value(writer, list_value);
                if (index != list.len - 1) {
                    writer.writeAll(", ") catch return;
                }
            }
            if (printable) {
                writer.writeAll(" / ") catch return;
                log_terminal_config.setColor(writer, .blue) catch return;
                for (list) |list_value| {
                    // Type and size check already done above.
                    writer.writeByte(@intCast(assembler.resolve(list_value, null, undefined).integer)) catch return;
                }
                log_terminal_config.setColor(writer, .bright_white) catch return;
            }
            writer.writeAll("]") catch return;
        },
        .register => |register| {
            log_terminal_config.setColor(writer, .blue) catch return;
            writer.print("x{d}", .{register}) catch return;
            log_terminal_config.setColor(writer, .bright_white) catch return;
        },
        .block => |block| {
            log_terminal_config.setColor(writer, .blue) catch return;
            if (block.length == 0) {
                writer.writeAll("{}") catch return;
            } else {
                writer.writeAll("{...}") catch return;
            }
            log_terminal_config.setColor(writer, .bright_white) catch return;
        },
        .unknown => {
            log_terminal_config.setColor(writer, .blue) catch return;
            writer.writeByte('?') catch return;
            log_terminal_config.setColor(writer, .bright_white) catch return;
        },
    }
}

const EncodedInstruction = packed struct(u32) {
    operation_code: u7,
    operand: packed union {
        r_type: packed struct(u25) {
            destination_register: RegisterIndex,
            function3: u3,
            source_register1: RegisterIndex,
            source_register2: RegisterIndex,
            function7: u7,
        },
        i_type: packed struct(u25) {
            destination_register: RegisterIndex,
            function3: u3,
            source_register: RegisterIndex,
            immediate_11_0: u12,
        },
        s_type: packed struct(u25) {
            immediate_4_0: u5,
            function3: u3,
            source_register1: RegisterIndex,
            source_register2: RegisterIndex,
            immediate_11_5: u7,
        },
        b_type: packed struct(u25) {
            immediate_11: u1,
            immediate_4_1: u4,
            function3: u3,
            source_register1: RegisterIndex,
            source_register2: RegisterIndex,
            immediate_10_5: u6,
            immediate_12: u1,
        },
        u_type: packed struct(u25) {
            destination_register: RegisterIndex,
            immediate_31_12: u20,
        },
        j_type: packed struct(u25) {
            destination_register: RegisterIndex,
            immediate_19_12: u8,
            immediate_11: u1,
            immediate_10_1: u10,
            immediate_20: u1,
        },
        other: u25,
    },
};
