# widgets/list.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode, and
# `RowsWidget`/`Selection`, which widgets/tablecore.jl DEFINES and this
# file USES and MUST NOT redefine.

"""
A scrollable, focusable list of items.

Scrolls by INDEXING `items`, never by shifting an origin: `render!`
touches `scroll.y + 1 : scroll.y + height` and nothing else, so paint is
O(viewport) and a 100 000-item list costs the same frame as a 10-item
one.

A ROW IS NOT A WIDGET. `TextArea`'s argument (textarea.jl:6), one type
up: a `Scrollpane` inside would mean one widget per ROW, so 100 000
items become 100 000 `WidgetNode`s, a full layout pass per `push_item!`
and 100 000 `render!` dispatches per frame -- and, the part that is easy
to miss, 100 000 hit-test nodes, so `hit_test` would be O(n) on every
POINTER MOVE. 100 000 rows are 100 000 elements of a `Vector` and ZERO
`WidgetNode`s.

PARAMETRIC ON BOTH the element type and the formatter, the
`Button{F}`/`TextInput{F}`/`TextArea{F}` pattern the codebase already
uses three times: `items[i]` is a TYPED load and `w.format(item)` is a
STATIC dispatch. `List{String,typeof(_tc_show)}` formats for ZERO
allocation per row, because `_tc_show(::String)` returns its argument
(`string(s::String) === s`).

THIS is why a `List` is not a one-column `Table`, and it is not
cosmetic: see `Table` for why a table's cell callback is on the widget.
Compare `Label` vs `Static` (label.jl:98) -- two types because one of
them must not pay the other's cost.

`items` is a PLAIN field, deliberately NOT a `Reactive`: `Reactive`'s
`==` guard would be an O(n) elementwise compare on every change AND an
in-place edit would never trip it. `version` is the reactive cell
instead -- an `Int` compare is O(1) for the O(1) edit that happened.
THE PRICE, stated so nobody discovers it: `items` mutated behind
`version`'s back will not repaint -- call `refresh_rows!`. It will NOT
CORRUPT, because `render!` re-syncs the selection's row count every
frame (`_tc_sync!`, O(1) when unchanged).

`items` is ALIASED, never copied: copying 100 000 rows is exactly the
O(n) this widget exists to avoid.

`version` is `Dirty.PAINT`-reactive, and this DIVERGES from
`TextArea.version` (LAYOUT) ON PURPOSE. `TextInput` states the criterion
verbatim (textinput.jl:158): "`Reactive`'s default is the conservative
`Dirty.LAYOUT` precisely because choosing PAINT for state that can
change size is a correctness bug. The text-independent `measure` above
is what licenses PAINT here; do not copy the choice to a widget without
that property." `measure(::List, avail) = avail` HAS that property, and
`compute_layout` NEVER calls `content_extent`. A data change therefore
PROVABLY cannot move a box, so `push_item!` on a 100 000-item list costs
ZERO layout and never fires `escalate_auto!`. `TextArea`'s LAYOUT is
conservative, not normative.

`format(item)` MUST return an `AbstractString` and MUST NOT contain a
newline -- a list row is ONE row. Same contract as `TextArea.lines`, and
policed the same way: not at all.
"""
mutable struct List{T,F,A,C} <: RowsWidget
    "Per-widget state."
    node::WidgetNode
    "The data, one entry per row. ALIASED. Mutated IN PLACE."
    const items::Vector{T}
    "`format(item)::TextLike`. CONCRETE: dispatches statically."
    const format::F
    """
    Bumped by every data OR selection change. THE reactive cell.
    Dirty.PAINT -- see above.
    """
    version::Reactive{Int}
    "Cursor and selected set, in SOURCE row indices."
    const sel::Selection
    """
    MONOTONE high-water mark of the widest row, in cells. NEVER an
    UNDER-estimate once `scanned` -- see `_lst_scan!` for why that
    direction is the whole ballgame.
    """
    widest::Int
    """
    True IFF `widest` is known not to UNDERSTATE any row. The memo bit
    of `_lst_scan!`; `false` seeds the one lazy O(items) scan.
    """
    scanned::Bool
    "True while focused. PAINT-reactive."
    focused::Reactive{Bool}
    "True if the list is disabled."
    disabled::Reactive{Bool}
    "Called as `on_submit(list)` on ENTER."
    on_submit::A
    "Called as `on_change(list)` when the cursor moves."
    on_change::C
