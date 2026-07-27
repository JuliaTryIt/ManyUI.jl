# widgets_datatable_tests.jl -- a sortable Table (layer 7).
#
# Every testitem is self-contained, starts `using ManyUI`, needs no tty,
# never sleeps and bounds every wait.
#
# THE TWO NORMATIVE PROPERTIES OF THE SORT, asserted on BEHAVIOUR rather
# than on a flag:
#   1. STABLE -- proved on DUPLICATE keys, in BOTH directions, against
#      the `[1,3,5,2,4]` anchor. Asserting `alg = MergeSort` is in the
#      source proves nothing; a tie that moved does.
#   2. IT DOES NOT MUTATE THE CALLER'S DATA -- proved with `===` on the
#      vector AND elementwise on its contents, after a sort.
#
# The sort is O(n log n) ON A USER ACTION and NEVER per frame: the paint
# tests here count `cell`/`key` calls and bound them by the WINDOW, so a
# 100 000-row sorted table costs the same frame as a 10-row one.

# --- construction -----------------------------------------------------

@testitem "datatable: key is a REQUIRED keyword" begin
    using ManyUI
    rows = [("Bob", 30), ("Amy", 25)]
    cols = [Column("Name"; width = cells(6))]
    # A `DataTable` exists to sort; one without a sort key is a `Table`.
    # The decision is UNAVOIDABLE AT CONSTRUCTION rather than a default
    # that silently does the wrong thing.
    @test_throws UndefKeywordError DataTable(rows, cols)
    @test DataTable(rows, cols; key = (r, j) -> r[j]) isa DataTable
end

@testitem "datatable: is focusable by construction" begin
    using ManyUI
    dt = DataTable([("a",)], [Column("X")]; key = (r, j) -> r[j])
    @test dt isa Widget
    @test dt isa RowsWidget
    @test is_focusable(dt)
    @test type_name(dt) === :DataTable
    @test id(dt) !== id(DataTable([("a",)], [Column("X")];
                                  key = (r, j) -> r[j]))
end

@testitem "datatable: starts in SOURCE order with no indicator" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    @test sort_column(dt) == 0
    @test sort_direction(dt) === SortDir.NONE
    @test dt.order == [1, 2, 3]
    @test dt.rank == [1, 2, 3]
    @test sort_indicator(dt, 1) == ""
    @test view_count(dt) == 3
    @test row_count(dt) == 3
    @test source_index(dt, 1) == 1
end

# --- the sort: the two normative properties ---------------------------

@testitem "datatable: sort_by! NEVER mutates rows" begin
    using ManyUI
    rows = [("c", 3), ("a", 1), ("b", 2)]
    before = copy(rows)
    dt = DataTable(rows, [Column("N"; width = cells(3)),
                          Column("V"; width = cells(3))];
                   key = (r, j) -> r[j])
    @test dt.rows === rows              # ALIASED, never copied

    @test sort_by!(dt, 1)
    # THE caller's vector, in THE caller's order. An index permutation is
    # the answer; permuting `rows` would mutate a `Vector` the caller
    # handed us and may still be using.
    @test dt.rows === rows
    @test rows == before
    @test rows[1] == ("c", 3)
    @test rows[2] == ("a", 1)
    @test rows[3] == ("b", 2)

    @test sort_by!(dt, 2; dir = SortDir.DESCENDING)
    @test rows == before
    @test sort_by!(dt, 0)
    @test rows == before
end

@testitem "datatable: sort_by! is stable ASCENDING" begin
    using ManyUI
    # Duplicate keys, distinct payloads: ties MUST keep SOURCE order.
    rows = [(2, :a), (1, :b), (2, :c), (1, :d), (2, :e)]
    dt = DataTable(rows, [Column("K"; width = cells(3))];
                   key = (r, j) -> r[1])
    @test sort_by!(dt, 1)
    # keys 1,1,2,2,2 -> the two 1s in source order (2,4), then the
    # three 2s in source order (1,3,5).
    @test dt.order == [2, 4, 1, 3, 5]
    @test [rows[dt.order[k]][2] for k in 1:5] == [:b, :d, :a, :c, :e]
end

@testitem "datatable: sort_by! DESCENDING keeps ties in SOURCE order" begin
    using ManyUI
    rows = [(2, :a), (1, :b), (2, :c), (1, :d), (2, :e)]
    dt = DataTable(rows, [Column("K"; width = cells(3))];
                   key = (r, j) -> r[1])
    @test sort_by!(dt, 1; dir = SortDir.DESCENDING)
    # THE ANCHOR: `rev = true` REVERSES THE ORDERING, NOT THE OUTPUT, so
    # ties keep their SOURCE order in BOTH directions. [1,3,5,2,4], NOT
    # [5,3,1,4,2]. That is what "stable" has to mean for a user who sorts
    # by Department then by Name and expects the Names still in order
    # within a Department.
    @test dt.order == [1, 3, 5, 2, 4]
    @test [rows[dt.order[k]][2] for k in 1:5] == [:a, :c, :e, :b, :d]
    @test dt.order != reverse([2, 4, 1, 3, 5])   # NOT the reversed ASC
end

@testitem "datatable: a tie-only column still flips its indicator" begin
    using ManyUI
    # EVERY key is equal, so ASC and DESC give the IDENTICAL order --
    # stability guarantees it. The arrow still has to turn over, and a
    # `sort_by!` that reported "nothing changed" here would skip the
    # PAINT bump and leave the header contradicting sort_direction.
    dt = DataTable([(1,), (1,), (1,)], [Column("K"; width = cells(3))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 6))

    @test sort_by!(dt, 1)
    @test dt.order == [1, 2, 3]
    clean!(dt)
    @test sort_by!(dt, 1; dir = SortDir.DESCENDING)   # order CANNOT move
    @test dt.order == [1, 2, 3]
    @test sort_direction(dt) === SortDir.DESCENDING
    @test sort_indicator(dt, 1) == TC_SORT_DESC
    @test is_dirty(dt, Dirty.PAINT)                   # and it repainted

    # Nothing at all changed: still false.
    @test !sort_by!(dt, 1; dir = SortDir.DESCENDING)
end

@testitem "datatable: sorting ascending and descending" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    @test sort_by!(dt, 1)
    @test sort_direction(dt) === SortDir.ASCENDING
    @test sort_column(dt) == 1
    @test [rows[i][1] for i in dt.order] == ["a", "b", "c"]

    @test sort_by!(dt, 1; dir = SortDir.DESCENDING)
    @test sort_direction(dt) === SortDir.DESCENDING
    @test [rows[i][1] for i in dt.order] == ["c", "b", "a"]
end

