# widgets/datatable.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode, and
# `RowsWidget`/`Selection`/`Column`/`TableGrid`, which
# widgets/tablecore.jl DEFINES and this file USES and MUST NOT redefine.
#
# This file is THIN and CONTAINS NO PAINT LOOP. It does NOT depend on
# widgets/table.jl: the grid painter is generic over `W<:RowsWidget` and
# lives in `tablecore.jl`.
#
# STUB: the struct, the seam and the docstrings are FINAL and are what
# `tablecore.jl` and the suite code against. The bodies below are the
# DATATABLE agent's to fill in.

"""
A `Table` plus a SORT: the same data, the same columns, the same paint
loop, viewed through an index PERMUTATION.

WHAT IT ADDS OVER `Table`, EXHAUSTIVELY:

    key::K                 `key(row, j)` -> something `isless` accepts
    order::Vector{Int}     view -> source. THE sort.
    rank::Vector{Int}      source -> view. The inverse.
    sort_col::Int          `0` == source order
    sort_dir::SortDir.T
    a sort indicator in the header, and a header click that sorts.

Everything else -- the columns, the sizing, the header, the truncation,
the selection, the navigation, the scrolling, the paint -- is
`tablecore`'s, reached through _tc_render_table! and the seam.

WHY TWO TYPES AND NOT ONE WITH A NULLABLE `order`: because `view_source`
is the ONLY behavioural difference, and it is `k` for one and `order[k]`
for the other. One type would branch on a nullable field ONCE PER
VISIBLE ROW PER FRAME, forever, on every table in every app, to serve
the ones that never sort. Two types make the compiler take that branch
ONCE, at specialisation time, and a `Table` that never sorts pays
neither the branch nor the 2n `Int`s -- 1.6 MB on 100 000 rows -- that
`order` and `rank` cost. That is not a new argument in this codebase, it
is the house one (label.jl:98, `Scrollbar{V}`).

TWO CALLBACKS, `cell` AND `key`, and the separation is the whole point:

    cell(row, j)::AbstractString  -- what the user SEES
    key(row, j)                   -- what the sort COMPARES

Sorting a numeric column by its RENDERED string puts "10" before "9".
That is a bug in every table library that conflates the two.

`key` IS A REQUIRED KEYWORD. It has NO default, and in particular it
does NOT default to `cell`. A default that silently does the wrong thing
is an honest confession of a dishonest default; a `sort_by!` that
silently no-ops is a quiet nothing on the one call whose entire purpose
is to change something. A required keyword makes the decision
UNAVOIDABLE AT CONSTRUCTION and unmissable in review. A `DataTable`
exists to sort; one without a sort key is a `Table`.

`key(row, j)` must return values mutually `isless`-comparable WITHIN a
column. Across columns it may return anything: the sort closes over a
FIXED `j`, so every comparison in a given `sort_by!` is homogeneous. A
column of MIXED types THROWS a `MethodError` from `isless` -- it is not
"merely slow".
"""
mutable struct DataTable{R,F,K,A,C} <: RowsWidget
    "Per-widget state."
    node::WidgetNode
    "The column model. IDENTICAL in kind to `Table`'s."
    const grid::TableGrid
    "THE CALLER'S rows. ALIASED. NEVER reordered, never copied."
    const rows::Vector{R}
    "`cell(row, j)::AbstractString`. CONCRETE: dispatches statically."
    const cell::F
    """
    `key(row, j)`. CONCRETE. Called O(rows) ONCE per sort -- a user
    action -- and NEVER on the frame path.
    """
    const key::K
    """
    View to source: `order[k]` is the source row of view row `k`.
    ALWAYS a permutation of `1:length(rows)`.
    """
    const order::Vector{Int}
    """
    Source to view: `rank[order[k]] == k`. Rebuilt in ONE O(n) pass
    after every sort, off the frame path.

    It exists because navigation is a VIEW question ("what is below the
    cursor?") and the selection is a SOURCE fact. Without it, DOWN would
    be an O(n) search through `order` PER KEYSTROKE. 8 bytes per row to
    make a keystroke O(1) is the right trade; it is bounded; and it is
    stated.
    """
    const rank::Vector{Int}
    "The sorted column, or `0` for source order."
    sort_col::Int
    "The sort direction. `NONE` iff `sort_col == 0`."
    sort_dir::SortDir.T
    "Bumped by every data OR selection change. Dirty.PAINT."
    version::Reactive{Int}
    "Cursor and selected set, in SOURCE row indices."
    const sel::Selection
    "True while focused. PAINT-reactive."
    focused::Reactive{Bool}
    "True if the table is disabled."
    disabled::Reactive{Bool}
    "Called as `on_submit(table)` on ENTER."
    on_submit::A
    "Called as `on_change(w)` when the cursor moves."
    on_change::C
