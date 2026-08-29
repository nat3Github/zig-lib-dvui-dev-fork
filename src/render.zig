pub const Target = struct {
    texture: ?Texture.Target,
    offset: Point.Physical,
    rendering: bool = true,

    /// Change where dvui renders.  Can pass output from `dvui.textureCreateTarget` or
    /// null for the screen.  Returns the previous target/offset.
    ///
    /// offset will be subtracted from all dvui rendering, useful as the point on
    /// the screen the texture will map to.
    ///
    /// Useful for caching expensive renders or to save a render for export.  See
    /// `Picture`.
    ///
    /// Only valid between `Window.begin`and `Window.end`.
    pub fn setAsCurrent(target: Target) Target {
        var cw = dvui.currentWindow();
        const ret = cw.render_target;
        cw.backend.renderTarget(target.texture) catch |err| {
            // TODO: This might be unrecoverable? Or brake rendering too badly?
            dvui.logError(@src(), err, "Failed to set render target", .{});
            return ret;
        };
        cw.render_target = target;
        return ret;
    }
};

/// Represents a deferred call to one of the render functions.  This is how
/// dvui defers rendering of floating windows so they render on top of widgets
/// that run later in the frame.
pub const RenderCommand = struct {
    clip: Rect.Physical,
    alpha: f32,
    snap: bool,
    kerning: bool,
    cmd: Command,

    pub const Command = union(enum) {
        text: TextOptions,
        texture: struct {
            tex: Texture,
            rs: RectScale,
            opts: TextureOptions,
        },
        pathFillConvex: struct {
            path: Path,
            opts: Path.FillConvexOptions,
        },
        pathFill: struct {
            contours: []const Path,
            opts: Path.FillOptions,
        },
        pathStroke: struct {
            path: Path,
            opts: Path.StrokeOptions,
        },
        triangles: struct {
            tri: Triangles,
            tex: ?Texture,
        },
    };
};

/// Rendered `Triangles` taking in to account the current clip rect
/// and deferred rendering through render targets.
///
/// Expect that `dvui.Window.alpha` has already been applied.
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn renderTriangles(triangles: Triangles, tex: ?Texture) Backend.GenericError!void {
    if (triangles.vertexes.len == 0) {
        return;
    }

    if (dvui.clipGet().empty()) {
        return;
    }

    const cw = dvui.currentWindow();

    if (!cw.render_target.rendering) {
        const tri_copy = try triangles.dupe(cw.arena());
        cw.addRenderCommand(.{ .triangles = .{ .tri = tri_copy, .tex = tex } }, false);
        return;
    }

    // expand clipping to full pixels before testing
    var clipping = dvui.clipGet();
    clipping.w = @max(0, @ceil(clipping.x - @floor(clipping.x) + clipping.w));
    clipping.x = @floor(clipping.x);
    clipping.h = @max(0, @ceil(clipping.y - @floor(clipping.y) + clipping.h));
    clipping.y = @floor(clipping.y);

    const clipr: ?Rect.Physical = if (triangles.bounds.clippedBy(clipping)) clipping.offsetNegPoint(cw.render_target.offset) else null;

    if (cw.render_target.offset.nonZero()) {
        const offset = cw.render_target.offset;
        for (triangles.vertexes) |*v| {
            v.pos = v.pos.diff(offset);
        }
    }

    cw.render_stats.draw_calls += 1;
    cw.render_stats.vertices +|= @intCast(triangles.vertexes.len);
    cw.render_stats.triangles +|= @intCast(triangles.indices.len / 3);
    if (tex != null) cw.render_stats.texture_binds += 1;

    try cw.backend.drawClippedTriangles(tex, triangles.vertexes, triangles.indices, clipr);
}

