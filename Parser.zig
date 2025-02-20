// Transforms tokens into a list of commands.

const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const Token = @import("main.zig").Token;
const Command = @import("main.zig").Command;
const Source = @import("main.zig").Source;
const SourceRange = @import("main.zig").SourceRange;
const SourceIndex = @import("main.zig").SourceIndex;
const SourceSize = @import("main.zig").SourceSize;
const SourceBundle = @import("main.zig").SourceBundle;
const MaximumBitSize = @import("main.zig").MaximumBitSize;
const error_with_out_of_memory = @import("main.zig").error_with_out_of_memory;
const compare_ignore_case = @import("main.zig").compare_ignore_case;
const cast_or_null = @import("main.zig").cast_or_null;
const read_source_file = @import("main.zig").read_source_file;
const index_commands_tag = @import("main.zig").index_commands_tag;
const index_commands_operand = @import("main.zig").index_commands_operand;

const Parser = @This();

tokenizer: Tokenizer,
// This is used for look-ahead and going back a token.
returned_token: ?Token = null,
variables: std.StringArrayHashMapUnmanaged(Variable) = .{},
parent_variables: std.ArrayListUnmanaged(std.StringArrayHashMapUnmanaged(Variable)) = .{},
// The source range of the most recently parsed operation (parse_operation) or value (parse_value).
last_value_source_range: SourceRange = undefined,
global_state: *GlobalState,
// This is the index of the source in global_state.sources being parsed.
source_index: SourceIndex,
commands: std.MultiArrayList(Command) = .{},
instruction_definitions: std.StringArrayHashMapUnmanaged(InstructionDefinition) = .{},
pseudoinstruction_definitions: std.StringArrayHashMapUnmanaged(PseudoinstructionDefinition) = .{},
allocator: std.mem.Allocator,

// This is state that is preserved across all `@import`s (i.e. all `Parser`s).
pub const GlobalState = struct {
    // All sources whose parsing is either in progress or finished.
    sources: std.ArrayListUnmanaged(Source) = .{},
    constants: std.StringArrayHashMapUnmanaged(Command.Index) = .{},
    bits: ?enum { @"32", @"64" } = null,
};

const Variable = struct {
    value: Command.Index,
    source_range: SourceRange,
    used: bool,
};

const InstructionDefinition = struct {
    type: Command.Operand.Instruction.Type,
    bits: Command.Index,
    source_range: SourceRange,
    imported: bool,
};

const PseudoinstructionDefinition = struct {
    block: Command.Index,
    block_source_bundle: SourceBundle,
    source_range: SourceRange,
    imported: bool,
};

fn root_scope(parser: *Parser) bool {
    return parser.parent_variables.items.len == 0;
}

fn variable_exists(parser: *Parser, key: []const u8) bool {
    if (parser.variables.contains(key)) return true;
    for (parser.parent_variables.items) |variables| {
        if (variables.contains(key)) return true;
    }
    return false;
}

fn read_variable(parser: *Parser, key: []const u8, token: Token) Command.Index {
    const variable = parser.variables.getPtr(key) orelse variable: {
        for (parser.parent_variables.items) |variables| {
            break :variable variables.getPtr(key) orelse continue;
        }
        parser.error_with_token(token, "unknown variable", .{});
    };
    variable.used = true;
    return variable.value;
}

fn write_variable(parser: *Parser, key: []const u8, source_range: SourceRange, value: Command.Index) void {
    const variable = parser.variables.getPtr(key) orelse variable: {
        for (parser.parent_variables.items) |variables| {
            break :variable variables.getPtr(key) orelse continue;
        }
        if (parser.instruction_definitions.contains(key)) parser.error_with_source_range(source_range, "identifier", .{}, "instruction with this name already exists", .{});
        if (parser.pseudoinstruction_definitions.contains(key)) parser.error_with_source_range(source_range, "identifier", .{}, "pseudoinstruction with this name already exists", .{});
        parser.variables.put(parser.allocator, key, .{ .value = value, .source_range = source_range, .used = false }) catch error_with_out_of_memory();
        return;
    };
    variable.value = value;
}

fn source_slice(parser: *const Parser, source_range: SourceRange) []const u8 {
    return parser.tokenizer.source[source_range.start..source_range.end];
}

fn next_token(parser: *Parser) Token {
    if (parser.returned_token) |token| {
        parser.returned_token = null;
        return token;
    }
    while (true) {
        const token = parser.tokenizer.tokenize();
        switch (token.tag) {
            .comment, .newline => {},
            else => return token,
        }
    }
}

fn next_token_expect(parser: *Parser, expected_token_tag: Token.Tag) Token {
    const token = parser.next_token();
    if (token.tag != expected_token_tag) parser.error_with_token(token, "expected {s}", .{@tagName(expected_token_tag)});
    return token;
}

fn return_token(parser: *Parser, token: Token) void {
    parser.returned_token = token;
}

fn append_command(parser: *Parser, tag: Command.Tag, operand: Command.Operand) Command.Index {
    const command: Command.Index = @intCast(parser.commands.len);
    parser.commands.append(parser.allocator, .{ .tag = tag, .operand = operand }) catch error_with_out_of_memory();
    return command;
}

fn append_command_assume_capacity(parser: *Parser, tag: Command.Tag, operand: Command.Operand) Command.Index {
    const command: Command.Index = @intCast(parser.commands.len);
    parser.commands.appendAssumeCapacity(.{ .tag = tag, .operand = operand });
    return command;
}

