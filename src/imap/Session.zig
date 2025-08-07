const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.mailbox);

const Session = @This();
const Capabilities = @import("Capability.zig");
const ResponseParser = @import("ResponseParser.zig");

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

pub fn disconnect(self: *Session, alloc: std.mem.Allocator) void {
    _ = self.tls.writeEnd(self.socket, "", true) catch |err| {
        log.err("Failed to write end to IMAP server: {}", .{err});
        return;
    };
    self.socket.close();
    self.capabilities.deinit(alloc);
    alloc.free(self.info);
    self.state = .disconnected;
}

pub fn connectTls(alloc: std.mem.Allocator, options: ConnectOptions) !Session {
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

    return Session{ .socket = socket, .tls = tls, .state = .connected, .info = try alloc.dupe(u8, buffer[0 .. read - 2]) };
}

pub fn logout(self: *Session) void {
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

pub fn noop(self: *Session) !void {
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

pub fn capability(self: *Session, alloc: std.mem.Allocator) !Capabilities {
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
    self.capabilities = try Capabilities.parseCapabilities(alloc, cap_buf[CAP_UNTAGGED.len..cap_end]);

    if (!std.mem.eql(u8, cap_buf[cap_end + 2 .. cap_end + 6], &tag_buf)) {
        log.err("Unexpected response from IMAP server: {s}", .{cap_buf[cap_end + 2 .. read]});
        return error.UnexpectedResponse;
    }

    self.state = .authenticated;
    self.tag_id += 1;
    return self.capabilities;
}

pub fn login(self: *Session, username: []const u8, password: []const u8) !void {
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

pub fn authenticatePlain(self: *Session, alloc: std.mem.Allocator, username: []const u8, password: []const u8) !void {
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
    self.capabilities = try Capabilities.parseCapabilities(alloc, cap.untagged.value);

    const end = parser.next() orelse return error.UnexpectedResponse;
    if (end.tagged.kind != .ok) {
        log.err("Authentication failed: {s}", .{end.tagged.value});
        return error.AuthenticationFailed;
    }

    self.state = .authenticated;
    self.tag_id = 1;
    return;
}

pub const Box = struct {
    folder: []const u8,
    name: []const u8,
    flags: std.EnumSet(Flags),
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
};
pub const ListResult = struct {
    boxes: std.MultiArrayList(Box) = .empty,

    pub fn deinit(self: *ListResult, alloc: std.mem.Allocator) void {
        for (self.boxes.items(.name)) |name| {
            alloc.free(name);
        }
        for (self.boxes.items(.folder)) |name| {
            alloc.free(name);
        }
        self.boxes.deinit(alloc);
    }

    fn parseFlags(flags: []const u8) !std.EnumSet(Box.Flags) {
        var result = std.EnumSet(Box.Flags).initEmpty();
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
    fn parseLine(self: *ListResult, alloc: std.mem.Allocator, line: []const u8) !void {
        std.debug.assert(line[0] == '(');
        const flags_end = std.mem.indexOfScalar(u8, line, ')') orelse return error.UnexpectedResponse;
        const flags = parseFlags(line[1..flags_end]) catch |err| {
            log.err("Failed to parse flags from LIST response: {s}", .{line});
            return err;
        };
        if (flags_end + 2 >= line.len or line[flags_end + 1] != ' ') {
            log.err("Unexpected LIST response format: {s}", .{line});
            return error.UnexpectedResponse;
        }
        var folder_start = flags_end + 2;
        if (folder_start >= line.len or line[folder_start] != '"') {
            log.err("Unexpected LIST response format: {s}", .{line});
            return error.UnexpectedResponse;
        }
        folder_start += 1; // Skip the opening quote
        const folder_end = std.mem.indexOfScalarPos(u8, line, folder_start, '"') orelse return error.UnexpectedResponse;
        if (folder_end + 1 >= line.len or line[folder_end + 1] != ' ') {
            log.err("Unexpected LIST response format: {s}", .{line});
            return error.UnexpectedResponse;
        }
        const folder = try alloc.dupe(u8, line[folder_start..folder_end]);
        errdefer alloc.free(folder);

        const name_start = folder_end + 2; // Skip the closing quote and space
        if (name_start >= line.len or line[name_start] != '"') {
            log.err("Unexpected LIST response format: {s}", .{line});
            return error.UnexpectedResponse;
        }
        const name_end = std.mem.indexOfScalarPos(u8, line, name_start + 1, '"') orelse return error.UnexpectedResponse;
        const name = try alloc.dupe(u8, line[name_start + 1 .. name_end]);
        errdefer alloc.free(name);

        return self.boxes.append(alloc, .{
            .folder = folder,
            .name = name,
            .flags = flags,
        });
    }
};
test "ListResult" {
    const alloc = std.testing.allocator;
    var result = ListResult{};
    defer result.deinit(alloc);
    try result.parseLine(alloc, "(\\HasNoChildren) \"/\" \"INBOX\"");
    try std.testing.expectEqual(result.boxes.len, 1);
    {
        const box = result.boxes.get(0);
        try std.testing.expectEqualStrings("INBOX", box.name);
        try std.testing.expectEqualStrings("/", box.folder);
        try std.testing.expect(box.flags.contains(.no_children));
        try std.testing.expect(!box.flags.contains(.has_children));
    }

    try result.parseLine(alloc, "(\\HasNoChildren \\Junk) \"/\" \"[Gmail]/Spam\"");
    try std.testing.expectEqual(result.boxes.len, 2);
    {
        const box = result.boxes.get(1);
        try std.testing.expectEqualStrings("[Gmail]/Spam", box.name);
        try std.testing.expectEqualStrings("/", box.folder);
        try std.testing.expect(box.flags.contains(.no_children));
        try std.testing.expect(box.flags.contains(.junk));
    }
}

pub fn list(self: *Session, alloc: std.mem.Allocator, root: []const u8, pattern: []const u8) !ListResult {
    if (self.state != .authenticated) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;

    var list_buf: [1024]u8 = undefined;
    const list_command = std.fmt.bufPrint(&list_buf, "{s} LIST \"{s}\" \"{s}\"\r\n", .{ tag, root, pattern }) catch unreachable;
    log.debug("Sending LIST command: {s}", .{list_command});
    try self.tls.writeAll(self.socket, list_command);

    var read_more = true;
    var list_result = ListResult{};
    errdefer list_result.deinit(alloc);

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
                        try list_result.parseLine(alloc, res.value);
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
                        list_result.boxes.shrinkAndFree(alloc, list_result.boxes.len);
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

pub fn select(self: *Session, mailbox: Box) !void {
    if (self.state != .authenticated) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;
    var select_buf: [1024]u8 = undefined;
    try self.tls.writeAll(self.socket, std.fmt.bufPrint(&select_buf, "{s} SELECT {s} {s}\r\n", .{ tag, mailbox.folder, mailbox.name }) catch unreachable);

    var read_more = true;
    var parser = ResponseParser{
        .tag = tag,
        .buffer = &select_buf,
    };
    while (read_more) {
        const read = self.tls.read(self.socket, select_buf[parser.offset..]) catch |err| {
            log.err("Failed to read from IMAP server after SELECT command: {}", .{err});
            return err;
        };
        parser.buffer = select_buf[parser.offset .. read + parser.offset];

        while (parser.next()) |line| {
            switch (line) {
                .untagged => |res| {
                    log.debug("Untagged response: {s} {s}", .{ res.kind, res.value });
                    if (std.mem.eql(u8, res.kind, "EXISTS") or std.mem.eql(u8, res.kind, "RECENT")) {
                        log.info("Mailbox {s} has {s}", .{ mailbox.name, res.value });
                    } else if (std.mem.eql(u8, res.kind, "FLAGS")) {
                        log.info("Mailbox {s} flags: {s}", .{ mailbox.name, res.value });
                    } else {
                        log.err("Unexpected untagged response: {s} {s}", .{ res.kind, res.value });
                        return error.UnexpectedResponse;
                    }
                },
                .tagged => |res| {
                    log.debug("Tagged response: {s} {s}", .{ @tagName(res.kind), res.value });
                    if (res.kind == .ok) {
                        log.info("SELECT command completed successfully for mailbox {s}: {s}", .{ mailbox.name, res.value });
                        self.tag_id += 1;
                        self.state = .selected;
                        return;
                    } else if (res.kind == .no or res.kind == .bad) {
                        log.err("SELECT command failed for mailbox {s}: {s}", .{ mailbox.name, res.value });
                        return error.SelectFailed;
                    } else {
                        log.err("Unexpected tagged response: {s} {s}", .{ @tagName(res.kind), res.value });
                        return error.UnexpectedResponse;
                    }
                },
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
                    std.mem.copyForwards(u8, select_buf[0..(read - parser.offset)], select_buf[parser.offset..read]);
                    parser.offset = 0;
                    log.debug("Continuing to read more data from IMAP server", .{});
                },
            }
        }
    }
}
