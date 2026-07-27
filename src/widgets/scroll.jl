# widgets/scroll.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode.
#
# Scrolling is not a widget: the compositor already knows how to shift a
# node's children (`WidgetNode.scroll`, applied in `paint.jl`). This file
# is POLICY over that -- where the offset may go, who moves it, and what
# the indicator looks like.

"""
When a `Scrollbar`'s track and thumb are drawn.

NOT the same axis of choice as `Overflow`: `Overflow` is a CLIPPING
policy owned by the box model; this is a scrollbar VISIBILITY policy
owned by the widget. Neither implies the other -- `NEVER` still scrolls.
"""
module ScrollMode
@enum T::UInt8 begin
    NEVER = 0    # no gutter, no bar; wheel and keys still scroll
    AUTO = 1     # gutter ALWAYS reserved; ink only when it can scroll
    ALWAYS = 2   # gutter reserved; bar always drawn
end
end

"""
Which axis a `Scrollbar` reports on.
"""
module ScrollAxis
@enum T::UInt8 begin
    VERTICAL = 0
    HORIZONTAL = 1
end
end

"""
Give `w` the geometry `p`, so that it holds under BOTH layout paths.

`inline_box` and `box` are set together ON PURPOSE, and neither alone is
enough. `layout!` reads `box` and never applies `inline_box`, so a test
that skips the cascade would see `BOX_DEFAULT`; and `apply_stylesheet!`
OVERWRITES `box` with `apply(BOX_DEFAULT, ..., inline_box)`, so a `box`
set at construction is gone the first time anything cascades. Writing
`box` as exactly the value an empty cascade would compute makes the two
paths agree by construction rather than by luck.

`merge` rather than assignment: the patch accumulates, so a later call
cannot silently drop the geometry an earlier one established.

Internal: this is the pane's own machinery, never a user knob.
"""
function _sp_box!(w::Widget, p::BoxPatch)::Nothing
    n = node(w)
    n.inline_box = merge(n.inline_box, p)
    n.box = apply(BOX_DEFAULT, n.inline_box)
    return nothing
end

# --- the scrollable seam ----------------------------------------------
#
# A node is scrollable iff it answers these three, and nothing else:
#
#     content_extent(w)::Size      -- how big the content is
#     layout_of(w).content::Region -- how big the window is
#     scroll_of(w)::Offset         -- where the window currently is
#
# There is no scrollable supertype, which is exactly why one `Scrollbar`
# serves a bare `Container`, a `Scrollpane`'s canvas and a `TextArea`.

"""
The scrollable content extent of `w`, in cells, measured from its
CONTENT-BOX ORIGIN.

Default: the bounding box of the laid-out children's MARGIN boxes,
straight from the `LayoutMap` the engine already computed -- one pass
over the children, no re-measure, no relayout. That is why a wheel tick
is free.

Reads `layout_of(k)`, the UNSHIFTED absolute box, so the extent is
independent of the current scroll offset and a scroll can never feed
back into the extent.

A widget whose content is DATA rather than children overrides this;
`TextArea` is the worked example. Pure.
"""
function content_extent(w::Widget)::Size
    u = EMPTY_REGION
    for k in children(w)
        _laid_out(k) || continue
        u = union(u, layout_of(k).margin_box)
    end
    isempty(u) && return Size(0, 0)
    c = layout_of(w).content
    return Size(max(0, right(u) - c.x + 1), max(0, bottom(u) - c.y + 1))
end

"""
The largest in-range scroll offset: `content_extent - content box`,
clamped at zero per axis, via `clamp_scroll`. Pure.
"""
function max_scroll(w::Widget)::Offset
    e = content_extent(w)
    c = layout_of(w).content
    return Offset(max(0, e.width - c.width),
                  max(0, e.height - c.height))
end

"""
Scroll `w` to `o`, CLAMPED per axis to `0:max_scroll(w)`. Returns the
offset ACTUALLY STORED.

Returning the stored offset is what makes scroll chaining fall out for
free: a caller detects "this pane is at its limit" with
`scroll_to!(w, o) === before` and simply does not consume the event.
"""
function scroll_to!(w::Widget, o::Offset)::Offset
    e = content_extent(w)
    c = layout_of(w).content
    v = Offset(clamp_scroll(o.x, c.width, e.width),
               clamp_scroll(o.y, c.height, e.height))
    set_scroll!(w, v)
    return v
