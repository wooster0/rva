// Transforms source into a representation where each meaningful unit of information is separate.

const SourceSize = @import("main.zig").SourceSize;
const Token = @import("main.zig").Token;
const error_with_source_range = @import("main.zig").error_with_source_range;
const RegisterIndex = @import("main.zig").RegisterIndex;
const compare_ignore_case = @import("main.zig").compare_ignore_case;

const Tokenizer = @This();

source: [:0]const u8,
source_file_path: []const u8,
index: SourceSize = 0,
current_line_start: SourceSize = 0,

const State = enum {
    start,
    comment,
    at_sign,
    dollar_sign,
    directive,
    constant,
    identifier,
    colon,
    relative_label_reference,
    absolute_label_reference,
    plus_sign,
    asterisk,
    period,
    less_than_sign,
    greater_than_sign,
    zero,
    integer_literal_decimal,
    integer_literal_hexadecimal,
    integer_literal_binary,
    apostrophe,
    singleline_string_literal,
    multiline_string_literal,
};

fn error_with_invalid_character(tokenizer: *const Tokenizer, comptime message: []const u8) noreturn {
    @branchHint(.cold);
    error_with_source_range(
        tokenizer.source,
        tokenizer.source_file_path,
        .{ .start = tokenizer.index, .end = tokenizer.index + 1 },
        "invalid character 0x{X}",
        .{tokenizer.source[tokenizer.index]},
        message,
        .{},
    );
}