pub const TextOptions = struct {
    font: Font,
    text: []const u8,
    rs: RectScale,

    /// Draw text starting here (top left corner of start of text).  If null,
    /// use rs.r.topLeft().
    p: ?Point.Physical = null,
    color: Color,
    /// If set, overrides `color` per-vertex via `Gradient.sample`, sampled
    /// against `rs.r` (or `gradient.anchor` if that's set). Glyph quads are
    /// small enough that Gouraud-interpolating the 4 corners' exact samples
    /// is visually identical to resampling per-pixel -- unlike fills, which
    /// need the ramp-texture trick in `Gradient.apply` for 3+ stops.
    gradient: ?Gradient = null,
    background_color: ?Color = null,

    /// radians clockwise, rotates around top-left corner (rs.x/rs.y)
    /// - doesn't support background or selection yet
    rotation: f32 = 0.0,
    sel_start: ?usize = null,
    sel_end: ?usize = null,
    sel_color: ?Color = null,
    debug: bool = false,
    kerning: ?bool = null,
    kern_in: ?[]u32 = null,
    ak_opts: ?AccessKit.TextRunOptions = null,
    pre_shaped: ?*const Font.ShapedText = null,
    pre_shaped_glyph_limit: ?usize = null,
};

/// Only renders a single line of text
/// Selection will be colored with the current themes accent color,
/// with the text color being set to the themes fill color.
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn renderText(opts: TextOptions) Backend.GenericError!void {
    var cw = dvui.currentWindow();
    // Record character heights and positions for AccessKit text_run role.
    var text_info: std.MultiArrayList(AccessKit.CharPositionInfo) = .empty;
    const clipped_rect = dvui.clipGet().intersect(opts.rs.r);

    // If accessibility is enabled, we still need create the associated text_run
    // even when the text is blank or not visible.
    if (opts.text.len == 0) return;
    if (opts.rs.s == 0) return;
    if (clipped_rect.empty() and opts.ak_opts == null) return;

    // `pre_shaped` bytes were already validated/shaped by the caller
    // (`Font.textSizeExShaped`) -- skip re-validating them here too.
    const utf8_text = if (opts.pre_shaped != null) opts.text else try dvui.toUtf8(cw.lifo(), opts.text);
    defer if (opts.pre_shaped == null and opts.text.ptr != utf8_text.ptr) cw.lifo().free(utf8_text);

    if (!cw.render_target.rendering) {
        var opts_copy = opts;
        opts_copy.text = try cw.arena().dupe(u8, utf8_text);
        cw.addRenderCommand(.{ .text = opts_copy }, false);
        return;
    }

    // fce is built directly at this device-pixel size (see Font.zig), so
    // everything below stays in device pixels -- no separate rescale factor
    // needed the way the old FreeType/stb integer-pixel-size path required.
    const target_size = opts.font.size * opts.rs.s;
    const sized_font = opts.font.withSize(target_size);

    // The Entry each glyph was actually shaped against (may differ per
    // glyph for a multi-family Font -- see `ShapedLine.entryForGlyph`).
    // `fallback_entry` (family index 0) is what line-level metrics
    // (underline/strike/selection bounds, atlas) use.
    var fallback_entry: *Font.Cache.Entry = undefined;
    var fallback_ascent: f32 = undefined;
    var line: Font.Cache.Entry.ShapedLine = undefined;
    var owns_line = false;
    defer if (owns_line) line.deinit();

    if (opts.pre_shaped) |shaped| {
        // Already shaped once by the caller (full UAX #9 bidi + GSUB/GPOS)
        // for measurement -- reuse it instead of reshaping the same bytes
        // a second time just to draw them.
        fallback_entry = shaped.fallback;
        fallback_ascent = shaped.ascent;
        line = shaped.line;
    } else {
        const resolved = try cw.fonts.resolveStack(cw.gpa, sized_font);
        fallback_entry = cw.fonts.stackEntry(resolved, 0) orelse return error.OutOfMemory;
        fallback_ascent = fallback_entry.ascent;
        if (opts.font.line_height_factor < 1.0) {
            fallback_ascent = @round(fallback_ascent * opts.font.line_height_factor);
        }
        line = cw.fonts.shapeLineText(cw.arena(), resolved, utf8_text) catch return error.OutOfMemory;
        owns_line = true;
    }

    // Generate new texture atlas if needed to update glyph uv coords
    const texture_atlas = fallback_entry.getTextureAtlas(cw.gpa, cw.backend) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            const fname = opts.font.name(cw.arena());
            defer cw.arena().free(fname);
            dvui.log.err("Could not get texture atlas for font {s}, text area marked in magenta, to display '{s}'", .{ fname, opts.text });
            opts.rs.r.fill(.{}, .{ .color = .magenta });
            return;
        },
    };

    // Over allocate the internal buffers assuming each byte is a character
    var builder = try dvui.Triangles.Builder.init(cw.lifo(), 4 * utf8_text.len, 6 * utf8_text.len);
    defer builder.deinit(cw.lifo());

    const color = opts.color.opacity(cw.alpha);
    const col: Color.PMA = .fromColor(color);
    const white_pma: Color.PMA = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    // Sample fresh per-vertex below when set; leave `col` as the flat
    // fallback for background/selection/underline/strike, which stay flat.
    const gradient_bounds = opts.rs.r;

    var start = opts.p orelse opts.rs.r.topLeft();
    if (cw.snap_to_pixels) {
        start.x = @round(start.x);
        start.y = @round(start.y);
    }

    var x = start.x;
    var max_x = start.x;

    if (opts.debug) {
        dvui.log.debug("renderText {f}\n", .{start});
    }

    var sel_in: bool = false;
    var sel_start_x: f32 = x;
    var sel_end_x: f32 = x;
    var sel_max_y: f32 = start.y;
    var sel_start: usize = opts.sel_start orelse 0;
    sel_start = @min(sel_start, utf8_text.len);
    var sel_end: usize = opts.sel_end orelse 0;
    sel_end = @min(sel_end, utf8_text.len);
    // if we will definitely have a selected region or not
    const sel: bool = sel_start < sel_end;

    const atlas_size: Size = .{ .w = @floatFromInt(texture_atlas.width), .h = @floatFromInt(texture_atlas.height) };
    const snap = cw.snap_to_pixels;

    // `line` may cover more than `utf8_text` when reusing a wider
    // pre-shaped line (e.g. before UAX #14 line-break trimming shrank the
    // rendered range) -- only draw the glyphs that correspond to it.
    const glyph_limit = if (opts.pre_shaped != null) opts.pre_shaped_glyph_limit orelse line.buffer.info.items.len else line.buffer.info.items.len;

    for (line.buffer.info.items[0..glyph_limit], line.buffer.pos.items[0..glyph_limit], 0..) |info, pos, gidx| {
        // ponytail: metrics/rasterization use each glyph's own entry
        // (correct for a multi-family Font), but the triangle batch below
        // is drawn in one pass against `texture_atlas` (fallback_entry's
        // atlas only) -- a glyph from a non-fallback family would sample
        // the wrong atlas. Unreachable today (nothing wires a multi-family
        // Font into rendering, so `fce` is always `fallback_entry` here);
        // upgrade path if that changes is per-segment triangle batches,
        // one `renderTriangles` call per atlas.
        const fce = line.entryForGlyph(fallback_entry, gidx);
        const gi = fce.glyphInfoGet(cw.gpa, info.codepoint) catch continue;

        const off_x = fce.toPixels(pos.x_offset);
        const off_y = fce.toPixels(pos.y_offset);
        const adv = fce.toPixels(pos.x_advance);
        const adv_used = if (snap) @round(adv) else adv;

        if (x + off_x + gi.leftBearing < start.x) {
            start.x -= off_x + gi.leftBearing;
            x = start.x;
        }

        const nextx = x + adv_used;
        const leftx = x + off_x + gi.leftBearing;

        if (sel) {
            const range = line.clusterByteRange(gidx);
            const in_sel = range.start < sel_end and range.end > sel_start;
            if (!sel_in and in_sel) {
                sel_in = true;
                sel_start_x = @min(x, leftx);
            } else if (sel_in and !in_sel) {
                sel_in = false;
            }

            if (sel_in) {
                sel_end_x = nextx;
            }
        }
        if (dvui.accesskit_enabled) {
            if (opts.ak_opts) |_| {
                const cluster_start = line.byte_offsets[info.cluster];
                const cluster_end = line.byte_offsets[info.cluster + 1];
                text_info.append(cw.arena(), .{
                    .l = @intCast(cluster_end - cluster_start),
                    .w = if (gi.w == 0) nextx - x else gi.w,
                    .x = std.math.clamp(x - clipped_rect.x, 0, clipped_rect.w),
                }) catch {};
            }
        }

        if (gi.w > 0) {
            const vtx_offset: dvui.Vertex.Index = @intCast(builder.vertexes.items.len);
            var v: Vertex = undefined;
            const base_col: Color.PMA = if (gi.is_color) white_pma else col;
            const uv0: @Vector(2, f32) = .{ gi.origin[0] / atlas_size.w, gi.origin[1] / atlas_size.h };

            v.pos.x = leftx;
            v.pos.y = start.y - off_y + (fallback_ascent - gi.topBearing);
            v.col = if (!gi.is_color and opts.gradient != null) .fromColor(opts.gradient.?.sample(gradient_bounds, v.pos).opacity(cw.alpha)) else base_col;
            v.uv = uv0;
            builder.appendVertex(v);

            if (opts.debug) {
                dvui.log.debug(" - x {d} y {d}", .{ v.pos.x, v.pos.y });
            }

            v.pos.x = x + off_x + gi.leftBearing + gi.w;
            max_x = @max(max_x, v.pos.x);
            v.uv[0] = uv0[0] + gi.w / atlas_size.w;
            if (!gi.is_color) if (opts.gradient) |g| {
                v.col = .fromColor(g.sample(gradient_bounds, v.pos).opacity(cw.alpha));
            };
            builder.appendVertex(v);

            v.pos.y = start.y - off_y + (fallback_ascent - gi.topBearing + gi.h);
            sel_max_y = @max(sel_max_y, v.pos.y);
            v.uv[1] = uv0[1] + gi.h / atlas_size.h;
            if (!gi.is_color) if (opts.gradient) |g| {
                v.col = .fromColor(g.sample(gradient_bounds, v.pos).opacity(cw.alpha));
            };
            builder.appendVertex(v);

            v.pos.x = leftx;
            v.uv[0] = uv0[0];
            if (!gi.is_color) if (opts.gradient) |g| {
                v.col = .fromColor(g.sample(gradient_bounds, v.pos).opacity(cw.alpha));
            };
            builder.appendVertex(v);

            // triangles must be counter-clockwise (y going down) to avoid backface culling
            builder.appendTriangles(&.{
                vtx_offset + 0, vtx_offset + 2, vtx_offset + 1,
                vtx_offset + 0, vtx_offset + 3, vtx_offset + 2,
            });
        }

        x = nextx;
    }

    if (opts.background_color) |bgcol| {
        opts.rs.r.toPoint(.{
            .x = max_x,
            .y = @max(sel_max_y, opts.rs.r.y + fallback_entry.height * opts.font.line_height_factor),
        }).fill(.{}, .{ .color = .{ .color = bgcol }, .fade = 0 });
    }

    if (sel) {
        Rect.Physical.fromPoint(.{ .x = sel_start_x, .y = start.y })
            .toPoint(.{
                .x = sel_end_x,
                .y = @max(sel_max_y, start.y + fallback_entry.height * opts.font.line_height_factor),
            })
            .fill(.{}, .{ .color = .{ .color = opts.sel_color orelse dvui.themeGet().focus }, .fade = 0 });
    }

    if (opts.font.underline) |u| {
        if (u.thick > 0) {
            var topleft: dvui.Point.Physical = .{ .x = start.x, .y = start.y + fallback_ascent + (fallback_entry.em_height * 0.2) };
            if (cw.snap_to_pixels) {
                // x should already be snapped
                topleft.y = @round(topleft.y);
            }

            const botright: dvui.Point.Physical = .{ .x = max_x, .y = topleft.y + @max(1.0 * opts.rs.s, fallback_entry.em_height * u.thick) };

            Rect.Physical.fromPoint(topleft).toPoint(botright).fill(.{}, .{ .color = .{ .color = color }, .fade = 0 });
        }
    }

    if (opts.font.strike) |s| {
        if (s.thick > 0) {
            const thick = @max(1.0 * opts.rs.s, fallback_entry.em_height * s.thick);
            var topleft: dvui.Point.Physical = .{ .x = start.x, .y = start.y + fallback_ascent - (fallback_entry.em_height * 0.5) - thick * 0.5 };
            if (cw.snap_to_pixels) {
                // x should already be snapped
                topleft.y = @round(topleft.y);
            }

            const botright: dvui.Point.Physical = .{ .x = max_x, .y = topleft.y + thick };

            Rect.Physical.fromPoint(topleft).toPoint(botright).fill(.{}, .{ .color = .{ .color = color }, .fade = 0 });
        }
    }

    var tri = builder.build();
    defer tri.deinit(cw.lifo());

    tri.rotate(.{ .x = start.x, .y = start.y }, opts.rotation);

    try renderTriangles(tri, texture_atlas);

    if (dvui.accesskit_enabled) if (opts.ak_opts) |ak_opts| {
        cw.accesskit.textRunPopulate(opts.text, ak_opts, &text_info, clipped_rect);
    };
}

