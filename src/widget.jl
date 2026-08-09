# widget.jl -- layer 4. May reference: types, geometry, style, boxmodel.
# U1 (the tree) and E1 (dirty flagging).

"""
What is stale about a node. Values are powers of two: they are combined
in a `DirtyMask`.

`SUBTREE` is a BREADCRUMB, not dirt: it means "a descendant is dirty",
and it is what lets a frame pass skip clean subtrees in O(depth)
instead of O(n).
"""
module Dirty
@enum T::UInt8 begin
    NONE = 0x00
    PAINT = 0x01    # repaint only; geometry unchanged
    LAYOUT = 0x02   # re-measure / re-arrange
    STYLE = 0x04    # re-run the cascade
    SUBTREE = 0x08  # BREADCRUMB: a descendant is dirty. NOT dirt.
end
end

"""
Bitset over `Dirty.T` values.
"""
const DirtyMask = UInt8

"""
`PAINT | LAYOUT | STYLE`. Note that it excludes the `SUBTREE`
breadcrumb.
"""
const DIRTY_ALL = UInt8(0x07)

"""
True when `k` is set in `m`. Pure.
"""
has_dirty(m::DirtyMask, k::Dirty.T)::Bool = (m & UInt8(k)) != 0x00

"""
`m` with `k` set. Pure.
"""
set_dirty(m::DirtyMask, k::Dirty.T)::DirtyMask = m | UInt8(k)

"""
`m` with `k` cleared. Pure.
"""
clear_dirty(m::DirtyMask, k::Dirty.T)::DirtyMask = m & ~UInt8(k)

"""
Per-widget state, held by COMPOSITION: every widget HAS a node. No
abstract-field inheritance anywhere.

`parent`/`children` are `Widget`-typed by necessity -- a heterogeneous
tree is the point -- and every hot path recovers inference through
`node(w)`, whose return type is concrete.
"""
mutable struct WidgetNode
    "CSS id; `gensym(:w)` when unset."
    const id::Symbol
    "CSS classes."
    const classes::Set{Symbol}
    "Type name, for CSS type selectors."
    const type_name::Symbol
    "Parent widget, or `nothing` at the root."
    parent::Union{Nothing,Widget}
    "Child widgets, in paint and tab order."
    const children::Vector{Widget}
    "Author-set style; highest specificity."
    inline_style::Style
    "Author-set box overrides; highest specificity."
    inline_box::BoxPatch
    "Post-cascade style."
    computed_style::Style
    "Post-cascade layout inputs."
    box::BoxStyle
    "Post-layout boxes, in ABSOLUTE coordinates."
    layout::LayoutBox
    """
    Cells this node's CHILDREN are shifted by at paint time. `ORIGIN` is
    unscrolled.

    `Offset(3, 0)` means "scrolled right by 3", so a child paints three
    cells to the LEFT. Shifts the CHILDREN and NEVER this node's own
    render frame -- that is what keeps `size(buf)` inside `render!`
    invariant under scroll. A widget with no children that scrolls its
    own content reads this field itself.

    NEVER an input to `compute_layout`: the `LayoutMap` is invariant
    under scrolling, which is why a wheel tick is a repaint and not a
    relayout.
    """
    scroll::Offset
    "What is stale about this node."
    dirty::DirtyMask
    "False hides the node and its subtree."
    visible::Bool
    "True makes the node part of the tab order."
    focusable::Bool
    "The owning App, once mounted."
    app::Any
    "Optional callback when focus is gained."
    on_focus::Union{Nothing,Function}
    "Optional callback when focus is lost."
    on_blur::Union{Nothing,Function}
end

"""
A fresh node: no parent, no children, nothing cascaded, nothing laid
out, everything dirty.
"""
WidgetNode(; id::Symbol = gensym(:w),
             classes = Symbol[],
             type_name::Symbol = :Widget,
             visible::Bool = true,
             focusable::Bool = false,
             on_focus::Union{Nothing,Function} = nothing,
             on_blur::Union{Nothing,Function} = nothing)::WidgetNode =
    WidgetNode(id, Set{Symbol}(classes), type_name, nothing, Widget[],
               STYLE_NONE, BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
               LAYOUT_BOX_EMPTY, ORIGIN, DIRTY_ALL, visible, focusable,
               nothing, on_focus, on_blur)

