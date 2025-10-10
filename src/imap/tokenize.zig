const std = @import("std");
const log = std.log.scoped(.tokenize);

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
        .{ "BODY", .keyword_body },
        .{ "HEADER", .keyword_header },
        .{ "FIELDS", .keyword_fields },
        .{ "Subject", .keyword_subject },
        .{ "SUBJECT", .keyword_subject },
        .{ "From", .keyword_from },
        .{ "FROM", .keyword_from },
        .{ "Date", .keyword_date },
        .{ "DATE", .keyword_date },
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
        colon,
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
        keyword_date,

        eof,
    };
};
pub const Tokenizer = struct {
    input: *std.Io.Reader,
    scratch: [256]u8 = undefined,
    scratch_len: u8 = 0,

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

    pub fn init(reader: *std.Io.Reader) Tokenizer {
        return .{
            .input = reader,
        };
    }

    pub fn save(self: *Tokenizer, b: u8) void {
        self.scratch[self.scratch_len] = b;
        self.scratch_len += 1;
    }

    pub fn take(self: *Tokenizer) void {
        // Assumes we have peeked the byte already
        const b = self.input.takeByte() catch unreachable;
        self.save(b);
    }

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = .invalid,
            .start = 0,
            .end = 0,
        };
        self.scratch_len = 0;

        state: switch (State.start) {
            .start => switch (self.input.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    result.tag = .eof;
                    result.end = 0;
                    return result;
                },
                else => {
                    log.err("Tokenizer error: {t}", .{err});
                    return result;
                },
            }) {
                0 => continue :state .invalid,
                ' ', '\t' => {
                    continue :state .start;
                },
                '\r' => {
                    continue :state .seen_cr;
                },
                '(' => {
                    result.tag = .l_paren;
                },
                ')' => {
                    result.tag = .r_paren;
                },
                '[' => {
                    result.tag = .l_bracket;
                },
                ']' => {
                    result.tag = .r_bracket;
                },
                '{' => {
                    result.tag = .l_brace;
                },
                '}' => {
                    result.tag = .r_brace;
                },
                '"' => {
                    result.tag = .string;
                    continue :state .string;
                },
                '*' => {
                    result.tag = .asterisk;
                },
                '.' => {
                    result.tag = .period;
                },
                ':' => {
                    result.tag = .colon;
                },
                '=' => {
                    result.tag = .eql;
                },
                '+' => {
                    result.tag = .plus;
                },
                '\\' => continue :state .backslash,
                '$',
                'a'...'z',
                'A'...'Z',
                => |b| {
                    self.save(b);
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '0'...'9' => |b| {
                    self.save(b);
                    result.tag = .int;
                    continue :state .int;
                },
                else => continue :state .invalid,
            },
            .invalid => {
                switch (self.input.takeByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        result.tag = .invalid;
                        return result;
                    },
                    else => return result,
                }) {
                    '\n' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },
            .seen_cr => switch (self.input.peekByte() catch |err| switch (err) {
                error.EndOfStream => {
                    result.tag = .eof;
                    return result;
                },
                else => 0,
            }) {
                '\n' => {
                    self.input.toss(1);
                    result.tag = .crlf;
                    return result;
                },
                else => {
                    continue :state .start;
                },
            },

            .backslash => {
                switch (self.input.peekByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        result.tag = .eof;
                        return result;
                    },
                    else => 0,
                }) {
                    0 => result.tag = .invalid,
                    '\n' => result.tag = .invalid,
                    else => continue :state .start,
                }
            },
            .string => {
                switch (self.input.peekByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        result.tag = .eof;
                        return result;
                    },
                    else => 0,
                }) {
                    0 => continue :state .invalid,
                    '\n' => result.tag = .invalid,
                    '\\' => {
                        self.take();
                        continue :state .string_backslash;
                    },
                    '"' => {
                        result.end = self.scratch_len;
                        self.input.toss(1);
                        return result;
                    },
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => {
                        self.take();
                        continue :state .string;
                    },
                }
            },

            .string_backslash => {
                switch (self.input.takeByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        result.tag = .eof;
                        return result;
                    },
                    else => 0,
                }) {
                    0, '\n' => result.tag = .invalid,
                    else => |b| {
                        self.save(b);
                        continue :state .string;
                    },
                }
            },

            .identifier => {
                switch (self.input.peekByte() catch 0) {
                    'a'...'z', 'A'...'Z', '_', '-', '0'...'9' => {
                        self.take();
                        continue :state .identifier;
                    },
                    else => {
                        result.end = self.scratch_len;
                        const ident = self.scratch[0..self.scratch_len];
                        if (Token.getKeyword(ident)) |tag| {
                            result.tag = tag;
                        }
                    },
                }
            },

            .int => switch (self.input.peekByte() catch 0) {
                '.' => {
                    self.take();
                    continue :state .int_period;
                },
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.take();
                    continue :state .int;
                },
                'e', 'E', 'p', 'P' => {
                    self.take();
                    continue :state .int_exponent;
                },
                else => {},
            },
            .int_exponent => {
                switch (self.input.peekByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        result.tag = .eof;
                        self.scratch_len = 0;
                        return result;
                    },
                    else => return result,
                }) {
                    '-', '+' => {
                        self.take();
                        continue :state .float;
                    },
                    else => {
                        self.take();
                        continue :state .int;
                    },
                }
            },
            .int_period => {
                switch (self.input.peekByte() catch 0) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                        self.take();
                        continue :state .float;
                    },
                    'e', 'E', 'p', 'P' => {
                        self.take();
                        continue :state .float_exponent;
                    },
                    else => {},
                }
            },
            .float => switch (self.input.peekByte() catch 0) {
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.take();
                    continue :state .float;
                },
                'e', 'E', 'p', 'P' => {
                    self.take();
                    continue :state .float_exponent;
                },
                else => {},
            },
            .float_exponent => {
                switch (self.input.peekByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        result.tag = .eof;
                        result.end = self.input.seek;
                        return result;
                    },
                    else => return result,
                }) {
                    else => {
                        self.take();
                        continue :state .float;
                    },
                }
            },
        }
        result.end = self.scratch_len;
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
    var reader = std.Io.Reader.fixed(source);
    var tokenizer = Tokenizer.init(&reader);
    for (expected_token_tags) |expected_token_tag| {
        const token = tokenizer.next();
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }
    // Last token should always be eof, even when the last token was invalid,
    // in which case the tokenizer is in an invalid state, which can only be
    // recovered by opinionated means outside the scope of this implementation.
    const last_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last_token.tag);
    // try std.testing.expectEqual(source.len, last_token.start);
    // try std.testing.expectEqual(source.len, last_token.end);
}