end

"""
A sortable table of `rows` under `cols`, calling `on_submit(table)` on
ENTER. Starts in SOURCE order.

`key` is REQUIRED and has no default: see the type's docstring. `rows`
and `cols` are both ALIASED, never copied.
"""
function DataTable(rows::Vector{R}, cols::Vector{Column},
                   on_submit::A = _tc_noop;
               on_change::C = _tc_noop,
                   key::K,                       # REQUIRED. No default.
                   cell::F = _tc_cell_default,
                   mode::SelectMode.T = SelectMode.SINGLE,
                   sep::AbstractString = " ", show_header::Bool = true,
                   rule::Bool = false,
                   rule_glyph::AbstractString = TC_RULE,
                   sample::Int = TC_AUTO_SAMPLE,
                   disabled::Bool = false,
                   id::Symbol = gensym(:datatable),
                   classes = Symbol[])::DataTable{R,F,K,A,C} where
                  {R,F,K,A,C}
    n = length(rows)
    w = DataTable{R,F,K,A,C}(
        WidgetNode(; id = id, classes = classes, type_name = :DataTable,
                   focusable = true),
        TableGrid(cols; sep = sep, show_header = show_header,
                  rule = rule, rule_glyph = rule_glyph, sample = sample),
        rows, cell, key,
        collect(1:n), collect(1:n),
        0, SortDir.NONE,
        Reactive(0; kind = Dirty.PAINT),
        Selection(mode, n),
        Reactive(false; kind = Dirty.PAINT),
        Reactive(disabled; kind = Dirty.PAINT),
        on_submit,
        on_change)
    attach_reactives!(w)
    # The AUTO seed, ONCE: the headers plus SOURCE rows 1:min(sample, n).
    # Nothing rescans them again unless `refresh_extent!` is called.
    _tc_auto_reset!(w)
    _tc_auto!(w, 1, min(sample, n))
    return w
end

_tc_on_change(w::DataTable) = w.on_change(w)

# --- the seam. The `order`/`rank` indirection IS the whole delta. -----
selection_of(w::DataTable)::Selection = w.sel
row_count(w::DataTable)::Int = length(w.rows)
view_count(w::DataTable)::Int = length(w.order)
view_source(w::DataTable, k::Int)::Int = @inbounds w.order[k]
view_rank(w::DataTable, s::Int)::Int = @inbounds w.rank[s]
grid_of(w::DataTable)::TableGrid = w.grid
_tc_touch!(w::DataTable)::Nothing =
    (w.version[] = w.version[] + 1; nothing)

"""
`(show_header ? 1 : 0) + (show_header && rule ? 1 : 0)`. The rows of the
content box that are pinned CHROME. `0`, `1` or `2`. Internal.
"""
function _tc_header_rows(w::DataTable)::Int
    w.grid.show_header || return 0
    return w.grid.rule ? 2 : 1
end

"""
`Size(cache_total, view_count + header_rows)`. OVERRIDES the container
default; THIS OVERRIDE IS THE WHOLE INTEGRATION WITH `Scrollbar` --
`Scrollbar{DataTable{R,F,K,A}}` works with ZERO new code in `scroll.jl`.
O(1) on the FRAME PATH.
"""
content_extent(w::DataTable)::Size = _tc_extent(w)

"""
`avail`. A `DataTable` takes the space it is OFFERED and scrolls its
content. Pure w.r.t. the tree.
"""
measure(w::DataTable, avail::Size)::Size = avail


"""
Keys: see `_tc_key!`. Consumes only when something actually moved.
"""
on_event!(w::DataTable, d::Dispatch{KeyEvent})::Nothing =
    (_tc_key!(w, d); nothing)

"""
Show the cursor, and scroll every ancestor pane until this table is
visible. `reveal!` is called EXPLICITLY because overriding `on_focus!`
REPLACES the default that would have called it (widget.jl:666).
"""
on_focus!(w::DataTable)::Nothing =
    (w.focused[] = true; reveal!(w); _focus_callback!(w))