end

"""
`scroll_to!(w, scroll_of(w) + d)`. Returns the stored offset.
"""
scroll_by!(w::Widget, d::Offset)::Offset =
    scroll_to!(w, scroll_of(w) + d)

"""
The shift `w` has ALREADY been given by scrolling nodes strictly between
it and `vp`, exclusive of `vp` itself.

`ORIGIN` when `vp` is `w`'s parent, and `nothing` when `vp` is not an
ancestor of `w` at all -- which is how `scroll_into_view!` tells "already
in the right place" from "not my descendant" without a second walk. Pure.
Internal.
"""
function _scroll_between(vp::Widget, w::Widget)::Union{Nothing,Offset}
    acc = ORIGIN
    a = parent(w)
    while a !== nothing
        a === vp && return acc
        acc = acc + node(a).scroll
        a = parent(a)
    end
    return nothing
end

"""
Scroll `vp` the MINIMUM needed to bring descendant `w`'s margin box
inside `vp`'s content box, on both axes, via `scroll_into_view`. Returns
the stored offset.

Reads `layout_of`, i.e. UNSHIFTED geometry, so it is correct whatever
the current offset is, and idempotent. A no-op when `w` is not a
descendant of `vp`.

Panes BETWEEN `vp` and `w` have already moved `w` and their shift is
subtracted here, which is why `reveal!` must run NEAREST FIRST: an inner
pane has to finish moving before `vp` can measure where `w` ended up.
"""
function scroll_into_view!(vp::Widget, w::Widget)::Offset
    acc = _scroll_between(vp, w)
    acc === nothing && return scroll_of(vp)
    c = layout_of(vp).content
    m = layout_of(w).margin_box
    s = scroll_of(vp)
    lo_x = m.x - acc.x - c.x
    lo_y = m.y - acc.y - c.y
    nx = scroll_into_view(s.x, c.width, lo_x, lo_x + m.width - 1)
    ny = scroll_into_view(s.y, c.height, lo_y, lo_y + m.height - 1)
    return scroll_to!(vp, Offset(nx, ny))
end

# --- Scrollpane -------------------------------------------------------

"""
A scrolling viewport over exactly ONE child.

Holds no offset of its own: the offset is `node(w.canvas).scroll`, the
core field, so a wheel tick is one `Dirty.PAINT` mark and layout never
runs. `Scrollpane` is therefore policy over a compositor that already
knows how to shift an origin.

Focusable by default, so a pane with no focusable children is still
keyboard-scrollable.

ONE child: wrap several in a `Container`, exactly as CSS makes you.
"""
mutable struct Scrollpane <: Widget
    "Per-widget state."
    node::WidgetNode
    "Internal flex row holding the canvas and the vertical bar."
    const row::Container
    "The node that carries the scroll offset. Its content box IS the
    window, so `content_extent` and `layout_of(...).content` mean two
    different things and the pane can tell whether it can scroll."
    const canvas::Container
    "Internal node holding the user's child at its NATURAL size, which
    is what overflows the canvas and therefore what there is to scroll."
    const holder::Container
    "Vertical scrollbar policy."
    const bar_y::ScrollMode.T
    "Horizontal scrollbar policy."
    const bar_x::ScrollMode.T
    "Cells one vertical wheel notch scrolls."
    const wheel_step::Int
    "Cells one horizontal wheel notch scrolls."
    const wheel_step_x::Int
end