"""
The pre-scroll POSITIONAL form: `scroll` defaults to `ORIGIN`.

Exists because adding a field silently invalidates the auto-generated
positional constructor, and call sites in `test_paint.jl` and
`css_tests.jl` depend on the 14-argument shape. Keep the argument order
in lockstep with the struct.
"""
WidgetNode(id::Symbol, classes::Set{Symbol}, type_name::Symbol,
           parent::Union{Nothing,Widget}, children::Vector{Widget},
           inline_style::Style, inline_box::BoxPatch,
           computed_style::Style, box::BoxStyle, layout::LayoutBox,
           dirty::DirtyMask, visible::Bool, focusable::Bool,
           app::Any, on_focus::Union{Nothing,Function} = nothing,
           on_blur::Union{Nothing,Function} = nothing)::WidgetNode =
    WidgetNode(id, classes, type_name, parent, children, inline_style,
               inline_box, computed_style, box, layout, ORIGIN, dirty,
               visible, focusable, app, on_focus, on_blur)

"""
The positional form that names `scroll` explicitly, retained for
compatibility after adding focus callbacks to `WidgetNode`.
"""
WidgetNode(id::Symbol, classes::Set{Symbol}, type_name::Symbol,
           parent::Union{Nothing,Widget}, children::Vector{Widget},
           inline_style::Style, inline_box::BoxPatch,
           computed_style::Style, box::BoxStyle, layout::LayoutBox,
           scroll::Offset, dirty::DirtyMask, visible::Bool,
           focusable::Bool, app::Any)::WidgetNode =
    WidgetNode(id, classes, type_name, parent, children, inline_style,
               inline_box, computed_style, box, layout, scroll, dirty,
               visible, focusable, app, nothing, nothing)

"""
THE one required method per widget type. The default duck-types on the
field name; override only for exotic widgets.
"""
node(w::Widget)::WidgetNode = w.node

"""
CSS id of `w`. Pure.
"""
id(w::Widget)::Symbol = node(w).id

"""
CSS classes of `w`. Pure.
"""
classes(w::Widget)::Set{Symbol} = node(w).classes

"""
Type name of `w`, as CSS type selectors see it. Pure.
"""
type_name(w::Widget)::Symbol = node(w).type_name

"""
Parent of `w`, or `nothing` at the root. Pure.
"""
parent(w::Widget)::Union{Nothing,Widget} = node(w).parent

"""
Children of `w`, in paint and tab order. Pure.
"""
children(w::Widget)::Vector{Widget} = node(w).children

"""
The four resolved boxes of `w`. Pure.
"""
layout_of(w::Widget)::LayoutBox = node(w).layout

"""
`node(w).layout.border_box`. Pure.
"""
region(w::Widget)::Region = node(w).layout.border_box

"""
`node(w).layout.content`. Pure.
"""
content_region(w::Widget)::Region = node(w).layout.content

"""
`node(w).scroll`. Pure.
"""
scroll_of(w::Widget)::Offset = node(w).scroll

"""
Set the shift applied to `w`'s CHILDREN at paint time. Returns true iff
it changed.

Clamped at ZERO per axis only. The UPPER bound needs the content extent,
which this layer cannot see -- `scroll_to!` in `widgets/scroll.jl` owns
it. An over-scroll is a UX bug (blank cells), never corruption.

Marks `Dirty.PAINT` and NOTHING ELSE, and this is the whole "a wheel
tick does not re-run layout" claim: `mark!` with PAINT sets PAINT on `w`
alone and drops only `SUBTREE` breadcrumbs on ancestors; it calls
`escalate_auto!` ONLY for `Dirty.LAYOUT`. `dirty_root` then finds no
real LAYOUT and returns `nothing`, so `relayout!` returns on its first
line -- and `compute_layout` never reads this field anyway.

`mark!(w, Dirty.PAINT)` and NOT `mark_subtree_dirty!`: the normative
rule above is "PAINT on w -> w ONLY", and `frame!` repaints the whole
tree unconditionally in any case.
"""
function set_scroll!(w::Widget, o::Offset)::Bool
    n = node(w)
    v = Offset(max(0, o.x), max(0, o.y))
    n.scroll === v && return false      # isbits: structural egality
    n.scroll = v
    mark!(w, Dirty.PAINT)
    return true
