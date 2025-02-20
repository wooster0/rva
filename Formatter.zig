// Transforms tokens into source code of a standard style.

const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const SourceSize = @import("main.zig").SourceSize;
const SourceRange = @import("main.zig").SourceRange;
const Token = @import("main.zig").Token;
const error_with_source_range = @import("main.zig").error_with_source_range;
const RegisterIndex = @import("main.zig").RegisterIndex;
const compare_ignore_case = @import("main.zig").compare_ignore_case;
const error_with_out_of_memory = @import("main.zig").error_with_out_of_memory;

const Formatter = @This();

tokenizer: Tokenizer,
// This is used for look-ahead and going back a token.
returned_token: ?Token = null,
output: std.ArrayListUnmanaged(u8) = .{},
allocator: std.mem.Allocator,

fn source_slice(formatter: *const Formatter, source_range: SourceRange) []const u8 {
    return formatter.tokenizer.source[source_range.start..source_range.end];
}

fn next_token(formatter: *Formatter) Token {
    if (formatter.returned_token) |token| {
        formatter.returned_token = null;
        return token;
    }
    return formatter.tokenizer.tokenize();
}

fn return_token(formatter: *Formatter, token: Token) void {
    formatter.returned_token = token;
}

pub fn format(formatter: *Formatter) void {
    var level: SourceSize = 0;
    var write_indentation = false;
    while (true) {
        const token = formatter.next_token();

        if (token.tag == .@"block end") level -= 1;

        if (write_indentation) {
            formatter.output.writer(formatter.allocator).writeBytesNTimes("    ", level) catch error_with_out_of_memory();
            write_indentation = false;
        }

        const look_ahead = formatter.next_token();

        switch (token.tag) {
            .@"block start" => level += 1,
            .newline => write_indentation = look_ahead.tag != .newline,
            .end => break,
            else => {},
        }

        formatter.output.writer(formatter.allocator).writeAll(formatter.source_slice(token.source_range)) catch error_with_out_of_memory();

        const insert_space = switch (token.tag) {
            .@"block start" => look_ahead.tag != .newline,
            .@"operation start",
            .@"list start",
            .@"register access start",
            .@"index operator",
            .newline,
            => false,
            else => true,
        } and switch (look_ahead.tag) {
            .@"block end" => look_ahead.tag != .newline and token.tag != .@"block start",
            .@"operation end",
            .@"list end",
            .@"register access end",
            .@"statement end",
            .@"index operator",
            .@"length index operator",
            .@"value separator",
            .newline,
            .end,
            => false,
            else => true,
        };
        formatter.return_token(look_ahead);

        if (insert_space) {
            formatter.output.writer(formatter.allocator).writeByte(' ') catch error_with_out_of_memory();
        }
    }
}
