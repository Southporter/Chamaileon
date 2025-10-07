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
        });
        defer content.deinit();

        var date_buf: [64]u8 = undefined;
        for (preview.mail.items) |item| {
            var item_box = dvui.box(@src(), .{
                .dir = .vertical,
            }, .{ .expand = .horizontal, .min_size_content = .{ .h = 30 }, .margin = .{ .x = 4 }, .id_extra = item.uid });
            defer item_box.deinit();

            if (dvui.button(@src(), item.subject, .{}, .{
                .id_extra = item.uid,
            })) {
                std.log.info("Item {d} clicked", .{item.uid});
            }

            var writer = std.Io.Writer.fixed(&date_buf);
            item.date.time().strftime(&writer, "%Y-%m-%d %H:%M") catch unreachable;

            dvui.label(@src(), "From: {s}", .{item.from}, .{ .id_extra = item.uid });
            dvui.label(@src(), "Date: {s}", .{date_buf[0..writer.end]}, .{ .id_extra = item.uid });
        }
        return .mailbox_list;
    } else {
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
