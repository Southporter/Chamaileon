/// An RFC822 Email
///
///
const std = @import("std");
const superhtml = @import("superhtml");
const decoding = @import("decoding.zig");
const log = std.log.scoped(.email_rfc822);
const Email = @This();

/// An arena of all allocated email data. This makes deallocation easy.
arena: std.heap.ArenaAllocator,
/// All headers from the RFC822 email
headers: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
/// The full body. If any of the parts have been decoded, this will be mutated.
/// After calling parse(), this will not change.
body_full: []const u8 = undefined,
/// The parsed parts of the email. Currently supports a maximum of 4 parts.
/// Most emails will have 1 or 2 parts. Usually a plaintext and HTML part.
/// There may be additional parts for attachments, but those are not yet supported.
/// Any parts not used will have content type `unknown`.
parts: [4]Part = @splat(.{
    .content_encoding = .unknown,
    .content = .{ .unknown = &[_]u8{} },
}),

/// Character sets supported in email parts.
/// Currently only utf-8 is supported.
const Charset = enum {
    utf_8,
    iso_8859_1,
    unknown,

    pub fn fromString(value: []const u8) Charset {
        if (std.ascii.eqlIgnoreCase(value, "utf-8")) {
            return .utf_8;
        } else if (std.ascii.eqlIgnoreCase(value, "iso-8859-1")) {
            return .iso_8859_1;
        } else {
            log.warn("Unknown charset: {s}", .{value});
            return .unknown;
        }
    }
};

/// Content types supported in email parts.
/// Currently supports text/plain, text/html, multipart/mixed, multipart/alternative.
/// Anything else is considered unknown.
const ContentType = enum {
    text_plain,
    text_html,
    multipart_mixed,
    multipart_alternative,
    multipart_related,
    unknown,

    pub fn fromString(value: []const u8) ContentType {
        if (std.mem.eql(u8, value, "text/plain")) {
            return .text_plain;
        } else if (std.mem.eql(u8, value, "text/html")) {
            return .text_html;
        } else if (std.mem.eql(u8, value, "multipart/mixed")) {
            return .multipart_mixed;
        } else if (std.mem.eql(u8, value, "multipart/alternative")) {
            return .multipart_alternative;
        } else if (std.mem.eql(u8, value, "multipart/related")) {
            return .multipart_related;
        } else {
            return .unknown;
        }
    }
};

/// Content transfer encodings supported in email parts.
/// Currently only quoted-printable is supported.
const ContentEncoding = enum {
    quoted_printable,
    utf7,
    @"7bit",
    base64,
    unknown,

    pub fn fromString(value: []const u8) ContentEncoding {
        if (std.ascii.eqlIgnoreCase(value, "quoted-printable")) {
            return .quoted_printable;
        } else if (std.ascii.eqlIgnoreCase(value, "utf-7")) {
            return .utf7;
        } else if (std.ascii.eqlIgnoreCase(value, "7bit")) {
            return .@"7bit";
        } else if (std.ascii.eqlIgnoreCase(value, "base64")) {
            return .base64;
        } else {
            log.warn("Unknown content encoding: {s}", .{value});
            return .unknown;
        }
    }
};

/// One part of a multi-part email. If an email is not multi-part, it will have a single part.
/// Each part has a content type, content transfer encoding, and charset.
const Part = struct {
    content_encoding: ContentEncoding = .unknown,
    charset: Charset = .unknown,
    content: Content,

    const Content = union(ContentType) {
        text_plain: []const u8,
        text_html: struct {
            ast: *superhtml.html.Ast,
            src: []const u8,
        },
        multipart_mixed: void,
        multipart_alternative: void,
        multipart_related: void,
        unknown: []const u8,
    };
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return switch (self.content) {
            .text_plain => |content| writer.print("(Part: type=text/plain, encoding={any}, charset={any}, content_len={d})", .{ self.content_encoding, self.charset, content.len }),
            .text_html => |html| writer.print("(Part: type=text/html, encoding={any}, charset={any}, ast_nodes={d})", .{ self.content_encoding, self.charset, html.ast.nodes.len }),
            .multipart_mixed => writer.print("(Part: type=multipart/mixed)", .{}),
            .multipart_alternative => writer.print("(Part: type=multipart/alternative)", .{}),
            .unknown => |content| writer.print("(Part: type=unknown, encoding={any}, charset={any}, content_len={d})", .{ self.content_encoding, self.charset, content.len }),
        };
    }
};