@testitem "datatable: the sort compares the KEY, not the cell" begin
    using ManyUI
    # Sorting a numeric column by its RENDERED string puts "10" before
    # "9". The two callbacks exist precisely so it cannot.
    rows = [(9,), (10,), (1,)]
    dt = DataTable(rows, [Column("N"; width = cells(4))];
                   key = (r, j) -> r[1])
    @test sort_by!(dt, 1)
    @test [rows[i][1] for i in dt.order] == [1, 9, 10]
end

# --- the sort: refusals and edges -------------------------------------

@testitem "datatable: sort_by! throws on a non-sortable column" begin
    using ManyUI
    rows = [("c",), ("a",)]
    cols = [Column("X"; width = cells(3), sortable = false)]
    dt = DataTable(rows, cols; key = (r, j) -> r[1])
    # NOT a silent no-op: a quiet nothing on the one call whose whole
    # purpose is to change something is the worst available failure.
    @test_throws ArgumentError sort_by!(dt, 1)
    @test_throws ArgumentError toggle_sort!(dt, 1)
    @test sort_column(dt) == 0
    @test dt.order == [1, 2]
end

@testitem "datatable: sort_by! throws outside 0:ncols" begin
    using ManyUI
    dt = DataTable([("c",), ("a",)], [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    @test_throws BoundsError sort_by!(dt, 2)
    @test_throws BoundsError sort_by!(dt, -1)
    @test_throws BoundsError sort_by!(dt, 99)
    @test sort_by!(dt, 1)                 # 1 is in range
    @test sort_by!(dt, 0)                 # 0 is in range: source order
end

@testitem "datatable: sort_by!(w, 0) restores source order exactly" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    @test sort_by!(dt, 1)
    @test dt.order == [2, 3, 1]
    # `NONE` restores SOURCE order and is reachable on purpose: it
    # un-sorts without reloading the data.
    @test sort_by!(dt, 0)
    @test dt.order == [1, 2, 3]
    @test dt.rank == [1, 2, 3]
    @test sort_column(dt) == 0
    @test sort_direction(dt) === SortDir.NONE
    @test sort_indicator(dt, 1) == ""
    @test !sort_by!(dt, 0)                # already there: nothing changed

    # `dir = NONE` on a real column is the same door.
    @test sort_by!(dt, 1)
    @test sort_by!(dt, 1; dir = SortDir.NONE)
    @test dt.order == [1, 2, 3]
    @test sort_column(dt) == 0
end

@testitem "datatable: sort_by! is deterministic whatever the history" begin
    using ManyUI
    rows = [("c", 2), ("a", 3), ("b", 1)]
    dt = DataTable(rows, [Column("N"; width = cells(3)),
                          Column("V"; width = cells(3))];
                   key = (r, j) -> r[j])
    sort_by!(dt, 1)
    want = copy(dt.order)

    # `order` is RESET to `1:n` before every sort, so the same call gives
    # the same answer whatever the history. THE PRICE: no multi-key sort
    # by chaining -- `key = (r, j) -> (r.dept, r.name)` is where that
    # lives instead.
    sort_by!(dt, 2; dir = SortDir.DESCENDING)
    sort_by!(dt, 2)
    sort_by!(dt, 0)
    sort_by!(dt, 1)
    @test dt.order == want

    fresh = DataTable(copy(rows), [Column("N"; width = cells(3)),
                                   Column("V"; width = cells(3))];
                      key = (r, j) -> r[j])
    sort_by!(fresh, 1)
    @test fresh.order == want
end

@testitem "datatable: sorting a mixed-type column THROWS" begin
    using ManyUI
    # A column of MIXED types THROWS a MethodError from `isless` -- it is
    # not "merely slow". `key` must return values mutually
    # `isless`-comparable WITHIN a column.
    rows = Any[("a",), (1,)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1], cell = (r, j) -> string(r[1]))
    @test_throws MethodError sort_by!(dt, 1)
end

@testitem "datatable: sort on an empty table" begin
    using ManyUI
    rows = Tuple{String}[]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    @test row_count(dt) == 0
    @test view_count(dt) == 0
    @test isempty(dt.order)
    @test isempty(dt.rank)
    @test row_cursor(dt) == 0
    # Total at n == 0: the STATE changes (the indicator appears), the
    # order cannot. Nothing throws.
    @test sort_by!(dt, 1)
    @test sort_column(dt) == 1
    @test sort_indicator(dt, 1) == TC_SORT_ASC
    @test isempty(dt.order)
    @test isempty(dt.rank)
    @test selected_rows(dt) == Int[]
    @test n_selected(dt) == 0
    @test sort_by!(dt, 1; dir = SortDir.DESCENDING)
    @test isempty(dt.order)
    @test sort_by!(dt, 0)
    @test isempty(dt.order)

    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 3))
    buf = Buffer(6, 3)
    clear!(buf)
    render!(dt, buf)                       # header, then nothing
    @test split(string(buf), '\n')[2] == "      "
end

@testitem "datatable: sort on one row" begin
    using ManyUI
    rows = [("only",)]
    dt = DataTable(rows, [Column("X"; width = cells(5))];
                   key = (r, j) -> r[1])
    @test sort_by!(dt, 1)
    @test dt.order == [1]
    @test dt.rank == [1]
    @test !sort_by!(dt, 1)                 # already there
    @test sort_by!(dt, 1; dir = SortDir.DESCENDING)
    @test dt.order == [1]                  # one row: both directions agree
    @test dt.rank == [1]
    @test rows == [("only",)]
    @test row_cursor(dt) == 1
    @test view_source(dt, 1) == 1
    @test view_rank(dt, 1) == 1
end

# --- the permutation invariants ---------------------------------------

@testitem "datatable: rank[order[k]] == k after every sort" begin
    using ManyUI
    rows = [(x,) for x in [5, 3, 9, 1, 3, 7, 3]]
    dt = DataTable(rows, [Column("K"; width = cells(3))];
                   key = (r, j) -> r[1])
    n = length(rows)
    for (j, d) in ((1, SortDir.ASCENDING), (1, SortDir.DESCENDING),
                   (0, SortDir.NONE), (1, SortDir.ASCENDING))
        sort_by!(dt, j; dir = d)
        # The inverse is rebuilt in ONE O(n) pass after every sort. It is
        # what makes DOWN O(1) instead of an O(n) search through `order`.
        for k in 1:n
            @test dt.rank[dt.order[k]] == k
            @test view_rank(dt, view_source(dt, k)) == k
        end
    end
end

@testitem "datatable: order is always a permutation of 1:n" begin
    using ManyUI
    rows = [(x,) for x in [5, 3, 9, 1, 3, 7, 3]]
    dt = DataTable(rows, [Column("K"; width = cells(3))];
                   key = (r, j) -> r[1])
    perm(v, n) = sort(copy(v)) == collect(1:n)
    for (j, d) in ((1, SortDir.ASCENDING), (1, SortDir.DESCENDING),
                   (0, SortDir.NONE))
        sort_by!(dt, j; dir = d)
        @test length(dt.order) == length(rows)
        @test perm(dt.order, length(rows))
        @test perm(dt.rank, length(rows))
    end
    push_row!(dt, (2,))
    @test perm(dt.order, length(rows))
    @test perm(dt.rank, length(rows))
    @test delete_row!(dt, 1)
    @test perm(dt.order, length(rows))
    @test perm(dt.rank, length(rows))