fn report_unused_variables(parser: *Parser, variables: std.StringArrayHashMapUnmanaged(Variable)) void {
    for (variables.values()) |variable| {
        if (!variable.used) {
            parser.error_with_source_range(variable.source_range, "variable", .{}, "unused variable", .{});
        }
    }
}

fn error_with_source_range(
    parser: *Parser,
    source_range: SourceRange,
    comptime item_format: []const u8,
    item_arguments: anytype,
    comptime message_format: []const u8,
    message_arguments: anytype,
) noreturn {
    @branchHint(.cold);
    @import("main.zig").error_with_source_range(
        parser.tokenizer.source,
        parser.tokenizer.source_file_path,
        source_range,
        item_format,
        item_arguments,
        message_format,
        message_arguments,
    );
}

fn error_with_token(parser: *const Parser, token: Token, comptime message_format: []const u8, message_arguments: anytype) noreturn {
    @branchHint(.cold);
    @import("main.zig").error_with_source_range(
        parser.tokenizer.source,
        parser.tokenizer.source_file_path,
        token.source_range,
        "{s}",
        .{token.tag.name()},
        message_format,
        message_arguments,
    );
}

fn lower_integer(parser: *Parser, integer: Command.Operand.Integer) Command.Index {
    return switch (integer) {
        0x00...0xff => Command.special.bytes_start + @as(u8, @intCast(integer)),
        else => parser.append_command(.integer, .{ .integer = integer }),
    };
}

fn lower_integer_assume_capacity(parser: *Parser, integer: Command.Operand.Integer) Command.Index {
    return switch (integer) {
        0x00...0xff => Command.special.bytes_start + @as(u8, @intCast(integer)),
        else => parser.append_command_assume_capacity(.integer, .{ .integer = integer }),
    };
}

pub fn parse(parser: *Parser) void {
    while (true) {
        const look_ahead = parser.next_token();
        if (look_ahead.tag == .end) {
            break;
        }
        parser.return_token(look_ahead);
        parser.parse_statement();
    }
    parser.report_unused_variables(parser.variables);
}

fn parse_statement(parser: *Parser) void {
    const token = parser.next_token();
    const token_source = parser.source_slice(token.source_range);
    switch (token.tag) {
        .identifier => {
            const look_ahead = parser.next_token();
            switch (look_ahead.tag) {
                .@"assignment operator" => {
                    const value = parser.parse_operation();
                    const key = std.ascii.allocLowerString(parser.allocator, token_source) catch error_with_out_of_memory();
                    parser.write_variable(key, token.source_range, value);
                },
                .@"index operator" => {
                    const key = std.ascii.allocLowerString(parser.allocator, token_source) catch error_with_out_of_memory();
                    const list = parser.read_variable(key, token);
                    const index = parser.parse_operation();
                    const index_source_range = parser.last_value_source_range;
                    _ = parser.next_token_expect(.@"assignment operator");
                    const element = parser.parse_operation();
                    _ = parser.append_command(
                        .list_element_write,
                        .{ .list_element_write = .{
                            .list = list,
                            .list_source_range = token.source_range,
                            .index = index,
                            .index_source_range = index_source_range,
                            .element = element,
                            .source_index = parser.source_index,
                        } },
                    );
                },
                else => {
                    parser.return_token(look_ahead);
                    parser.parse_instruction_or_pseudoinstruction(token, token_source);
                },
            }
        },
        .constant => {
            _ = parser.next_token_expect(.@"assignment operator");
            const value = parser.parse_operation();
            if (!parser.root_scope()) parser.error_with_token(token, "cannot define constant in non-root scope", .{});
            const source = token_source["$".len..];
            if (compare_ignore_case(true, "bits", source)) {
                parser.error_with_token(token, "cannot define $bits without @bits", .{});
            }
            const key = std.ascii.allocLowerString(parser.allocator, source) catch error_with_out_of_memory();
            const result = parser.global_state.constants.getOrPut(parser.allocator, key) catch error_with_out_of_memory();
            if (result.found_existing) {
                parser.error_with_token(token, "constant already exists", .{});
            } else {
                result.value_ptr.* = value;
            }
        },
        .@"block operand" => {
            parser.commands.ensureUnusedCapacity(parser.allocator, 2) catch error_with_out_of_memory();
            _ = parser.next_token_expect(.@"index operator");
            const list = parser.append_command_assume_capacity(.block_operand, .{ .source_bundle = .{ .range = token.source_range, .index = parser.source_index } });
            const index = parser.parse_operation();
            const index_source_range = parser.last_value_source_range;
            _ = parser.next_token_expect(.@"assignment operator");
            const element = parser.parse_operation();
            _ = parser.append_command_assume_capacity(
                .list_element_write,
                .{ .list_element_write = .{
                    .list = list,
                    .list_source_range = token.source_range,
                    .index = index,
                    .index_source_range = index_source_range,
                    .element = element,
                    .source_index = parser.source_index,
                } },
            );
        },
        .directive => {
            const name = token_source["@".len..];
            if (compare_ignore_case(true, "bits", name)) {
                parser.parse_directive_bits();
            } else if (compare_ignore_case(true, "import", name)) {
                parser.parse_directive_import(token);
            } else if (compare_ignore_case(true, "origin", name)) {
                parser.parse_directive_origin();
            } else if (compare_ignore_case(true, "instruction", name)) {
                parser.parse_directive_instruction(token);
            } else if (compare_ignore_case(true, "pseudoinstruction", name)) {
                parser.parse_directive_pseudoinstruction(token);
            } else if (compare_ignore_case(true, "inline", name)) {
                parser.parse_directive_inline();
            } else if (compare_ignore_case(true, "invoke", name)) {
                parser.parse_directive_invoke();
            } else if (compare_ignore_case(true, "log", name)) {
                parser.parse_directive_log(token);
            } else if (compare_ignore_case(true, "bytes", name)) {
                parser.parse_directive_bytes();
            } else if (compare_ignore_case(true, "byte", name)) {
                parser.parse_directive_byte();
            } else if (compare_ignore_case(true, "half", name)) {
                parser.parse_directive_half();
            } else if (compare_ignore_case(true, "word", name)) {
                parser.parse_directive_word();
            } else if (compare_ignore_case(true, "double", name)) {
                parser.parse_directive_double();
            } else {
                parser.error_with_token(token, "unknown directive", .{});
            }
        },
        .@"label definition" => {
            _ = parser.append_command(
                .label_definition,
                .{ .source_bundle = .{ .range = token.source_range, .index = parser.source_index } },
            );
        },
        .@"register access start" => {
            const register = parser.parse_operation();
            const register_source_range = parser.last_value_source_range;
            const register_access_end_token = parser.next_token_expect(.@"register access end");
            _ = parser.next_token_expect(.@"assignment operator");
            const value = parser.parse_operation();
            const value_source_range = parser.last_value_source_range;
            _ = parser.append_command(.register_write, .{ .register_write = .{
                .register = register,
                .register_source_range = register_source_range,
                .value = value,
                .value_source_range = value_source_range,
                .operation_source_range = .{
                    .start = token.source_range.start,
                    .end = register_access_end_token.source_range.end,
                },
                .source_index = parser.source_index,
            } });
        },
        else => parser.error_with_token(token, "expected instruction, assignment, directive, or label", .{}),
    }
}

