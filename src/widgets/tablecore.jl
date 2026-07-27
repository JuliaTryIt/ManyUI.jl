# widgets/tablecore.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode.
#
# This file defines `RowsWidget`, `Selection`, `Column` and `TableGrid`,
# which `list.jl`, `table.jl` and `datatable.jl` USE and MUST NOT
# redefine.
#
# A ROW IS NOT A WIDGET. `TextArea`'s argument (textarea.jl:6), one type
# up: `node(w).scroll` shifts a node's CHILDREN, and these widgets'
# content is a `Vector` of DATA, not children -- so 100 000 rows are
# 100 000 elements of a `Vector` and ZERO `WidgetNode`s. Widget-per-row
# would mean a full layout pass per edit, 100 000 `render!` dispatches
# per frame, and -- the part that is easy to miss -- 100 000 hit-test
# nodes, so `hit_test` would be O(n) on every POINTER MOVE.
#
# What it reuses, exactly, and it is `textarea.jl`'s list verbatim:
#   * the same field: `node(w).scroll`, via `set_scroll!`/`scroll_to!`;
#   * the same clamps: `clamp_scroll`, `scroll_into_view` (widget.jl);
#   * the same seam: each widget OVERRIDES `content_extent`, so a
#     `Scrollbar{List{T,F,A}}` reports on it with NO new code in
#     `scroll.jl`. That override is exactly why `Scrollbar` is
#     parametric on its viewport.
#
# `Scrollpane(List(...))` remains legal and scrolls the List's whole box
# -- the two mechanisms compose instead of competing.
#
# `Base.textwidth` appears NOWHERE: it reports 1 for a VS16 emoji
# occupying 2 cells and 6 for a ZWJ family occupying 2. No byte indexes
# user text.

# --- enums ------------------------------------------------------------

"""
How many rows may be selected at once.

Orthogonal to the CURSOR, which exists under every mode: `NONE` is a
browsable list with no selection at all, which is a real widget (a log
viewer) and not a degenerate one.
"""
module SelectMode
@enum T::UInt8 begin
    NONE = 0     # cursor only; `rows` stays empty
    SINGLE = 1   # at most one row; a new pick REPLACES
    MULTI = 2    # anchor + extend, toggle
end
end

"""
The direction a `DataTable` is sorted in. `NONE` restores SOURCE order
and is reachable on purpose: it un-sorts without reloading the data.
"""
module SortDir
@enum T::UInt8 begin
    NONE = 0
    ASCENDING = 1
    DESCENDING = 2
end
end

# --- constants --------------------------------------------------------

"""
Rows an AUTO column measures at a data change. 200: 200 formatter calls
cost about what ONE frame of a 40-row table costs, so it is invisible;
and a column's width is decided by its TYPICAL value, which 200 samples
estimate as well as 100 000 do.
"""
const TC_AUTO_SAMPLE = 200

"""
The measurement cap an AUTO column uses BEFORE the first layout, when
there is no content box to cap against yet.

`_tc_measure`'s cap is normally the content-box width, but an AUTO
column is seeded at CONSTRUCTION, and at construction `layout_of(w)` is
still empty -- so the rule "cap at the viewport" has no viewport to name
and a cap of `0` would measure every column at nothing. This is that
fallback and nothing else: it keeps the seed O(cap) per cell rather than
O(length), and `refresh_extent!(w)` re-measures against the real box for
anyone who needs the exact answer. Internal.
"""
const TC_MEASURE_CAP = 512

"Cells one vertical wheel notch scrolls a row widget. `Scrollpane`'s."
const TC_WHEEL_STEP = 3

"Cells one horizontal wheel notch scrolls a row widget."
const TC_WHEEL_STEP_X = 6

"Truncation marker. Width-1 BY CONSTRUCTION, asserted in the suite."
const TC_ELLIPSIS = "…"

"Default header rule glyph. Width-1 BY CONSTRUCTION, asserted."
const TC_RULE = "─"

"Ascending indicator. Width-1 BY CONSTRUCTION, asserted."
const TC_SORT_ASC = "▲"

"Descending indicator. Width-1 BY CONSTRUCTION, asserted."
const TC_SORT_DESC = "▼"

"A selected row. MERGED onto the cells under it."
const TC_SELECTED = Style(; reverse = true)

"""
The cursor row, drawn only while FOCUSED. Merged, so it composes with
`TC_SELECTED` on a row that is both.
"""
const TC_CURSOR = Style(; underline = true)

"The header rows."
const TC_HEADER = Style(; bold = true)

"The modifier set that EXTENDS. See `_tc_key!`'s modifier policy."
const TC_SHIFT = Modifiers(Modifier.SHIFT)

# --- formatting helpers -----------------------------------------------

"""
`x` as an `AbstractString`, without copying one that already is:
`string(s::String) === s`, so a `List{String}` formats for ZERO
allocation per row. Internal.
"""
_tc_show(s::AbstractString)::AbstractString = s

# Documented above, with the `AbstractString` form: both methods share
# one doc signature, and documenting each would replace the other.
_tc_show(x)::AbstractString = string(x)

"The default `on_activate`: do nothing. Internal."
_tc_noop(::Widget)::Nothing = nothing

"""
`text_width(truncate_width(s, cap))` -- the width of `s`, CAPPED at
`cap` cells. O(cap), NEVER O(length(s)).

THE bound on every AUTO measurement, and it is not a micro-optimisation:
`truncate_width` (unicode.jl:138) breaks out of its grapheme loop the
moment the budget is exceeded, so this is thousands of times cheaper
than `text_width` on a 100 000-character cell. A 10 KB description
column would otherwise cost 10 KB of grapheme iteration per measured
cell to discover a fact `truncate_width` already knows. Pure. Internal.
"""
_tc_measure(s::AbstractString, cap::Int)::Int =
    text_width(truncate_width(s, cap))

"""
True when `truncate_width` actually cut something.

`ncodeunits`, NOT `text_width(s) > cw`: the obvious spelling walks the
WHOLE untruncated string. `_uw_string_backed` (unicode.jl:123) returns a
`String`/`SubString{String}` input UNCOPIED, so `t` shares `s`'s
codeunits and the comparison is exact. Pure. Internal.
"""
_tc_truncated(t::SubString{String}, s::AbstractString)::Bool =
    ncodeunits(t) < ncodeunits(s)

# --- the type lattice -------------------------------------------------

"""
A widget whose content is a sequence of DATA ROWS rather than children.

THE SEAM, and it is functions, not fields -- `scroll.jl`'s own move
("the scrollable seam is three functions, not a type"), one layer up.
Every subtype MUST define, each a one-liner:

    selection_of(w)::Selection
    row_count(w)::Int             # SOURCE rows. O(1). FRAME PATH.
    view_count(w)::Int            # rows in view order. O(1).
    view_source(w, k::Int)::Int   # view index -> source index
    view_rank(w, s::Int)::Int     # source index -> view index
    _tc_touch!(w)::Nothing        # bump the PAINT cell
    _tc_header_rows(w)::Int       # pinned chrome rows at the top
    _tc_extent_width(w)::Int      # the extent's WIDTH, read not computed

and MUST carry these DIRECT fields:

    node::WidgetNode
    version::Reactive{Int}        # Dirty.PAINT -- see below
    focused::Reactive{Bool}

`version`/`focused` MUST be direct fields of the widget and MUST NOT be
moved into a held struct: `attach_reactives!` walks
`fieldnames(typeof(w))` ONE level and binds only direct `Reactive`
fields (reactive.jl:100). A `Reactive` one level down silently never
gets an owner and never marks anything dirty. THAT FAILURE HAS NO ERROR
MESSAGE.

This is NOT a scrollable supertype and must not become one. The
scrollable seam stays the three functions `scroll.jl:57-66` names --
`content_extent`, `layout_of(w).content`, `scroll_of(w)` -- which is why
`Scrollbar{List{T,F,A}}` needs ZERO new code in `scroll.jl`.
`RowsWidget` is a different axis: it is the seam for SELECTION and
NAVIGATION, which are identical across the three rather than merely
similar.

The seam methods take `::RowsWidget` and have NO default, so a subtype
that forgets one gets a MethodError -- and a `Button` never answers them
at all.
"""
abstract type RowsWidget <: Widget end

