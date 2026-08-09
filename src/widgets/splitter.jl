# widgets/splitter.jl -- layer 7.
# May reference: widget, reactive, dispatch, layout, unicode,
# `_sp_box!` (scroll.jl) -- USED, never redefined, as tabs.jl uses it.
#
# A HANDLE IS A WIDGET, and that is the whole design. Tachikoma paints
# its resize handles over the pane borders from the top-level view and
# hit-tests them against a table of rectangles it keeps itself; here the
# handle is a node between two panes, so it is hit-tested, painted and
# laid out by machinery that already exists and that nothing in this
# file re-implements.
#
# The one thing a handle CANNOT do for itself is follow a drag. A mouse
# that moves faster than the redraw leaves the one-cell handle, and the
# DRAG lands on a pane. So the SPLITTER consumes drags, in the CAPTURE
# phase, while one of its handles is down: it is an ancestor of whatever
# the cursor is over, so it sees the event first without any notion of
# pointer capture existing in the framework.

"The glyph a handle paints along its length, per axis."
const SPLIT_GLYPH_V = "│"
const SPLIT_GLYPH_H = "─"
"A handle being dragged, and the one under the pointer."
const SPLIT_ACTIVE = Style(; reverse = true)
"Smallest pane a drag may leave behind, in cells."
const SPLIT_MIN_PANE = 1

"""
The draggable divider between two panes. INTERNAL machinery of
`Splitter`, mounted by it and never by a caller.

One cell thick on the main axis and stretched on the cross axis, with
`grow = 0` and `shrink = 0` so the flex pass cannot eat it: a divider
that can be squeezed to nothing is a divider that cannot be grabbed.
"""
mutable struct SplitHandle <: Widget
    "Per-widget state."
    node::WidgetNode
    "True while this handle is the one being dragged. PAINT-reactive."
    active::Reactive{Bool}
end

"""
A row or column of panes separated by draggable handles.

The panes are children, and so are the handles, interleaved:
`pane, handle, pane, handle, pane`. A pane's share of the main axis is
its `grow`, so the layout engine already knows how to distribute it and
this widget only ever rewrites two numbers.
"""
mutable struct Splitter <: Widget
    "Per-widget state."
    node::WidgetNode
    "Main axis: `Direction.ROW` for side-by-side, `COLUMN` for stacked."
    direction::Direction.T
    """
    Index of the handle being dragged, `0` when idle. NOT reactive: it
    changes nothing on screen by itself -- the handle's own `active`
    cell does that.
    """
    dragging::Int
    "Pointer coordinate on the main axis when the drag began."
    drag_from::Int
    "Main-axis sizes of the two panes either side, when it began."
    drag_sizes::Tuple{Int,Int}
    "Their `grow` values when it began."
    drag_grows::Tuple{Float32,Float32}
    "Called as `on_resize(splitter)` after a drag changes the weights."
    on_resize::Any
end

_split_noop(::Any) = nothing

"""
True when `sp` lays its panes out along the horizontal axis.
"""
is_horizontal(sp::Splitter)::Bool =
    sp.direction === Direction.ROW || sp.direction === Direction.ROW_REVERSE

