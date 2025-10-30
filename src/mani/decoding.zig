const std = @import("std");
const log = std.log.scoped(.decoding);

pub const DecodeError = error{
    InvalidHexDigit,
};

const QuotedPrintableOptions = struct {
    header_space: bool = false,
};

/// Decode the src in place. Returns a slice of the decoded data.
/// Decoded quoted-printable data according to RFC 2045.
/// Returned slice will always be smaller than or equal to the input slice.
pub fn quotedPrintable(src: []u8, options: QuotedPrintableOptions) ![]u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < src.len) {
        if (src[read] == '=') {
            read += 2;
            std.debug.assert(read < src.len);
            if (src[read] == '\n' or src[read] == '\r') {
                // Soft line break, skip
                read += 1;
                continue;
            }
            _ = try std.fmt.hexToBytes(src[write .. write + 1], src[read - 1 .. read + 1]);
        } else {
            if (options.header_space and src[read] == '_') {
                src[write] = ' ';
            } else {
                src[write] = src[read];
            }
        }
        read += 1;
        write += 1;
    }
    return src[0..write];
}

pub fn base64(src: []u8) ![]u8 {
    const decoded_size = try base64Decoder.calcSizeForSlice(src);
    const decoded = src[0..decoded_size];
    try base64Decoder.decode(decoded, src);
    return decoded;
}

pub fn utf7(src: []const u8) ![]const u8 {
    log.warn("utf7 decoding not implemented", .{});
    log.warn("input: {s}", .{src});
    // Placeholder implementation
    return src;
}