end

"""
`pos` clamped to the range a scroll position may legally take: `0` when
the content fits, `0:(content - viewport)` otherwise.

THE definition of "clamped to the content extent". Pure, total, and
shared by every scrolling widget so they cannot disagree -- with no
widget-to-widget dependency. Pure.
"""
clamp_scroll(pos::Int, viewport::Int, content::Int)::Int =
    clamp(pos, 0, max(0, content - viewport))

"""
The scroll position NEAREST `pos` that puts the 0-based inclusive extent
`lo:hi` inside a `viewport`-cell window starting at `pos`. Pure.

MINIMAL MOVEMENT: already-visible content does not move. When the extent
is LARGER than the viewport its START wins -- showing the top of an
over-long item beats showing its bottom. Returns `pos` unchanged for a
non-positive viewport (not laid out yet).

The asymmetry is deliberate and `clamp` cannot express it: `clamp` with
an inverted lo/hi silently picks the wrong edge.
"""
function scroll_into_view(pos::Int, viewport::Int, lo::Int,
                          hi::Int)::Int
    viewport <= 0 && return pos
    hi < pos + viewport - 1 || (pos = hi - viewport + 1)
    lo < pos && (pos = lo)
    return max(0, pos)
end

"""
The accumulated shift `w` is PAINTED with: the sum of every STRICT
ancestor's `scroll`, negated. `ORIGIN` outside any scrolled subtree.

A node's OWN scroll is deliberately not included -- it shifts that
node's children, not itself. O(depth), and never on the frame path:
`_paint_node!` threads the same value down for free. Pure.
"""
function paint_offset(w::Widget)::Offset
    o = ORIGIN
    a = parent(w)
    while a !== nothing
        o = o - node(a).scroll
        a = parent(a)
    end
    return o
end

"""
Where `w`'s border box is actually PAINTED: `region(w)` shifted by
`paint_offset(w)`. Identical to `region(w)` outside a scrolled subtree.

THIS, not `region(w)`, is what a hit test must compare a pointer
against: layout computes ABSOLUTE regions and knows nothing about
scrolling, so `region(w)` is where `w` WOULD be if nothing had scrolled.
Pure.
"""
painted_region(w::Widget)::Region =
    translate(region(w), paint_offset(w))

"""
Post-cascade style of `w`. Pure.
"""
computed_style(w::Widget)::Style = node(w).computed_style

"""
Post-cascade layout inputs of `w`. Pure.
"""
box(w::Widget)::BoxStyle = node(w).box

"""
False when `w` or its subtree is hidden. Pure.
"""
is_visible(w::Widget)::Bool = node(w).visible

"""
True when `w` takes part in the tab order. Pure.
"""
is_focusable(w::Widget)::Bool = node(w).focusable

"""
The caption drawn ON `w`'s top border, or empty for none.

A SEAM, not a field, for the same reason the scrollable one is three
functions: a title belongs to the handful of widgets that frame
something, and a slot on every `WidgetNode` would charge the other
thousands for it. Override it and any widget gains a caption.

It is a seam AT ALL because a widget cannot draw this itself.
`_paint_node!` hands `render!` the CONTENT box, and the border is
outside it, so a titled box drawing its own caption would have to
reserve a content row -- which puts the caption inside the frame rather
than on it. The paint pass asks instead.

Empty by default, and the default returns a SHARED constant: this is
asked of every node on every frame.
"""
border_title(::Widget)::RichText = RICHTEXT_EMPTY

"""
Where `border_title(w)` sits along the top edge: `Align.START`,
`Align.CENTER` or `Align.END`. `Align.START` by default.
"""
border_title_align(::Widget)::Align.T = Align.START

"""
The `App` this widget is mounted on, or `nothing`. Walks the tree.
"""
app(w::Widget)::Any = node(w).app