# --- Selection --------------------------------------------------------

"""
A row cursor and a set of selected rows, over `n` SOURCE rows.

NORMATIVE: every index here is a SOURCE index -- an index into the
user's `rows`/`items` -- and NEVER a view index. That is what makes a
sort harmless: `sort_by!` permutes the VIEW and this does not move. The
alternative -- view indices -- silently reassigns the selection to
DIFFERENT ROWS the moment the user clicks a header, which is data
corruption with a pretty animation.

PURE: no widget, no layout, no buffer -- four `Int`s and a `BitSet`, so
the whole selection model is one table test. `thumb_span`
(scroll.jl:572) set that bar and this meets it.

`n` IS A FIELD, and that is deliberate: a `Selection` that does not know
how many rows there are makes every mutator take a caller-supplied `n`
you can get wrong -- `set_cursor!(s, 5, 999)` on a 3-row list parks the
cursor out of range, silently. `resize_selection!` is the ONE way `n`
changes.

`cursor`/`anchor` are `0` when there is no row, never `nothing`: `0`
keeps the fields concrete `Int` and every operation total at `n == 0`.

`rows` is a `BitSet` and not a `Set{Int}` or a `Vector{Bool}`. MEASURED,
not assumed: `in` allocates ZERO for BOTH `BitSet` and `Set{Int}`, so
the usual allocation argument for BitSet is WRONG and is not made here.
BitSet wins on the two axes that survive: an empty selection over
100 000 rows costs ~0 (a `Vector{Bool}`/`BitVector` costs 12.5 kB), and
a contiguous `anchor:target` extend is a bitmap range rather than
100 000 hash inserts. All of Base; no dependency.
"""
mutable struct Selection
    """
    Selection policy. `const`: a widget that needs another mode is a
    different widget -- build a new one.
    """
    const mode::SelectMode.T
    "Rows this selection is sized for. `resize_selection!` maintains it."
    n::Int
    "The cursor's SOURCE row, 1-based. `0` IFF `n == 0`."
    cursor::Int
    "The fixed end of a shift-extend, a SOURCE row. `0` IFF `n == 0`."
    anchor::Int
    "The selected SOURCE rows. Unordered -- see `selected_rows`."
    const rows::BitSet
end

"""
A selection of `mode` over `n` rows, cursor and anchor on row 1 (or `0`
when `n == 0`). NOTHING is selected initially, in every mode --
including `SINGLE`: a list that selects row 1 before the user has
touched it has made a choice on their behalf.
"""
function Selection(mode::SelectMode.T = SelectMode.SINGLE,
                   n::Int = 0)::Selection
    m = max(0, n)
    c = m == 0 ? 0 : 1
    return Selection(mode, m, c, c, BitSet())
end

# --- readers. PURE. ---------------------------------------------------

"The selection policy of `s`. Pure."
select_mode(s::Selection)::SelectMode.T = s.mode

"The number of SOURCE rows `s` is sized for. Pure."
n_rows(s::Selection)::Int = s.n

"The cursor's SOURCE row; `0` iff there is no row. Pure."
row_cursor(s::Selection)::Int = s.cursor

"The anchor's SOURCE row; `0` iff there is no row. Pure."
row_anchor(s::Selection)::Int = s.anchor

"""
True when SOURCE row `i` is selected.

O(1), ZERO allocation (MEASURED). FRAME PATH: one call per VISIBLE row.
Total for any `i`, including `i <= 0` and `i > n`. Pure.
"""
is_selected(s::Selection, i::Int)::Bool = i in s.rows

"""
How many rows are selected. O(1) in NONE/SINGLE; O(n/64) in MULTI. NEVER
the frame path. Pure.
"""
n_selected(s::Selection)::Int = length(s.rows)

"""
The selected SOURCE rows, ASCENDING. ALLOCATES. NEVER the frame path;
this is what an application calls after ENTER. Pure.
"""
selected_rows(s::Selection)::Vector{Int} = collect(s.rows)

# --- mutators. Each returns true IFF something changed. ---------------

"""
Select `i` and nothing else, without touching the cursor or the anchor.
True iff the set changed. Internal.
"""
function _tc_only!(s::Selection, i::Int)::Bool
    length(s.rows) == 1 && first(s.rows) == i && return false
    empty!(s.rows)
    push!(s.rows, i)
    return true
end

"""
Resize to `n` SOURCE rows: drop selected rows above `n`, clamp the
cursor and anchor into `1:n` (`0` when `n == 0`). O(1) -- ONE Int
compare -- when `n` is unchanged, which is what lets `render!` call it
every frame as a self-healing guard. See `_tc_sync!`.
"""
function resize_selection!(s::Selection, n::Int)::Bool
    m = max(0, n)
    m === s.n && return false           # THE O(1) guard
    s.n = m
    while !isempty(s.rows)
        hi = last(s.rows)               # a BitSet's maximum, O(1)-ish
        hi > m || break
        delete!(s.rows, hi)
    end
    if m == 0
        s.cursor = 0
        s.anchor = 0
    else
        s.cursor = s.cursor == 0 ? 1 : clamp(s.cursor, 1, m)
        s.anchor = s.anchor == 0 ? 1 : clamp(s.anchor, 1, m)
    end
    return true
end

"""
Move the cursor to SOURCE row `i`, CLAMPED to `1:n`; `0` when `n == 0`.
`0` is Home and `typemax(Int)` is End -- "go as far as you can" needs no
knowledge of how far that is, which is `_sp_key_delta`'s trick
(scroll.jl:475) reused rather than reinvented.

`extend = false` re-pins the anchor to `i` and, under SINGLE/MULTI,
selects `i` ALONE. `extend = true` leaves the anchor and REPLACES the
selection with `anchor:i` (MULTI), or moves the cursor alone
(SINGLE/NONE -- there is no range to extend to).

NORMATIVE: `anchor:i` is a SOURCE range, which is the only thing a
`Selection` can mean -- it has no view. A widget whose view is a
PERMUTATION must extend over VIEW rows instead, and
`set_cursor!(::RowsWidget, k; extend = true)` is where that happens.
"""
function set_cursor!(s::Selection, i::Int; extend::Bool = false)::Bool
    s.n == 0 && return false
    t = clamp(i, 1, s.n)
    if extend
        s.cursor === t && return false
        s.cursor = t
        s.mode === SelectMode.MULTI || return true
        lo, hi = minmax(s.anchor, t)
        _tc_replace_range!(s, lo, hi)
        return true
    end
    changed = s.cursor !== t || s.anchor !== t
    s.cursor = t
    s.anchor = t
    s.mode === SelectMode.NONE && return changed
    return _tc_only!(s, t) || changed
end

"""
Replace the selection with the contiguous SOURCE range `lo:hi`, clipped
to `1:n`. A bitmap range, not `hi - lo + 1` inserts. Internal.
"""
function _tc_replace_range!(s::Selection, lo::Int, hi::Int)::Nothing
    empty!(s.rows)
    a = max(1, lo)
    b = min(s.n, hi)
    a <= b && union!(s.rows, a:b)
    return nothing
end

"Select `i` and NOTHING else; re-pin the cursor and the anchor to it. A
 no-op under NONE."
function select_only!(s::Selection, i::Int)::Bool
    s.mode === SelectMode.NONE && return false
    s.n == 0 && return false
    t = clamp(i, 1, s.n)
    changed = s.cursor !== t || s.anchor !== t
    s.cursor = t
    s.anchor = t
    return _tc_only!(s, t) || changed
