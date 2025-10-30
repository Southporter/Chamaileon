const std = @import("std");
const dvui = @import("dvui");
const background = @import("../worker.zig");
const Page = @import("../ui.zig").Page;

pub fn render(alloc: std.mem.Allocator, state: background.State) Page {
    _ = alloc;
    if (state.preview) |preview| {
        var content = dvui.box(@src(), .{
            .dir = .vertical,
        }, .{
            .expand = .both,
            .background = true,
            .color_fill = .white,
        });
        defer content.deinit();
        var scroll = dvui.scrollArea(@src(), .{
            .vertical = .auto,
        }, .{ .expand = .both });
        defer scroll.deinit();

        var date_buf: [64]u8 = undefined;
        for (preview.mail.items) |item| {
            const id_extra = @intFromEnum(item.uid);
            var item_box = dvui.box(@src(), .{
                .dir = .vertical,
            }, .{
                .expand = .horizontal,
                .margin = .all(4),
                .id_extra = id_extra,
                .color_border = .teal,
                .border = .all(2),
            });
            defer item_box.deinit();

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
        var back = dvui.box(@src(), .{}, .{ .expand = .both });
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
