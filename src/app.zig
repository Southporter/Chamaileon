const std = @import("std");
const builtin = @import("builtin");
const mailbox = @import("mailbox");
const background = @import("worker.zig");
const dvui = @import("dvui");
const ui = @import("ui.zig");
const Backend = dvui.backend;
comptime {
    std.debug.assert(@hasDecl(Backend, "SDLBackend"));
}
const Config = mailbox.Config;

const log = std.log.scoped(.gui);

// const window_icon_png = @embedFile("zig-favicon.png");

var gpa_instance = std.heap.DebugAllocator(.{}){};
const gpa = gpa_instance.allocator();

const vsync = true;
const show_demo = true;
var scale_val: f32 = 1.0;

var show_dialog_outside_frame: bool = false;

pub fn main() !void {
    std.log.info("SDL version: {f}", .{Backend.getSDLVersion()});

    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");

    if (@import("builtin").os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    // const fira_code_bytes = @embedFile("fonts/FiraCode-Regular.ttf");
    const fira_code_bytes = try loadFont(gpa, "FiraCodeNerdFont_Regular.ttf");
    defer gpa.free(fira_code_bytes);

    // init SDL backend (creates and owns OS window)
    var backend = try Backend.initWindow(.{
        .allocator = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .min_size = .{ .w = 250.0, .h = 350.0 },
        .vsync = vsync,
        .title = "Mailbox",
        // .icon = window_icon_png, // can also call setIconFromFileContent()
    });
    defer backend.deinit();

    _ = Backend.c.SDL_EnableScreenSaver();

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{});
    defer win.deinit();

    const fira_code_cache: dvui.Font.Cache.TTFEntry = .{
        .name = "FiraCode",
        .bytes = fira_code_bytes,
        .allocator = null,
    };
    try win.fonts.database.put(gpa, .fromName("FiraCode"), fira_code_cache);
    win.theme.font_body.id = .fromName("FiraCode");
    _ = try win.fonts.getOrCreate(gpa, win.theme.font_body);
    win.theme.font_title_3.id = .fromName("FiraCode");
    _ = try win.fonts.getOrCreate(gpa, win.theme.font_title_3);
    win.theme.font_title_4.id = .fromName("FiraCode");
    _ = try win.fonts.getOrCreate(gpa, win.theme.font_title_4);

    var running = true;

    const config = try Config.load(gpa);
    defer config.deinit(gpa);
    const worker = try std.Thread.spawn(.{}, background.worker, .{ gpa, config, &running, &win });
    defer worker.join();
    try worker.setName("Mailbox Worker");
    defer {
        log.info("Stopping worker thread", .{});
        background.queue.push(.logout) catch {};
    }

    var interrupted = false;
    var page: ui.Page = .mailbox_select;

    main_loop: while (true) {

        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(interrupted);

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        // send all SDL events to dvui for processing
        const quit = try backend.addAllEvents(&win);
        if (quit) break :main_loop;

        // if dvui widgets might not cover the whole window, then need to clear
        // the previous frame's render
        _ = Backend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 255);
        _ = Backend.c.SDL_RenderClear(backend.renderer);

        // The demos we pass in here show up under "Platform-specific demos"
        page = gui_frame(page);

        // marks end of dvui frame, don't call dvui functions after this
        // - sends all dvui stuff to backend for rendering, must be called before renderPresent()
        const end_micros = try win.end(.{});

        // cursor management
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());

        // render frame to OS
        try backend.renderPresent();

        // waitTime and beginWait combine to achieve variable framerates
        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);

        // Example of how to show a dialog from another thread (outside of win.begin/win.end)
        if (show_dialog_outside_frame) {
            show_dialog_outside_frame = false;
            dvui.dialog(@src(), .{}, .{ .window = &win, .modal = false, .title = "Dialog from Outside", .message = "This is a non modal dialog that was created outside win.begin()/win.end(), usually from another thread." });
        }
    }

    running = false;
}

// both dvui and SDL drawing
fn gui_frame(page: ui.Page) ui.Page {
    if (ui.menu()) |p| {
        return p;
    }

    const next_page = switch (page) {
        .mailbox_select => ui.mailbox_select(gpa, background.state) catch |err| {
            std.log.err("Failed to render mailbox select: {}", .{err});
            return .err;
        },
        .mailbox_list => ui.mailbox_list(gpa, background.state),
        .mail_view => ui.view_mail(gpa, background.state),
        .err => ui.err(),
    };

    dvui.Examples.demo();

    return next_page;
}

const known_folders = @import("known-folders");
fn loadFont(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    // Load fira from local
    var fonts = try known_folders.open(alloc, .home, .{}) orelse return error.FontsFolderNotFound;
    defer fonts.close();

    var dir = try fonts.openDir(".local/share/fonts/f", .{});
    defer dir.close();

    const regular = try dir.openFile(name, .{});
    var bytes = std.Io.Writer.Allocating.init(alloc);
    var buf: [4096]u8 = undefined;
    var reader = regular.reader(&buf);
    _ = try reader.interface.streamRemaining(&bytes.writer);
    try bytes.writer.writeByte(0);
    return bytes.toOwnedSlice();
}

test {
    _ = @import("worker.zig");
}
