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

    return ImapSession{ .socket = socket, .tls = tls, .state = .connected, .info = alloc.dupe(buffer[0 .. read - 2]) };
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
    _ = self;
    @panic("Not implemented");
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
    const CAP_UNTAGGED = "* CAPABILITY ";
    std.debug.assert(read >= CAP_UNTAGGED.len); // At least "* CAPABILITY "
    var cap_end = std.mem.indexOfScalar(u8, auth_buf[CAP_UNTAGGED.len..read], '\n') orelse return error.UnexpectedResponse;
    self.capabilities.deinit(alloc);
    self.capabilities = try parseCapabilities(alloc, auth_buf[CAP_UNTAGGED.len .. cap_end - 1]);

    cap_end += 1;

    if (std.mem.eql(u8, auth_buf[cap_end .. cap_end + 4], &tag_buf) and std.mem.eql(u8, auth_buf[cap_end + 4 .. cap_end + 8], " OK ")) {
        log.info("Authentication successful", .{});
    } else {
        log.err("Authentication failed: {s}", .{auth_buf[cap_end..read]});
        return error.AuthenticationFailed;
    }
    self.state = .authenticated;
    self.tag_id = 1;
    return;
}

pub const ListResult = struct {
    arena: std.heap.ArenaAllocator,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    flags: std.ArrayListUnmanaged(std.EnumSet(Flags)) = .empty,

    /// * LIST (\HasNoChildren) "/" "INBOX"
    // * LIST (\HasNoChildren) "/" "Notes"
    // * LIST (\HasChildren \Noselect) "/" "[Gmail]"
    // * LIST (\All \HasNoChildren) "/" "[Gmail]/All Mail"
    // * LIST (\Drafts \HasNoChildren) "/" "[Gmail]/Drafts"
    // * LIST (\HasNoChildren \Important) "/" "[Gmail]/Important"
    // * LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail"
    // * LIST (\HasNoChildren \Junk) "/" "[Gmail]/Spam"
    // * LIST (\Flagged \HasNoChildren) "/" "[Gmail]/Starred"
    // * LIST (\HasNoChildren \Trash) "/" "[Gmail]/Trash"
    // * LIST (\HasNoChildren) "/" "[Notion]"
    // S001 OK Success
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

    fn parseLine(self: *ListResult, line: []const u8) !void {
        _ = self;
        _ = line;
        return error.NotImplemented;
    }
};

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
        .buffer = list_buf,
    };
    while (read_more) {
        const read = self.tls.read(self.socket, list_buf[parser.start..]) catch |err| {
            log.err("Failed to read from IMAP server after LIST command: {}", .{err});
            return err;
        };
        while (parser.next()) |line| {
            switch (line) {
                .untagged => {
                    log.debug("Untagged response: {s} {s}", .{ line.kind, line.value });
                    if (std.mem.eql(u8, line.kind, "LIST")) {
                        try list_result.parseLine(line.value);
                    } else {
                        log.err("Unexpected untagged response: {s} {s}", .{ line.kind, line.value });
                        return error.UnexpectedResponse;
                    }
                },
            }
        }
        switch (parser.state) {
            .end => {
                read_more = false;
            },
            else => {
                std.mem.copyForwards(u8, list_buf[0..(read - parser.start)], list_buf[parser.start..read]);
                parser.start = 0;
                log.debug("Continuing to read more data from IMAP server");
            },
        }
    }
}

const ResponseParser = struct {
    tag: []const u8,
    buffer: []const u8,
    start: usize = 0,
    state: ParserState = .init,
    const ParserState = enum {
        init,
        tag,
        untagged,
        response,
        line_end,
        end,
    };

    const Response = union(enum) {
        untagged: struct {
            kind: []const u8,
            value: []const u8,
        },
        tagged: []const u8,
    };

    pub fn next(self: *ResponseParser) ?Response {
        parser: switch (self.state) {
            .init, .line_end => {
                if (self.buffer[self.start] == '*') {
                    self.state = .untagged;
                    self.start += 1;
                } else {
                    self.state = .tag;
                    continue :parser .tag;
                }
            },
            .untagged => {
                const kind_end = std.mem.indexOfScalar(u8, self.buffer[self.start..], ' ') orelse return null;
                const kind = self.buffer[self.start .. self.start + kind_end];
                self.start += kind_end + 1; // Skip the space
                const value_end = std.mem.indexOfScalar(u8, self.buffer[self.start..], '\r') orelse return null;
                const value = self.buffer[self.start .. self.start + value_end];
                self.start += value_end + 2; // Skip the \r\n
                self.state = .line_end;
                return Response{ .untagged = .{ .kind = kind, .value = value } };
            },
            .tag => {
                const tag_end = std.mem.indexOfScalar(u8, self.buffer[self.start..], ' ') orelse return null;
                const tag = self.buffer[self.start .. self.start + tag_end];
                if (!std.mem.eql(u8, tag, self.tag)) {
                    log.err("Unexpected tag in response: {s}", .{tag});
                    return null;
                }
                self.start += tag_end + 1; // Skip the space
                self.state = .response;
                continue :parser .response;
            },
            .response => {
                const response_end = std.mem.indexOfScalar(u8, self.buffer[self.start..], '\r') orelse return null;
                const response = self.buffer[self.start .. self.start + response_end];
                self.start += response_end + 2; // Skip the \r\n
                if (std.mem.eql(u8, response, "OK")) {
                    self.state = .line_end;
                    return Response{ .tagged = "OK" };
                } else if (std.mem.eql(u8, response, "NO") or std.mem.eql(u8, response, "BAD")) {
                    log.err("IMAP server responded with error: {s}", .{response});
                    return null;
                } else {
                    log.err("Unexpected response from IMAP server: {s}", .{response});
                    return null;
                }
            },
            .end => {
                return null; // No more data
            },
        }
        return null; // No more data
    }
};

test "ResponseParser - full buffer" {
    var parser = ResponseParser{
        .tag = "A001",
        .buffer = "* CAPABILITY IMAP4rev1\r\nA001 OK\r\n",
    };
    var res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqualStrings("CAPABILITY ", res.untagged.kind);
    try std.testing.expectEqualStrings("IMAP4rev1", res.untagged.value);
    try std.testing.expectEqual(parser.state, .line_end);
    res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqualStrings("A001 OK", res.tagged);
    try std.testing.expectEqual(parser.state, .line_end);
    try std.testing.expectEqual(null, parser.next());
    try std.testing.expectEqual(parser.state, .end);
}

test "ResponseParser - partial buffer" {
    var parser = ResponseParser{
        .tag = "A001",
        .buffer = "* CAPABILITY IMAP4rev1\r\nA001 OK",
    };
    const res = parser.next() orelse return error.UnexpectedResponse;
    try std.testing.expectEqualStrings("CAPABILITY ", res.untagged.kind);
    try std.testing.expectEqualStrings("IMAP4rev1", res.untagged.value);
    try std.testing.expectEqual(parser.state, .line_end);
    try std.testing.expectEqual(null, parser.next());
    try std.testing.expectEqual(parser.state, .response);
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