end

"""
Flip `i`'s membership; re-pin the cursor and anchor to it. MULTI only:
under SINGLE this is a no-op returning false, because toggling the one
selected row off would leave a single-select list with nothing selected,
which is a contradiction. A no-op under NONE.

`i` is NOT clamped: clamping a toggle would flip the WRONG row.
"""
function toggle_row!(s::Selection, i::Int)::Bool
    s.mode === SelectMode.MULTI || return false
    (1 <= i <= s.n) || return false
    i in s.rows ? delete!(s.rows, i) : push!(s.rows, i)
    s.cursor = i
    s.anchor = i
    return true
end

"""
Select exactly the SOURCE rows in `ids`, replacing the selection.
MULTI only; SINGLE falls back to `select_only!(s, last(ids))`.

`ids` is ANY iterable of `Int`, and that is the whole reason
`tablecore` never learns what a permutation is:

    sel_extend_ids!(s, min(a, b):max(a, b))            # List/Table
    sel_extend_ids!(s, (w.order[k] for k in lo:hi))    # DataTable

Both ARGUMENTS allocate ZERO and `Selection` is none the wiser. Ids
outside `1:n` are DROPPED, never stored.

NORMATIVE: an extend REPLACES, it does not union. Shift+click after a
run of ctrl+clicks replaces the selection with the anchor range -- what
every file manager does. `toggle_row!` is the documented escape.
"""
function sel_extend_ids!(s::Selection, ids)::Bool
    s.mode === SelectMode.NONE && return false
    s.n == 0 && return false
    if s.mode === SelectMode.SINGLE
        i = 0
        for k in ids
            i = k
        end
        i == 0 && return false
        return select_only!(s, i)
    end
    want = BitSet()
    for k in ids
        (1 <= k <= s.n) && push!(want, k)
    end
    want == s.rows && return false
    empty!(s.rows)
    union!(s.rows, want)
    return true
end

"Deselect everything; the CURSOR STAYS."
function clear_selection!(s::Selection)::Bool
    isempty(s.rows) && return false
    empty!(s.rows)
    return true
end

"Select `1:n`. MULTI only. O(n/64). A user gesture, NEVER a frame."
function select_all!(s::Selection)::Bool
    s.mode === SelectMode.MULTI || return false
    s.n == 0 && return false
    length(s.rows) == s.n && return false
    union!(s.rows, 1:s.n)
    return true
end

"""
Shift the selection, cursor and anchor for a row INSERTED at SOURCE
index `i`: everything at or above `i` moves up one, and `n` grows.

An index-keyed selection is only correct while the indices mean what
they meant. Source indices are structurally safe against REORDERING;
they are NOT safe against insertion, and this is the price, paid by the
mutation rather than by the frame. O(n_selected).
"""
function reindex_insert!(s::Selection, i::Int)::Bool
    t = clamp(i, 1, s.n + 1)
    held = collect(s.rows)              # ascending; O(n_selected)
    for k in length(held):-1:1          # DESCENDING: no collisions
        r = held[k]
        r >= t || break
        delete!(s.rows, r)
        push!(s.rows, r + 1)
    end
    s.n += 1
    if s.cursor == 0
        s.cursor = 1
        s.anchor = 1
    else
        s.cursor >= t && (s.cursor += 1)
        s.anchor >= t && (s.anchor += 1)
    end
    return true
end

"""
As `reindex_insert!`, for a row DELETED at SOURCE index `i`. `i` itself
is dropped from the selection; everything above moves down one; `n`
shrinks. The cursor, if it was ON `i`, stays at `i` and is re-clamped,
so it lands on the row that took `i`'s place -- or on the new last row.
"""
function reindex_delete!(s::Selection, i::Int)::Bool
    (1 <= i <= s.n) || return false
    delete!(s.rows, i)
    held = collect(s.rows)              # ascending: no collisions
    for r in held
        r > i || continue
        delete!(s.rows, r)
        push!(s.rows, r - 1)
    end
    s.n -= 1
    if s.n == 0
        s.cursor = 0
        s.anchor = 0
    else
        s.cursor > i && (s.cursor -= 1)
        s.anchor > i && (s.anchor -= 1)
        s.cursor = clamp(s.cursor, 1, s.n)
        s.anchor = clamp(s.anchor, 1, s.n)
    end
    return true
end

# --- Column and TableGrid ---------------------------------------------

"""
One column of a `Table`: a caption, a width policy, an alignment.

IMMUTABLE: a column is a SPEC. Changing one is
`grid_of(t).cols[j] = Column(...)` followed by `refresh_columns!(t)`.

`width` is a `Length` -- `cells(12)`, `pct(25)`, `fr(1)`, `AUTO` --
because those are already the framework's four answers to "how wide",
already parsed by the CSS engine and already resolved by
`definite_size`/`_apportion`. Inventing a fifth vocabulary for columns
would be inventing flexbox next to flexbox.

`align` is `Align.T`, REUSED rather than reinvented: `cross_align`
(layout.jl:163) does the placement, START/CENTER/END are
left/centre/right, and `Align.STRETCH` degenerates to START FOR FREE
because `cross_align(n, STRETCH, w)` returns `(0, w)` and a text painter
reads only the offset. There is no `CellAlign` enum because there is
nothing for one to say that `Align` does not.

`min_width`/`max_width` are `Length`s, not `Int`s: a bound the box model
spells as a `Length` must not be downgraded here. AUTO means unbounded
-- `0` low, `typemax(Int)` high.

`sortable` is ignored by `Table`, which never sorts. It is one `Bool`
per COLUMN, not per row, and it buys `DataTable` two things: which
headers reserve an indicator cell, and which headers a click sorts.
"""
struct Column
    "Header caption. ONE row; a newline is undefined."
    header::String
    "Width policy. See `_tc_resolve!`."
    width::Length
    "How the cell text AND the header sit in the column."
    align::Align.T
    "Lower bound. AUTO is unbounded."
    min_width::Length
    """
    Upper bound. AUTO is unbounded. On an AUTO column this is ALSO the
    measurement cap -- see `_tc_measure`.
    """
    max_width::Length
    "`DataTable` only: may this column be sorted?"
    sortable::Bool
end

"""
A column captioned `header`.
"""
Column(header::AbstractString = "";
       width::Length = AUTO, align::Align.T = Align.START,
       min_width::Length = AUTO, max_width::Length = AUTO,
       sortable::Bool = true)::Column =
    Column(String(header), width, align, min_width, max_width, sortable)

"""
Everything a `Table` and a `DataTable` need about COLUMNS, held BY
COMPOSITION so the two widgets share one column model instead of
declaring it twice and drifting.

NOT a `Widget`: no node, no dirty, no `render!`. It holds NO `Reactive`
and MUST NOT ever hold one -- `attach_reactives!` would not see it
(reactive.jl:100).

It holds no rows and no selection: those stay on the widget, because
`Selection` is shared with `List` (which has no columns) and `rows` is
what `DataTable` sorts a permutation OVER.
"""
mutable struct TableGrid
    "The columns, left to right."
    const cols::Vector{Column}
    "Cells painted BETWEEN columns."
    const sep::String
    "`text_width(sep)`, cached: it is read once per column per frame."
    const sep_w::Int
    "False drops the header rows entirely."
    const show_header::Bool
    "True draws one rule row under the header."
    const rule::Bool
    "The rule glyph. Width-1 BY CONSTRUCTION, asserted in the suite."
    const rule_glyph::String
    "Rows an AUTO column measures at a data change. See `_tc_auto!`."
    const sample::Int
    "Per-column AUTO measurement, in cells; `0` for a non-AUTO column."
    const autos::Vector{Int}
    "Resolved cell width per column. SCRATCH, refilled on a miss."
    const widths::Vector{Int}
    "0-based content-box x of each column, PRE-scroll. SCRATCH."
    const xs::Vector{Int}
    "The `version` the memo was resolved at; `-1` is never."
    cache_version::Int
    "The content-box width it was resolved for; `-1` is never."
    cache_width::Int
    "`sum(widths) + sep_w * (ncols - 1)`. What `_tc_extent` reads."
    cache_total::Int