"""
A pane scrolling `child`, or an empty one.

The node geometry is:

    Scrollpane                     display FLEX, direction COLUMN
      +-- row                      FLEX ROW, grow 1
      |     +-- canvas             grow 1, overflow SCROLL  <-- THE WINDOW
      |     |     +-- holder       shrink 0, grow 0         <-- THE CONTENT
      |     |           +-- child
      |     +-- vbar               width 1        [iff bar_y !== NEVER]
      +-- hbar                     height 1       [iff bar_x !== NEVER]

Two of those lines carry the whole design and neither is negotiable:

  * `shrink = 0f0` on the HOLDER is what creates the overflow. The
    default `shrink` is `1f0`, so without it the flex kernel absorbs the
    overflow and squeezes the content down to the window -- an 8-row
    document in a 3-row window collapses to 3 rows and there is nothing
    left to scroll.
  * `align = Align.START` on the canvas is what stops the holder's WIDTH
    being stretched to the window. `Align.STRETCH`, the default, would
    pin the content's width to the window's and horizontal scrolling
    could never happen at all.

The canvas is the WINDOW and the holder is the CONTENT, deliberately two
nodes: one box cannot be both 3 rows tall (what you see) and 8 rows tall
(what there is), and the scrollable seam reads the first from
`layout_of(canvas).content` and the second from `content_extent(canvas)`.
"""
function Scrollpane(child::Union{Nothing,Widget} = nothing;
                    bar_y::ScrollMode.T = ScrollMode.AUTO,
                    bar_x::ScrollMode.T = ScrollMode.NEVER,
                    wheel_step::Int = 3, wheel_step_x::Int = 6,
                    focusable::Bool = true,
                    id::Symbol = gensym(:scrollpane),
                    classes = Symbol[])::Scrollpane
    holder = Container(; id = Symbol(id, :_holder))
    _sp_box!(holder, BoxPatch(; shrink = 0f0, grow = 0f0))

    canvas = Container(; id = Symbol(id, :_canvas))
    _sp_box!(canvas, BoxPatch(; display = Display.FLEX,
                              direction = Direction.COLUMN,
                              align = Align.START, grow = 1f0,
                              overflow_x = Overflow.SCROLL,
                              overflow_y = Overflow.SCROLL))
    mount!(canvas, holder)

    row = Container(; id = Symbol(id, :_row))
    _sp_box!(row, BoxPatch(; display = Display.FLEX,
                           direction = Direction.ROW, grow = 1f0,
                           overflow_x = Overflow.HIDDEN,
                           overflow_y = Overflow.HIDDEN))
    mount!(row, canvas)
    if bar_y !== ScrollMode.NEVER
        vbar = Scrollbar(canvas, ScrollAxis.VERTICAL; mode = bar_y,
                         id = Symbol(id, :_vbar))
        _sp_box!(vbar, BoxPatch(; width = cells(1), shrink = 0f0,
                                grow = 0f0))
        mount!(row, vbar)
    end

    p = Scrollpane(WidgetNode(; id = id, classes = classes,
                              type_name = :Scrollpane,
                              focusable = focusable),
                   row, canvas, holder, bar_y, bar_x, wheel_step,
                   wheel_step_x)
    _sp_box!(p, BoxPatch(; display = Display.FLEX,
                         direction = Direction.COLUMN,
                         overflow_x = Overflow.HIDDEN,
                         overflow_y = Overflow.HIDDEN))
    # `invoke`, because `mount!(::Scrollpane, ::Widget)` below forwards
    # to the holder: the pane's own machinery must bypass the very
    # redirection that machinery exists to provide.
    invoke(mount!, Tuple{Widget,Widget}, p, row)
    if bar_x !== ScrollMode.NEVER
        hbar = Scrollbar(canvas, ScrollAxis.HORIZONTAL; mode = bar_x,
                         id = Symbol(id, :_hbar))
        _sp_box!(hbar, BoxPatch(; height = cells(1), shrink = 0f0,
                                grow = 0f0))
        invoke(mount!, Tuple{Widget,Widget}, p, hbar)
    end
    child === nothing || mount!(p, child)
    return p
end

"""
Mount `c` INTO the canvas, not onto the pane: `children(pane)` is the
pane's own machinery and the user never addresses it. Throws
`ArgumentError` when the canvas already holds a child.
"""
function mount!(p::Scrollpane, c::Widget)::Widget
    isempty(children(p.holder)) || throw(ArgumentError(
        "Scrollpane $(repr(id(p))) already holds a child; wrap several " *
        "in a Container"))
    mount!(p.holder, c)
    return p
