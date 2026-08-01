# widgets/table.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode, and
# `RowsWidget`/`Selection`/`Column`/`TableGrid`, which
# widgets/tablecore.jl DEFINES and this file USES and MUST NOT redefine.
#
# This file is THIN and contains NO PAINT LOOP: _tc_render_table! is
# generic over `W<:RowsWidget` and lives in `tablecore.jl`, so
# `datatable.jl` does not depend on this file for anything.
#
# THE HEADER DOES NOT SCROLL VERTICALLY BUT DOES FOLLOW THE COLUMNS
# HORIZONTALLY. That asymmetry is the whole point of a table header --
# get it wrong and the header lies about which column you are looking at
# -- and it is not a mechanism here, it is the ABSENCE of one: the
# painter reads `xs[j] - off.x` for the header AND the body, and reads
# `off.y` for the body ALONE. One arithmetic, two `y` rules, in
# _tc_render_table!.
#
# A ROW IS NOT A WIDGET: 100 000 rows are 100 000 elements of a `Vector`
# and ZERO `WidgetNode`s. `content_extent` is overridden and O(1), and
# `render!` is O(visible rows x VISIBLE columns), so a 100 000 x 500
# table costs the same frame as a 20 x 6 one.
#
# `Base.textwidth` appears NOWHERE. No byte indexes user text.

"""
Columns with headers over a `Vector` of rows.

`Table` OWNS its rows. A view that owns nothing cannot answer
`_tc_sync!`, cannot `reindex_*` its selection, and forces a SECOND data
model across `Table`/`DataTable` -- which is a second paint loop or a
messier seam. One data model, one paint loop, and `view_source` is the
only delta between the two widgets. A caller with a lazy source
materialises a window into a `Vector` themselves.

THE CELL CALLBACK IS ON THE WIDGET, NOT ON THE COLUMN, and this is the
decisive type decision of the tier. A `Vector{Column{T,G}}` parametric
on the projection is IMPOSSIBLE -- each column's closure has its own
type, so one `G` cannot serve them all -- which forces `Column` to hold
an ABSTRACT projection field and pay ONE DYNAMIC DISPATCH PER VISIBLE
CELL, FOREVER. `cell::F` on the widget is one CONCRETE type parameter, a
STATIC dispatch, the same expressive power (`cell(row, j)` can branch on
`j` however it likes), and it is the `Button{F}` pattern this package
already uses three times.

`rows` is a PLAIN field, ALIASED, not a `Reactive` -- `List`'s reason,
`List`'s price, `List`'s `render!`-time self-heal via `_tc_sync!`.

`version` is `Dirty.PAINT`-reactive -- `List`'s reason, verbatim.

`cell(row, j)` MUST return an `AbstractString`, MUST be PURE and CHEAP,
and MUST NOT contain a newline. It is called ONCE PER VISIBLE CELL PER
FRAME -- never for a culled column, never for a row outside the window,
and never during `_tc_auto!` for a non-AUTO column.
"""
mutable struct Table{R,F,A} <: RowsWidget
    "Per-widget state."
    node::WidgetNode
    "The column model. IDENTICAL in kind to `DataTable`'s."
    const grid::TableGrid
    "The rows. ALIASED. Mutated IN PLACE, via the ops."
    const rows::Vector{R}
    "`cell(row, j)::AbstractString`. CONCRETE: dispatches statically."
    const cell::F
    "Bumped by every data OR selection change. Dirty.PAINT."
    version::Reactive{Int}
    "Cursor and selected set, in SOURCE row indices."
    const sel::Selection
    "True while focused. PAINT-reactive."
    focused::Reactive{Bool}
    "Called as `on_activate(table)` on ENTER."
    on_activate::A
end

"""
The default cell function: `_tc_show(row[j])`. Works for a `Vector` of
`Tuple`s, of `NamedTuple`s and of `Vector`s -- the three shapes a
table's rows actually arrive in -- and for nothing else, which is
exactly what the `cell` keyword is for. Internal.
"""
_tc_cell_default(row, j::Int)::AbstractString = _tc_show(row[j])

"""
A table of `rows` under `cols`, calling `on_activate(table)` on ENTER.

`rows` and `cols` are both ALIASED, never copied. Focusable by
construction. Seeds every AUTO column from the headers and SOURCE rows
`1 : min(sample, length(rows))`, once -- see `_tc_auto!`.
"""
function Table(rows::Vector{R}, cols::Vector{Column},
               on_activate::A = _tc_noop;
               cell::F = _tc_cell_default,
               mode::SelectMode.T = SelectMode.SINGLE,
               sep::AbstractString = " ", show_header::Bool = true,
               rule::Bool = false, rule_glyph::AbstractString = TC_RULE,
               sample::Int = TC_AUTO_SAMPLE,
               id::Symbol = gensym(:table),
               classes = Symbol[])::Table{R,F,A} where {R,F,A}
    w = Table{R,F,A}(WidgetNode(; id = id, classes = classes,
                                type_name = :Table, focusable = true),
                     TableGrid(cols; sep = sep,
                               show_header = show_header, rule = rule,
                               rule_glyph = rule_glyph, sample = sample),
                     rows, cell,
                     Reactive(0; kind = Dirty.PAINT),
                     Selection(mode, length(rows)),
                     Reactive(false; kind = Dirty.PAINT),
                     on_activate)
    # The ONE seeding pass, and it is BOUNDED: the headers, then SOURCE
    # rows `1 : min(sample, n)`. Nothing measures anything again until a
    # row is inserted, the columns change, or `refresh_extent!` is called
    # and paid for.
    _tb_reseed!(w)
    attach_reactives!(w)
    return w