end

"""
A grid over `cols`. `cols` is ALIASED, never copied.

Throws `ArgumentError` when `rule` is true and `rule_glyph` is not
width-1, and when `sample < 0`. Throwing beats a quiet nothing:
`mount!(::Scrollpane, ...)` throws for the same class of reason.
"""
function TableGrid(cols::Vector{Column};
                   sep::AbstractString = " ",
                   show_header::Bool = true, rule::Bool = false,
                   rule_glyph::AbstractString = TC_RULE,
                   sample::Int = TC_AUTO_SAMPLE)::TableGrid
    rule && text_width(rule_glyph) != 1 && throw(ArgumentError(
        "TableGrid: rule_glyph $(repr(rule_glyph)) is not width-1"))
    sample < 0 && throw(ArgumentError(
        "TableGrid: sample must be non-negative, got $(sample)"))
    n = length(cols)
    return TableGrid(cols, String(sep), text_width(sep), show_header,
                     rule, String(rule_glyph), sample,
                     zeros(Int, n), zeros(Int, n), zeros(Int, n),
                     -1, -1, 0)
end

# --- the RowsWidget seam. NO defaults except the last three. ----------

"The `Selection` of `w`. No default. Pure."
function selection_of end

"The number of SOURCE rows of `w`. O(1). FRAME PATH. No default. Pure."
function row_count end

"The number of rows in VIEW order. O(1). No default. Pure."
function view_count end

"The SOURCE row behind VIEW row `k`. O(1). No default. Pure."
function view_source end

"The VIEW row of SOURCE row `s`. O(1). No default. Pure."
function view_rank end

"""
The `TableGrid` of `w`. `Table`/`DataTable` only; a `List` has no
columns and answers with a MethodError. No default. Pure.
"""
function grid_of end

"Bump `w`'s PAINT cell. No default. Internal."
function _tc_touch! end

"""
Rows of the content box that are pinned CHROME rather than data. `0` by
default -- a `List` has no header. Internal.
"""
_tc_header_rows(w::RowsWidget)::Int = 0

"""
The WIDTH `_tc_extent` reports, READ and never computed.

For a grid it is `grid_of(w).cache_total`, resolved against the CURRENT
content box -- which is what makes `max_scroll(t).x` correct BEFORE the
first paint. A `List` overrides with its `widest` high-water mark,
because it has no columns to resolve.

NOT in the architect's seam list, and it is the one addition this file
makes to it: `_tc_extent` is specified as "`grid_of(w).cache_total` for
a grid and the row-extent mark for a `List`", which is a per-widget
branch the contract names but never gives a name to. `grid_of` has no
`List` method, so the branch cannot be written any other way without a
type-unstable `Union{Nothing,TableGrid}` probe on the FRAME PATH.
Internal.
"""
function _tc_extent_width(w::RowsWidget)::Int
    _tc_resolve!(w, max(0, layout_of(w).content.width))
    return grid_of(w).cache_total
end

"True while `w` holds the focus. Pure."
is_focused(w::RowsWidget)::Bool = w.focused[]

# --- widget-level reader forwards. Defined ONCE on ::RowsWidget. ------

"The cursor's SOURCE row of `w`; `0` when there is no row. Pure."
row_cursor(w::RowsWidget)::Int = row_cursor(selection_of(w))

"The anchor's SOURCE row of `w`; `0` when there is no row. Pure."
row_anchor(w::RowsWidget)::Int = row_anchor(selection_of(w))

"The selection policy of `w`. Pure."
select_mode(w::RowsWidget)::SelectMode.T = select_mode(selection_of(w))

"True when SOURCE row `i` of `w` is selected. O(1), 0 bytes. Pure."
is_selected(w::RowsWidget, i::Int)::Bool =
    is_selected(selection_of(w), i)

"How many rows of `w` are selected. NEVER the frame path. Pure."
n_selected(w::RowsWidget)::Int = n_selected(selection_of(w))

"""
The selected SOURCE rows of `w`, ASCENDING. ALLOCATES; this is what an
application calls after ENTER, never what `render!` calls. Pure.
"""
selected_rows(w::RowsWidget)::Vector{Int} =
    selected_rows(selection_of(w))

# --- widget-level MUTATOR forwards. THE single exit. ------------------
#
# These exist because `select_only!(selection_of(w), 3)` silently does
# not repaint and does not follow the cursor: the obvious call must be
# the correct one.

"""
Pure op, then `_tc_touch!` and `_tc_follow_cursor!`. THE single exit of
every cursor/selection change, so neither can be forgotten at a call
site. `_ta_moved!` (textarea.jl:449) is the precedent, line for line.
Returns `changed`. Internal.
"""
function _tc_moved!(w::RowsWidget, changed::Bool)::Bool
    changed || return false
    _tc_touch!(w)
    _tc_follow_cursor!(w)
    return true
end

"The cursor's VIEW row; `0` when there is none. Internal."
function _tc_cursor_view(w::RowsWidget)::Int
    c = row_cursor(w)
    c == 0 && return 0
    n = view_count(w)
    n == 0 && return 0
    return clamp(view_rank(w, c), 1, n)
end

"""
Move the cursor to VIEW row `k`, clamped. `0` is Home, `typemax(Int)` is
End.

VIEW, not source: "go to the third row on screen" is what a cursor
means, and the selection stores SOURCE. `view_source` is the whole
translation. A no-op returning false when `view_count(w) == 0`.

`extend = true` REPLACES the selection with the VIEW range from the
anchor to `k`, mapped back through `view_source` -- and NOT with the
SOURCE range `set_cursor!(::Selection, i; extend = true)` would use. On
a `List` or a `Table` the two are identical, because `view_source` is
the identity. On a `DataTable` they are NOT: the user shift-arrowing
down the screen means the rows BETWEEN the two ON SCREEN, which is what
the generator below says and what a source range would get wrong.
"""
function set_cursor!(w::RowsWidget, k::Int; extend::Bool = false)::Bool
    s = selection_of(w)
    n = view_count(w)
    n == 0 && return false
    t = clamp(k, 1, n)
    src = view_source(w, t)
    extend || return _tc_moved!(w, set_cursor!(s, src; extend = false))
    changed = s.cursor !== src
    s.cursor = src
    if s.mode === SelectMode.MULTI && s.anchor != 0
        a = clamp(view_rank(w, s.anchor), 1, n)
        lo, hi = minmax(a, t)
        # ZERO allocation for the argument, on List, Table and DataTable
        # alike -- `Selection` never learns what a permutation is.
        sel_extend_ids!(s, (view_source(w, v) for v in lo:hi)) &&
            (changed = true)
    end
    return _tc_moved!(w, changed)
end

"""
Move the cursor by `d` VIEW rows, clamped. `move_cursor!(w,
typemax(Int) ÷ 2)` is End and cannot run off it -- `÷ 2` so that
`rank + d` cannot overflow, which is `_sp_key_delta`'s trick.
"""
function move_cursor!(w::RowsWidget, d::Int; extend::Bool = false)::Bool
    n = view_count(w)
    n == 0 && return false
    r = _tc_cursor_view(w)
    r == 0 && (r = 1)
    return set_cursor!(w, r + d; extend = extend)
end