end

"""
The scrolling node of `p` -- what `scroll_to!`, `max_scroll` and
`content_extent` take. `p.canvas`.
"""
viewport(p::Scrollpane)::Container = p.canvas

# The pane forwards the scrolling vocabulary to its canvas.
#
# `Scrollpane <: Widget`, so without these the generic `::Widget` methods
# apply and silently measure the pane's own node, whose only child is the
# internal row -- an extent equal to the viewport, hence a `max_scroll` of
# `ORIGIN` and a `scroll_to!` that clamps every request to nothing and
# reports success. `viewport(p)` stays the explicit form; these make the
# obvious call correct rather than quietly inert.
#
# Safe because nothing reads a pane's OWN `node(p).scroll`: `paint_offset`
# and `_scroll_between` walk `node(a).scroll` directly, so the pane's node
# keeps its zero offset and paint still shifts the row by nothing.

"""
`content_extent(viewport(p))`: what `p` shows, not the shell around it.
"""
content_extent(p::Scrollpane)::Size = content_extent(p.canvas)

"""
`max_scroll(viewport(p))`: how far `p` can actually scroll.
"""
max_scroll(p::Scrollpane)::Offset = max_scroll(p.canvas)

"""
`scroll_of(viewport(p))`: where `p` is currently scrolled to.

This is also what makes the generic `scroll_by!(p, d)` --
`scroll_to!(p, scroll_of(p) + d)` -- accumulate against the canvas's real
offset instead of the pane's permanent zero.
"""
scroll_of(p::Scrollpane)::Offset = scroll_of(p.canvas)

"""
`scroll_to!(viewport(p), o)`. Returns the offset actually stored.
"""
scroll_to!(p::Scrollpane, o::Offset)::Offset = scroll_to!(p.canvas, o)

"""
`scroll_into_view!(viewport(p), w)`: scroll `p` the minimum needed to
reveal descendant `w`.
"""
scroll_into_view!(p::Scrollpane, w::Widget)::Offset =
    scroll_into_view!(p.canvas, w)

"""
True when `d` is a strict descendant of `p`'s HOLDER, i.e. genuinely the
user's content rather than the pane's own machinery. Pure. Internal.

`row`, `canvas`, the bars and the holder itself all answer false, which
is what stops `reveal!` on a focused scrollbar rewinding the pane to the
top.
"""
function _sp_is_content(p::Scrollpane, d::Widget)::Bool
    a = parent(d)
    while a !== nothing
        a === p.holder && return true
        a === p && return false
        a = parent(a)
    end
    return false
end

"""
Bring descendant `d` into the pane's window. Overrides the `widget.jl`
hook; a no-op for the pane's own machinery (`row`, `canvas`, the bars).
"""
function reveal_child!(w::Scrollpane, d::Widget)::Nothing
    _sp_is_content(w, d) || return nothing
    scroll_into_view!(w.canvas, d)
    return nothing
end

"""
Re-clamp the stored offset to the CURRENT geometry, as the pane paints.

Layout can move under a scroll offset that was legal when it was stored:
grow the terminal until the content fits and an offset of 5 becomes an
offset past the end, painting blank rows under content that would now fit
whole. Nothing else can catch it -- `handle!(app, ::ResizeEvent)`
relayouts WITHOUT dispatching the event to the tree, so no `on_event!`
method ever sees a resize.

`paint!` is PRE-ORDER, so this runs before the canvas and its subtree
paint and the correction lands in the SAME frame. It converges: once in
range `set_scroll!` is a no-op that marks nothing, and `mark!` never
wakes the app, so marking `PAINT` mid-paint cannot loop.

THE PRICE, measured rather than asserted: 208 B/frame/pane, all of it
the dynamic dispatch `content_extent` pays walking the canvas's
`Vector{Widget}` -- the same dispatch `paint!` itself pays per node. For
scale, a 149-node frame allocates 44672 B, so a pane costs ~0.5% of one.
It is UNCONDITIONAL on purpose: caching the last window would miss the
case where the CONTENT shrinks under a fixed window, which strands the
offset past the end just as surely.
"""
function render!(w::Scrollpane, ::AbstractMatrix{Cell})::Nothing
    scroll_to!(w.canvas, scroll_of(w.canvas))
    return nothing
