# widgets/tree.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode, and
# `RowsWidget`/`Selection`/`_tc_*`, which widgets/tablecore.jl DEFINES
# and this file USES and MUST NOT redefine.
#
# A TreeView's NODES ARE DATA. A 10 000-node tree is 10 000 `TreeNode`s
# and ZERO `WidgetNode`s: `List`'s argument (list.jl:14) one type up. No
# layout pass per expand, no 10 000 `render!` dispatches per frame and --
# the part that is easy to miss -- no 10 000 hit-test nodes, so
# `hit_test` stays O(depth) on every POINTER MOVE, not merely every
# frame.
#
# `TreeView <: RowsWidget`, so `_tc_key!`, `_tc_mouse!`, `_tc_wheel!`,
# `_tc_follow_cursor!`, `_tc_extent`, `_tc_page`, `_tc_sync!`,
# `_tc_row_style`, `_tc_bar_style` and `Scrollbar{TreeView{T,F,A}}` all
# work with ZERO new code in `scroll.jl`: the scrollable seam is three
# functions and not a type.

"""
One node of a `TreeView`'s data model. NOT A WIDGET.

`List`'s argument (list.jl:14) one type up, and it is worth more here: a
10 000-node tree is 10 000 of THESE and ZERO `WidgetNode`s -- no layout
pass per expand, no 10 000 `render!` dispatches per frame, and -- the
part that is easy to miss -- no 10 000 hit-test nodes, so `hit_test`
stays O(depth) ON EVERY POINTER MOVE, not merely every frame.

NO PARENT POINTER, DELIBERATELY. A `parent` field is a second source of
truth that `push!(n.kids, x)` silently fails to maintain, and building a
tree stops being a literal. `TreeView` recovers the parent FROM THE
FLATTENED ROWS -- the nearest earlier row with a smaller `depth` -- in
O(depth-from-here) on a KEYSTROKE, never on a frame. That is the right
price for a field that cannot go stale because it does not exist.
"""
mutable struct TreeNode{T}
    "The payload."
    value::T
    "Children, in display order. EMPTY is a LEAF. ALIASED."
    const kids::Vector{TreeNode{T}}
    """
    True when this node's children are part of the visible flattening.
    A LEAF is always collapsed and `toggle_node!` will not move it --
    `isempty(kids)` IS the leaf test, so there is no separate flag to
    fall out of step with the vector it describes.
    """
    expanded::Bool
end

"""
A tree node carrying `value`, with `kids` in display order.

`expanded` defaults to `false`: a tree opens showing its roots and
nothing beneath them, which is what "collapsed" means and what every
file browser does.
"""
TreeNode(v::T, kids::Vector{TreeNode{T}} = TreeNode{T}[];
         expanded::Bool = false) where {T} =
    TreeNode{T}(v, kids, expanded)

"True when `n` has no children. Pure."
is_leaf(n::TreeNode)::Bool = isempty(n.kids)

"True when `n` is a non-leaf whose children are visible. Pure."
is_expanded(n::TreeNode)::Bool = n.expanded && !is_leaf(n)

"""
One DISPLAYED row: a node and its indentation depth. `isbits`-adjacent
(a reference and an `Int`), so `Vector{TreeRow{T}}` is dense. Internal
to the widget's cache; never a user type.
"""
struct TreeRow{T}
    "The node this row shows."
    node::TreeNode{T}
    "Indent level. A root is 0."
    depth::Int
end

# --- glyphs. ASCII, width 1 BY CONSTRUCTION; the suite asserts it. ----

"Expanded twisty. Width 1 BY CONSTRUCTION, asserted."
const TV_OPEN = "-"
"Collapsed twisty. Width 1 BY CONSTRUCTION, asserted."
const TV_CLOSED = "+"
"""
A leaf's twisty: a space. Width 1, so the TEXT COLUMN IS INVARIANT
between leaves and branches -- a tree whose labels jog left by one on a
leaf is a tree nobody can read.
"""
const TV_LEAF = " "
"Cells of indent per depth level."
const TV_INDENT = 2
"Cells between the twisty and the label."
const TV_GAP = 1