"Flip VIEW row `k`'s membership. MULTI only. See `toggle_row!`."
function toggle_row!(w::RowsWidget, k::Int)::Bool
    (1 <= k <= view_count(w)) || return false
    return _tc_moved!(w, toggle_row!(selection_of(w),
                                    view_source(w, k)))
end

"Select VIEW row `k` and nothing else. A no-op under NONE."
function select_only!(w::RowsWidget, k::Int)::Bool
    n = view_count(w)
    n == 0 && return false
    t = clamp(k, 1, n)
    return _tc_moved!(w, select_only!(selection_of(w),
                                     view_source(w, t)))
end

"""
Select every row. MULTI only. `ctrl+a` is NOT bound to this: `bind!` it.
"""
select_all!(w::RowsWidget)::Bool =
    _tc_moved!(w, select_all!(selection_of(w)))

"Deselect everything; the CURSOR STAYS."
clear_selection!(w::RowsWidget)::Bool =
    _tc_moved!(w, clear_selection!(selection_of(w)))

# --- extent, sync, follow, page ---------------------------------------

"""
`resize_selection!(selection_of(w), row_count(w))`. Called at the TOP of
`render!`, `_tc_key!` and `_tc_mouse!`.

THE self-healing guard, and it is the cure for the one footgun this
whole family shares: `items`/`rows` are ALIASED and mutated behind
`version`'s back will not repaint. This makes a cursor past the end
STRUCTURALLY IMPOSSIBLE even then -- it downgrades the footgun from
CORRUPTION to STALENESS. O(1) -- one `Int` compare -- when the count is
unchanged, which is what makes it affordable every frame.

Mutating state inside `render!` is licensed by `Scrollpane.render!`
(scroll.jl:389-415), which does exactly this and defends it at length:
nothing here is a `Reactive`, so this marks NOTHING and cannot loop, and
it converges. Internal.
"""
function _tc_sync!(w::RowsWidget)::Nothing
    resize_selection!(selection_of(w), row_count(w))
    return nothing
end

"""
`Size(_tc_extent_width(w), view_count(w) + _tc_header_rows(w))`.

THE `+ header_rows` IS LOAD-BEARING AND IS NOT A ROUNDING ERROR. It is
FORCED, and here is the proof rather than the assertion:
`Scrollbar._sb_metrics` (scroll.jl:624-634) reads
`content_extent(w.viewport)` and `layout_of(w.viewport).content`
DIRECTLY and NEVER calls `max_scroll`. There is therefore NO seam that
can tell a bar the body is `hh` rows shorter than the box, and
OVERRIDING `max_scroll` WOULD NOT WORK. Counting the header restores

    max_scroll.y = extent.height - content.height = (n + hh) - H
    last body row visible  <=>  scroll.y + (H - hh) == n
                           <=>  scroll.y == n + hh - H

-- the SAME number. So `max_scroll`, `clamp_scroll`, `scroll_to!`,
`scroll_into_view` and `thumb_span` are all already right, and
`Scrollbar{Table{R,F,A}}` needs not one line in `scroll.jl`. Drop the
`+ hh` and THE LAST `hh` ROWS OF EVERY TABLE ARE UNREACHABLE.

THE PRICE, stated rather than discovered: `content_extent(t).height` is
a white lie -- `row_count(t)` is the honest accessor and it is public
and exported -- and the thumb over-reports the visible fraction by
`hh/(n + hh)`, ~5% on a 20-row table with a header, decaying to nothing
as the data grows. That is the cost of not inventing a second scrollable
seam for one row.

O(1). ON THE FRAME PATH, several times -- see `_tc_resolve!`. Internal.
"""
_tc_extent(w::RowsWidget)::Size =
    Size(_tc_extent_width(w), view_count(w) + _tc_header_rows(w))

"Rows of the SCROLLING body: the content box less the header. Internal."
_tc_body_height(w::RowsWidget)::Int =
    max(0, layout_of(w).content.height - _tc_header_rows(w))

"""
Rows one PAGE_UP/PAGE_DOWN travels: one body LESS ONE ROW of overlap, so
the reader keeps a landmark. At least one, so an unlaid-out widget still
moves. `_ta_page` and `_sp_key_delta` both say this; this is the third
and last copy. Internal.
"""
_tc_page(w::RowsWidget)::Int = max(1, _tc_body_height(w) - 1)

"""
Scroll the MINIMUM needed to bring the cursor's VIEW row into the BODY
window, via `scroll_into_view`. A no-op before the first layout and with
no cursor.

`set_scroll!` and NOT `scroll_to!`, mirroring `_ta_follow_caret!`
(textarea.jl:483): `scroll_into_view(off, H - hh, r-1, r-1)` already
returns a value in `0 : n + hh - H`, which IS `max_scroll(w).y` by the
identity in `_tc_extent`, so the clamp is provably redundant and would
cost a `content_extent` call on every keystroke.

VERTICAL ONLY. THE CURSOR IS A ROW, NOT A CELL: there is no column
cursor, so there is nothing to follow horizontally. Horizontal scrolling
is the wheel's and the bar's job.

The two halves of the header arithmetic MUST agree: `_tc_extent` says
`n + hh`, this says the window is `H - hh`. The suite asserts the
identity. Internal.
"""
function _tc_follow_cursor!(w::RowsWidget)::Nothing
    r = _tc_cursor_view(w)
    r == 0 && return nothing
    c = layout_of(w).content
    (c.width <= 0 || c.height <= 0) && return nothing
    h = c.height - _tc_header_rows(w)
    h <= 0 && return nothing
    off = scroll_of(w)
    y = scroll_into_view(off.y, h, r - 1, r - 1)
    set_scroll!(w, Offset(off.x, y))
    return nothing
end

# --- the mouse. `local_offset` is FORBIDDEN in this tier. -------------

"""
The pointer's position in `w`'s CONTENT-box frame, 1-based, honouring
every scrolled ancestor. `(1, 1)` is the first cell `render!` can write.

`local_offset(d)` IS FORBIDDEN IN THIS TIER AND THIS IS WHY. It is
measured from `region(d.current)`, the UNSHIFTED border box
(events.jl:450). `Scrollbar` may use it only because "a scrollbar is
never inside a scrolled subtree" (scroll.jl:683) -- and a `List` inside
a `Scrollpane` IS inside one. Inside a pane scrolled to `y = 3` every
click would select the row three above the pointer. `painted_region`'s
own docstring settles it: "THIS, not `region(w)`, is what a hit test
must compare a pointer against" (widget.jl:262).

O(depth), on a mouse event, NEVER on a frame. Pure. Internal.
"""
function _tc_local(w::Widget, e::MouseEvent)::Offset
    c = translate(layout_of(w).content, paint_offset(w))
    return Offset(e.x - c.x + 1, e.y - c.y + 1)
end

"""
The 1-based VIEW row under mouse event `e`; `0` for the header, the
chrome, the margins or past the last row.

Arithmetic, not a hit test: `scroll.y + local.y - hh`. There are no row
widgets to hit-test, which is "a row is not a widget" seen from the
mouse's side -- `hit_test` walks nodes, so widget-per-row would be O(n)
on every POINTER MOVE, not merely every frame. Internal.
"""
function _tc_row_at(w::RowsWidget, e::MouseEvent)::Int
    c = layout_of(w).content
    (c.width <= 0 || c.height <= 0) && return 0
    o = _tc_local(w, e)
    (1 <= o.x <= c.width) || return 0
    hh = _tc_header_rows(w)
    (hh < o.y <= c.height) || return 0
    k = scroll_of(w).y + o.y - hh
    (1 <= k <= view_count(w)) || return 0
    return k
end

