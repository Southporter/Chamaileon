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
        gui_frame(.mailbox_select);

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

const Page = enum {
    mailbox_select,
};

// both dvui and SDL drawing
fn gui_frame(page: Page) void {
    ui.menu();

    switch (page) {
        .mailbox_select => ui.mailbox_select(gpa, background.state) catch |err| {
            std.log.err("Failed to render mailbox select: {}", .{err});
        },
    }

    // var content = dvui.box(@src(), .horizontal, .{
    //     .expand = .both,
    // });
    // defer content.deinit();
    //
    // {
    //     var list_view = dvui.scrollArea(@src(), .{
    //         .horizontal = .auto,
    //     }, .{
    //         .expand = .vertical,
    //         .color_fill = .fill_window,
    //     });
    //     defer list_view.deinit();
    //
    //     var arena = std.heap.ArenaAllocator.init(gpa);
    //     defer arena.deinit();
    //
    //     for (0..10) |i| {
    //         var item = dvui.box(@src(), .horizontal, .{ .expand = .horizontal, .min_size_content = .{ .h = 30 }, .margin = .{ .x = 4 }, .id_extra = i });
    //         defer item.deinit();
    //
    //         if (dvui.button(@src(), std.fmt.allocPrint(arena.allocator(), "Button {d}", .{i}) catch return, .{}, .{ .id_extra = i })) {
    //             std.log.info("Button {d} clicked", .{i});
    //         }
    //
    //         dvui.label(@src(), "Item {d}", .{i}, .{ .id_extra = i });
    //     }
    // }
    //
    // {
    //     var content_view = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    //     defer content_view.deinit();
    //
    //     var text = dvui.textLayout(@src(), .{}, .{});
    //     defer text.deinit();
    //
    //     text.addText(
    //         \\ This is a test
    //         \\ with a lot of extra text
    //         \\ to show how text layout works in dvui.
    //         \\ It can handle multiple lines
    //         \\ and will automatically wrap text
    //         \\ to fit the available space.
    //         \\
    //     , .{});
    // }
    //
    // look at demo() for examples of dvui widgets, shows in a floating window
    dvui.Examples.demo();
}

test {
    _ = @import("worker.zig");
}
