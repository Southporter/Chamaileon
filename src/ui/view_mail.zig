const std = @import("std");
const dvui = @import("dvui");
const background = @import("../worker.zig");
const superhtml = @import("superhtml");
const Page = @import("../ui.zig").Page;
const log = std.log.scoped(.ui_view_mail);

pub fn render(alloc: std.mem.Allocator, state: background.State) Page {
    _ = alloc;
    if (state.visible_mail) |email| {
        var content = dvui.box(@src(), .{
            .dir = .vertical,
        }, .{
            .expand = .both,
            .background = true,
            .color_fill = .white,
        });
        defer content.deinit();

        if (dvui.button(@src(), "Back", .{}, .{ .expand = .none })) {
            return .mailbox_list;
        }

        const active_tab = dvui.dataGetPtrDefault(null, content.data().id, "active_tab", u4, 0);
        {
            var tabs = dvui.TabsWidget.init(@src(), .{}, .{ .expand = .horizontal, .padding = .{
                .h = 5,
                .w = 5,
                .x = 5,
                .y = 5,
            }, .min_size_content = .{ .h = 30.0, .w = 30.0 } });
            tabs.install();
            defer tabs.deinit();
            for (email.parts, 0..) |part, i| {
                if (std.meta.activeTag(part.content) == .unknown) continue;

                if (tabs.addTabLabel(i == active_tab.*, switch (part.content) {
                    .text_plain => "Text",
                    .text_html => "HTML",
                    else => "Other",
                })) {
                    active_tab.* = @truncate(i);
                }
            }
        }

        const view = email.parts[active_tab.*];
        var view_box = dvui.box(@src(), .{
            .dir = .vertical,
        }, .{
            .expand = .both,
        });
        defer view_box.deinit();

        switch (view.content) {
            .text_plain => |text| {
                var header_box = dvui.box(@src(), .{
                    .dir = .vertical,
                }, .{ .expand = .horizontal, .margin = .all(4), .color_border = .black, .border = .all(1) });
                var header_layout = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
                header_layout.format("Encoding: {t} / Charset: {t}", .{ view.content_encoding, view.charset }, .{});
                header_layout.deinit();
                header_box.deinit();

                var scroll = dvui.scrollArea(@src(), .{
                    .vertical = .auto,
                }, .{ .expand = .both });
                defer scroll.deinit();
                var text_layout = dvui.textLayout(@src(), .{}, .{ .expand = .both });
                defer text_layout.deinit();

                var iter = std.mem.splitSequence(u8, text, "\r\n");
                var link_id: usize = 42;
                while (iter.next()) |line| {
                    var start: usize = 0;
                    // var parts = std.mem.splitScalar(u8, line, ' ');
                    // const first = parts.next() orelse continue; // Skip empty lines
                    // //
                    const options: dvui.Options = .{};
                    // TODO: Add Mardown viewing support
                    //
                    // const header_depth = std.mem.count(u8, first, "#"); // Check for markdown header
                    // switch (header_depth) {
                    //     1 => options.font_style = .title_1,
                    //     2 => options.font_style = .title_2,
                    //     3 => options.font_style = .title_3,
                    //     4 => options.font_style = .title_4,
                    //     5 => options.font_style = .heading,
                    //     6 => options.font_style = .caption_heading,
                    //     else => {},
                    // }
                    // const quote_depth = std.mem.count(u8, line, ">"); // Check for blockquote
                    // if (quote_depth > 0) {
                    //     options.margin = .{
                    //         .x = 16,
                    //         .w = 4,
                    //         .h = 0,
                    //         .y = 0,
                    //     };
                    //     options.border = .{ .x = 4 };
                    // }
                    //
                    // start = parts.index orelse 0;

                    while (std.mem.indexOf(u8, line[start..], "https://")) |link_start_rel| {
                        defer link_id += 1;
                        const link_start = start + link_start_rel;
                        const link_end = std.mem.indexOfAny(u8, line[link_start..], " \t") orelse line.len - link_start;
                        const url = line[link_start .. link_end + link_start];
                        var options_with_id_extra = options;
                        options_with_id_extra.id_extra = link_id;
                        if (std.mem.eql(u8, line[link_start -| 2..link_start], "](")) {
                            // Find start of markdown link
                            const md_link_start = std.mem.lastIndexOf(u8, line[0 .. link_start - 2], "[") orelse 0;
                            text_layout.addText(line[start..md_link_start], options);
                            text_layout.addLink(.{
                                .url = url,
                                .text = line[md_link_start + 1 .. link_start - 2],
                            }, options_with_id_extra);
                        } else {
                            text_layout.addText(line[start..link_start], options);
                            text_layout.addLink(.{
                                .url = url,
                            }, options_with_id_extra);
                        }
                        start = link_start + link_end;
                    }
                    text_layout.addText(line[start..], options);
                    text_layout.addText("\n", options);
                }
            },
            .text_html => |html| {
                var scroll = dvui.scrollArea(@src(), .{
                    .vertical = .auto,
                }, .{ .expand = .both });
                defer scroll.deinit();
                // if (html.ast.has_syntax_errors) {
                //     var text_layout = dvui.textLayout(@src(), .{}, .{ .expand = .both });
                //     defer text_layout.deinit();
                //     text_layout.addText("(HTML Content - rendering failed)\n", .{});
                //     text_layout.addText("Syntax Errors:\n", .{});
                //     for (html.ast.errors) |err| {
                //         text_layout.format(" - {f}\n", .{err.tag.fmt(html.src)}, .{});
                //     }
                // } else {
                const root = html.ast.nodes[0];
                std.debug.assert(root.kind == .root);
                renderHtmlNode(html.ast, root, html.src);

                if (dvui.expander(@src(), "Show HTML Source", .{}, .{ .expand = .horizontal })) {
                    var src_box = dvui.box(@src(), .{
                        .dir = .vertical,
                    }, .{ .expand = .both, .margin = .all(4), .border = .all(2), .color_border = .green });
                    defer src_box.deinit();
                    var src_view = dvui.textLayout(@src(), .{}, .{ .expand = .both });
                    defer src_view.deinit();
                    src_view.addText("--- HTML Source ---\n", .{});
                    var iter = std.mem.splitSequence(u8, html.src, "\r\n");
                    while (iter.next()) |line| {
                        src_view.addText(line, .{});
                        src_view.addText("\n", .{});
                    }
                }

                // }
            },
            else => {
                var text_layout = dvui.textLayout(@src(), .{}, .{ .expand = .both });
                defer text_layout.deinit();
                text_layout.addText("(Unsupported Content Type)", .{});
            },
        }
    }
    return .mail_view;
}