"""
The 1-based column index under mouse event `e`, from `grid_of(w).xs` and
`widths` -- LAST frame's, which is exactly the header the user SAW and
clicked. `0` for none, and `0` before the first paint. Internal.
"""
function _tc_col_at(w::RowsWidget, e::MouseEvent)::Int
    c = layout_of(w).content
    (c.width <= 0 || c.height <= 0) && return 0
    o = _tc_local(w, e)
    (1 <= o.x <= c.width) || return 0
    g = grid_of(w)
    x = scroll_of(w).x + o.x - 1        # 0-based content x
    for j in eachindex(g.cols)
        g.widths[j] > 0 || continue
        (g.xs[j] <= x < g.xs[j] + g.widths[j]) && return j
    end
    return 0
end

"""
True while `d` is live and at or past its target. CAPTURE belongs to
ancestors that want to intercept, and a list is never an interceptor.
`_ta_acts`/`_sp_acts`, third copy. Pure. Internal.
"""
_tc_acts(d::Dispatch)::Bool =
    d.phase !== Phase.CAPTURE && !is_consumed(d)

# --- the shared keyboard and mouse ------------------------------------

"""
Scroll `w` horizontally by `d` cells. True iff the offset moved.
Internal.
"""
function _tc_scroll_x!(w::RowsWidget, d::Int)::Bool
    before = scroll_of(w)
    return scroll_to!(w, Offset(before.x + d, before.y)) !== before
end

"""
UP/DOWN by one; PAGE_UP/PAGE_DOWN by one body LESS ONE ROW of overlap;
HOME/END to the ends; SPACE toggles (MULTI); ENTER calls
`on_activate(w)`; LEFT/RIGHT scroll HORIZONTALLY by one cell. SHIFT on
any movement key EXTENDS from the anchor. Returns true iff it consumed.

Each of the three widgets is exactly:

    on_event!(w::List, d::Dispatch{KeyEvent})::Nothing =
        (_tc_key!(w, d); nothing)

CONSUMES ONLY WHEN SOMETHING ACTUALLY MOVED. That is `_sp_move!`'s rule
(scroll.jl:435) applied to a cursor, and it is the whole of chaining: a
`List` on its LAST row lets DOWN bubble to an outer `Scrollpane`. ENTER
is the one exception and it is not one: firing `on_activate` IS the
something that happened.

MODIFIER POLICY, a DELIBERATE and BOUNDED departure from the "unmodified
keys only" rule `TextInput`/`TextArea`/`Scrollpane` follow: bare keys
act, and SHIFT ALONE additionally extends. The rule exists so `ctrl+a`
reaches an application binding (textinput.jl:477); the guard here leaves
ctrl+*, alt+* and super+* ENTIRELY to the app, and shift+arrow has
exactly one meaning in every list ever shipped and is not a plausible
accelerator.

CTRL+A IS NOT BOUND. `select_all!(w)` is public; `bind!` it.

TAB and ESCAPE FALL THROUGH UNCONSUMED, which is what keeps the tab
order alive.

THERE IS NO CELL CURSOR. LEFT/RIGHT scroll; they do not walk columns.
Internal.
"""
function _tc_key!(w::RowsWidget, d::Dispatch{KeyEvent})::Bool
    _tc_acts(d) || return false
    e = event(d)
    bare = isempty(e.mods)
    (bare || e.mods === TC_SHIFT) || return false
    ext = !bare
    _tc_sync!(w)
    c = e.code
    moved = false
    if c === Key.UP
        moved = move_cursor!(w, -1; extend = ext)
    elseif c === Key.DOWN
        moved = move_cursor!(w, 1; extend = ext)
    elseif c === Key.PAGE_UP
        moved = move_cursor!(w, -_tc_page(w); extend = ext)
    elseif c === Key.PAGE_DOWN
        moved = move_cursor!(w, _tc_page(w); extend = ext)
    elseif c === Key.HOME
        moved = set_cursor!(w, 0; extend = ext)
    elseif c === Key.END
        moved = set_cursor!(w, typemax(Int); extend = ext)
    elseif c === Key.LEFT
        bare || return false
        moved = _tc_scroll_x!(w, -1)
    elseif c === Key.RIGHT
        bare || return false
        moved = _tc_scroll_x!(w, 1)
    elseif c === Key.SPACE
        bare || return false
        moved = toggle_row!(w, _tc_cursor_view(w))
    elseif c === Key.ENTER
        bare || return false
        w.on_activate(w)
        consume!(d)
        return true
    else
        return false
    end
    moved || return false
    consume!(d)
    return true
end

"""
Scroll the body on a wheel notch; SHIFT swaps the axis. Consumes only
when the offset actually moved, so a list at its limit lets the notch
bubble to the next pane out -- scroll chaining, out of the phase rule
alone. Internal.
"""
function _tc_wheel!(w::RowsWidget, d::Dispatch{MouseEvent},
                    e::MouseEvent)::Bool
    b = e.button
    back = b === MouseButton.WHEEL_UP || b === MouseButton.WHEEL_LEFT
    vert = b === MouseButton.WHEEL_UP || b === MouseButton.WHEEL_DOWN
    (Modifier.SHIFT in e.mods) && (vert = !vert)
    step = (back ? -1 : 1) * (vert ? TC_WHEEL_STEP : TC_WHEEL_STEP_X)
    before = scroll_of(w)
    o = vert ? Offset(before.x, before.y + step) :
               Offset(before.x + step, before.y)
    scroll_to!(w, o) === before && return false
    consume!(d)
    return true
end

"""
Wheel scrolls the body, SHIFT swaps the axis; a LEFT PRESS puts the
cursor on the row under the pointer and selects it; SHIFT extends from
the anchor; CTRL toggles (MULTI); LEFT DRAG extends, so a press-drag
paints a range. Returns true iff it consumed. Consumes ONLY when
something changed.

A press on the HEADER rows returns false WITHOUT touching the selection,
so `DataTable` can act on it in its own `on_event!`. There is no
`on_header_click!` seam: per-concrete-type `on_event!` methods over this
shared internal have no shadowing problem to escape.

A plain press routes through `set_cursor!(w, k)` and NOT
`select_only!(w, k)`: the two are IDENTICAL under SINGLE and MULTI (both
re-pin the cursor and the anchor and select `k` alone), and they differ
only under NONE, where `select_only!` is a no-op and a click would then
not even move the cursor. A browsable list whose rows cannot be clicked
onto is not browsable.

`_tc_local`, NEVER `local_offset`. Internal.
"""
function _tc_mouse!(w::RowsWidget, d::Dispatch{MouseEvent})::Bool
    _tc_acts(d) || return false
    e = event(d)
    _tc_sync!(w)
    is_scroll(e) && return _tc_wheel!(w, d, e)
    e.button === MouseButton.LEFT || return false
    (e.action === MouseAction.PRESS ||
     e.action === MouseAction.DRAG) || return false
    k = _tc_row_at(w, e)
    k == 0 && return false
    drag = e.action === MouseAction.DRAG
    changed = if drag || Modifier.SHIFT in e.mods
        set_cursor!(w, k; extend = true)
    elseif Modifier.CTRL in e.mods
        toggle_row!(w, k)
    else
        set_cursor!(w, k; extend = false)
    end
    changed || return false
    consume!(d)
    return true
end

# --- painting ---------------------------------------------------------

"""
The style row `src` is painted in: `st`, REVERSED when selected, and
additionally UNDERLINE on the cursor row while focused.

Two independent bits, because they are two independent facts: in MULTI
the cursor is frequently NOT on a selected row, and a user who cannot
see which row ENTER will act on has no cursor at all. An unfocused list
shows its selection and hides its cursor -- exactly as `TextInput` hides
its caret on blur (textarea.jl:246). Internal.
"""
function _tc_row_style(w::RowsWidget, st::Style, src::Int,
                       foc::Bool)::Style
    s = selection_of(w)
    r = st
    is_selected(s, src) && (r = merge(r, TC_SELECTED))
    (foc && s.cursor === src) && (r = merge(r, TC_CURSOR))
    return r