"""
A scrollable, focusable hierarchical view over `TreeNode` DATA.

`render!` touches `rows[scroll.y+1 : scroll.y+height]` and NOTHING ELSE,
so paint is O(WINDOW), never O(nodes) -- `List`'s contract exactly, and
a 10 000-node tree costs the same frame as a 10-node one.

THE FLATTEN IS O(VISIBLE), NOT O(WINDOW). A fully-expanded 10 000-node
tree holds a 10 000-entry `Vector{TreeRow}`. It is 10 000 `TreeRow`s and
ZERO `WidgetNode`s, which is the claim that matters. A COLLAPSED SUBTREE
CONTRIBUTES EXACTLY ONE ROW HOWEVER DEEP IT IS -- that is not an
optimisation, IT IS WHAT EXPAND/COLLAPSE MEANS.

`flattened` is the memo bit and it is KEYED ON THE SHAPE, NOT ON
`version` -- deliberately: `version` bumps on every ARROW KEY
(`_tc_touch!`), so keying on it would re-flatten 10 000 nodes PER
KEYSTROKE. A cursor move is not a shape change.

GREEDY BY DESIGN: `measure(w, avail) = avail`. `List`'s argument
(list.jl:239) -- an auto-height tree would be as tall as its data and
would NEVER SCROLL AT ALL. Give it `height: 10` or a `grow: 1` parent;
do not put it beside a one-row `Label` you want to survive. This is also
what licenses `version`'s PAINT reactivity: a data change provably
cannot move this box, so `toggle_node!` on a 10 000-node tree costs ZERO
layout.

SINGLE SELECTION ONLY; `mode` IS NOT A KWARG. Re-pinning a `BitSet` of N
rows across a re-flatten has no answer for a selected row whose parent
just collapsed. Under SINGLE the selection IS the cursor and one rule
covers both.

`roots` is ALIASED, never copied.
"""
mutable struct TreeView{T,F,A,C} <: RowsWidget
    "Per-widget state."
    node::WidgetNode
    "The roots. ALIASED, mutated in place. A FOREST, not a tree: a file
     browser has N."
    const roots::Vector{TreeNode{T}}
    "`format(value)::AbstractString`, no newline. CONCRETE: static."
    const format::F
    "The flattened VISIBLE rows. Rebuilt by `_tv_flat!`; REUSED."
    const rows::Vector{TreeRow{T}}
    "False when `rows` is stale. The memo bit of `_tv_flat!`."
    flattened::Bool
    "Bumped by every data, expansion OR cursor change. THE cell. PAINT."
    version::Reactive{Int}
    "Cursor and selected set, in FLAT ROW indices."
    const sel::Selection
    "Widest visible row in cells, INCLUDING indent and twisty. EXACT."
    widest::Int
    "True while focused. PAINT-reactive."
    focused::Reactive{Bool}
    "True if the tree is disabled."
    disabled::Reactive{Bool}
    "Called as `on_submit(tree)` on ENTER. NAMED `on_submit` BY
     FORCE: `_tc_key!` reads `w.on_submit` (tablecore.jl:1080)."
    on_submit::A
    "Called as `on_change(tree)` when the cursor moves."
    on_change::C
end