end

"""
A list over `items`, calling `on_submit(list)` on ENTER.

`on_submit` is the SECOND POSITIONAL.
`on_change` is an optional KEYWORD argument that fires when the cursor moves.

Focusable by construction, so it appears in `focusable_widgets` and is
reachable by TAB with no further wiring.

`items` is ALIASED, not copied. `List(1:100_000)` collects, once, and
the caller knows what they paid.

`widest` starts at ZERO and the formatter is called NOT ONCE here: the
mark is DEFERRED, not skipped. `scanned` starts false and `_lst_scan!`
pays the O(items) measurement at the first query -- which is the first
time anyone ASKS how wide the content is, and therefore the first time
the answer can matter. A `List(1:100_000)` that nobody scrolls pays for
nothing, and the constructor stays O(1) over an aliased `Vector`.

`isempty(items)` is `scanned` BY CONSTRUCTION and is not a special case:
`0` IS the exact maximum over no rows.
"""
function List(items::Vector{T}, on_submit::A = _tc_noop;
              format::F = _tc_show,
              mode::SelectMode.T = SelectMode.SINGLE,
              disabled::Bool = false,
              on_change::C = _tc_noop,
              id::Symbol = gensym(:list),
              classes = Symbol[])::List{T,F,A,C} where {T,F,A,C}
    w = List{T,F,A,C}(WidgetNode(; id = id, classes = classes,
                                 type_name = :List, focusable = true),
                      items, format,
                      Reactive(0; kind = Dirty.PAINT),
                      Selection(mode, length(items)),
                      0, isempty(items),
                      Reactive(false; kind = Dirty.PAINT),
                      Reactive(disabled; kind = Dirty.PAINT),
                      on_submit,
                      on_change)
    attach_reactives!(w)
    return w
end

"""
A list over any `AbstractVector`, collected ONCE into a `Vector`.
"""
List(items::AbstractVector, args...; kwargs...) =
    List(collect(items), args...; kwargs...)

_tc_on_change(w::List) = w.on_change(w)

# --- the seam. FINAL: `tablecore.jl` dispatches on every one of these.
selection_of(w::List)::Selection = w.sel
row_count(w::List)::Int = length(w.items)
view_count(w::List)::Int = length(w.items)
view_source(::List, k::Int)::Int = k
view_rank(::List, s::Int)::Int = s
_tc_touch!(w::List)::Nothing = (w.version[] = w.version[] + 1; nothing)