end

# --- the selection across a sort --------------------------------------

@testitem "datatable: the SELECTION survives a sort by ROW" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1], mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 6))

    select_only!(dt, 1)                    # VIEW row 1 == source 1 == "c"
    @test selected_rows(dt) == [1]
    @test row_cursor(dt) == 1

    sort_by!(dt, 1)                        # a, b, c -> order == [2, 3, 1]
    @test dt.order == [2, 3, 1]
    # Every index in `Selection` is a SOURCE index, so a sort -- a claim
    # about ORDER -- cannot touch a selection -- a claim about ROWS.
    @test selected_rows(dt) == [1]
    @test is_selected(dt, 1)
    @test !is_selected(dt, 2)
    @test rows[only(selected_rows(dt))] == ("c",)   # STILL "c"
    @test view_rank(dt, 1) == 3            # "c" now sits at VIEW row 3
    @test source_index(dt, 3) == 1
end

@testitem "datatable: the selection is UNCHANGED by a sort" begin
    using ManyUI
    rows = [(x,) for x in [5, 3, 9, 1]]
    dt = DataTable(rows, [Column("K"; width = cells(3))];
                   key = (r, j) -> r[1], mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 8))
    select_only!(dt, 1)
    toggle_row!(dt, 3)
    held = selected_rows(dt)
    anchor = row_anchor(dt)
    @test length(held) == 2

    # ZERO WORK: there is no `remap!` here to get wrong.
    for (j, d) in ((1, SortDir.ASCENDING), (1, SortDir.DESCENDING),
                   (0, SortDir.NONE))
        sort_by!(dt, j; dir = d)
        @test selected_rows(dt) == held
        @test row_anchor(dt) == anchor
    end
end

@testitem "datatable: the cursor's ROW survives a sort, scrolled to" begin
    using ManyUI
    # key = -i, so ASCENDING exactly reverses the source order.
    rows = [(i,) for i in 1:100]
    dt = DataTable(rows, [Column("N"; width = cells(4))];
                   key = (r, j) -> -r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 10, 12))
    set_cursor!(dt, 1)                     # VIEW row 1 == source row 1
    @test row_cursor(dt) == 1
    @test scroll_of(dt).y == 0

    sort_by!(dt, 1)
    # The cursor does not change ROW; it changes SCREEN POSITION, because
    # `view_rank` changed. `_tc_follow_cursor!` then runs, so THE USER'S
    # ROW STAYS UNDER THEIR EYES across the sort.
    @test row_cursor(dt) == 1              # the ROW did not move
    @test view_rank(dt, 1) == 100          # its screen position did
    @test scroll_of(dt).y == max_scroll(dt).y
    @test scroll_of(dt).y == 89            # (100 + 1) - 12

    sort_by!(dt, 0)
    @test row_cursor(dt) == 1
    @test view_rank(dt, 1) == 1
    @test scroll_of(dt).y == 0             # followed back to the top
end

@testitem "datatable: navigation after a re-sort walks the VIEW" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 6))
    sort_by!(dt, 1)                        # view: a(2), b(3), c(1)

    set_cursor!(dt, 1)
    @test row_cursor(dt) == 2              # source of VIEW row 1 is "a"
    @test move_cursor!(dt, 1)
    @test row_cursor(dt) == 3              # "b"
    @test move_cursor!(dt, 1)
    @test row_cursor(dt) == 1              # "c"
    @test !move_cursor!(dt, 1)             # last VIEW row: does not move
end

# --- the indicator ----------------------------------------------------

@testitem "datatable: the indicator is on the sorted column ONLY" begin
    using ManyUI
    dt = DataTable([("a", 1)], [Column("N"; width = cells(6)),
                                Column("V"; width = cells(4))];
                   key = (r, j) -> r[j])
    @test sort_indicator(dt, 1) == ""
    @test sort_indicator(dt, 2) == ""

    sort_by!(dt, 1)
    @test sort_indicator(dt, 1) == TC_SORT_ASC
    @test sort_indicator(dt, 2) == ""

    sort_by!(dt, 1; dir = SortDir.DESCENDING)
    @test sort_indicator(dt, 1) == TC_SORT_DESC
    @test sort_indicator(dt, 2) == ""

    sort_by!(dt, 2)
    @test sort_indicator(dt, 1) == ""
    @test sort_indicator(dt, 2) == TC_SORT_ASC

    sort_by!(dt, 0)
    @test sort_indicator(dt, 1) == ""
    @test sort_indicator(dt, 2) == ""
end

@testitem "datatable: the indicator is in the column's last cell" begin
    using ManyUI
    rows = [("Bob", 30), ("Amy", 25)]
    cols = [Column("Name"; width = cells(6)), Column("Age";
                                                     width = cells(4))]
    dt = DataTable(rows, cols; key = (r, j) -> r[j])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 12, 4))
    buf = Buffer(12, 4)

    clear!(buf); render!(dt, buf)
    hdr = split(string(buf), '\n')[1]
    @test hdr == "Name   Age  "            # the gutter, blank

    sort_by!(dt, 1)
    clear!(buf); render!(dt, buf)
    r = split(string(buf), '\n')
    # Cell 6 IS the column's last cell -- xs[1] == 0, widths[1] == 6.
    @test r[1] == "Name ▲ Age  "
    @test buf[6, 1].content == TC_SORT_ASC
    @test r[2] == "Amy    25   "           # sorted: Amy before Bob
    @test r[3] == "Bob    30   "

    sort_by!(dt, 1; dir = SortDir.DESCENDING)
    clear!(buf); render!(dt, buf)
    r = split(string(buf), '\n')
    @test r[1] == "Name ▼ Age  "
    @test buf[6, 1].content == TC_SORT_DESC
    @test r[2] == "Bob    30   "

    sort_by!(dt, 2)                        # the indicator MOVES
    clear!(buf); render!(dt, buf)
    r = split(string(buf), '\n')
    # Column 2 owns cells 8:11 (xs[2] == 7, widths[2] == 4), so ITS last
    # cell is 11 -- not the frame's cell 12, which no column owns.
    @test r[1] == "Name   Age▲ "
    @test buf[11, 1].content == TC_SORT_ASC
    @test buf[6, 1].content == " "         # column 1's gutter, now blank
end

