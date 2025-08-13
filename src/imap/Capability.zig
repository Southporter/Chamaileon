const std = @import("std");

pub const Capability = enum(u16) {
    login = 16,
    login_disabled,
    auth_plain,
    auth_login,
    auth_xoauth2,
    starttls,
    _,
};

const Capabilities = @This();

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

pub fn parseCapabilities(alloc: std.mem.Allocator, cap_str: []const u8) !Capabilities {
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
        } else if (std.mem.eql(u8, name, "STARTTLS")) {
            capabilities.tags.insert(.starttls);
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

pub fn has(self: Capabilities, cap: Capability) bool {
    return self.tags.contains(cap);
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