"""
A `Splitter` over `panes`, separated by handles.

`weights` is one positive number per pane, defaulting to equal shares;
they are ratios, so `[1, 1]` and `[3, 3]` describe the same split. A
handle is mounted between each neighbouring pair, which is why the
child list is `2n - 1` long and why `panes` and `handles` exist rather
than callers indexing `children` and counting in twos.
"""
function Splitter(panes::Widget...;
                  direction::Direction.T = Direction.ROW,
                  weights::AbstractVector{<:Real} = Float32[],
                  on_resize = _split_noop,
                  id::Symbol = gensym(:splitter),
                  classes = Symbol[])::Splitter
    n = length(panes)
    ws = isempty(weights) ? fill(1.0f0, n) : Float32.(weights)
    length(ws) == n || throw(ArgumentError(
        "weights has $(length(ws)) entries for $n panes"))
    all(>(0), ws) || throw(ArgumentError("every weight must be positive"))

    sp = Splitter(WidgetNode(; id = id, classes = classes,
                             type_name = :Splitter),
                  direction, 0, 0, (0, 0), (0.0f0, 0.0f0), on_resize)
    _sp_box!(sp, BoxPatch(; display = Display.FLEX, direction = direction))

    horiz = is_horizontal(sp)
    for (i, pane) in enumerate(panes)
        if i > 1
            h = SplitHandle(WidgetNode(; id = Symbol(id, :_handle, i - 1),
                                       type_name = :SplitHandle),
                            Reactive(false; kind = Dirty.PAINT))
            attach_reactives!(h)
            _sp_box!(h, horiz ?
                     BoxPatch(; width = cells(1), grow = 0.0f0,
                              shrink = 0.0f0) :
                     BoxPatch(; height = cells(1), grow = 0.0f0,
                              shrink = 0.0f0))
            invoke(mount!, Tuple{Widget,Widget}, sp, h)
        end
        _sp_box!(pane, BoxPatch(; grow = ws[i], shrink = 1.0f0))
        invoke(mount!, Tuple{Widget,Widget}, sp, pane)
    end
    attach_reactives!(sp)
    return sp
end

"""
Refuse a stray child.

The interleaving -- pane, handle, pane -- is what `panes`, `handles`
and every index in this file rely on. A child mounted from outside
would shift the parity and silently turn one pane into a handle, so the
constructor is the only way in, exactly as `add_tab!` is for `Tabs`.
"""
mount!(::Splitter, ::Widget) = throw(ArgumentError(
    "a Splitter's children are its panes and handles: pass the panes " *
    "to the constructor"))

"""
The panes, in order. Children `1, 3, 5, ...`.
"""
panes(sp::Splitter)::Vector{Widget} = children(sp)[1:2:end]

"""
The handles, in order. Children `2, 4, 6, ...`; handle `i` sits between
pane `i` and pane `i + 1`.
"""
handles(sp::Splitter)::Vector{Widget} = children(sp)[2:2:end]

"""
How many panes `sp` has.
"""
pane_count(sp::Splitter)::Int = (length(children(sp)) + 1) ÷ 2

"""
The current weights, one per pane.
"""
weights_of(sp::Splitter)::Vector{Float32} =
    Float32[box(p).grow for p in panes(sp)]

"""
Give the panes new weights and relayout. Every weight must be positive
and there must be one per pane.

THE single writer: a drag ends here too, so there is one place where a
split changes and one place to look when it changes wrongly.
"""
function set_weights!(sp::Splitter, ws::AbstractVector{<:Real})::Nothing
    ps = panes(sp)
    length(ws) == length(ps) || throw(ArgumentError(
        "weights has $(length(ws)) entries for $(length(ps)) panes"))
    all(>(0), ws) || throw(ArgumentError("every weight must be positive"))
    for (p, w) in zip(ps, ws)
        _sp_box!(p, BoxPatch(; grow = Float32(w)))
    end
    mark!(sp, Dirty.LAYOUT)
    return nothing
end

"""
`parent(w)` as a `Splitter`, or `nothing`.

The owner is `parent(w)` BY CONSTRUCTION -- `Splitter` mounts its
handles and nothing else ever mounts a `SplitHandle`. A handle with no
`Splitter` parent is INERT rather than an error, exactly as a bare
`TabStrip` is (tabs.jl): a test that builds one must not throw.
Internal.
"""
function _split_owner(w::SplitHandle)::Union{Nothing,Splitter}
    p = parent(w)
    return p isa Splitter ? p : nothing
end

"""
The index of handle `h` within its splitter, or `0`. Internal.
"""
function _split_index(sp::Splitter, h::SplitHandle)::Int
    for (i, x) in enumerate(handles(sp))
        x === h && return i
    end
    return 0
end

"""
Main-axis extent of `w`'s laid-out border box. Internal.
"""
_split_extent(sp::Splitter, w::Widget)::Int =
    is_horizontal(sp) ? layout_of(w).border_box.width :
                        layout_of(w).border_box.height

