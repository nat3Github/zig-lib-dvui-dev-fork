var line_height_factor: f32 = 1.2;
var underline_thick: f32 = 0.0;
var strike_thick: f32 = 0.0;
var wght_axis: f32 = 400;
var multi_script_font_size: f32 = 18;
var multi_script_family_choice: usize = 0;
var variable_font_registered = false;
/// Registered stack alias, first entry in the family dropdown below.
const demo_stack_alias = "Demo Stack (Aleo + Noto KR)";
/// Dropdown entries: the 5 CSS generics, then every family this device
/// actually has installed (`dvui.Font.systemFamilies`), enumerated once --
/// the OS query walks the whole font catalog, too slow to redo per frame.
var family_choices: ?[]const []const u8 = null;
var family_choices_buf: [1024][]const u8 = undefined;
var family_names_storage: [64 * 1024]u8 = undefined;
var manifest_font_state: enum { unresolved, loaded, failed } = .unresolved;
var manifest_woff2_font_state: enum { unresolved, loaded, failed } = .unresolved;

/// css2-API-style manifest (family name -> variants -> font URL); see
/// `opentype.discovery_manifest.ManifestSource`. Points at a real,
/// statically-hosted OFL font so the demo can fetch it over HTTP.
const manifest_test_fixture =
    \\{
    \\  "families": [
    \\    {
    \\      "name": "Tinos",
    \\      "variants": [
    \\        {"weight": 400, "style": "normal", "url": "https://raw.githubusercontent.com/google/fonts/main/ofl/tinos/Tinos-Regular.ttf"}
    \\      ]
    \\    }
    \\  ]
    \\}
;

/// Same font, WOFF2-encoded (Google Fonts' actual serving format) -- exercises
/// the `opentype` WOFF2 decoder end to end, which the plain-.ttf fixture above
/// never touches. Requires the library built with `-Dwoff2=true`; otherwise
/// `resolveManifestFont` fails with `error.Woff2NotSupported`, same as any
/// other unsupported-format failure.
const manifest_woff2_test_fixture =
    \\{
    \\  "families": [
    \\    {
    \\      "name": "Tinos WOFF2",
    \\      "variants": [
    \\        {"weight": 400, "style": "normal", "url": "https://fonts.gstatic.com/s/tinos/v26/buE4poGnedXvwjX7fmQ.woff2"}
    \\      ]
    \\    }
    \\  ]
    \\}
;