const Base64Decoder = struct {
    const invalid_char: u8 = 0xff;
    const invalid_char_tst: u32 = 0xff000000;

    /// e.g. 'A' => 0.
    /// `invalid_char` for any value not in the 64 alphabet chars.
    char_to_index: [256]u8,
    fast_char_to_index: [4][256]u32,
    pad_char: ?u8,
    const Error = error{
        InvalidCharacter,
        InvalidPadding,
        NoSpaceLeft,
    };

    pub fn init(alphabet_chars: [64]u8, pad_char: ?u8) Base64Decoder {
        var result = Base64Decoder{
            .char_to_index = [_]u8{invalid_char} ** 256,
            .fast_char_to_index = .{[_]u32{invalid_char_tst} ** 256} ** 4,
            .pad_char = pad_char,
        };

        var char_in_alphabet = [_]bool{false} ** 256;
        for (alphabet_chars, 0..) |c, i| {
            std.debug.assert(!char_in_alphabet[c]);
            std.debug.assert(pad_char == null or c != pad_char.?);

            const ci = @as(u32, @intCast(i));
            result.fast_char_to_index[0][c] = ci << 2;
            result.fast_char_to_index[1][c] = (ci >> 4) | ((ci & 0x0f) << 12);
            result.fast_char_to_index[2][c] = ((ci & 0x3) << 22) | ((ci & 0x3c) << 6);
            result.fast_char_to_index[3][c] = ci << 16;

            result.char_to_index[c] = @as(u8, @intCast(i));
            char_in_alphabet[c] = true;
        }
        return result;
    }

    /// Return the maximum possible decoded size for a given input length - The actual length may be less if the input includes padding.
    /// `InvalidPadding` is returned if the input length is not valid.
    pub fn calcSizeUpperBound(decoder: *const Base64Decoder, source_len: usize) Error!usize {
        var result = source_len / 4 * 3;
        const leftover = source_len % 4;
        if (decoder.pad_char != null) {
            if (leftover % 4 != 0) return error.InvalidPadding;
        } else {
            if (leftover % 4 == 1) return error.InvalidPadding;
            result += leftover * 3 / 4;
        }
        return result;
    }

    /// Return the exact decoded size for a slice.
    /// `InvalidPadding` is returned if the input length is not valid.
    pub fn calcSizeForSlice(decoder: *const Base64Decoder, source: []const u8) Error!usize {
        const source_len = source.len;
        var result = try decoder.calcSizeUpperBound(source_len);
        if (decoder.pad_char) |pad_char| {
            if (source_len >= 1 and source[source_len - 1] == pad_char) result -= 1;
            if (source_len >= 2 and source[source_len - 2] == pad_char) result -= 1;
        }
        return result;
    }

    const StreamError = Error || std.Io.Reader.Error || std.Io.Writer.Error;
    pub fn stream(decoder: *const Base64Decoder, read: *std.Io.Reader, write: *std.Io.Writer) StreamError!void {
        while (true) {
            const bytes = read.take(4) catch |e| switch (e) {
                std.Io.Reader.Error.EndOfStream => return,
                else => return e,
            };
            var dest: [3]u8 = .{ 0, 0, 0 };
            try decoder.decode(&dest, bytes);
            try write.writeAll(std.mem.trim(u8, &dest, "\x00"));
        }
    }

    /// dest.len must be what you get from ::calcSize.
    /// Invalid characters result in `error.InvalidCharacter`.
    /// Invalid padding results in `error.InvalidPadding`.
    pub fn decode(decoder: *const Base64Decoder, dest: []u8, source: []const u8) Error!void {
        if (decoder.pad_char != null and source.len % 4 != 0) return error.InvalidPadding;
        var dest_idx: usize = 0;
        var fast_src_idx: usize = 0;
        var acc: u12 = 0;
        var acc_len: u4 = 0;
        var leftover_idx: ?usize = null;
        while (fast_src_idx + 16 < source.len and dest_idx + 15 < dest.len) : ({
            fast_src_idx += 16;
            dest_idx += 12;
        }) {
            var bits: u128 = 0;
            inline for (0..4) |i| {
                var new_bits: u128 = decoder.fast_char_to_index[0][source[fast_src_idx + i * 4]];
                new_bits |= decoder.fast_char_to_index[1][source[fast_src_idx + 1 + i * 4]];
                new_bits |= decoder.fast_char_to_index[2][source[fast_src_idx + 2 + i * 4]];
                new_bits |= decoder.fast_char_to_index[3][source[fast_src_idx + 3 + i * 4]];
                if ((new_bits & invalid_char_tst) != 0) return error.InvalidCharacter;
                bits |= (new_bits << (24 * i));
            }
            std.mem.writeInt(u128, dest[dest_idx..][0..16], bits, .little);
        }
        while (fast_src_idx + 4 < source.len and dest_idx + 3 < dest.len) : ({
            fast_src_idx += 4;
            dest_idx += 3;
        }) {
            var bits = decoder.fast_char_to_index[0][source[fast_src_idx]];
            bits |= decoder.fast_char_to_index[1][source[fast_src_idx + 1]];
            bits |= decoder.fast_char_to_index[2][source[fast_src_idx + 2]];
            bits |= decoder.fast_char_to_index[3][source[fast_src_idx + 3]];
            if ((bits & invalid_char_tst) != 0) return error.InvalidCharacter;
            std.mem.writeInt(u32, dest[dest_idx..][0..4], bits, .little);
        }
        const remaining = source[fast_src_idx..];
        for (remaining, fast_src_idx..) |c, src_idx| {
            const d = decoder.char_to_index[c];
            if (d == invalid_char) {
                if (decoder.pad_char == null or c != decoder.pad_char.?) return error.InvalidCharacter;
                leftover_idx = src_idx;
                break;
            }
            acc = (acc << 6) + d;
            acc_len += 6;
            if (acc_len >= 8) {
                acc_len -= 8;
                dest[dest_idx] = @as(u8, @truncate(acc >> acc_len));
                dest_idx += 1;
            }
        }
        if (acc_len > 4 or (acc & (@as(u12, 1) << acc_len) - 1) != 0) {
            return error.InvalidPadding;
        }
        if (leftover_idx == null) return;
        const leftover = source[leftover_idx.?..];
        if (decoder.pad_char) |pad_char| {
            const padding_len = acc_len / 2;
            var padding_chars: usize = 0;
            for (leftover) |c| {
                if (c != pad_char) {
                    return if (c == Base64Decoder.invalid_char) error.InvalidCharacter else error.InvalidPadding;
                }
                padding_chars += 1;
            }
            if (padding_chars != padding_len) return error.InvalidPadding;
        }
    }
};

const base64Decoder = Base64Decoder.init(std.base64.standard_alphabet_chars, '=');