"""
Hide the cursor.
"""
on_blur!(w::DataTable)::Nothing =
    (w.focused[] = false; _blur_callback!(w))

"""
Reset and re-measure every AUTO mark over EVERY row, re-resolve, and
return the new `content_extent`. THE OPT-IN EXACT RESCAN, and the ONLY
thing that can make an AUTO column NARROWER.
"""
function refresh_extent!(w::DataTable)::Size
    _tc_auto_reset!(w)
    _tc_auto!(w, 1, row_count(w))
    e = content_extent(w)
    # This is the only call that can SHRINK the extent and strand an
    # offset past the end.
    scroll_to!(w, scroll_of(w))
    return e
end

"""
1 for a `sortable` column: the indicator needs a cell to live in, and an
AUTO column sized to its header text alone would have nowhere to draw
it. Internal.
"""
_tc_header_reserve(w::DataTable, j::Int)::Int =
    grid_of(w).cols[j].sortable ? 1 : 0

"""
`TC_SORT_ASC`, `TC_SORT_DESC`, or `""` when column `j` is not the sorted
one.
"""
function sort_indicator(w::DataTable, j::Int)::String
    (j >= 1 && j === w.sort_col) || return ""
    w.sort_dir === SortDir.ASCENDING && return TC_SORT_ASC
    w.sort_dir === SortDir.DESCENDING && return TC_SORT_DESC
    return ""
end

"""
`n` spaces; the empty string at or below zero. Pure. Internal.
"""
_dt_pad(n::Int)::String = n > 0 ? " "^n : ""

"""
The caption, and the sort indicator when this is the sorted column.

THE INDICATOR IS PAINTED IN THE COLUMN'S LAST CELL BY `_tc_put!`, not
APPENDED to the caption. Appending is the obvious spelling and is wrong
twice: a narrow column would TRUNCATE THE INDICATOR AWAY -- so the one
column whose state you must see is the one that hides it -- and the
column's AUTO width would depend on its sort state, so CLICKING A HEADER
WOULD RESIZE IT.

THE GUTTER IS RESERVED IN EVERY SORTABLE COLUMN, ALWAYS, and left blank
when unsorted (`_tc_header_reserve`). Reserving it only when sorted
would change the caption's width the moment you sort, so the caption
would re-truncate and the header would twitch. `ScrollMode.AUTO`'s
doctrine, quoted: THE GUTTER IS STABLE, THE INK IS NOT. Internal.
"""
function _tc_header_text(w::DataTable, j::Int)::AbstractString
    g = w.grid
    col = g.cols[j]
    # A column no indicator can ever land in gets EVERY cell for its
    # caption, and `_tc_put!` aligns and truncates it exactly as it does
    # a `Table`'s.
    _tc_header_reserve(w, j) == 0 && return col.header
    # _tc_render_table! resolves the columns BEFORE it paints the
    # header, and guards this call with `ws[j] > 0`, so this is the width
    # the caption is about to be painted into.
    cw = g.widths[j]
    cw <= 0 && return col.header
    ind = sort_indicator(w, j)
    isempty(ind) && (ind = " ")             # the gutter, reserved, blank
    capw = cw - 1
    capw <= 0 && return ind
    # The string is built to EXACTLY `cw` cells, so `_tc_put!` neither
    # truncates it nor shifts it: the indicator lands in the column's
    # LAST cell and the caption is placed here, in the `capw` cells the
    # gutter leaves -- which is why sorting can never re-truncate it.
    t = truncate_width(col.header, capw)
    if _tc_truncated(t, col.header)
        # A truncated caption is LEFT-ANCHORED and marked, whatever
        # `align` says -- `_tc_put!`'s rule, applied to the caption area.
        cap = string(truncate_width(col.header, capw - 1), TC_ELLIPSIS)
        lead = 0
    else
        cap = string(t)
        lead = first(cross_align(text_width(t), col.align, capw))
    end
    trail = capw - lead - text_width(cap)
    return string(_dt_pad(lead), cap, _dt_pad(trail), ind)
end

"The sorted column, or `0` for source order. Pure."
sort_column(w::DataTable)::Int = w.sort_col

"The sort direction. `NONE` iff `sort_column(w) == 0`. Pure."
sort_direction(w::DataTable)::SortDir.T = w.sort_dir

