# tablecore_tests.jl -- the shared row-widget core (layer 7).
#
# Every testitem is self-contained, starts `using DualUI`, needs no tty
# and never sleeps.
#
# NOTHING here constructs a List, a Table or a DataTable, and that is
# the whole point of the tier split: `Selection` is four Ints and a
# BitSet, `_tc_resolve_now!` is a TableGrid and an Int, and `_tc_put!`
# is a Buffer -- so the entire shared core is a TABLE TEST, exactly as
# `thumb_span` (scroll.jl:572) is one.
#
# `Base.textwidth` appears nowhere. The grapheme discipline asserted
# here is the same one `TextInput` and `TextArea` obey: a wide cluster
# is ONE step and TWO cells, and it is never halved.

@testitem "tablecore: enums are module-scoped and typed" begin
    using DualUI
    @test SelectMode isa Module
    @test SelectMode.T <: Enum{UInt8}
    @test SelectMode.NONE isa SelectMode.T
    @test SelectMode.SINGLE isa SelectMode.T
    @test SelectMode.MULTI isa SelectMode.T
    @test UInt8(SelectMode.NONE) == 0
    @test UInt8(SelectMode.SINGLE) == 1
    @test UInt8(SelectMode.MULTI) == 2
    @test length(instances(SelectMode.T)) == 3

    @test SortDir isa Module
    @test SortDir.T <: Enum{UInt8}
    @test SortDir.NONE isa SortDir.T
    @test UInt8(SortDir.NONE) == 0
    @test UInt8(SortDir.ASCENDING) == 1
    @test UInt8(SortDir.DESCENDING) == 2
    @test length(instances(SortDir.T)) == 3

    # There is NO CellAlign enum, and that is normative: `Align` already
    # says everything a column needs, and `cross_align` places it.
    @test !isdefined(DualUI, :CellAlign)
    @test length(instances(Align.T)) == 4
end

@testitem "tablecore: glyph constants are all width-1" begin
    using DualUI
    # The `SB_TRACK_V`/`SB_THUMB` discipline (scroll.jl:600): "width-1
    # BY CONSTRUCTION, asserted in the suite" is only true if the suite
    # actually asserts it.
    for g in (TC_ELLIPSIS, TC_RULE, TC_SORT_ASC, TC_SORT_DESC)
        @test grapheme_width(g) == 1
        @test text_width(g) == 1
        @test length(collect(Base.Unicode.graphemes(g))) == 1
    end
    @test TC_AUTO_SAMPLE == 200
    @test TC_AUTO_SAMPLE > 0

    # Two INDEPENDENT bits, because they are two independent facts: in
    # MULTI the cursor is frequently not on a selected row.
    @test has(TC_SELECTED, Attr.REVERSE)
    @test has(TC_CURSOR, Attr.UNDERLINE)
    @test has(TC_HEADER, Attr.BOLD)
    @test !specified(TC_SELECTED, Attr.UNDERLINE)
    @test !specified(TC_CURSOR, Attr.REVERSE)
    # They MERGE, so a row that is both selected and current composes.
    both = merge(TC_SELECTED, TC_CURSOR)
    @test has(both, Attr.REVERSE)
    @test has(both, Attr.UNDERLINE)
end

@testitem "tablecore: selection is total on empty data" begin
    using DualUI
    # `n == 0` is a real state, not a degenerate one: no method throws
    # and no method returns `nothing` where an `Int` is declared.
    for m in (SelectMode.NONE, SelectMode.SINGLE, SelectMode.MULTI)
        s = Selection(m, 0)
        @test select_mode(s) === m
        @test n_rows(s) == 0
        @test row_cursor(s) == 0        # `0`, never `nothing`
        @test row_anchor(s) == 0
        @test n_selected(s) == 0
        @test selected_rows(s) == Int[]
        @test !is_selected(s, 0)
        @test !is_selected(s, 1)
        @test !is_selected(s, -7)

        # Every mutator is TOTAL and reports "nothing changed".
        @test !set_cursor!(s, 1)
        @test !set_cursor!(s, 0)
        @test !set_cursor!(s, typemax(Int))
        @test !set_cursor!(s, 3; extend = true)
        @test !select_only!(s, 1)
        @test !toggle_row!(s, 1)
        @test !sel_extend_ids!(s, 1:3)
        @test !clear_selection!(s)
        @test !select_all!(s)
        @test !reindex_delete!(s, 1)
        @test !resize_selection!(s, 0)

        @test row_cursor(s) == 0
        @test row_anchor(s) == 0
        @test n_selected(s) == 0
    end
end

@testitem "tablecore: selection on exactly one row" begin
    using DualUI
    s = Selection(SelectMode.SINGLE, 1)
    @test n_rows(s) == 1
    @test row_cursor(s) == 1
    @test row_anchor(s) == 1
    # NOTHING is selected initially, in EVERY mode -- including SINGLE:
    # a list that selects row 1 before the user has touched it has made
    # a choice on their behalf.
    @test n_selected(s) == 0
    @test !is_selected(s, 1)

    @test select_only!(s, 1)
    @test is_selected(s, 1)
    @test n_selected(s) == 1
    @test !select_only!(s, 1)
    # There is nowhere else to go, so nothing changes.
    @test !set_cursor!(s, 5)
    @test !set_cursor!(s, typemax(Int))
    @test !set_cursor!(s, 0)
    @test row_cursor(s) == 1

    m = Selection(SelectMode.MULTI, 1)
    @test toggle_row!(m, 1)
    @test is_selected(m, 1)
    @test toggle_row!(m, 1)
    @test !is_selected(m, 1)
    @test row_cursor(m) == 1
    @test select_all!(m)
    @test selected_rows(m) == [1]
    @test !select_all!(m)
end

@testitem "tablecore: every mutator returns true iff it changed" begin
    using DualUI
    # `set_scroll!`'s contract (widget.jl:204), one layer up. It buys
    # three things: the widget bumps PAINT only on a real change; the
    # handler consumes only when it moved; and the tests read like this.
    s = Selection(SelectMode.MULTI, 10)
    @test set_cursor!(s, 4)
    @test !set_cursor!(s, 4)
    @test toggle_row!(s, 4)
    @test toggle_row!(s, 4)
    @test select_only!(s, 7)
    @test !select_only!(s, 7)
    @test clear_selection!(s)
    @test !clear_selection!(s)
    @test select_all!(s)
    @test !select_all!(s)
    @test resize_selection!(s, 12)
    @test !resize_selection!(s, 12)
    @test sel_extend_ids!(s, 2:5)
    @test !sel_extend_ids!(s, 2:5)
    @test !sel_extend_ids!(s, 5:-1:2)      # the same SET, backwards
    @test reindex_insert!(s, 3)
    @test reindex_delete!(s, 3)
    @test !reindex_delete!(s, 999)
    @test !reindex_delete!(s, 0)