"""
`w.widest`, MEMOIZED on `scanned`: O(1) and ZERO allocation on a hit,
one O(items) scan on the miss. A `List` has no columns, so there is no
grid to resolve and `_tc_extent_width`'s default would not find one --
this is the `List` half of that per-widget branch.

THE MARK IS MEASURED FROM THE DATA AND NEVER FROM THE PAINT, and that
is not a refinement -- it is the difference between a working axis and a
dead one. A mark raised only by `render!` from what it PAINTS cannot
exceed `scroll.x + width`, because `_tc_paint_slice!` reports a CUT row
as exactly that; and `_tc_scroll_x!` moves through `scroll_to!`, clamped
to `max_scroll.x == widest - width`. The two together are a FIXPOINT:

    widest <= scroll.x + width   AND   scroll.x <= widest - width
    =>  scroll.x <= scroll.x

-- the mark pins at the viewport width, `max_scroll.x` pins at ZERO, and
every cell past the first screenful is unreachable FOREVER. The mark
cannot bootstrap, because scrolling is the only thing that would raise
it and the mark is the only thing that permits scrolling. This is the
anti-pattern the architect's contract names for the GRID at
`_tc_resolve!` -- "a `widths` field that only `render!` writes, so
`max_scroll(t).x == 0` -- 'cannot scroll' when it can -- until the first
frame" -- and it is fatal here rather than merely late, because a
`List`'s extent has no columns to resolve it into shape.

THE ASYMMETRY THAT MATTERS, and the reason `TextArea` never had this
bug: an OVER-estimate is self-correcting (you can always scroll, and
`refresh_extent!` shrinks it), an UNDER-estimate is SELF-LOCKING. This
is why `scanned` means "not an under-estimate" rather than "exact": the
monotone over-report `delete_item!` leaves is safe and stays documented.

KEYED ON THE DATA, NOT ON `version` -- deliberately, and this is where
it departs from `_tc_resolve!`'s `(version, avail)`: `version` bumps on
every ARROW KEY (`_tc_touch!`), so keying on it would rescan 100 000
rows per keystroke. `_lst_widen!` MAINTAINS the mark across `push_item!`
and `insert_item!` instead -- `max` over `items ∪ {x}` IS
`max(mark, width(x))` -- so only the two BULK ops invalidate. Internal.
"""
_tc_extent_width(w::List)::Int = _lst_scan!(w)

"""
Measure every item and RAISE `widest` to fit, once. Returns the mark.
O(items) and one formatter call per item on the MISS; O(1), zero
allocation, one `Bool` test on the HIT.

`max`, not assignment: this only ever RAISES, so it cannot strand a
stored offset past the end and MUST NOT re-clamp -- which is what makes
it safe to call from inside `scroll_to!`'s own `content_extent` read,
where a `_lst_reclamp!` would recurse. `refresh_extent!` is the call
that can LOWER the mark, and it is the one that re-clamps. Internal.
"""
function _lst_scan!(w::List)::Int
    w.scanned && return w.widest
    m = w.widest
    for x in w.items
        m = max(m, text_width(w.format(x)))
    end
    w.widest = m
    w.scanned = true
    return m
end

"""
`Size(widest, length(items))`. OVERRIDES the container default
(scroll.jl:84): a `List`'s content is DATA, not children, so the
bounding box of its (nonexistent) children is not its extent. THIS
OVERRIDE IS THE WHOLE INTEGRATION WITH `Scrollbar` --
`Scrollbar{List{T,F,A}}` works with ZERO new code in `scroll.jl`,
because the scrollable seam is three functions and not a type.

`_tc_header_rows(::List) == 0`, so the `+ hh` of `_tc_extent`
degenerates and this is `Size(widest, n)` exactly.

O(1) AND ZERO ALLOCATION ON EVERY CALL BUT THE FIRST, which is the bar
that matters: THIS FUNCTION IS ON THE FRAME PATH -- `_sb_metrics`,
`max_scroll`, `scroll_to!` and `Scrollpane.render!` all reach it,
several times per frame (scroll.jl:100,115,413,626). `length` on a
`Vector` is O(1) and `widest` is a MEMOIZED mark. Writing
`maximum(text_width, items)` here -- on every call, unmemoized -- would
make every frame O(rows) and IS FORBIDDEN.

THE FIRST call after a bulk data change pays ONE O(items) scan
(`_lst_scan!`), stated rather than hidden. There is no cheaper honest
answer: the widest of `n` rows is not knowable without looking at `n`
rows, and the alternative -- inferring the mark from what `render!`
painted -- is the fixpoint `_tc_extent_width` documents, which does not
cost O(rows) only because it never works at all.
"""
content_extent(w::List)::Size = _tc_extent(w)

"""
`avail`. `TextArea`'s argument verbatim (textarea.jl:164): a `List`
takes the space it is OFFERED and scrolls its content, because an
auto-HEIGHT `List` would be as tall as its data and would never scroll
at all. Give it `height: 10` or a `grow: 1` parent. This is also what
licenses `version`'s PAINT reactivity. Pure w.r.t. the tree.
"""
measure(w::List, avail::Size)::Size = avail