end

"""
The style to MERGE across a highlighted row: `TC_SELECTED`, `TC_CURSOR`,
or both merged.

`style_region!` and NOT `fill_region!`: it MERGES onto the cells already
there, KEEPING `cur.content` and `cur.width` (buffer.jl:476), so a
highlight over a wide cluster restyles its HEAD and leaves its
continuation a continuation. `frame!` blanks the back buffer every frame
(app.jl:552), so a never-written padding cell is a blank and reversing a
blank IS the bar -- the full-width highlight costs one `style_region!`
per highlighted VISIBLE row and no fill pass at all. Internal.
"""
function _tc_bar_style(s::Selection, src::Int, foc::Bool)::Style
    sel = is_selected(s, src)
    cur = foc && s.cursor === src
    sel && cur && return merge(TC_SELECTED, TC_CURSOR)
    return sel ? TC_SELECTED : TC_CURSOR
end

"""
Write the clusters of `s` left to right starting at frame column `x`,
skipping any that land left of column 1 and stopping past `width`.
Returns the frame column one past the last cell the text would occupy.

A wide cluster landing at `cx < 1` is skipped WHOLE, never halved: it is
`TextArea.render!`'s rule (textarea.jl:239), and `set_cell!` already
refuses the mirror case at the right edge (buffer.jl:419).

ONE pass over the graphemes, no `grapheme_cells`: it allocates a
`Vector` per call and this is the frame path. Internal.
"""

"""
Paint `s` on row `y` of a `width`-cell frame, having first dropped `skip`
CONTENT CELLS off the LEFT. Returns THE CONTENT COLUMN REACHED:
`text_width(s)` when the row fit, and AT LEAST `skip + width` when it was
cut off.

That return value is what `List.render!` raises `widest` from, and it
makes the high-water mark cost the paint loop NOTHING -- no second pass
over the graphemes, no `text_width` on an unbounded string.

A wide cluster STRADDLING THE LEFT EDGE IS DROPPED, NEVER HALVED. This
is `TextArea.render!`'s loop (textarea.jl:239) and `TextInput`'s
`write_text!(buf, 1 - off, ...)` (textinput.jl:344); this is the third
and last copy. Internal.
"""

"""
Write `text` into the `cw`-cell column whose left edge is FRAME column
`x0`, aligned per `align`, truncated on a GRAPHEME boundary, clipped to
the frame.

`x0` MAY BE `<= 0`: a column scrolled off the left is a negative start,
exactly as `TextInput.render!` hands `write_text!` a negative `1 - off`.
There is no `skip` parameter; the negative `x0` IS the skip.

TRUNCATION, NORMATIVE:
  * `truncate_width(text, cw)` cuts at `cw` on a CLUSTER boundary and
    DROPS a width-2 cluster that would straddle it
    (`truncate_width("世界a", 3) == "世"`). A CLUSTER THEREFORE
    CANNOT STRADDLE A COLUMN EDGE BY CONSTRUCTION and there is no second
    guard to write. A width-2 cluster in an odd-width column leaves a
    one-cell gap, which is the correct rendering of "it does not fit".
  * When it cut (`_tc_truncated`), `TC_ELLIPSIS` is written in the
    column's LAST cell and the text is re-truncated to `cw - 1`.
  * A TRUNCATED CELL IS ALWAYS LEFT-ANCHORED, whatever `align` says.
    `align` applies ONLY when the text fits. A right-aligned truncated
    number ("…234") reads as a DIFFERENT NUMBER, which is worse
    than a visibly clipped one. It also means an `Align.END` cell can
    never paint its text OVER its own marker.
  * DEGENERATE BY CONSTRUCTION, not by special case: a 1-cell column
    holding "世" gets `truncate_width("世", 1) == ""` and then
    the ellipsis alone -- one cell, one legible glyph, nothing halved.

Placement is `first(cross_align(text_width(t), align, cw))` --
layout.jl:163, REUSED. There is no `_tc_lead`.

`Base.textwidth` appears NOWHERE. No byte indexes user text. Internal.
"""

# --- column width resolution ------------------------------------------

"""
The measurement cap for column `j` in an `avail`-cell content box:
`min(definite max_width, content-box width)`.

`TC_MEASURE_CAP` stands in for the content box before the first layout,
when `avail` is still `0` and there is no viewport for the rule to name.
Pure. Internal.
"""
function _tc_cap(col::Column, avail::Int)::Int
    base = avail > 0 ? avail : TC_MEASURE_CAP
    is_definite(col.max_width) || return base
    return min(base, max(0, definite_size(col.max_width, base)))
end

"""
`w` clamped into column `j`'s `min_width:max_width`, resolved against
`avail`. An AUTO bound is unbounded: `0` low, `typemax(Int)` high. Pure.
Internal.
"""
function _tc_bound(col::Column, wj::Int, avail::Int)::Int
    lo = is_definite(col.min_width) ?
         max(0, definite_size(col.min_width, avail)) : 0
    hi = is_definite(col.max_width) ?
         max(0, definite_size(col.max_width, avail)) : typemax(Int)
    return clamp(wj, lo, max(lo, hi))
end

"""
Cells reserved at the RIGHT of column `j`'s header when seeding its AUTO
mark. `0` by default. `DataTable` returns 1 for a `sortable` column, so
a column sized to its header alone still has a cell for the indicator.
Internal.
"""
_tc_header_reserve(w::RowsWidget, j::Int)::Int = 0

"""
Reset every AUTO mark to its SEED -- the header text plus
`_tc_header_reserve` -- and invalidate the resolve memo. THE ONLY thing
that can make a column NARROWER. Internal.
"""
function _tc_auto_reset!(w::RowsWidget)::Nothing
    g = grid_of(w)
    avail = max(0, layout_of(w).content.width)
    for j in eachindex(g.cols)
        col = g.cols[j]
        if col.width.kind !== Dimension.AUTO
            g.autos[j] = 0
            continue
        end
        g.autos[j] = _tc_measure(col.header, _tc_cap(col, avail)) +
                     _tc_header_reserve(w, j)
    end
    g.cache_version = -1
    return nothing
end

"""
Measure every AUTO column of `w` from SOURCE rows `first:last` and RAISE
its mark. True iff a mark rose. MONOTONE: nothing here lowers a mark.

Only AUTO columns pay: the loop `continue`s on any column whose `width`
is CELLS, PERCENT or FRACTION, so a table of fixed columns calls the
cell function ZERO times outside the paint loop.

Every measurement is CAPPED via `_tc_measure(s, cap)` with
`cap = min(definite max_width, content-box width)`. O(cap) per cell,
never O(length). Internal.
"""
function _tc_auto!(w::RowsWidget, first::Int, last::Int)::Bool
    g = grid_of(w)
    lo = max(1, first)
    hi = min(last, row_count(w))
    lo <= hi || return false
    avail = max(0, layout_of(w).content.width)
    raised = false
    for j in eachindex(g.cols)
        col = g.cols[j]
        col.width.kind === Dimension.AUTO || continue
        cap = _tc_cap(col, avail)
        m = g.autos[j]
        for src in lo:hi
            m = max(m, _tc_measure(_tc_cell_text(w, src, j), cap))
        end
        if m > g.autos[j]
            g.autos[j] = m
            raised = true
        end
    end
    raised && (g.cache_version = -1)
    return raised
end

