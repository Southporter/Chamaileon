const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "OK", .keyword_ok },
        .{ "NO", .keyword_no },
        .{ "BAD", .keyword_bad },
        .{ "SELECT", .keyword_select },
        .{ "EXAMINE", .keyword_examine },
        .{ "CREATE", .keyword_create },
        .{ "DELETE", .keyword_delete },
        .{ "RENAME", .keyword_rename },
        .{ "LIST", .keyword_list },
        .{ "LSUB", .keyword_lsub },
        .{ "STATUS", .keyword_status },
        .{ "APPEND", .keyword_append },
        .{ "CHECK", .keyword_check },
        .{ "CLOSE", .keyword_close },
        .{ "EXPUNGE", .keyword_expunge },
        .{ "SEARCH", .keyword_search },
        .{ "FETCH", .keyword_fetch },
        .{ "STORE", .keyword_store },
        .{ "COPY", .keyword_copy },
        .{ "LOGOUT", .keyword_logout },
        .{ "CAPABILITY", .keyword_capability },
        .{ "STARTTLS", .keyword_starttls },
        .{ "AUTHENTICATE", .keyword_authenticate },
        .{ "LOGIN", .keyword_login },
        .{ "NOOP", .keyword_noop },
        .{ "FLAGS", .keyword_flags },
        .{ "EXISTS", .keyword_exists },
        .{ "RECENT", .keyword_recent },
        .{ "UIDVALIDITY", .keyword_uidvalidity },
        .{ "UIDNEXT", .keyword_uidnext },
        .{ "HIGHESTMODSEQ", .keyword_highestmodseq },
        .{ "PERMANENTFLAGS", .keyword_permanentflags },
        .{ "READ-WRITE", .keyword_read_write },
        .{ "READ-ONLY", .keyword_read_only },
        .{ "BODY", .keyword_body},
        .{ "HEADER", .keyword_header },
        .{ "FIELDS", .keyword_fields},
        .{ "SUBJECT", .keyword_subject},
        .{ "FROM", .keyword_subject},
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Tag = enum {
        invalid,
        crlf,
        identifier,
        int,
        float,
        string,
        asterisk,
        period,
        plus,
        dot,
        eql,
        l_brace,
        r_brace,
        l_paren,
        r_paren,
        l_bracket,
        r_bracket,

        keyword_ok,
        keyword_no,
        keyword_bad,

        keyword_select,
        keyword_examine,
        keyword_create,
        keyword_delete,
        keyword_rename,
        keyword_list,
        keyword_lsub,
        keyword_status,
        keyword_append,
        keyword_check,
        keyword_close,
        keyword_expunge,
        keyword_search,
        keyword_fetch,
        keyword_store,
        keyword_copy,
        keyword_logout,
        keyword_capability,
        keyword_starttls,
        keyword_authenticate,
        keyword_login,
        keyword_noop,
        keyword_flags,
        keyword_exists,
        keyword_recent,
        keyword_uidvalidity,
        keyword_uidnext,
        keyword_highestmodseq,
        keyword_permanentflags,
        keyword_read_write,
        keyword_read_only,

        keyword_body,
        keyword_header,
        keyword_fields,
        keyword_subject,
        keyword_from,

        eof,
    };
};
pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    const State = enum {
        start,
        invalid,

        seen_cr,
        backslash,

        int,
        int_period,
        int_exponent,
        float,
        float_exponent,

        identifier,
        string,
        string_backslash,
    };

    pub fn init(buffer: [:0]const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = .invalid,
            .start = self.index,
            .end = undefined,
        };

        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index == self.buffer.len) {
                        result.tag = .eof;
                        result.end = self.index;
                        return result;
                    } else {
                        continue :state .invalid;
                    }
                },
                ' ', '\t' => {
                    self.index += 1;
                    result.start = self.index;
                    continue :state .start;
                },
                '\r' => {
                    self.index += 1;
                    result.start = self.index;
                    continue :state .seen_cr;
                },
                '(' => {
                    result.tag = .l_paren;
                    self.index += 1;
                },
                ')' => {
                    result.tag = .r_paren;
                    self.index += 1;
                },
                '[' => {
                    result.tag = .l_bracket;
                    self.index += 1;
                },
                ']' => {
                    result.tag = .r_bracket;
                    self.index += 1;
                },
                '{' => {
                    result.tag = .l_brace;
                    self.index += 1;
                },
                '}' => {
                    result.tag = .r_brace;
                    self.index += 1;
                },
                '"' => {
                    result.tag = .string;
                    continue :state .string;
                },
                '*' => {
                    result.tag = .asterisk;
                    self.index += 1;
                },
                '.' => {
                    result.tag = .period;
                    self.index += 1;
                },
                '=' => {
                    result.tag = .eql;
                    self.index += 1;
                },
                '+' => {
                    result.tag = .plus;
                    self.index += 1;
                },
                '\\' => continue :state .backslash,
                '$',
                'a'...'z',
                'A'...'Z',
                => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '0'...'9' => {
                    result.tag = .int;
                    self.index += 1;
                    continue :state .int;
                },
                else => continue :state .invalid,
            },
            .invalid => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
                    '\n' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },
            .seen_cr => switch (self.buffer[self.index]) {
                0 => if (self.index == self.buffer.len) {
                    result.tag = .eof;
                    result.end = self.index;
                    return result;
                } else {
                    continue :state .invalid;
                },
                '\n' => {
                    self.index += 1;
                    result.tag = .crlf;
                    result.end = self.index;
                    return result;
                },
                else => {
                    self.index += 1;
                    continue :state .start;
                },
            },

            .backslash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => result.tag = .invalid,
                    '\n' => result.tag = .invalid,
                    else => continue :state .start,
                }
            },
            .string => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                    '\n' => result.tag = .invalid,
                    '\\' => continue :state .string_backslash,
                    '"' => self.index += 1,
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .string,
                }
            },

            .string_backslash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    else => continue :state .string,
                }
            },

            .identifier => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z', '_', '-', '0'...'9' => continue :state .identifier,
                    else => {
                        const ident = self.buffer[result.start..self.index];
                        if (Token.getKeyword(ident)) |tag| {
                            result.tag = tag;
                        }
                    },
                }
            },

            .int => switch (self.buffer[self.index]) {
                '.' => continue :state .int_period,
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.index += 1;
                    continue :state .int;
                },
                'e', 'E', 'p', 'P' => {
                    continue :state .int_exponent;
                },
                else => {},
            },
            .int_exponent => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '-', '+' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    else => continue :state .int,
                }
            },
            .int_period => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    'e', 'E', 'p', 'P' => {
                        continue :state .float_exponent;
                    },
                    else => self.index -= 1,
                }
            },
            .float => switch (self.buffer[self.index]) {
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.index += 1;
                    continue :state .float;
                },
                'e', 'E', 'p', 'P' => {
                    continue :state .float_exponent;
                },
                else => {},
            },
            .float_exponent => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '-', '+' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    else => continue :state .float,
                }
            },
        }
        result.end = self.index;
        return result;
    }
};

