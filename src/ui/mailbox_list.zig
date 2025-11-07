const std = @import("std");
const dvui = @import("dvui");
const background = @import("../worker.zig");
const Page = @import("../ui.zig").Page;

pub fn render(alloc: std.mem.Allocator, state: background.State) Page {
    _ = alloc;
    if (state.preview) |preview| {
        const win = dvui.currentWindow();
        const move_highlight: enum { up, down, none } = .none;
        for (win.events.items) |event| {
            switch (event.evt) {
                .key => |key| {
                    // consume alt key events to avoid them propagating to other widgets
                    if (key.code == .h and key.mod.shiftOnly()) {
                        return .mailbox_select;
                    }
                    if ((key.code == .up or key.code == .j) and key.mod == .none) {
                        move_highlight = .up;
                    } else if ((key.code == .down or key.code == .k) and key.mod == .none) {
                        move_highlight = .down;
                    }
                },
                else => {},
            }
        }
        var content = dvui.box(@src(), .{
            .dir = .vertical,
        }, .{
            .expand = .both,
            .background = true,
            .color_fill = .white,
        });
        defer content.deinit();

        const highligted = dvui.dataGetPtrDefault(null, content.data().id, "highlighted_mail", usize, 0);
        if (move_highlight == .up) {
            highligted.* -|= 1;
        } else if (move_highlight == .down) {
            const next = highligted.* + 1;
            highligted.* = @min(next, preview.mail.items.len - 1);
        }

        var scroll = dvui.scrollArea(@src(), .{
            .vertical = .auto,
        }, .{ .expand = .both });
        defer scroll.deinit();

        var date_buf: [64]u8 = undefined;
        for (preview.mail.items, 0..) |item, index| {
            const id_extra = @intFromEnum(item.uid);
            var item_box = dvui.box(@src(), .{
                .dir = .vertical,
            }, .{
                .expand = .horizontal,
                .margin = .all(4),
                .id_extra = id_extra,
                .color_border = if (index == highligted.*) .teal else .gray,
                .border = .all(2),
            });
            defer item_box.deinit();
            if (index == highligted.*) {
                scroll.init_opts.focus_id = item_box.data().id;
            }

            if (dvui.clicked(&item_box.wd, .{})) {
                std.log.info("Item {d} clicked", .{item.uid});
                background.queue.push(.{ .fetch = item.uid }) catch |err| {
                    std.log.err("Failed to push to queue: {}", .{err});
                    break;
                };
                return .mail_view;
            }

            var writer = std.Io.Writer.fixed(&date_buf);
            item.date.time().strftime(&writer, "%Y-%m-%d %H:%M") catch unreachable;

            dvui.label(@src(), "{s}", .{item.subject}, .{ .id_extra = @intFromEnum(item.uid), .font_style = .title_3 });
            var details_box = dvui.box(@src(), .{
                .dir = .horizontal,
            }, .{
                .expand = .horizontal,
                .id_extra = id_extra,
            });
            defer details_box.deinit();
            dvui.label(@src(), "From: {s}", .{item.from}, .{ .id_extra = id_extra, .font_style = .title_4 });
            dvui.label(@src(), "{s}", .{date_buf[0..writer.end]}, .{ .id_extra = id_extra, .font_style = .title_4 });
        }
        return .mailbox_list;
    } else {
        var back = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = .white });
        defer back.deinit();
        var container = dvui.flexbox(@src(), .{
            .justify_content = .center,
        }, .{ .expand = .both });
        defer container.deinit();
        dvui.spinner(@src(), .{});
        var text = dvui.textLayout(@src(), .{}, .{});
        defer text.deinit();

        text.addText("Loading Mail", .{});
        return .mailbox_list;
    }
}
