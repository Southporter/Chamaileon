const std = @import("std");
const tokenize = @import("tokenize.zig");
const Tokenizer = tokenize.Tokenizer;
const Token = tokenize.Token;

const Parser = @This();

tokenizer: Tokenizer,

prev: ?Token = null,
curr: ?Token = null,

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
    self.advance();
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
    return false;
}

pub fn get(self: *Parser, expected: Token.Tag) ![]const u8 {
    if (self.curr) |token| {
        if (token.tag != expected) {
            return error.UnexpectedToken;
        }
        const slice = self.tokenizer.scratch[token.start..token.end];
        self.advance();
        return slice;
    }
    return error.EndOfInput;
}

pub fn value(self: *Parser, tok: Token) []const u8 {
    return self.tokenizer.buffer[tok.start..tok.end];
}