end

@testitem "tablecore: SINGLE selects at most one row" begin
    using DualUI
    s = Selection(SelectMode.SINGLE, 6)
    set_cursor!(s, 2)
    @test selected_rows(s) == [2]
    set_cursor!(s, 5)
    @test selected_rows(s) == [5]          # a new pick REPLACES
    @test n_selected(s) == 1
    select_only!(s, 1)
    @test selected_rows(s) == [1]

    # There is no range to extend to under SINGLE, so the cursor moves
    # ALONE and the selection stays put.
    @test set_cursor!(s, 4; extend = true)
    @test row_cursor(s) == 4
    @test row_anchor(s) == 1
    @test selected_rows(s) == [1]
    @test n_selected(s) == 1

    # SINGLE falls back to `select_only!(s, last(ids))`.
    @test sel_extend_ids!(s, 2:5)
    @test selected_rows(s) == [5]
    @test n_selected(s) == 1
    @test !select_all!(s)                  # MULTI only
    @test selected_rows(s) == [5]
end

@testitem "tablecore: SINGLE refuses to toggle its only row off" begin
    using DualUI
    # Toggling the one selected row off would leave a single-select list
    # with nothing selected, which is a contradiction.
    s = Selection(SelectMode.SINGLE, 4)
    select_only!(s, 2)
    @test !toggle_row!(s, 2)
    @test selected_rows(s) == [2]
    @test !toggle_row!(s, 3)
    @test selected_rows(s) == [2]
    @test row_cursor(s) == 2
    @test n_selected(s) == 1
end

@testitem "tablecore: NONE navigates and never selects" begin
    using DualUI
    # NONE is a browsable list with no selection at all, which is a real
    # widget (a log viewer) and not a degenerate one. The CURSOR is
    # orthogonal to the mode and exists under every one of them.
    s = Selection(SelectMode.NONE, 8)
    @test set_cursor!(s, 5)
    @test row_cursor(s) == 5
    @test row_anchor(s) == 5
    @test n_selected(s) == 0

    @test set_cursor!(s, 8; extend = true)
    @test row_cursor(s) == 8
    @test n_selected(s) == 0

    @test !select_only!(s, 3)
    @test !toggle_row!(s, 3)
    @test !select_all!(s)
    @test !sel_extend_ids!(s, 1:8)
    @test n_selected(s) == 0
    @test selected_rows(s) == Int[]
    @test !is_selected(s, 8)

    @test set_cursor!(s, 0)                # Home still navigates
    @test row_cursor(s) == 1
end

@testitem "tablecore: MULTI anchor+extend across both directions" begin
    using DualUI
    s = Selection(SelectMode.MULTI, 10)
    set_cursor!(s, 5)
    @test row_anchor(s) == 5
    @test selected_rows(s) == [5]

    set_cursor!(s, 8; extend = true)       # extend DOWN
    @test row_anchor(s) == 5               # the anchor does NOT move
    @test row_cursor(s) == 8
    @test selected_rows(s) == [5, 6, 7, 8]

    set_cursor!(s, 2; extend = true)       # extend UP, THROUGH it
    @test row_anchor(s) == 5
    @test row_cursor(s) == 2
    @test selected_rows(s) == [2, 3, 4, 5]

    set_cursor!(s, 5; extend = true)       # back onto the anchor
    @test selected_rows(s) == [5]

    set_cursor!(s, 3)                      # no extend: re-pins it
    @test row_anchor(s) == 3
    @test row_cursor(s) == 3
    @test selected_rows(s) == [3]

    # Clamped at both ends, and the range with it.
    set_cursor!(s, typemax(Int); extend = true)
    @test row_cursor(s) == 10
    @test selected_rows(s) == collect(3:10)
    set_cursor!(s, 0; extend = true)
    @test row_cursor(s) == 1
    @test selected_rows(s) == [1, 2, 3]
end

@testitem "tablecore: extend REPLACES rather than unions" begin
    using DualUI
    # NORMATIVE: shift+click after a run of ctrl+clicks REPLACES the
    # selection with the anchor range -- what every file manager does.
    # `toggle_row!` is the documented escape.
    s = Selection(SelectMode.MULTI, 10)
    toggle_row!(s, 1)
    toggle_row!(s, 9)
    @test selected_rows(s) == [1, 9]
    @test row_anchor(s) == 9               # a toggle re-pins the anchor

    set_cursor!(s, 7; extend = true)
    @test selected_rows(s) == [7, 8, 9]
    @test !is_selected(s, 1)               # NOT a union

    sel_extend_ids!(s, 2:3)
    @test selected_rows(s) == [2, 3]
    @test !is_selected(s, 7)
end

@testitem "tablecore: sel_extend_ids! over a UnitRange" begin
    using DualUI
    s = Selection(SelectMode.MULTI, 100_000)
    # A contiguous extend is a BITMAP RANGE, not 100 000 hash inserts.
    @test sel_extend_ids!(s, 1:100_000)
    @test n_selected(s) == 100_000
    @test is_selected(s, 1)
    @test is_selected(s, 100_000)

    @test sel_extend_ids!(s, 4:6)
    @test selected_rows(s) == [4, 5, 6]

    # Ids OUTSIDE 1:n are DROPPED, never stored: the invariant is that
    # `rows` only ever names rows that exist.
    @test sel_extend_ids!(s, -5:3)
    @test selected_rows(s) == [1, 2, 3]
    @test sel_extend_ids!(s, 99_999:100_005)
    @test selected_rows(s) == [99_999, 100_000]
    # An extend REPLACES -- even with nothing.
    @test sel_extend_ids!(s, 200_000:200_010)
    @test selected_rows(s) == Int[]
end

@testitem "tablecore: sel_extend_ids! over a generator, zero alloc" begin
    using DualUI
    # THE call `datatable.jl` makes. `ids` is ANY iterable of `Int`, and
    # that is the whole reason `tablecore` never learns what a
    # permutation is.
    order = collect(10:-1:1)
    s = Selection(SelectMode.MULTI, 10)
    @test sel_extend_ids!(s, (order[k] for k in 3:5))
    @test selected_rows(s) == [6, 7, 8]
    @test !sel_extend_ids!(s, (order[k] for k in 3:5))

    # The ARGUMENT is what costs nothing: a Generator over a UnitRange
    # and a UnitRange are both built without touching the heap, so
    # `Selection` is none the wiser and pays for neither.
    mkgen(o) = (o[k] for k in 3:5)
    mkrng() = 3:5
    mkgen(order)
    mkrng()
    @test @allocated(mkgen(order)) == 0
    @test @allocated(mkrng()) == 0

    # Both spellings mean the same thing to `Selection`.
    t = Selection(SelectMode.MULTI, 10)
    @test sel_extend_ids!(t, 6:8)
    @test selected_rows(t) == selected_rows(s)