"""
Link `c` (and its whole subtree) into `p`'s tree: set the parent, bind
the app, fire `on_mount!` in pre-order, then flag the new subtree for a
cascade and a layout.

Internal: the three public entry points (`mount!`, `mount!` variadic and
`insert_child!`) all funnel through here so the lifecycle is defined
exactly once.
"""
function _attach!(p::Widget, c::Widget)::Nothing
    node(c).parent = p
    a = app(p)
    walk(c) do w
        node(w).app = a
        on_mount!(w)
        nothing
    end
    mark!(c, Dirty.STYLE)
    mark!(c, Dirty.LAYOUT)
    return nothing
end

"""
Append `c` to `p`, bind it to `p`'s app, and call `on_mount!`. Returns
`p`.

Throws `ArgumentError` when `c` already has a parent: a widget lives in
exactly one tree, and silently re-parenting it would leave the old
parent's `children` stale.
"""
function mount!(p::Widget, c::Widget)::Widget
    parent(c) === nothing || throw(ArgumentError(
        "widget $(repr(id(c))) is already mounted; unmount! it first"))
    push!(children(p), c)
    _attach!(p, c)
    return p
end

"""
Mount several children in order. Returns `p`.
"""
function mount!(p::Widget, cs::Widget...)::Widget
    for c in cs
        mount!(p, c)
    end
    return p
end

"""
Mount `c` at index `i`. Returns `p`.
"""
function insert_child!(p::Widget, i::Int, c::Widget)::Widget
    parent(c) === nothing || throw(ArgumentError(
        "widget $(repr(id(c))) is already mounted; unmount! it first"))
    insert!(children(p), i, c)
    _attach!(p, c)
    return p
end

"""
Call `on_unmount!` and detach `c` from its parent. Returns `c`.

The detached subtree keeps its own structure and is left dirty-clean;
the OLD parent is marked `Dirty.LAYOUT`, because its remaining children
restack.
"""
function unmount!(c::Widget)::Widget
    p = parent(c)
    walk(w -> (on_unmount!(w); nothing), c)
    if p !== nothing
        cs = children(p)
        i = findfirst(x -> x === c, cs)
        i === nothing || deleteat!(cs, i)
        node(c).parent = nothing
    end
    walk(w -> (node(w).app = nothing; nothing), c)
    p === nothing || mark!(p, Dirty.LAYOUT)
    return c
end

"""
Swap `old` for `new` in place. Returns `p`.
"""
function replace_child!(p::Widget, old::Widget, new::Widget)::Widget
    i = findfirst(x -> x === old, children(p))
    i === nothing && throw(ArgumentError(
        "widget $(repr(id(old))) is not a child of $(repr(id(p)))"))
    unmount!(old)
    insert_child!(p, i, new)
    return p
end

"""
The root of `w`'s tree; `w` itself when it has no parent. Pure.
"""
function root_of(w::Widget)::Widget
    r = w
    while true
        p = parent(r)
        p === nothing && return r
        r = p
    end
end

"""
`w`'s ancestors, from its parent up to the root. Pure.
"""
function ancestors(w::Widget)::Vector{Widget}
    out = Widget[]
    p = parent(w)
    while p !== nothing
        push!(out, p)
        p = parent(p)
    end
    return out
end

"""
`w`'s descendants in pre-order, excluding `w`. Pure.
"""
function descendants(w::Widget)::Vector{Widget}
    out = Widget[]
    for c in children(w)
        walk(x -> (push!(out, x); nothing), c)
    end
    return out
end

"""
Root to `w`, inclusive of both. Pure.
"""
function path_from_root(w::Widget)::Vector{Widget}
    out = ancestors(w)
    reverse!(out)
    push!(out, w)
    return out
end

"""
Call `f` on `w` and every descendant, pre-order.
"""
function walk(f, w::Widget)::Nothing
    f(w)
    for c in children(w)
        walk(f, c)
    end
    return nothing
end

"""
Like `walk`, but skips invisible subtrees entirely.
"""
function walk_visible(f, w::Widget)::Nothing
    is_visible(w) || return nothing
    f(w)
    for c in children(w)
        walk_visible(f, c)
    end
    return nothing
end

"""
`children(w)[i]`. Pure.
"""
Base.getindex(w::Widget, i::Int)::Widget = children(w)[i]

