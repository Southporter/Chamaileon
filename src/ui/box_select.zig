const std = @import("std");
const dvui = @import("dvui");
const background = @import("../worker.zig");

pub fn render(alloc: std.mem.Allocator, state: background.State) !void {
    _ = alloc;
    const boxes = state.boxes;
    if (boxes.len == 0) {
        var text = dvui.textLayout(@src(), .{}, .{});
        defer text.deinit();

        text.addText("No mailboxes found", .{});
        return;
    }

    var choice: usize = 0;
    if (dvui.dropdown(@src(), boxes.items(.name), &choice, .{})) {
        const selected_box = boxes.get(choice);
        return background.queue.push(.{ .select = selected_box });
    }
}
