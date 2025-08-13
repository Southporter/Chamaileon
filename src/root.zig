const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.mailbox);

pub const Config = @import("Config.zig");
pub const ImapSession = @import("imap/Session.zig");

test {
    _ = @import("imap/Session.zig");
    _ = @import("imap/Capability.zig");
    _ = @import("imap/ResponseParser.zig");
    _ = @import("imap/tokenize.zig");
}