/// ![image](Examples-text_layout.png)
pub fn layoutText() void {
    // Register a variable font once so the wght slider below has an fvar axis
    // to move. Bytes are embedded (static), so pass null allocator.
    if (!variable_font_registered) {
        dvui.addFont("Aleo VF", @embedFile("../fonts/Aleo/Aleo-VariableFont_wght.ttf"), null) catch {};
        dvui.addFont("Noto Sans KR", @embedFile("../fonts/NotoSansKR-Regular.ttf"), null) catch {};
        // An explicit family stack (CSS font-family model): Latin from Aleo,
        // Hangul from Noto Sans KR, everything else from whatever the OS
        // calls sans-serif. The KR slot is scaled down because Noto's
        // Hangul runs visually larger than Aleo's Latin at the same size.
        dvui.addFontFamilyEntries(demo_stack_alias, &.{
            .{ .family = dvui.Font.array("Aleo VF") },
            .{ .family = dvui.Font.array("Noto Sans KR"), .size_scale = 0.85 },
            .{ .family = dvui.Font.array("sans-serif") },
        }) catch {};
        variable_font_registered = true;
    }
    {
        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer box.deinit();

        const show_large_doc: *bool = dvui.dataGetPtrDefault(null, box.data().id, "show_large_doc", bool, false);
        const show_multi_script: *bool = dvui.dataGetPtrDefault(null, box.data().id, "show_multi_script", bool, false);

        {
            var vbox = dvui.box(@src(), .{}, .{});
            defer vbox.deinit();

            _ = dvui.sliderEntry(@src(), "line height: {d:0.2}", .{ .value = &line_height_factor, .min = 0.1, .max = 2, .interval = 0.1 }, .{});
            _ = dvui.sliderEntry(@src(), "underline thick: {d:0.2}", .{ .value = &underline_thick, .min = 0.00, .max = 1.0, .interval = 0.01 }, .{});
            _ = dvui.sliderEntry(@src(), "strike thick: {d:0.2}", .{ .value = &strike_thick, .min = 0.00, .max = 1.0, .interval = 0.01 }, .{});
            _ = dvui.sliderEntry(@src(), "weight axis: {d:0.0}", .{ .value = &wght_axis, .min = 100, .max = 900, .interval = 1 }, .{});
        }

        if (dvui.button(@src(), "Multi-Script", .{}, .{ .gravity_x = 1.0 })) {
            show_multi_script.* = !show_multi_script.*;
        }

        if (dvui.button(@src(), "Large Doc", .{}, .{ .gravity_x = 1.0 })) {
            show_large_doc.* = !show_large_doc.*;
        }

        if (show_multi_script.*) {
            var fw = dvui.floatingWindow(@src(), .{}, .{ .max_size_content = .width(500) });
            defer fw.deinit();
            fw.dragAreaSet(dvui.windowHeader("Multi-Script (system fonts)", "", show_multi_script));

            // A single font is used for every sample line below; whatever
            // its family (or generic alias) doesn't cover goes to dvui's
            // dynamic OS-fallback (Font.Cache.discoverDynamicFallback). The
            // label after each script name is the font that actually renders
            // it -- shown so a broken/absent fallback (wrong font, or "no
            // fallback available") is visible here instead of only showing
            // up as tofu boxes in the sample text.
            const families = family_choices orelse blk: {
                family_choices_buf[0] = demo_stack_alias;
                const generics = dvui.Font.generic_families;
                for (generics, 0..) |g, i| family_choices_buf[1 + i] = g;
                var head = 1 + generics.len;
                // CoreText hides the system UI font from
                // CTFontManagerCopyAvailableFontFamilyNames, so SF never shows
                // up below -- but "System Font" still resolves by name.
                if (@import("builtin").os.tag.isDarwin()) {
                    family_choices_buf[head] = "System Font";
                    head += 1;
                }
                const system = dvui.Font.systemFamilies(
                    family_choices_buf[head..],
                    &family_names_storage,
                    dvui.currentWindow().gpa,
                );
                family_choices = family_choices_buf[0 .. head + system.len];
                break :blk family_choices.?;
            };
            {
                // Must be a sibling of the scroll area/text layout below, not
                // a child of `mtl` -- TextLayoutWidget.rectFor only places
                // children at its 4 corners (for overlay buttons), so a plain
                // flow widget placed inside it lands on top of/under the text.
                var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer hbox.deinit();
                _ = dvui.sliderEntry(@src(), "font size: {d:0.0}", .{ .value = &multi_script_font_size, .min = 8, .max = 48, .interval = 1 }, .{ .gravity_y = 0.5 });
                _ = dvui.dropdown(@src(), families, .{ .choice = &multi_script_family_choice }, .{}, .{ .gravity_y = 0.5 });

                // Fetch only on explicit click, not every time this panel is
                // shown -- resolveManifestFont blocks the UI thread on a
                // synchronous HTTP GET, which would freeze the whole app
                // (including its first frame, if this panel is open by
                // default) for as long as the network call takes.
                if (manifest_font_state == .unresolved and dvui.button(@src(), "Fetch Tinos", .{}, .{ .gravity_y = 0.5 })) {
                    manifest_font_state = .failed;
                    if (dvui.Font.resolveManifestFont(dvui.currentWindow().gpa, manifest_test_fixture, dvui.Font.find(.{ .family = "Tinos" }))) |source| {
                        dvui.currentWindow().fonts.database.append(dvui.currentWindow().gpa, source) catch {};
                        manifest_font_state = .loaded;
                    }
                }
                if (manifest_woff2_font_state == .unresolved and dvui.button(@src(), "Fetch Tinos WOFF2", .{}, .{ .gravity_y = 0.5 })) {
                    manifest_woff2_font_state = .failed;
                    if (dvui.Font.resolveManifestFont(dvui.currentWindow().gpa, manifest_woff2_test_fixture, dvui.Font.find(.{ .family = "Tinos WOFF2" }))) |source| {
                        dvui.currentWindow().fonts.database.append(dvui.currentWindow().gpa, source) catch {};
                        manifest_woff2_font_state = .loaded;
                    }
                }
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .h = 400 } });
            defer scroll.deinit();

            var mtl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer mtl.deinit();

            const font_size = multi_script_font_size;
            const font = dvui.Font.init(families[multi_script_family_choice]).withSize(font_size);

            const scripts = [_]struct { label: []const u8, sample: []const u8 }{
                .{ .label = "Latin", .sample = "The quick brown fox jumps over the lazy dog." },
                .{ .label = "Arabic", .sample = "هذه جملة اختبارية باللغة العربية." },
                .{ .label = "Devanagari", .sample = "यह हिन्दी में एक परीक्षण वाक्य है।" },
                .{ .label = "Japanese", .sample = "これは日本語のテスト文です。" },
                .{ .label = "Korean", .sample = "이것은 한국어 테스트 문장입니다." },
                .{ .label = "Chinese", .sample = "这是一个中文测试句子。" },
                .{ .label = "Emoji (color)", .sample = "\u{1F600}\u{1F389}\u{1F680}\u{2764}\u{FE0F}\u{1F525}\u{1F30D}" },
                .{ .label = "Emoji (grey/mono)", .sample = "\u{2600}\u{2602}\u{267B}" },
            };
            for (scripts) |s| {
                // Outlives the block below: `displayName()` borrows from it.
                var source: dvui.Font.Source = undefined;
                const resolved_name: []const u8 = blk: {
                    const len = std.unicode.utf8ByteSequenceLength(s.sample[0]) catch 1;
                    const cp = std.unicode.utf8Decode(s.sample[0..len]) catch break :blk "not text";
                    const cw = dvui.currentWindow();
                    const stack = cw.fonts.resolveStack(cw.gpa, font) catch break :blk "out of memory";
                    if (stack.entryIndexFor(cp)) |idx| {
                        const family_font = stack.family_fonts[idx];
                        source = family_font.findSource() orelse break :blk family_font.familyName();
                        break :blk source.displayName();
                    }
                    const fb_font = cw.fonts.discoverDynamicFallback(cw.gpa, cp) orelse break :blk "no fallback available";
                    source = fb_font.findSource() orelse break :blk "no fallback available";
                    break :blk source.displayName();
                };
                mtl.format("{s}: {s}\n", .{ s.label, resolved_name }, .{ .font = font });
                mtl.format("{s}\n\n", .{s.sample}, .{ .font = font });
            }

            const manifest_font = dvui.Font.find(.{ .family = "Tinos", .size = font_size });
            switch (manifest_font_state) {
                .unresolved => mtl.format("Manifest (remote font): press \"Fetch Tinos\"\n\n", .{}, .{}),
                .loaded => mtl.format("Fetched over HTTP from a manifest URL: the quick brown fox\n\n", .{}, .{ .font = manifest_font }),
                .failed => mtl.format("Manifest fetch failed (offline, or not available on this target)\n\n", .{}, .{}),
            }

            const manifest_woff2_font = dvui.Font.find(.{ .family = "Tinos WOFF2", .size = font_size });
            switch (manifest_woff2_font_state) {
                .unresolved => mtl.format("Manifest (remote WOFF2 font): press \"Fetch Tinos WOFF2\"\n\n", .{}, .{}),
                .loaded => mtl.format("Fetched WOFF2 over HTTP from a manifest URL: the quick brown fox\n\n", .{}, .{ .font = manifest_woff2_font }),
                .failed => mtl.format("WOFF2 manifest fetch failed (offline, not built with -Dwoff2=true, or not available on this target)\n\n", .{}, .{}),
            }
        }

        if (show_large_doc.*) {
            var fw = dvui.floatingWindow(@src(), .{}, .{ .max_size_content = .width(500) });
            defer fw.deinit();

            var buf: [100]u8 = undefined;
            const fps_str = std.fmt.bufPrint(&buf, "{d:0>3.0} fps", .{dvui.FPS()}) catch unreachable;

            fw.dragAreaSet(dvui.windowHeader("Large Text Layout", fps_str, show_large_doc));

            var cache_ok = true;

            const copies: *usize = dvui.dataGetPtrDefault(null, box.data().id, "copies", usize, 100);
            const break_lines: *bool = dvui.dataGetPtrDefault(null, box.data().id, "break_lines", bool, false);
            const refresh: *bool = dvui.dataGetPtrDefault(null, box.data().id, "refresh", bool, false);
            {
                var box2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer box2.deinit();

                var copies_val: f32 = @floatFromInt(copies.*);
                if (dvui.sliderEntry(@src(), "copies: {d:0.0}", .{ .value = &copies_val, .min = 0, .max = 1000, .interval = 1 }, .{ .gravity_y = 0.5 })) {
                    copies.* = @trunc(copies_val);
                    cache_ok = false;
                }

                _ = dvui.checkbox(@src(), refresh, "Refresh", .{});

                if (refresh.*) {
                    dvui.refresh(null, @src(), null);
                }
            }

            {
                var box2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer box2.deinit();

                if (dvui.checkbox(@src(), break_lines, "Break Lines", .{ .gravity_y = 0.5 })) {
                    cache_ok = false;
                }
            }

            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();

            var tl = dvui.textLayout(@src(), .{ .cache_layout = cache_ok, .break_lines = break_lines.* }, .{ .expand = .both });
            defer tl.deinit();

            const lorem1 = "Header line with 9 indented (kerning test T.)\n" ++
                "  indented line 1\n" ++
                "  indented line 2\n" ++
                "  indented line 3\n" ++
                "  indented line 4\n" ++
                "  indented line 5\n" ++
                "  indented line 6\n" ++
                "  indented line 7\n" ++
                "  indented line 8\n" ++
                "  indented line 9\n";

            for (0..copies.*) |i| {
                tl.format("{d} ", .{i}, .{});
                tl.addText(lorem1, .{});
            }
        }
    }

    {
        var tl: TextLayoutWidget = undefined;
        tl.init(@src(), .{}, .{ .expand = .horizontal });
        defer tl.deinit();

        var cbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .margin = dvui.Rect.all(6), .min_size_content = .{ .w = 40 } });
        if (dvui.buttonIcon(
            @src(),
            "play",
            entypo.controller_play,
            .{},
            .{},
            .{ .expand = .ratio },
        )) {
            dvui.dialog(@src(), .{}, .{ .modal = false, .title = "Play", .message = "You clicked play" });
        }
        if (dvui.buttonIcon(
            @src(),
            "more",
            entypo.dots_three_vertical,
            .{},
            .{},
            .{ .expand = .ratio },
        )) {
            dvui.dialog(@src(), .{}, .{ .modal = false, .title = "More", .message = "You clicked more" });
        }
        cbox.deinit();

        cbox = dvui.box(@src(), .{}, .{ .role = .group, .margin = Rect.all(4), .padding = Rect.all(4), .gravity_x = 1.0, .background = true, .style = .window, .min_size_content = .{ .w = 160 }, .max_size_content = .width(160) });
        var tl_caption = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        {
            var inner_box = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer inner_box.deinit();
            dvui.icon(@src(), "aircraft", entypo.aircraft, .{}, .{ .min_size_content = .{ .h = 30 }, .gravity_x = 0.5 });
            dvui.label(@src(), "Caption Heading", .{}, .{ .font = dvui.Font.theme(.body).larger(-2).withWeight(.bold).withLineHeight(1.1), .gravity_x = 0.5 });
            tl_caption.addText("Here is some caption text that is in it's own text layout.", .{ .font = dvui.Font.theme(.body).larger(-2).withLineHeight(1.1) });
        }
        tl_caption.deinit();
        cbox.deinit();

        if (tl.touchEditing()) |floating_widget| {
            defer floating_widget.deinit();
            tl.touchEditingMenu();
        }

        tl.processEvents();

        const fontWithLineHeight = dvui.Font.theme(.body).withLineHeight(line_height_factor).withUnderline(.{ .thick = underline_thick }).withStrike(.{ .thick = strike_thick });

        tl.format("Body font is {s}\n\n", .{dvui.Font.theme(.body).familyName()}, .{});

        const lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. ";
        const lorem2 = " Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.\n";
        tl.addText(lorem, .{ .font = fontWithLineHeight });

        tl.addLink(
            .{
                .text = "This text is a link that is part of the text layout and goes to the dvui home page.",
                .url = "https://david-vanderson.github.io/",
            },
            .{ .font = fontWithLineHeight.withUnderline(.{}) },
        );

        tl.addText(lorem2, .{ .font = fontWithLineHeight });

        const start = "\nNotice that the text in this box is wrapping around the stuff in the corners.\n\n";
        tl.addText(start, .{ .font = .theme(.title) });

        const col = dvui.Color.average(tl.data().options.color(.text).toColor(), tl.data().options.color(.fill).toColor());
        tl.addTextTooltip(@src(), "Hover this for a tooltip.\n\n", "This is some tooltip", .{ .color_text = .{ .color = col } });

        tl.format("This line uses zig format strings: {d}\n\n", .{12345}, .{});

        const bold_font = dvui.Font.theme(.body).withWeight(.bold);
        if (bold_font.findSource()) |_| {
            tl.addText("Bold\n", .{ .font = bold_font.larger(2) });
        } else {
            tl.addText("Bold not available (using fallback font)\n", .{ .font = bold_font.larger(2) });
        }
        const italic_font = dvui.Font.theme(.body).withStyle(.italic);
        if (italic_font.findSource()) |_| {
            tl.addText("Italic\n", .{ .font = italic_font.larger(2) });
        } else {
            tl.addText("Italic not available (using fallback font)\n", .{ .font = italic_font.larger(2) });
        }
        const mono_font = dvui.Font.theme(.mono);
        if (mono_font.findSource()) |_| {
            tl.format("Mono Font is {s}\n", .{mono_font.familyName()}, .{ .font = mono_font.larger(2) });
        } else {
            tl.addText("Mono not available (using fallback font)\n", .{ .font = mono_font.larger(2) });
        }

        tl.addText("Here ", .{ .font = dvui.Font.theme(.body).withWeight(.bold).withStyle(.italic).larger(12), .color_text = .{ .color = .{ .r = 100, .b = 100 } } });
        tl.addText("is some ", .{ .font = dvui.Font.theme(.body).larger(6), .color_text = .{ .color = .{ .b = 100, .g = 100 } }, .color_fill = .green });
        tl.addText("ugly text ", .{ .font = dvui.Font.theme(.body).larger(8), .color_text = .{ .color = .{ .r = 100, .g = 100 } }, .color_fill = .teal });
        tl.addText("that shows styling.", .{ .font = dvui.Font.theme(.body).larger(-2), .color_text = .{ .color = .{ .r = 100, .g = 50, .b = 50 } } });

        const variable_font = dvui.Font.init("Aleo VF").larger(4).withVariation("wght", wght_axis);
        tl.format("\n\nVariable font (wght={d:0.0}): the quick brown fox\n", .{wght_axis}, .{ .font = variable_font });
    }

    if (dvui.useTreeSitter) {
        const global = struct {
            extern fn tree_sitter_json() callconv(.c) *dvui.c.TSLanguage;
        };

        var log_captures = false;
        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer hbox.deinit();

            dvui.label(@src(), "Syntax Highlight", .{}, .{ .gravity_y = 0.5 });

            if (dvui.button(@src(), "Log Captures", .{}, .{ .gravity_y = 0.5, .gravity_x = 1.0 })) {
                log_captures = true;
            }
        }

        const source =
            \\{ "name"   : "John Smith",
            \\  "array"  : [true, false, null, { "sku" : 123 }],
            \\  // comments are not part of base json
            \\  // but supported by this parser
            \\  "price"  : 23.95,
            \\  /* block comment */
            \\  "shipTo" : { "name" : "Jane Smith",
            \\               "address" : "123 Maple Street" },
            \\}
        ;

        // If multiple queries match, we use the last
        // If a query matches inside another query, we drop it (like
        // escape_sequence which is inside string)
        const queries =
            \\(string) @string
            \\
            \\(pair
            \\  key: (_) @string.special.key)
            \\
            \\(number) @number
            \\
            \\[
            \\  (null)
            \\  (true)
            \\  (false)
            \\] @constant.builtin
            \\
            \\(escape_sequence) @escape
            \\
            \\(comment) @comment
        ;

        // If multiple highlights match, we use the last
        const highlights: []const dvui.TextEntryWidget.SyntaxHighlight = &.{
            .{ .name = "constant", .opts = .{ .color_text = .fromHex("87d75f") } },
            .{ .name = "string", .opts = .{ .color_text = .fromHex("d7af5f") } },
            .{ .name = "string.special.key", .opts = .{ .color_text = .fromHex("87afd7") } },
            .{ .name = "comment", .opts = .{ .color_text = .fromHex("af87d7") } },
            .{ .name = "number", .opts = .{ .color_text = .fromHex("d75f5f") } },
        };

        var tl: TextLayoutWidget = undefined;
        tl.init(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.mono) });
        defer tl.deinit();

        if (tl.touchEditing()) |floating_widget| {
            defer floating_widget.deinit();
            tl.touchEditingMenu();
        }

        tl.processEvents();

        const ts: dvui.TreeSitter = .{
            .language = global.tree_sitter_json(),
            .queries = queries,
            .highlights = highlights,
            .log_captures = log_captures,
        };

        var iter = ts.parse(tl.data().id, "parser", source);
        defer iter.deinit();

        iter.debug = ts.log_captures;

        // do this if the text changes
        //iter.reparse(null);

        if (tl.cacheLayoutBytes()) |clb| {
            iter.setByteRange(clb.start, clb.end);
        }

        // do all matches
        const normal_opts = tl.data().options.strip();
        while (iter.next()) |h| {
            tl.addText(h.text, h.opts orelse normal_opts);
        }
    } else {
        dvui.label(@src(), "Syntax highlight disabled (not yet available in on web)", .{}, .{});
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "DOCIMG text_layout" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 500, .h = 500 } });
    defer t.deinit();

    const frame = struct {
        fn frame() !dvui.App.Result {
            var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .style = .window });
            defer box.deinit();
            layoutText();
            return .ok;
        }
    }.frame;

    try dvui.testing.settle(frame);
    try t.saveImage(frame, null, "Examples-text_layout.png");
}

const std = @import("std");
const dvui = @import("../dvui.zig");
const entypo = dvui.entypo;
const TextLayoutWidget = dvui.TextLayoutWidget;
const Rect = dvui.Rect;
