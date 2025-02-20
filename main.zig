const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const Assembler = @import("Assembler.zig");
const Formatter = @import("Formatter.zig");

pub const std_options = std.Options{ .keep_sigpipe = true };

pub var log_terminal_config: std.io.tty.Config = undefined;
var error_terminal_config: std.io.tty.Config = undefined;

pub fn main() void {
    // We rely on the operating system to free any memory still unfreed after exit of the program.
    // This means resources that need to live until the end of the program as well as intermediate resources are not freed.
    // This plays well with immediately exiting when an error occurs and works for a short-lived process.
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    log_terminal_config = std.io.tty.detectConfig(std.io.getStdOut());
    error_terminal_config = std.io.tty.detectConfig(std.io.getStdErr());

    var arguments = std.process.argsWithAllocator(allocator) catch error_with_out_of_memory();
    // Skip program name.
    _ = arguments.skip();
    const source_file_path_or_format = arguments.next() orelse {
        error_with_message("expected root source file path or \"format\" argument", .{});
    };
    if (compare_ignore_case(true, "format", source_file_path_or_format)) {
        const source_file_path = arguments.next() orelse {
            error_with_message("expected source file path", .{});
        };
        format(allocator, source_file_path);
    } else {
        assemble(allocator, source_file_path_or_format);
    }
}

fn format(allocator: std.mem.Allocator, source_file_path: []const u8) void {
    // Pipeline: source -> Tokenizer -> tokens -> Formatter -> source code.

    const source_file_name = std.fs.path.basename(source_file_path);
    _ = std.mem.lastIndexOfScalar(u8, source_file_name, '.') orelse {
        error_with_message("source file name requires extension", .{});
    };

    const file = std.fs.cwd().openFile(source_file_path, .{ .mode = .read_write }) catch {
        error_with_message("could not open source file", .{});
    };
    defer file.close();

    const source = read_source_file(allocator, file) catch |@"error"| {
        switch (@"error") {
            error.read_failed => error_with_message("could not read source file", .{}),
            error.too_big => error_with_message("source file is bigger than {d} bytes", .{
                // Subtract one because the check is a greater than or equal check.
                std.math.maxInt(SourceSize) - 1,
            }),
        }
    };
    const tokenizer = Tokenizer{
        .source = source,
        .source_file_path = source_file_path,
    };

    var formatter = Formatter{
        .tokenizer = tokenizer,
        .allocator = allocator,
    };
    formatter.format();

    file.setEndPos(0) catch {
        error_with_message("could not write to output file", .{});
    };
    file.pwriteAll(formatter.output.items, 0) catch {
        error_with_message("could not write to output file", .{});
    };
}

fn assemble(allocator: std.mem.Allocator, source_file_path: []const u8) void {
    // Pipeline: source -> Tokenizer -> tokens -> Parser -> commands -> Assembler -> machine code.

    const source_file_name = std.fs.path.basename(source_file_path);
    const source_file_name_without_extension = source_file_name[0 .. std.mem.lastIndexOfScalar(u8, source_file_name, '.') orelse {
        error_with_message("root source file name requires extension", .{});
    }];

    const file = std.fs.cwd().openFile(source_file_path, .{ .mode = .read_only }) catch {
        error_with_message("could not open root source file", .{});
    };
    defer file.close();

    const source = read_source_file(allocator, file) catch |@"error"| {
        switch (@"error") {
            error.read_failed => error_with_message("could not read root source file", .{}),
            error.too_big => error_with_message("root source file is bigger than {d} bytes", .{
                // Subtract one because the check is a greater than or equal check.
                std.math.maxInt(SourceSize) - 1,
            }),
        }
    };
    const tokenizer = Tokenizer{
        .source = source,
        .source_file_path = source_file_path,
    };

    var parser_global_state = Parser.GlobalState{};
    parser_global_state.sources.append(allocator, .{ .source = source, .file_path = source_file_path }) catch error_with_out_of_memory();
    var parser = Parser{
        .tokenizer = tokenizer,
        .global_state = &parser_global_state,
        .source_index = 0,
        .allocator = allocator,
    };
    parser.parse();
    const commands = parser.commands.slice();
    const sources = parser_global_state.sources.items;

    var assembler = Assembler{
        .commands = commands,
        .sources = sources,
        .allocator = allocator,
    };
    assembler.assemble();
    const output = assembler.output.items;

    const output_file = std.fs.cwd().createFile(source_file_name_without_extension, .{
        // Empty the file if one with this name already exists.
        .truncate = true,
        // Make the file executable.
        .mode = 0o777,
    }) catch {
        error_with_message("could not create output file", .{});
    };
    defer output_file.close();
    output_file.writeAll(output) catch {
        std.fs.cwd().deleteFile(source_file_name_without_extension) catch {
            error_with_message("could not write to output file or delete the unwritten output file", .{});
        };
        error_with_message("could not write to output file", .{});
    };
}