"""
A tree over `roots`, calling `on_submit(tree)` on ENTER.

Focusable by construction, so it appears in `focusable_widgets` and is
reachable by TAB with no further wiring. `roots` is ALIASED, not copied.
"""
function TreeView(roots::Vector{TreeNode{T}},
                  on_submit::A = _tc_noop;
               on_change::C = _tc_noop,
                  format::F = _tc_show,
                  disabled::Bool = false,
                  id::Symbol = gensym(:treeview),
                  classes = Symbol[])::TreeView{T,F,A,C} where {T,F,A,C}
    w = TreeView{T,F,A,C}(
        WidgetNode(; id = id, classes = classes,
                   type_name = :TreeView, focusable = true),
        roots, format, TreeRow{T}[], false,
        Reactive(0; kind = Dirty.PAINT),
        Selection(SelectMode.SINGLE, 0),
        0,
        Reactive(false; kind = Dirty.PAINT),
        Reactive(disabled; kind = Dirty.PAINT),
        on_submit,
        on_change)
    attach_reactives!(w)
    _tv_rebuild!(w)
    return w
end

# --- the RowsWidget seam. FINAL: `tablecore.jl` dispatches on each. ----
selection_of(w::TreeView)::Selection = w.sel
row_count(w::TreeView)::Int = length(_tv_flat!(w))
view_count(w::TreeView)::Int = length(_tv_flat!(w))
view_source(::TreeView, k::Int)::Int = k
view_rank(::TreeView, s::Int)::Int = s
_tc_touch!(w::TreeView)::Nothing =
    (w.version[] = w.version[] + 1; nothing)
_tc_on_change(w::TreeView) = w.on_change(w)

"""
The widest visible row, in cells. OVERRIDES the `RowsWidget` default,
which calls `grid_of(w)` -- a tree has no columns, so that default is a
`MethodError`. `_tv_flat!` computes the exact mark in the walk it was
doing anyway; there is no `scanned` bit and no fixpoint to escape
(list.jl:154). Internal.
"""
_tc_extent_width(w::TreeView)::Int = (_tv_flat!(w); w.widest)

"""
`Size(widest, n_visible)`. OVERRIDES the container default: a tree's
content is DATA, not children. THIS OVERRIDE IS THE WHOLE INTEGRATION
WITH `Scrollbar` -- `Scrollbar{TreeView{T,F,A}}` works with ZERO new
code in `scroll.jl` (list.jl:212). O(1) on the memo hit; ON THE FRAME
PATH several times per frame.
"""
content_extent(w::TreeView)::Size = _tc_extent(w)

"""
`avail`. `List`'s argument verbatim (list.jl:239): a tree takes the
space it is OFFERED and scrolls its content, because an auto-HEIGHT tree
would be as tall as its data and would never scroll at all. Give it
`height: 10` or a `grow: 1` parent. This is also what licenses
`version`'s PAINT reactivity. Pure w.r.t. the tree.
"""
measure(w::TreeView, avail::Size)::Size = avail

# --- the flatten ------------------------------------------------------

"""
`w.rows`, REBUILT IFF `flattened` is false. One `Bool` test and ZERO
allocation on the hit; O(VISIBLE) on the miss. `_lst_scan!`
(list.jl:200) is the precedent and the memo bit means the same thing.

`empty!` + `push!` into the SAME `Vector`, never a fresh one: the
buffer's capacity survives, so re-expanding the same subtree allocates
nothing after the first time.

`widest` IS EXACT AND THERE IS NO `scanned` BIT: a tree MUST walk to
know what is visible at all, so the width falls out of a walk that was
happening anyway. One pass, exact answer, no memo to invalidate.
Internal.
"""
function _tv_flat!(w::TreeView{T})::Vector{TreeRow{T}} where {T}
    w.flattened && return w.rows
    empty!(w.rows)
    w.widest = 0
    for r in w.roots
        _tv_walk!(w, r, 0)
    end
    w.flattened = true
    return w.rows
end

"""
Push `n` and, if it is expanded, its subtree, into `w.rows`; raise
`widest` to fit each label. Internal.
"""
function _tv_walk!(w::TreeView{T}, n::TreeNode{T},
                   depth::Int)::Nothing where {T}
    push!(w.rows, TreeRow{T}(n, depth))
    w.widest = max(w.widest,
                   TV_INDENT * depth + 1 + TV_GAP +
                   text_width(w.format(n.value)))
    is_expanded(n) || return nothing
    for k in n.kids
        _tv_walk!(w, k, depth + 1)
    end
    return nothing