@testitem "datatable: the indicator is never truncated away" begin
    using ManyUI
    # APPENDING the indicator to the caption would truncate it away in a
    # narrow column -- so the ONE column whose state you must see is the
    # one that hides it. It is painted in the column's LAST cell instead.
    dt = DataTable([("x",)], [Column("LongHeader"; width = cells(5))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 5, 3))
    buf = Buffer(5, 3)

    clear!(buf); render!(dt, buf)
    @test split(string(buf), '\n')[1] == "Lon… "

    sort_by!(dt, 1)
    clear!(buf); render!(dt, buf)
    @test split(string(buf), '\n')[1] == "Lon…▲"
    @test buf[5, 1].content == TC_SORT_ASC

    sort_by!(dt, 1; dir = SortDir.DESCENDING)
    clear!(buf); render!(dt, buf)
    @test buf[5, 1].content == TC_SORT_DESC
end

@testitem "datatable: the indicator survives a 1-cell column" begin
    using ManyUI
    dt = DataTable([("x",)], [Column("Name"; width = cells(1))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 1, 2))
    buf = Buffer(1, 2)
    sort_by!(dt, 1)
    clear!(buf); render!(dt, buf)
    # One cell, one legible glyph, nothing halved: the caption has
    # nowhere to go and the indicator is what the cell is FOR.
    @test buf[1, 1].content == TC_SORT_ASC
end

@testitem "datatable: the gutter is reserved when unsorted" begin
    using ManyUI
    # "Names" is exactly 5 cells and the column is 5 cells. APPENDING
    # would render the caption WHOLE while unsorted and re-truncate it
    # the moment you sort -- the header would twitch. THE GUTTER IS
    # STABLE, THE INK IS NOT.
    dt = DataTable([("x",)], [Column("Names"; width = cells(5))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 5, 3))
    buf = Buffer(5, 3)

    clear!(buf); render!(dt, buf)
    unsorted = split(string(buf), '\n')[1]
    @test unsorted == "Nam… "

    sort_by!(dt, 1)
    clear!(buf); render!(dt, buf)
    sorted = split(string(buf), '\n')[1]
    @test sorted == "Nam…▲"

    # THE CAPTION CELLS ARE IDENTICAL. Only the gutter's ink changed.
    @test unsorted[1:(prevind(unsorted, lastindex(unsorted)) - 1)] ==
          sorted[1:(prevind(sorted, lastindex(sorted)) - 1)]
end

@testitem "datatable: a non-sortable column reserves no gutter" begin
    using ManyUI
    dt = DataTable([("x",)],
                   [Column("Names"; width = cells(5), sortable = false)];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 5, 3))
    buf = Buffer(5, 3)
    clear!(buf); render!(dt, buf)
    # No indicator can ever land here, so the caption gets every cell.
    @test split(string(buf), '\n')[1] == "Names"
end

@testitem "datatable: the header honours Align in the caption area" begin
    using ManyUI
    dt = DataTable([("x",)], [Column("Ab"; width = cells(6),
                                     align = Align.END)];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 3))
    buf = Buffer(6, 3)
    clear!(buf); render!(dt, buf)
    # END pushes the caption to the RIGHT of its 5-cell area; the gutter
    # is still cell 6.
    @test split(string(buf), '\n')[1] == "   Ab "
    sort_by!(dt, 1)
    clear!(buf); render!(dt, buf)
    @test split(string(buf), '\n')[1] == "   Ab▲"
end

@testitem "datatable: column widths do NOT change when you sort" begin
    using ManyUI
    # `_tc_auto!` samples SOURCE rows 1:sample, NEVER view rows, so a
    # width that moved under a sort is impossible by construction. A
    # table that reflows under the reader's eyes is a worse bug than a
    # truncated cell.
    rows = [("aaaaaaaa", 1), ("b", 22), ("cc", 333)]
    dt = DataTable(rows, [Column("N"), Column("V")];  # both AUTO
                   key = (r, j) -> r[j])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 24, 6))
    buf = Buffer(24, 6)
    clear!(buf); render!(dt, buf)
    before = copy(grid_of(dt).widths)
    xs = copy(grid_of(dt).xs)
    total = grid_of(dt).cache_total
    @test before[1] > 0

    for (j, d) in ((1, SortDir.ASCENDING), (1, SortDir.DESCENDING),
                   (2, SortDir.ASCENDING), (0, SortDir.NONE))
        sort_by!(dt, j; dir = d)
        clear!(buf); render!(dt, buf)
        @test grid_of(dt).widths == before
        @test grid_of(dt).xs == xs
        @test grid_of(dt).cache_total == total
        @test content_extent(dt).width == total
    end
end

# --- the mouse --------------------------------------------------------

@testitem "datatable: a header click sorts, a second toggles it" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(4))];
                   key = (r, j) -> r[1])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 4, 5))
    buf = Buffer(4, 5)
    clear!(buf); paint!(buf, root)          # the widths the user SAW

    press(x, y) = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, x, y,
                             MOD_NONE)
    @test dispatch_event!(root, press(1, 1))
    @test sort_column(dt) == 1
    @test sort_direction(dt) === SortDir.ASCENDING
    @test dt.order == [2, 3, 1]

    # Cycle: ASCENDING -> DESCENDING -> ASCENDING. There is NO click path
    # to NONE: a third state that looks identical to "sorted by whatever
    # it was before" is a state a user cannot see and cannot want.
    @test dispatch_event!(root, press(1, 1))
    @test sort_direction(dt) === SortDir.DESCENDING
    @test dt.order == [1, 3, 2]
    @test dispatch_event!(root, press(1, 1))
    @test sort_direction(dt) === SortDir.ASCENDING
    @test sort_column(dt) == 1
end

@testitem "datatable: a header click on a NEW column sorts ASCENDING" begin
    using ManyUI
    rows = [("c", 1), ("a", 3), ("b", 2)]
    dt = DataTable(rows, [Column("N"; width = cells(4)),
                          Column("V"; width = cells(4))];
                   key = (r, j) -> r[j])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 9, 5))
    buf = Buffer(9, 5)
    clear!(buf); paint!(buf, root)

    press(x, y) = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, x, y,
                             MOD_NONE)
    @test dispatch_event!(root, press(1, 1))
    @test sort_by!(dt, 1; dir = SortDir.DESCENDING)
    @test sort_direction(dt) === SortDir.DESCENDING
    # xs == [0, 5]; column 2 owns cells 6:9.
    @test dispatch_event!(root, press(6, 1))
    @test sort_column(dt) == 2
    @test sort_direction(dt) === SortDir.ASCENDING   # a NEW column: ASC
end