end

@testitem "tablecore: set_cursor! 0 is Home and typemax is End" begin
    using DualUI
    # "Go as far as you can" needs no knowledge of how far that is --
    # `_sp_key_delta`'s trick (scroll.jl:475) reused, not reinvented.
    s = Selection(SelectMode.SINGLE, 20)
    @test set_cursor!(s, typemax(Int))
    @test row_cursor(s) == 20
    @test !set_cursor!(s, typemax(Int))
    @test set_cursor!(s, 0)
    @test row_cursor(s) == 1
    @test !set_cursor!(s, -999)
    @test row_cursor(s) == 1
    @test !set_cursor!(s, typemin(Int))
    @test row_cursor(s) == 1

    # Nothing overflows, and nothing is out of range afterwards.
    @test 1 <= row_cursor(s) <= n_rows(s)
    @test 1 <= row_anchor(s) <= n_rows(s)

    e = Selection(SelectMode.SINGLE, 0)
    @test !set_cursor!(e, 0)
    @test !set_cursor!(e, typemax(Int))
    @test row_cursor(e) == 0
end

@testitem "tablecore: resize_selection! shrinking under a cursor" begin
    using DualUI
    s = Selection(SelectMode.MULTI, 10)
    set_cursor!(s, 6)
    set_cursor!(s, 10; extend = true)
    @test selected_rows(s) == [6, 7, 8, 9, 10]
    @test row_cursor(s) == 10

    # The data shrinks under it. A cursor past the end is STRUCTURALLY
    # IMPOSSIBLE, which is what downgrades the aliasing footgun from
    # CORRUPTION to STALENESS.
    @test resize_selection!(s, 4)
    @test n_rows(s) == 4
    @test row_cursor(s) == 4
    @test row_anchor(s) == 4
    @test selected_rows(s) == Int[]        # every held row is gone
    @test !is_selected(s, 6)

    @test resize_selection!(s, 0)
    @test row_cursor(s) == 0
    @test row_anchor(s) == 0
    @test n_selected(s) == 0

    # Growing again puts the cursor back on a real row.
    @test resize_selection!(s, 3)
    @test row_cursor(s) == 1
    @test row_anchor(s) == 1

    # A partial shrink keeps the rows that survive.
    t = Selection(SelectMode.MULTI, 10)
    sel_extend_ids!(t, [2, 5, 9])
    @test resize_selection!(t, 5)
    @test selected_rows(t) == [2, 5]
end

@testitem "tablecore: resize_selection! is O(1) when n is unchanged" begin
    using DualUI
    # THE self-healing guard: `render!`, `_tc_key!` and `_tc_mouse!` all
    # call this every single time, so an unchanged count MUST cost one
    # Int compare and touch nothing. This is what makes it affordable
    # every frame -- and `Scrollpane.render!` (scroll.jl:389) is the
    # precedent for mutating state inside a paint.
    s = Selection(SelectMode.MULTI, 100_000)
    select_all!(s)
    @test !resize_selection!(s, 100_000)
    resize_selection!(s, 100_000)
    @test @allocated(resize_selection!(s, 100_000)) == 0
    @test n_selected(s) == 100_000
    @test row_cursor(s) == 1
end

@testitem "tablecore: reindex_insert! shifts the selection up" begin
    using DualUI
    # Source indices are structurally safe against REORDERING; they are
    # NOT safe against insertion, and this is the price -- paid by the
    # mutation rather than by the frame.
    s = Selection(SelectMode.MULTI, 5)
    set_cursor!(s, 4)
    sel_extend_ids!(s, [2, 4])
    @test selected_rows(s) == [2, 4]
    @test row_cursor(s) == 4

    @test reindex_insert!(s, 3)            # at or above 3 moves up one
    @test n_rows(s) == 6
    @test selected_rows(s) == [2, 5]
    @test row_cursor(s) == 5
    @test row_anchor(s) == 5

    @test reindex_insert!(s, 6)            # below everything held
    @test n_rows(s) == 7
    @test selected_rows(s) == [2, 5]
    @test row_cursor(s) == 5

    @test reindex_insert!(s, 1)            # above everything held
    @test n_rows(s) == 8
    @test selected_rows(s) == [3, 6]
    @test row_cursor(s) == 6

    # On an EMPTY selection it still lands the cursor on a real row.
    e = Selection(SelectMode.SINGLE, 0)
    @test reindex_insert!(e, 1)
    @test n_rows(e) == 1
    @test row_cursor(e) == 1
    @test row_anchor(e) == 1
    @test n_selected(e) == 0
end

@testitem "tablecore: reindex_delete! drops i and shifts down" begin
    using DualUI
    s = Selection(SelectMode.MULTI, 6)
    set_cursor!(s, 1)
    sel_extend_ids!(s, [2, 3, 5])
    @test reindex_delete!(s, 3)
    @test n_rows(s) == 5
    @test selected_rows(s) == [2, 4]       # 3 is GONE, 5 moved to 4
    @test is_selected(s, 2)
    @test !is_selected(s, 3)
    @test is_selected(s, 4)
    @test !is_selected(s, 5)

    @test !reindex_delete!(s, 0)
    @test !reindex_delete!(s, 6)
    @test n_rows(s) == 5

    @test reindex_delete!(s, 5)            # below the selection
    @test selected_rows(s) == [2, 4]
    @test n_rows(s) == 4
    @test row_cursor(s) == 1
end

@testitem "tablecore: reindex_delete! leaves the cursor in range" begin
    using DualUI
    # The cursor, if it was ON `i`, STAYS at `i` and is re-clamped, so
    # it lands on the row that took `i`'s place.
    s = Selection(SelectMode.SINGLE, 5)
    set_cursor!(s, 3)
    @test reindex_delete!(s, 3)
    @test n_rows(s) == 4
    @test row_cursor(s) == 3
    @test !is_selected(s, 3)               # the deleted row left

    # ... or on the NEW LAST row when there was no replacement.
    t = Selection(SelectMode.SINGLE, 5)
    set_cursor!(t, 5)
    @test reindex_delete!(t, 5)
    @test n_rows(t) == 4
    @test row_cursor(t) == 4

    # Down to the last row of all: still total, still `0`.
    u = Selection(SelectMode.MULTI, 1)
    select_only!(u, 1)
    @test reindex_delete!(u, 1)
    @test n_rows(u) == 0
    @test row_cursor(u) == 0
    @test row_anchor(u) == 0
    @test selected_rows(u) == Int[]

    # Whatever happens, the cursor is IN RANGE afterwards.
    for i in 1:6
        v = Selection(SelectMode.MULTI, 6)
        set_cursor!(v, 6)
        reindex_delete!(v, i)
        @test 1 <= row_cursor(v) <= n_rows(v)
        @test 1 <= row_anchor(v) <= n_rows(v)
    end