fn parse_instruction_or_pseudoinstruction(parser: *Parser, directive_token: Token, mnemonic: []const u8) void {
    var operands = std.ArrayListUnmanaged(Command.Index){};
    var first_operand_source_range_start: SourceSize = undefined;
    var first_value = true;
    while (true) {
        const operand = if (first_value) operand: {
            const operand = parser.parse_operation_or_none();
            if (operand == Command.special.none) break;
            first_operand_source_range_start = parser.last_value_source_range.start;
            break :operand operand;
        } else operand: {
            break :operand parser.parse_operation();
        };
        first_value = false;
        operands.append(parser.allocator, operand) catch error_with_out_of_memory();
        const look_ahead = parser.next_token();
        if (look_ahead.tag != .@"value separator") {
            parser.return_token(look_ahead);
            break;
        }
    }
    parser.commands.ensureUnusedCapacity(parser.allocator, 2) catch error_with_out_of_memory();
    const operands_length = operands.items.len;
    const operands_list = parser.append_command_assume_capacity(
        .list,
        .{ .list = operands.items },
    );
    const commands = parser.commands.slice();
    var relative_label_reference = SourceBundle.none;
    for (operands.items) |index| {
        const tag = index_commands_tag(commands, index);
        const operand = index_commands_operand(commands, index);
        if (tag == .relative_label_reference) {
            relative_label_reference = operand.label_reference.source_bundle;
        }
    }
    const key = std.ascii.allocLowerString(parser.allocator, mnemonic) catch error_with_out_of_memory();
    const source_range = SourceRange{ .start = directive_token.source_range.start, .end = parser.last_value_source_range.end };
    const operand_source_range = SourceRange{ .start = first_operand_source_range_start, .end = parser.last_value_source_range.end };
    if (parser.instruction_definitions.get(key)) |instruction_definition| {
        _ = parser.append_command_assume_capacity(
            .instruction,
            .{ .instruction = .{
                .type = instruction_definition.type,
                .bits = instruction_definition.bits,
                .operands = operands_list,
                .source_bundle = .{ .range = source_range, .index = parser.source_index },
                .relative_label_reference = relative_label_reference,
            } },
        );
        return;
    }
    if (parser.pseudoinstruction_definitions.get(key)) |pseudoinstruction_definition| {
        _ = parser.append_command_assume_capacity(
            .directive_inline,
            .{ .block_and_operand = .{
                .block = pseudoinstruction_definition.block,
                .block_source_bundle = pseudoinstruction_definition.block_source_bundle,
                .operand = if (operands_length == 0) Command.special.none else operands_list,
                .operand_source_bundle = .{ .range = operand_source_range, .index = parser.source_index },
            } },
        );
        return;
    }
    parser.error_with_source_range(source_range, "instruction or pseudoinstruction", .{}, "unknown instruction or pseudoinstruction", .{});
}

fn parse_directive_bits(parser: *Parser) void {
    const operand_command_index = parser.parse_operation();
    const commands = parser.commands.slice();
    const operand_tag = index_commands_tag(commands, operand_command_index);
    const operand_operand = index_commands_operand(commands, operand_command_index);
    if (operand_tag != .integer) {
        parser.error_with_source_range(parser.last_value_source_range, "non-integer literal", .{}, "expected integer literal", .{});
    }
    parser.global_state.bits = switch (operand_operand.integer) {
        32 => .@"32",
        64 => .@"64",
        else => parser.error_with_source_range(parser.last_value_source_range, "integer literal", .{}, "expected 32 or 64", .{}),
    };
}