const crlf = "\r\n";
test "list response" {
    const input: [:0]const u8 = "* LIST (\\Noselect) \"/\" \"INBOX\"" ++ crlf ++ "AAAA OK Success" ++ crlf;

    try testTokenize(input, &.{
        .asterisk,
        .keyword_list,
        .l_paren,
        .identifier,
        .r_paren,
        .string,
        .string,
        .crlf,
        .identifier,
        .keyword_ok,
        .identifier,
        .crlf,
    });
}

test "keywords" {
    const input: [:0]const u8 = "OK BAD NO READ-WRITE";
    try testTokenize(input, &.{
        .keyword_ok,
        .keyword_bad,
        .keyword_no,
        .keyword_read_write,
    });
}
test "punctuation" {
    const input: [:0]const u8 = "()[]{}*.";
    try testTokenize(input, &.{
        .l_paren,
        .r_paren,
        .l_bracket,
        .r_bracket,
        .l_brace,
        .r_brace,
        .asterisk,
        .period,
    });
}

test "whitespace" {
    const input: [:0]const u8 = "\r \t\r\n";
    try testTokenize(input, &.{
        .crlf,
    });
}

test "identifier" {
    const input: [:0]const u8 = "INBOX mailbox_name";
    try testTokenize(input, &.{
        .identifier,
        .identifier,
    });
}

