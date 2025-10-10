const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.mailbox);
const zeit = @import("zeit");

const Session = @This();
const Capabilities = @import("Capability.zig");
const ResponseParser = @import("ResponseParser.zig");
const Parser = @import("Parser.zig");

const min_buffer_len = std.crypto.tls.Client.min_buffer_len;

socket: struct {
    stream: std.net.Stream,
    reader: std.net.Stream.Reader = undefined,
    writer: std.net.Stream.Writer = undefined,
    read_buf: [min_buffer_len]u8 = undefined,
    write_buf: [min_buffer_len]u8 = undefined,
},
tls: ?std.crypto.tls.Client = null,
tls_read_buf: [4096]u8 = undefined,
tls_write_buf: [1024]u8 = undefined,
state: State = .disconnected,
tag_id: u32 = 1,
capabilities: Capabilities = .empty(),
info: []const u8 = undefined,

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
    if (self.tls) |*client| {
        client.end() catch {};
    }
    self.tls = null;
    self.socket.stream.close();
    self.capabilities.deinit(alloc);
    alloc.free(self.info);
    self.state = .disconnected;
}

pub fn connect(session: *Session, alloc: std.mem.Allocator, options: ConnectOptions) !void {
    const stream = try std.net.tcpConnectToHost(alloc, options.host, if (options.port == 0) 143 else options.port);
    session.* = .{
        .socket = .{ .stream = stream },
    };
    session.socket.reader = stream.reader(&session.socket.read_buf);
    session.socket.writer = stream.writer(&session.socket.write_buf);
    log.info("Connecting to IMAP server at {s}:{d}", .{ options.host, options.port });

    const read = try session.socket.reader.interface().takeDelimiterInclusive('\n');
    if (std.debug.runtime_safety) std.debug.assert(std.mem.eql(u8, read[read.len - 2 ..], "\r\n"));
    log.info("Connected to IMAP server: {s}", .{read});
    session.state = .connected;
    session.info = try alloc.dupe(u8, read[0 .. read.len - 2]);
    session.tag_id = 1;
}

pub fn connectTls(session: *Session, alloc: std.mem.Allocator, options: ConnectOptions) !void {
    const stream = try std.net.tcpConnectToHost(alloc, options.host, if (options.port == 0) 993 else options.port);
    session.* = .{
        .socket = .{ .stream = stream },
    };
    session.socket.stream = stream;
    session.socket.reader = session.socket.stream.reader(&session.socket.read_buf);
    session.socket.writer = session.socket.stream.writer(&session.socket.write_buf);
    var alert: std.crypto.tls.Alert = undefined;
    session.tls = try std.crypto.tls.Client.init(session.socket.reader.interface(), &session.socket.writer.interface, .{
        .host = .{ .explicit = options.host },
        .ca = .{ .bundle = options.ca_bundle },
        .read_buffer = &session.tls_read_buf,
        .write_buffer = &session.tls_write_buf,
        .alert = &alert,
    });
    log.info("Connecting to IMAP server at {s}:{d}", .{ options.host, options.port });
    log.info("Alert? {any}", .{session.tls.?.alert});

    var client = &session.tls.?;
    _ = try client.reader.peekByte(); // Workaround issue https://github.com/ziglang/zig/issues/25428
    const buffer = try client.reader.takeDelimiterInclusive('\n');
    log.info("Connected to IMAP server: {s}", .{buffer});

    session.state = .connected;
    session.tag_id = 1;
    session.info = try alloc.dupe(u8, buffer[0 .. buffer.len - 2]); // Strip the \r\n
}

fn writer(session: *Session) *std.Io.Writer {
    return if (session.tls) |*client| &client.writer else &session.socket.writer.interface;
}
fn reader(session: *Session) *std.Io.Reader {
    return if (session.tls) |*client| &client.reader else session.socket.reader.interface();
}
fn flush(session: *Session) !void {
    if (session.tls) |*client| {
        try client.writer.flush();
        try client.output.flush();
    } else try session.socket.writer.interface.flush();
}

/// Logs out from the IMAP server and closes the connection.
/// If the session is already disconnected, this function does nothing.
/// This does not close the connection. Make sure to call `disconnect` afterward.
pub fn logout(self: *Session) void {
    if (self.state == .disconnected) {
        return;
    }
    var w = self.writer();
    w.writeAll("A999 LOGOUT\r\n") catch |err| {
        log.err("Failed to write logout command to IMAP server: {}", .{err});
        return;
    };
    self.flush() catch |err| {
        log.err("Failed to flush logout command to IMAP server: {}", .{err});
        return;
    };
    var r = self.reader();
    const read = r.takeDelimiterInclusive('\n') catch |err| {
        log.err("Failed to read from IMAP server after logout command: {}", .{err});
        return;
    };
    log.info("Logged out from IMAP server: {s}", .{read});
}