fn parse_directive_import(parser: *Parser, directive_token: Token) void {
    const value_command_index = parser.parse_operation();
    const commands = parser.commands.slice();
    const value_tag = index_commands_tag(commands, value_command_index);
    const value_operand = index_commands_operand(commands, value_command_index);
    if (value_tag != .list) {
        parser.error_with_source_range(parser.last_value_source_range, "non-list literal", .{}, "expected list literal", .{});
    }
    const bytes = parser.allocator.alloc(u8, value_operand.list.len) catch error_with_out_of_memory();
    for (bytes, value_operand.list) |*byte, list_value| {
        const list_value_tag = index_commands_tag(commands, list_value);
        const list_value_operand = index_commands_operand(commands, list_value);
        if (list_value_tag != .integer) {
            parser.error_with_source_range(parser.last_value_source_range, "non-byte list literal", .{}, "expected byte list literal", .{});
        }
        const uncasted_integer = list_value_operand.integer;
        byte.* = cast_or_null(uncasted_integer, 8) orelse {
            parser.error_with_source_range(parser.last_value_source_range, "non-byte list literal", .{}, "expected byte list literal", .{});
        };
    }
    const source_file_path = if (std.fs.path.extension(bytes).len == 0) source_file_path: {
        const prefix = "standard/";
        const suffix = ".asm";
        const source_file_path = parser.allocator.alloc(u8, prefix.len + bytes.len + suffix.len) catch error_with_out_of_memory();
        @memcpy(source_file_path[0..prefix.len], prefix);
        for (source_file_path[prefix.len..][0..bytes.len], bytes) |*a, b| {
            a.* = std.ascii.toLower(b);
        }
        @memcpy(source_file_path[prefix.len + bytes.len ..][0..suffix.len], suffix);
        break :source_file_path source_file_path;
    } else source_file_path: {
        break :source_file_path bytes;
    };
    const directive_source_range = SourceRange{ .start = directive_token.source_range.start, .end = parser.last_value_source_range.end };
    const file = std.fs.cwd().openFile(source_file_path, .{ .mode = .read_only }) catch {
        parser.error_with_source_range(directive_source_range, "import", .{}, "could not open source file", .{});
    };
    defer file.close();
    const source = read_source_file(parser.allocator, file) catch |@"error"| {
        switch (@"error") {
            error.read_failed => parser.error_with_source_range(directive_source_range, "import", .{}, "could not read source file", .{}),
            error.too_big => parser.error_with_source_range(directive_source_range, "import", .{}, "total amount of bytes of all source files is bigger than {d} bytes", .{
                // Subtract one because the check is a greater than or equal check.
                std.math.maxInt(SourceSize),
            }),
        }
    };
    const import_tokenizer = Tokenizer{
        .source = source,
        .source_file_path = source_file_path,
    };
    parser.global_state.sources.append(parser.allocator, .{ .source = source, .file_path = source_file_path }) catch error_with_out_of_memory();
    var import_parser = Parser{
        .tokenizer = import_tokenizer,
        .source_index = @intCast(parser.global_state.sources.items.len - 1),
        .global_state = parser.global_state,
        .allocator = parser.allocator,
    };
    import_parser.parse();
    const command_offset: Command.Index = @intCast(parser.commands.len);
    const import_commands = import_parser.commands.slice();
    // Move over the imported commands.
    parser.commands.ensureUnusedCapacity(parser.allocator, import_commands.len) catch error_with_out_of_memory();
    var index: Command.Index = 0;
    while (index < import_commands.len) : (index += 1) {
        const tag = index_commands_tag(import_commands, index);
        var operand = index_commands_operand(import_commands, index);
        // Shift all indices contained in the operand, if any, because the command position changes.
        switch (tag) {
            .integer,
            .register,
            .block,
            .label_definition,
            .relative_label_reference,
            .absolute_label_reference,
            .here,
            .block_operand,
            .unknown,
            => {
                // These do not have operands with indices in them.
            },
            .instruction => {
                operand.instruction.bits = Command.shift(operand.instruction.bits, command_offset);
                operand.instruction.operands = Command.shift(operand.instruction.operands, command_offset);
            },
            .directive_log => {
                operand.directive_log.operand = Command.shift(operand.directive_log.operand, command_offset);
            },
            .list => {
                for (operand.list) |*list_index| {
                    list_index.* = Command.shift(list_index.*, command_offset);
                }
            },
            .register_read,
            .directive_bytes,
            .directive_byte,
            .directive_half,
            .directive_word,
            .directive_double,
            .directive_origin,
            .bitwise_not,
            .negation,
            .list_length,
            => {
                operand.unary.operand = Command.shift(operand.unary.operand, command_offset);
            },
            .directive_inline,
            .directive_invoke,
            => {
                operand.block_and_operand.block = Command.shift(operand.block_and_operand.block, command_offset);
                operand.block_and_operand.operand = Command.shift(operand.block_and_operand.operand, command_offset);
            },
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
            => {
                operand.binary.left = Command.shift(operand.binary.left, command_offset);
                operand.binary.right = Command.shift(operand.binary.right, command_offset);
            },
            .list_element_write => {
                operand.list_element_write.list = Command.shift(operand.list_element_write.list, command_offset);
                operand.list_element_write.index = Command.shift(operand.list_element_write.index, command_offset);
                operand.list_element_write.element = Command.shift(operand.list_element_write.element, command_offset);
            },
            .register_write => {
                operand.register_write.register = Command.shift(operand.register_write.register, command_offset);
                operand.register_write.value = Command.shift(operand.register_write.value, command_offset);
            },
        }
        _ = parser.append_command_assume_capacity(tag, operand);
    }
    // Shift the imported constants' command indices because the commands' positions changed.
    for (parser.global_state.constants.values()) |*constant| {
        constant.* = Command.shift(constant.*, command_offset);
    }
    // Shift the imported instruction definitions' command indices because the commands' positions changed.
    var instruction_definitions = import_parser.instruction_definitions.iterator();
    while (instruction_definitions.next()) |instruction_definition| {
        const key = instruction_definition.key_ptr.*;
        const value = instruction_definition.value_ptr.*;
        // This makes sure the pseudoinstruction will be imported only into the current source file.
        if (value.imported) break;
        if (parser.variable_exists(key)) {
            parser.error_with_source_range(value.source_range, "instruction", .{}, "variable with this name already exists", .{});
        }
        // To allow a source file containing instructions to be imported multiple times, allow clobbering already existing instructions, if it's not a pseudoinstruction.
        if (parser.pseudoinstruction_definitions.contains(key)) {
            parser.error_with_source_range(value.source_range, "instruction", .{}, "pseudoinstruction with this name already exists", .{});
        }
        parser.instruction_definitions.put(parser.allocator, key, .{
            .type = value.type,
            .bits = Command.shift(value.bits, command_offset),
            .source_range = value.source_range,
            .imported = true,
        }) catch error_with_out_of_memory();
    }
    // Shift the imported pseudoinstruction definitions' command indices because the commands' positions changed.
    var pseudoinstruction_definitions = import_parser.pseudoinstruction_definitions.iterator();
    while (pseudoinstruction_definitions.next()) |pseudoinstruction_definition| {
        const key = pseudoinstruction_definition.key_ptr.*;
        const value = pseudoinstruction_definition.value_ptr.*;
        // This makes sure the pseudoinstruction will be imported only into the current source file.
        if (value.imported) break;
        if (parser.variable_exists(key)) {
            parser.error_with_source_range(value.source_range, "pseudoinstruction", .{}, "variable with this name already exists", .{});
        }
        // To allow a source file containing pseudoinstructions to be imported multiple times, allow clobbering already existing pseudoinstructions, if it's not an instruction.
        if (parser.instruction_definitions.contains(key)) {
            parser.error_with_source_range(value.source_range, "pseudoinstruction", .{}, "instruction with this name already exists", .{});
        }
        parser.pseudoinstruction_definitions.put(parser.allocator, key, .{
            .block = Command.shift(value.block, command_offset),
            .block_source_bundle = value.block_source_bundle,
            .source_range = value.source_range,
            .imported = true,
        }) catch error_with_out_of_memory();
    }
    // No command is appended for the import.
    // The list of bytes of the source file path remain.
}