end

@testitem "tablecore: is_selected allocates zero" begin
    using DualUI
    # FRAME PATH: one call per VISIBLE row, so a byte here is a byte per
    # row per frame. MEASURED, not assumed -- and `Set{Int}` measures
    # zero too, so the usual allocation argument for BitSet is WRONG and
    # is not the reason BitSet was chosen.
    s = Selection(SelectMode.MULTI, 100_000)
    select_all!(s)
    is_selected(s, 1)
    @test @allocated(is_selected(s, 1)) == 0
    @test @allocated(is_selected(s, 100_000)) == 0
    @test @allocated(is_selected(s, 999_999)) == 0
    @test @allocated(is_selected(s, -1)) == 0
    @test @allocated(is_selected(s, 0)) == 0

    # An EMPTY selection over 100 000 rows costs ~0 -- THAT is why the
    # set is a BitSet and not a Vector{Bool}.
    e = Selection(SelectMode.MULTI, 100_000)
    @test @allocated(is_selected(e, 50_000)) == 0
    @test n_selected(e) == 0
end

@testitem "tablecore: is_selected is total outside 1:n" begin
    using DualUI
    s = Selection(SelectMode.MULTI, 4)
    select_all!(s)
    @test is_selected(s, 1)
    @test is_selected(s, 4)
    @test !is_selected(s, 0)
    @test !is_selected(s, 5)
    @test !is_selected(s, -1)
    @test !is_selected(s, typemax(Int))
    @test !is_selected(s, typemin(Int))

    e = Selection(SelectMode.NONE, 0)
    @test !is_selected(e, 0)
    @test !is_selected(e, 1)
    @test !is_selected(e, typemin(Int))
end

@testitem "tablecore: selected_rows is ascending" begin
    using DualUI
    # `rows` is UNORDERED; THIS is the ordered view of it, and it is
    # what an application calls after ENTER.
    s = Selection(SelectMode.MULTI, 50)
    sel_extend_ids!(s, [40, 3, 17, 1, 29])
    r = selected_rows(s)
    @test r == [1, 3, 17, 29, 40]
    @test issorted(r)
    @test r isa Vector{Int}
    @test length(r) == n_selected(s)
    @test selected_rows(Selection(SelectMode.MULTI, 4)) == Int[]
    # It ALLOCATES a fresh vector: mutating it must not reach inside.
    push!(r, 99)
    @test selected_rows(s) == [1, 3, 17, 29, 40]
end

@testitem "tablecore: Column defaults and Length bounds" begin
    using DualUI
    c = Column()
    @test c.header == ""
    @test c.width === AUTO
    @test c.align === Align.START
    @test c.min_width === AUTO             # AUTO means UNBOUNDED
    @test c.max_width === AUTO
    @test c.sortable

    d = Column("Name"; width = cells(12), align = Align.END,
               min_width = cells(4), max_width = pct(50),
               sortable = false)
    @test d.header == "Name"
    @test d.width === cells(12)
    @test d.align === Align.END
    @test d.min_width === cells(4)
    @test d.max_width === pct(50)
    @test !d.sortable

    # A column is a SPEC: IMMUTABLE. Changing one is
    # `grid_of(t).cols[j] = Column(...)` then `refresh_columns!(t)`.
    @test !ismutable(d)
    @test isbits(d.width)
    # `width` is a `Length` -- the framework's four answers to "how
    # wide", not a fifth vocabulary next to flexbox.
    @test Column(; width = fr(2)).width === fr(2)
    @test Column(; width = pct(25)).width === pct(25)
    @test Column(; align = Align.STRETCH).align === Align.STRETCH
    @test Column("h").header isa String
end

@testitem "tablecore: TableGrid throws on a wide rule glyph" begin
    using DualUI
    cols = [Column("A"), Column("B")]
    # Throwing beats a quiet nothing: `mount!(::Scrollpane, ...)` throws
    # for the same class of reason.
    @test_throws ArgumentError TableGrid(cols; rule = true,
                                         rule_glyph = "世")
    @test_throws ArgumentError TableGrid(cols; rule = true,
                                         rule_glyph = "ab")
    @test_throws ArgumentError TableGrid(cols; rule = true,
                                         rule_glyph = "")
    @test_throws ArgumentError TableGrid(cols; rule = true,
                                         rule_glyph = "❤️")

    # No rule, no check: the glyph is never drawn.
    @test TableGrid(cols; rule = false, rule_glyph = "世") isa TableGrid

    g = TableGrid(cols; rule = true)
    @test g.rule_glyph == TC_RULE
    @test text_width(g.rule_glyph) == 1
    @test g.rule
    @test !TableGrid(cols).rule
end

@testitem "tablecore: TableGrid throws on a negative sample" begin
    using DualUI
    cols = [Column("A")]
    @test_throws ArgumentError TableGrid(cols; sample = -1)
    @test_throws ArgumentError TableGrid(cols; sample = typemin(Int))
    @test TableGrid(cols; sample = 0).sample == 0
    @test TableGrid(cols).sample == TC_AUTO_SAMPLE
    @test TableGrid(cols; sample = typemax(Int)).sample == typemax(Int)

    # The rest of the defaults, which two other files code against.
    g = TableGrid(cols)
    @test g.sep == " "
    @test g.sep_w == 1
    @test g.show_header
    @test !g.rule
    @test g.cols === cols                  # ALIASED, not copied
    @test length(g.autos) == 1
    @test length(g.widths) == 1
    @test length(g.xs) == 1
    @test g.cache_version == -1            # `-1` is NEVER
    @test g.cache_width == -1
    @test !(g isa Widget)                  # NOT a widget: no node
    h = TableGrid(cols; sep = "|")
    @test h.sep_w == 1
    @test TableGrid(cols; sep = "  ").sep_w == 2
    @test TableGrid(cols; sep = "").sep_w == 0
end

