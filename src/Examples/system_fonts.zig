//! Per-OS system font family names, resolved through dvui's OS font-discovery
//! backend (fontconfig / CoreText / DirectWrite) -- no bundled font bytes.
//! `dvui.Font.find`/`init` only need a family name; if it wasn't registered
//! with `addFont`, `Font.Cache.getOrCreate` calls `discoverSystemFont` and
//! reads the matched file straight off the OS. Not available on web (no
//! discovery backend there), Font.Cache falls back to the embedded Vera font.
//! `dvui.Font.resolveManifestFont` covers that gap on native targets (fetch
//! a font by URL from an app-supplied manifest instead of the OS) -- see the
//! "Manifest (remote font)" entry in the Multi-Script demo, text_layout.zig.

const dvui = @import("../dvui.zig");

const Table = struct {
    latin: []const u8,
    arabic: []const u8,
    devanagari: []const u8,
    japanese: []const u8,
    korean: []const u8,
    chinese: []const u8,
    emoji_color: []const u8,
    emoji_grey: []const u8,
};

pub const table: Table = switch (@import("builtin").target.os.tag) {
    .macos, .ios => .{
        .latin = "Helvetica",
        .arabic = "Geeza Pro",
        .devanagari = "Kohinoor Devanagari",
        .japanese = "Hiragino Sans",
        .korean = "Apple SD Gothic Neo",
        // NOTE: not "PingFang SC" -- recent macOS ships it with Apple's
        // proprietary 'hvgl' variable-glyph table instead of glyf/CFF/CFF2,
        // which no cross-platform renderer (including this one) decodes.
        // "Heiti SC" is an older bundled Chinese font using plain CFF.
        .chinese = "Heiti SC",
        .emoji_color = "Apple Color Emoji",
        // NOTE: macOS ships no system mono/outline emoji font; closest
        // analog is Apple Symbols (dingbat-style glyphs, not real emoji).
        .emoji_grey = "Apple Symbols",
    },
    .windows => .{
        .latin = "Segoe UI",
        .arabic = "Tahoma",
        .devanagari = "Nirmala UI",
        .japanese = "Yu Gothic UI",
        .korean = "Malgun Gothic",
        .chinese = "Microsoft YaHei",
        .emoji_color = "Segoe UI Emoji",
        .emoji_grey = "Segoe UI Symbol",
    },
    // Linux/BSD/Android via fontconfig; assumes the common Noto set.
    else => .{
        .latin = "Noto Sans",
        .arabic = "Noto Sans Arabic",
        .devanagari = "Noto Sans Devanagari",
        .japanese = "Noto Sans CJK JP",
        .korean = "Noto Sans CJK KR",
        .chinese = "Noto Sans CJK SC",
        .emoji_color = "Noto Color Emoji",
        .emoji_grey = "Noto Emoji",
    },
};

pub fn find(family: []const u8, size: f32) dvui.Font {
    return dvui.Font.find(.{ .family = family, .size = size });
}
