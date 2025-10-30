/// This module provides functions to convert byte slices from various charsets to UTF-8.
const std = @import("std");

const ReadErrors = std.Io.Reader.Error;
const WriteErrors = std.Io.Writer.Error;
const Iso8859_1Errors = error{
    UndefinedIso8859_1Byte,
} || ReadErrors || WriteErrors;

/// Converts a byte slice from ISO-8859-1 to UTF-8.
/// Many characters in ISO-8859-1 map directly to single-byte UTF-8 characters,
/// but characters in the range 0xA0 to 0xFF map to two
/// Use Writers to handle the fact that the resulting UTF-8 may be longer than the input.
pub fn iso8859_1ToUtf8(from: *std.Io.Reader, to: *std.Io.Writer) Iso8859_1Errors!void {
    while (from.takeByte() catch |err| switch (err) {
        ReadErrors.EndOfStream => null,
        ReadErrors.ReadFailed => return err,
    }) |b| {
        switch (b) {
            0x20...0x7E => try to.writeByte(b),
            0xA0 => try to.writeAll(" "), // Non-breaking space
            0xA1 => try to.writeAll("¡"),
            0xA2 => try to.writeAll("¢"),
            0xA3 => try to.writeAll("£"),
            0xA4 => try to.writeAll("¤"),
            0xA5 => try to.writeAll("¥"),
            0xA6 => try to.writeAll("¦"),
            0xA7 => try to.writeAll("§"),
            0xA8 => try to.writeAll("¨"),
            0xA9 => try to.writeAll("©"),
            0xAA => try to.writeAll("ª"),
            0xAB => try to.writeAll("«"),
            0xAC => try to.writeAll("¬"),
            0xAD => try to.writeAll("­"), // Soft hyphen
            0xAE => try to.writeAll("®"),
            0xAF => try to.writeAll("¯"),
            0xB0 => try to.writeAll("°"),
            0xB1 => try to.writeAll("±"),
            0xB2 => try to.writeAll("²"),
            0xB3 => try to.writeAll("³"),
            0xB4 => try to.writeAll("´"),
            0xB5 => try to.writeAll("µ"),
            0xB6 => try to.writeAll("¶"),
            0xB7 => try to.writeAll("·"),
            0xB8 => try to.writeAll("¸"),
            0xB9 => try to.writeAll("¹"),
            0xBA => try to.writeAll("º"),
            0xBB => try to.writeAll("»"),
            0xBC => try to.writeAll("¼"),
            0xBD => try to.writeAll("½"),
            0xBE => try to.writeAll("¾"),
            0xBF => try to.writeAll("¿"),
            0xC0 => try to.writeAll("À"),
            0xC1 => try to.writeAll("Á"),
            0xC2 => try to.writeAll("Â"),
            0xC3 => try to.writeAll("Ã"),
            0xC4 => try to.writeAll("Ä"),
            0xC5 => try to.writeAll("Å"),
            0xC6 => try to.writeAll("Æ"),
            0xC7 => try to.writeAll("Ç"),
            0xC8 => try to.writeAll("È"),
            0xC9 => try to.writeAll("É"),
            0xCA => try to.writeAll("Ê"),
            0xCB => try to.writeAll("Ë"),
            0xCC => try to.writeAll("Ì"),
            0xCD => try to.writeAll("Í"),
            0xCE => try to.writeAll("Î"),
            0xCF => try to.writeAll("Ï"),
            0xD0 => try to.writeAll("Ð"),
            0xD1 => try to.writeAll("Ñ"),
            0xD2 => try to.writeAll("Ò"),
            0xD3 => try to.writeAll("Ó"),
            0xD4 => try to.writeAll("Ô"),
            0xD5 => try to.writeAll("Õ"),
            0xD6 => try to.writeAll("Ö"),
            0xD7 => try to.writeAll("×"),
            0xD8 => try to.writeAll("Ø"),
            0xD9 => try to.writeAll("Ù"),
            0xDA => try to.writeAll("Ú"),
            0xDB => try to.writeAll("Û"),
            0xDC => try to.writeAll("Ü"),
            0xDD => try to.writeAll("Ý"),
            0xDE => try to.writeAll("Þ"),
            0xDF => try to.writeAll("ß"),
            0xE0 => try to.writeAll("à"),
            0xE1 => try to.writeAll("á"),
            0xE2 => try to.writeAll("â"),
            0xE3 => try to.writeAll("ã"),
            0xE4 => try to.writeAll("ä"),
            0xE5 => try to.writeAll("å"),
            0xE6 => try to.writeAll("æ"),
            0xE7 => try to.writeAll("ç"),
            0xE8 => try to.writeAll("è"),
            0xE9 => try to.writeAll("é"),
            0xEA => try to.writeAll("ê"),
            0xEB => try to.writeAll("ë"),
            0xEC => try to.writeAll("ì"),
            0xED => try to.writeAll("í"),
            0xEE => try to.writeAll("î"),
            0xEF => try to.writeAll("ï"),
            0xF0 => try to.writeAll("ð"),
            0xF1 => try to.writeAll("ñ"),
            0xF2 => try to.writeAll("ò"),
            0xF3 => try to.writeAll("ó"),
            0xF4 => try to.writeAll("ô"),
            0xF5 => try to.writeAll("õ"),
            0xF6 => try to.writeAll("ö"),
            0xF7 => try to.writeAll("÷"),
            0xF8 => try to.writeAll("ø"),
            0xF9 => try to.writeAll("ù"),
            0xFA => try to.writeAll("ú"),
            0xFB => try to.writeAll("û"),
            0xFC => try to.writeAll("ü"),
            0xFD => try to.writeAll("ý"),
            0xFE => try to.writeAll("þ"),
            0xFF => try to.writeAll("ÿ"),
            else => return error.UndefinedIso8859_1Byte, // Other bytes are undefined in ISO-8859-1
        }
    }
}

test "ISO-8859-1 to UTF-8 conversion" {
    const input = [_]u8{
        'H', 0xE9, 'l', 'l', 'o', ',', 0xA0, 'w', 0xF6, 'r', 'l', 'd', '!',
    };
    var reader: std.Io.Reader = .fixed(&input);
    var output_buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output_buffer);

    try iso8859_1ToUtf8(&reader, &writer);
    const result = output_buffer[0..writer.end];

    try std.testing.expectEqualStrings("Héllo, wörld!", result);

    const invalid_input = [_]u8{0x80}; // Undefined byte in ISO-8859-1
    reader = .fixed(&invalid_input);
    try std.testing.expectError(error.UndefinedIso8859_1Byte, iso8859_1ToUtf8(&reader, &writer));
}