@testitem "tablecore: resolve_columns is a table test" begin
    using DualUI
    # PURE: a TableGrid and an Int in; `widths`, `xs` and `cache_total`
    # out. No widget, no layout, no buffer -- `thumb_span` set that bar
    # (scroll.jl:572) and this meets it.
    function resolve(cols, avail; sep = " ")
        g = TableGrid(cols; sep = sep)
        DualUI._tc_resolve_now!(g, avail)
        return (copy(g.widths), copy(g.xs), g.cache_total)
    end

    # 1. CELLS: exact, O(1).
    w, xs, tot = resolve([Column("A"; width = cells(4)),
                          Column("B"; width = cells(6))], 40)
    @test w == [4, 6]
    @test xs == [0, 5]                     # 0-based, PRE-scroll
    @test tot == 4 + 6 + 1

    # 2. PERCENT: against the CONTENT BOX -- "25% of the box you see".
    w, _, _ = resolve([Column("A"; width = pct(25)),
                       Column("B"; width = pct(50))], 40)
    @test w == [10, 20]

    # 3. AUTO: reads the cached mark and measures NOTHING here.
    g = TableGrid([Column("A"), Column("B"; width = cells(3))])
    g.autos[1] = 7
    DualUI._tc_resolve_now!(g, 40)
    @test g.widths == [7, 3]
    @test g.xs == [0, 8]

    # 4. FRACTION: a share of what is LEFT of the INNER box.
    #    inner = 40 - 1*(3-1) = 38; fixed = 8; leftover = 30, split 1:2.
    w, _, _ = resolve([Column("A"; width = cells(8)),
                       Column("B"; width = fr(1)),
                       Column("C"; width = fr(2))], 40)
    @test w == [8, 10, 20]
    @test sum(w) + 2 == 40

    # 5. min_width/max_width clamp; AUTO bounds are UNBOUNDED.
    w, _, _ = resolve([Column("A"; width = cells(2),
                              min_width = cells(5)),
                       Column("B"; width = cells(30),
                              max_width = cells(9))], 40)
    @test w == [5, 9]

    # 6. A COLUMN NARROWER THAN ITS CONTENT STAYS NARROW. Sizing is a
    #    policy about the COLUMN; fitting the text is `_tc_put!`'s job,
    #    and it truncates with an ellipsis rather than widening.
    w, _, _ = resolve([Column("A very long header"; width = cells(3)),
                       Column("B"; width = cells(2))], 40)
    @test w == [3, 2]
    @test tot isa Int

    # 7. The separators are paid for BEFORE the columns bid --
    #    `_arrange!`'s `inner_main = main_avail - bs.gap*(n-1)`.
    w, xs, tot = resolve([Column("A"; width = fr(1)),
                          Column("B"; width = fr(1))], 11; sep = "|+")
    @test w == [5, 4]                      # ties go to the LOWER index
    @test sum(w) == 11 - 2
    @test xs == [0, 5 + 2]
    @test tot == 11

    # 8. ZERO columns does not throw and reports nothing.
    g0 = TableGrid(Column[])
    DualUI._tc_resolve_now!(g0, 40)
    @test g0.widths == Int[]
    @test g0.xs == Int[]
    @test g0.cache_total == 0

    # 9. A zero-width box is legal (nothing is laid out yet).
    w, _, tot = resolve([Column("A"; width = cells(4)),
                         Column("B"; width = fr(1))], 0)
    @test w == [4, 0]
    @test tot == 5
end

@testitem "tablecore: fr columns sum to the window EXACTLY" begin
    using DualUI
    # `_apportion` is the SAME largest-remainder-first kernel
    # `_arrange!` step 3 uses (layout.jl:417), so `sum == leftover`
    # EXACTLY and a column never drifts a cell. `fr` therefore means
    # "fill the window", and a table of all-`fr` columns never scrolls
    # horizontally, BY CONSTRUCTION.
    bad = Tuple{Int,Int}[]
    for avail in 0:60, k in 1:5
        cols = [Column("c$j"; width = fr(1)) for j in 1:k]
        g = TableGrid(cols)                # sep_w == 1
        DualUI._tc_resolve_now!(g, avail)
        inner = max(0, avail - (k - 1))
        (sum(g.widths) == inner &&
         g.cache_total == inner + (k - 1) &&
         all(>=(0), g.widths)) || push!(bad, (avail, k))
    end
    @test isempty(bad)

    # Uneven weights land exactly too.
    g = TableGrid([Column("a"; width = fr(1)),
                   Column("b"; width = fr(3)),
                   Column("c"; width = fr(1))])
    DualUI._tc_resolve_now!(g, 33)
    @test sum(g.widths) == 33 - 2
    @test g.cache_total == 33
    # inner = 31 over weights 1:3:1 -> 6.2, 18.6, 6.2; the floors are
    # 6, 18, 6 and the ONE spare cell goes to the largest remainder.
    @test g.widths == [6, 19, 6]

    # A window that exactly fits the separators leaves nothing to bid
    # for, and that is a number, not an error.
    h = TableGrid([Column("a"; width = fr(1)), Column("b"; width = fr(1))])
    DualUI._tc_resolve_now!(h, 1)
    @test h.widths == [0, 0]
    @test h.cache_total == 1
end

@testitem "tablecore: columns do NOT shrink when they overflow" begin
    using DualUI
    # NORMATIVE: `sum(widths) + sep_w*(ncols-1)` MAY EXCEED `avail`, and
    # that excess IS the horizontal scroll range. A table that shrank
    # its columns to fit would have nothing left to scroll and no reason
    # for the header to follow them -- `Scrollpane`'s holder lesson
    # (scroll.jl:250) verbatim. `flex_distribute` is NOT called: with no
    # shrink and no grow factor it is provably the identity.
    g = TableGrid([Column("A"; width = cells(30)),
                   Column("B"; width = cells(30)),
                   Column("C"; width = cells(30))])
    DualUI._tc_resolve_now!(g, 20)
    @test g.widths == [30, 30, 30]         # NOT squeezed to the window
    @test g.xs == [0, 31, 62]
    @test g.cache_total == 92
    @test g.cache_total > 20               # THIS is the scroll range

    # An AUTO mark wider than the box is not shrunk either.
    h = TableGrid([Column("A"), Column("B")])
    h.autos[1] = 50
    h.autos[2] = 50
    DualUI._tc_resolve_now!(h, 10)
    @test h.widths == [50, 50]
    @test h.cache_total == 101

    # A PERCENT column is exact, not fitted.
    p = TableGrid([Column("A"; width = pct(100)),
                   Column("B"; width = pct(100))])
    DualUI._tc_resolve_now!(p, 10)
    @test p.widths == [10, 10]
    @test p.cache_total == 21

    # `fr` is the OPT-IN to filling the window instead.
    f = TableGrid([Column("A"; width = fr(1))])
    DualUI._tc_resolve_now!(f, 10)
    @test f.widths == [10]
    @test f.cache_total == 10
end