"""
The caller's row index behind VIEW row `k`. The map a selection needs --
and `selected_rows(w)` is ALREADY in source indices, so this is for
reading the view, not for repairing it. Pure.
"""
source_index(w::DataTable, k::Int)::Int = w.order[k]

"""
Rebuild `rank` from `order` in ONE pass: `rank[order[k]] = k`. O(n), off
the frame path. Internal.
"""
function _dt_rank!(w::DataTable)::Nothing
    @inbounds for k in eachindex(w.order)
        w.rank[w.order[k]] = k
    end
    return nothing
end

"""
Resize `order`/`rank` to `length(rows)`. True iff either was resized --
in which case the grown slots are UNDEFINED and every caller must write
`order` whole before `_dt_rank!` reads it. Internal.
"""
function _dt_fit!(w::DataTable)::Bool
    n = length(w.rows)
    (length(w.order) === n && length(w.rank) === n) && return false
    resize!(w.order, n)
    resize!(w.rank, n)
    return true
end

"""
Write `p` into `order`. True iff any entry moved. `p` is a permutation of
`1:length(rows)` -- `sortperm`'s answer, or the identity. Internal.
"""
function _dt_order!(w::DataTable, p::AbstractVector{Int})::Bool
    changed = false
    @inbounds for k in eachindex(p)
        w.order[k] === p[k] || (changed = true)
        w.order[k] = p[k]
    end
    return changed
end

"""
Restore SOURCE order: `order[k] = k`. True iff any entry moved. Internal.
"""
function _dt_identity!(w::DataTable)::Bool
    changed = false
    @inbounds for k in eachindex(w.order)
        w.order[k] === k || (changed = true)
        w.order[k] = k
    end
    return changed
end

"""
The permutation column `j` in direction `dir` puts `rows` in, WITHOUT
touching `rows`. See `sort_by!` for why the keys are materialised first
and why `MergeSort` is spelled. O(n) keys + O(n log n). Internal.
"""
function _dt_perm(w::DataTable, j::Int, dir::SortDir.T)::Vector{Int}
    n = length(w.rows)
    ks = [w.key(w.rows[i], j) for i in 1:n]
    return sortperm(ks; alg = MergeSort,
                    rev = (dir === SortDir.DESCENDING))
end

"""
Rebuild `order`/`rank` from the CURRENT sort state: the identity when
`sort_col == 0`, the permutation otherwise. THE reapply, and the whole of
what a data change owes the sort. Internal.
"""
function _dt_reapply!(w::DataTable)::Nothing
    _dt_fit!(w)
    if w.sort_col == 0 || w.sort_dir === SortDir.NONE
        _dt_identity!(w)
    else
        _dt_order!(w, _dt_perm(w, w.sort_col, w.sort_dir))
    end
    _dt_rank!(w)
    return nothing
end