test "int" {
    const input: [:0]const u8 = "123 4567";
    try testTokenize(input, &.{
        .int,
        .int,
    });
}

test "select response" {
    // zig fmt: off
    const input: [:0]const u8 = "* FLAGS (\\Seen $Forwarded Junk NotJunk)" ++ crlf
    ++ "* OK [PERMANENTFLAGS (\\Seen $Forwarded Junk NotJunk \\*)] Flags permitted." ++ crlf
    ++ "* OK [UIDVALIDITY 1] UIDs valid." ++ crlf
    ++ "* 20 EXISTS" ++ crlf
    ++ "* 0 RECENT " ++ crlf
    ++ "* OK [UIDNEXT 8775] Predicted next UID." ++ crlf
    ++ "* OK [HIGHESTMODSEQ 1609783]" ++ crlf
    ++ "BBBB OK [READ-WRITE] INBOX selected. (Success)" ++ crlf;
    // zig fmt: on

    try testTokenize(input, &.{
        .asterisk,
        .keyword_flags,
        .l_paren,
        .identifier,
        .identifier,
        .identifier,
        .identifier,
        .r_paren,
        .crlf,
        // Line 2
        .asterisk,
        .keyword_ok,
        .l_bracket,
        .keyword_permanentflags,
        .l_paren,
        .identifier,
        .identifier,
        .identifier,
        .identifier,
        .asterisk,
        .r_paren,
        .r_bracket,
        .identifier,
        .identifier,
        .period,
        .crlf,
        // Line 3
        .asterisk,
        .keyword_ok,
        .l_bracket,
        .keyword_uidvalidity,
        .int,
        .r_bracket,
        .identifier,
        .identifier,
        .period,
        .crlf,
        // Line 4
        .asterisk,
        .int,
        .keyword_exists,
        .crlf,
        // Line 5
        .asterisk,
        .int,
        .keyword_recent,
        .crlf,
        // Line 6
        .asterisk,
        .keyword_ok,
        .l_bracket,
        .keyword_uidnext,
        .int,
        .r_bracket,
        .identifier,
        .identifier,
        .identifier,
        .period,
        .crlf,
        // Line 7
        .asterisk,
        .keyword_ok,
        .l_bracket,
        .keyword_highestmodseq,
        .int,
        .r_bracket,
        .crlf,

        // Line 8
        .identifier,
        .keyword_ok,
        .l_bracket,
        .keyword_read_write,
        .r_bracket,
        .identifier,
        .identifier,
        .period,
        .l_paren,
        .identifier,
        .r_paren,
        .crlf,
    });
}

fn testTokenize(source: [:0]const u8, expected_token_tags: []const Token.Tag) !void {
    var tokenizer = Tokenizer.init(source);
    for (expected_token_tags) |expected_token_tag| {
        const token = tokenizer.next();
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }
    // Last token should always be eof, even when the last token was invalid,
    // in which case the tokenizer is in an invalid state, which can only be
    // recovered by opinionated means outside the scope of this implementation.
    const last_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last_token.tag);
    try std.testing.expectEqual(source.len, last_token.start);
    try std.testing.expectEqual(source.len, last_token.end);
}
