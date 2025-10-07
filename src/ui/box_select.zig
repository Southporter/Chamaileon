const std = @import("std");
const dvui = @import("dvui");
const background = @import("../worker.zig");
const Page = @import("../ui.zig").Page;

pub fn render(alloc: std.mem.Allocator, state: background.State) !Page {
    _ = alloc;
    var display = dvui.box(@src(), .{
        .dir = .vertical,
    }, .{
        .expand = .both,
        .padding = .{
            .x = 8,
            .y = 8,
        },
    });
    defer display.deinit();

    const boxes = state.boxes;
    if (boxes.len == 0) {
        var container = dvui.flexbox(@src(), .{
            .justify_content = .center,
        }, .{});
        defer container.deinit();
        var text = dvui.textLayout(@src(), .{}, .{});
        defer text.deinit();

        text.addText("No mailboxes found", .{});
        return .mailbox_select;
    }

    {
        var list = dvui.scrollArea(@src(), .{
            .vertical = .auto,
        }, .{
            .expand = .both,
        });
        defer list.deinit();

        for (boxes.items(.name), 0..) |box, i| {
            if (dvui.button(@src(), box, .{}, .{ .expand = .horizontal, .id_extra = i })) {
                const selected_box = boxes.get(i);
                try background.queue.push(.{ .select = selected_box });
                return .mailbox_list;
            }
        }
    }
    return .mailbox_select;
}