pub const TextureOptions = struct {
    rotation: f32 = 0,
    colormod: Color = .{},
    corners: CornerRect = .{},
    uv: Rect = .{ .w = 1, .h = 1 },
    uv_rect: ?Rect.Physical = null,
    background_color: ?Color = null,
    debug: bool = false,

    /// Size (physical pixels) of fade to transparent centered on the edge.
    /// If >1, then starts a half-pixel inside and the rest outside.
    fade: f32 = 0.0,
};

/// Only valid between `Window.begin`and `Window.end`.
pub fn renderTexture(tex: Texture, rs: RectScale, opts: TextureOptions) Backend.TextureError!void {
    if (rs.s == 0) return;
    if (dvui.clipGet().intersect(rs.r).empty()) return;

    const cw = dvui.currentWindow();

    if (!cw.render_target.rendering) {
        cw.addRenderCommand(.{ .texture = .{ .tex = tex, .rs = rs, .opts = opts } }, false);
        return;
    }

    var rect = rs.r;
    if (cw.snap_to_pixels) {
        rect.x = @round(rect.x);
        rect.y = @round(rect.y);
    }

    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();

    path.addRect(rect, opts.corners.scale(rs.s, CornerRect.Physical));

    var triangles = try path.build().fillConvexTriangles(cw.lifo(), .{ .color = .{ .color = opts.colormod.opacity(cw.alpha) }, .fade = opts.fade });
    defer triangles.deinit(cw.lifo());

    const uvRect = opts.uv_rect orelse rect;
    triangles.uvFromRectuv(uvRect, opts.uv);
    triangles.rotate(rect.center(), opts.rotation);

    if (opts.background_color) |bg_col| {
        var back_tri = try triangles.dupe(cw.lifo());
        defer back_tri.deinit(cw.lifo());

        back_tri.color(bg_col);
        try renderTriangles(back_tri, null);
    }

    try renderTriangles(triangles, tex);
}