"""
Sort the VIEW by column `j` in direction `dir`. `j == 0` or
`dir === SortDir.NONE` restores SOURCE order. Returns true iff the order
changed.

THE ORDER, PRECISELY: the view order OR the sorted column OR the
direction -- "something actually changed", which is the convention every
mutator in this family follows (`set_scroll!`, widget.jl:204). The three
are ONE fact and the wider reading is the load-bearing one: a column
whose keys are ALL EQUAL flips ASCENDING to DESCENDING without moving a
single row, and a `false` there would skip the PAINT bump and leave the
header showing an arrow that contradicts `sort_direction(w)`. The
indicator is state, not order.

THROWS `ArgumentError` when `1 <= j <= ncols` and `!cols[j].sortable`,
and `BoundsError` on a `j` outside `0:ncols`. It does NOT silently
no-op: a quiet nothing on the one call whose whole purpose is to change
something is the worst available failure.

DOES NOT MUTATE THE CALLER'S DATA, and the mechanism IS the whole
answer: `sortperm` READS `rows` and returns a PERMUTATION. `rows` is
never touched, never permuted, never copied. Sorting a COPY costs O(n)
memory and O(n) moves of `R` and severs identity; sorting IN PLACE
mutates a `Vector` the caller handed us and may still be using. The
permutation costs 8n bytes, moves `Int`s, and `view_source`'s one array
load is the entire read side.

THE ALGORITHM IS SPELLED, NOT DEFAULTED:

    ks = [w.key(w.rows[i], j) for i in 1:n]
    p  = sortperm(ks; alg = MergeSort, rev = (dir === DESCENDING))

  * MATERIALIZING `ks` FIRST IS NOT AN OPTIMISATION, IT IS THE
    ALGORITHM. `sort!(order; by = i -> key(rows[i], j))` runs `by` TWICE
    PER COMPARISON, because `Base.Order.By` has no Schwartzian
    transform. MEASURED: 17824 `by` calls at n=2000 versus 2000 for this
    spelling -- ~9x. The comprehension also INFERS its eltype, so a
    numeric column sorts a concrete `Vector{Float64}`.
  * `alg = MergeSort` IS SPELLED even though `sortperm`'s default is
    already stable. Stability is a CONTRACT here, and a contract you get
    from a default is a contract you will lose.
  * `rev = true` REVERSES THE ORDERING, NOT THE OUTPUT, so ties keep
    their SOURCE order in BOTH directions:
    `sortperm([2,1,2,1,2]; rev=true, alg=MergeSort) == [1,3,5,2,4]`,
    NOT `[5,3,1,4,2]`. That is what "stable" has to mean for a user who
    sorts by Department then by Name and expects the Names still in
    order within a Department.
  * `order` is RESET to `1:n` before every sort, so `sort_by!(w, 2,
    ASCENDING)` gives the same answer whatever the history. THE PRICE:
    no multi-key sort by chaining. That feature is not lost, it is
    RELOCATED to where it costs nothing -- `key = (r, j) -> (r.dept,
    r.name)` IS the multi-key sort, it is one line of user code, and
    unlike chaining it says what it means.

THE SELECTION DOES NOT MOVE, AND THERE IS NO CODE HERE THAT MOVES IT.
`Selection` stores SOURCE indices, so a sort -- a claim about ORDER --
cannot touch a selection -- a claim about ROWS. That is the entire
reason the index space is source-based, and it is why this function has
no `remap!` to get wrong. The cursor does not change ROW; it changes
SCREEN POSITION, because `view_rank` changed. `_tc_follow_cursor!` then
runs, so THE USER'S ROW STAYS UNDER THEIR EYES across the sort.

THE COLUMN WIDTHS DO NOT CHANGE: `_tc_auto!` samples SOURCE rows
`1:sample`, never view rows, so a width that moved under a sort is
impossible by construction.

O(n) key materialisation + O(n log n) sortperm + O(n) `_dt_rank!`. ALL
OF IT ON A USER ACTION, once per header click. The frame path is
untouched.
"""
function sort_by!(w::DataTable, j::Int;
                  dir::SortDir.T = SortDir.ASCENDING)::Bool
    g = w.grid
    (0 <= j <= length(g.cols)) || throw(BoundsError(g.cols, j))
    (j >= 1 && !g.cols[j].sortable) && throw(ArgumentError(
        "sort_by!: column $(j) ($(repr(g.cols[j].header))) is not " *
        "sortable"))
    src = j == 0 || dir === SortDir.NONE
    col = src ? 0 : j
    d = src ? SortDir.NONE : dir
    # The INDICATOR is state, not order: a column whose keys are all
    # equal changes its arrow without moving a row, and a header that
    # does not repaint then lies about how its data is sorted.
    changed = w.sort_col !== col || w.sort_dir !== d
    _dt_fit!(w) && (changed = true)
    w.sort_col = col
    w.sort_dir = d
    # `sortperm` READS `rows` and returns a PERMUTATION indexed by SOURCE
    # row, so `order` is RESET to `1:n` by construction -- the sort is
    # never applied on top of the last one -- and THE CALLER'S VECTOR IS
    # NEVER TOUCHED, never permuted, never copied.
    moved = src ? _dt_identity!(w) : _dt_order!(w, _dt_perm(w, col, d))
    moved && (changed = true)
    changed || return false
    _dt_rank!(w)
    _tc_touch!(w)
    # THE SELECTION DOES NOT MOVE, AND THERE IS NO CODE HERE THAT MOVES
    # IT: `Selection` stores SOURCE indices. The cursor keeps its ROW and
    # changes SCREEN POSITION, so this is what keeps it under the eyes
    # that were on it.
    _tc_follow_cursor!(w)
    return true
end