"""
Begin a drag of handle `i`, anchored at pointer coordinate `at`.

The anchor is the pointer AND the two panes' sizes as laid out right
now, not their weights: the weights are ratios over the whole splitter,
whereas a drag is a number of cells moved. Recording cells makes the
arithmetic below exact and independent of what the other panes are
doing. Internal.
"""
function _split_begin!(sp::Splitter, i::Int, at::Int)::Nothing
    ps = panes(sp)
    (1 <= i < length(ps)) || return nothing
    sp.dragging = i
    sp.drag_from = at
    sp.drag_sizes = (_split_extent(sp, ps[i]), _split_extent(sp, ps[i+1]))
    sp.drag_grows = (box(ps[i]).grow, box(ps[i+1]).grow)
    handles(sp)[i].active[] = true
    return nothing
end

"""
Move the live drag so the pointer sits at `at`, and return true when
the weights actually changed.

Only the two panes either side move, and their `grow` total is
preserved, so a drag NEVER disturbs a pane it is not between. Both are
clamped to `SPLIT_MIN_PANE`, which is what stops a drag past the end
from inverting them. Internal.
"""
function _split_move!(sp::Splitter, at::Int)::Bool
    i = sp.dragging
    i == 0 && return false
    (a0, b0) = sp.drag_sizes
    total = a0 + b0
    total > 0 || return false
    delta = clamp(at - sp.drag_from,
                  SPLIT_MIN_PANE - a0, b0 - SPLIT_MIN_PANE)
    a = a0 + delta
    b = total - a
    (ga, gb) = sp.drag_grows
    gsum = ga + gb
    gsum > 0 || return false
    na = Float32(gsum * a / total)
    nb = Float32(gsum - na)
    (na > 0 && nb > 0) || return false
    ps = panes(sp)
    (na === box(ps[i]).grow && nb === box(ps[i+1]).grow) && return false
    _sp_box!(ps[i], BoxPatch(; grow = na))
    _sp_box!(ps[i+1], BoxPatch(; grow = nb))
    mark!(sp, Dirty.LAYOUT)
    return true
end

"""
End the live drag. Internal.
"""
function _split_end!(sp::Splitter)::Nothing
    i = sp.dragging
    i == 0 && return nothing
    hs = handles(sp)
    i <= length(hs) && (hs[i].active[] = false)
    sp.dragging = 0
    return nothing
end

"""
Press on a handle: arm the drag on the owning splitter.

Only the press is handled here. Everything after it belongs to the
splitter, because a pointer that outruns the redraw is no longer over
this one-cell widget.
"""
function on_event!(w::SplitHandle, d::Dispatch{MouseEvent})::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    e = event(d)
    e.button === MouseButton.LEFT || return nothing
    e.action === MouseAction.PRESS || return nothing
    sp = _split_owner(w)
    sp === nothing && return nothing
    i = _split_index(sp, w)
    i == 0 && return nothing
    _split_begin!(sp, i, is_horizontal(sp) ? e.x : e.y)
    consume!(d)
    return nothing
end

"""
Follow a live drag, in the CAPTURE phase.

CAPTURE and not BUBBLE: capture runs root-first, so the splitter sees
the event BEFORE the pane the pointer has strayed onto and consumes it
there. That is pointer capture, obtained from the propagation order
that already exists rather than from a new mechanism in the app.

A no-op when no handle is down, which is every mouse event in a
splitter that is not being resized.
"""
function on_event!(sp::Splitter, d::Dispatch{MouseEvent})::Nothing
    sp.dragging == 0 && return nothing
    d.phase === Phase.CAPTURE || return nothing
    e = event(d)
    if e.action === MouseAction.RELEASE
        _split_end!(sp)
        consume!(d)
    elseif e.action === MouseAction.DRAG || e.action === MouseAction.MOVE
        _split_move!(sp, is_horizontal(sp) ? e.x : e.y) && sp.on_resize(sp)
        consume!(d)
    end
    return nothing
end
