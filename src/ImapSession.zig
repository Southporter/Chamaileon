const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.mailbox);

const ImapSession = @This();

socket: std.net.Stream,
tls: std.crypto.tls.Client,
state: State = .disconnected,
tag_id: u32 = 1,
capabilities: Capabilities = .empty(),
info: []const u8,

pub const State = enum {
    disconnected,
    connected,
    authenticated,
    selected,
};

pub const ConnectOptions = struct {
    host: []const u8,
    port: u16 = 0,
    ca_bundle: std.crypto.Certificate.Bundle,
};

pub fn disconnect(self: *ImapSession, alloc: std.mem.Allocator) void {
    _ = self.tls.writeEnd(self.socket, "", true) catch |err| {
        log.err("Failed to write end to IMAP server: {}", .{err});
        return;
    };
    self.socket.close();
    self.capabilities.deinit(alloc);
    alloc.free(self.info);
    self.state = .disconnected;
}

pub fn connectTls(alloc: std.mem.Allocator, options: ConnectOptions) !ImapSession {
    const socket = try std.net.tcpConnectToHost(alloc, options.host, if (options.port == 0) 993 else options.port);
    var tls = try std.crypto.tls.Client.init(socket, .{
        .host = .{ .explicit = options.host },
        .ca = .{ .bundle = options.ca_bundle },
    });
    log.info("Connecting to IMAP server at {s}:{d}", .{ options.host, options.port });

    var buffer: [256]u8 = undefined;
    const read = try tls.read(socket, &buffer);
    if (std.debug.runtime_safety) std.debug.assert(std.mem.eql(u8, buffer[read - 2 .. read], "\r\n"));
    log.info("Connected to IMAP server: {s}", .{buffer[0..read]});

    return ImapSession{ .socket = socket, .tls = tls, .state = .connected, .info = try alloc.dupe(u8, buffer[0 .. read - 2]) };
}

pub fn logout(self: *ImapSession) void {
    if (self.state == .disconnected) {
        return;
    }
    self.tls.writeAllEnd(self.socket, "A999 LOGOUT\r\n", true) catch |err| {
        log.err("Failed to write logout command to IMAP server: {}", .{err});
        return;
    };
    self.state = .disconnected;
    var buffer: [256]u8 = undefined;
    const read = self.tls.read(self.socket, &buffer) catch |err| {
        log.err("Failed to read from IMAP server after logout command: {}", .{err});
        return;
    };
    if (std.debug.runtime_safety) std.debug.assert(std.mem.eql(u8, buffer[read - 2 .. read], "\r\n"));
    log.info("Logged out from IMAP server: {s}", .{buffer[0..read]});
}

pub fn noop(self: *ImapSession) !void {
    if (self.state == .disconnected) {
        return error.InvalidState;
    }

    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;
    var noop_buf: [256]u8 = undefined;
    try self.tls.writeAll(self.socket, std.fmt.bufPrint(&noop_buf, "{s} NOOP\r\n", .{tag}) catch unreachable);

    var parser = ResponseParser{
        .tag = tag,
        .buffer = &noop_buf,
    };
    var read_more = true;
    while (read_more) {
        const read = self.tls.read(self.socket, &noop_buf) catch |err| {
            log.err("Failed to read from IMAP server after NOOP command: {}", .{err});
            return err;
        };
        parser.buffer = noop_buf[parser.offset .. read + parser.offset];

        while (parser.next()) |line| {
            switch (line) {
                .untagged => |res| {
                    log.debug("Untagged response: {s} {s}", .{ res.kind, res.value });
                    if (std.mem.eql(u8, res.kind, "OK")) {
                        log.info("NOOP command completed successfully: {s}", .{res.value});
                    } else {
                        log.err("Unexpected untagged response: {s} {s}", .{ res.kind, res.value });
                    }
                },
                .tagged => |res| {
                    log.debug("Tagged response: {s} {s}", .{ @tagName(res.kind), res.value });
                    if (res.kind == .ok) {
                        log.info("NOOP command completed successfully: {s}", .{res.value});
                        self.tag_id += 1;
                        return;
                    } else if (res.kind == .no or res.kind == .bad) {
                        log.err("NOOP command failed: {s}", .{res.value});
                        return error.NoopFailed;
                    } else {
                        log.err("Unexpected tagged response: {s} {s}", .{ @tagName(res.kind), res.value });
                        return error.UnexpectedResponse;
                    }
                },
            }
        }
        switch (parser.state) {
            .err => {
                log.err("Parser is in error state, cannot continue", .{});
                read_more = false;
            },
            .end => {
                read_more = false;
            },
            else => {
                std.mem.copyForwards(u8, noop_buf[0..(read - parser.offset)], noop_buf[parser.offset..read]);
                parser.offset = 0;
                log.debug("Continuing to read more data from IMAP server", .{});
            },
        }
    }
}