"""
Raise the high-water mark to fit `x`, formatted. O(text_width(x)), never
O(items). `_ta_widen!` (textarea.jl:151) is the precedent.

MAINTAINS `scanned` rather than clearing it, and that is what keeps
`push_item!` O(1) instead of O(items): `max` over `items ∪ {x}` IS
`max(mark, width(x))`, so a mark that did not understate `items` does
not understate `items ∪ {x}` either. Building a list by `push_item!`
therefore stays O(n) overall, never O(n^2). Internal.
"""
function _lst_widen!(w::List, x)::Nothing
    w.widest = max(w.widest, text_width(w.format(x)))
    return nothing
end

"""
Re-clamp the stored offset to the CURRENT extent. Called by the two
functions that can SHRINK it -- `refresh_extent!` and `refresh_rows!` --
and by nothing else, because `scroll_to!` reads `content_extent` and
that is a cost the frame path must not pay for a no-op. Internal.
"""
function _lst_reclamp!(w::List)::Nothing
    scroll_to!(w, scroll_of(w))
    return nothing
end

"""
Recompute `widest` from scratch and return the new `content_extent`.
O(items), and it CALLS THE FORMATTER ONCE PER ITEM.

`widest` is a MONOTONE HIGH-WATER MARK: `render!` raises it from the
width `_tc_paint_slice!` returns, in O(1) per painted row, and nothing
lowers it. THE SAME NAME, THE SAME CONTRACT and the same return type as
`refresh_extent!(::TextArea)` (textarea.jl:183) -- one name, one
meaning, four widgets, and no new export.

THE TRADEOFF, stated so nobody discovers it, and it is now the SAME as
`TextArea`'s rather than its mirror image: both start EXACT and drift
TOO WIDE as you delete, and this is the call that makes them exact
again. A `List` that started TOO NARROW would not be an optimistic
thumb, it would be a DEAD AXIS -- see `_tc_extent_width` for the
fixpoint. The VERTICAL axis -- the one a list is actually about -- is
EXACT and free either way, because it is `length(items)`.

THIS IS NO LONGER LOAD-BEARING FOR CORRECTNESS, and that is the point:
`_lst_scan!` reaches the same mark automatically, memoized, at the first
query. What is left here is the one thing a monotone mark cannot do
alone -- LOWER itself after a delete -- which is a thumb that reads a
little small, never a cell you cannot reach.

Re-clamps the stored offset afterwards, because this is the only call
that can SHRINK the extent and strand an offset past the end.
"""
function refresh_extent!(w::List)::Size
    m = 0
    for x in w.items
        m = max(m, text_width(w.format(x)))
    end
    w.widest = m
    w.scanned = true            # BEFORE the reclamp, which reads it.
    _lst_reclamp!(w)
    return content_extent(w)
end

"""
Paint `items[scroll.y+1 : scroll.y+height]`, each sliced at `scroll.x`,
then the selection and cursor bars. O(viewport), NEVER O(items).

`_tc_sync!` FIRST: the self-healing guard, O(1) when the count has not
changed.

`widest` is raised from `_tc_paint_slice!`'s return, which is the row's
FULL width when it fit and AT LEAST `scroll.x + width` when it was cut
off. Understating a cut row is exactly what a high-water mark does, and
it means the mark costs the paint loop NOTHING.

MUTATING `widest` and `sel.n` inside `render!` is safe for the reason
`Scrollpane.render!` gives at length (scroll.jl:389-415): neither is a
`Reactive`, so this marks NOTHING and cannot loop, and it converges.
"""

"""
Keys: see `_tc_key!`. Consumes only when something actually moved.
"""
on_event!(w::List, d::Dispatch{KeyEvent})::Nothing =
    (_tc_key!(w, d); nothing)

"""
Mouse: see `_tc_mouse!`. Consumes only when something actually changed.
"""
on_event!(w::List, d::Dispatch{MouseEvent})::Nothing =
    (_tc_mouse!(w, d); nothing)