"""
Cycle column `j`: ASCENDING -> DESCENDING -> ASCENDING. What a header
CLICK does.

There is NO click path to `SortDir.NONE`: a third state that looks
identical to "sorted by whatever it was before" is a state a user cannot
see and therefore cannot want. `sort_by!(w, 0)` restores source order
for a caller who means it. Clicking a NEW column sorts ASCENDING.
"""
function toggle_sort!(w::DataTable, j::Int)::Bool
    asc = w.sort_col === j && w.sort_dir === SortDir.ASCENDING
    return sort_by!(w, j;
                    dir = asc ? SortDir.DESCENDING : SortDir.ASCENDING)
end

"""
True when `e` points at the pinned header rows of `w` -- the caption row
and the rule under it, which is exactly the block `_tc_header_rows`
counts and exactly the block `_tc_row_at` refuses to call a body row.

`_tc_local`, NEVER `local_offset`: inside a `Scrollpane` scrolled to
`y = 3` the unshifted border box would call a BODY row a header and sort
on a click that meant to select. Internal.
"""
function _dt_on_header(w::DataTable, e::MouseEvent)::Bool
    hh = _tc_header_rows(w)
    hh >= 1 || return false
    c = layout_of(w).content
    (c.width <= 0 || c.height <= 0) && return false
    o = _tc_local(w, e)
    (1 <= o.x <= c.width) || return false
    return 1 <= o.y <= min(hh, c.height)
end

"""
A LEFT PRESS on the HEADER rows sorts the column under the pointer;
everything else is `_tc_mouse!`. That one branch is `DataTable`'s entire
mouse delta. A press on a non-`sortable` column consumes nothing and
does nothing.

Uses `grid_of(w).xs`/`widths` -- LAST frame's -- which is exactly the
header the user saw and clicked. Before the first paint they are zeros
and a click does nothing, which is correct: there was no header to
click.
"""
function on_event!(w::DataTable, d::Dispatch{MouseEvent})::Nothing
    _tc_acts(d) || return nothing
    e = event(d)
    # LEFT PRESS only, so a WHEEL notch over the header still reaches
    # `_tc_mouse!` and still scrolls the body.
    if e.button === MouseButton.LEFT && e.action === MouseAction.PRESS &&
       _dt_on_header(w, e)
        j = _tc_col_at(w, e)
        # `0` for no column, and `0` before the first paint -- the widths
        # are zeros then, which is correct: there was no header to click.
        (1 <= j <= length(w.grid.cols)) || return nothing
        # A non-sortable column consumes nothing and does nothing. It
        # does NOT throw: `sort_by!` throws because a CALLER who names an
        # unsortable column has made a mistake, and a user whose pointer
        # merely landed on one has not.
        w.grid.cols[j].sortable || return nothing
        toggle_sort!(w, j) && consume!(d)
        return nothing
    end
    _tc_mouse!(w, d)
    return nothing
end

# --- data ops. `order`/`rank` are resized and the sort is REAPPLIED. --

"""
Replace the contents. CLEARS the selection and cursor, rewinds the
scroll, re-seeds the AUTO marks and rebuilds `order`/`rank`.
"""
function set_rows!(w::DataTable{R},
                   rows::AbstractVector)::Nothing where {R}
    empty!(w.rows)
    append!(w.rows, rows)
    s = w.sel
    # CLEARED, not remapped: every index the selection held names a row
    # that may no longer exist, and silently keeping them would select the
    # WRONG ROWS. `resize_selection!(s, 0)` drops every row and zeroes the
    # cursor; the second call re-pins it to row 1 (or leaves it at 0).
    resize_selection!(s, 0)
    resize_selection!(s, length(w.rows))
    _dt_reapply!(w)
    if row_count(w) > 0
        # The cursor belongs at the TOP OF THE VIEW, which under a live
        # sort is not SOURCE row 1. `clear_selection!` undoes the pick
        # `set_cursor!` makes under SINGLE/MULTI: a fresh table has a
        # cursor and NOTHING selected.
        set_cursor!(s, view_source(w, 1))
        clear_selection!(s)
    end
    set_scroll!(w, ORIGIN)
    _dt_reseed!(w)                      # the seeding pass, as at ctor
    _tc_touch!(w)
    return nothing
end

"""
Append `r`. Raises the AUTO marks from the new row alone, then
REAPPLIES the current sort.
"""
function push_row!(w::DataTable{R}, r::R)::Nothing where {R}
    push!(w.rows, r)
    # The new row ALONE: the marks are MONOTONE, so nothing rescans the
    # sample and building a table by `push_row!` stays O(1) per row.
    _tc_auto!(w, length(w.rows), length(w.rows))
    refresh_rows!(w)
    return nothing