pub fn capability(self: *ImapSession, alloc: std.mem.Allocator) !Capabilities {
    if (self.state != .connected) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;
    var cap_buf: [1024]u8 = undefined;
    try self.tls.writeAll(self.socket, std.fmt.bufPrint(&cap_buf, "{s} CAPABILITY\r\n", .{tag}) catch unreachable);
    const read = try self.tls.read(self.socket, &cap_buf) catch |err| {
        log.err("Failed to read from IMAP server after capability command: {}", .{err});
        return err;
    };
    const CAP_UNTAGGED = "* CAPABILITY ";
    if (!std.mem.startsWith(u8, cap_buf[0..CAP_UNTAGGED.len], CAP_UNTAGGED)) {
        log.err("Unexpected response from IMAP server: {s}", .{cap_buf[0..read]});
        return error.UnexpectedResponse;
    }
    const cap_end = std.mem.indexOfScalar(u8, cap_buf[CAP_UNTAGGED.len..read], '\r') orelse return error.UnexpectedResponse;

    self.capabilities.deinit(alloc);
    self.capabilities = try parseCapabilities(alloc, cap_buf[CAP_UNTAGGED.len..cap_end]);

    if (!std.mem.eql(u8, cap_buf[cap_end + 2 .. cap_end + 6], &tag_buf)) {
        log.err("Unexpected response from IMAP server: {s}", .{cap_buf[cap_end + 2 .. read]});
        return error.UnexpectedResponse;
    }

    self.state = .authenticated;
    self.tag_id += 1;
    return self.capabilities;
}

pub fn login(self: *ImapSession, username: []const u8, password: []const u8) !void {
    if (username.len == 0 or password.len == 0) {
        return error.InvalidCredentials;
    }
    if (self.state != .connected) {
        return error.InvalidState;
    }
    if (self.capabilities.tags.contains(.login_disabled)) {
        return error.LoginDisabled;
    }

    const tag_buf: [4]u8 = undefined;
    std.fmt.bufPrint(&tag_buf, "A{d:0>3}", .{self.tag_id}) catch unreachable;
    const login_buf: [1024]u8 = undefined;
    try self.tls.writeAll(self.socket, std.fmt.bufPrint(&login_buf, "{s} LOGIN {s} {s}\r\n", .{ tag_buf, username, password }) catch unreachable);
}