end

"""
True while `d` is live and at or past its target.

CAPTURE is excluded deliberately: acting there would let an OUTER pane
steal the wheel from the inner pane the pointer is actually over. Pure.
Internal.
"""
_sp_acts(d::Dispatch)::Bool =
    d.phase !== Phase.CAPTURE && !is_consumed(d)

"""
Move `w`'s canvas by `d` and consume `disp` IFF the offset actually
changed.

The whole of scroll chaining is this one rule: a pane at its limit does
not consume, so the event bubbles to the next pane out and that pane
takes over. No pane knows another exists. Internal.
"""
function _sp_move!(w::Scrollpane, disp::Dispatch, d::Offset)::Nothing
    before = scroll_of(w.canvas)
    scroll_by!(w.canvas, d) === before && return nothing
    consume!(disp)
    return nothing
end

"""
Scroll on the wheel; `shift` swaps the axis.

Wheel events route to whatever is under the pointer and reach the pane
on the way UP, so the INNERMOST pane gets first refusal. CONSUMES ONLY
WHEN IT ACTUALLY MOVED: a pane at its limit lets the notch bubble to the
next pane out -- scroll chaining, out of the phase rule alone.

CAPTURE is excluded deliberately: acting there would let an outer pane
steal the wheel from the inner pane the pointer is over.
"""
function on_event!(w::Scrollpane, d::Dispatch{MouseEvent})::Nothing
    _sp_acts(d) || return nothing
    e = event(d)
    is_scroll(e) || return nothing
    b = e.button
    back = b === MouseButton.WHEEL_UP || b === MouseButton.WHEEL_LEFT
    vert = b === MouseButton.WHEEL_UP || b === MouseButton.WHEEL_DOWN
    (Modifier.SHIFT in e.mods) && (vert = !vert)
    step = (back ? -1 : 1) * (vert ? w.wheel_step : w.wheel_step_x)
    _sp_move!(w, d, vert ? Offset(0, step) : Offset(step, 0))
    return nothing
end

"""
The distance `code` scrolls `w`, or `nothing` when the key is not one of
the pane's. Pure with respect to the tree. Internal.

`HOME`/`END` are a HUGE delta rather than a computed target, and letting
`scroll_to!` clamp it IS the implementation: "go as far as you can" needs
no knowledge of how far that is. `typemax(Int) ÷ 2` so that
`scroll_of(w) + d` cannot overflow.
"""
function _sp_key_delta(w::Scrollpane,
                       code::Key.T)::Union{Nothing,Offset}
    s = w.wheel_step
    code === Key.UP && return Offset(0, -s)
    code === Key.DOWN && return Offset(0, s)
    code === Key.LEFT && return Offset(-s, 0)
    code === Key.RIGHT && return Offset(s, 0)
    if code === Key.PAGE_UP || code === Key.PAGE_DOWN
        # One viewport LESS ONE ROW: the last row of the old page is the
        # first row of the new one, so the reader keeps a landmark.
        page = max(1, layout_of(w.canvas).content.height - 1)
        return code === Key.PAGE_UP ? Offset(0, -page) : Offset(0, page)
    end
    huge = typemax(Int) ÷ 2
    code === Key.HOME && return Offset(0, -huge)
    code === Key.END && return Offset(0, huge)
    return nothing
end

"""
UP/DOWN/LEFT/RIGHT by `wheel_step`; PAGE_UP/PAGE_DOWN by one viewport
LESS ONE ROW of overlap, so the reader keeps a landmark; HOME/END to the
extremes of the vertical axis. Unmodified keys only, BUBBLE/AT_TARGET
only, and consuming only on real movement.

A focused `TextInput` consumes LEFT/RIGHT AT TARGET, so the pane never
sees them. That precedence costs zero special-casing.
"""
function on_event!(w::Scrollpane, d::Dispatch{KeyEvent})::Nothing
    _sp_acts(d) || return nothing
    e = event(d)
    isempty(e.mods) || return nothing
    delta = _sp_key_delta(w, e.code)
    delta === nothing && return nothing
    _sp_move!(w, d, delta)
    return nothing