fn parse_directive_origin(parser: *Parser) void {
    const operand = parser.parse_operation();
    _ = parser.append_command(.directive_origin, .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = parser.last_value_source_range, .index = parser.source_index } } });
}

fn parse_directive_instruction(parser: *Parser, directive_token: Token) void {
    const mnemonic_token = parser.next_token_expect(.identifier);
    const mnemonic = parser.source_slice(mnemonic_token.source_range);
    const type_token = parser.next_token_expect(.identifier);
    const type_source = parser.source_slice(type_token.source_range);
    if (type_source.len != 1) parser.error_with_token(type_token, "unknown type", .{});
    const type_character = std.ascii.toLower(type_source[0]);
    const @"type": Command.Operand.Instruction.Type = switch (type_character) {
        'r' => .r,
        'i' => .i,
        's' => .s,
        'b' => .b,
        'u' => .u,
        'j' => .j,
        'x' => .other,
        else => parser.error_with_token(type_token, "unknown type", .{}),
    };
    const bits = parser.parse_operation();
    const source_range = SourceRange{ .start = directive_token.source_range.start, .end = parser.last_value_source_range.end };
    if (!parser.root_scope()) parser.error_with_source_range(source_range, "instruction", .{}, "cannot define instruction in non-root scope", .{});
    const key = std.ascii.allocLowerString(parser.allocator, mnemonic) catch error_with_out_of_memory();
    if (parser.variable_exists(key)) parser.error_with_source_range(source_range, "instruction", .{}, "variable with this name already exists", .{});
    if (parser.pseudoinstruction_definitions.contains(key)) parser.error_with_source_range(source_range, "instruction", .{}, "pseudoinstruction with this name already exists", .{});
    const result = parser.instruction_definitions.getOrPut(parser.allocator, key) catch error_with_out_of_memory();
    if (result.found_existing and !result.value_ptr.imported) {
        parser.error_with_source_range(
            source_range,
            "instruction definition",
            .{},
            "instruction already exists",
            .{},
        );
    } else {
        result.value_ptr.* = .{
            .type = @"type",
            .bits = bits,
            .source_range = source_range,
            .imported = false,
        };
    }
}

fn parse_directive_pseudoinstruction(parser: *Parser, directive_token: Token) void {
    const mnemonic_token = parser.next_token_expect(.identifier);
    const mnemonic = parser.source_slice(mnemonic_token.source_range);
    const block = parser.parse_operation();
    const source_range = SourceRange{ .start = directive_token.source_range.start, .end = parser.last_value_source_range.end };
    if (!parser.root_scope()) parser.error_with_source_range(source_range, "pseudoinstruction", .{}, "cannot define pseudoinstruction in non-root scope", .{});
    const key = std.ascii.allocLowerString(parser.allocator, mnemonic) catch error_with_out_of_memory();
    if (parser.variable_exists(key)) parser.error_with_source_range(source_range, "pseudoinstruction", .{}, "variable with this name already exists", .{});
    if (parser.instruction_definitions.contains(key)) parser.error_with_source_range(source_range, "pseudoinstruction", .{}, "instruction with this name already exists", .{});
    const result = parser.pseudoinstruction_definitions.getOrPut(parser.allocator, key) catch error_with_out_of_memory();
    if (result.found_existing and !result.value_ptr.imported) {
        parser.error_with_source_range(
            source_range,
            "pseudoinstruction definition",
            .{},
            "pseudoinstruction already exists",
            .{},
        );
    } else {
        result.value_ptr.* = .{
            .block = block,
            .block_source_bundle = .{ .range = parser.last_value_source_range, .index = parser.source_index },
            .source_range = source_range,
            .imported = false,
        };
    }
}