pub fn tokenize(tokenizer: *Tokenizer) Token {
    var token: Token = .{
        .tag = undefined,
        .source_range = .{
            .start = tokenizer.index,
            .end = undefined,
        },
    };
    tokenize: switch (State.start) {
        .start => switch (tokenizer.source[tokenizer.index]) {
            ' ' => {
                tokenizer.index += 1;
                token.source_range.start = tokenizer.index;
                continue :tokenize .start;
            },
            '#' => continue :tokenize .comment,
            '\n' => {
                token.tag = .newline;
                tokenizer.index += 1;
                tokenizer.current_line_start = tokenizer.index;
            },
            '@' => {
                tokenizer.index += 1;
                continue :tokenize .at_sign;
            },
            '$' => {
                tokenizer.index += 1;
                continue :tokenize .dollar_sign;
            },
            'a'...'z', 'A'...'Z', '_' => continue :tokenize .identifier,
            ':' => {
                tokenizer.index += 1;
                continue :tokenize .colon;
            },
            '=' => {
                token.tag = .@"assignment operator";
                tokenizer.index += 1;
            },
            '+' => {
                tokenizer.index += 1;
                continue :tokenize .plus_sign;
            },
            '-' => {
                token.tag = .@"minus sign";
                tokenizer.index += 1;
            },
            '*' => {
                tokenizer.index += 1;
                continue :tokenize .asterisk;
            },
            '/' => {
                token.tag = .@"division operator";
                tokenizer.index += 1;
            },
            '%' => {
                token.tag = .@"modulo operator";
                tokenizer.index += 1;
            },
            '&' => {
                token.tag = .@"bitwise AND operator";
                tokenizer.index += 1;
            },
            '|' => {
                token.tag = .@"bitwise OR operator";
                tokenizer.index += 1;
            },
            '^' => {
                token.tag = .@"bitwise XOR operator";
                tokenizer.index += 1;
            },
            '!', '~' => {
                token.tag = .@"bitwise NOT operator";
                tokenizer.index += 1;
            },
            '.' => {
                tokenizer.index += 1;
                continue :tokenize .period;
            },
            '(' => {
                token.tag = .@"operation start";
                tokenizer.index += 1;
            },
            ')' => {
                token.tag = .@"operation end";
                tokenizer.index += 1;
            },
            '{' => {
                token.tag = .@"block start";
                tokenizer.index += 1;
            },
            '}' => {
                token.tag = .@"block end";
                tokenizer.index += 1;
            },
            '[' => {
                token.tag = .@"list start";
                tokenizer.index += 1;
            },
            ']' => {
                token.tag = .@"list end";
                tokenizer.index += 1;
            },
            '<' => {
                tokenizer.index += 1;
                continue :tokenize .less_than_sign;
            },
            '>' => {
                tokenizer.index += 1;
                continue :tokenize .greater_than_sign;
            },
            ';' => {
                token.tag = .@"statement end";
                tokenizer.index += 1;
            },
            '0' => {
                tokenizer.index += 1;
                continue :tokenize .zero;
            },
            '1'...'9' => continue :tokenize .integer_literal_decimal,
            '\'' => {
                tokenizer.index += 1;
                continue :tokenize .apostrophe;
            },
            '"' => continue :tokenize .singleline_string_literal,
            '`' => continue :tokenize .multiline_string_literal,
            ',' => {
                token.tag = .@"value separator";
                tokenizer.index += 1;
            },
            '?' => {
                token.tag = .unknown;
                tokenizer.index += 1;
            },
            0 => if (tokenizer.index == tokenizer.source.len) {
                return .{
                    .tag = .end,
                    .source_range = .{
                        // Saturate for the case of no source.
                        .start = tokenizer.index -| 1,
                        .end = tokenizer.index -| 1,
                    },
                };
            } else {
                tokenizer.error_with_invalid_character("meaningless");
            },
            else => tokenizer.error_with_invalid_character("meaningless"),
        },
        .at_sign => switch (tokenizer.source[tokenizer.index]) {
            '@' => {
                token.tag = .here;
                tokenizer.index += 1;
            },
            'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :tokenize .directive,
            else => tokenizer.error_with_invalid_character("meaningless"),
        },
        .dollar_sign => switch (tokenizer.source[tokenizer.index]) {
            '$' => {
                token.tag = .@"block operand";
                tokenizer.index += 1;
            },
            'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :tokenize .constant,
            else => tokenizer.error_with_invalid_character("meaningless"),
        },
        .directive => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :tokenize .directive,
                else => token.tag = .directive,
            }
        },
        .identifier => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :tokenize .identifier,
                ':' => {
                    token.tag = .@"label definition";
                    tokenizer.index += 1;
                },
                else => {
                    if (parse_register(tokenizer.source[token.source_range.start..tokenizer.index])) |register| {
                        token.tag = @enumFromInt(register);
                    } else {
                        token.tag = .identifier;
                    }
                },
            }
        },
        .colon => {
            switch (tokenizer.source[tokenizer.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :tokenize .relative_label_reference,
                ':' => continue :tokenize .absolute_label_reference,
                else => tokenizer.error_with_invalid_character("meaningless"),
            }
        },
        .relative_label_reference => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :tokenize .relative_label_reference,
                else => token.tag = .@"relative label reference",
            }
        },
        .absolute_label_reference => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :tokenize .absolute_label_reference,
                else => token.tag = .@"absolute label reference",
            }
        },
        .constant => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :tokenize .constant,
                else => token.tag = .constant,
            }
        },
        .plus_sign => switch (tokenizer.source[tokenizer.index]) {
            '+' => {
                token.tag = .@"concatenation operator";
                tokenizer.index += 1;
            },
            else => token.tag = .@"addition operator",
        },
        .asterisk => switch (tokenizer.source[tokenizer.index]) {
            '*' => {
                token.tag = .@"duplication operator";
                tokenizer.index += 1;
            },
            else => token.tag = .@"multiplication operator",
        },
        .period => switch (tokenizer.source[tokenizer.index]) {
            '@' => {
                token.tag = .@"length index operator";
                tokenizer.index += 1;
            },
            else => token.tag = .@"index operator",
        },
        .less_than_sign => switch (tokenizer.source[tokenizer.index]) {
            '<' => {
                token.tag = .@"bitwise left shift operator";
                tokenizer.index += 1;
            },
            else => token.tag = .@"register access start",
        },
        .greater_than_sign => switch (tokenizer.source[tokenizer.index]) {
            '>' => {
                token.tag = .@"bitwise right shift operator";
                tokenizer.index += 1;
            },
            else => token.tag = .@"register access end",
        },
        .zero => switch (tokenizer.source[tokenizer.index]) {
            'x', 'X' => continue :tokenize .integer_literal_hexadecimal,
            'b', 'B' => continue :tokenize .integer_literal_binary,
            '0'...'9' => tokenizer.error_with_invalid_character("meaningless leading zero"),
            else => token.tag = .@"decimal integer literal",
        },
        .integer_literal_decimal => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                '0'...'9', '_' => continue :tokenize .integer_literal_decimal,
                else => token.tag = .@"decimal integer literal",
            }
        },
        .integer_literal_hexadecimal => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                '0'...'9', 'a'...'f', 'A'...'F', '_' => continue :tokenize .integer_literal_hexadecimal,
                else => token.tag = .@"hexadecimal integer literal",
            }
        },
        .integer_literal_binary => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                '0', '1', '_' => continue :tokenize .integer_literal_binary,
                else => token.tag = .@"binary integer literal",
            }
        },
        .apostrophe => {
            tokenizer.index += 1;
            if (tokenizer.source[tokenizer.index] != '\'') tokenizer.error_with_invalid_character("expected terminating apostrophe");
            token.tag = .@"character literal";
            tokenizer.index += 1;
        },
        .singleline_string_literal => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                '\n' => tokenizer.error_with_invalid_character("newline"),
                '"' => {
                    token.tag = .@"single-line string literal";
                    tokenizer.index += 1;
                },
                0 => tokenizer.error_with_invalid_character("meaningless"),
                else => continue :tokenize .singleline_string_literal,
            }
        },
        .multiline_string_literal => {
            const indentation = tokenizer.index - tokenizer.current_line_start;
            tokenizer.index += 1;
            if (tokenizer.source[tokenizer.index] != '`') tokenizer.error_with_invalid_character("expected grave accent");
            tokenizer.index += 1;
            if (tokenizer.source[tokenizer.index] != '`') tokenizer.error_with_invalid_character("expected grave accent");
            tokenizer.index += 1;
            if (tokenizer.source[tokenizer.index] != '\n') tokenizer.error_with_invalid_character("expected newline");
            tokenizer.index += 1;
            while (true) {
                for (0..indentation) |_| {
                    while (tokenizer.source[tokenizer.index] == '\n') tokenizer.index += 1;
                    if (tokenizer.source[tokenizer.index] != ' ') tokenizer.error_with_invalid_character("expected matching indentation");
                    tokenizer.index += 1;
                }
                if (tokenizer.source[tokenizer.index] == '`') {
                    tokenizer.index += 1;
                    if (tokenizer.source[tokenizer.index] != '`') tokenizer.error_with_invalid_character("expected grave accent");
                    tokenizer.index += 1;
                    if (tokenizer.source[tokenizer.index] != '`') tokenizer.error_with_invalid_character("expected grave accent");
                    tokenizer.index += 1;
                    token.tag = .@"multi-line string literal";
                    break;
                }
                while (true) {
                    switch (tokenizer.source[tokenizer.index]) {
                        '\n' => {
                            tokenizer.index += 1;
                            break;
                        },
                        else => {},
                    }
                    tokenizer.index += 1;
                }
            }
        },
        .comment => {
            tokenizer.index += 1;
            switch (tokenizer.source[tokenizer.index]) {
                '\n', 0 => {
                    token.tag = .comment;
                },
                else => continue :tokenize .comment,
            }
        },
    }
    token.source_range.end = tokenizer.index;
    return token;
}