fn error_with_message(comptime message_format: []const u8, message_arguments: anytype) noreturn {
    @branchHint(.cold);
    // Use standard error to make this output not redirect.
    const standard_error = std.io.getStdErr();
    var buffered_writer = std.io.bufferedWriter(standard_error.writer());
    const writer = buffered_writer.writer();
    error_terminal_config.setColor(writer, .red) catch abort();
    writer.writeAll("error: ") catch abort();
    error_terminal_config.setColor(writer, .bright_white) catch abort();
    writer.print(message_format ++ "\n", message_arguments) catch abort();
    buffered_writer.flush() catch abort();
    abort();
}

pub fn error_with_out_of_memory() noreturn {
    @branchHint(.cold);
    error_with_message("ran out of memory", .{});
}

pub fn error_with_source_range(
    source: [:0]const u8,
    source_file_path: []const u8,
    source_range: SourceRange,
    comptime item_format: []const u8,
    item_arguments: anytype,
    comptime message_format: []const u8,
    message_arguments: anytype,
) noreturn {
    @branchHint(.cold);
    // Use standard error to make this output not redirect.
    const standard_error = std.io.getStdErr();
    var buffered_writer = std.io.bufferedWriter(standard_error.writer());
    const writer = buffered_writer.writer();

    var row: SourceSize = 0;
    var column: SourceSize = 0;
    var line_start: SourceSize = 0;
    var line_end: SourceSize = 0;
    // Find row, column, and line start.
    while (line_end < source_range.start) : (line_end += 1) {
        switch (source[line_end]) {
            '\n' => {
                row += 1;
                column = 0;
                line_start = line_end + 1;
            },
            else => column += 1,
        }
    }
    // Find line end by skipping to the next newline or source end.
    while (line_end < source.len and source[line_end] != '\n') line_end += 1;
    // Do not print more than one line of the token if it spans multiple lines.
    var token_contains_newlines = false;
    var first_line_length: SourceSize = 0;
    for (source[source_range.start..source_range.end]) |byte| {
        if (byte == '\n') {
            token_contains_newlines = true;
            break;
        }
        first_line_length += 1;
    }

    // Saturate for the case of an .end token.
    const token_length = source_range.end - source_range.start -| 1;
    const token_source = source[line_start..line_end];
    // The first check is a special case for the case of a newline used with the "invalid character" error.
    const spans_multiple_lines = (source_range.end - source_range.start) != 1 and token_contains_newlines;

    // Print out the error.
    error_terminal_config.setColor(writer, .bright_white) catch abort();
    writer.print("{s}:{d}:{d}: ", .{ source_file_path, row + 1, column + 1 }) catch abort();
    error_terminal_config.setColor(writer, .red) catch abort();
    writer.writeAll("error: ") catch abort();
    error_terminal_config.setColor(writer, .bright_white) catch abort();
    writer.print(message_format ++ "\n", message_arguments) catch abort();
    error_terminal_config.setColor(writer, .reset) catch abort();
    writer.print("{s}\n", .{token_source}) catch abort();
    writer.writeByteNTimes(' ', column) catch abort();
    error_terminal_config.setColor(writer, .green) catch abort();
    writer.writeByteNTimes('^', if (spans_multiple_lines) first_line_length else token_length + 1) catch abort();
    error_terminal_config.setColor(writer, .dim) catch abort();
    error_terminal_config.setColor(writer, .white) catch abort();
    writer.print(" (found " ++ item_format ++ "{s})\n", item_arguments ++ .{if (spans_multiple_lines) " spanning multiple lines" else ""}) catch abort();
    error_terminal_config.setColor(writer, .reset) catch abort();
    buffered_writer.flush() catch abort();
    abort();
}

pub fn abort() noreturn {
    @branchHint(.cold);
    std.process.exit(1);
}

