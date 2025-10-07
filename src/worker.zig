const std = @import("std");
const mailbox = @import("mailbox");
const log = std.log.scoped(.worker);
const dvui = @import("dvui");

const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    messages: [8]Message = undefined,
    read_index: u8 = 0,
    write_index: u8 = 0,

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
        self.mutex.lock();
        self.mutex.unlock();
        self.cond.signal();
    }
    fn isEmpty(self: *Queue) bool {
        return self.read_index == self.write_index;
    }

    pub fn pop(self: *Queue, timeout: u64) ?Message {
        if (self.isEmpty()) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.timedWait(&self.mutex, timeout) catch {};
        }
        if (self.isEmpty()) {
            return null;
        }
        const msg = self.messages[self.read_index];
        self.read_index += 1;
        if (self.read_index >= self.messages.len) {
            self.read_index = 0;
        }
        return msg;
    }
};

const Message = union(enum) {
    logout: void,
    select: mailbox.ImapSession.Box,
};

pub var queue: Queue = .{};

pub var state: State = .{};

pub const State = struct {
    lock: std.Thread.RwLock = .{},
    boxes: std.MultiArrayList(mailbox.ImapSession.Box) = .empty,
    data: Data = .{},
    details: ?mailbox.ImapSession.MailboxDetails = null,
    preview: ?mailbox.ImapSession.PreviewResult = null,

    const Data = struct {
        details: []const u8 = "",
    };

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        @breakpoint();
        self.lock.lock();
        defer self.lock.unlock();
        self.boxes.deinit(alloc);
        if (self.preview) |p| {
            p.deinit(alloc);
            self.preview = null;
        }
        if (self.details) |d| {
            d.deinit(alloc);
            self.details = null;
        }
    }
};

pub fn worker(alloc: std.mem.Allocator, config: mailbox.Config, running: *bool, win: *dvui.Window) void {
    log.info("Starting Mailbox Worker", .{});
    var ca_bundle = std.crypto.Certificate.Bundle{};
    defer ca_bundle.deinit(alloc);
    ca_bundle.rescan(alloc) catch |err| {
        std.log.err("Failed to rescan CA bundle: {}", .{err});
        return;
    };

    log.info("Connecting to the server", .{});

    var session: mailbox.ImapSession = undefined;
    if (config.port == 993) session.connectTls(alloc, .{
        .host = config.hostname,
        .port = config.port,
        .ca_bundle = ca_bundle,
    }) catch |err| {
        std.log.err("Failed to connect to IMAP server: {}", .{err});
        return;
    } else session.connect(alloc, .{ .host = config.hostname, .port = config.port, .ca_bundle = undefined }) catch |err| {
        std.log.err("Failed to connect to IMAP server: {}", .{err});
        return;
    };
    defer session.disconnect(alloc);
    {
        state.lock.lock();
        defer state.lock.unlock();
        state.data.details = session.info;
    }
    if (config.port != 993) {
        log.info("Server supports STARTTLS", .{});
        // TODO: Check capabilities before starting TLS
        session.startTls(.{ .host = config.hostname, .port = config.port, .ca_bundle = ca_bundle }) catch |err| {
            std.log.err("Failed to start TLS: {}", .{err});
            return;
        };
    }
    const cap = session.capability(alloc) catch |err| {
        std.log.err("Failed to get server capabilities: {}", .{err});
        return;
    };
    if (!cap.has(.auth_plain)) {
        std.log.err("Server does not support PLAIN authentication", .{});
        return;
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

    var box_arena = std.heap.ArenaAllocator.init(alloc);
    blk: {
        log.info("Authentication successful", .{});
        const res = session.list(box_arena.allocator(), "", "*") catch |err| {
            std.log.err("Failed to list mailboxes: {}", .{err});
            break :blk;
        };
        state.lock.lock();
        state.boxes = res.boxes;
        state.lock.unlock();

        dvui.refresh(win, @src(), @enumFromInt(13131313));
    }
    defer box_arena.deinit();

    while (running.*) {
        const start = std.time.milliTimestamp();
        if (queue.pop(std.time.ns_per_min * 1)) |msg| {
            const elapsed = std.time.milliTimestamp() - start;
            log.info("Message received after {d} ms: {any}", .{ elapsed, msg });
            switch (msg) {
                .logout => {
                    return;
                },
                .select => {
                    log.info("Selecting mailbox: {s}", .{msg.select.name});
                    const details = session.select(msg.select) catch |err| {
                        log.err("Failed to select mailbox '{s}': {any}", .{ msg.select.name, err });
                        continue;
                    };
                    log.info("Mailbox '{s}' selected successfully", .{msg.select.name});
                    {
                        state.lock.lock();
                        defer state.lock.unlock();
                        state.details = details;
                    }

                    log.info("Fetching mailbox details for '{f}'", .{details});
                    const preview = session.preview(alloc, .{ .min = 1, .max = details.exists }) catch |err| {
                        log.err("Failed to fetch mailbox details: {}", .{err});
                        continue;
                    };
                    {
                        state.lock.lock();
                        defer state.lock.unlock();
                        state.preview = preview;
                    }
                    dvui.refresh(win, @src(), @enumFromInt(13131313));

                    log.info("Fetched mailbox details for '{f}'", .{preview});
                },
            }
        } else {
            const elapsed = std.time.milliTimestamp() - start;
            log.info("No messages received after {} ms, sending NOOP", .{elapsed});
            session.noop() catch |err| {
                log.err("Failed to send NOOP command: {}", .{err});
            };
        }
    }
}

test "Queue" {
    var q = Queue{};

    try std.testing.expect(q.isEmpty());

    try std.testing.expectEqual(q.pop(10), null);
    try q.push(.{ .logout = {} });
    try std.testing.expect(!q.isEmpty());
    const start = std.time.nanoTimestamp();
    const msg = q.pop(1000);
    const elapsed = std.time.nanoTimestamp() - start;
    errdefer std.debug.print("Elapsed time: {d} ns\n", .{elapsed});
    try std.testing.expect(elapsed < 500);
    try std.testing.expectEqual(msg.?, Message{ .logout = {} });

    try std.testing.expect(q.isEmpty());
    const start2 = std.time.nanoTimestamp();
    const msg2 = q.pop(1000);
    const elapsed2 = std.time.nanoTimestamp() - start2;
    try std.testing.expectEqual(msg2, null);
    try std.testing.expect(elapsed2 > 500);

    try std.testing.expect(q.isEmpty());
    const select = Message{
        .select = mailbox.ImapSession.Box{
            .folder = "/",
            .name = "INBOX",
            .flags = .{},
        },
    };
    try q.push(select);
    try q.push(.{ .logout = {} });
    const start3 = std.time.nanoTimestamp();
    const msg3 = q.pop(1000);
    const elapsed3 = std.time.nanoTimestamp() - start3;
    try std.testing.expectEqual(msg3.?, select);
    try std.testing.expect(elapsed3 < 500);
}