"""
Resolve every column of `g` for an `avail`-cell content box, writing
`widths`, `xs` and `cache_total`. PURE with respect to the tree: a
`TableGrid` and an `Int` in, three scratch fields out, which is what
makes the whole of SS4 a table test.

    1. `cells(n)`  -> `definite_size`. Exact, O(1).
    2. `pct(p)`    -> `definite_size` against the CONTENT BOX.
    3. `AUTO`      -> the cached mark `g.autos[j]`.
    4. `fr(n)`     -> a share of `max(0, inner - sum(the above))` via
                      `_apportion`, the SAME largest-remainder-first
                      kernel `_arrange!` step 3 uses (layout.jl:417), so
                      `sum == leftover` EXACTLY and a column never
                      drifts a cell.

`inner = avail - sep_w * (ncols - 1)`: the separators are paid for
before the columns bid, which is `_arrange!`'s
`inner_main = main_avail - bs.gap * (n - 1)` (layout.jl:388) verbatim.

NORMATIVE: `cache_total` MAY EXCEED `avail`, and that excess IS the
horizontal scroll range. `flex_distribute` is NOT called: with no shrink
and no grow factor it is provably the identity (layout.jl:73), so
calling it to claim reuse would be ceremony. Internal.
"""
function _tc_resolve_now!(g::TableGrid, avail::Int)::Nothing
    n = length(g.cols)
    if n == 0
        g.cache_total = 0
        return nothing
    end
    fixed = 0
    frs = false
    for j in 1:n
        col = g.cols[j]
        k = col.width.kind
        if k === Dimension.FRACTION
            frs = true
            g.widths[j] = 0
            continue
        end
        wj = k === Dimension.AUTO ? g.autos[j] :
             definite_size(col.width, avail)
        g.widths[j] = _tc_bound(col, wj, avail)
        fixed += g.widths[j]
    end
    if frs
        inner = avail - g.sep_w * (n - 1)
        weights = Vector{Float32}(undef, n)
        for j in 1:n
            col = g.cols[j]
            weights[j] = col.width.kind === Dimension.FRACTION ?
                         max(0f0, col.width.value) : 0f0
        end
        share = _apportion(weights, max(0, inner - fixed))
        for j in 1:n
            col = g.cols[j]
            col.width.kind === Dimension.FRACTION || continue
            g.widths[j] = _tc_bound(col, share[j], avail)
        end
    end
    tot = 0
    x = 0
    for j in 1:n
        g.xs[j] = x
        x += g.widths[j] + g.sep_w
        tot += g.widths[j]
    end
    g.cache_total = tot + g.sep_w * (n - 1)
    return nothing
end

"""
Resolve every column of `w` to a cell width and an x offset for an
`avail`-cell content box, MEMOIZED on `(version, avail)`. Writes
`grid.widths`, `grid.xs`, `grid.cache_total` and returns `grid.widths`.

BOTH `render!` AND `_tc_extent` CALL THIS, and that is what makes
`max_scroll(t).x` correct BEFORE the first paint. Reading a `widths`
field that only `render!` writes would make `max_scroll(t).x == 0` --
"cannot scroll" when it can -- until the first frame.

NOT `Pure`, and this says so rather than hiding it: `content_extent` is
documented `Pure` in scroll.jl:83 and this override writes a memo. The
memo is OBSERVATIONALLY pure -- same inputs, same output -- and its key
is `(version, content-box width)`, NEITHER of which is a function of the
scroll offset. That is the same property `content_extent` itself relies
on ("the extent is independent of the current scroll offset and a scroll
can never feed back into the extent"), and it is why the cache is safe.
A future reader who trusts the base docstring will be surprised once;
that is the price of not lying about `max_scroll`.

`paint.jl` guarantees `render!` and `_tc_extent` agree on `avail`: a
widget "gets a frame that is its FULL content box, so `size(buf)` is the
widget's real content box and is INVARIANT UNDER SCROLL"
(buffer.jl:232), so `size(buf)[1] == layout_of(w).content.width` always
and the key never thrashes within a frame.

ON A HIT: O(1) to decide, ZERO allocation, and the scratch comes back.
ON A MISS: `_apportion` allocates -- once per edit or resize, never per
frame. Internal.
"""
function _tc_resolve!(w::RowsWidget, avail::Int)::Vector{Int}
    g = grid_of(w)
    v = w.version[]
    (g.cache_version === v && g.cache_width === avail) && return g.widths
    _tc_resolve_now!(g, avail)
    g.cache_version = v
    g.cache_width = avail
    return g.widths
end

"""
`lo:hi`, the columns the window `[off_x + 1, off_x + width]` touches. ONE
O(ncols) scan per frame, so the per-row loop runs only over visible
columns. `(1, 0)` when none. Pure. Internal.
"""
function _tc_visible_cols(g::TableGrid, off_x::Int,
                          width::Int)::Tuple{Int,Int}
    n = length(g.cols)
    n == 0 && return (1, 0)
    lo = 0
    hi = 0
    for j in 1:n
        # `xs` is increasing, so the first column whose RIGHT edge is
        # past the window's start is the first visible one, and the last
        # whose LEFT edge is before the window's end is the last.
        lo == 0 && g.xs[j] + g.widths[j] > off_x && (lo = j)
        g.xs[j] < off_x + width && (hi = j)
    end
    (lo == 0 || hi < lo) && return (1, 0)
    return (lo, hi)
end

# --- THE grid painter -------------------------------------------------

"""
The cell text of SOURCE row `src`, column `j`.

SOURCE, not view: the painter resolves `view_source` ONCE per row (it
needs it for the selection anyway), so this is IDENTICAL for `Table` and
`DataTable` and neither defines it. THAT is why there is no per-widget
`cell_text` and no second paint loop.

`w.cell` is a CONCRETE field of a parametric struct, so this is a STATIC
dispatch. Internal.
"""
_tc_cell_text(w::RowsWidget, src::Int, j::Int)::AbstractString =
    w.cell(w.rows[src], j)

"""
The header text of column `j`. `grid_of(w).cols[j].header` by default;
`DataTable` overrides to add its indicator. Internal.
"""
_tc_header_text(w::RowsWidget, j::Int)::AbstractString =
    grid_of(w).cols[j].header

"""
Draw the rule row across the FULL content width with ONE glyph,
continuously, with NO junction glyphs where separators cross it.

Deliberate: `border_glyphs` gives eight glyphs and no T or cross
(boxmodel.jl:141), so junctions mean a new glyph table for one cell per
column. The table's OUTER frame is `box(t).border` and costs ZERO code
-- `paint!` already draws it and the content box already shrinks for it.

Takes the glyph rather than reading `TC_RULE`: the grid OWNS
`rule_glyph`, and a painter that ignored it would make the field a lie.
Internal.
"""

"""
Draw the separators between visible columns, on row `y`. Internal.
"""

"""
Paint the pinned header, the optional rule, then
`rows[scroll.y+1 : scroll.y+H-hh]` IN VIEW ORDER. O(visible rows x
VISIBLE COLUMNS), never O(rows) and never O(ncols).

Generic over `W<:RowsWidget`, so this ONE loop paints both a `Table`
(where `view_source(w, k)` inlines to `k`) and a `DataTable` (where it
inlines to `w.order[k]`). `where {W<:RowsWidget}` and NOT
`::Union{Table,DataTable}`: neither type exists when this file is
included, and a Union would deoptimise the very indirection this
specialises away.

THE HEADER DOES NOT SCROLL VERTICALLY BUT DOES FOLLOW THE COLUMNS
HORIZONTALLY, and that is not a mechanism -- it is the ABSENCE of one:

    y = 1        header    -- x from `xs[j] - off.x`; never reads off.y
    y = 2        rule      -- neither offset
    y = hh+1..H  body rows -- x from `xs[j] - off.x`; y from off.y

One expression, two `y` rules. No sticky-row machinery, no second
buffer, no second node, no second `Scrollbar`. They cannot drift because
there is only one arithmetic.

`Base.view` per column is NOT used -- not because it is unavailable (it
IS: `Base.view(::ScrolledView, ::Region)` at buffer.jl:281) but because
raw arithmetic on the frame is `TextArea.render!`'s established
precedent and carving a view per column per row would allocate per cell.
Internal.
"""
