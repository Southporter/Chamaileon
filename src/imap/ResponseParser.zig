const std = @import("std");
const log = std.log.scoped(.imap_response_parser);
const ResponseParser = @This();

tag: []const u8,
reader: *std.Io.Reader,
state: ParserState = .init,
const ParserState = enum {
    init,
    tag,
    untagged,
    response,
    response_o,
    response_ok,
    response_n,
    response_no,
    response_b,
    response_bad,
    line_end,
    end,
    err,
};

const Response = union(enum) {
    untagged: struct {
        value: []const u8,
        kind: []const u8,
    },
    tagged: struct {
        value: []const u8,
        kind: Tag,
    },

    const Tag = enum {
        ok,
        no,
        bad,
    };
};

pub fn next(self: *ResponseParser) ?Response {
    parser: switch (self.state) {
        .init, .line_end => {
            const star = self.reader.peekByte() catch return null;
            if (star == '*') {
                _ = self.reader.takeByte() catch unreachable; // Skip the '*'
                self.state = .untagged;
                continue :parser .untagged;
            } else {
                self.state = .tag;
                continue :parser .tag;
            }
        },
        .untagged => {
            const space = self.reader.takeByte() catch return null;
            if (space != ' ') {
                log.err("Expected space after '*', got: ({c})", .{space});
                self.state = .err;
                return null;
            }
            const kind = self.reader.takeDelimiterExclusive(' ') catch return null;
            _ = self.reader.takeByte() catch unreachable; // Skip space
            log.debug("KIND: {s}", .{kind});
            const value = self.reader.takeDelimiterInclusive('\n') catch return null;
            log.debug("VALUE: {s}", .{value});
            self.state = .line_end;
            return Response{ .untagged = .{ .kind = kind, .value = value[0 .. value.len - 2] } };
        },
        .tag => {
            const tag = (self.reader.takeDelimiter(' ') catch return null) orelse return null;
            std.debug.assert(tag.len == self.tag.len);
            log.debug("TAG: ({s}) == ({s})", .{ tag, self.tag });
            if (!std.mem.eql(u8, tag, self.tag)) {
                log.err("Unexpected tag in response: {s}", .{tag});
                self.state = .err;
                return null;
            }
            self.state = .response;
            continue :parser .response;
        },
        .response => {
            log.debug("Next state: response ({c})", .{self.reader.peekByte() catch return null});
            switch (self.reader.peekByte() catch unreachable) {
                'O' => continue :parser .response_o,
                'N' => continue :parser .response_n,
                'B' => continue :parser .response_b,
                else => |b| {
                    log.err("Unexpected response from IMAP server: ({c})", .{b});
                    self.state = .err;
                    return null;
                },
            }
        },
        .response_o => {
            const ok = self.reader.take(2) catch return null;
            if (ok[1] == 'K') {
                self.state = .response_ok;
                continue :parser .response_ok;
            } else {
                log.err("Unexpected response from IMAP server: ({s})", .{ok});
                self.state = .err;
                return null;
            }
        },
        .response_ok => {
            var value = self.reader.takeDelimiterInclusive('\n') catch return null;
            log.debug("Response OK: {s}", .{value});
            self.state = .end;
            if (value[0] == ' ') {
                value = value[1..]; // Skip leading space
            }
            return Response{ .tagged = .{ .kind = .ok, .value = value[0 .. value.len - 2] } };
        },
        .response_n => {
            const no = self.reader.take(2) catch return null;
            if (no[1] == 'O') {
                self.state = .response_no;
                continue :parser .response_no;
            } else {
                log.err("Unexpected response from IMAP server: ({s})", .{no});
                self.state = .err;
                return null;
            }
        },
        .response_no => {
            var value = self.reader.takeDelimiterInclusive('\n') catch return null;
            if (value[0] == ' ') {
                value = value[1..]; // Skip leading space
            }
            log.debug("Response NO: {s}", .{value});
            self.state = .end;
            return Response{ .tagged = .{ .kind = .no, .value = value[0 .. value.len - 2] } };
        },

        .response_b => {
            const bad = self.reader.take(3) catch return null;
            if (bad[1] == 'A' and bad[2] == 'D') {
                self.state = .response_bad;
                continue :parser .response_bad;
            } else {
                log.err("Unexpected response from IMAP server: ({s})", .{bad});
                self.state = .err;
                return null;
            }
        },

        .response_bad => {
            var value = self.reader.takeDelimiterInclusive('\n') catch return null;
            if (value[0] == ' ') {
                value = value[1..]; // Skip leading space
            }
            log.debug("Response BAD: {s}", .{value});
            self.state = .end;
            return Response{ .tagged = .{ .kind = .bad, .value = value[0 .. value.len - 2] } };
        },
        .end => {
            return null; // No more data
        },
        .err => {
            log.err("Parser is in error state, cannot continue", .{});
            return null; // Error state, no more data
        },
    }
    return null; // No more data
}