fn parse_directive_inline(parser: *Parser) void {
    const block = parser.parse_operation();
    const block_source_range = parser.last_value_source_range;
    const operand = parser.parse_operation_or_none();
    const operand_source_range = parser.last_value_source_range;
    _ = parser.append_command(
        .directive_inline,
        .{ .block_and_operand = .{
            .block = block,
            .block_source_bundle = .{ .range = block_source_range, .index = parser.source_index },
            .operand = operand,
            .operand_source_bundle = .{ .range = operand_source_range, .index = parser.source_index },
        } },
    );
}

fn parse_directive_invoke(parser: *Parser) void {
    const block = parser.parse_operation();
    const block_source_range = parser.last_value_source_range;
    const operand = parser.parse_operation_or_none();
    const operand_source_range = parser.last_value_source_range;
    _ = parser.append_command(
        .directive_invoke,
        .{ .block_and_operand = .{
            .block = block,
            .block_source_bundle = .{ .range = block_source_range, .index = parser.source_index },
            .operand = operand,
            .operand_source_bundle = .{ .range = operand_source_range, .index = parser.source_index },
        } },
    );
}

fn parse_directive_log(parser: *Parser, directive_token: Token) void {
    const operand = parser.parse_operation();
    _ = parser.append_command(
        .directive_log,
        .{ .directive_log = .{
            .operand = operand,
            .source_range_start = directive_token.source_range.start,
            .source_index = parser.source_index,
        } },
    );
}

fn parse_directive_bytes(parser: *Parser) void {
    const operand = parser.parse_operation();
    _ = parser.append_command(.directive_bytes, .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = parser.last_value_source_range, .index = parser.source_index } } });
}

fn parse_directive_byte(parser: *Parser) void {
    const operand = parser.parse_operation();
    _ = parser.append_command(.directive_byte, .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = parser.last_value_source_range, .index = parser.source_index } } });
}

fn parse_directive_half(parser: *Parser) void {
    const operand = parser.parse_operation();
    _ = parser.append_command(.directive_half, .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = parser.last_value_source_range, .index = parser.source_index } } });
}

fn parse_directive_word(parser: *Parser) void {
    const operand = parser.parse_operation();
    _ = parser.append_command(.directive_word, .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = parser.last_value_source_range, .index = parser.source_index } } });
}

fn parse_directive_double(parser: *Parser) void {
    const operand = parser.parse_operation();
    _ = parser.append_command(.directive_double, .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = parser.last_value_source_range, .index = parser.source_index } } });
}

fn parse_operation_or_none(parser: *Parser) Command.Index {
    const look_ahead = parser.next_token();
    if (look_ahead.tag == .@"statement end") {
        parser.last_value_source_range = look_ahead.source_range;
        return Command.special.none;
    }
    const first_token = look_ahead;
    parser.return_token(look_ahead);
    const left = parser.parse_value();
    return parser.parse_operation_complete(left, first_token);
}

fn parse_operation(parser: *Parser) Command.Index {
    const look_ahead = parser.next_token();
    const first_token = look_ahead;
    parser.return_token(look_ahead);
    const left = parser.parse_value();
    return parser.parse_operation_complete(left, first_token);
}

fn parse_operation_complete(parser: *Parser, left: Command.Index, first_token: Token) Command.Index {
    const left_source_range = parser.last_value_source_range;
    var source_range: SourceRange = parser.last_value_source_range;
    defer parser.last_value_source_range = source_range;
    const look_ahead = parser.next_token();
    const command_tag: Command.Tag = switch (look_ahead.tag) {
        .@"addition operator" => .addition,
        .@"minus sign" => .subtraction,
        .@"multiplication operator" => .multiplication,
        .@"division operator" => .division,
        .@"modulo operator" => .modulo,
        .@"bitwise AND operator" => .bitwise_and,
        .@"bitwise OR operator" => .bitwise_or,
        .@"bitwise XOR operator" => .bitwise_xor,
        .@"bitwise left shift operator" => .bitwise_left_shift,
        .@"bitwise right shift operator" => .bitwise_right_shift,
        .@"index operator" => .index,
        .@"concatenation operator" => .concatenation,
        .@"duplication operator" => .duplication,
        else => {
            if (first_token.tag == .@"operation start") {
                parser.error_with_token(first_token, "redundant", .{});
            } else if (look_ahead.tag == .@"operation end") {
                parser.error_with_token(look_ahead, "redundant", .{});
            }
            parser.return_token(look_ahead);
            return left;
        },
    };
    const right = parser.parse_value();
    const right_source_range = parser.last_value_source_range;
    source_range.end = parser.last_value_source_range.end;
    return parser.append_command(
        command_tag,
        .{ .binary = .{
            .left = left,
            .left_source_range = left_source_range,
            .right = right,
            .right_source_range = right_source_range,
            .source_index = parser.source_index,
        } },
    );
}