"""
Add a class and mark `Dirty.STYLE`. Adding a class `w` already carries
is a no-op: nothing cascades differently, so nothing is flagged.
Returns `w`.
"""
function add_class!(w::Widget, c::Symbol)::Widget
    cs = classes(w)
    if !(c in cs)
        push!(cs, c)
        mark!(w, Dirty.STYLE)
    end
    return w
end

"""
Remove a class and mark `Dirty.STYLE`. Removing an absent class is a
no-op. Returns `w`.
"""
function remove_class!(w::Widget, c::Symbol)::Widget
    cs = classes(w)
    if c in cs
        delete!(cs, c)
        mark!(w, Dirty.STYLE)
    end
    return w
end

"""
Toggle a class and mark `Dirty.STYLE`. Returns the new membership.
"""
function toggle_class!(w::Widget, c::Symbol)::Bool
    if has_class(w, c)
        remove_class!(w, c)
        return false
    end
    add_class!(w, c)
    return true
end

"""
True when `w` carries class `c`. Pure.
"""
has_class(w::Widget, c::Symbol)::Bool = c in classes(w)

"""
Show or hide `w` and mark `Dirty.LAYOUT`. Setting the value `w` already
has is a no-op.
"""
function set_visible!(w::Widget, v::Bool)::Nothing
    n = node(w)
    n.visible == v && return nothing
    n.visible = v
    mark!(w, Dirty.LAYOUT)
    return nothing
end

# A compound selector: one or more `*`, `#id`, `.class` or `Type`
# tokens, concatenated. Combinators (` `, `>`) are deliberately NOT
# supported here -- they belong to the full engine in `css.jl`, which
# this layer must not depend on.
const _SELECTOR_COMPOUND_RE = r"^(?:\*|[#.]?[A-Za-z_][A-Za-z0-9_-]*)+$"
const _SELECTOR_TOKEN_RE = r"\*|[#.]?[A-Za-z_][A-Za-z0-9_-]*"

"""
Split a comma-separated selector list into validated compound
selectors. Throws `ArgumentError` on anything this layer cannot
express. Pure.
"""
function _parse_selector(sel::AbstractString)::Vector{String}
    out = String[]
    for part in split(sel, ',')
        s = String(strip(part))
        occursin(_SELECTOR_COMPOUND_RE, s) || throw(ArgumentError(
            "unsupported widget selector: $(repr(String(sel)))"))
        push!(out, s)
    end
    return out
end

"""
True when `w` satisfies every token of the validated compound selector
`sel`. Pure.
"""
function _match_compound(w::Widget, sel::AbstractString)::Bool
    for m in eachmatch(_SELECTOR_TOKEN_RE, sel)
        t = m.match
        if t == "*"
            continue
        elseif startswith(t, '#')
            id(w) === Symbol(SubString(t, 2)) || return false
        elseif startswith(t, '.')
            has_class(w, Symbol(SubString(t, 2))) || return false
        else
            type_name(w) === Symbol(t) || return false
        end
    end
    return true
end

"""
True when `w` matches any compound in the parsed selector list. Pure.
"""
_match_any(w::Widget, cs::Vector{String})::Bool =
    any(c -> _match_compound(w, c), cs)

"""
Every widget in `root`'s tree matching the CSS selector `sel`, in
pre-order. Pure.

Supports `*`, `#id`, `.class`, `Type`, compounds of those
(`Button.primary#ok`) and comma-separated lists. Combinators live in
`css.jl`; `query` is the dependency-free subset this layer can afford.
"""
function query(root::Widget, sel::AbstractString)::Vector{Widget}
    cs = _parse_selector(sel)
    out = Widget[]
    walk(root) do w
        _match_any(w, cs) && push!(out, w)
        nothing
    end
    return out
end

"""
Depth-first search for the first match, exiting as soon as it is found.
Pure.
"""
function _find_first(w::Widget,
                     cs::Vector{String})::Union{Nothing,Widget}
    _match_any(w, cs) && return w
    for c in children(w)
        r = _find_first(c, cs)
        r === nothing || return r
    end
    return nothing
end

"""
The first widget matching `sel`, or `nothing`. Pure.
"""
function query_one(root::Widget,
                   sel::AbstractString)::Union{Nothing,Widget}
    return _find_first(root, _parse_selector(sel))
end

