var line_height_factor: f32 = 1.2;
var underline_thick: f32 = 0.0;
var strike_thick: f32 = 0.0;
var wght_axis: f32 = 400;
var font_weight: f32 = 400;
var font_stretch: f32 = 1.0;
var font_style: dvui.Font.Style = .normal;
var multi_script_font_size: f32 = 18;
var multi_script_family_choice: usize = 0;
var fallback_language_choice: usize = 0;
const fallback_language_labels = [_][]const u8{ "OS locale", "ja", "zh-Hans", "zh-Hant", "ko" };
const fallback_language_tags = [_]?[]const u8{ null, "ja", "zh-Hans", "zh-Hant", "ko" };
var break_width: f32 = 260;
var break_line_break: @FieldType(TextLayoutWidget.InitOptions, "line_break") = .strict;
var break_word_break: @FieldType(TextLayoutWidget.InitOptions, "word_break") = .normal;
var break_overflow_wrap: @FieldType(TextLayoutWidget.InitOptions, "overflow_wrap") = .anywhere;
var bidi_direction: @FieldType(TextLayoutWidget.InitOptions, "base_direction") = .auto;
var variable_font_registered = false;
/// Registered stack alias, first entry in the family dropdown below.
const demo_stack_alias = "Demo Stack (Aleo + Noto KR)";
/// Dropdown entries: the CSS generics, then every family this device
/// actually has installed (`dvui.Font.systemFamilies`), enumerated once --
/// the OS query walks the whole font catalog, too slow to redo per frame.
var family_choices: ?[]const []const u8 = null;
var family_choices_buf: [1024][]const u8 = undefined;
var family_names_storage: [64 * 1024]u8 = undefined;

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

        {
            var flex = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
            defer flex.deinit();

            _ = dvui.sliderEntry(@src(), "line height: {d:0.2}", .{ .value = &line_height_factor, .min = 0.1, .max = 2, .interval = 0.1 }, .{});
            _ = dvui.sliderEntry(@src(), "underline thick: {d:0.2}", .{ .value = &underline_thick, .min = 0.00, .max = 1.0, .interval = 0.01 }, .{});
            _ = dvui.sliderEntry(@src(), "strike thick: {d:0.2}", .{ .value = &strike_thick, .min = 0.00, .max = 1.0, .interval = 0.01 }, .{});
            _ = dvui.sliderEntry(@src(), "weight axis: {d:0.0}", .{ .value = &wght_axis, .min = 100, .max = 900, .interval = 1 }, .{});
            _ = dvui.sliderEntry(@src(), "font weight: {d:0.0}", .{ .value = &font_weight, .min = 100, .max = 900, .interval = 100 }, .{});
            _ = dvui.sliderEntry(@src(), "font stretch: {d:0.000}", .{ .value = &font_stretch, .min = 0.5, .max = 2, .interval = 0.125 }, .{});
            _ = dvui.dropdownEnum(@src(), dvui.Font.Style, .{ .choice = &font_style }, .{}, .{});
            if (dvui.button(@src(), "Large Doc", .{}, .{})) {
                show_large_doc.* = !show_large_doc.*;
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

        const prose = "Typography across scripts: Falsches Üben von Xylophonmusik quält jeden größeren Zwerg. " ++
            "Γαζέες καὶ μυρτιὲς δὲν θὰ βρῶ πιὰ στὸ χρυσαφὶ ξέφωτο. Съешь же ещё этих мягких французских булок. " ++
            "यह हिन्दी में एक परीक्षण वाक्य है। 日本語と中文も同じ段落に入ります。 한국어 문장도 있습니다. ";
        const prose2 = " والنص العربي يُكتب من اليمين إلى اليسار. עברית גם כן. ภาษาไทยไม่มีช่องว่างระหว่างคำ Emoji \u{1F600}\u{1F469}\u{200D}\u{1F4BB}.\n";
        tl.addText(prose, .{ .font = fontWithLineHeight });

        tl.addLink(
            .{
                .text = "This text is a link that is part of the text layout and goes to the dvui home page.",
                .url = "https://david-vanderson.github.io/",
            },
            .{ .font = fontWithLineHeight.withUnderline(.{}) },
        );

        tl.addText(prose2, .{ .font = fontWithLineHeight });

        tl.addText("\nNotice that the text in this box is wrapping around the stuff in the corners.\n", .{ .font = .theme(.title) });
    }

    multiScript();
    lineBreaking();
    bidi();
    styling();
}