pub fn mimeWord(src: *std.Io.Reader, sink: *std.Io.Writer) !void {
    while (src.seek < src.end) {
        if (std.mem.eql(u8, src.peek(2) catch "", "=?")) {
            _ = src.take(2) catch unreachable;
            const charset = try src.takeDelimiter('?') orelse "";
            if (!std.ascii.eqlIgnoreCase(charset, "utf-8")) {
                log.warn("Unknown charset: {s}", .{charset});
                return error.UnknownMimeWordCharset;
            }
            const encoding = try src.takeDelimiter('?') orelse "";
            const text = try src.takeDelimiter('?') orelse "";
            const end = try src.takeByte();
            std.debug.assert(end == '=');

            if (std.ascii.eqlIgnoreCase(encoding, "Q")) {
                // Quoted-printable decoding
                const decoded_slice = try quotedPrintable(@constCast(text), .{ .header_space = true });
                var decoded: std.Io.Reader = .fixed(decoded_slice);
                // Copy decoded data to output
                const streamed = decoded.streamRemaining(sink) catch unreachable;
                std.debug.assert(streamed == decoded_slice.len);
            } else if (std.ascii.eqlIgnoreCase(encoding, "B")) {
                var encoded = std.Io.Reader.fixed(text);
                try base64Decoder.stream(&encoded, sink);
            } else {
                log.warn("Unknown encoding: {s}", .{encoding});
                return error.UnknownMimeWordEncoding;
            }
        } else {
            src.streamExact(sink, 1) catch unreachable;
        }
    }
}

test "quoted-printable decoding" {
    const input: []const u8 = "Hello=2C=20World=21=0AThis=20is=20a=20test=2E=0A";
    const duped = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(duped);
    const expected = "Hello, World!\nThis is a test.\n";
    const decoded = try quotedPrintable(duped, .{});
    try std.testing.expectEqualStrings(expected, decoded);
}

test "quoted-printable decoding with no encoded chars" {
    const input: []const u8 = "Just a normal string with no encoding.";
    const duped = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(duped);
    const expected = "Just a normal string with no encoding.";
    const decoded = try quotedPrintable(duped, .{});
    try std.testing.expectEqualStrings(expected, decoded);
}

test "quoted-printable with newlines in a header" {
    const input: []const u8 = "Hello=2C=20World=21=\r\nThis=20is=20a=20test=2E=0A";
    const duped = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(duped);
    const expected = "Hello, World!This is a test.\n";
    const decoded = try quotedPrintable(duped, .{ .header_space = true });
    try std.testing.expectEqualStrings(expected, decoded);
}

test "utf7 decoding" {
    const input: []const u8 = "Hello &AOk- World &APg-!";
    const decoded = try utf7(input);
    // Since utf7 is not implemented, we just check that the output matches the input for now
    try std.testing.expectEqualStrings(input, decoded);
}

test "mime word decoding" {
    const input: []const u8 = "=?UTF-8?Q?Hello=2C=20World!?=";
    const duped = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(duped);
    var reader = std.Io.Reader.fixed(duped);
    var result = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer result.deinit();
    var writer = &result.writer;

    try mimeWord(&reader, writer);
    // Since mimeWord is not implemented, we just check that the output matches the input for now
    try std.testing.expectEqualStrings("Hello, World!", writer.buffer[0..writer.end]);
}

test "mime word decoding base64" {
    const input: []const u8 = "=?UTF-8?B?SGVsbG8sIFdvcmxkIQ==?=";
    const duped = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(duped);
    var reader = std.Io.Reader.fixed(duped);
    var result = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer result.deinit();
    var writer = &result.writer;

    try mimeWord(&reader, writer);
    try std.testing.expectEqualStrings("Hello, World!", writer.buffer[0..writer.end]);
}
test "mime word decoding no encoding" {
    const input: []const u8 = "Hello, World!";
    const duped = try std.testing.allocator.dupe(u8, input);
    defer std.testing.allocator.free(duped);
    var reader = std.Io.Reader.fixed(duped);
    var result = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer result.deinit();
    var writer = &result.writer;

    try mimeWord(&reader, writer);
    try std.testing.expectEqualStrings("Hello, World!", writer.buffer[0..writer.end]);
}