pub fn noop(self: *Session) !void {
    @breakpoint();
    if (self.state == .disconnected) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;

    var w = self.writer();
    try w.print("{s} NOOP\r\n", .{tag});
    try self.flush();

    var r = self.reader();

    while ((try r.peekByte()) == '*') {
        _ = try r.take(2); // Skip "* "
        const ok = try r.take(2);
        if (ok[0] != 'O' or ok[1] != 'K') {
            log.err("Unexpected response from IMAP server: {s}", .{ok});
            return error.UnexpectedResponse;
        }
        _ = try r.takeDelimiter('\n'); // Skip the rest of the line
    }

    const res_tag = try r.take(4); // Skip "Sxxx"
    if (!std.mem.eql(u8, res_tag, tag)) {
        log.err("Unexpected response tag from IMAP server: {s}", .{res_tag});
        return error.UnexpectedResponse;
    }
    _ = try r.take(1);
    switch (try r.peekByte()) {
        'O' => {
            _ = try r.take(2); // Skip "OK"
            _ = try r.takeDelimiterInclusive('\n'); // Skip the rest of the line
            self.tag_id += 1;
            return;
        },
        'N' => {
            _ = try r.take(2); // Skip "NO"
            const msg = try r.takeDelimiterInclusive('\n');
            log.err("NOOP command failed: {s}", .{msg});
            return error.NoopFailed;
        },
        'B' => {
            _ = try r.take(3); // Skip "BAD"
            const msg = try r.takeDelimiterInclusive('\n');
            log.err("NOOP command failed: {s}", .{msg});
            return error.NoopFailed;
        },
        else => {
            log.err("Unexpected response from IMAP server: {s}", .{res_tag});
            return error.UnexpectedResponse;
        },
    }
}

pub fn capability(self: *Session, alloc: std.mem.Allocator) !Capabilities {
    if (self.state != .connected) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;
    const r = self.reader();
    var w = self.writer();
    try w.print("{s} CAPABILITY\r\n", .{tag});
    try self.flush();

    var parser = Parser.init(r);

    // TODO: Handle case of bad or no
    try parser.expect(.asterisk);
    try parser.expect(.keyword_capability);

    self.capabilities.deinit(alloc);

    try self.capabilities.parse(alloc, &parser);

    try parser.expectIdentifier(tag);
    try parser.expect(.keyword_ok);
    _ = try r.takeDelimiterInclusive('\n');

    self.tag_id += 1;
    return self.capabilities;
}