@testitem "tablecore: largest-remainder ties go to the lower index" begin
    using DualUI
    # Two equal `fr` columns over an ODD leftover: the spare cell goes
    # to the LOWER index, DETERMINISTICALLY. `_apportion`'s contract,
    # reused rather than re-derived, so the right edge is never ragged.
    g = TableGrid([Column("a"; width = fr(1)),
                   Column("b"; width = fr(1))])
    DualUI._tc_resolve_now!(g, 10)         # inner = 9
    @test g.widths == [5, 4]
    @test sum(g.widths) == 9

    h = TableGrid([Column("a"; width = fr(1)),
                   Column("b"; width = fr(1)),
                   Column("c"; width = fr(1))])
    DualUI._tc_resolve_now!(h, 13)         # inner = 11
    @test h.widths == [4, 4, 3]
    @test sum(h.widths) == 11

    # A non-fr column never receives a remainder cell.
    m = TableGrid([Column("a"; width = cells(2)),
                   Column("b"; width = fr(1)),
                   Column("c"; width = fr(1))])
    DualUI._tc_resolve_now!(m, 12)         # inner = 10, leftover = 8
    @test m.widths == [2, 4, 4]
end

@testitem "tablecore: _tc_measure is capped, not O(length)" begin
    using DualUI
    # THE bound on every AUTO measurement, and it is not a micro-
    # optimisation: `truncate_width` (unicode.jl:138) BREAKS OUT of its
    # grapheme loop the moment the budget is exceeded, so this is O(cap)
    # and NEVER O(length(s)). A 10 KB description column would otherwise
    # cost 10 KB of grapheme iteration per measured cell to discover a
    # fact `truncate_width` already knows.
    m = DualUI._tc_measure
    @test m("abc", 10) == 3
    @test m("abcdefghij", 4) == 4
    @test m("", 10) == 0
    @test m("abc", 0) == 0
    @test m("abc", -3) == 0

    # A wide cluster that would STRADDLE the cap is DROPPED, so the
    # measurement can come in UNDER it -- which is exactly right: half a
    # cluster does not fit.
    @test m("世界", 3) == 2
    @test m("世界", 4) == 4
    @test m("❤️", 1) == 0
    @test m("❤️", 2) == 2

    # THE MECHANISM, asserted rather than assumed: the result is the
    # width of a prefix `truncate_width` stopped building the moment the
    # budget was gone. The string's length never enters.
    huge = repeat("x", 100_000)
    @test m(huge, 10) == 10
    @test ncodeunits(truncate_width(huge, 10)) == 10
    @test m(huge, 10) == m("xxxxxxxxxx", 10)

    # And the consequence, measured. MEASURED at ~3526x by the
    # architect; 10x is a floor no O(length) spelling can pass.
    m(huge, 10)
    text_width(huge)
    t = @elapsed for _ in 1:50
        m(huge, 10)
    end
    u = @elapsed for _ in 1:50
        text_width(huge)
    end
    @test t < u / 10
end

@testitem "tablecore: _tc_show returns its argument for a String" begin
    using DualUI
    # `string(s::String) === s`, so a `List{String}` formats for ZERO
    # allocation per row.
    s = "already a string"
    @test DualUI._tc_show(s) === s
    @test DualUI._tc_show(SubString(s, 1, 7)) === SubString(s, 1, 7)
    @test DualUI._tc_show(42) == "42"
    @test DualUI._tc_show(4.5) == "4.5"
    @test DualUI._tc_show(:sym) == "sym"
    @test DualUI._tc_show(nothing) == "nothing"
    @test DualUI._tc_show(s) isa AbstractString
    @test DualUI._tc_show(42) isa AbstractString
    DualUI._tc_show(s)
    @test @allocated(DualUI._tc_show(s)) == 0

    # The default `on_activate` does nothing, and returns nothing.
    @test DualUI._tc_noop(Container()) === nothing
end

@testitem "tablecore: _tc_put! truncates on a grapheme boundary" begin
    using DualUI
    put! = DualUI._tc_put!
    txt(b) = String(strip(string(b)))

    # ASCII.
    b = Buffer(20, 1)
    put!(b, 1, 1, 5, "Alice Smith", Align.START, STYLE_NONE)
    @test txt(b) == "Alic…"

    # CJK: `truncate_width("世界世", 4)` is the first two
    # clusters, and the ellipsis takes the fifth cell.
    b = Buffer(20, 1)
    put!(b, 1, 1, 5, "世界世", Align.START, STYLE_NONE)
    @test txt(b) == "世界…"
    @test b[1, 1].width == Int8(2)
    @test is_continuation(b[2, 1])
    @test b[3, 1].width == Int8(2)
    @test is_continuation(b[4, 1])
    @test String(b[5, 1].content) == TC_ELLIPSIS

    # It FITS: no ellipsis, nothing cut.
    b = Buffer(20, 1)
    put!(b, 1, 1, 11, "Alice Smith", Align.START, STYLE_NONE)
    @test txt(b) == "Alice Smith"

    # Exactly fits: the boundary case either side of it.
    b = Buffer(20, 1)
    put!(b, 1, 1, 4, "世界", Align.START, STYLE_NONE)
    @test txt(b) == "世界"

    # A ZWJ family is ONE cluster and TWO cells, and `Base.textwidth`
    # would say 6 and cut it to ribbons.
    zwj = "\U0001F468‍\U0001F469‍\U0001F467"
    @test grapheme_width(zwj) == 2
    b = Buffer(20, 1)
    put!(b, 1, 1, 2, zwj, Align.START, STYLE_NONE)
    @test txt(b) == zwj
    @test b[1, 1].width == Int8(2)
    @test is_continuation(b[2, 1])
end

@testitem "tablecore: _tc_put! never halves a cluster at a column edge" begin
    using DualUI
    # A CLUSTER CANNOT STRADDLE A COLUMN EDGE BY CONSTRUCTION:
    # `truncate_width` DROPS a width-2 cluster that would straddle the
    # cap, and `cross_align` places the result inside
    # `0 : cw - text_width(t)`. There is no second guard to write.
    put! = DualUI._tc_put!

    # A width-2 cluster in an ODD-width column leaves a one-cell gap --
    # the correct rendering of "it does not fit".
    b = Buffer(10, 1)
    put!(b, 1, 1, 3, "世界", Align.START, STYLE_NONE)
    # cw = 3 holds ONE cluster (2 cells) + the ellipsis (1 cell).
    @test b[1, 1].width == Int8(2)
    @test is_continuation(b[2, 1])
    @test String(b[3, 1].content) == TC_ELLIPSIS
    # The NEXT column's first cell is untouched.
    @test b[4, 1] == CELL_BLANK

    # Two columns, back to back: nothing bleeds across `x0 + cw`.
    b = Buffer(10, 1)
    put!(b, 1, 1, 4, "世界世", Align.START, STYLE_NONE)
    put!(b, 5, 1, 4, "世界世", Align.START, STYLE_NONE)
    @test String(b[4, 1].content) == TC_ELLIPSIS
    @test b[5, 1].width == Int8(2)
    @test String(b[8, 1].content) == TC_ELLIPSIS
    @test b[9, 1] == CELL_BLANK

    # The §6.2 property: no CELL_CONT whose head we did not write.
    for x in 1:10
        is_continuation(b[x, 1]) || continue
        @test x > 1
        @test b[x - 1, 1].width == Int8(2)
    end