/// Deinitialize the email and free all allocated memory.
pub fn deinit(self: *Email) void {
    self.arena.deinit();
}

/// Allocate memory from the email's arena. This is mainly for internal use.
/// This is typically used to pre-allocate the memory for the raw body bytes.
pub fn alloc(self: *Email, count: usize) std.mem.Allocator.Error![]u8 {
    return self.arena.allocator().alloc(u8, count);
}

const ParserState = enum {
    headers,
    header,
    header_value,
    body,
};

fn parseHeaders(self: *Email) !usize {
    var it = std.mem.splitSequence(u8, self.body_full, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) {
            break; // End of headers
        }
        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = line[0..colon_index];
        var value_start = colon_index + 1;
        while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t')) {
            value_start += 1; // Skip leading whitespace
        }
        var value = line[value_start..];
        // Handle folded headers
        while (it.peek()) |next_line| {
            if (next_line.len > 0 and (next_line[0] == ' ' or next_line[0] == '\t')) {
                if (it.next()) |continuation| {
                    value.len += continuation.len + 2; // +2 for the CRLF
                }
            } else {
                break;
            }
        }
        try self.headers.put(self.arena.allocator(), header_name, value);
    }
    return it.index.?;
}

/// Parse the email body and headers.
/// This will populate the `headers` and `parts` fields of the email.
/// This expects the `body_full` field to be populated with the full raw email data.
pub fn parse(self: *Email) !void {
    try self.headers.ensureTotalCapacity(self.arena.allocator(), 16);

    const headers_end = try self.parseHeaders();

    const content_type = self.headers.get("Content-Type");
    log.info("Email Content-Type: {?s}", .{content_type});
    var part_iter = std.mem.tokenizeScalar(u8, content_type.?, ';');
    const main_type = ContentType.fromString(part_iter.next() orelse return error.InvalidContentType);
    const encoding_header = self.headers.get("Content-Transfer-Encoding");
    const main_encoding = if (encoding_header) |enc| ContentEncoding.fromString(enc) else .unknown;
    switch (main_type) {
        .text_plain => {
            self.parts[0] = .{
                .content_encoding = main_encoding,
                .content = .{
                    .text_plain = switch (main_encoding) {
                        .quoted_printable => try decoding.quotedPrintable(@constCast(self.body_full[headers_end..]), .{}),
                        .base64 => try decoding.base64(@constCast(self.body_full[headers_end..])),
                        else => self.body_full[headers_end..],
                    },
                },
            };
        },
        .text_html => {
            const ast = try self.arena.allocator().create(superhtml.html.Ast);
            const src = switch (main_encoding) {
                .quoted_printable => try decoding.quotedPrintable(@constCast(self.body_full[headers_end..]), .{}),
                .base64 => try decoding.base64(@constCast(self.body_full[headers_end..])),
                else => self.body_full[headers_end..],
            };
            ast.* = try superhtml.html.Ast.init(self.arena.allocator(), src, .html, false);
            self.parts[0] = .{
                .content = .{
                    .text_html = .{
                        .ast = ast,
                        .src = src,
                    },
                },
            };
        },
        .multipart_mixed => {
            log.warn("Multipart/mixed not yet supported", .{});
        },
        .multipart_related => {
            log.warn("Multipart/related not yet supported", .{});
        },
        .multipart_alternative => {
            const boundary_prefix = "boundary=";
            var boundary: []const u8 = "";
            while (part_iter.next()) |part| {
                var trimmed = std.mem.trim(u8, part, " \r\n\t");
                if (std.mem.startsWith(u8, trimmed, boundary_prefix)) {
                    boundary = std.mem.trim(u8, trimmed[boundary_prefix.len..trimmed.len], "\""); // Strip quotes
                    break;
                }
            }
            if (boundary.len == 0) {
                log.err("Multipart email missing boundary in Content-Type: {?s}", .{content_type});
                return error.InvalidContentType;
            }
            var parser = Parser{
                .input = .fixed(self.body_full[headers_end..]),
            };
            var part_index: usize = 0;
            var part: Part = .{
                .content = .{ .unknown = &[_]u8{} },
            };
            parse: switch (enum { boundary, headers, content }.boundary) {
                .boundary => {
                    parser.skipWhitespace();
                    try parser.expectSlice("--");
                    try parser.expectSlice(boundary);
                    if (parser.nextIsCrlf()) {
                        parser.crlf() catch unreachable;
                        continue :parse .headers;
                    }
                    try parser.expectSlice("--\r\n");
                    break :parse; // End of multipart
                },
                .headers => {
                    var line_it = std.mem.splitSequence(u8, parser.input.buffer[parser.input.seek..], "\r\n");
                    while (line_it.next()) |line| {
                        if (line.len == 0) {
                            _ = parser.input.take(line_it.index.?) catch unreachable;
                            continue :parse .content; // End of part headers
                        }
                        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                        const header_name = line[0..colon_index];
                        if (std.mem.eql(u8, header_name, "Content-Type")) {
                            const value_start = colon_index + 1;
                            const split = std.mem.indexOfScalar(u8, line[value_start..], ';') orelse line.len;
                            const value = line[value_start .. split + value_start];
                            switch (ContentType.fromString(std.mem.trim(u8, value, " "))) {
                                .text_plain => {
                                    part.content = .{
                                        .text_plain = self.body_full[0..0],
                                    };
                                },
                                .text_html => {
                                    part.content = .{
                                        .text_html = undefined,
                                    };
                                },
                                .multipart_mixed => {
                                    part.content = .{
                                        .multipart_mixed = {},
                                    };
                                },
                                .multipart_alternative => {
                                    part.content = .{
                                        .multipart_alternative = {},
                                    };
                                },
                                .multipart_related => {
                                    part.content = .{
                                        .multipart_related = {},
                                    };
                                },
                                .unknown => {
                                    part.content = .{
                                        .unknown = self.body_full[0..0],
                                    };
                                },
                            }
                            if (split != line.len) {
                                const params = line[split + value_start ..];
                                var param_iter = std.mem.tokenizeScalar(u8, params, ';');
                                while (param_iter.next()) |param| {
                                    var trimmed = std.mem.trim(u8, param, " ");
                                    if (std.mem.startsWith(u8, trimmed, "charset=")) {
                                        var charset_value = trimmed["charset=".len..];
                                        if (std.mem.startsWith(u8, charset_value, "\"") and
                                            std.mem.endsWith(u8, charset_value, "\""))
                                        {
                                            charset_value = charset_value[1 .. charset_value.len - 1];
                                        }
                                        part.charset = Charset.fromString(charset_value);
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, header_name, "Content-Transfer-Encoding")) {
                            const value_start = colon_index + 1;
                            const value = line[value_start..];
                            part.content_encoding = ContentEncoding.fromString(std.mem.trim(u8, value, " "));
                        }
                    }
                },
                .content => {
                    const content_start = parser.input.seek;
                    while (true) {
                        parser.skipWhitespace();
                        const possible_boundary = try parser.input.peek(boundary.len + 4);
                        if (std.mem.startsWith(u8, possible_boundary, "--")) {
                            if (std.mem.eql(u8, possible_boundary[2 .. 2 + boundary.len], boundary)) {
                                break; // Reached boundary
                            }
                        }
                        _ = parser.until('\r') catch break;
                    }
                    const content_end = parser.input.seek;
                    switch (part.content) {
                        .text_html => {
                            const ast = try self.arena.allocator().create(superhtml.html.Ast);
                            const src = switch (part.content_encoding) {
                                .quoted_printable => try decoding.quotedPrintable(@constCast(parser.input.buffer[content_start..content_end]), .{}),
                                .base64 => try decoding.base64(@constCast(parser.input.buffer[content_start..content_end])),
                                else => parser.input.buffer[content_start..content_end],
                            };

                            ast.* = try superhtml.html.Ast.init(self.arena.allocator(), src, .html, false);
                            part.content = .{
                                .text_html = .{
                                    .ast = ast,
                                    .src = src,
                                },
                            };
                        },
                        .text_plain => {
                            switch (part.content_encoding) {
                                .quoted_printable => {
                                    // Can const cast because decoding returns a slice into the same buffer
                                    const decoded = try decoding.quotedPrintable(@constCast(parser.input.buffer[content_start..content_end]), .{});
                                    part.content = .{ .text_plain = decoded };
                                },
                                .base64 => {
                                    const decoded = try decoding.base64(@constCast(parser.input.buffer[content_start..content_end]));
                                    part.content = .{ .text_plain = decoded };
                                },
                                else => {
                                    part.content = .{ .text_plain = parser.input.buffer[content_start..content_end] };
                                },
                            }
                            part.content = .{ .text_plain = parser.input.buffer[content_start..content_end] };
                        },
                        else => {},
                    }
                    self.parts[part_index] = part;
                    part_index += 1;
                    part = .{
                        .content = .{ .unknown = &[_]u8{} },
                    };
                    if (part_index >= self.parts.len) {
                        log.warn("Exceeded maximum number of parts", .{});
                        return;
                    }
                    continue :parse .boundary;
                },
            }
        },
        .unknown => {
            log.warn("Unknown Content-Type: {?s}", .{content_type});
        },
    }
}

const Parser = struct {
    input: std.Io.Reader,

    fn skipWhitespace(self: *Parser) void {
        while (true) {
            const byte = self.input.peekByte() catch break;
            if (std.ascii.isWhitespace(byte)) {
                _ = self.input.takeByte() catch break;
            } else {
                break;
            }
        }
    }

    pub fn expectSlice(self: *Parser, expected: []const u8) !void {
        const buffer = try self.input.peek(expected.len);
        if (!std.mem.eql(u8, buffer[0..], expected)) {
            return error.UnexpectedData;
        }
        _ = self.input.take(expected.len) catch unreachable;
    }

    pub fn crlf(self: *Parser) !void {
        try self.expectSlice("\r\n");
    }

    pub fn until(self: *Parser, delimiter: u8) ![]const u8 {
        var len: usize = 0;
        while (len + self.input.seek < self.input.end) : (len += 1) {
            if (self.input.buffer[self.input.seek + len] == delimiter) {
                break;
            }
        }
        return self.input.take(len) catch unreachable;
    }

    pub fn nextIsCrlf(self: *Parser) bool {
        const buffer = self.input.peek(2) catch return false;
        return std.mem.eql(u8, buffer, "\r\n");
    }
};

test "Plaintext Only" {
    const input = "Content-Type: text/plain; charset=\"utf-8\"\r\n" ++
        "Subject: Test Email\r\n" ++
        "From: test@example.com\r\n" ++
        "To: me@examples.com\r\n" ++
        "\r\n" ++
        "This is a test email body.\r\n";

    var email = Email{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .body_full = input,
    };
    defer email.deinit();

    try email.parse();
    try std.testing.expect(std.meta.activeTag(email.parts[0].content) == .text_plain);
    try std.testing.expect(std.meta.activeTag(email.parts[1].content) == .unknown);
    try std.testing.expect(std.meta.activeTag(email.parts[2].content) == .unknown);
    try std.testing.expect(std.meta.activeTag(email.parts[3].content) == .unknown);
    try std.testing.expectEqualStrings(email.parts[0].content.text_plain, "This is a test email body.\r\n");
}
test "Multipart Alternative" {
    const plain_text = "This is the plain text part of the email.\r\n";
    const text_html = "<html><body><p>This is the HTML part of the email.</p></body></html>\r\n";
    const input = "Content-Type: multipart/alternative; boundary=\"BONDARY\"\r\n" ++
        "Subject: Test Email\r\n" ++
        "From: test@example.com\r\n" ++
        "To: me@examples.com\r\n" ++
        "\r\n" ++
        "--BONDARY\r\n" ++
        "Content-Type: text/plain; charset=\"utf-8\"\r\n" ++
        "\r\n" ++
        plain_text ++
        "--BONDARY\r\n" ++
        "Content-Type: text/html; charset=\"utf-8\"\r\n" ++
        "\r\n" ++
        text_html ++
        "--BONDARY--\r\n";
    var email = Email{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .body_full = input,
    };
    defer email.deinit();

    try email.parse();
    try std.testing.expect(std.meta.activeTag(email.parts[0].content) == .text_plain);
    try std.testing.expect(std.meta.activeTag(email.parts[1].content) == .text_html);
    try std.testing.expect(std.meta.activeTag(email.parts[2].content) == .unknown);
    try std.testing.expect(std.meta.activeTag(email.parts[3].content) == .unknown);
    try std.testing.expectEqualStrings(email.parts[0].content.text_plain, plain_text);
    try std.testing.expectEqual(email.parts[0].charset, .utf_8);
    try std.testing.expectEqual(email.parts[1].charset, .utf_8);
    try std.testing.expectEqualStrings(email.parts[1].content.text_html.src, text_html);
}
test "Multipart Alternative Unquoted Boundary" {
    const plain_text = "This is the plain text part of the email.\r\n";
    const text_html = "<html><body><p>This is the HTML part of the email.</p></body></html>\r\n";
    const input = "Content-Type: multipart/alternative; boundary=BONDARY\r\n" ++
        "Subject: Test Email\r\n" ++
        "From: test@example.com\r\n" ++
        "To: me@examples.com\r\n" ++
        "\r\n" ++
        "--BONDARY\r\n" ++
        "Content-Type: text/plain; charset=\"utf-8\"\r\n" ++
        "\r\n" ++
        plain_text ++
        "--BONDARY\r\n" ++
        "Content-Type: text/html; charset=\"utf-8\"\r\n" ++
        "\r\n" ++
        text_html ++
        "--BONDARY--\r\n";
    var email = Email{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .body_full = input,
    };
    defer email.deinit();

    try email.parse();
    try std.testing.expect(std.meta.activeTag(email.parts[0].content) == .text_plain);
    try std.testing.expect(std.meta.activeTag(email.parts[1].content) == .text_html);
    try std.testing.expect(std.meta.activeTag(email.parts[2].content) == .unknown);
    try std.testing.expect(std.meta.activeTag(email.parts[3].content) == .unknown);
    try std.testing.expectEqualStrings(email.parts[0].content.text_plain, plain_text);
    try std.testing.expectEqual(email.parts[0].charset, .utf_8);
    try std.testing.expectEqual(email.parts[1].charset, .utf_8);
    try std.testing.expectEqualStrings(email.parts[1].content.text_html.src, text_html);
}

test "Quoted-Printable Encoding" {
    const input = "Content-Type: text/plain; charset=\"utf-8\"\r\n" ++
        "Content-Transfer-Encoding: quoted-printable\r\n" ++
        "\r\n" ++
        "This is a test email body with quoted-printable encoding.=0A" ++
        "Here is a line break.=0A" ++
        "And some special characters: =C3=A9, =C3=B1, =C3=BC.\r\n";
    var email = Email{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .body_full = input,
    };
    defer email.deinit();
    try email.parse();
    try std.testing.expectEqual(.text_plain, std.meta.activeTag(email.parts[0].content));
    try std.testing.expectEqual(.quoted_printable, email.parts[0].content_encoding);
    try std.testing.expectEqualStrings(email.parts[0].content.text_plain, "This is a test email body with quoted-printable encoding.\nHere is a line break.\nAnd some special characters: \xC3\xA9, \xC3\xB1, \xC3\xBC.\r\n");
}
test {
    _ = @import("decoding.zig");
}
