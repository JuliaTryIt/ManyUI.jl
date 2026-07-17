# dispatch.jl -- layer 5. May reference: widget, events, geometry.
# E3: capture and bubble until consumed.

"""
Root to `target`, inclusive of both.

Separately named and PURE so the capture/bubble order assertion is a
literal vector comparison against a stub tree.
"""
propagation_path(target::Widget)::Vector{Widget} = path_from_root(target)

"""
The deepest VISIBLE widget whose `painted_region` contains the point, or
`nothing` when nothing is hit.

Pre-order descent; `Display.NONE` and invisible subtrees are skipped
entirely. Pure.
"""
hit_test(root::Widget, x::Int, y::Int)::Union{Nothing,Widget} =
    hit_test(root, Offset(x, y))

"""
The deepest VISIBLE widget whose `painted_region` contains `o`. Pure.

`painted_region`, NOT `region`: layout computes ABSOLUTE boxes and knows
nothing about scrolling, so inside a scrolled subtree `region(w)` is
where `w` WOULD be at scroll zero, while the pointer names a cell on the
SCREEN. Comparing against the unshifted box targets whatever happens to
occupy `w`'s unscrolled slot -- with a pane scrolled to `y = 3`, row 1
displays `L4` but the click lands on `L1`.

The two agree exactly outside a scrolled subtree (`paint_offset` is then
`ORIGIN`), so this is a no-op for every unscrolled tree. It costs
O(depth) per node visited, on the MOUSE path only, never on the frame
path -- `_paint_node!` threads the same shift down for free and does not
pay this.

Clipping needs no separate test: a node scrolled out of its pane is only
reached by descending THROUGH the pane, whose own box is unshifted and
already rejected the point.
"""
function hit_test(root::Widget, o::Offset)::Union{Nothing,Widget}
    is_visible(root) || return nothing
    box(root).display === Display.NONE && return nothing
    o in painted_region(root) || return nothing
    # Children are searched LAST-first: paint order is document order
    # (paint.jl), so where two siblings overlap the later one is what
    # the user sees and therefore what the click must reach.
    cs = children(root)
    for i in lastindex(cs):-1:firstindex(cs)
        hit = hit_test(cs[i], o)
        hit === nothing || return hit
    end
    return root
end

"""
`propagation_path(target)` truncated to begin at `root`, so a subtree
can be propagated through without the event reaching the widgets above
it.

Falls back to the full path when `root` is not an ancestor of `target`.
Pure. Internal.
"""
function _path_within(root::Widget, target::Widget)::Vector{Widget}
    path = propagation_path(target)
    i = findlast(w -> w === root, path)
    return i === nothing ? path : path[i:end]
end

"""
The capture, at-target and bubble walk over `path`, which runs root
first and ends at `path[1]`. Stops the instant the event is consumed.
Returns true iff it was. Internal.
"""
function _walk!(d::Dispatch, path::Vector{Widget})::Bool
    n = length(path)
    n == 0 && return false
    d.phase = Phase.CAPTURE
    for i in 1:(n - 1)
        d.current = path[i]
        on_event!(path[i], d)
        is_consumed(d) && return true
    end
    d.phase = Phase.AT_TARGET
    d.current = path[n]
    on_event!(path[n], d)
    is_consumed(d) && return true
    d.phase = Phase.BUBBLE
    for i in (n - 1):-1:1
        d.current = path[i]
        on_event!(path[i], d)
        is_consumed(d) && return true
    end
    return false
end

"""
E3. A pure TREE WALK -- it knows nothing about App or focus. Returns
true iff the event was consumed.

  1. `path = propagation_path(target)`
  2. CAPTURE: walk the path root to target, EXCLUDING target, with
     `d.phase = Phase.CAPTURE`
  3. AT_TARGET: `d.phase = Phase.AT_TARGET`, call on target
  4. BUBBLE: walk the path target to root, EXCLUDING target, with
     `d.phase = Phase.BUBBLE`

`d.current` is set to each visited widget before `on_event!(w, d)`, and
the walk STOPS the instant `is_consumed(d)`.
"""
propagate!(root::Widget, target::Widget, e::Event)::Bool =
    _walk!(Dispatch(e, target), _path_within(root, target))

"""
E3. Propagate an already-built envelope. Returns true iff consumed.
"""
propagate!(d::Dispatch)::Bool = _walk!(d, propagation_path(d.target))

"""
A mouse event goes to whatever is under the pointer, and to `root` when
the pointer is outside the tree entirely. Internal.
"""
_route(root::Widget, e::MouseEvent,
       ::Union{Nothing,Widget})::Union{Nothing,Widget} =
    something(hit_test(root, e.x, e.y), root)

"""
Keystrokes go to the focused widget, and to `root` when nothing has
focus. Internal.
"""
_route(root::Widget, ::KeyEvent,
       focus::Union{Nothing,Widget})::Union{Nothing,Widget} =
    focus === nothing ? root : focus

"""
A paste goes wherever a keystroke would. Internal.
"""
_route(root::Widget, ::PasteEvent,
       focus::Union{Nothing,Widget})::Union{Nothing,Widget} =
    focus === nothing ? root : focus

"""
`RefreshEvent` and `QuitEvent` are App-level only: the tree never sees
them. Internal.
"""
_route(::Widget, ::Union{RefreshEvent,QuitEvent},
       ::Union{Nothing,Widget})::Union{Nothing,Widget} = nothing

"""
Everything else -- resize, focus, tick and any user-defined `Event` --
is a whole-tree concern and goes to `root`, focus notwithstanding.
Internal.
"""
_route(root::Widget, ::Event,
       ::Union{Nothing,Widget})::Union{Nothing,Widget} = root

"""
E3. Route, then propagate. Returns true iff consumed.

NORMATIVE routing table:

    MouseEvent            -> `hit_test(root, e.x, e.y)`, falling back
                             to `root` when nothing is hit
    KeyEvent, PasteEvent  -> `focus`, falling back to `root` when
                             `focus === nothing`
    ResizeEvent,
    FocusEvent, TickEvent -> `root`
    RefreshEvent,
    QuitEvent             -> NOT ROUTED (App-level only; returns false)
"""
function dispatch_event!(root::Widget, e::Event,
                         focus::Union{Nothing,Widget} = nothing)::Bool
    target = _route(root, e, focus)
    target === nothing && return false
    return propagate!(root, target, e)
end

"""
The tab order: every visible, focusable widget in pre-order. Pure.
"""
function focusable_widgets(root::Widget)::Vector{Widget}
    out = Widget[]
    walk_visible(w -> (is_focusable(w) && push!(out, w); nothing), root)
    return out
end