end

@testitem "tablecore: _tc_put! never halves a cluster at a frame edge" begin
    using DualUI
    # LEFT: `x0` MAY BE <= 0 -- a column scrolled off the left is a
    # NEGATIVE start, exactly as `TextInput.render!` hands `write_text!`
    # a negative `1 - off`. A cluster landing at `cx < 1` is skipped
    # WHOLE, so `set_cell!` never sees the half that would orphan a
    # continuation into column 1.
    put! = DualUI._tc_put!
    b = Buffer(6, 1)
    put!(b, 0, 1, 6, "世界ab", Align.START, STYLE_NONE)
    # The first cluster starts at frame column 0 and STRADDLES the edge:
    # dropped whole, NOT halved into column 1.
    @test b[1, 1] == CELL_BLANK
    @test b[2, 1].width == Int8(2)         # the second cluster
    @test is_continuation(b[3, 1])

    # RIGHT: `set_cell!` already refuses a wide cluster that would
    # straddle the frame's right edge (buffer.jl:419).
    b = Buffer(6, 1)
    put!(b, 6, 1, 4, "世", Align.START, STYLE_NONE)
    @test b[6, 1] == CELL_BLANK            # refused, not halved

    # A column entirely off-frame writes nothing at all and throws
    # nothing either.
    b = Buffer(6, 1)
    put!(b, -20, 1, 4, "abcd", Align.START, STYLE_NONE)
    @test string(b) == "      "
    put!(b, 40, 1, 4, "abcd", Align.START, STYLE_NONE)
    @test string(b) == "      "

    # Degenerate widths are numbers, not special cases.
    put!(b, 1, 1, 0, "abcd", Align.START, STYLE_NONE)
    @test string(b) == "      "
    put!(b, 1, 1, -3, "abcd", Align.START, STYLE_NONE)
    @test string(b) == "      "
    put!(b, 1, 9, 4, "abcd", Align.START, STYLE_NONE)
    @test string(b) == "      "
end

@testitem "tablecore: _tc_put! in a 1-cell column holding CJK" begin
    using DualUI
    # DEGENERATE BY CONSTRUCTION, not by special case:
    # `truncate_width("世", 1) == ""` (VERIFIED), so the cell gets
    # the ellipsis ALONE -- one cell, one legible glyph, nothing halved.
    put! = DualUI._tc_put!
    b = Buffer(4, 1)
    put!(b, 1, 1, 1, "世", Align.START, STYLE_NONE)
    @test String(b[1, 1].content) == TC_ELLIPSIS
    @test b[1, 1].width == Int8(1)
    @test b[2, 1] == CELL_BLANK

    # Same for every wide cluster the tier cares about.
    for s in ("世界", "❤️", "\U0001F1EB\U0001F1F7",
              "\U0001F468‍\U0001F469‍\U0001F467")
        @test grapheme_width(s) == 2
        local b = Buffer(4, 1)
        put!(b, 1, 1, 1, s, Align.START, STYLE_NONE)
        @test String(b[1, 1].content) == TC_ELLIPSIS
        @test b[2, 1] == CELL_BLANK
        @test !is_continuation(b[2, 1])
    end

    # A 1-cell column with a 1-cell cluster just fits -- no ellipsis.
    for s in ("a", "é", "a︎")
        @test grapheme_width(s) == 1
        local b = Buffer(4, 1)
        put!(b, 1, 1, 1, s, Align.START, STYLE_NONE)
        @test String(b[1, 1].content) == s
    end
end

@testitem "tablecore: _tc_put! ellipsis marks a truncated cell" begin
    using DualUI
    put! = DualUI._tc_put!
    txt(b) = String(strip(string(b)))

    b = Buffer(12, 1)
    put!(b, 1, 1, 6, "abcdefgh", Align.START, STYLE_NONE)
    @test txt(b) == "abcde…"
    @test String(b[6, 1].content) == TC_ELLIPSIS

    # NOT truncated: no marker, and the last cell stays the text's.
    b = Buffer(12, 1)
    put!(b, 1, 1, 6, "abcdef", Align.START, STYLE_NONE)
    @test txt(b) == "abcdef"
    @test String(b[6, 1].content) == "f"

    # One cluster over: the marker appears.
    b = Buffer(12, 1)
    put!(b, 1, 1, 6, "abcdefg", Align.START, STYLE_NONE)
    @test txt(b) == "abcde…"

    # `_tc_truncated` is `ncodeunits`, not `text_width(s) > cw`: the
    # obvious spelling walks the WHOLE untruncated string.
    @test DualUI._tc_truncated(truncate_width("abcdef", 3), "abcdef")
    @test !DualUI._tc_truncated(truncate_width("abc", 3), "abc")
    @test !DualUI._tc_truncated(truncate_width("", 3), "")
    @test DualUI._tc_truncated(truncate_width("世", 1), "世")
end

@testitem "tablecore: a truncated cell is left-anchored under every align" begin
    using DualUI
    # NORMATIVE: `align` applies ONLY when the text FITS. A right-
    # aligned truncated number ("…234") reads as a DIFFERENT
    # NUMBER, which is worse than a visibly clipped one. This also fixes
    # the bug where an END-aligned cell paints text OVER its own marker.
    put! = DualUI._tc_put!
    txt(b) = String(strip(string(b)))
    for a in (Align.START, Align.CENTER, Align.END, Align.STRETCH)
        b = Buffer(12, 1)
        put!(b, 1, 1, 6, "123456789", a, STYLE_NONE)
        @test txt(b) == "12345…"
        @test String(b[1, 1].content) == "1"
        @test String(b[6, 1].content) == TC_ELLIPSIS
    end
end

@testitem "tablecore: _tc_put! honours all four Align values" begin
    using DualUI
    # `cross_align` (layout.jl:163) does the placement -- REUSED, not
    # reinvented. `Align.STRETCH` degenerates to START FOR FREE, because
    # `cross_align(n, STRETCH, w)` returns `(0, w)` and a text painter
    # reads only the OFFSET. That is why there is no CellAlign enum and
    # no `_tc_lead`.
    put! = DualUI._tc_put!
    lay(a) = begin
        b = Buffer(9, 1)
        put!(b, 1, 1, 9, "abc", a, STYLE_NONE)
        string(b)
    end
    @test lay(Align.START) == "abc      "
    @test lay(Align.CENTER) == "   abc   "
    @test lay(Align.END) == "      abc"
    @test lay(Align.STRETCH) == "abc      "
    @test cross_align(3, Align.STRETCH, 9) == (0, 9)

    # An odd leftover under CENTER rounds DOWN -- `cross_align`'s rule,
    # not a new one.
    b = Buffer(8, 1)
    put!(b, 1, 1, 8, "abc", Align.CENTER, STYLE_NONE)
    @test string(b) == "  abc   "

    # Alignment inside a column that is not at the frame's origin.
    b = Buffer(12, 1)
    put!(b, 5, 1, 6, "ab", Align.END, STYLE_NONE)
    @test string(b) == "        ab  "