end

"""
The `TreeNode` at flat row `k`, or `nothing` out of range. O(1). Pure.
"""
function node_at(w::TreeView{T},
                 k::Int)::Union{Nothing,TreeNode{T}} where {T}
    rows = _tv_flat!(w)
    (1 <= k <= length(rows)) || return nothing
    return rows[k].node
end

"The node under the cursor, or `nothing`. Internal, pure w.r.t. tree."
_tv_cursor_node(w::TreeView{T}) where {T} =
    node_at(w, row_cursor(w))::Union{Nothing,TreeNode{T}}

"""
The flat row showing `n` by IDENTITY; `0` when `n` is not visible.
O(visible), on a keystroke, never a frame. Internal.
"""
function _tv_row_of(w::TreeView{T}, n::TreeNode{T})::Int where {T}
    rows = _tv_flat!(w)
    for k in eachindex(rows)
        rows[k].node === n && return k
    end
    return 0
end

"""
Re-flatten and RE-PIN the cursor by NODE IDENTITY: the row the user was
on keeps the node they were on, whatever its flat index becomes.

RE-PINNING IS THE WHOLE FUNCTION AND IT IS WHY MULTI IS NOT OFFERED. The
cursor is a ROW INDEX and the rows renumber, so a rebuild that did not
re-pin would leave the cursor on whatever slid into its slot.

`fallback` is where the cursor goes when its node is NO LONGER VISIBLE
-- which is exactly `collapse!`'s case. `_tv_set_expanded!` passes THE
COLLAPSED NODE, so collapsing an ancestor puts the cursor on the
ancestor -- one rule, testable, and unrepresentable as a bug.

Re-clamps the scroll afterwards: this is the only call that can SHRINK
the extent and strand an offset past the end
(`refresh_extent!(::List)`, list.jl:299). Internal.
"""
function _tv_rebuild!(w::TreeView{T},
                      fallback::Union{Nothing,TreeNode{T}} =
                          nothing)::Nothing where {T}
    keep = _tv_cursor_node(w)          # BEFORE: reads the OLD rows
    w.flattened = false
    _tv_flat!(w)                       # rebuild; sets flattened = true
    _tc_sync!(w)                       # resize_selection! to the new n
    k = keep === nothing ? 0 : _tv_row_of(w, keep)
    (k == 0 && fallback !== nothing) && (k = _tv_row_of(w, fallback))
    k == 0 || set_cursor!(w, k)
    _tc_touch!(w)
    scroll_to!(w, scroll_of(w))
    _tc_follow_cursor!(w)
    return nothing
end

"""
The parent of visible row `i`: the NEAREST EARLIER row with a SMALLER
`depth`; `0` when `i` is top-level or out of range. Pure w.r.t. tree.

O(depth-from-here) worst case -- it walks UP the flattened vector and
stops at the first shallower row -- on a KEYSTROKE, never on a frame.
This is what `TreeNode` having no parent pointer costs, and it CANNOT BE
STALE, which a field would be the first time someone `push!`ed a child.
Internal.
"""
function _tv_parent_row(w::TreeView, i::Int)::Int
    rows = _tv_flat!(w)
    (1 <= i <= length(rows)) || return 0
    d0 = rows[i].depth
    d0 == 0 && return 0
    for j in (i - 1):-1:1
        rows[j].depth < d0 && return j
    end
    return 0
end

# --- expand / collapse ------------------------------------------------