/// Calls `renderTexture` with the texture created from `tvg_bytes`
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn renderIcon(name: []const u8, tvg_bytes: []const u8, rs: RectScale, opts: TextureOptions, icon_opts: IconRenderOptions) Backend.TextureError!void {
    if (rs.s == 0) return;
    if (dvui.clipGet().intersect(rs.r).empty()) return;

    if (comptime !dvui.useTvg) {
        try renderText(.{
            .font = (dvui.Options{}).fontGet().withSize(0.5 * rs.r.h / rs.s),
            .text = name,
            .rs = rs,
            .color = (dvui.Options{}).color(.text).toColor(),
        });
        return;
    }

    try dvui.render_tvg.renderIcon(name, tvg_bytes, rs, opts, icon_opts);
}

/// Calls `renderTexture` with the texture created from `source`
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn renderImage(source: ImageSource, rs: RectScale, opts: TextureOptions) (Backend.TextureError || StbImageError)!void {
    if (rs.s == 0) return;
    if (dvui.clipGet().intersect(rs.r).empty()) return;
    try renderTexture(try source.getTexture(), rs, opts);
}

pub const Ninepatch = struct {
    pub const none: Ninepatch = .{};

    /// Image to use, default means explicitly no ninepatch.
    source: Texture.ImageSource = .{ .imageFile = .{
        .bytes = &.{},
        .name = "Ninepatch.none",
    } },
    /// How many pixels of source make up each edge.
    edge: Rect = .{},
};

