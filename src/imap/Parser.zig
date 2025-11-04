const std = @import("std");
const tokenize = @import("tokenize.zig");
const Tokenizer = tokenize.Tokenizer;
const Token = tokenize.Token;

const Parser = @This();

tokenizer: Tokenizer,

prev: ?Token = null,
curr: ?Token = null,
prev_buf: [256]u8 = undefined,

pub fn init(input: *std.Io.Reader) Parser {
    var tokenizer = Tokenizer.init(input);
    const first_token = tokenizer.next();
    return .{
        .tokenizer = tokenizer,
        .curr = first_token,
    };
}

pub fn hasEnoughBuffer(self: *Parser, size: usize) bool {
    return (self.tokenizer.buffer.len - self.tokenizer.offset) >= size;
}

fn advance(self: *Parser) void {
    self.prev = self.curr;
    self.curr = self.tokenizer.next();
}

pub fn next(self: *Parser) ?Token {
    defer self.advance();
    return self.curr;
}

pub fn peek(self: *Parser) ?Token {
    return self.curr;
}

pub fn peekExpect(self: *Parser, expected: Token.Tag) bool {
    if (self.curr) |token| {
        return token.tag == expected;
    }
    return false;
}

pub fn expect(self: *Parser, expected: Token.Tag) !void {
    defer self.advance();

    if (self.curr) |token| {
        if (token.tag != expected) {
            return error.UnexpectedToken;
        }
    } else {
        return error.EndOfInput;
    }
}

pub fn expectIdentifier(self: *Parser, identifier: []const u8) !void {
    defer self.advance();
    if (self.curr) |token| {
        if (token.tag != .identifier) {
            return error.UnexpectedToken;
        }
        if (!std.mem.eql(u8, self.tokenizer.scratch[token.start..token.end], identifier)) {
            return error.UnexpectedIdentifier;
        }
    } else {
        return error.EndOfInput;
    }
}

pub fn not(self: *Parser, unexpected: Token.Tag) bool {
    if (self.curr) |token| {
        return token.tag != unexpected;
    }
    return true;
}

pub fn get(self: *Parser, expected: Token.Tag) ![]const u8 {
    if (self.curr) |token| {
        if (token.tag != expected) {
            return error.UnexpectedToken;
        }
        const slice = self.tokenizer.scratch[token.start..token.end];
        @memcpy(self.prev_buf[0..slice.len], slice);
        self.advance();
        return self.prev_buf[0..slice.len];
    }
    return error.EndOfInput;
}

pub fn expectAny(self: *Parser, first: Token.Tag, second: Token.Tag) !Token {
    if (self.curr) |token| {
        if (token.tag == first or token.tag == second) {
            self.advance();
            return token;
        }
        return error.UnexpectedToken;
    }
    return error.EndOfInput;
}

pub fn value(self: *Parser) []const u8 {
    return self.tokenizer.scratch[self.curr.?.start..self.curr.?.end];
}

test {
    var input = std.Io.Reader.fixed("S001 OK LOGIN successfully completed\r\n");
    var parser = Parser.init(&input);
    try parser.expectIdentifier("S001");
    try std.testing.expect(parser.not(.keyword_login));
    try parser.expect(.keyword_ok);
    try parser.expect(.keyword_login);
    try std.testing.expectEqual([]const u8, "successfully", try parser.get(.identifier));
    try std.testing.expectEqual([]const u8, "successfully", parser.value());
    try std.testing.expectEqual([]const u8, "completed", try parser.get(.identifier));
    try std.testing.expectEqual([]const u8, "completed", parser.value());
    try parser.expect(.crlf);
}