"""
Set `n.expanded = v` and re-flatten, re-pinning the cursor. False for a
leaf or an unchanged flag. THE single exit of every expand/collapse, so
none of the four steps can be forgotten. Internal.
"""
function _tv_set_expanded!(w::TreeView{T}, n::TreeNode{T},
                           v::Bool)::Bool where {T}
    is_leaf(n) && return false
    n.expanded === v && return false
    n.expanded = v
    _tv_rebuild!(w, v ? nothing : n)
    return true
end

"Expand `n`. False for a leaf or an already-open node."
expand_node!(w::TreeView{T}, n::TreeNode{T}) where {T} =
    _tv_set_expanded!(w, n, true)

"""
Collapse `n`. False for an already-shut node. Passes `n` as the
rebuild's fallback, so a cursor inside the closing subtree lands on `n`.
"""
collapse_node!(w::TreeView{T}, n::TreeNode{T}) where {T} =
    _tv_set_expanded!(w, n, false)

"""
Flip the expansion of flat row `k`. False for a leaf or a bad row.
"""
function toggle_node!(w::TreeView, k::Int)::Bool
    rows = _tv_flat!(w)
    (1 <= k <= length(rows)) || return false
    n = rows[k].node
    is_leaf(n) && return false
    return _tv_set_expanded!(w, n, !n.expanded)
end

"Recursively set `expanded` on `n` and every non-leaf below it. Internal."
function _tv_set_all!(n::TreeNode, v::Bool)::Nothing
    is_leaf(n) && return nothing
    n.expanded = v
    for k in n.kids
        _tv_set_all!(k, v)
    end
    return nothing
end

"""
Expand EVERY node. O(nodes) -- on a user action, never a frame.
"""
function expand_all!(w::TreeView)::Nothing
    for r in w.roots
        _tv_set_all!(r, true)
    end
    _tv_rebuild!(w)
    return nothing
end

"""
Collapse EVERY node. O(nodes) -- on a user action, never a frame.
"""
function collapse_all!(w::TreeView)::Nothing
    for r in w.roots
        _tv_set_all!(r, false)
    end
    _tv_rebuild!(w)
    return nothing
end

# --- data ops ---------------------------------------------------------

"The flattened VISIBLE rows. ALIASED; do not mutate. Pure w.r.t. tree."
tree_rows(w::TreeView) = _tv_flat!(w)

"The node under the cursor, or `nothing`. Pure w.r.t. tree."
tree_cursor(w::TreeView{T}) where {T} =
    _tv_cursor_node(w)::Union{Nothing,TreeNode{T}}

"""
Replace the roots. CLEARS the selection and rewinds the scroll: every
flat index the selection held names a row that may no longer exist.
`set_items!(::List)`'s argument (list.jl:394).
"""
function set_roots!(w::TreeView{T}, rs)::Nothing where {T}
    empty!(w.roots)
    append!(w.roots, rs)
    set_scroll!(w, ORIGIN)
    resize_selection!(w.sel, 0)
    _tv_rebuild!(w)
    return nothing
end

"""
Re-flatten from the current `roots`/`kids`. THE public escape hatch for
"I mutated `roots`/`kids` myself" -- `refresh_rows!(::List)`'s contract
(list.jl:462), same meaning.
"""
refresh_tree!(w::TreeView)::Nothing = _tv_rebuild!(w)

# --- painting ---------------------------------------------------------

"""
Paint `rows[scroll.y+1 : scroll.y+height]`: indent, twisty, label, then
the selection and cursor bars. O(WINDOW), NEVER O(nodes) and never
O(visible rows). `List.render!` (list.jl:328) line for line, with a
prefix.

ZERO STRING BUILDING PER ROW. The indent is NOT PAINTED AT ALL --
`frame!` blanks the back buffer every frame (app.jl:552), so blank cells
ARE the indent -- and the label goes through `_tc_slice!` at an explicit
start column rather than through a concatenation.
"""

# --- keyboard ---------------------------------------------------------

