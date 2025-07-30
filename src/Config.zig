const std = @import("std");
const Config = @This();
const known_folders = @import("known-folders");

username: []const u8,
password: []const u8,

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
        return .{
            .username = allocator.dupe(u8, local_config.username) catch return error.OutOfMemory,
            .password = allocator.dupe(u8, local_config.password) catch return error.OutOfMemory,
        };
    }
    return error.HomeDirNotFound;
}

pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
    allocator.free(self.username);
    allocator.free(self.password);
}