fn styling() void {
    dvui.label(@src(), "Styling", .{}, .{ .font = .theme(.title) });
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        defer tl.deinit();

        const col = dvui.Color.average(tl.data().options.color(.text).toColor(), tl.data().options.color(.fill).toColor());
        tl.addTextTooltip(@src(), "Hover this for a tooltip.\n", "This is some tooltip", .{ .color_text = .{ .color = col } });

        tl.format("This line uses zig format strings: {d}\n", .{12345}, .{});

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

        // CSS font matching: request weight/stretch/style, show the face that actually won.
        for ([_][]const u8{ "Aleo VF", familyChoices()[multi_script_family_choice] }) |family| {
            const requested = dvui.Font.init(family).larger(4).withWeight(.{ .value = font_weight }).withStretch(.{ .value = font_stretch }).withStyle(font_style);
            if (requested.findSource()) |source| {
                tl.format("{s} {d:0} {d:0.000} {t} -> {s} {d:0} {d:0.000} {t}: the quick brown fox\n", .{ family, font_weight, font_stretch, font_style, source.displayName(), source.weight.value, source.stretch.value, source.style }, .{ .font = requested });
            } else {
                tl.format("{s} {d:0} {d:0.000} {t} -> no face loaded: the quick brown fox\n", .{ family, font_weight, font_stretch, font_style }, .{ .font = requested });
            }
        }
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

fn familyChoices() []const []const u8 {
    return family_choices orelse blk: {
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
}

/// Name of the font that actually renders `codepoint` in `font`: its own
/// stack entry, else dvui's dynamic OS fallback. `source` must outlive the
/// returned slice (`displayName()` borrows from it).
fn resolvedFontName(font: dvui.Font, codepoint: u21, source: *dvui.Font.Source) []const u8 {
    const cw = dvui.currentWindow();
    const stack = cw.fonts.resolveStack(cw.gpa, font) catch return "out of memory";
    if (stack.entryIndexFor(codepoint)) |idx| {
        const family_font = &stack.family_fonts[idx];
        source.* = family_font.findSource() orelse return family_font.familyName();
        return source.displayName();
    }
    const fb_font = cw.fonts.discoverDynamicFallback(cw.gpa, codepoint) orelse return "no fallback available";
    source.* = fb_font.findSource() orelse return "no fallback available";
    return source.displayName();
}

fn firstCodepoint(text: []const u8) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return 0xFFFD;
    return std.unicode.utf8Decode(text[0..len]) catch 0xFFFD;
}

fn multiScript() void {
    const families = familyChoices();
    dvui.label(@src(), "Multi-Script (system fonts)", .{}, .{ .font = .theme(.title) });
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();
        _ = dvui.sliderEntry(@src(), "font size: {d:0.0}", .{ .value = &multi_script_font_size, .min = 8, .max = 48, .interval = 1 }, .{ .gravity_y = 0.5 });
        _ = dvui.dropdown(@src(), families, .{ .choice = &multi_script_family_choice }, .{}, .{ .gravity_y = 0.5 });
        dvui.label(@src(), "Han fallback language", .{}, .{ .gravity_y = 0.5 });
        if (dvui.dropdown(@src(), &fallback_language_labels, .{ .choice = &fallback_language_choice }, .{}, .{ .gravity_y = 0.5 })) {
            const cw = dvui.currentWindow();
            cw.fonts.fallback_language = fallback_language_tags[fallback_language_choice];
            // Picks are memoized per codepoint; forget them so Han re-resolves for the new language.
            cw.fonts.dynamic_fallback.clearRetainingCapacity();
        }
    }

    var mtl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    defer mtl.deinit();

    const font_size = multi_script_font_size;
    const font = dvui.Font.init(families[multi_script_family_choice]).withSize(font_size);

    mtl.addText("Generic families resolve to: ", .{ .font = font });
    for (dvui.Font.generic_families) |generic| {
        var source: dvui.Font.Source = undefined;
        const generic_font = dvui.Font.init(generic).withSize(font_size);
        mtl.format("{s} = {s}   ", .{ generic, resolvedFontName(generic_font, 'A', &source) }, .{ .font = generic_font });
    }
    mtl.addText("\n\n", .{ .font = font });

    // The label after each script name is the font that actually renders it,
    // so a wrong or missing fallback shows up here instead of only as tofu.
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
        var source: dvui.Font.Source = undefined;
        mtl.format("{s}: {s}\n", .{ s.label, resolvedFontName(font, firstCodepoint(s.sample), &source) }, .{ .font = font });
        mtl.format("{s}\n\n", .{s.sample}, .{ .font = font });
    }

    // sans-serif rather than the dropdown pick: the demo stack's Noto Sans KR
    // covers Han itself, which would hide the fallback-language choice.
    {
        const han_font = dvui.Font.init("sans-serif").withSize(font_size);
        const han_sample = "直 骨 角 誤 返 刃 令 化";
        var source: dvui.Font.Source = undefined;
        const lang = fallback_language_labels[fallback_language_choice];
        // Language in the line text too: shaped lines are cached by text, so this reshapes on a switch.
        mtl.format("Han, fallback language {s}: {s}\n", .{ lang, resolvedFontName(han_font, firstCodepoint(han_sample), &source) }, .{ .font = han_font });
        mtl.format("[{s}] {s}\n\n", .{ lang, han_sample }, .{ .font = han_font });
    }
}