pub fn authenticatePlain(self: *ImapSession, alloc: std.mem.Allocator, username: []const u8, password: []const u8) !void {
    if (self.state != .connected) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "A{d:0>3}", .{self.tag_id}) catch unreachable;
    var auth_buf: [1024]u8 = undefined;
    try self.tls.writeAll(self.socket, tag);
    try self.tls.writeAll(self.socket, " AUTHENTICATE PLAIN\r\n");
    var read = self.tls.read(self.socket, &auth_buf) catch |err| {
        log.err("Failed to read from IMAP server after auth command: {}", .{err});
        return err;
    };
    if (std.mem.eql(u8, auth_buf[0..read], "+\r\n")) {
        return error.UnexpectedResponse;
    }

    var stream = std.io.fixedBufferStream(&auth_buf);
    var writer = stream.writer();
    try writer.writeByte(0);
    try writer.writeAll(username);
    try writer.writeByte(0);
    try writer.writeAll(password);

    const auth_str = auth_buf[0..stream.pos];
    const encoder = std.base64.standard.Encoder;
    const encoded = encoder.encode(auth_buf[stream.pos..], auth_str);

    try self.tls.writeAll(self.socket, encoded);
    try self.tls.writeAll(self.socket, "\r\n");

    read = self.tls.read(self.socket, &auth_buf) catch |err| {
        log.err("Failed to read from IMAP server after auth string: {}", .{err});
        return err;
    };
    var parser = ResponseParser{
        .tag = tag,
        .buffer = auth_buf[0..read],
    };

    const cap = parser.next() orelse return error.UnexpectedResponse;

    self.capabilities.deinit(alloc);
    self.capabilities = try parseCapabilities(alloc, cap.untagged.value);

    const end = parser.next() orelse return error.UnexpectedResponse;
    if (end.tagged.kind != .ok) {
        log.err("Authentication failed: {s}", .{end.tagged.value});
        return error.AuthenticationFailed;
    }

    self.state = .authenticated;
    self.tag_id = 1;
    return;
}

pub const ListResult = struct {
    arena: std.heap.ArenaAllocator,
    boxes: std.MultiArrayList(Box) = .empty,

    pub const Box = struct {
        folder: []const u8,
        name: []const u8,
        flags: std.EnumSet(Flags),
    };

    pub const Flags = enum {
        no_select,
        marked,
        unmarked,
        all,
        drafts,
        junk,
        sent,
        important,
        trash,
        has_children,
        no_children,
    };

    pub fn deinit(self: *ListResult) void {
        self.arena.deinit();
    }

    fn parseFlags(flags: []const u8) !std.EnumSet(Flags) {
        var result = std.EnumSet(Flags).initEmpty();
        var iter = std.mem.tokenizeScalar(u8, flags, ' ');
        while (iter.next()) |flag| {
            var line = flag;
            if (flag[0] == '\\') {
                line = flag[1..]; // Skip the leading backslash
            }
            if (std.mem.eql(u8, line, "HasNoChildren")) {
                result.insert(.no_children);
            } else if (std.mem.eql(u8, line, "HasChildren")) {
                result.insert(.has_children);
            } else if (std.mem.eql(u8, line, "NoSelect")) {
                result.insert(.no_select);
            } else if (std.mem.eql(u8, line, "Marked")) {
                result.insert(.marked);
            } else if (std.mem.eql(u8, line, "Unmarked")) {
                result.insert(.unmarked);
            } else if (std.mem.eql(u8, line, "All")) {
                result.insert(.all);
            } else if (std.mem.eql(u8, line, "Drafts")) {
                result.insert(.drafts);
            } else if (std.mem.eql(u8, line, "Junk")) {
                result.insert(.junk);
            } else if (std.mem.eql(u8, line, "Sent")) {
                result.insert(.sent);
            } else if (std.mem.eql(u8, line, "Important")) {
                result.insert(.important);
            } else if (std.mem.eql(u8, line, "Trash")) {
                result.insert(.trash);
            } else {
                log.warn("Unknown LIST flag: {s}", .{flag});
            }
        }
        return result;
    }
    fn parseLine(self: *ListResult, line: []const u8) !void {
        const alloc = self.arena.allocator();
        const copy = try alloc.dupe(u8, line);
        errdefer alloc.free(copy);

        std.debug.assert(copy[0] == '(');
        const flags_end = std.mem.indexOfScalar(u8, copy, ')') orelse return error.UnexpectedResponse;
        const flags = parseFlags(copy[1..flags_end]) catch |err| {
            log.err("Failed to parse flags from LIST response: {s}", .{line});
            return err;
        };
        if (flags_end + 2 >= copy.len or copy[flags_end + 1] != ' ') {
            log.err("Unexpected LIST response format: {s}", .{line});
            return error.UnexpectedResponse;
        }
        var folder_start = flags_end + 2;
        if (folder_start >= copy.len or copy[folder_start] != '"') {
            log.err("Unexpected LIST response format: {s}", .{line});
            return error.UnexpectedResponse;
        }
        folder_start += 1; // Skip the opening quote
        const folder_end = std.mem.indexOfScalarPos(u8, copy, folder_start, '"') orelse return error.UnexpectedResponse;
        if (folder_end + 1 >= copy.len or copy[folder_end + 1] != ' ') {
            log.err("Unexpected LIST response format: {s}", .{line});
            return error.UnexpectedResponse;
        }
        const folder = copy[folder_start..folder_end];

        const name_start = folder_end + 2; // Skip the closing quote and space
        if (name_start >= copy.len or copy[name_start] != '"') {
            log.err("Unexpected LIST response format: {s}", .{line});
            return error.UnexpectedResponse;
        }
        const name_end = std.mem.indexOfScalarPos(u8, copy, name_start + 1, '"') orelse return error.UnexpectedResponse;
        const name = copy[name_start + 1 .. name_end];

        return self.boxes.append(alloc, .{
            .folder = folder,
            .name = name,
            .flags = flags,
        });
    }
};
test "ListResult" {
    const alloc = std.testing.allocator;
    var result = ListResult{
        .arena = std.heap.ArenaAllocator.init(alloc),
    };
    defer result.deinit();
    try result.parseLine("(\\HasNoChildren) \"/\" \"INBOX\"");
    try std.testing.expectEqual(result.boxes.len, 1);
    {
        const box = result.boxes.get(0);
        try std.testing.expectEqualStrings("INBOX", box.name);
        try std.testing.expectEqualStrings("/", box.folder);
        try std.testing.expect(box.flags.contains(.no_children));
        try std.testing.expect(!box.flags.contains(.has_children));
    }

    try result.parseLine("(\\HasNoChildren \\Junk) \"/\" \"[Gmail]/Spam\"");
    try std.testing.expectEqual(result.boxes.len, 2);
    {
        const box = result.boxes.get(1);
        try std.testing.expectEqualStrings("[Gmail]/Spam", box.name);
        try std.testing.expectEqualStrings("/", box.folder);
        try std.testing.expect(box.flags.contains(.no_children));
        try std.testing.expect(box.flags.contains(.junk));
    }
}