"""
The first widget matching `sel`, asserted to be a `T`. Throws when
absent or of the wrong type. Pure.
"""
function query_one(root::Widget, sel::AbstractString,
                   ::Type{T})::T where {T<:Widget}
    w = query_one(root, sel)
    w === nothing && throw(KeyError(sel))
    w isa T || throw(TypeError(:query_one, "", T, typeof(w)))
    return w
end

"""
Lifecycle hook: `w` has just been added to a tree. Default no-op.
"""
on_mount!(w::Widget)::Nothing = nothing

"""
Lifecycle hook: `w` is about to leave its tree. Default no-op.
"""
on_unmount!(w::Widget)::Nothing = nothing

"""
Hook: bring `d`, a descendant of `w`, into `w`'s visible area. Default
no-op; a scrolling viewport overrides it.

The core therefore knows that a node MAY be able to reveal a descendant,
and nothing whatever about how -- there is no `isa Scrollpane` anywhere
below layer 7.
"""
reveal_child!(::Widget, ::Widget)::Nothing = nothing

"""
Ask every ancestor of `w`, NEAREST FIRST, to bring `w` into view.

Nearest-first is load-bearing: an inner pane must finish moving before
an outer pane measures where `w` ended up. Never on the frame path --
focus changes are events, not frames.
"""
function reveal!(w::Widget)::Nothing
    a = parent(w)
    while a !== nothing
        reveal_child!(a, w)
        a = parent(a)
    end
    return nothing
end

"""
Lifecycle hook: `w` has just gained focus. Default: `reveal!(w)`, so
TAB-ing to a widget inside a scrolling viewport scrolls it into view
with no wiring at the call site.

OVERRIDING THIS REPLACES IT: a widget type with its own `on_focus!` MUST
call `reveal!(w)` itself.
"""
function _focus_callback!(w::Widget)::Nothing
    callback = node(w).on_focus
    callback === nothing || callback(w)
    return nothing
end

function _blur_callback!(w::Widget)::Nothing
    callback = node(w).on_blur
    callback === nothing || callback(w)
    return nothing
end

function on_focus!(w::Widget)::Nothing
    reveal!(w)
    _focus_callback!(w)
    return nothing
end

"""
Lifecycle hook: `w` has just lost focus. Default no-op.
"""
function on_blur!(w::Widget)::Nothing
    _blur_callback!(w)
    return nothing
end

"""
E1. Set `kind` on `w` ONLY. Touches no ancestor and no descendant.
"""
function mark_dirty!(w::Widget, kind::Dirty.T = Dirty.PAINT)::Nothing
    n = node(w)
    n.dirty = set_dirty(n.dirty, kind)
    return nothing
end

"""
E1. Set `kind` on `w` AND on every descendant.
"""
function mark_subtree_dirty!(w::Widget, kind::Dirty.T)::Nothing
    walk(w) do x
        n = node(x)
        n.dirty = set_dirty(n.dirty, kind)
        nothing
    end
    return nothing
end

"""
Drop the `Dirty.SUBTREE` breadcrumb on every ancestor of `w`, and on
nothing else.

Internal. The breadcrumb is a routing hint, not dirt: `is_dirty(a)`
stays false for an ancestor that only carries it, which is exactly what
makes E1 ("only that specific widget and its affected descendants")
literally true.
"""
function _breadcrumb!(w::Widget)::Nothing
    a = parent(w)
    while a !== nothing
        n = node(a)
        n.dirty = set_dirty(n.dirty, Dirty.SUBTREE)
        a = parent(a)
    end
    return nothing
end