end

# --- Scrollbar --------------------------------------------------------

"""
The visible scroll indicator for one axis of `viewport`.

PARAMETRIC on the viewport type -- the `Button{F}` pattern -- so
`viewport` is a CONCRETE field and `content_extent`/`layout_of` dispatch
statically. This is also what lets ONE `Scrollbar` serve a
`Scrollpane`'s `Container` canvas AND a `TextArea`, which scrolls data
rather than children: the scrollable seam is three functions, not a
type.

A SIBLING of the canvas, never a child of it: the core shifts only a
node's children, so a bar is never inside a scrolled subtree and
`local_offset` on it is always honest.
"""
mutable struct Scrollbar{V<:Widget} <: Widget
    "Per-widget state."
    node::WidgetNode
    "The axis this bar reports and controls."
    const axis::ScrollAxis.T
    "When the track and thumb are drawn."
    const mode::ScrollMode.T
    "The scrolling node this bar reports on."
    const viewport::V
end

"""
A bar reporting on `vp` along `axis`.
"""
function Scrollbar(vp::V, axis::ScrollAxis.T;
                   mode::ScrollMode.T = ScrollMode.AUTO,
                   id::Symbol = gensym(:scrollbar),
                   classes = Symbol[])::Scrollbar{V} where {V<:Widget}
    return Scrollbar{V}(WidgetNode(; id = id, classes = classes,
                                   type_name = :Scrollbar),
                        axis, mode, vp)
end

"""
Thumb geometry on a `track`-cell track, for a `view`-cell window over
`total` cells of content scrolled to `off`.

Returns `(start, len)`, 1-based inclusive within the track, or `(0, 0)`
when there is no track or nothing to scroll.

NORMATIVE:

  * `len = clamp(round(Int, track * view / total), 1, track)`. NEVER
    zero: an invisible thumb is a broken scrollbar, and a 1-cell thumb
    on a 40-cell track is the honest rendering of a 40x document.
  * `start` maps `0:(total - view)` onto `1:(track - len + 1)`, so
    `off == 0` pins the thumb to the FIRST cell and `off == total -
    view` pins it to the LAST (`start + len - 1 == track`) EXACTLY. The
    two ends are the only positions a user can verify at a glance, so
    they are the two the arithmetic is written around.

Pure: four `Int`s, no widget, no layout, no buffer -- the whole of this
widget's behaviour is one table test.
"""
function thumb_span(track::Int, view::Int, total::Int,
                    off::Int)::Tuple{Int,Int}
    (track <= 0 || view <= 0 || total <= 0) && return (0, 0)
    total <= view && return (0, 0)          # nothing to scroll
    len = clamp(round(Int, track * view / total), 1, track)
    span = total - view                     # > 0
    room = track - len                      # >= 0
    room == 0 && return (1, len)
    start = 1 + round(Int, clamp(off, 0, span) * room / span)
    return (start, len)
end

"""
The scroll offset a thumb starting at `start` represents: the inverse of
`thumb_span`'s `start` mapping. Pure. Internal.

Exact at both ends by construction, because it inverts the same
`room`/`span` ratio rather than deriving an independent one.
"""
function _sb_offset(start::Int, len::Int, track::Int, view::Int,
                    total::Int)::Int
    span = total - view
    room = track - len
    (span <= 0 || room <= 0) && return 0
    return clamp(round(Int, (start - 1) * span / room), 0, span)
end

"Track glyph. Width-1 BY CONSTRUCTION, asserted in the suite."
const SB_TRACK_V = "│"
"Track glyph. Width-1 BY CONSTRUCTION, asserted in the suite."
const SB_TRACK_H = "─"
"Thumb glyph. Width-1 BY CONSTRUCTION, asserted in the suite."
const SB_THUMB = "█"