@testitem "datatable: a header click on a non-sortable column no-ops" begin
    using ManyUI
    rows = [("c",), ("a",)]
    dt = DataTable(rows, [Column("X"; width = cells(4),
                                 sortable = false)];
                   key = (r, j) -> r[1])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 4, 5))
    buf = Buffer(4, 5)
    clear!(buf); paint!(buf, root)

    e = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 1, 1, MOD_NONE)
    # Consumes nothing and does nothing -- and does NOT throw, which is
    # what `sort_by!` would do on the same column.
    @test !dispatch_event!(root, e)
    @test sort_column(dt) == 0
    @test dt.order == [1, 2]
end

@testitem "datatable: a body click selects and does not sort" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(4))];
                   key = (r, j) -> r[1])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 4, 5))
    buf = Buffer(4, 5)
    clear!(buf); paint!(buf, root)

    press(x, y) = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, x, y,
                             MOD_NONE)
    @test dispatch_event!(root, press(1, 2))    # y=2 is the FIRST body row
    @test sort_column(dt) == 0                  # NOT a sort
    @test row_cursor(dt) == 1
    @test selected_rows(dt) == [1]

    @test dispatch_event!(root, press(1, 3))
    @test row_cursor(dt) == 2
    @test selected_rows(dt) == [2]
    @test sort_column(dt) == 0
    @test dt.order == [1, 2, 3]
end

@testitem "datatable: a body click after a sort selects by position" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(4))];
                   key = (r, j) -> r[1])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 4, 5))
    buf = Buffer(4, 5)
    clear!(buf); paint!(buf, root)
    sort_by!(dt, 1)                             # view: a(2), b(3), c(1)

    e = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 1, 2, MOD_NONE)
    @test dispatch_event!(root, e)
    # VIEW row 1 is "a", whose SOURCE index is 2.
    @test row_cursor(dt) == 2
    @test selected_rows(dt) == [2]
    @test rows[only(selected_rows(dt))] == ("a",)
end

@testitem "datatable: a header click before the first paint no-ops" begin
    using ManyUI
    rows = [("c",), ("a",)]
    dt = DataTable(rows, [Column("X"; width = cells(4))];
                   key = (r, j) -> r[1])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    # NO layout!, so there is no content box and no header the user could
    # have seen. A click on a header that was never drawn does nothing --
    # which is correct: there was no header to click.
    @test grid_of(dt).widths == [0]
    e = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 1, 1, MOD_NONE)
    @test !dispatch_event!(root, e)
    @test sort_column(dt) == 0
end

@testitem "datatable: the wheel still scrolls over the header" begin
    using ManyUI
    rows = [(i,) for i in 1:100]
    dt = DataTable(rows, [Column("N"; width = cells(4))];
                   key = (r, j) -> r[1])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 6, 8))
    buf = Buffer(6, 8)
    clear!(buf); paint!(buf, root)

    # The header branch takes LEFT PRESSes only: a wheel notch over the
    # header must still reach `_tc_mouse!`.
    e = MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_DOWN, 1, 1,
                   MOD_NONE)
    @test dispatch_event!(root, e)
    @test scroll_of(dt).y == 3
    @test sort_column(dt) == 0
end

@testitem "datatable: a header click with padding hits the right col" begin
    using ManyUI
    # `_tc_local` measures from the CONTENT box, so padding and a border
    # shift the header without moving the column under the pointer.
    # `local_offset` -- measured from the UNSHIFTED BORDER box -- would
    # be off by the padding here and by the scroll offset inside a pane.
    rows = [("c", 1), ("a", 3), ("b", 2)]
    dt = DataTable(rows, [Column("N"; width = cells(4)),
                          Column("V"; width = cells(4))];
                   key = (r, j) -> r[j])
    dt.node.inline_box = BoxPatch(; padding = Spacing(1))
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 11, 7))
    buf = Buffer(11, 7)
    clear!(buf); paint!(buf, root)
    @test layout_of(dt).content == Region(2, 2, 9, 5)

    press(x, y) = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, x, y,
                             MOD_NONE)
    @test !dispatch_event!(root, press(1, 1))   # the padding, not a header
    @test sort_column(dt) == 0
    # Content cell (1,1) is SCREEN cell (2,2): column 1's header.
    @test dispatch_event!(root, press(2, 2))
    @test sort_column(dt) == 1
    # Content x 6 -> column 2 (xs == [0, 5]) -> SCREEN x 7.
    @test dispatch_event!(root, press(7, 2))
    @test sort_column(dt) == 2
end

@testitem "datatable: a header click follows a horizontal scroll" begin
    using ManyUI
    # THE HEADER FOLLOWS THE COLUMNS HORIZONTALLY, so the hit test must
    # too: `_tc_col_at` reads `scroll_of(w).x`, and without it every
    # click past a scroll would sort the column to its left.
    rows = [("c", 1, "z"), ("a", 3, "y")]
    dt = DataTable(rows, [Column("N"; width = cells(4)),
                          Column("V"; width = cells(4)),
                          Column("W"; width = cells(4))];
                   key = (r, j) -> r[j])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 6, 5))
    buf = Buffer(6, 5)
    clear!(buf); paint!(buf, root)
    @test grid_of(dt).xs == [0, 5, 10]

    press(x, y) = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, x, y,
                             MOD_NONE)
    @test dispatch_event!(root, press(1, 1))    # column 1 at x = 1
    @test sort_column(dt) == 1

    @test scroll_to!(dt, Offset(5, 0)) === Offset(5, 0)
    clear!(buf); paint!(buf, root)
    # Column 2 (content cells 6:9) is now painted AT screen x 1.
    @test dispatch_event!(root, press(1, 1))
    @test sort_column(dt) == 2
end

# --- the O(window) contract -------------------------------------------

@testitem "datatable: paint after a sort is still O(window)" begin
    using ManyUI
    hits = Ref(0)
    rows = [(i, -i) for i in 1:100_000]
    cols = [Column("A"; width = cells(8)), Column("B"; width = cells(8))]
    dt = DataTable(rows, cols; key = (r, j) -> r[j],
                   cell = (r, j) -> (hits[] += 1; string(r[j])))
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 20, 24))
    buf = Buffer(20, 24)

    sort_by!(dt, 2)                         # reverse: the view is upside
    hits[] = 0                              # down, the paint is not
    clear!(buf); paint!(buf, root)
    # 24 rows less the header, x 2 visible columns. Painting a SORTED
    # table costs the same as painting an unsorted one.
    @test hits[] <= 23 * 2
    @test hits[] > 0

    hits[] = 0
    @test content_extent(dt).height == 100_001   # 100 000 + the header
    @test max_scroll(dt).y == 100_001 - 24
    @test hits[] == 0                       # the extent NEVER reads a row
end