const line_break_sample =
    "Thai (dictionary break): ภาษาไทยไม่มีการเว้นวรรคระหว่างคำจึงต้องใช้พจนานุกรมในการตัดคำ\n" ++
    "CJK: 日本語の文章は「句読点」の前後で改行の規則が変わります。ぁぃぅ小さい仮名もあります。中文句子也可以在任意汉字之间断行。\n" ++
    "URL: https://example.com/a/very/long/path/to/some/resource?query=value&other=1\n" ++
    "Long word: Donaudampfschifffahrtsgesellschaftskapitänsmützenhalter\n" ++
    "LS here\u{2028}next line, PS here\u{2029}next paragraph, CRLF here\r\nlast line.";

fn lineBreaking() void {
    dvui.label(@src(), "Line Breaking", .{}, .{ .font = .theme(.title) });
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();
        _ = dvui.sliderEntry(@src(), "width: {d:0}", .{ .value = &break_width, .min = 40, .max = 700, .interval = 1 }, .{ .gravity_y = 0.5 });
        dvui.label(@src(), "line-break", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.dropdownEnum(@src(), @TypeOf(break_line_break), .{ .choice = &break_line_break }, .{}, .{ .gravity_y = 0.5 });
        dvui.label(@src(), "word-break", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.dropdownEnum(@src(), @TypeOf(break_word_break), .{ .choice = &break_word_break }, .{}, .{ .gravity_y = 0.5 });
        dvui.label(@src(), "overflow-wrap", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.dropdownEnum(@src(), @TypeOf(break_overflow_wrap), .{ .choice = &break_overflow_wrap }, .{}, .{ .gravity_y = 0.5 });
    }

    var tl = dvui.textLayout(@src(), .{
        .line_break = break_line_break,
        .word_break = break_word_break,
        .overflow_wrap = break_overflow_wrap,
    }, .{
        .min_size_content = .width(break_width),
        .max_size_content = .width(break_width),
        .border = Rect.all(1),
    });
    defer tl.deinit();
    tl.addText(line_break_sample, .{});
}

fn bidi() void {
    dvui.label(@src(), "Bidi", .{}, .{ .font = .theme(.title) });
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();
        dvui.label(@src(), "base direction", .{}, .{ .gravity_y = 0.5 });
        _ = dvui.dropdownEnum(@src(), @TypeOf(bidi_direction), .{ .choice = &bidi_direction }, .{}, .{ .gravity_y = 0.5 });
    }

    var tl = dvui.textLayout(@src(), .{ .base_direction = bidi_direction }, .{ .expand = .horizontal });
    defer tl.deinit();

    const highlight: dvui.Options = .{ .color_fill = .fromHex("f0c040"), .color_text = .black };
    tl.addText("Latin first, then Hebrew ", .{});
    tl.addText("עברית עם המספר ", .{});
    // One styled chunk spanning the RTL -> LTR boundary.
    tl.addText("1,234 ושוב English", highlight);
    tl.addText(" and back, then Arabic ", .{});
    tl.addText("مرحبا بالعالم ٢٠٢٦", .{ .font = dvui.Font.theme(.body).withStyle(.italic) });
    tl.addText(" (2026).\n", .{});
    tl.addText("שורה שמתחילה בעברית, then Latin 42% ", .{});
    tl.addText("and a highlight שחוצה", highlight);
    tl.addText(" את הגבול.\n", .{});
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
