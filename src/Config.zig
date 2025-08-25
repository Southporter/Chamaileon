const std = @import("std");
const Config = @This();
const known_folders = @import("known-folders");
const log = std.log.scoped(.config);

username: []const u8,
password: []const u8,
hostname: []const u8 = "imap.gmail.com",
port: u16 = 993,

pub fn load(allocator: std.mem.Allocator) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const home_dir = try known_folders.open(alloc, .home, .{ .access_sub_paths = true });
    if (home_dir) |home| {
        const config_data = try home.openFile(".config/mailbox/config.zon", .{ .mode = .read_only });
        const config_bytes = try config_data.readToEndAllocOptions(alloc, 2048, 64, @alignOf([:0]u8), 0);
        var status: std.zon.parse.Status = .{};
        const local_config = std.zon.parse.fromSlice(Config, alloc, config_bytes, &status, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.ParseZon => {
                std.log.err("Failed to parse config: {}", .{status});
                return error.ParseError;
            },
            else => return err,
        };
        const bytes = try alloc.alloc(u8, local_config.username.len + local_config.password.len + local_config.hostname.len);
        log.info("CONFIG: ALLOCATED {d} BYTES {d}", .{ bytes.len, @intFromPtr(bytes.ptr) });
        @memcpy(bytes[0..local_config.username.len], local_config.username);
        @memcpy(bytes[local_config.username.len .. local_config.username.len + local_config.password.len], local_config.password);
        @memcpy(bytes[local_config.username.len + local_config.password.len ..], local_config.hostname);
        return .{
            .username = bytes[0..local_config.username.len],
            .password = bytes[local_config.username.len .. local_config.username.len + local_config.password.len],
            .hostname = bytes[local_config.username.len + local_config.password.len ..],
            .port = local_config.port,
        };
    }
    return error.HomeDirNotFound;
}

pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
    const bytes = self.username.ptr[0 .. self.username.len + self.password.len + self.hostname.len];
    log.info("CONFIG: FREEING {d} BYTES {d}", .{ bytes.len, @intFromPtr(bytes.ptr) });
    allocator.free(bytes);
}