"""
`Size(1, 0)` vertical, `Size(0, 1)` horizontal: a bar is one cell thick
and claims nothing on its long axis. Pure with respect to the tree.
"""
measure(w::Scrollbar, avail::Size)::Size =
    w.axis === ScrollAxis.VERTICAL ? Size(1, 0) : Size(0, 1)

"""
`(track, view, total, off)` for `w`, read from the scrollable seam and
nothing else.

It never measures anything and never touches the pane, which is why one
`Scrollbar` serves a bare `Container`, a `Scrollpane`'s canvas and a
`TextArea` identically. `off` is clamped FOR DISPLAY only: the stored
offset may legitimately be stale for one frame, and a thumb off the end
of its track is worse than a thumb that led by one frame. Internal.
"""
function _sb_metrics(w::Scrollbar,
                     track::Int)::NTuple{4,Int}
    e = content_extent(w.viewport)
    c = layout_of(w.viewport).content
    s = scroll_of(w.viewport)
    vert = w.axis === ScrollAxis.VERTICAL
    total = vert ? e.height : e.width
    view = vert ? c.height : c.width
    off = vert ? s.y : s.x
    return (track, view, total, clamp_scroll(off, view, total))
end

"""
Write one cell of the bar, in the bar's own long-axis coordinate.
Internal.
"""
_sb_put!(w::Scrollbar, buf::AbstractMatrix{Cell}, i::Int,
         g::AbstractString, st::Style)::Int =
    w.axis === ScrollAxis.VERTICAL ? set_cell!(buf, 1, i, g, st) :
                                     set_cell!(buf, i, 1, g, st)

"""
Draw the track, then the thumb over it.

`ScrollMode.AUTO` with nothing to scroll draws NOTHING and leaves the
reserved gutter blank -- the gutter is stable, the ink is not.
`ScrollMode.ALWAYS` with nothing to scroll draws a FULL-LENGTH thumb,
the honest picture of "all of it is visible".
"""
function render!(w::Scrollbar, buf::AbstractMatrix{Cell})::Nothing
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    w.mode === ScrollMode.NEVER && return nothing
    vert = w.axis === ScrollAxis.VERTICAL
    track = vert ? height : width
    st = computed_style(w)
    (start, len) = thumb_span(_sb_metrics(w, track)...)
    if len == 0
        # Nothing to scroll. AUTO keeps the gutter and drops the ink;
        # ALWAYS says so with a thumb that fills the track.
        w.mode === ScrollMode.AUTO && return nothing
        start, len = 1, track
    else
        g = vert ? SB_TRACK_V : SB_TRACK_H
        for i in 1:track
            _sb_put!(w, buf, i, g, st)
        end
    end
    for i in start:(start + len - 1)
        _sb_put!(w, buf, i, SB_THUMB, st)
    end
    return nothing
end

"""
Jump the viewport so the thumb centres on the pointer; drag continues
it. LEFT button only.

`local_offset(d)` is measured from the bar's UNSHIFTED border box, which
is correct here precisely because a scrollbar is never inside a scrolled
subtree.
"""
function on_event!(w::Scrollbar, d::Dispatch{MouseEvent})::Nothing
    _sp_acts(d) || return nothing
    w.mode === ScrollMode.NEVER && return nothing
    e = event(d)
    e.button === MouseButton.LEFT || return nothing
    (e.action === MouseAction.PRESS || e.action === MouseAction.DRAG) ||
        return nothing
    vert = w.axis === ScrollAxis.VERTICAL
    r = region(w)
    track = vert ? r.height : r.width
    (_, view, total, _) = _sb_metrics(w, track)
    (_, len) = thumb_span(track, view, total, 0)
    len == 0 && return nothing              # nothing to scroll
    o = local_offset(d)
    p = vert ? o.y : o.x
    start = clamp(p - (len - 1) ÷ 2, 1, track - len + 1)
    off = _sb_offset(start, len, track, view, total)
    s = scroll_of(w.viewport)
    scroll_to!(w.viewport, vert ? Offset(s.x, off) : Offset(off, s.y))
    scroll_of(w.viewport) === s && return nothing
    consume!(d)
    return nothing
end