"""
Three interceptions, then `_tc_key!`. SPACE toggles the cursor node,
RIGHT expands / walks to the first child, LEFT collapses / walks to the
parent -- a tree's arrows have meant expand/collapse since 1990 and no
user will accept the horizontal-scroll binding `_tc_key!` gives them.
UP/DOWN/PAGE/HOME/END/ENTER and shift-extend are DELEGATED unchanged.
Consumes ONLY when something moved, so LEFT on a root leaf bubbles. TAB
and ESCAPE fall through, which is what keeps the tab order alive.
"""
function on_event!(w::TreeView, d::Dispatch{KeyEvent})::Nothing
    _tc_acts(d) || return nothing
    e = event(d)
    if isempty(e.mods)
        c = e.code
        if c === Key.SPACE || (c === Key.CHAR && e.char == ' ')
            _tv_key_toggle!(w, d)
            return nothing
        elseif c === Key.RIGHT
            _tv_key_right!(w, d)
            return nothing
        elseif c === Key.LEFT
            _tv_key_left!(w, d)
            return nothing
        end
    end
    _tc_key!(w, d)
    return nothing
end

"SPACE: toggle the cursor node; consume iff it moved. Internal."
function _tv_key_toggle!(w::TreeView, d::Dispatch{KeyEvent})::Nothing
    _tc_sync!(w)
    toggle_node!(w, row_cursor(w)) || return nothing
    consume!(d)
    return nothing
end

"RIGHT: expand, or if already open move to the first child. Internal."
function _tv_key_right!(w::TreeView, d::Dispatch{KeyEvent})::Nothing
    _tc_sync!(w)
    k = row_cursor(w)
    n = node_at(w, k)
    n === nothing && return nothing
    moved = if is_leaf(n)
        false
    elseif !n.expanded
        expand_node!(w, n)
    else
        set_cursor!(w, k + 1)          # the first child is the next row
    end
    moved || return nothing
    consume!(d)
    return nothing
end

"LEFT: collapse, or if already shut / a leaf move to the parent."
function _tv_key_left!(w::TreeView, d::Dispatch{KeyEvent})::Nothing
    _tc_sync!(w)
    k = row_cursor(w)
    n = node_at(w, k)
    n === nothing && return nothing
    moved = if !is_leaf(n) && n.expanded
        collapse_node!(w, n)
    else
        p = _tv_parent_row(w, k)
        p == 0 ? false : set_cursor!(w, p)
    end
    moved || return nothing
    consume!(d)
    return nothing
end

# --- mouse ------------------------------------------------------------

"""
A LEFT PRESS on the TWISTY COLUMN toggles the row; anywhere else
DELEGATES to `_tc_mouse!` (cursor, drag, wheel). The twisty test uses
the SAME arithmetic `render!` paints it at, so "click what you see" is
true by construction. `_tc_local`, NEVER `local_offset`.
"""
function on_event!(w::TreeView, d::Dispatch{MouseEvent})::Nothing
    _tc_acts(d) || return nothing
    e = event(d)
    if e.button === MouseButton.LEFT &&
       e.action === MouseAction.PRESS
        k = _tc_row_at(w, e)
        if k != 0
            r = _tv_flat!(w)[k]
            if !is_leaf(r.node)
                o = _tc_local(w, e)
                if scroll_of(w).x + o.x - 1 == TV_INDENT * r.depth
                    toggle_node!(w, k)
                    consume!(d)
                    return nothing
                end
            end
        end
    end
    _tc_mouse!(w, d)
    return nothing
end

"""
Show the cursor, and scroll every ancestor pane until this tree is
visible. `reveal!` is called EXPLICITLY because overriding `on_focus!`
REPLACES the default that would have called it (widget.jl:666).
"""
on_focus!(w::TreeView)::Nothing =
    (w.focused[] = true; reveal!(w); _focus_callback!(w))

"Hide the cursor."
on_blur!(w::TreeView)::Nothing =
    (w.focused[] = false; _blur_callback!(w))