pub fn startTls(session: *Session, config: ConnectOptions) !void {
    if (session.state != .connected) {
        return error.InvalidState;
    }
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{session.tag_id}) catch unreachable;

    var w = session.writer();
    try w.print("{s} STARTTLS\r\n", .{tag});
    try session.flush();
    log.info("StartTLS with server at {s}:{d}", .{ config.host, config.port });

    const r = session.reader();
    var parser = ResponseParser{
        .tag = tag,
        .reader = r,
    };
    const cap = parser.next() orelse return error.UnexpectedResponse;
    if (cap.tagged.kind != .ok) {
        log.err("STARTTLS command failed: {s}", .{cap.tagged.value});
        return error.StartTlsFailed;
    }

    session.tls = try std.crypto.tls.Client.init(r, w, .{
        // TODO: Add support for explicit host verification
        .host = .{ .no_verification = {} },
        .ca = .{ .self_signed = {} },
        .read_buffer = &session.tls_read_buf,
        .write_buffer = &session.tls_write_buf,
    });

    session.state = .connected;
    session.tag_id = 1;
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
    var w = self.writer();
    try w.print("{s} AUTHENTICATE PLAIN\r\n", .{tag});
    try self.flush();

    var r = self.reader();
    switch (try r.takeByte()) {
        '+' => {
            _ = try r.takeDelimiterInclusive('\n'); // Skip the rest of the line
        },
        else => {
            log.err("Unexpected response from IMAP server: {s}", .{tag_buf});
            return error.UnexpectedResponse;
        },
    }

    var auth_buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&auth_buf);
    var buf_writer = stream.writer();
    try buf_writer.writeByte(0);
    try buf_writer.writeAll(username);
    try buf_writer.writeByte(0);
    try buf_writer.writeAll(password);

    const auth_str = auth_buf[0..stream.pos];
    const encoder = std.base64.standard.Encoder;
    try encoder.encodeWriter(w, auth_str);

    try w.writeAll("\r\n");
    try self.flush();

    var parser = Parser.init(r);

    if (parser.peek()) |tok| {
        switch (tok.tag) {
            .asterisk => {
                parser.expect(.asterisk) catch unreachable;
                try parser.expect(.keyword_capability);
                self.capabilities.deinit(alloc);
                self.capabilities.parse(alloc, &parser) catch |err| {
                    log.err("Failed to parse capabilities from AUTHENTICATE response: {}", .{err});
                    return err;
                };
            },
            .keyword_bad, .keyword_no => {
                log.err("AUTHENTICATE command failed", .{});
                return error.AuthenticateFailed;
            },
            .identifier => {
                // This is likely the tagged response
            },
            else => {
                log.err("Unexpected response from IMAP server", .{});
                return error.UnexpectedResponse;
            },
        }
    }
    try parser.expectIdentifier(tag);
    try parser.expect(.keyword_ok);
    _ = try r.takeDelimiterInclusive('\n');

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

    const w = self.writer();

    log.debug("Sending LIST command", .{});
    w.print("{s} LIST \"{s}\" \"{s}\"\r\n", .{ tag, root, pattern }) catch |err| {
        log.err("Failed to write LIST command to IMAP server: {}", .{err});
        return err;
    };
    try self.flush();

    var list_result = ListResult{};
    errdefer list_result.deinit(alloc);

    var parser = ResponseParser{
        .tag = tag,
        .reader = self.reader(),
    };
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

        fn parse(value: []const u8) ?Flags {
            if (std.mem.eql(u8, value, "Answered")) {
                return .answered;
            } else if (std.mem.eql(u8, value, "Flagged")) {
                return .flagged;
            } else if (std.mem.eql(u8, value, "Draft")) {
                return .draft;
            } else if (std.mem.eql(u8, value, "Deleted")) {
                return .deleted;
            } else if (std.mem.eql(u8, value, "Seen")) {
                return .seen;
            } else if (std.mem.eql(u8, value, "NotJunk")) {
                return .not_junk;
            } else if (std.mem.eql(u8, value, "NonJunk")) {
                return .not_junk;
            } else if (std.mem.eql(u8, value, "NotPhishing")) {
                return .not_phishing;
            } else if (std.mem.eql(u8, value, "Phishing")) {
                return .phishing;
            } else if (std.mem.eql(u8, value, "Forwarded")) {
                return .forwarded;
            } else if (std.mem.eql(u8, value, "Junk")) {
                return .junk;
            } else if (std.mem.eql(u8, value, "JunkRecorded")) {
                return .junk_recorded;
            }
            log.warn("Unknown mailbox flag: {s}", .{value});
            return null;
        }
    };

    pub fn format(value: *const MailboxDetails, w: *std.Io.Writer) !void {
        try w.print("MailboxDetails: ({d} total, {d} recent, {d} unseen, {d} next uid }}", .{
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
            } else if (std.mem.eql(u8, stripped, "NonJunk")) {
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

    var w = self.writer();
    w.print("{s} SELECT {s}\r\n", .{ tag, mailbox.name }) catch |err| {
        log.err("Failed to write SELECT command to IMAP server: {}", .{err});
        return err;
    };
    try self.flush();

    var parser = ResponseParser{
        .tag = tag,
        .reader = self.reader(),
    };
    var mailbox_details = MailboxDetails{};
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
    }
    return error.UnexpectedResponse; // If we reach here, something went wrong
}

pub const Range = struct {
    min: u32 = 0,
    max: u32 = 0,
};

pub const Uid = enum(u32) {
    none = 0,
    _,
};

pub const PreviewResult = struct {
    mail: std.ArrayListUnmanaged(Preview) = .empty,

    pub const Preview = struct {
        uid: Uid = .none,
        flags: std.EnumSet(MailboxDetails.Flags) = .initEmpty(),
        from: []const u8 = "",
        subject: []const u8 = "",
        date: zeit.Instant = undefined,

        pub fn deinit(self: *Preview, alloc: std.mem.Allocator) void {
            alloc.free(self.from);
            alloc.free(self.subject);
            self.flags = .initEmpty();
        }
    };

    pub fn deinit(self: *PreviewResult, alloc: std.mem.Allocator) void {
        for (self.mail.items) |*mail| {
            mail.deinit(alloc);
        }
        self.mail.deinit(alloc);
    }

    pub fn format(self: PreviewResult, w: *std.Io.Writer) !void {
        try w.print("PeekResult: {d} items 0_0", .{
            self.mail.items.len,
        });
    }
};

const PreviewReadState = enum {
    tagged_or_untagged,
    tagged,
    id,
    fetch,
    flag,
    body,
    message_headers,
    message_header,
    message_end,
};

pub fn preview(self: *Session, alloc: std.mem.Allocator, range: Range) !PreviewResult {
    var tag_buf: [4]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "S{d:0>3}", .{self.tag_id}) catch unreachable;

    var w = self.writer();
    w.print("{s} FETCH {d}:{d} (FLAGS BODY.PEEK[HEADER.FIELDS (Subject From Date)])\r\n", .{ tag, range.min, range.max }) catch |err| {
        log.err("Failed to write FETCH command to IMAP server: {}", .{err});
        return err;
    };
    try self.flush();

    const r = self.reader();

    var parser: Parser = .init(r);
    var view: PreviewResult.Preview = .{};
    var result = PreviewResult{};
    errdefer result.deinit(alloc);
    try result.mail.ensureTotalCapacityPrecise(alloc, range.max - range.min + 1);
    parse: switch (PreviewReadState.tagged_or_untagged) {
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
            _ = try r.takeDelimiterInclusive('\n');
            return result;
        },
        .id => {
            view = .{};
            const raw = try parser.get(.int);
            const uid = std.fmt.parseInt(u32, raw, 10) catch {
                log.err("Failed to parse UID from FETCH response: {s}", .{raw});
                return error.UnexpectedResponse;
            };
            view.uid = @enumFromInt(uid);
            continue :parse .fetch;
        },
        .fetch => {
            try parser.expect(.keyword_fetch);
            try parser.expect(.l_paren);
            try parser.expect(.keyword_flags);
            try parser.expect(.l_paren);
            continue :parse .flag;
        },
        .flag => {
            const next = parser.peek();
            if (next) |tok| {
                if (tok.tag == .r_paren) {
                    parser.expect(.r_paren) catch unreachable;
                    continue :parse .body;
                }
                if (MailboxDetails.Flags.parse(parser.value())) |flag| {
                    view.flags.insert(flag);
                }
                _ = parser.next();
                continue :parse .flag;
            } else {
                return error.UnexpectedResponse;
            }
        },
        .body => {
            try parser.expect(.keyword_body);
            try parser.expect(.l_bracket);
            try parser.expect(.keyword_header);
            try parser.expect(.period);
            try parser.expect(.keyword_fields);
            try parser.expect(.l_paren);
            try parser.expect(.keyword_subject);
            try parser.expect(.keyword_from);
            try parser.expect(.keyword_date);
            try parser.expect(.r_paren);
            try parser.expect(.r_bracket);
            try parser.expect(.l_brace);
            _ = try parser.get(.int);
            try parser.expect(.r_brace);
            try parser.expect(.crlf);
            continue :parse .message_headers;
        },
        .message_headers => {
            const next = parser.peek();
            if (next) |tok| {
                if (tok.tag == .crlf) {
                    continue :parse .message_end;
                } else {
                    continue :parse .message_header;
                }
            }
        },
        .message_header => {
            const header = parser.next() orelse return error.UnexpectedResponse;
            if (!parser.peekExpect(.colon)) return error.InvalidMessageHeader;
            var value: std.ArrayList(u8) = .empty;
            while (try r.peekByte() == ' ') {
                _ = try r.take(1); // consume the space
                var line = try r.takeDelimiterInclusive('\n');
                try value.appendSlice(alloc, line[0 .. line.len - 2]); // Strip CRLF
            }
            _ = parser.next() orelse return error.UnexpectedResponse; // prime the next token
            if (header.tag == .keyword_subject) {
                view.subject = try value.toOwnedSlice(alloc);
            } else if (header.tag == .keyword_from) {
                view.from = try value.toOwnedSlice(alloc);
            } else if (header.tag == .keyword_date) {
                view.date = try zeit.instant(.{
                    .source = .{
                        .rfc2822 = value.items, // Strip CRLF
                    },
                });
            }
            continue :parse .message_headers;
        },
        .message_end => {
            parser.expect(.crlf) catch unreachable;
            try parser.expect(.r_paren);
            try parser.expect(.crlf);
            result.mail.appendAssumeCapacity(view);
            continue :parse .tagged_or_untagged;
        },
    }
    return error.UnexpectedResponse; // If we reach here, something went wrong
}