"""
E1. The full propagation -- THE function `Reactive` and the widget API
call. Rules, normative:

    PAINT  on w -> w ONLY. Never ancestors, never descendants.
    LAYOUT on w -> LAYOUT|PAINT on w AND ALL DESCENDANTS (their
                   absolute regions derive from w's, so they are
                   genuinely stale -- this is "and its affected
                   descendants" in the EARS text), then
                   `escalate_auto!(w)`.
    STYLE  on w -> STYLE on w and all descendants (inheritance plus
                   descendant selectors).

In EVERY case each ANCESTOR receives `Dirty.SUBTREE` and NOTHING ELSE.
Marking an ancestor LAYOUT would make E1 false as written.

SIBLINGS ARE NEVER MARKED.
"""
function mark!(w::Widget, kind::Dirty.T = Dirty.LAYOUT)::Nothing
    kind === Dirty.NONE && return nothing
    if kind === Dirty.PAINT
        mark_dirty!(w, Dirty.PAINT)
    elseif kind === Dirty.LAYOUT
        walk(w) do x
            n = node(x)
            n.dirty = set_dirty(set_dirty(n.dirty, Dirty.LAYOUT),
                                Dirty.PAINT)
            nothing
        end
    elseif kind === Dirty.STYLE
        mark_subtree_dirty!(w, Dirty.STYLE)
    else
        mark_dirty!(w, Dirty.SUBTREE)
    end
    _breadcrumb!(w)
    kind === Dirty.LAYOUT && escalate_auto!(w)
    return nothing
end

"""
The `Length` governing `bs`'s own main-axis size: width for a ROW,
height for a COLUMN. Pure.
"""
function _main_axis_length(bs::BoxStyle)::Length
    d = bs.direction
    return (d === Direction.ROW || d === Direction.ROW_REVERSE) ?
        bs.width : bs.height
end

"""
True when `bs`'s main-axis size resolves without measuring its
children.

CELLS and PERCENT are definite; AUTO sizes to content and FRACTION is a
share of free space, so both genuinely depend on the subtree. Pure.
"""
function _main_axis_is_definite(bs::BoxStyle)::Bool
    k = _main_axis_length(bs).kind
    return k === Dimension.CELLS || k === Dimension.PERCENT
end

"""
Walk UP from `w`. An ancestor whose main-axis size is AUTO genuinely
depends on its children, so its `SUBTREE` breadcrumb is PROMOTED to real
LAYOUT.

Stops at the first ancestor with a definite (CELLS/PERCENT) size on the
relevant axis -- that ancestor keeps only `SUBTREE`, because its own box
cannot move, and the walk goes no higher. This is what makes `relayout!`
sublinear.

A promoted ancestor gets LAYOUT but NOT PAINT: whether its box actually
changed is `apply_layout!`'s call to make, not ours.
"""
function escalate_auto!(w::Widget)::Nothing
    a = parent(w)
    while a !== nothing
        n = node(a)
        n.dirty = set_dirty(n.dirty, Dirty.SUBTREE)
        _main_axis_is_definite(n.box) && break
        n.dirty = set_dirty(n.dirty, Dirty.LAYOUT)
        a = parent(a)
    end
    return nothing
end

"""
True when `kind` is set on `w`. Pure.
"""
is_dirty(w::Widget, kind::Dirty.T)::Bool = has_dirty(node(w).dirty, kind)

"""
True when any of PAINT, LAYOUT or STYLE is set on `w`. Pure.

`Dirty.SUBTREE` alone is deliberately NOT dirt.
"""
is_dirty(w::Widget)::Bool = (node(w).dirty & DIRTY_ALL) != 0x00

"""
Clear `w`'s whole dirty mask.
"""
function clean!(w::Widget)::Nothing
    node(w).dirty = DirtyMask(0)
    return nothing
end

"""
The HIGHEST node carrying real `Dirty.LAYOUT` -- the root of the minimal
relayout. `nothing` when the tree is layout-clean.

Found by descending `SUBTREE` breadcrumbs, so it is O(depth), not O(n).
When two independent branches are layout-dirty the descent stops at
their common ancestor -- the shallowest node a correct relayout can
start from -- even though that node carries only the breadcrumb. Pure.
"""
function dirty_root(root::Widget)::Union{Nothing,Widget}
    w = root
    while true
        n = node(w)
        has_dirty(n.dirty, Dirty.LAYOUT) && return w
        has_dirty(n.dirty, Dirty.SUBTREE) || return nothing
        nxt = nothing
        for c in children(w)
            m = node(c).dirty
            if has_dirty(m, Dirty.LAYOUT) || has_dirty(m, Dirty.SUBTREE)
                nxt === nothing || return w   # a fork: `w` is the LCA
                nxt = c
            end
        end
        nxt === nothing && return nothing     # a stale breadcrumb
        w = nxt
    end
end
