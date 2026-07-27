# paint.jl -- layer 6. May reference: widget, buffer, layout, boxmodel,
# style. U1 (the tree renders itself) and E2 (into a plain Buffer).
#
# Nothing here names a Driver, a terminal, an escape sequence or a
# colour depth: the render pass ends at a Buffer, which is exactly what
# `diff` consumes. That is requirement 2.1 (isolate the application
# logic from the rendering target) discharged structurally rather than
# by convention.

"""
The user hook: paint `w` into `buf`, whose `(1, 1)` IS `w`'s
content-box origin.

The view is ALREADY clipped to the widget's ancestors, so `render!`
works in local coordinates and CANNOT escape its box.

The background fill and the border are already applied by `paint!`.
Containers need no method. Default: no-op.
"""
render!(w::Widget, buf::AbstractMatrix{Cell})::Nothing = nothing

"""
Translate an ABSOLUTE region into coordinates local to a clip window
anchored at `clip`'s top-left. Pure.
"""
_to_local(r::Region, clip::Region)::Region =
    translate(r, Offset(1 - clip.x, 1 - clip.y))

"""
The clip a node hands to its children, in ABSOLUTE coordinates.

Per axis: `Overflow.VISIBLE` keeps the node's own inherited clip, so a
child may spill out of the content box but never out of its ancestors'
clip; `HIDDEN` and `SCROLL` clamp that axis to the content box.

The result is ALWAYS a subset of `clip` -- clipping composes by
intersection and can only ever narrow. Pure.
"""
function _child_clip(bs::BoxStyle, lb::LayoutBox, clip::Region)::Region
    c = lb.content
    vis_x = bs.overflow_x === Overflow.VISIBLE
    vis_y = bs.overflow_y === Overflow.VISIBLE
    x0 = vis_x ? clip.x : c.x
    x1 = vis_x ? right(clip) : right(c)
    y0 = vis_y ? clip.y : c.y
    y1 = vis_y ? bottom(clip) : bottom(c)
    r = Region(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    return intersect(r, clip)
end

"""
`lb` with all four boxes translated by the ACCUMULATED scroll of every
ancestor.

Returns `lb` ITSELF, untouched, when the shift is zero -- which is every
node of every app that never scrolls: two integer compares, no memory
touched, no allocation (`LayoutBox` is `isbits`). Pure. Internal.
"""
function _shift_box(lb::LayoutBox, sx::Int, sy::Int)::LayoutBox
    (sx == 0 && sy == 0) && return lb
    s = Offset(sx, sy)
    return LayoutBox(translate(lb.margin_box, s),
                     translate(lb.border_box, s),
                     translate(lb.padding_box, s),
                     translate(lb.content, s))
end

"""
The unscrolled entry point, so no caller must name a shift.
"""
function _paint_node!(buf::Buffer, w::Widget, clip::Region)::Nothing
    return _paint_node!(buf, w, clip, 0, 0)
end

"""
Paint one node and its subtree. `clip` is the ABSOLUTE region the node
may touch; `(sx, sy)` is the accumulated scroll shift of its ANCESTORS.

INVARIANT, on which the whole compositor rests: every write goes through
a view whose writable window is a subset of `buffer_region(buf)`, and
both view types silently drop out-of-range writes -- a widget cannot
paint outside its clip even if it tries.

WHAT CHANGED, and why the comment that stood here was wrong: origin and
clip coincide only while the clip cannot cut the content box's TOP-LEFT
corner. That was never true even of this file's own tests, and a
scrolled child makes it the normal case. Origin and clip are now two
arguments, not a coincidence -- `lb.content` is the FRAME (where local
(1, 1) is) and `inter` is the CLIP (which cells may be touched).

Layout computed ABSOLUTE regions and knows nothing about scrolling, so
every scrolled ancestor's shift is accumulated in `(sx, sy)` and applied
HERE, once. A wheel tick therefore never re-runs layout.

`sx, sy` are two bare `Int`s and NOT an `Offset` ON PURPOSE: measured,
an isbits STRUCT parameter is boxed once per call by the dynamic
dispatch on `w`, costing +32 B/node/frame on every app that never
scrolls. `0` is inside Julia's cached-`Int` range, so the unscrolled
path allocates nothing. Do not "simplify" this to an `Offset`.
"""
function _paint_node!(buf::Buffer, w::Widget, clip::Region,
                      sx::Int, sy::Int)::Nothing
    is_visible(w) || return nothing
    n = node(w)
    bs = n.box
    bs.display === Display.NONE && return nothing
    isempty(clip) && return nothing

    lb = _shift_box(n.layout, sx, sy)
    clipped = view(buf, clip)
    st = n.computed_style

    # 1. Background: the padding box, only when a bg is actually set --
    #    an UNSET bg is transparent, not "paint the default".
    if is_set(st.bg)
        fill_region!(clipped, _to_local(lb.padding_box, clip),
                     Cell(" ", st))
    end

    # 2. Border, on the perimeter of the border box.
    paint_border!(clipped, _to_local(lb.border_box, clip), bs.border)

    # 3. The widget itself. When the clip does not cut this node at all
    #    -- overwhelmingly the common case -- frame and clip coincide
    #    and we build THE EXACT VIEW THE PRE-SCROLL CODE BUILT, from the
    #    same expression: zero delta, byte-identical output. Only a
    #    genuinely clipped node pays for the split, and it gets a frame
    #    that is its FULL content box, so `size(buf)` is the widget's
    #    real content box and is INVARIANT UNDER SCROLL -- which is why
    #    a scrolled Label does not reflow and a scrolled Button does not
    #    re-centre.
    inter = intersect(lb.content, clip)
    if inter === lb.content
        render!(w, view(buf, inter))
    else
        render!(w, ScrolledView(buf, lb.content, inter))
    end

    # 4. Children, painted OVER the parent (painter's algorithm) in
    #    document order, narrowed by this node's overflow policy and
    #    shifted by its own scroll. LEAVES NEVER REACH `_child_clip`, so
    #    the majority of any tree skips two Region constructions and an
    #    intersect per frame.
    kids = children(w)
    isempty(kids) && return nothing
    kid_clip = _child_clip(bs, lb, clip)
    own = n.scroll
    kx, ky = sx - own.x, sy - own.y
    for c in kids
        _paint_node!(buf, c, kid_clip, kx, ky)
    end
    return nothing
end

"""
U1 + E2. The painter's algorithm, PRE-ORDER, so parents paint under
children. Returns `buf`.

Per visible node, in order:

  1. `fill_region!(buf, lb.padding_box, Cell(" ", style))` when
     `is_set(style.bg)`
  2. `paint_border!(buf, lb.border_box, box(w).border)`
  3. `render!(w, view(buf, lb.content))`
  4. children, each clipped to `lb.content` when overflow is
     HIDDEN/SCROLL (VISIBLE clips to the parent's own clip instead)

`Display.NONE` and invisible subtrees are skipped entirely.

There is no z-index: paint order IS document order, so a later sibling
covers an earlier one and a child covers its parent.
"""
function paint!(buf::Buffer, root::Widget)::Buffer
    _paint_node!(buf, root, buffer_region(buf))
    return buf
end

"""
Draw the eight glyphs of `b.kind` on the PERIMETER of `r`.

A no-op for `BorderKind.NONE`. `BorderKind.BLANK` draws spaces: it
occupies its cells and shows nothing.

The interior is never touched, and neither is anything outside `b` --
every write is bounds-clipped, so a border larger than its buffer is a
partial draw, not a throw. Degenerate boxes are handled by
construction: at width 1 the left and right edges coincide and the
corners collapse onto each other.
"""
function paint_border!(buf::AbstractMatrix{Cell}, r::Region,
                       b::Border)::Nothing
    b.kind === BorderKind.NONE && return nothing
    isempty(r) && return nothing

    g = border_glyphs(b.kind)
    # Build the eight cells once, not once per perimeter cell.
    cs = ntuple(i -> Cell(string(g[i]), b.style), 8)
    x0, y0 = r.x, r.y
    x1, y1 = right(r), bottom(r)

    # Edges first, then corners, so a corner always wins its cell.
    for x in (x0 + 1):(x1 - 1)
        set_cell!(buf, x, y0, cs[2])
        y1 == y0 || set_cell!(buf, x, y1, cs[6])
    end
    for y in (y0 + 1):(y1 - 1)
        set_cell!(buf, x0, y, cs[8])
        x1 == x0 || set_cell!(buf, x1, y, cs[4])
    end
    set_cell!(buf, x0, y0, cs[1])
    x1 == x0 || set_cell!(buf, x1, y0, cs[3])
    y1 == y0 || set_cell!(buf, x0, y1, cs[7])
    (x1 == x0 || y1 == y0) || set_cell!(buf, x1, y1, cs[5])
    return nothing
end