fn parse_value(parser: *Parser) Command.Index {
    const token = parser.next_token();
    var source_range: SourceRange = .{ .start = token.source_range.start, .end = token.source_range.end };
    const token_source = parser.source_slice(token.source_range);
    const value = value: switch (token.tag) {
        .identifier => {
            const key = std.ascii.allocLowerString(parser.allocator, token_source) catch error_with_out_of_memory();
            break :value parser.read_variable(key, token);
        },
        .constant => {
            const source = token_source["$".len..];
            if (compare_ignore_case(true, "bits", source)) {
                break :value if (parser.global_state.bits) |bits| switch (bits) {
                    .@"32" => parser.lower_integer(32),
                    .@"64" => parser.lower_integer(64),
                } else {
                    parser.error_with_token(token, "unknown bit size", .{});
                };
            }
            const key = std.ascii.allocLowerString(parser.allocator, source) catch error_with_out_of_memory();
            break :value parser.global_state.constants.get(key) orelse parser.error_with_token(token, "unknown constant", .{});
        },
        .here => {
            // This command will be fixed up to an .integer when assembling.
            break :value parser.append_command(.here, undefined);
        },
        .@"block operand" => {
            break :value parser.append_command(.block_operand, .{ .source_bundle = .{ .range = token.source_range, .index = parser.source_index } });
        },
        .@"relative label reference" => {
            const name = token_source[":".len..];
            if (name.len == 0) {
                parser.error_with_token(token, "no label name", .{});
            }
            // This command will be fixed up to an .integer when assembling.
            break :value parser.append_command(
                .relative_label_reference,
                .{ .label_reference = .{
                    .source_bundle = .{ .range = token.source_range, .index = parser.source_index },
                    .address = undefined,
                } },
            );
        },
        .@"absolute label reference" => {
            const name = token_source["::".len..];
            if (name.len == 0) {
                parser.error_with_token(token, "no label name", .{});
            }
            // This command will be fixed up to an .integer when assembling.
            break :value parser.append_command(
                .absolute_label_reference,
                .{ .label_reference = .{
                    .source_bundle = .{ .range = token.source_range, .index = parser.source_index },
                    .address = undefined,
                } },
            );
        },
        .@"operation start" => {
            const value = parser.parse_operation();
            source_range = parser.last_value_source_range;
            _ = parser.next_token_expect(.@"operation end");
            break :value value;
        },
        .@"minus sign" => {
            const operand = parser.parse_value();
            source_range.end = parser.last_value_source_range.end;
            break :value parser.append_command(.negation, .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = source_range, .index = parser.source_index } } });
        },
        .@"bitwise NOT operator" => {
            const operand = parser.parse_value();
            source_range.end = parser.last_value_source_range.end;
            break :value parser.append_command(.bitwise_not, .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = source_range, .index = parser.source_index } } });
        },
        .@"list start" => {
            const look_ahead = parser.next_token();
            if (look_ahead.tag == .@"list end") {
                source_range.end = look_ahead.source_range.end;
                break :value Command.special.empty_list;
            }
            parser.return_token(look_ahead);
            var values = std.ArrayListUnmanaged(Command.Index){};
            while (true) {
                const value = parser.parse_operation();
                values.append(parser.allocator, value) catch error_with_out_of_memory();
                const list_token = parser.next_token();
                switch (list_token.tag) {
                    .@"list end" => {
                        source_range.end = list_token.source_range.end;
                        break;
                    },
                    .@"value separator" => continue,
                    else => parser.error_with_token(list_token, "expected list end or value separator", .{}),
                }
            }
            std.debug.assert(values.items.len != 0);
            break :value parser.append_command(
                .list,
                .{ .list = values.items },
            );
        },
        .@"block start" => {
            const command_index = parser.append_command(
                .block,
                .{
                    .block = .{
                        // This will be fixed up later.
                        .length = undefined,
                        .resolved = false,
                    },
                },
            );
            const length_before: SourceSize = @intCast(parser.commands.len);
            // This makes sure variables from outside the block will be accessible inside of it.
            parser.parent_variables.append(parser.allocator, parser.variables) catch error_with_out_of_memory();
            // This makes sure variables from inside the block will not be accessible outside of it.
            defer parser.variables = parser.parent_variables.pop().?;
            // There are initially no variables inside the block.
            parser.variables = std.StringArrayHashMapUnmanaged(Variable){};
            while (true) {
                const look_ahead = parser.next_token();
                if (look_ahead.tag == .@"block end") {
                    source_range.end = look_ahead.source_range.end;
                    break;
                }
                parser.return_token(look_ahead);
                parser.parse_statement();
            }
            parser.report_unused_variables(parser.variables);
            const length_after: SourceSize = @intCast(parser.commands.len);
            const length = length_after - length_before;
            if (length == 0) {
                // No other commands were appended so this gets rid of the block command appended initially.
                _ = parser.commands.pop().?;
                break :value Command.special.empty_block;
            }
            // Fix up the length.
            parser.commands.items(.operand)[command_index].block.length = length;
            break :value command_index;
        },
        .@"decimal integer literal",
        .@"hexadecimal integer literal",
        .@"binary integer literal",
        .@"character literal",
        => {
            break :value parser.lower_integer(parser.parse_integer_literal(token));
        },
        .@"single-line string literal",
        .@"multi-line string literal",
        => {
            break :value parser.append_command(
                .list,
                .{ .list = parser.parse_string_literal(token) },
            );
        },
        .@"register access start" => {
            const operand = parser.parse_operation();
            const last_token = parser.next_token_expect(.@"register access end");
            source_range.end = last_token.source_range.end;
            break :value parser.append_command(
                .register_read,
                .{ .unary = .{ .operand = operand, .source_bundle = .{ .range = source_range, .index = parser.source_index } } },
            );
        },
        .unknown => {
            break :value Command.special.unknown;
        },
        else => {
            switch (@intFromEnum(token.tag)) {
                @intFromEnum(Token.Tag.registers_start)...@intFromEnum(Token.Tag.registers_end) => |register| {
                    break :value Command.special.registers_start + register;
                },
                else => parser.error_with_token(token, "expected value", .{}),
            }
        },
    };
    const look_ahead = parser.next_token();
    if (look_ahead.tag == .@"length index operator") {
        source_range.end = look_ahead.source_range.end;
        parser.last_value_source_range = source_range;
        return parser.append_command(
            .list_length,
            .{ .unary = .{
                .operand = value,
                .source_bundle = .{ .range = source_range, .index = parser.source_index },
            } },
        );
    }
    parser.return_token(look_ahead);
    parser.last_value_source_range = source_range;
    return value;
}