fn parse_register(name: []const u8) ?RegisterIndex {
    switch (name.len) {
        2 => {
            if (name[0] == 'x' or name[0] == 'X') {
                return switch (name[1]) {
                    '0'...'9' => @intCast(name[1] - '0'),
                    else => null,
                };
            }
            const candidate_names = [32]?[]const u8{
                null, "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
                "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", null, null, "t3", "t4", "t5", "t6",
            };
            for (candidate_names, 0..) |potential_candidate_name, index| {
                if (potential_candidate_name) |candidate_name| {
                    if (compare_ignore_case(false, candidate_name, name)) return @intCast(index);
                }
            }
            if (compare_ignore_case(false, "fp", name)) return 8;
        },
        3 => {
            if (name[0] == 'x' or name[0] == 'X') {
                var index: RegisterIndex = switch (name[1]) {
                    '0'...'9' => @intCast(name[1] - '0'),
                    else => return null,
                };
                index *= 10;
                switch (name[1]) {
                    '1'...'2' => {
                        index += switch (name[2]) {
                            '0'...'9' => @intCast(name[2] - '0'),
                            else => return null,
                        };
                    },
                    '3' => {
                        index += switch (name[2]) {
                            '0'...'1' => @intCast(name[2] - '0'),
                            else => return null,
                        };
                    },
                    else => return null,
                }
                return index;
            }
            if (compare_ignore_case(false, "s10", name)) return 26;
            if (compare_ignore_case(false, "s11", name)) return 27;
        },
        4 => {
            if (compare_ignore_case(false, "zero", name)) return 0;
        },
        else => {},
    }
    return null;
}