var read_source_file_total_amount: SourceSize = 0;
pub fn read_source_file(allocator: std.mem.Allocator, file: std.fs.File) error{ read_failed, too_big }![:0]const u8 {
    const size = (file.stat() catch return error.read_failed).size;
    // This ensures SourceSize and Command.Index never overflow and also reserves Command.none.
    if (read_source_file_total_amount + size >= std.math.maxInt(SourceSize)) {
        return error.too_big;
    }
    const source = allocator.allocSentinel(u8, @intCast(size), 0) catch error_with_out_of_memory();
    const amount = file.readAll(source) catch return error.read_failed;
    if (amount != size) {
        return error.read_failed;
    }
    read_source_file_total_amount += @intCast(amount);
    return source;
}

// Returns whether strings a and b are equal, ignoring case and asserting a is lowercase.
// If check_length is false, asserts both inputs are of equal length.
pub fn compare_ignore_case(check_length: bool, a: []const u8, b: []const u8) bool {
    if (check_length and a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        std.debug.assert(!std.ascii.isUpper(a_byte));
        if (a_byte != std.ascii.toLower(b_byte)) {
            return false;
        }
    }
    return true;
}

// Checks whether the given integer fits within the given amount of bits, either signed or unsigned, and returns the casted result or null.
pub fn cast_or_null(integer: MaximumBitSize, bit_count: comptime_int) ?@Type(.{ .int = .{ .signedness = .unsigned, .bits = bit_count } }) {
    const SizeUnsigned = @Type(.{ .int = .{ .signedness = .unsigned, .bits = bit_count } });
    const SizeSigned = @Type(.{ .int = .{ .signedness = .signed, .bits = bit_count } });
    return @bitCast(std.math.cast(SizeSigned, @as(MaximumBitSizeSigned, @bitCast(integer))) orelse {
        return std.math.cast(SizeUnsigned, integer) orelse {
            return null;
        };
    });
}

pub const SourceSize = u32;
pub const MaximumBitSize = u64;
pub const MaximumBitSizeSigned = i64;
pub const RegisterIndex = u5;

pub const SourceRange = struct {
    start: SourceSize,
    end: SourceSize,
};

pub const Source = struct {
    source: [:0]const u8,
    file_path: []const u8,
};

pub const SourceIndex = SourceSize;

pub const SourceBundle = struct {
    range: SourceRange,
    index: SourceIndex,

    pub const none = SourceBundle{
        .range = undefined,
        .index = std.math.maxInt(SourceIndex),
    };

    pub fn is_none(source_bundle: SourceBundle) bool {
        return source_bundle.index == std.math.maxInt(SourceIndex);
    }
};

pub const Token = struct {
    tag: Tag,
    source_range: SourceRange,

    pub const Tag = enum(u8) {
        registers_start = 0b00000,
        registers_end = 0b11111,
        directive,
        register,
        here,
        identifier,
        constant,
        @"block operand",
        @"label definition",
        @"relative label reference",
        @"absolute label reference",
        @"minus sign",
        @"assignment operator",
        @"addition operator",
        @"multiplication operator",
        @"division operator",
        @"modulo operator",
        @"bitwise AND operator",
        @"bitwise OR operator",
        @"bitwise XOR operator",
        @"bitwise NOT operator",
        @"bitwise left shift operator",
        @"bitwise right shift operator",
        @"index operator",
        @"length index operator",
        @"concatenation operator",
        @"duplication operator",
        @"operation start",
        @"operation end",
        @"block start",
        @"block end",
        @"list start",
        @"list end",
        @"register access start",
        @"register access end",
        @"statement end",
        @"decimal integer literal",
        @"hexadecimal integer literal",
        @"binary integer literal",
        @"character literal",
        @"single-line string literal",
        @"multi-line string literal",
        @"value separator",
        unknown,
        comment,
        newline,
        end,
        _,

        pub fn name(tag: Tag) []const u8 {
            return switch (@intFromEnum(tag)) {
                @intFromEnum(Token.Tag.registers_start)...@intFromEnum(Token.Tag.registers_end) => "register",
                else => @tagName(tag),
            };
        }
    };
};

pub fn index_commands_tag(commands: std.MultiArrayList(Command).Slice, index: Command.Index) Command.Tag {
    return switch (index) {
        Command.special.none => unreachable,
        Command.special.bytes_start...Command.special.bytes_end => .integer,
        Command.special.registers_start...Command.special.registers_end => .register,
        Command.special.empty_block => .block,
        Command.special.empty_list => .list,
        Command.special.unknown => .unknown,
        else => commands.items(.tag)[index],
    };
}