fn parse_integer_literal(parser: *Parser, token: Token) MaximumBitSize {
    const token_source = parser.source_slice(token.source_range);
    switch (token.tag) {
        .@"decimal integer literal" => {
            var result: MaximumBitSize = 0;
            for (token_source, 0..) |character, index| {
                if (character == '_') {
                    if (index == 0) parser.error_with_token(token, "leading digit separator", .{});
                    if (index == token_source.len - 1) parser.error_with_token(token, "trailing digit separator", .{});
                    continue;
                }
                const digit = character - '0';
                result = std.math.mul(MaximumBitSize, result, 10) catch {
                    parser.error_with_token(token, "expected integer literal not bigger than {d} bits", .{@bitSizeOf(MaximumBitSize)});
                };
                result = std.math.add(MaximumBitSize, result, digit) catch {
                    parser.error_with_token(token, "expected integer literal not bigger than {d} bits", .{@bitSizeOf(MaximumBitSize)});
                };
            }
            return result;
        },
        .@"hexadecimal integer literal" => {
            var result: MaximumBitSize = 0;
            for (token_source["0x".len..], 0..) |character, index| {
                if (character == '_') {
                    if (index == 0) parser.error_with_token(token, "leading digit separator", .{});
                    if (index == token_source.len - "0x".len - 1) parser.error_with_token(token, "trailing digit separator", .{});
                    continue;
                }
                const digit = switch (character) {
                    '0'...'9' => character - '0',
                    'a'...'f' => (character - 'a') + 10,
                    'A'...'F' => (character - 'A') + 10,
                    else => unreachable,
                };
                result = std.math.mul(MaximumBitSize, result, 16) catch {
                    parser.error_with_token(token, "expected integer literal not bigger than {d} bits", .{@bitSizeOf(MaximumBitSize)});
                };
                result = std.math.add(MaximumBitSize, result, digit) catch {
                    parser.error_with_token(token, "expected integer literal not bigger than {d} bits", .{@bitSizeOf(MaximumBitSize)});
                };
            }
            return result;
        },
        .@"binary integer literal" => {
            var result: MaximumBitSize = 0;
            for (token_source["0b".len..], 0..) |character, index| {
                if (character == '_') {
                    if (index == 0) parser.error_with_token(token, "leading digit separator", .{});
                    if (index == token_source.len - "0b".len - 1) parser.error_with_token(token, "trailing digit separator", .{});
                    continue;
                }
                const digit = character - '0';
                result = std.math.mul(MaximumBitSize, result, 2) catch {
                    parser.error_with_token(token, "expected integer literal not bigger than {d} bits", .{@bitSizeOf(MaximumBitSize)});
                };
                result = std.math.add(MaximumBitSize, result, digit) catch {
                    parser.error_with_token(token, "expected integer literal not bigger than {d} bits", .{@bitSizeOf(MaximumBitSize)});
                };
            }
            return result;
        },
        .@"character literal" => return token_source[1],
        else => unreachable,
    }
}

fn parse_string_literal(parser: *Parser, token: Token) []Command.Index {
    const token_source = parser.source_slice(token.source_range);
    switch (token.tag) {
        .@"single-line string literal" => {
            const source = token_source["\"".len .. token_source.len - "\"".len];
            const values = parser.allocator.alloc(Command.Index, source.len) catch error_with_out_of_memory();
            parser.commands.ensureUnusedCapacity(parser.allocator, source.len) catch error_with_out_of_memory();
            for (values, source) |*value, byte| {
                value.* = parser.lower_integer_assume_capacity(byte);
            }
            return values;
        },
        .@"multi-line string literal" => {
            const source = token_source["```".len .. token_source.len - "```".len];
            const indentation = indentation: {
                var indentation: SourceSize = 0;
                var index: SourceSize = 0;
                while (index < source.len and source[index] == '\n') index += 1;
                for (source[index..]) |byte| {
                    if (byte == ' ') indentation += 1 else break;
                }
                break :indentation indentation;
            };
            var values = std.ArrayListUnmanaged(Command.Index){};
            var index: SourceSize = 0;
            while (index < source.len) {
                var newline = false;
                while (index < source.len and source[index] == '\n') : (index += 1) {
                    if (index != 0) {
                        values.append(parser.allocator, parser.lower_integer(source[index])) catch error_with_out_of_memory();
                    }
                    newline = true;
                }
                if (newline) {
                    index += indentation;
                } else {
                    values.append(parser.allocator, parser.lower_integer(source[index])) catch error_with_out_of_memory();
                    index += 1;
                }
            }
            return values.items;
        },
        else => unreachable,
    }
}
