const std = @import("std");
const log = std.log.scoped(.imap_response_parser);
const ResponseParser = @This();

tag: []const u8,
buffer: []const u8,
offset: usize = 0,
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
    if (self.offset >= self.buffer.len) {
        return null; // No more data
    }
    log.debug("NEXT: ({s}) {s}", .{ self.buffer[self.offset .. self.offset + 1], @tagName(self.state) });

    parser: switch (self.state) {
        .init, .line_end => {
            if (self.buffer[self.offset] == '*') {
                self.offset += 1; // Skip the '*'
                self.state = .untagged;
                continue :parser .untagged;
            } else {
                self.state = .tag;
                continue :parser .tag;
            }
        },
        .untagged => {
            if (self.offset >= self.buffer.len) {
                return null; // No more data
            }
            var start = self.offset + 1;
            log.debug("UNTAGGED: {c}", .{self.buffer[self.offset]});
            const kind_end = std.mem.indexOfScalar(u8, self.buffer[start..], ' ') orelse return null;
            const kind = self.buffer[start .. start + kind_end];
            log.debug("KIND: {s}", .{kind});
            start += kind_end + 1; // Skip the space
            const value_start = start;

            while (start + 1 <= self.buffer.len and self.buffer[start] != '\r' and self.buffer[start + 1] != '\n') {
                start += 1;
            }
            if (start + 1 > self.buffer.len or self.buffer[start] != '\r' or self.buffer[start + 1] != '\n') {
                return null; // Not enough data for value
            }
            const value = self.buffer[value_start..start];
            log.debug("VALUE: {s}", .{value});
            self.offset = start + 2; // Skip the \r\n
            self.state = .line_end;
            return Response{ .untagged = .{ .kind = kind, .value = value } };
        },
        .tag => {
            var start = self.offset;
            log.debug("TAG: {c}", .{self.buffer[self.offset]});
            const tag_end = std.mem.indexOfScalar(u8, self.buffer[start..], ' ') orelse return null;
            if (tag_end < 1 or tag_end > self.tag.len) {
                self.state = .line_end;
                return null;
            }
            const tag = self.buffer[start .. start + tag_end];
            std.debug.assert(tag.len == self.tag.len);
            log.debug("TAG: ({s}) == ({s})", .{ tag, self.tag });
            if (!std.mem.eql(u8, tag, self.tag)) {
                log.err("Unexpected tag in response: {s}", .{tag});
                self.state = .err;
                return null;
            }
            start += tag_end + 1;
            self.offset = start;
            self.state = .response;
            continue :parser .response;
        },
        .response => {
            log.debug("Next state: response ({c})", .{self.buffer[self.offset]});
            switch (self.buffer[self.offset]) {
                'O' => continue :parser .response_o,
                'N' => continue :parser .response_n,
                'B' => continue :parser .response_b,
                else => {
                    log.err("Unexpected response from IMAP server: ({s})", .{self.buffer[self.offset..]});
                    self.state = .err;
                    return null;
                },
            }
        },
        .response_o => {
            var start = self.offset;
            if (start + 2 > self.buffer.len) {
                return null; // Not enough data for "OK "
            }
            if (self.buffer[start + 1] == 'K') {
                start += 2; // Skip "OK"
                self.offset = start;
                self.state = .response_ok;
                continue :parser .response_ok;
            } else {
                log.err("Unexpected response from IMAP server: ({s})", .{self.buffer[start..]});
                self.state = .err;
                return null;
            }
        },
        .response_ok => {
            var start = self.offset;
            if (self.buffer[start] == ' ') {
                start += 1; // Skip the space after "OK"
            }
            const value_start = start;
            while (start + 1 <= self.buffer.len and self.buffer[start] != '\r' and self.buffer[start + 1] != '\n') {
                start += 1;
            }
            const value = self.buffer[value_start..start];
            log.debug("Response OK: {s}", .{value});
            self.offset = start + 2; // Skip the \r\n
            self.state = .end;
            return Response{ .tagged = .{ .kind = .ok, .value = value } };
        },
        .response_n => {
            var start = self.offset;
            if (start + 2 > self.buffer.len) {
                return null; // Not enough data for "NO "
            }
            if (self.buffer[start + 1] == 'O') {
                start += 2; // Skip "NO"
                self.offset = start;
                self.state = .response_no;
                continue :parser .response_no;
            } else {
                log.err("Unexpected response from IMAP server: ({s})", .{self.buffer[start..]});
                self.state = .err;
                return null;
            }
        },
        .response_no => {
            var start = self.offset;
            if (self.buffer[start] == ' ') {
                start += 1; // Skip the space after "OK"
            }
            const value_start = start;
            while (start + 1 <= self.buffer.len and self.buffer[start] != '\r' and self.buffer[start + 1] != '\n') {
                start += 1;
            }
            const value = self.buffer[value_start..start];
            log.debug("Response NO: {s}", .{value});
            self.offset = start + 2; // Skip the \r\n
            self.state = .end;
            return Response{ .tagged = .{ .kind = .no, .value = value } };
        },

        .response_b => {
            if (self.offset + 2 >= self.buffer.len) {
                return null; // Not enough data for "BAD "
            }
            if (self.buffer[self.offset + 1] == 'A' and self.buffer[self.offset + 2] == 'D') {
                self.offset += 3;
                self.state = .response_bad;
                continue :parser .response_bad;
            } else {
                log.err("Unexpected response from IMAP server: ({s})", .{self.buffer[self.offset..]});
                self.state = .err;
                return null;
            }
        },

        .response_bad => {
            var start = self.offset;
            if (self.buffer[start] == ' ') {
                start += 1; // Skip the space after "BAD"
            }
            const value_start = start;
            while (start + 1 <= self.buffer.len and self.buffer[start] != '\r' and self.buffer[start + 1] != '\n') {
                start += 1;
            }
            const value = self.buffer[value_start..start];
            log.debug("Response BAD: {s}", .{value});
            self.offset = start + 2; // Skip the \r\n
            self.state = .end;
            return Response{ .tagged = .{ .kind = .bad, .value = value } };
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
    var parser = ResponseParser{
        .tag = "A001",
        .buffer = "* CAPABILITY IMAP4rev1\r\nA001 OK That's it\r\n",
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
    var parser = ResponseParser{
        .tag = "A001",
        .buffer = "* CAPABILITY IMAP4rev1\r\nA001 OK\r\n",
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
    var parser = ResponseParser{
        .tag = "A001",
        .buffer = "* CAPABILITY IMAP4rev1\r\nA001 O",
    };
    const res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqualStrings("CAPABILITY", res.untagged.kind);
    try std.testing.expectEqualStrings("IMAP4rev1", res.untagged.value);
    try std.testing.expectEqual(parser.state, .line_end);
    try std.testing.expectEqual(null, parser.next());
    try std.testing.expectEqual(parser.state, .response);

    parser.offset = 0;
    parser.buffer = "OK Value\r\n";
    const res2 = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqual(.ok, res2.tagged.kind);
    try std.testing.expectEqualStrings("Value", res2.tagged.value);
    try std.testing.expectEqual(parser.state, .end);
    try std.testing.expectEqual(null, parser.next());
    try std.testing.expectEqual(parser.state, .end);
}

test "ResponseParser - BAD tag" {
    var parser = ResponseParser{
        .tag = "A001",
        .buffer = "A001 BAD Invalid command\r\n",
    };

    const res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqual(.bad, res.tagged.kind);
    try std.testing.expectEqualStrings("Invalid command", res.tagged.value);
    try std.testing.expectEqual(parser.state, .end);
    try std.testing.expectEqual(null, parser.next());
}

test "ResponseParser - NO tag" {
    var parser = ResponseParser{
        .tag = "A001",
        .buffer = "A001 NO Not allowed\r\n",
    };

    const res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqual(.no, res.tagged.kind);
    try std.testing.expectEqualStrings("Not allowed", res.tagged.value);
    try std.testing.expectEqual(parser.state, .end);
    try std.testing.expectEqual(null, parser.next());
}