@testitem "datatable: a 100 000-row sort never touches the frame" begin
    using ManyUI
    kh = Ref(0)
    ch = Ref(0)
    rows = [(i,) for i in 100_000:-1:1]
    dt = DataTable(rows, [Column("N"; width = cells(8))];
                   key = (r, j) -> (kh[] += 1; r[1]),
                   cell = (r, j) -> (ch[] += 1; string(r[1])))
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 10, 12))
    buf = Buffer(10, 12)

    kh[] = 0
    ch[] = 0
    sort_by!(dt, 1)
    # O(n) key materialisation ONCE -- and NOT ONE cell call: a sort
    # never renders.
    @test kh[] == 100_000
    @test ch[] == 0

    kh[] = 0
    ch[] = 0
    clear!(buf); paint!(buf, root)
    @test kh[] == 0                         # `key` is NEVER a frame
    @test ch[] <= 11                        # the WINDOW, never the data
    @test rows[dt.order[1]] == (1,)         # and it really is sorted
end

@testitem "datatable: a row is not a widget, at ANY size" begin
    using ManyUI
    # THE RULE THE WHOLE TIER RESTS ON, MEASURED rather than assumed: a
    # row is an element of a Vector and ZERO WidgetNodes. A `DataTable`
    # has a header, a grid painter AND a sort -- all three are data or
    # paint, none is a child widget -- so this is where a row-widget
    # regression lands first.
    #
    # `descendants` is the instrument the rule names, at TWO sizes
    # 10 000x apart: ONE size is a point and cannot show that the node
    # count does not GROW with the data.
    small = DataTable([(i, "r$i") for i in 1:10],
                      [Column("A"; width = cells(4)),
                       Column("B"; width = cells(4))];
                      key = (r, j) -> r[j])
    big = DataTable([(i, "r$i") for i in 1:100_000],
                    [Column("A"; width = cells(4)),
                     Column("B"; width = cells(4))];
                    key = (r, j) -> r[j], mode = SelectMode.MULTI)
    @test isempty(descendants(small))
    @test isempty(descendants(big))
    @test length(descendants(big)) == length(descendants(small))
    @test isempty(children(big))
    @test length(focusable_widgets(small)) == 1
    @test length(focusable_widgets(big)) == 1

    # STILL flat after a REAL frame -- header included.
    apply_stylesheet!(STYLESHEET_EMPTY, big)
    layout!(big, Region(1, 1, 20, 24))
    buf = Buffer(20, 24)
    clear!(buf)
    paint!(buf, big)
    @test isempty(descendants(big))

    # A SORT permutes `order`, an O(n) Vector of Int -- it does not
    # build a row. 100 000 rows reordered, still ZERO nodes.
    sort_by!(big, 1; dir = SortDir.DESCENDING)
    @test isempty(descendants(big))
    clear!(buf)
    paint!(buf, big)
    @test isempty(descendants(big))
    @test length(big.order) == 100_000    # the permutation, not widgets

    # And flat after selecting every row: a selection is a set of source
    # indices, never a widget per selected row.
    select_all!(big)
    @test n_selected(big) == 100_000
    @test isempty(descendants(big))
    @test length(focusable_widgets(big)) == 1

    # The instrument is LIVE, not vacuous: `descendants` DOES count real
    # children. Without this control a `descendants` that always
    # returned `[]` would satisfy every assertion above.
    @test !isempty(descendants(Scrollpane(
        DataTable([(1,)], [Column("A")]; key = (r, j) -> r[j]))))
end

@testitem "datatable: sort_by! calls key exactly n times" begin
    using ManyUI
    hits = Ref(0)
    rows = [(x,) for x in [5, 3, 9, 1, 3, 7, 3, 2, 8, 4]]
    dt = DataTable(rows, [Column("K"; width = cells(3))];
                   key = (r, j) -> (hits[] += 1; r[1]))
    hits[] = 0
    sort_by!(dt, 1)
    # MATERIALIZING the keys first IS THE ALGORITHM, not an optimisation:
    # `sort!(order; by = i -> key(rows[i], j))` runs `by` TWICE PER
    # COMPARISON -- ~9x more calls -- because `Base.Order.By` has no
    # Schwartzian transform.
    @test hits[] == length(rows)

    hits[] = 0
    sort_by!(dt, 1; dir = SortDir.DESCENDING)
    @test hits[] == length(rows)

    hits[] = 0
    sort_by!(dt, 0)                         # source order reads NO key
    @test hits[] == 0
end

@testitem "datatable: over-scroll paints blanks, never a BoundsError" begin
    using ManyUI
    dt = DataTable([("x",), ("y",)], [Column("N"; width = cells(3))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 3, 3))
    sort_by!(dt, 1)
    buf = Buffer(3, 3)
    for o in (Offset(0, 99), Offset(99, 0), Offset(0, typemax(Int)),
              Offset(typemax(Int), 0))
        set_scroll!(dt, o)                  # BYPASSING scroll_to!
        clear!(buf)
        @test render!(dt, buf) === nothing
    end
end

# --- the scrollable seam ----------------------------------------------

@testitem "datatable: Scrollbar{DataTable} needs ZERO new scroll code" begin
    using ManyUI
    rows = [(i,) for i in 1:20]
    dt = DataTable(rows, [Column("N"; width = cells(4))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 5))
    # The scrollable seam is THREE functions, not a type: the override of
    # `content_extent` is the whole integration.
    @test content_extent(dt) == Size(4, 21)      # 20 rows + 1 header row
    @test layout_of(dt).content.height == 5
    @test scroll_of(dt) === ORIGIN

    sb = Scrollbar(dt, ScrollAxis.VERTICAL)
    @test sb isa Scrollbar{<:DataTable}
    @test sb.viewport === dt
    @test sb.axis === ScrollAxis.VERTICAL

    sort_by!(dt, 1; dir = SortDir.DESCENDING)
    @test content_extent(dt) == Size(4, 21)      # a sort is not a resize
    @test max_scroll(dt) === Offset(0, 16)
end

@testitem "datatable: Scrollpane(DataTable(...)) composes" begin
    using ManyUI
    rows = [(i,) for i in 1:20]
    dt = DataTable(rows, [Column("N"; width = cells(4))];
                   key = (r, j) -> r[1])
    inner = Container(dt; id = :inner)
    pane = Scrollpane(inner; id = :pane)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 8, 6))
    buf = Buffer(8, 6)
    clear!(buf)
    paint!(buf, pane)
    # `measure(::DataTable, avail) == avail`, so the holder is exactly
    # canvas-sized, nothing overflows, and the PANE does no scrolling --
    # the table does it all. The two mechanisms compose rather than
    # compete.
    @test max_scroll(pane) === ORIGIN
    @test max_scroll(dt).y > 0
end

