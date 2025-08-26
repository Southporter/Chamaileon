const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.mailbox);
const zeit = @import("zeit");

const Session = @This();
const Capabilities = @import("Capability.zig");
const ResponseParser = @import("ResponseParser.zig");
const Tokenizer = @import("tokenize.zig").Tokenizer;
const Parser = @import("Parser.zig");

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

pub fn connect(alloc: std.mem.Allocator, options: ConnectOptions) !Session {
    const socket = try std.net.tcpConnectToHost(alloc, options.host, if (options.port == 0) 143 else options.port);
    log.info("Connecting to IMAP server at {s}:{d}", .{ options.host, options.port });

    var buffer: [256]u8 = undefined;
    const read = try socket.read(&buffer);
    if (std.debug.runtime_safety) std.debug.assert(std.mem.eql(u8, buffer[read - 2 .. read], "\r\n"));
    log.info("Connected to IMAP server: {s}", .{buffer[0..read]});

    return Session{ .socket = socket, .tls = undefined, .state = .connected, .info = try alloc.dupe(u8, buffer[0 .. read - 2]) };
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
    const read = self.tls.read(self.socket, &cap_buf) catch |err| {
        log.err("Failed to read from IMAP server after capability command: {}", .{err});
        return err;
    };
    log.info("Received CAPABILITY response: {s}", .{cap_buf[0..read]});

    cap_buf[read] = 0;

    var parser = Parser.init(cap_buf[0..read :0]);

    // TODO: Handle case of bad or no
    try parser.expect(.asterisk);
    try parser.expect(.keyword_capability);

    self.capabilities.deinit(alloc);

    try self.capabilities.parse(alloc, &parser);

    try parser.expectIdentifier(tag);
    try parser.expect(.keyword_ok);

    self.tag_id += 1;
    return self.capabilities;
}