pub fn list(self: *ImapSession, alloc: std.mem.Allocator, root: []const u8, pattern: []const u8) !ListResult {
    if (self.state != .authenticated) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;

    var list_buf: [1024]u8 = undefined;
    try self.tls.writeAll(self.socket, std.fmt.bufPrint(&list_buf, "{s} LIST {s} {s}\r\n", .{ tag, root, pattern }) catch unreachable);

    var read_more = true;
    var list_result = ListResult{
        .arena = std.heap.ArenaAllocator.init(alloc),
    };

    var parser = ResponseParser{
        .tag = tag,
        .buffer = &list_buf,
    };
    while (read_more) {
        const read = self.tls.read(self.socket, list_buf[parser.offset..]) catch |err| {
            log.err("Failed to read from IMAP server after LIST command: {}", .{err});
            return err;
        };
        parser.buffer = list_buf[parser.offset .. read + parser.offset];

        while (parser.next()) |line| {
            switch (line) {
                .untagged => |res| {
                    log.debug("Untagged response: {s} {s}", .{ res.kind, res.value });
                    if (std.mem.eql(u8, res.kind, "LIST")) {
                        try list_result.parseLine(res.value);
                    } else {
                        log.err("Unexpected untagged response: {s} {s}", .{ res.kind, res.value });
                        return error.UnexpectedResponse;
                    }
                },
                .tagged => |res| {
                    log.debug("Tagged response: {s} {s}", .{ @tagName(res.kind), res.value });
                    if (res.kind == .ok) {
                        log.info("LIST command completed successfully: {s}", .{res.value});
                        self.tag_id += 1;
                        self.state = .selected;
                        list_result.boxes.shrinkAndFree(list_result.arena.allocator(), list_result.boxes.len);
                        return list_result;
                    } else if (res.kind == .no or res.kind == .bad) {
                        log.err("LIST command failed: {s}", .{res.value});
                        return error.ListFailed;
                    } else {
                        log.err("Unexpected tagged response: {s} {s}", .{ @tagName(res.kind), res.value });
                        return error.UnexpectedResponse;
                    }
                },
            }
        }
        switch (parser.state) {
            .err => {
                log.err("Parser is in error state, cannot continue", .{});
                read_more = false;
            },
            .end => {
                read_more = false;
            },
            else => {
                std.mem.copyForwards(u8, list_buf[0..(read - parser.offset)], list_buf[parser.offset..read]);
                parser.offset = 0;
                log.debug("Continuing to read more data from IMAP server", .{});
            },
        }
    }
    return error.UnexpectedResponse; // If we reach here, something went wrong
}