@testitem "datatable: content_extent counts the header rows" begin
    using ManyUI
    for (sh, ru, hh) in ((true, false, 1), (true, true, 2),
                         (false, false, 0), (false, true, 0))
        dt = DataTable([(i,) for i in 1:7],
                       [Column("N"; width = cells(4))];
                       key = (r, j) -> r[1], show_header = sh, rule = ru)
        apply_stylesheet!(STYLESHEET_EMPTY, dt)
        layout!(dt, Region(1, 1, 6, 5))
        @test content_extent(dt).height == view_count(dt) + hh
        @test content_extent(dt).height == 7 + hh
        sort_by!(dt, 1; dir = SortDir.DESCENDING)
        @test content_extent(dt).height == 7 + hh
    end
end

@testitem "datatable: END lands the last row on the last window row" begin
    using ManyUI
    # `content_extent`'s `+ hh` and `_tc_follow_cursor!`'s `- hh` are the
    # same fact stated twice. If they ever drift, this fails.
    dt = DataTable([(i,) for i in 1:100],
                   [Column("N"; width = cells(4))];
                   key = (r, j) -> -r[1], show_header = true, rule = true)
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 20, 12))
    move_cursor!(dt, typemax(Int) ÷ 2)
    @test row_cursor(dt) == 100
    @test scroll_of(dt).y == max_scroll(dt).y

    sort_by!(dt, 1)                          # the view is now reversed
    @test row_cursor(dt) == 100              # the ROW did not move
    @test view_rank(dt, 100) == 1            # it is now the FIRST view row
    @test scroll_of(dt).y == 0
    move_cursor!(dt, typemax(Int) ÷ 2)
    @test view_rank(dt, row_cursor(dt)) == 100
    @test scroll_of(dt).y == max_scroll(dt).y
end

# --- data ops ---------------------------------------------------------

@testitem "datatable: push_row! reapplies the current sort" begin
    using ManyUI
    rows = [("c",), ("a",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 6))
    sort_by!(dt, 1)
    @test dt.order == [2, 1]

    push_row!(dt, ("b",))
    @test rows == [("c",), ("a",), ("b",)]   # APPENDED to the SOURCE
    @test row_count(dt) == 3
    @test view_count(dt) == 3
    @test dt.order == [2, 3, 1]              # a, b, c: the sort REAPPLIED
    @test dt.rank == [3, 1, 2]
    @test n_rows(selection_of(dt)) == 3

    # Unsorted, a push just appends to the view.
    sort_by!(dt, 0)
    push_row!(dt, ("z",))
    @test dt.order == [1, 2, 3, 4]
end

@testitem "datatable: insert_row! reindexes and reapplies the sort" begin
    using ManyUI
    rows = [("c",), ("a",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1], mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 6))
    select_only!(dt, 2)                      # VIEW 2 == source 2 == "a"
    @test selected_rows(dt) == [2]
    sort_by!(dt, 1)

    insert_row!(dt, 1, ("b",))               # at SOURCE index 1
    @test rows == [("b",), ("c",), ("a",)]
    # Source indices are structurally safe against REORDERING; they are
    # NOT safe against insertion, and this is the price -- paid by the
    # mutation rather than by the frame.
    @test selected_rows(dt) == [3]           # "a" moved 2 -> 3
    @test rows[only(selected_rows(dt))] == ("a",)
    @test dt.order == [3, 1, 2]              # a, b, c: still sorted
    @test row_count(dt) == 3
end

@testitem "datatable: delete_row! reindexes and rebuilds rank" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1], mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 6))
    sort_by!(dt, 1)
    select_only!(dt, 3)                      # VIEW 3 == source 1 == "c"
    @test selected_rows(dt) == [1]

    @test !delete_row!(dt, 0)
    @test !delete_row!(dt, 99)
    @test delete_row!(dt, 2)                 # drop "a" at SOURCE index 2
    @test rows == [("c",), ("b",)]
    @test selected_rows(dt) == [1]           # "c" is still source 1
    @test row_count(dt) == 2
    @test view_count(dt) == 2
    @test length(dt.rank) == 2
    @test dt.order == [2, 1]                 # b, c: the sort REAPPLIED
    for k in 1:2
        @test dt.rank[dt.order[k]] == k
    end

    @test delete_row!(dt, 1)                 # drop the SELECTED row
    @test !is_selected(dt, 1)
    @test row_count(dt) == 1
    @test dt.order == [1]
    @test row_cursor(dt) == 1
end

@testitem "datatable: set_rows! clears the selection and the scroll" begin
    using ManyUI
    rows = [(i,) for i in 1:50]
    dt = DataTable(rows, [Column("N"; width = cells(4))];
                   key = (r, j) -> -r[1], mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 8, 10))
    sort_by!(dt, 1)
    select_only!(dt, 40)
    move_cursor!(dt, 20)
    @test scroll_of(dt).y > 0
    @test !isempty(selected_rows(dt))

    set_rows!(dt, [(9,), (7,), (8,)])
    # Every index the selection held names a row that may no longer
    # exist, and silently keeping them would select the WRONG ROWS.
    @test selected_rows(dt) == Int[]
    @test n_selected(dt) == 0
    @test row_count(dt) == 3
    @test view_count(dt) == 3
    @test scroll_of(dt) === ORIGIN
    @test rows == [(9,), (7,), (8,)]         # ALIASED: the SAME vector
    @test dt.rows === rows
    # The sort is REAPPLIED to the new data: key = -x, so DESCENDING by
    # value -> 9, 8, 7.
    @test sort_column(dt) == 1
    @test [rows[i][1] for i in dt.order] == [9, 8, 7]
    @test row_cursor(dt) == view_source(dt, 1)   # the VIEW's first row
    @test length(dt.rank) == 3

    set_rows!(dt, Tuple{Int}[])              # to nothing at all
    @test row_count(dt) == 0
    @test row_cursor(dt) == 0
    @test isempty(dt.order)
end

@testitem "datatable: refresh_rows! is the escape hatch" begin
    using ManyUI
    rows = [("c",), ("a",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 6))
    sort_by!(dt, 1)

    push!(rows, ("b",))                      # behind `version`'s back
    # STALENESS, never corruption: `_tc_sync!` keeps every index in range
    # at the next frame even without the call.
    buf = Buffer(6, 6)
    clear!(buf)
    @test render!(dt, buf) === nothing
    @test n_rows(selection_of(dt)) == 3

    refresh_rows!(dt)                        # the cure
    @test view_count(dt) == 3
    @test dt.order == [2, 3, 1]              # the sort REAPPLIED
    @test dt.rank == [3, 1, 2]
end