end

"""
Insert `r` at SOURCE index `i`, clamped. REINDEXES the selection via
`reindex_insert!`, then REAPPLIES the current sort.
"""
function insert_row!(w::DataTable{R}, i::Int, r::R)::Nothing where {R}
    k = clamp(i, 1, length(w.rows) + 1)
    insert!(w.rows, k, r)
    # Source indices are structurally safe against REORDERING; they are
    # NOT safe against insertion, and this is the price -- paid by the
    # mutation rather than by the frame.
    reindex_insert!(w.sel, k)
    _tc_auto!(w, k, k)
    refresh_rows!(w)
    return nothing
end

"""
Delete SOURCE row `i`. False when out of range. REINDEXES via
`reindex_delete!` and rebuilds `order`/`rank`.
"""
function delete_row!(w::DataTable, i::Int)::Bool
    (1 <= i <= length(w.rows)) || return false
    deleteat!(w.rows, i)
    reindex_delete!(w.sel, i)
    refresh_rows!(w)
    return true
end

"""
THE single exit. Rebuilds `order`/`rank` to `1:n`, REAPPLIES the current
sort when `sort_col != 0`, bumps `version`, re-syncs the selection,
re-clamps the scroll, follows the cursor. O(n log n) when sorted -- a
data change, never a frame.
"""
function refresh_rows!(w::DataTable)::Nothing
    _dt_reapply!(w)
    _tc_touch!(w)
    _tc_sync!(w)
    scroll_to!(w, scroll_of(w))         # the data may have SHRUNK
    _tc_follow_cursor!(w)
    return nothing
end

"""
Replace the columns. Resizes `widths`/`xs`/`autos`, re-seeds the AUTO
marks and invalidates the memo. Resets the sort when `sort_col` is no
longer a valid column.
"""
function set_columns!(w::DataTable, cols::Vector{Column})::Nothing
    g = w.grid
    n = length(cols)
    resize!(g.cols, n)
    copyto!(g.cols, cols)
    resize!(g.autos, n)
    resize!(g.widths, n)
    resize!(g.xs, n)
    # `resize!` leaves the grown slots UNDEFINED, and `_tc_col_at` reads
    # `widths` WITHOUT resolving -- so a click landing between here and
    # the next paint would hit-test against garbage. Zeroed, it hits
    # nothing, which is the same answer as before the first paint.
    fill!(g.autos, 0)
    fill!(g.widths, 0)
    fill!(g.xs, 0)
    if w.sort_col > n || (w.sort_col >= 1 && !g.cols[w.sort_col].sortable)
        # The sorted column no longer exists, or no longer sorts: the
        # sort has nothing left to be about.
        w.sort_col = 0
        w.sort_dir = SortDir.NONE
        _dt_reapply!(w)
    end
    refresh_columns!(w)
    return nothing
end

"""
Re-seed the AUTO marks and invalidate the memo after `grid_of(w).cols`
was written in place.

RE-MEASURES THE SAMPLE, exactly as construction does, and not the
headers alone. `_tc_auto_reset!` LOWERS every AUTO mark to its header
seed, so a reset that stopped there would collapse every AUTO column to
its own caption: re-speccing ONE column's alignment would silently
resize its NEIGHBOURS. A column model rewritten is a column model
measured, and the cost is the construction cost -- O(min(sample, n) x
AUTO columns), bounded, on an explicit call and never on a frame.

The `Table` twin's `refresh_columns!` states the same rule, and this is
what `DataTable` itself does at construction and at `set_rows!`. No
data-change path (`push_row!`/`insert_row!`/`delete_row!`) rescans.
"""
function refresh_columns!(w::DataTable)::Nothing
    _dt_reseed!(w)                      # invalidates the memo
    _tc_touch!(w)
    return nothing
end

"""
Reset every AUTO mark to its header seed and re-measure SOURCE rows
`1 : min(sample, n)` -- the seeding pass, exactly as at construction.

THE ONE PLACE the sample is re-scanned, and it is never a data change.
Mirrors `_tb_reseed!(::Table)`. Internal.
"""
function _dt_reseed!(w::DataTable)::Nothing
    _tc_auto_reset!(w)
    _tc_auto!(w, 1, min(w.grid.sample, row_count(w)))
    return nothing
end