end

# --- the seam. FINAL: `tablecore.jl` dispatches on every one of these.
selection_of(w::Table)::Selection = w.sel
row_count(w::Table)::Int = length(w.rows)
view_count(w::Table)::Int = length(w.rows)
view_source(::Table, k::Int)::Int = k
view_rank(::Table, s::Int)::Int = s
grid_of(w::Table)::TableGrid = w.grid
_tc_touch!(w::Table)::Nothing = (w.version[] = w.version[] + 1; nothing)

"""
`(show_header ? 1 : 0) + (show_header && rule ? 1 : 0)`. The rows of the
content box that are pinned CHROME. `0`, `1` or `2`. Internal.
"""
function _tc_header_rows(w::Table)::Int
    g = w.grid
    g.show_header || return 0
    return g.rule ? 2 : 1
end

"""
`Size(cache_total, row_count + header_rows)`. OVERRIDES the container
default: a `Table`'s content is DATA, not children. THIS OVERRIDE IS THE
WHOLE INTEGRATION WITH `Scrollbar` -- `Scrollbar{Table{R,F,A}}` works
with ZERO new code in `scroll.jl`. See `_tc_extent` for why the header
rows are counted and why dropping them would make the last `hh` rows of
every table unreachable. O(1) on the FRAME PATH.
"""
content_extent(w::Table)::Size = _tc_extent(w)

"""
`avail`. A `Table` takes the space it is OFFERED and scrolls its
content: an auto-HEIGHT table would be as tall as its data and would
never scroll at all. This is also what licenses `version`'s PAINT
reactivity. Pure w.r.t. the tree.
"""
measure(w::Table, avail::Size)::Size = avail


"""
Keys: see `_tc_key!`. Consumes only when something actually moved.
"""
on_event!(w::Table, d::Dispatch{KeyEvent})::Nothing =
    (_tc_key!(w, d); nothing)

"""
Mouse: see `_tc_mouse!`. A press on the header does nothing: a `Table`
never sorts.
"""
on_event!(w::Table, d::Dispatch{MouseEvent})::Nothing =
    (_tc_mouse!(w, d); nothing)

"""
Show the cursor, and scroll every ancestor pane until this table is
visible. `reveal!` is called EXPLICITLY because overriding `on_focus!`
REPLACES the default that would have called it (widget.jl:666).
"""
on_focus!(w::Table)::Nothing = (w.focused[] = true; reveal!(w))

"""
Hide the cursor.
"""
on_blur!(w::Table)::Nothing = (w.focused[] = false; nothing)

"""
Reset and re-measure every AUTO mark over EVERY row, re-resolve, and
return the new `content_extent`. O(rows x AUTO columns), each cell
capped by `_tc_measure`.

THE OPT-IN EXACT RESCAN, and the same name and meaning as
`refresh_extent!(::TextArea)` and `refresh_extent!(::List)`. This is the
ONLY thing that can make an AUTO column NARROWER, and it is the
documented escape from the sampling rule.
"""
function refresh_extent!(w::Table)::Size
    _tc_auto_reset!(w)
    _tc_auto!(w, 1, length(w.rows))
    e = content_extent(w)
    # Re-clamp: this is the ONLY call that can SHRINK the extent, and so
    # the only one that can strand an offset past the end.
    # `refresh_extent!(::List)` re-clamps for the same reason.
    scroll_to!(w, scroll_of(w))
    return e
end

# --- data ops. Each routes through `refresh_rows!`. -------------------

"""
Replace the contents. CLEARS the selection and cursor, rewinds the
scroll and RE-SEEDS the AUTO marks: every index the selection held names
a row that may no longer exist.
"""
function set_rows!(w::Table{R}, rows::AbstractVector)::Nothing where {R}
    empty!(w.rows)
    append!(w.rows, rows)
    s = w.sel
    clear_selection!(s)
    resize_selection!(s, length(w.rows))
    # The cursor is re-pinned to the FIRST row DIRECTLY, and not through
    # `set_cursor!(s, 1)`: that would SELECT row 1 under SINGLE/MULTI,
    # and a table that selects a row before the user has touched it has
    # made a choice on their behalf. `resize_selection!` alone would not
    # move a cursor when the COUNT happens to be unchanged, and the rows
    # under it are new either way. `set_text!(::TextArea)` re-pins its
    # caret with the same two writes (textarea.jl:199).
    s.cursor = isempty(w.rows) ? 0 : 1
    s.anchor = s.cursor
    set_scroll!(w, ORIGIN)
    _tb_reseed!(w)
    refresh_rows!(w)
    return nothing