pub fn startTls(self: *Session, config: ConnectOptions) !void {
    if (self.state != .connected) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;
    var starttls_buf: [256]u8 = undefined;
    try self.socket.writeAll(std.fmt.bufPrint(&starttls_buf, "{s} STARTTLS\r\n", .{tag}) catch unreachable);
    log.info("StartTLS with server at {s}:{d}", .{ config.host, config.port });
    const read = self.socket.read(&starttls_buf) catch |err| {
        log.err("Failed to read from IMAP server after STARTTLS command: {}", .{err});
        return err;
    };
    if (!std.mem.startsWith(u8, starttls_buf[0..read], tag)) {
        log.err("Unexpected response from IMAP server: {s}", .{starttls_buf[0..read]});
        return error.UnexpectedResponse;
    }
    var parser = ResponseParser{
        .tag = tag,
        .buffer = starttls_buf[0..read],
    };
    const cap = parser.next() orelse return error.UnexpectedResponse;
    if (cap.tagged.kind != .ok) {
        log.err("STARTTLS command failed: {s}", .{cap.tagged.value});
        return error.StartTlsFailed;
    }

    self.tls = try std.crypto.tls.Client.init(self.socket, .{
        // TODO: Add support for explicit host verification
        .host = .{ .no_verification = {} },
        .ca = .{ .self_signed = {} },
        // .ca = .{ .bundle = config.ca_bundle },
    });

    self.state = .connected;
    self.tag_id = 1;
    return;
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
    {
        auth_buf[read] = 0;
        var auth_parse = Parser.init(auth_buf[0..read :0]);
        // TODO: Handle case of bad or no
        try auth_parse.expect(.plus);
        try auth_parse.expect(.crlf);
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

    auth_buf[read] = 0;
    var parser = Parser.init(auth_buf[0..read :0]);

    if (parser.peek()) |tok| {
        switch (tok.tag) {
            .asterisk => {
                parser.expect(.asterisk) catch unreachable;
                try parser.expect(.keyword_capability);
                self.capabilities.deinit(alloc);
                self.capabilities.parse(alloc, &parser) catch |err| {
                    log.err("Failed to parse capabilities from AUTHENTICATE response: {s}", .{auth_buf[0..read]});
                    return err;
                };
            },
            .keyword_bad, .keyword_no => {
                log.err("AUTHENTICATE command failed: {s}", .{auth_buf[0..read]});
                return error.AuthenticateFailed;
            },
            .identifier => {
                // This is likely the tagged response
            },
            else => {
                log.err("Unexpected response from IMAP server: {s}", .{auth_buf[0..read]});
                return error.UnexpectedResponse;
            },
        }
    }
    try parser.expectIdentifier(tag);
    try parser.expect(.keyword_ok);

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

pub const MailboxDetails = struct {
    exists: u32 = 0,
    recent: u32 = 0,
    slash_flags: std.EnumSet(Flags) = .initEmpty(),
    dollar_flags: std.EnumSet(Flags) = .initEmpty(),
    bare_flags: std.EnumSet(Flags) = .initEmpty(),
    permanent_flags: std.EnumSet(Flags) = .initEmpty(),
    unseen: u32 = 0,
    uid_next: u32 = 0,
    uid_validity: u32 = 0,
    highest_mod_seq: u64 = 0,
    status: enum { read_write, read_only } = .read_only,

    pub const Flags = enum {
        answered,
        flagged,
        draft,
        deleted,
        seen,
        not_junk,
        not_phishing,
        phishing,
        forwarded,
        junk,
        junk_recorded,
        custom_flags,

        fn parse(value: []const u8) ?Flag {
            if (std.mem.eql(u8, stripped, "Answered")) {
                return .answered;
            } else if (std.mem.eql(u8, stripped, "Flagged")) {
                return .flagged;
            } else if (std.mem.eql(u8, stripped, "Draft")) {
                return .draft;
            } else if (std.mem.eql(u8, stripped, "Deleted")) {
                return .deleted;
            } else if (std.mem.eql(u8, stripped, "Seen")) {
                return .seen;
            } else if (std.mem.eql(u8, stripped, "NotJunk")) {
                return .not_junk;
            } else if (std.mem.eql(u8, stripped, "NotPhishing")) {
                return .not_phishing;
            } else if (std.mem.eql(u8, stripped, "Phishing")) {
                return .phishing;
            } else if (std.mem.eql(u8, stripped, "Forwarded")) {
                return .forwarded;
            } else if (std.mem.eql(u8, stripped, "Junk")) {
                return .junk;
            } else if (std.mem.eql(u8, stripped, "JunkRecorded")) {
                return .junk_recorded;
            }
            log.warn("Unknown mailbox flag: {s}", .{flag});
            return null;
        }
    };

    pub fn format(value: *const MailboxDetails, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("MailboxDetails: ({d} total, {d} recent, {d} unseen, {d} next uid }}", .{
            value.exists,
            value.recent,
            value.unseen,
            value.uid_next,
        });
    }

    fn parseFlags(self: *MailboxDetails, flags: []const u8) !void {
        var iter = std.mem.tokenizeScalar(u8, flags, ' ');
        while (iter.next()) |flag| {
            var stripped = flag;

            var result = switch (flag[0]) {
                '\\' => &self.slash_flags,
                '$' => &self.dollar_flags,
                else => &self.bare_flags,
            };
            if (flag[0] == '\\' or flag[0] == '$') {
                stripped = flag[1..]; // Skip the leading backslash
            }
            if (std.mem.eql(u8, stripped, "*")) {
                result.insert(.custom_flags);
                continue;
            }
            if (std.mem.eql(u8, stripped, "Answered")) {
                result.insert(.answered);
            } else if (std.mem.eql(u8, stripped, "Flagged")) {
                result.insert(.flagged);
            } else if (std.mem.eql(u8, stripped, "Draft")) {
                result.insert(.draft);
            } else if (std.mem.eql(u8, stripped, "Deleted")) {
                result.insert(.deleted);
            } else if (std.mem.eql(u8, stripped, "Seen")) {
                result.insert(.seen);
            } else if (std.mem.eql(u8, stripped, "NotJunk")) {
                result.insert(.not_junk);
            } else if (std.mem.eql(u8, stripped, "NotPhishing")) {
                result.insert(.not_phishing);
            } else if (std.mem.eql(u8, stripped, "Phishing")) {
                result.insert(.phishing);
            } else if (std.mem.eql(u8, stripped, "Forwarded")) {
                result.insert(.forwarded);
            } else if (std.mem.eql(u8, stripped, "Junk")) {
                result.insert(.junk);
            } else if (std.mem.eql(u8, stripped, "JunkRecorded")) {
                result.insert(.junk_recorded);
            } else {
                log.warn("Unknown mailbox flag: {s}", .{flag});
            }
        }
    }
    fn parsePermanentFlags(self: *MailboxDetails, flags: []const u8) !void {
        var result = self.permanent_flags;
        var iter = std.mem.tokenizeScalar(u8, flags, ' ');
        while (iter.next()) |flag| {
            var stripped = flag;

            if (flag[0] == '\\' or flag[0] == '$') {
                stripped = flag[1..]; // Skip the leading backslash
            }
            if (std.mem.eql(u8, stripped, "*")) {
                result.insert(.custom_flags);
                continue;
            }
            if (std.mem.eql(u8, stripped, "Answered")) {
                result.insert(.answered);
            } else if (std.mem.eql(u8, stripped, "Flagged")) {
                result.insert(.flagged);
            } else if (std.mem.eql(u8, stripped, "Draft")) {
                result.insert(.draft);
            } else if (std.mem.eql(u8, stripped, "Deleted")) {
                result.insert(.deleted);
            } else if (std.mem.eql(u8, stripped, "Seen")) {
                result.insert(.seen);
            } else if (std.mem.eql(u8, stripped, "NotJunk")) {
                result.insert(.not_junk);
            } else if (std.mem.eql(u8, stripped, "NotPhishing")) {
                result.insert(.not_phishing);
            } else if (std.mem.eql(u8, stripped, "Phishing")) {
                result.insert(.phishing);
            } else if (std.mem.eql(u8, stripped, "Forwarded")) {
                result.insert(.forwarded);
            } else if (std.mem.eql(u8, stripped, "Junk")) {
                result.insert(.junk);
            } else if (std.mem.eql(u8, stripped, "JunkRecorded")) {
                result.insert(.junk_recorded);
            } else {
                log.warn("Unknown mailbox flag: {s}", .{flag});
            }
        }
    }
};

pub fn select(self: *Session, mailbox: Box) !MailboxDetails {
    log.debug("Selecting in state: {s}", .{@tagName(self.state)});
    if (self.state != .selected and self.state != .authenticated) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;
    var select_buf: [1024]u8 = undefined;
    try self.tls.writeAll(self.socket, std.fmt.bufPrint(&select_buf, "{s} SELECT {s}\r\n", .{ tag, mailbox.name }) catch unreachable);

    var read_more = true;
    var parser = ResponseParser{
        .tag = tag,
        .buffer = &select_buf,
    };
    var mailbox_details = MailboxDetails{};
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
                        std.debug.assert(res.value[0] == '(' and res.value[res.value.len - 1] == ')');
                        mailbox_details.parseFlags(res.value[1 .. res.value.len - 1]) catch |err| {
                            log.err("Failed to parse flags from SELECT response: {s}", .{res.value});
                            return err;
                        };
                    } else if (std.mem.eql(u8, res.kind, "OK")) {
                        log.info("Mailbox {s} OK: {s}", .{ mailbox.name, res.value });
                        const PERMANENTFLAGS = "[PERMANENTFLAGS (";
                        const UIDNEXT = "[UIDNEXT ";
                        const UIDVALIDITY = "[UIDVALIDITY ";
                        const HIGHESTMODSEQ = "[HIGHESTMODSEQ ";
                        if (std.mem.startsWith(u8, res.value, PERMANENTFLAGS)) {
                            const flags_start = res.value[PERMANENTFLAGS.len..];
                            const flags_end = std.mem.indexOfScalar(u8, flags_start, ')') orelse return error.UnexpectedResponse;
                            mailbox_details.parsePermanentFlags(flags_start[0..flags_end]) catch |err| {
                                log.err("Failed to parse permanent flags from SELECT response: {s}", .{res.value});
                                return err;
                            };
                        } else if (std.mem.startsWith(u8, res.value, UIDNEXT)) {
                            const value_start = UIDNEXT.len;
                            const value_end = std.mem.indexOfScalarPos(u8, res.value, value_start, ']') orelse return error.UnexpectedResponse;
                            mailbox_details.uid_next = std.fmt.parseInt(u32, res.value[value_start..value_end], 10) catch {
                                log.err("Failed to parse UIDNEXT from SELECT response: {s}", .{res.value});
                                return error.UnexpectedResponse;
                            };
                        } else if (std.mem.startsWith(u8, res.value, UIDVALIDITY)) {
                            const value_start = UIDVALIDITY.len;
                            const value_end = std.mem.indexOfScalarPos(u8, res.value, value_start, ']') orelse return error.UnexpectedResponse;
                            mailbox_details.uid_validity = std.fmt.parseInt(u32, res.value[value_start..value_end], 10) catch {
                                log.err("Failed to parse UIDNEXT from SELECT response: {s}", .{res.value});
                                return error.UnexpectedResponse;
                            };
                        } else if (std.mem.startsWith(u8, res.value, HIGHESTMODSEQ)) {
                            const value_start = HIGHESTMODSEQ.len;
                            const value_end = std.mem.indexOfScalarPos(u8, res.value, value_start, ']') orelse return error.UnexpectedResponse;
                            mailbox_details.highest_mod_seq = std.fmt.parseInt(u64, res.value[value_start..value_end], 10) catch {
                                log.err("Failed to parse UIDNEXT from SELECT response: {s}", .{res.value});
                                return error.UnexpectedResponse;
                            };
                        }
                    } else if (res.kind[0] >= '0' and res.kind[0] <= '9') {
                        const num = std.fmt.parseInt(u32, res.kind, 10) catch {
                            log.err("Failed to parse numeric untagged response: {s} {s}", .{ res.kind, res.value });
                            return error.UnexpectedResponse;
                        };
                        if (std.mem.eql(u8, res.value, "EXISTS")) {
                            mailbox_details.exists = num;
                        } else if (std.mem.eql(u8, res.value, "RECENT")) {
                            mailbox_details.recent = num;
                        }
                    } else {
                        log.err("Unexpected untagged response: {s} {s}", .{ res.kind, res.value });
                        return error.UnexpectedResponse;
                    }
                },
                .tagged => |res| {
                    log.debug("Tagged response: {s} {s}", .{ @tagName(res.kind), res.value });
                    if (res.kind == .ok) {
                        log.info("SELECT command completed successfully for mailbox {s}: {s}", .{ mailbox.name, res.value });
                        if (std.mem.startsWith(u8, res.value, "[READ-WRITE]")) {
                            mailbox_details.status = .read_write;
                        } else if (std.mem.startsWith(u8, res.value, "[READ-ONLY]")) {
                            mailbox_details.status = .read_only;
                        } else {
                            log.warn("Unexpected mailbox status in SELECT response: {s}", .{res.value});
                        }
                        self.tag_id += 1;
                        self.state = .selected;
                        return mailbox_details;
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
    return error.UnexpectedResponse; // If we reach here, something went wrong
}

pub const Range = struct {
    min: u32 = 0,
    max: u32 = 0,
};

pub const PreviewResult = struct {
    mail: std.ArrayListUnmanaged(Preview) = .empty,

    pub const Preview = struct {
        uid: u32 = 0,
        flags: std.EnumSet(MailboxDetails.Flags) = .initEmpty(),
        from: []const u8 = "",
        subject: []const u8 = "",
        date: zeit.Instant,

        pub fn deinit(self: *Preview, alloc: std.mem.Allocator) void {
            self.headers.deinit(alloc);
            alloc.free(self.body);
            self.flags = .initEmpty();
        }
    };

    pub fn deinit(self: *PreviewResult, alloc: std.mem.Allocator) void {
        for (self.mail.items) |mail| {
            mail.deinit(alloc);
        }
        self.mail.deinit(alloc);
    }

    pub fn format(
        self: PreviewResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("PeekResult: {d} items 0_0", .{
            self.mail.items.len,
        });
    }
};

const PreviewReadState = enum {
    read_buf,
    tagged_or_untagged,
    tagged,
    id,
    fetch,
    flags,
    flag,
    body,
};

pub fn preview(self: *Session, alloc: std.mem.Allocator, range: Range) !PreviewResult {
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;

    var fetch_buf: [1024]u8 = undefined;
    try self.tls.writeAll(self.socket, std.fmt.bufPrint(&fetch_buf, "{s} FETCH {d}:{d} (FLAGS BODY.PEEK[HEADER.FIELDS (Subject From Date)])\r\n", .{ tag, range.min, range.max }) catch unreachable);

    var parser: Parser = undefined;
    var state_after_read: PreviewReadState = .tagged_or_untagged;
    var preview: PreviewResult.Preview = .{
    };
    var result = PreviewResult{};
    parse: switch (PreviewReadState.read_buf) {
        .read_buf => {
            const read = self.tls.read(self.socket, &fetch_buf) catch |err| {
                log.err("Failed to read from IMAP server after FETCH command: {}", .{err});
                return err;
            };
            fetch_buf[read] = 0;
            parser = Parser.init(fetch_buf[0..read :0]);
            continue :parse state_after_read;
        },
        .tagged_or_untagged => {
            if (parser.peekExpect(.asterisk)) {
                parser.expect(.asterisk) catch unreachable;
                continue :parse .id;
            } else {
                continue :parse .tagged;
            }
        },
        .tagged => {
            try parser.expectIdentifier(tag);
            try parser.expect(.keyword_ok);
            self.tag_id += 1;
            return result;
        },
        .id => {
            preview.uid = parser.get(.number) catch |err| {
                switch (err) {
                    error.UnexpectedResponse => {
                        log.err("Failed to parse UID from FETCH response: {s}", .{fetch_buf[0..parser.offset]});
                        return err;
                    },
                    error.EndOfStream => {
                        state_after_read = .id;
                        continue :parse read_buf;
                    },
                    else => return err,
                }
            },
            continue :parse .fetch;
        },
        .fetch => {
            try parser.expect(.keyword_fetch);
            continue :parse .flags;
        },
        .flags => {
            try parser.expect(.lparen);
            try parser.expect(.keyword_flags);
            try parser.expect(.lparen);
            continue :parse .flag;
        },
        .flag => {
            const next = parser.next() orelse {
                state_after_read = .flag;
                continue :parse read_buf;
            };
            if (next.tag == .rparen) {
                continue :parse .body;
            }
            if (MailboxDetails.Flags.parse(parser.value(next))) |flag| {
                preview.flags.insert(flag);
            }
            continue :parse .flag;
        },
        .body => {
            try parser.expect(.keyword_body);
            try parser.expect(.dot);
            try parser.expect(.lbrack);
continue :parse .header_fields;
        },
        .header_fields => {
            try parser.expect(.keyword_header);
            try parser.expect(.period);
            try parser.expect(.keyword_fields);
            try parser.expect(.lparen);
            try parser.expect(.keyword_subject);
            try parser.expect(.keyword_from);
            try parser.expectIdentifier("Date");
            try parser.expect(.rparen);
            try parser.expect(.rbrack);
        },
        .message_length => {
            try parser.expect(.lbrace);
            const msg_len = try parser.get(.number);
            try parser.expect(.rbrace);
            try parser.expect(.crlf);
            if (!parser.hasEnoughBuffer(msg_len)) {
                state_after_read = .message_body;
                continue :parse read_buf;
            }
            continue :parse .message_body;
        },
        .message_body => {
            
        }
    }
}