fn renderHtmlNode(ast: *superhtml.html.Ast, node: superhtml.html.Ast.Node, src: []const u8) void {
    log.debug("Rendering HTML node of kind {t}", .{node.kind});
    switch (node.kind) {
        .root => {
            if (ast.child(node)) |child| {
                log.debug("Rendering {t} child node: {t}", .{ node.kind, child.kind });
                renderHtmlNode(ast, child, src);
                var next = ast.nextSibling(node);
                while (next) |n| {
                    log.debug("Rendering {t} child sibling node: {t}", .{ node.kind, n.kind });
                    renderHtmlNode(ast, n, src);
                    next = ast.nextSibling(n);
                }
            }
            if (ast.nextSibling(node)) |sibling| {
                log.debug("Rendering {t} sibling node: {t}", .{ node.kind, sibling.kind });
                renderHtmlNode(ast, sibling, src);
            }
        },
        .doctype, .html, .head, .body => {
            if (ast.child(node)) |child| {
                log.debug("Rendering {t} child node: {t}", .{ node.kind, child.kind });
                renderHtmlNode(ast, child, src);
                var next = ast.nextSibling(node);
                while (next) |n| {
                    log.debug("Rendering {t} child sibling node: {t}", .{ node.kind, n.kind });
                    renderHtmlNode(ast, n, src);
                    next = ast.nextSibling(n);
                }
            }
        },
        .super => {},
        .div => {
            var box = dvui.box(@src(), .{}, .{});
            defer box.deinit();
            if (ast.child(node)) |child| {
                renderHtmlNode(ast, child, src);
                var next = ast.nextSibling(node);
                while (next) |n| {
                    log.debug("Rendering div child sibling node: {t}", .{n.kind});
                    renderHtmlNode(ast, n, src);
                    next = ast.nextSibling(n);
                }
            }
        },
        .input => {
            const input = dvui.textEntry(@src(), .{}, .{ .expand = .horizontal });
            defer input.deinit();
            dvui.label(@src(), "(Input Field)", .{}, .{ .expand = .none });
        },
        .button => {
            if (dvui.button(@src(), "Button", .{}, .{ .expand = .none })) {
                log.info("HTML Button clicked", .{});
            }
            if (ast.child(node)) |child| {
                renderHtmlNode(ast, child, src);
            }
        },
        .text => {
            const text_content = node.span(src).slice(src);
            var text_layout = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer text_layout.deinit();
            text_layout.addText(text_content, .{});
        },
        .p => {
            log.debug("Rendering <p> node", .{});
            if (ast.child(node)) |child| {
                log.debug("Rendering <p> child: {t}", .{child.kind});
                renderHtmlNode(ast, child, src);
                var next = ast.nextSibling(node);
                while (next) |n| {
                    log.debug("Rendering <p> child sibling: {t}", .{n.kind});
                    renderHtmlNode(ast, n, src);
                    next = ast.nextSibling(n);
                }
            }
            dvui.label(@src(), "\n", .{}, .{ .expand = .none });
        },
        else => |kind| {
            log.debug("Rendering HTML node of kind {t} unimplemented", .{kind});
        },
    }
}
