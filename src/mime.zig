const std = @import("std");

const DecodeState = enum {
    init,
    eql,
    eql_question,
    eql_hex,
};
fn decode(input: []const u8, output: []u8) ![]u8 {
    const state: DecodeState = .init;
    var i: usize = 0;
    var stream = std.io.fixedBufferStream(output);
    var writer = stream.writer();

    dec: switch (state) {
        .init => switch (input[i]) {
            '=' => {
                i += 1;
                continue :dec .eql;
            },
            else => return input,
        },
        .eql => switch (input[i]) {
            '?' => {
                i += 1;
                continue :dec .eql_question;
            },
            '0'...'9', 'A'...'Z', 'a'...'z' => {
                i += 1;
                continue :dec .eql_hex;
            },
            else => return error.InvalidInput,
        },
        .eql_question => switch (input[i]) {
            else => return error.InvalidInput,
        },
        .copy => {
            switch (input[i]) {
                '=' => {
                    i += 1;
                    continue :dec .eql;
                },
                else => {
                    writer.writeByte(input[i]) catch return error.WriteFailed;
                    i += 1;
                },
            }
        },
        else => return error.InvalidInput,
    }
}

test "decode" {
    const input = "=?us-ascii?Q?This needs to be =28decoded=29?=";
    var output: [256]u8 = undefined;

    const result = try decode(input, output[0..]);
    try std.testing.expectEqualSlices(u8, "This needs to be (decoded)", result);
}