end

@testitem "tablecore: _tc_paint_slice! drops a cluster at the left edge" begin
    using DualUI
    # `TextArea.render!`'s loop (textarea.jl:239), third and last copy:
    # a cluster left of the window lands on `cx <= 0` and is skipped,
    # and one STRADDLING the edge lands there too, so `set_cell!` never
    # sees the half of it that would orphan a continuation into column 1.
    slice! = DualUI._tc_paint_slice!

    # skip = 1 cuts INTO the first wide cluster: dropped, not halved.
    b = Buffer(6, 1)
    slice!(b, 1, 6, 1, "世界ab", STYLE_NONE)
    @test b[1, 1] == CELL_BLANK            # the halved cell is BLANK
    @test b[2, 1].width == Int8(2)         # the second cluster
    @test is_continuation(b[3, 1])
    @test String(b[4, 1].content) == "a"

    # skip = 2 lands exactly on the boundary: nothing is lost.
    b = Buffer(6, 1)
    slice!(b, 1, 6, 2, "世界ab", STYLE_NONE)
    @test b[1, 1].width == Int8(2)
    @test is_continuation(b[2, 1])
    @test String(b[3, 1].content) == "a"

    # Wholly skipped clusters cost nothing and write nothing.
    b = Buffer(6, 1)
    slice!(b, 1, 6, 4, "世界ab", STYLE_NONE)
    @test String(b[1, 1].content) == "a"
    @test String(b[2, 1].content) == "b"

    # No CELL_CONT without its head, at any skip.
    for skip in 0:8
        local b = Buffer(6, 1)
        slice!(b, 1, 6, skip, "世界ab❤️", STYLE_NONE)
        for x in 1:6
            is_continuation(b[x, 1]) || continue
            @test x > 1 && b[x - 1, 1].width == Int8(2)
        end
    end
end

@testitem "tablecore: _tc_paint_slice! returns the column reached" begin
    using DualUI
    # THE return value is what `List.render!` raises `widest` from, and
    # it makes the high-water mark cost the paint loop NOTHING -- no
    # second pass over the graphemes, no `text_width` on an unbounded
    # string.
    slice! = DualUI._tc_paint_slice!
    b = Buffer(10, 1)

    # It FIT: the row's FULL width.
    @test slice!(b, 1, 10, 0, "abc", STYLE_NONE) == 3
    @test slice!(b, 1, 10, 0, "", STYLE_NONE) == 0
    @test slice!(b, 1, 10, 0, "世界", STYLE_NONE) == 4
    @test slice!(b, 1, 10, 0, "❤️", STYLE_NONE) == 2
    @test slice!(b, 1, 10, 0, "abcdefghij", STYLE_NONE) == 10
    # Sliced at an offset and still fitting: the FULL width, so the mark
    # does not depend on where the reader happens to be scrolled.
    @test slice!(b, 1, 10, 2, "abcde", STYLE_NONE) == 5
    @test slice!(b, 1, 4, 6, "abcdefghi", STYLE_NONE) == 9

    # It was CUT OFF: AT LEAST `skip + width`. Understating a cut row is
    # exactly what a high-water mark does.
    @test slice!(b, 1, 10, 0, repeat("x", 100), STYLE_NONE) >= 10
    @test slice!(b, 1, 4, 6, repeat("x", 100), STYLE_NONE) >= 10
    # ... and never MORE than the truth.
    @test slice!(b, 1, 10, 0, repeat("x", 100), STYLE_NONE) <= 100
end

@testitem "tablecore: no CELL_CONT without its head" begin
    using DualUI
    # THE §6.2 property, checkable by scanning the buffer, and it
    # catches everything: for every `s`, `x0`, `cw` and `align` the
    # painter writes ONLY into frame columns
    # `max(x0,1) : min(x0+cw-1, width)`; every cluster it writes is
    # written WHOLE OR NOT AT ALL; and it leaves no continuation whose
    # head it did not write.
    #
    # ALL of §6.1's test vectors, exhaustively.
    texts = ("Alice Smith",                                # ASCII
             "世界",                               # CJK
             "❤️",                               # VS16
             "\U0001F468‍\U0001F469‍\U0001F467", # ZWJ family
             "a︎",                                    # VS15
             "\U0001F1EB\U0001F1F7",                       # RI flag
             "é",                               # combining
             "",
             "a世b")
    W = 7
    orphan(b) = begin
        for x in 1:W
            is_continuation(b[x, 1]) || continue
            (x > 1 && b[x - 1, 1].width == Int8(2)) || return true
        end
        false
    end
    outside(b, lo, hi) = begin
        for x in 1:W
            (lo <= x <= hi) && continue
            b[x, 1] == CELL_BLANK || return true
        end
        false
    end

    bad = Any[]
    for s in texts, x0 in -3:9, cw in 0:7,
        a in (Align.START, Align.CENTER, Align.END, Align.STRETCH)

        b = Buffer(W, 1)
        DualUI._tc_put!(b, x0, 1, cw, s, a, STYLE_NONE)
        orphan(b) && push!(bad, (:orphan, s, x0, cw, a))
        outside(b, max(x0, 1), min(x0 + cw - 1, W)) &&
            push!(bad, (:outside, s, x0, cw, a))
    end
    @test isempty(bad)

    # `_tc_paint_slice!` obeys the same property over every skip.
    bad2 = Any[]
    for s in texts, skip in 0:6
        b = Buffer(W, 1)
        DualUI._tc_paint_slice!(b, 1, W, skip, s, STYLE_NONE)
        orphan(b) && push!(bad2, (s, skip))
    end
    @test isempty(bad2)

    # And a highlight over a wide cluster restyles its HEAD and leaves
    # its continuation a continuation -- `style_region!`, never
    # `fill_region!` (buffer.jl:476).
    b = Buffer(W, 1)
    DualUI._tc_put!(b, 1, 1, 4, "世界", Align.START, STYLE_NONE)
    style_region!(b, Region(1, 1, W, 1), TC_SELECTED)
    @test !orphan(b)
    @test b[1, 1].width == Int8(2)
    @test is_continuation(b[2, 1])
    @test has(b[1, 1].style, Attr.REVERSE)
end