test "ResponseParser - full buffer" {
    var fixed: std.Io.Reader = .fixed("* CAPABILITY IMAP4rev1\r\nA001 OK That's it\r\n");
    var parser = ResponseParser{
        .tag = "A001",
        .reader = &fixed,
    };
    var res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqualStrings("CAPABILITY", res.untagged.kind);
    try std.testing.expectEqualStrings("IMAP4rev1", res.untagged.value);
    try std.testing.expectEqual(parser.state, .line_end);
    res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqual(.ok, res.tagged.kind);
    try std.testing.expectEqualStrings("That's it", res.tagged.value);
    try std.testing.expectEqual(parser.state, .end);
    try std.testing.expectEqual(null, parser.next());
    try std.testing.expectEqual(parser.state, .end);
}
test "ResponseParser - full buffer tag with empty value" {
    var fixed: std.Io.Reader = .fixed("* CAPABILITY IMAP4rev1\r\nA001 OK\r\n");
    var parser = ResponseParser{
        .tag = "A001",
        .reader = &fixed,
    };
    var res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqualStrings("CAPABILITY", res.untagged.kind);
    try std.testing.expectEqualStrings("IMAP4rev1", res.untagged.value);
    try std.testing.expectEqual(parser.state, .line_end);
    res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqual(.ok, res.tagged.kind);
    try std.testing.expectEqualStrings("", res.tagged.value);
    try std.testing.expectEqual(parser.state, .end);
    try std.testing.expectEqual(null, parser.next());
    try std.testing.expectEqual(parser.state, .end);
}

test "ResponseParser - partial buffer" {
    var fixed: std.Io.Reader = .fixed("* CAPABILITY IMAP4rev1\r\nA001 O");
    var parser = ResponseParser{
        .tag = "A001",
        .reader = &fixed,
    };
    const res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqualStrings("CAPABILITY", res.untagged.kind);
    try std.testing.expectEqualStrings("IMAP4rev1", res.untagged.value);
    try std.testing.expectEqual(parser.state, .line_end);
    try std.testing.expectEqual(null, parser.next());
    try std.testing.expectEqual(parser.state, .response);

    fixed = .fixed("OK Value\r\n");
    const res2 = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqual(.ok, res2.tagged.kind);
    try std.testing.expectEqualStrings("Value", res2.tagged.value);
    try std.testing.expectEqual(parser.state, .end);
    try std.testing.expectEqual(null, parser.next());
    try std.testing.expectEqual(parser.state, .end);
}

test "ResponseParser - BAD tag" {
    var fixed: std.Io.Reader = .fixed("A001 BAD Invalid command\r\n");
    var parser = ResponseParser{
        .tag = "A001",
        .reader = &fixed,
    };

    const res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqual(.bad, res.tagged.kind);
    try std.testing.expectEqualStrings("Invalid command", res.tagged.value);
    try std.testing.expectEqual(parser.state, .end);
    try std.testing.expectEqual(null, parser.next());
}

test "ResponseParser - NO tag" {
    var fixed: std.Io.Reader = .fixed("A001 NO Not allowed\r\n");
    var parser = ResponseParser{
        .tag = "A001",
        .reader = &fixed,
    };

    const res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqual(.no, res.tagged.kind);
    try std.testing.expectEqualStrings("Not allowed", res.tagged.value);
    try std.testing.expectEqual(parser.state, .end);
    try std.testing.expectEqual(null, parser.next());
}