"""
Show the cursor, and scroll every ancestor pane until this list is
visible. `reveal!` is called EXPLICITLY because overriding `on_focus!`
REPLACES the default that would have called it (widget.jl:666).
"""
on_focus!(w::List)::Nothing =
    (w.focused[] = true; reveal!(w); _focus_callback!(w))

"""
Hide the cursor.
"""
on_blur!(w::List)::Nothing =
    (w.focused[] = false; _blur_callback!(w))

# --- data ops. Each routes through `refresh_rows!`. -------------------

"""
Replace the contents. CLEARS the selection and cursor and rewinds the
scroll: every index the selection held names a row that may no longer
exist, and silently keeping them would select the WRONG ROWS.
`set_text!(::TextArea)` makes the same choice with the caret.

The mark is INVALIDATED for the same reason and by the same precedent:
`set_text!` calls `refresh_extent!`, because a mark measured over data
that no longer exists is not a high-water mark, it is a stale number.
Dropping it to ZERO and clearing `scanned` is the O(1) half of that --
`_lst_scan!` pays the rescan at the next query, and only if there IS
one -- and it leaves EXACTLY the state the constructor leaves, which is
what "replace the contents" should mean.
"""
function set_items!(w::List{T}, xs::AbstractVector)::Nothing where {T}
    empty!(w.items)
    append!(w.items, xs)
    w.widest = 0
    # Exactly the constructor's seed: `0` is exact over no rows.
    w.scanned = isempty(w.items)
    s = w.sel
    # Exactly `Selection(mode, n)`'s state, written rather than
    # replaced because `sel` is `const`. `resize_selection!` alone will
    # not do it: it is O(1) and returns EARLY when the count is
    # unchanged, so replacing 20 items with 20 others would keep the
    # old cursor -- pointing at a different row.
    resize_selection!(s, length(w.items))
    clear_selection!(s)
    s.cursor = s.n == 0 ? 0 : 1
    s.anchor = s.cursor
    set_scroll!(w, ORIGIN)
    refresh_rows!(w)
    return nothing
end

"""
Append `x`. O(1) plus an O(text_width(x)) mark raise.
"""
function push_item!(w::List{T}, x::T)::Nothing where {T}
    push!(w.items, x)
    _lst_widen!(w, x)
    refresh_rows!(w)
    return nothing
end

"""
Insert `x` at `i`, clamped. REINDEXES the selection via
`reindex_insert!`: every selected row at or above `i` moves up one.
"""
function insert_item!(w::List{T}, i::Int, x::T)::Nothing where {T}
    k = clamp(i, 1, length(w.items) + 1)
    insert!(w.items, k, x)
    _lst_widen!(w, x)
    # BEFORE `refresh_rows!`, which is what makes the shift happen at
    # all: `reindex_insert!` grows `n` itself, so the `_tc_sync!` inside
    # `refresh_rows!` then finds the count already right and returns on
    # its O(1) guard. Reversed, `resize_selection!` would grow `n`
    # first and the rows would never move.
    reindex_insert!(w.sel, k)
    refresh_rows!(w)
    return nothing
end

"""
Delete row `i`. False when out of range. REINDEXES via
`reindex_delete!`: `i` leaves the selection and the cursor lands on the
row that took its place, or on the new last row.
"""
function delete_item!(w::List, i::Int)::Bool
    (1 <= i <= length(w.items)) || return false
    deleteat!(w.items, i)
    reindex_delete!(w.sel, i)           # BEFORE `refresh_rows!`
    refresh_rows!(w)
    return true
end

"""
Bump `version`, re-sync the selection, re-clamp the scroll, follow the
cursor. THE single exit of every data change, so none of the four can be
forgotten at a call site -- `_ta_edited!`'s pattern (textarea.jl:461).
ALSO the public escape hatch for "I mutated `items` myself".
"""
function refresh_rows!(w::List)::Nothing
    _tc_touch!(w)
    _tc_sync!(w)
    _lst_reclamp!(w)
    _tc_follow_cursor!(w)
    return nothing
end