end

"""
Reset every AUTO mark to its header seed and re-measure SOURCE rows
`1 : min(sample, n)` -- the seeding pass, exactly as at construction.

THE ONE PLACE the sample is re-scanned, and it is never a data change:
`push_row!`/`insert_row!` raise the marks from the NEW ROW ALONE, which
is what keeps a push O(1). Internal.
"""
function _tb_reseed!(w::Table)::Nothing
    _tc_auto_reset!(w)
    _tc_auto!(w, 1, w.grid.sample)
    return nothing
end

"""
Append `r`. O(1) plus an O(cap) mark raise for that row alone -- nothing
rescans.
"""
function push_row!(w::Table{R}, r::R)::Nothing where {R}
    push!(w.rows, r)
    # THE NEW ROW ALONE. A `version`-keyed rescan of the whole sample
    # here would turn building a 100 000-row table by push into 20M cell
    # calls; the marks are MONOTONE, so raising them one row at a time
    # gives the same answer for O(1) each.
    n = length(w.rows)
    _tc_auto!(w, n, n)
    refresh_rows!(w)
    return nothing
end

"""
Insert `r` at `i`, clamped. REINDEXES the selection via
`reindex_insert!` and raises the AUTO marks from the new row alone.
"""
function insert_row!(w::Table{R}, i::Int, r::R)::Nothing where {R}
    # `_tc_sync!` FIRST, so `sel.n` is the PRE-insert count even when
    # `rows` was mutated behind `version`'s back: `reindex_insert!` is
    # arithmetic on that count and a stale one would shift the wrong
    # rows.
    _tc_sync!(w)
    t = clamp(i, 1, length(w.rows) + 1)
    insert!(w.rows, t, r)
    reindex_insert!(w.sel, t)
    _tc_auto!(w, t, t)                  # the new row alone
    refresh_rows!(w)
    return nothing
end

"""
Delete row `i`. False when out of range. REINDEXES via
`reindex_delete!`. An AUTO column stays TOO WIDE until `refresh_extent!`
-- `TextArea.widest` makes exactly this trade (textarea.jl:176).
"""
function delete_row!(w::Table, i::Int)::Bool
    (1 <= i <= length(w.rows)) || return false
    _tc_sync!(w)                        # `sel.n` is the PRE-delete count
    deleteat!(w.rows, i)
    reindex_delete!(w.sel, i)
    refresh_rows!(w)
    return true
end

"""
THE single exit of every data change; also the public escape hatch for a
direct mutation of `rows`. Bumps `version` (which invalidates the
resolve memo), re-syncs the selection, re-clamps the scroll, follows the
cursor.
"""
function refresh_rows!(w::Table)::Nothing
    _tc_touch!(w)                       # bumps `version`: the memo key
    _tc_sync!(w)
    scroll_to!(w, scroll_of(w))         # re-clamp: the extent may have
    _tc_follow_cursor!(w)               #   shrunk under the offset
    return nothing
end

"""
Replace the columns. Resizes `widths`/`xs`/`autos`, re-seeds the AUTO
marks and invalidates the memo.
"""
function set_columns!(w::Table, cols::Vector{Column})::Nothing
    g = w.grid
    empty!(g.cols)
    append!(g.cols, cols)
    n = length(g.cols)
    # The three scratch vectors are per-column and `const`, so they are
    # RESIZED in place rather than replaced: `TableGrid` is held by
    # composition and `grid_of(w)` must keep answering the same object.
    resize!(g.autos, n)
    resize!(g.widths, n)
    resize!(g.xs, n)
    fill!(g.autos, 0)
    fill!(g.widths, 0)
    fill!(g.xs, 0)
    refresh_columns!(w)
    return nothing
end

"""
Re-seed the AUTO marks and invalidate the memo after `grid_of(w).cols`
was written in place.

RE-MEASURES THE SAMPLE, exactly as construction does, and not the
headers alone. `_tc_auto_reset!` lowers every AUTO mark to its header
seed, so a reset that stopped there would collapse every AUTO column to
its own caption: changing one column's ALIGNMENT would silently resize
its NEIGHBOURS. A column model rewritten is a column model measured, and
the cost is the construction cost -- O(min(sample, n) x AUTO columns),
bounded, on an explicit call and never on a frame.
"""
function refresh_columns!(w::Table)::Nothing
    _tb_reseed!(w)                      # invalidates the memo
    _tc_touch!(w)
    return nothing
end
