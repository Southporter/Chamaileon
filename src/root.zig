const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.mailbox);
const imap = @import("imap");

pub const Config = @import("Config.zig");
pub const ImapSession = imap.Session;
pub const Uid = ImapSession.Uid;
pub const Email = imap.Email;