pub fn index_commands_operand(commands: std.MultiArrayList(Command).Slice, index: Command.Index) Command.Operand {
    return switch (index) {
        Command.special.none => unreachable,
        Command.special.bytes_start...Command.special.bytes_end => .{ .integer = index - Command.special.bytes_start },
        Command.special.registers_start...Command.special.registers_end => .{ .register = @intCast(index - Command.special.registers_start) },
        Command.special.empty_block => .{ .block = .{ .length = 0, .resolved = true } },
        Command.special.empty_list => .{ .list = &.{} },
        Command.special.unknown => unreachable,
        else => commands.items(.operand)[index],
    };
}

// Returns a mutable tag or null if the index is a special representation and the tag need not be mutated.
pub fn index_commands_tag_pointer(commands: std.MultiArrayList(Command).Slice, index: Command.Index) ?*Command.Tag {
    if (Command.special.contains(index)) return null;
    return &commands.items(.tag)[index];
}

// Returns a mutable operand or null if the index is a special representation and the operand need not be mutated.
pub fn index_commands_operand_pointer(commands: std.MultiArrayList(Command).Slice, index: Command.Index) ?*Command.Operand {
    if (Command.special.contains(index)) return null;
    return &commands.items(.operand)[index];
}

pub const Command = struct {
    tag: Tag,
    operand: Operand,

    // This contains special representations for certain commands representing common values so that commands for such common values need not be repeatedly created.
    pub const special = struct {
        pub const start = std.math.maxInt(Index) - (1 + 0xff + 1 + 32 + 1 + 1 + 1);
        pub const none: Index = start;
        pub const bytes_start: Index = none + 1;
        pub const bytes_end: Index = bytes_start + 0xff;
        pub const registers_start: Index = bytes_end + 1;
        pub const registers_end: Index = registers_start + 32;
        pub const empty_block: Index = registers_end + 1;
        pub const empty_list: Index = empty_block + 1;
        pub const unknown: Index = empty_list + 1;
        pub const end = unknown;

        comptime {
            std.debug.assert(end == std.math.maxInt(Index));
        }

        pub fn contains(index: Index) bool {
            return switch (index) {
                Command.special.start...Command.special.end => true,
                else => false,
            };
        }
    };

    pub fn format(index: Index, buffer: []u8) []const u8 {
        return switch (index) {
            Command.special.none => "none",
            Command.special.bytes_start...Command.special.bytes_end => std.fmt.bufPrint(buffer, "{d}", .{index - Command.special.bytes_start}) catch unreachable,
            Command.special.registers_start...Command.special.registers_end => std.fmt.bufPrint(buffer, "x{d}", .{index - Command.special.registers_start}) catch unreachable,
            Command.special.empty_block => "{}",
            Command.special.empty_list => "[]",
            Command.special.unknown => "unknown",
            else => std.fmt.bufPrint(buffer, "%{d}", .{index}) catch unreachable,
        };
    }

    pub fn shift(index: Index, offset: Index) Index {
        // Special representations need not be shifted.
        if (Command.special.contains(index)) return index;
        return index + offset;
    }

    pub const Index = SourceSize;

    pub const Tag = enum {
        // Uses .integer.
        integer,
        // Uses .register.
        register,
        // Uses .block.
        block,
        // Uses .list.
        list,
        // Uses .source_bundle.
        label_definition,
        // Uses .label_reference.
        relative_label_reference,
        // Uses .label_reference.
        absolute_label_reference,
        // Uses none.
        here,
        // Uses .source_bundle.
        block_operand,
        // Uses .instruction.
        instruction,
        // Uses .list_element_write.
        list_element_write,
        // Uses .unary.
        register_read,
        // Uses .register_write.
        register_write,

        // Uses .unary.
        directive_origin,
        // Uses .block_and_operand.
        directive_inline,
        // Uses .block_and_operand.
        directive_invoke,
        // Uses .directive_log.
        directive_log,
        // Uses .unary.
        directive_bytes,
        // Uses .unary.
        directive_byte,
        // Uses .unary.
        directive_half,
        // Uses .unary.
        directive_word,
        // Uses .unary.
        directive_double,

        // Uses .binary.
        addition,
        // Uses .binary.
        subtraction,
        // Uses .binary.
        multiplication,
        // Uses .binary.
        division,
        // Uses .binary.
        modulo,
        // Uses .binary.
        concatenation,
        // Uses .binary.
        duplication,
        // Uses .binary.
        bitwise_and,
        // Uses .binary.
        bitwise_or,
        // Uses .binary.
        bitwise_xor,
        // Uses .binary.
        bitwise_left_shift,
        // Uses .binary.
        bitwise_right_shift,
        // Uses .binary.
        index,

        // Uses .unary.
        bitwise_not,
        // Uses .unary.
        negation,
        // Uses .unary.
        list_length,

        // Uses none.
        unknown,
    };

    pub const Operand = union {
        integer: Integer,
        register: Register,
        block: Block,
        list: List,
        label_reference: LabelReference,
        instruction: Instruction,
        block_and_operand: BlockAndOperand,
        directive_log: DirectiveLog,
        binary: Binary,
        unary: Unary,
        source_bundle: SourceBundle,
        list_element_write: ListElementWrite,
        register_write: RegisterWrite,

        pub const Integer = MaximumBitSize;
        pub const Register = RegisterIndex;
        pub const Block = struct {
            length: SourceSize,
            resolved: bool,
        };
        pub const List = []Index;

        pub const LabelReference = struct {
            source_bundle: SourceBundle,
            address: MaximumBitSize,
        };

        pub const Instruction = struct {
            type: Type,
            bits: Index,
            operands: Index,
            source_bundle: SourceBundle,
            relative_label_reference: SourceBundle,

            pub const Type = enum {
                r,
                i,
                s,
                b,
                u,
                j,
                other,
            };
        };

        pub const BlockAndOperand = struct {
            block: Index,
            block_source_bundle: SourceBundle,
            operand: Index,
            operand_source_bundle: SourceBundle,
        };

        pub const DirectiveLog = struct {
            operand: Index,
            source_range_start: SourceSize,
            source_index: SourceIndex,
        };

        const Binary = struct {
            left: Index,
            left_source_range: SourceRange,
            right: Index,
            right_source_range: SourceRange,
            source_index: SourceIndex,

            pub fn left_source_bundle(binary: Binary) SourceBundle {
                return .{
                    .range = binary.left_source_range,
                    .index = binary.source_index,
                };
            }

            pub fn right_source_bundle(binary: Binary) SourceBundle {
                return .{
                    .range = binary.right_source_range,
                    .index = binary.source_index,
                };
            }

            pub fn operation_source_bundle(binary: Binary) SourceBundle {
                return SourceBundle{
                    .range = .{
                        .start = binary.left_source_range.start,
                        .end = binary.right_source_range.end,
                    },
                    .index = binary.source_index,
                };
            }
        };

        pub const Unary = struct {
            operand: Index,
            source_bundle: SourceBundle,
        };

        pub const ListElementWrite = struct {
            list: Index,
            list_source_range: SourceRange,
            index: Index,
            index_source_range: SourceRange,
            element: Index,
            source_index: SourceIndex,

            pub fn list_source_bundle(list_element_write: ListElementWrite) SourceBundle {
                return .{
                    .range = list_element_write.list_source_range,
                    .index = list_element_write.source_index,
                };
            }

            pub fn index_source_bundle(list_element_write: ListElementWrite) SourceBundle {
                return .{
                    .range = list_element_write.index_source_range,
                    .index = list_element_write.source_index,
                };
            }

            pub fn operation_source_bundle(list_element_write: ListElementWrite) SourceBundle {
                return .{
                    .range = .{
                        .start = list_element_write.list_source_range.start,
                        .end = list_element_write.index_source_range.end,
                    },
                    .index = list_element_write.source_index,
                };
            }
        };

        pub const RegisterWrite = struct {
            register: Index,
            register_source_range: SourceRange,
            value: Index,
            value_source_range: SourceRange,
            operation_source_range: SourceRange,
            source_index: SourceIndex,

            pub fn register_source_bundle(register_write: RegisterWrite) SourceBundle {
                return .{
                    .range = register_write.register_source_range,
                    .index = register_write.source_index,
                };
            }

            pub fn value_source_bundle(register_write: RegisterWrite) SourceBundle {
                return .{
                    .range = register_write.value_source_range,
                    .index = register_write.source_index,
                };
            }

            pub fn operation_source_bundle(register_write: RegisterWrite) SourceBundle {
                return .{
                    .range = register_write.operation_source_range,
                    .index = register_write.source_index,
                };
            }
        };
    };
};