const ResponseParser = struct {
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
                var start = self.offset;
                if (start + 2 >= self.buffer.len) {
                    return null; // Not enough data for "BAD "
                }
                if (self.buffer[start + 1] == 'A' and self.buffer[start + 2] == 'D') {
                    start += 2; // Skip "BAD"
                    self.offset = start;
                    self.state = .response_bad;
                    continue :parser .response_bad;
                } else {
                    log.err("Unexpected response from IMAP server: ({s})", .{self.buffer[start..]});
                    self.state = .err;
                    return null;
                }
            },

            .response_bad => {
                var start = self.offset;
                if (self.buffer[start] == ' ') {
                    start += 1; // Skip the space after "OK"
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
};

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

pub const Capability = enum(u16) {
    login = 16,
    login_disabled,
    auth_plain,
    auth_login,
    auth_xoauth2,
    _,
};

pub const Capabilities = struct {
    tags: std.EnumSet(Capability),
    interned: std.ArrayListUnmanaged(u8),
    extra: [16]usize,

    pub fn empty() Capabilities {
        return Capabilities{
            .tags = .initEmpty(),
            .interned = .empty,
            .extra = [_]usize{0} ** 16,
        };
    }

    pub fn deinit(self: *Capabilities, alloc: std.mem.Allocator) void {
        self.interned.deinit(alloc);
    }
};

fn parseCapabilities(alloc: std.mem.Allocator, cap_str: []const u8) !Capabilities {
    var iter = std.mem.tokenizeScalar(u8, cap_str, ' ');
    var capabilities = Capabilities.empty();
    while (iter.next()) |name| {
        if (std.mem.eql(u8, name, "AUTH=PLAIN")) {
            capabilities.tags.insert(.auth_plain);
        } else if (std.mem.eql(u8, name, "AUTH=LOGIN")) {
            capabilities.tags.insert(.auth_login);
        } else if (std.mem.eql(u8, name, "AUTH=XOAUTH2")) {
            capabilities.tags.insert(.auth_xoauth2);
        } else if (std.mem.eql(u8, name, "LOGIN")) {
            capabilities.tags.insert(.login);
        } else if (std.mem.eql(u8, name, "LOGINDISABLED")) {
            capabilities.tags.insert(.login_disabled);
        } else {
            var i: u32 = 0;
            while (capabilities.tags.contains(@enumFromInt(i))) : (i += 1) {}
            if (i >= capabilities.extra.len) {
                return error.ExtraCapabilitiesFull;
            }
            const start = capabilities.interned.items.len;
            try capabilities.interned.appendSlice(alloc, name);
            try capabilities.interned.append(alloc, 0); // Null-terminate
            capabilities.extra[i] = start;
        }
    }
    return capabilities;
}

test "capabilities" {
    const alloc = std.testing.allocator;

    const cap_str = "AUTH=PLAIN AUTH=LOGIN LOGIN IDLE UNSELECT";

    var capabilities = try parseCapabilities(alloc, cap_str);
    defer capabilities.deinit(alloc);

    try std.testing.expect(capabilities.tags.contains(.auth_plain));
    try std.testing.expect(capabilities.tags.contains(.auth_login));
    try std.testing.expect(capabilities.tags.contains(.login));
    try std.testing.expect(!capabilities.tags.contains(.login_disabled));
    try std.testing.expectEqualStrings("IDLE\x00UNSELECT\x00", capabilities.interned.items);
}
