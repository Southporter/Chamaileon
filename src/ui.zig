pub const dvui = @import("dvui");
pub const mailbox_select = @import("ui/box_select.zig").render;
pub const mailbox_list = @import("ui/mailbox_list.zig").render;

pub const Page = enum {
    mailbox_select,
    mailbox_list,
    err,
};

pub fn menu() void {
    var m = dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
    defer m.deinit();

    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Close Menu", .{}, .{}) != null) {
            m.close();
        }
    }

    if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        _ = dvui.menuItemLabel(@src(), "Dummy", .{}, .{ .expand = .horizontal });
        _ = dvui.menuItemLabel(@src(), "Dummy Long", .{}, .{ .expand = .horizontal });
        _ = dvui.menuItemLabel(@src(), "Dummy Super Long", .{}, .{ .expand = .horizontal });
    }
    if (dvui.menuItemLabel(@src(), "Demo", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        const label = if (dvui.Examples.show_demo_window) "Hide Demo Window" else "Show Demo Window";
        if (dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal }) != null) {
            dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
        }
    }
}

pub fn err() Page {
    var text = dvui.textLayout(@src(), .{}, .{});
    defer text.deinit();

    text.addText("An error occurred, please restart the application", .{});
    return .err;
}