@testitem "datatable: a data change is a PAINT mark and nothing more" begin
    using ManyUI
    dt = DataTable([("c",), ("a",)], [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    root = Container(dt; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 6, 6))
    clean!(root)

    # `measure(::DataTable, avail) == avail` is what licenses PAINT: a
    # data change PROVABLY cannot move a box, so a sort on 100 000 rows
    # costs ZERO layout.
    sort_by!(dt, 1)
    @test dirty_root(root) === nothing
    @test is_dirty(dt, Dirty.PAINT)

    clean!(root)
    push_row!(dt, ("b",))
    @test dirty_root(root) === nothing
    @test is_dirty(dt, Dirty.PAINT)
end

@testitem "datatable: refresh_extent! is the exact rescan" begin
    using ManyUI
    # AUTO measures the header and SOURCE rows 1:sample, and NOTHING
    # else, ever -- unless you call this and pay for it. It is the ONLY
    # thing that can make an AUTO column NARROWER.
    rows = [("aaaaaaaaaa",), ("b",)]
    dt = DataTable(rows, [Column("N")];      # AUTO
                   key = (r, j) -> r[1], sample = 1)
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 20, 6))
    wide = refresh_extent!(dt)
    @test wide.width == 10                   # the long row, measured
    @test wide == content_extent(dt)

    @test delete_row!(dt, 1)                 # drop the widest row
    @test content_extent(dt).width == 10     # STILL too wide: monotone
    narrow = refresh_extent!(dt)
    # Only this can narrow it -- and only to the SEED, which is the
    # header "N" plus the sort gutter and is the column's FLOOR. The one
    # remaining cell ("b") is narrower than its own caption.
    @test narrow.width == 2
    @test content_extent(dt).width == 2
    @test grid_of(dt).autos[1] == 2
end

@testitem "datatable: set_columns! resets a sort on a gone column" begin
    using ManyUI
    rows = [("c", 1), ("a", 3), ("b", 2)]
    dt = DataTable(rows, [Column("N"; width = cells(4)),
                          Column("V"; width = cells(4))];
                   key = (r, j) -> r[j])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 12, 6))
    sort_by!(dt, 2)
    @test sort_column(dt) == 2
    @test dt.order == [1, 3, 2]

    set_columns!(dt, [Column("N"; width = cells(4))])
    # Column 2 no longer exists, so the sort has nothing to be about.
    @test length(grid_of(dt).cols) == 1
    @test length(grid_of(dt).widths) == 1
    @test length(grid_of(dt).xs) == 1
    @test length(grid_of(dt).autos) == 1
    @test sort_column(dt) == 0
    @test sort_direction(dt) === SortDir.NONE
    @test dt.order == [1, 2, 3]              # back to SOURCE order
    @test dt.rank == [1, 2, 3]

    # A surviving sorted column KEEPS its sort.
    sort_by!(dt, 1)
    keep = copy(dt.order)
    set_columns!(dt, [Column("N"; width = cells(6))])
    @test sort_column(dt) == 1
    @test dt.order == keep
end

@testitem "datatable: set_columns! resets an unsortable sort" begin
    using ManyUI
    rows = [("c",), ("a",)]
    dt = DataTable(rows, [Column("N"; width = cells(4))];
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 6, 6))
    sort_by!(dt, 1)
    @test sort_column(dt) == 1

    set_columns!(dt, [Column("N"; width = cells(4), sortable = false)])
    @test sort_column(dt) == 0
    @test sort_direction(dt) === SortDir.NONE
    @test dt.order == [1, 2]
end

@testitem "datatable: refresh_columns! re-seeds the AUTO marks" begin
    using ManyUI
    dt = DataTable([("x",)], [Column("N")];  # AUTO
                   key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 20, 6))
    @test grid_of(dt).autos[1] == 2          # "N" + the sort gutter

    # A column is a SPEC: changing one is a write plus a refresh.
    grid_of(dt).cols[1] = Column("LongerName")
    refresh_columns!(dt)
    @test grid_of(dt).autos[1] == 10 + 1     # the caption + the gutter
    @test grid_of(dt).cache_version == -1    # the memo, invalidated
end

@testitem "datatable: refresh_columns! keeps a neighbour's width" begin
    using ManyUI
    # `_tc_auto_reset!` LOWERS every AUTO mark to its header seed, so a
    # refresh that stopped there would collapse every AUTO column to its
    # own caption: re-spec ONE column and its NEIGHBOURS silently shrink
    # to header width. Re-seeding measures the sample too, exactly as at
    # construction -- the `Table` twin's rule (widgets_table_tests.jl
    # "set_columns! resizes ... and re-seeds"), and DataTable's own rule
    # at construction and at `set_rows!`.
    dt = DataTable([(1, "Bartholomew Fitzgerald")],
                   [Column("ID"), Column("Name")];   # both AUTO
                   key = r -> r[1],
                   cell = (r, j) -> j == 1 ? string(r[1]) : r[2])
    apply_stylesheet!(STYLESHEET_EMPTY, dt)
    layout!(dt, Region(1, 1, 60, 6))
    # Column 1: "ID" (2) + the sort gutter. Column 2: the DATA width,
    # which already exceeds its header seed of "Name" (4) + gutter.
    @test grid_of(dt).autos == [3, 22]

    # Re-spec column 1 ALONE: only its alignment moves. Column 2 is not
    # touched and MUST NOT move.
    grid_of(dt).cols[1] = Column("ID"; align = Align.END)
    refresh_columns!(dt)
    @test grid_of(dt).autos[2] == 22     # the neighbour, unharmed
    @test grid_of(dt).autos[1] == 3
    @test grid_of(dt).cache_version == -1
end

@testitem "datatable: AUTO seeds the sort gutter" begin
    using ManyUI
    # 1 for a `sortable` column: the indicator needs a cell to live in,
    # and an AUTO column sized to its header text ALONE would have
    # nowhere to draw it.
    a = DataTable([("x",)], [Column("Name")]; key = (r, j) -> r[1])
    b = DataTable([("x",)],
                  [Column("Name"; sortable = false)];
                  key = (r, j) -> r[1])
    apply_stylesheet!(STYLESHEET_EMPTY, a)
    apply_stylesheet!(STYLESHEET_EMPTY, b)
    layout!(a, Region(1, 1, 20, 4))
    layout!(b, Region(1, 1, 20, 4))
    @test grid_of(a).autos[1] == 5           # "Name" + 1
    @test grid_of(b).autos[1] == 4           # "Name"
end

@testitem "datatable: the seam answers every RowsWidget question" begin
    using ManyUI
    rows = [("c",), ("a",), ("b",)]
    dt = DataTable(rows, [Column("X"; width = cells(3))];
                   key = (r, j) -> r[1])
    @test selection_of(dt) === dt.sel
    @test grid_of(dt) === dt.grid
    @test select_mode(dt) === SelectMode.SINGLE
    @test !is_focused(dt)
    on_focus!(dt)
    @test is_focused(dt)
    on_blur!(dt)
    @test !is_focused(dt)
    @test measure(dt, Size(9, 4)) == Size(9, 4)

    sort_by!(dt, 1)
    @test view_source(dt, 1) == 2
    @test source_index(dt, 1) == 2
    @test view_rank(dt, 2) == 1
    @test view_count(dt) == 3
    @test row_count(dt) == 3
end