pub const NinepatchOptions = struct {
    debug: bool = false,
};

/// Renders a ninepatch with the given parameters.
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn renderNinepatch(ninepatch: Ninepatch, rs: RectScale, opts: NinepatchOptions) Backend.TextureError!void {
    if (ninepatch.source.imageFile.bytes.len == 0) return;
    if (rs.s == 0) return;
    if (rs.r.empty()) return;
    if (dvui.clipGet().intersect(rs.r).empty()) return;

    const tex = ninepatch.source.getTexture() catch |err| {
        dvui.log.err("renderNinepatch() got {any}", .{err});
        return;
    };

    var rect = rs.r;
    if (dvui.currentWindow().snap_to_pixels) {
        rect.x = @round(rect.x);
        rect.y = @round(rect.y);
    }

    const ts: Size = .{
        .w = @floatFromInt(tex.width),
        .h = @floatFromInt(tex.width),
    };

    // scale ninepatch edge size
    const e = ninepatch.edge.scale(rs.s, Rect.Physical);

    // middle
    var r = rect.inset(e);
    if (!r.empty()) {
        try renderTexture(tex, .{ .r = r, .s = rs.s }, .{
            .uv = .{
                .x = ninepatch.edge.x / ts.w,
                .w = (ts.w - ninepatch.edge.x - ninepatch.edge.w) / ts.w,
                .y = ninepatch.edge.y / ts.h,
                .h = (ts.h - ninepatch.edge.y - ninepatch.edge.h) / ts.h,
            },
            .debug = opts.debug,
        });
    }

    // top and bottom edges
    r = rect.inset(.{ .x = e.x, .w = e.w });
    if (!r.empty()) {
        // bottom first, draw as much as possible from bottom up
        var height = @min(r.h, e.h);
        const bottom = r.y + r.h;
        var th = height / rs.s;
        try renderTexture(tex, .{ .r = .{
            .x = r.x,
            .w = r.w,
            .y = bottom - height,
            .h = height,
        }, .s = rs.s }, .{
            .uv = .{
                .x = ninepatch.edge.x / ts.w,
                .w = (ts.w - ninepatch.edge.x - ninepatch.edge.w) / ts.w,
                .y = (ts.h - th) / ts.h,
                .h = th / ts.h,
            },
            .debug = opts.debug,
        });

        // top edge
        height = @min(r.h, e.y);
        th = height / rs.s;
        try renderTexture(tex, .{ .r = .{
            .x = r.x,
            .w = r.w,
            .y = r.y,
            .h = height,
        }, .s = rs.s }, .{
            .uv = .{
                .x = ninepatch.edge.x / ts.w,
                .w = (ts.w - ninepatch.edge.x - ninepatch.edge.w) / ts.w,
                .y = 0,
                .h = th / ts.h,
            },
            .debug = opts.debug,
        });
    }

    // left and right edges
    r = rect.inset(.{ .y = e.y, .h = e.h });
    if (!r.empty()) {
        // right first, draw from right edge
        var width = @min(r.w, e.w);
        const right = r.x + r.w;
        var tw = width / rs.s;
        try renderTexture(tex, .{ .r = .{
            .x = right - width,
            .w = width,
            .y = r.y,
            .h = r.h,
        }, .s = rs.s }, .{
            .uv = .{
                .x = (ts.w - tw) / ts.w,
                .w = tw / ts.w,
                .y = ninepatch.edge.y / ts.h,
                .h = (ts.h - ninepatch.edge.y - ninepatch.edge.h) / ts.h,
            },
            .debug = opts.debug,
        });

        // left
        width = @min(r.w, e.x);
        tw = width / rs.s;
        try renderTexture(tex, .{ .r = .{
            .x = r.x,
            .w = width,
            .y = r.y,
            .h = r.h,
        }, .s = rs.s }, .{
            .uv = .{
                .x = 0,
                .w = tw / ts.w,
                .y = ninepatch.edge.y / ts.h,
                .h = (ts.h - ninepatch.edge.y - ninepatch.edge.h) / ts.h,
            },
            .debug = opts.debug,
        });
    }

    // bottom right corner
    {
        r = rect;
        const width = @min(r.w, e.w);
        const tw = width / rs.s;
        const height = @min(r.h, e.h);
        const th = height / rs.s;
        if (!r.empty()) {
            try renderTexture(tex, .{ .r = .{
                .x = r.x + r.w - width,
                .w = width,
                .y = r.y + r.h - height,
                .h = height,
            }, .s = rs.s }, .{
                .uv = .{
                    .x = (ts.w - tw) / ts.w,
                    .w = tw / ts.w,
                    .y = (ts.h - th) / ts.h,
                    .h = th / ts.h,
                },
                .debug = opts.debug,
            });
        }
    }

    // bottom left corner
    {
        r = rect;
        const width = @min(r.w, e.x);
        const tw = width / rs.s;
        const height = @min(r.h, e.h);
        const th = height / rs.s;
        if (!r.empty()) {
            try renderTexture(tex, .{ .r = .{
                .x = r.x,
                .w = width,
                .y = r.y + r.h - height,
                .h = height,
            }, .s = rs.s }, .{
                .uv = .{
                    .x = 0,
                    .w = tw / ts.w,
                    .y = (ts.h - th) / ts.h,
                    .h = th / ts.h,
                },
                .debug = opts.debug,
            });
        }
    }

    // top right corner
    {
        r = rect;
        const width = @min(r.w, e.w);
        const tw = width / rs.s;
        const height = @min(r.h, e.y);
        const th = height / rs.s;
        if (!r.empty()) {
            try renderTexture(tex, .{ .r = .{
                .x = r.x + r.w - width,
                .w = width,
                .y = r.y,
                .h = height,
            }, .s = rs.s }, .{
                .uv = .{
                    .x = (ts.w - tw) / ts.w,
                    .w = tw / ts.w,
                    .y = 0,
                    .h = th / ts.h,
                },
                .debug = opts.debug,
            });
        }
    }

    // top left corner
    {
        r = rect;
        const width = @min(r.w, e.x);
        const tw = width / rs.s;
        const height = @min(r.h, e.y);
        const th = height / rs.s;
        if (!r.empty()) {
            try renderTexture(tex, .{ .r = .{
                .x = r.x,
                .w = width,
                .y = r.y,
                .h = height,
            }, .s = rs.s }, .{
                .uv = .{
                    .x = 0,
                    .w = tw / ts.w,
                    .y = 0,
                    .h = th / ts.h,
                },
                .debug = opts.debug,
            });
        }
    }
}

const std = @import("std");
const dvui = @import("dvui.zig");

const Backend = dvui.Backend;
const Font = dvui.Font;
const Color = dvui.Color;
const Point = dvui.Point;
const Size = dvui.Size;
const CornerRect = dvui.CornerRect;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Triangles = dvui.Triangles;
const Path = dvui.Path;
const Gradient = dvui.Gradient;
const Texture = dvui.Texture;
const Vertex = dvui.Vertex;
const ImageSource = dvui.ImageSource;
const AccessKit = dvui.AccessKit;
const StbImageError = dvui.StbImageError;
const IconRenderOptions = dvui.IconRenderOptions;

test {
    @import("std").testing.refAllDecls(@This());
}
