const std = @import("std");
const mailbox = @import("mailbox");
const log = std.log.scoped(.worker);

const Queue = struct {
    lock: std.atomic.Value(u32) = .init(0),
    messages: [8]Message = undefined,
    read_index: u8 = 0,
    write_index: u8 = 0,

    const WAKE_VALUE: u32 = 3232;

    pub fn push(self: *Queue, msg: Message) !void {
        if (self.read_index == self.write_index + 1) {
            return error.QueueFull; // Queue is full
        }
        std.debug.assert(self.write_index < self.messages.len);
        self.messages[self.write_index] = msg;
        self.write_index += 1;
        if (self.write_index >= self.messages.len) {
            self.write_index = 0;
        }
        self.lock.store(WAKE_VALUE, .release);
    }
    pub fn pushImmediate(self: *Queue, msg: Message) void {
        self.messages[self.read_index] = msg;
        self.lock.store(WAKE_VALUE, .release);
    }

    fn isEmpty(self: *Queue) bool {
        return self.read_index == self.write_index;
    }

    pub fn pop(self: *Queue, timeout: u64) ?Message {
        if (self.isEmpty()) {
            std.Thread.Futex.timedWait(&self.lock, WAKE_VALUE, timeout) catch {};
        }
        if (self.isEmpty()) {
            return null;
        }
        self.lock.store(0, .release);
        const msg = self.messages[self.read_index];
        self.read_index += 1;
        if (self.read_index >= self.messages.len) {
            self.read_index = 0;
        }
        if (self.read_index == self.write_index) {}
        return msg;
    }
};

const Message = union(enum) {
    logout: void,
};

pub var queue: Queue = .{};

pub var state: State = .{};

pub const State = struct {
    lock: std.Thread.RwLock = .{},
    boxes: std.ArrayList([]const u8) = .empty,
    data: Data = .{},

    const Data = struct {
        host: []const u8 = "",
        port: usize = 993,
        details: []const u8 = "",
    };
};

pub fn worker(alloc: std.mem.Allocator, config: mailbox.Config) void {
    log.info("Starting Mailbox Worker", .{});
    var ca_bundle = std.crypto.Certificate.Bundle{};
    defer ca_bundle.deinit(alloc);
    ca_bundle.rescan(alloc) catch |err| {
        std.log.err("Failed to rescan CA bundle: {}", .{err});
        return;
    };

    log.info("Connecting to the server", .{});
    var session = mailbox.ImapSession.connectTls(alloc, .{
        .host = "imap.gmail.com",
        .ca_bundle = ca_bundle,
    }) catch |err| {
        std.log.err("Failed to connect to IMAP server: {}", .{err});
        return;
    };
    defer session.disconnect(alloc);
    {
        state.lock.lock();
        defer state.lock.unlock();

        state.data.host = "imap.gmail.com";
        state.data.port = 993;
        state.data.details = session.info;
    }

    log.info("Authenticating", .{});
    session.authenticatePlain(
        alloc,
        config.username,
        config.password,
    ) catch |err| {
        std.log.err("Failed to authenticate: {}", .{err});
        return;
    };
    defer session.logout();

    log.info("Authentication successful", .{});


    while (true) {
        if (queue.pop(std.time.ns_per_s * 5)) |msg| {
            switch (msg) {
                .logout => {
                    return;
                },
            }
        } else {
            session.noop() catch |err| {
                log.err("Failed to send NOOP command: {}", .{err});
            };
        }
    }
}
