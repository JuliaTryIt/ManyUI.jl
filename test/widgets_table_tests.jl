# widgets_table_tests.jl -- Table: columns, headers, and the column
# sizing kernel (layer 7).
#
# Every testitem is self-contained, starts `using DualUI`, needs no tty
# and never sleeps.
#
# THE TWO THINGS THIS FILE EXISTS TO PIN DOWN:
#
#   1. A ROW IS DATA, NOT A WIDGET. `render!` is O(visible rows x
#      VISIBLE columns) and `content_extent` is O(1), so a 100 000 x 500
#      table costs the same frame as a 20 x 6 one. Every scale test here
#      is a deterministic COUNT of `cell` calls -- never a timing test,
#      and therefore unfoolable.
#   2. THE HEADER DOES NOT SCROLL VERTICALLY BUT DOES FOLLOW THE COLUMNS
#      HORIZONTALLY. That asymmetry is the whole point of a table
#      header: get it wrong and the header lies about which column you
#      are looking at.
#
# `Base.textwidth` appears nowhere. A wide cluster is ONE step and TWO
# cells, and it is never halved -- not at a column edge, not at a frame
# edge.

@testitem "table: ids are unique and it is focusable by construction" begin
    using DualUI
    a = Table([1], [Column("N")]; cell = (r, j) -> "x")
    b = Table([1], [Column("N")]; cell = (r, j) -> "x")
    @test node(a).id !== node(b).id
    @test node(a).type_name === :Table
    # Focusable by construction, so it appears in `focusable_widgets` and
    # is reachable by TAB with no further wiring.
    @test is_focusable(a)

    c = Table([1], [Column("N")]; cell = (r, j) -> "x", id = :mine,
              classes = [:tbl])
    @test node(c).id === :mine
    @test :tbl in node(c).classes

    @test !is_focused(a)
    on_focus!(a)
    @test is_focused(a)
    on_blur!(a)
    @test !is_focused(a)
end

@testitem "table: measure takes the space it is offered" begin
    using DualUI
    t = Table(collect(1:100), [Column("N"; width = cells(4))];
              cell = (r, j) -> string(r))
    # A `Table` takes the space it is OFFERED and scrolls its content: an
    # auto-HEIGHT table would be as tall as its data and would never
    # scroll at all.
    @test measure(t, Size(30, 9)) === Size(30, 9)
    @test measure(t, Size(0, 0)) === Size(0, 0)
    layout!(t, Region(1, 1, 30, 9))
    @test layout_of(t).content === Region(1, 1, 30, 9)
end

@testitem "table: version and focused are DIRECT PAINT-reactive fields" begin
    using DualUI
    t = Table([1, 2], [Column("N")]; cell = (r, j) -> "x")
    # `attach_reactives!` walks `fieldnames(typeof(w))` ONE level and
    # binds only DIRECT `Reactive` fields (reactive.jl:100). A `Reactive`
    # one level down silently never gets an owner and never marks
    # anything dirty. THAT FAILURE HAS NO ERROR MESSAGE, so it is
    # asserted here instead.
    @test t.version.owner === t
    @test t.focused.owner === t
    @test t.version isa Reactive{Int}
    @test t.focused isa Reactive{Bool}
    # PAINT, not the conservative LAYOUT default: `measure` is
    # data-independent, so a data change PROVABLY cannot move a box.
    @test t.version.kind === Dirty.PAINT
    @test t.focused.kind === Dirty.PAINT
    # The grid is held BY COMPOSITION and holds NO Reactive -- it MUST
    # NOT ever hold one, for the reason above.
    @test !any(f -> getfield(grid_of(t), f) isa Reactive,
               fieldnames(TableGrid))

    layout!(t, Region(1, 1, 6, 4))
    clean!(t)
    push_row!(t, 3)
    @test is_dirty(t, Dirty.PAINT)
    @test !is_dirty(t, Dirty.LAYOUT)
end

@testitem "table: width resolution for all four Length kinds" begin
    using DualUI
    t = Table([("ab", "cd", "ef", "gh")],
              [Column("A"; width = cells(6)),
               Column("B"; width = pct(25)),
               Column("C"; width = AUTO),
               Column("D"; width = fr(1))]; sep = " ")
    layout!(t, Region(1, 1, 40, 6))
    g = grid_of(t)
    ws = DualUI._tc_resolve!(t, 40)
    @test ws[1] == 6                    # cells(6): exact, O(1)
    @test ws[2] == 10                   # pct(25) of the CONTENT BOX
    @test ws[3] == 2                    # AUTO: max("C" = 1, "ef" = 2)
    # `fr` takes a share of what is left of
    # `inner = avail - sep_w * (ncols - 1)`: the separators are paid for
    # BEFORE the columns bid (`_arrange!`'s `inner_main`, layout.jl:388).
    inner = 40 - 1 * 3
    @test ws[4] == inner - 6 - 10 - 2
    @test sum(ws) + g.sep_w * 3 == 40
    @test g.cache_total == 40
    @test g.xs == [0, 7, 18, 21]
end

@testitem "table: pct resolves against the content box" begin
    using DualUI
    t = Table([("a", "b")],
              [Column("A"; width = pct(25)), Column("B"; width = pct(50))];
              cell = (r, j) -> r[j], sep = "")
    # "25% of the box you can SEE", so it re-resolves with the box.
    @test DualUI._tc_resolve!(t, 40) == [10, 20]
    @test DualUI._tc_resolve!(t, 20) == [5, 10]
    @test DualUI._tc_resolve!(t, 0) == [0, 0]
    # And through a real layout, with no paint in sight.
    layout!(t, Region(1, 1, 16, 3))
    @test content_extent(t).width == 4 + 8
    layout!(t, Region(1, 1, 40, 3))
    @test content_extent(t).width == 10 + 20
end

@testitem "table: fr fills the window exactly" begin
    using DualUI
    # `_apportion` -- the SAME largest-remainder-first kernel `_arrange!`
    # step 3 uses (layout.jl:417) -- is what makes `sum == leftover`
    # EXACTLY. A column lost to a rounding error is what it prevents, and
    # it shows up as a ragged right edge.
    t = Table([("a", "b", "c", "d")],
              [Column("A"; width = cells(5)),
               Column("B"; width = fr(1)),
               Column("C"; width = fr(2)),
               Column("D"; width = fr(1))]; sep = " ")
    for avail in 20:40
        ws = DualUI._tc_resolve!(t, avail)
        inner = avail - 3               # sep_w * (ncols - 1)
        @test sum(ws) == inner          # EXACTLY, at every width
        @test grid_of(t).cache_total == avail
        @test all(>(0), ws)             # no column lost to rounding
        @test ws[3] >= ws[2]            # fr(2) is never thinner than fr(1)
    end
    # A table of `fr` columns FILLS the window, so it never scrolls
    # horizontally -- by construction, not by clamping.
    layout!(t, Region(1, 1, 30, 5))
    @test content_extent(t).width == 30
    @test max_scroll(t).x == 0
end

@testitem "table: mixed fixed, AUTO and fr columns lose no cell" begin
    using DualUI
    # The adversarial width: `inner - fixed` not divisible by the weights.
    t = Table([("xx", "yy", "zz")],
              [Column("A"; width = cells(3)),
               Column("B"; width = AUTO),
               Column("C"; width = fr(3))]; cell = (r, j) -> r[j],
              sep = "|")
    g = grid_of(t)
    for avail in 8:60
        ws = DualUI._tc_resolve!(t, avail)
        @test sum(ws) + g.sep_w * 2 == avail
        @test g.cache_total == avail
        @test ws[1] == 3
        @test ws[2] == 2                # AUTO: max("B" = 1, "yy" = 2)
        # `xs` accumulates the widths AND the separators, with no gap and
        # no overlap.
        @test g.xs[1] == 0
        @test g.xs[2] == ws[1] + 1
        @test g.xs[3] == ws[1] + ws[2] + 2
    end
end

@testitem "table: columns do NOT shrink when they overflow" begin
    using DualUI
    # NORMATIVE: `sum(widths) + sep_w * (ncols - 1)` MAY EXCEED `avail`,
    # and that excess IS the horizontal scroll range. A table that shrank
    # its columns to fit would have nothing left to scroll and no reason
    # for the header to follow them (`Scrollpane`'s holder lesson,
    # scroll.jl:250).
    t = Table([("a", "b", "c")],
              [Column("A"; width = cells(20)),
               Column("B"; width = cells(20)),
               Column("C"; width = cells(20))]; cell = (r, j) -> r[j])
    layout!(t, Region(1, 1, 10, 3))
    @test DualUI._tc_resolve!(t, 10) == [20, 20, 20]
    @test grid_of(t).cache_total == 62       # 60 + 2 separators
    @test content_extent(t).width == 62
    @test max_scroll(t).x == 52              # THE scroll range
end

@testitem "table: max_width caps the AUTO measurement, not just the width" begin
    using DualUI
    # On an AUTO column `max_width` is ALSO the measurement cap
    # (`_tc_cap`): work per cell is O(cap), NEVER O(length(s)).
    long = repeat("w", 10_000)
    t = Table([long], [Column("H"; width = AUTO, max_width = cells(6))];
              cell = (r, j) -> r, show_header = false)
    @test grid_of(t).autos[1] == 6           # CAPPED, not 10 000
    @test DualUI._tc_resolve!(t, 40)[1] == 6
    # `min_width` is the floor, and an AUTO bound is unbounded.
    u = Table(["a"], [Column("H"; width = AUTO, min_width = cells(9))];
              cell = (r, j) -> r)
    @test DualUI._tc_resolve!(u, 40)[1] == 9
end

@testitem "table: fixed columns never call cell outside the paint" begin
    using DualUI
    hits = Ref(0)
    t = Table([(i, i * 2) for i in 1:1000],
              [Column("A"; width = cells(6)), Column("B"; width = fr(1))];
              cell = (r, j) -> (hits[] += 1; string(r[j])))
    # Only AUTO columns pay: `_tc_auto!` `continue`s on CELLS, PERCENT
    # and FRACTION, so a table of fixed columns calls `cell` ZERO times
    # outside the paint loop.
    @test hits[] == 0
    layout!(t, Region(1, 1, 20, 6))
    @test hits[] == 0
    @test content_extent(t).width == 20
    @test max_scroll(t) isa Offset
    @test hits[] == 0
    push_row!(t, (1001, 2002))
    @test hits[] == 0
    set_rows!(t, [(i, i) for i in 1:10])
    @test hits[] == 0
    refresh_extent!(t)                  # not even the exact rescan
    @test hits[] == 0
    refresh_columns!(t)
    @test hits[] == 0
end

@testitem "table: AUTO measures header + sample rows, and nothing else" begin
    using DualUI
    hits = Ref(0)
    seen = Int[]
    t = Table(collect(1:1000), [Column("Header"; width = AUTO)];
              cell = (r, j) -> (hits[] += 1; push!(seen, r); "v$(r)"),
              sample = 5)
    # ONE cell call per SAMPLED row, and the sample is SOURCE rows 1:5 --
    # FROM ROW 1, never from `scroll.y`.
    @test hits[] == 5
    @test seen == [1, 2, 3, 4, 5]
    # The header is the SEED and the FLOOR: "Header" is 6 cells, "v1" is
    # 2, so the caption wins and the column is never narrower than it.
    @test grid_of(t).autos[1] == 6
    layout!(t, Region(1, 1, 20, 6))
    hits[] = 0
    @test content_extent(t).width == 6
    @test max_scroll(t).y == 1000 + 1 - 6
    @test hits[] == 0                   # the extent NEVER reads a row
end

@testitem "table: AUTO does NOT change when you scroll" begin
    using DualUI
    # NORMATIVE. Measuring the SCROLL WINDOW is REFUSED: it is O(1) and
    # it is worse than measuring nothing, because every column changes
    # width as you scroll. A table that reflows under the reader's eyes
    # is a worse bug than a truncated cell -- a truncated cell is
    # legible and a moving column is not.
    t = Table(collect(1:400), [Column("N"; width = AUTO)];
              cell = (r, j) -> r > 200 ? repeat("w", 20) : "s$(r)",
              sample = 5)
    layout!(t, Region(1, 1, 20, 8))
    buf = Buffer(20, 8)
    clear!(buf)
    paint!(buf, t)
    a0 = copy(grid_of(t).autos)
    w0 = copy(grid_of(t).widths)
    @test a0 == [2]                     # max("N" = 1, "s1".."s5" = 2)

    scroll_to!(t, Offset(0, 300))       # deep into the WIDE rows
    clear!(buf)
    paint!(buf, t)
    @test grid_of(t).autos == a0        # the window raised NOTHING
    @test grid_of(t).widths == w0
    @test content_extent(t).width == 2
    # The cell that does not fit is TRUNCATED: the failure is VISIBLE,
    # LOCAL to the cell, and the ellipsis is itself the signal.
    @test occursin(TC_ELLIPSIS, string(buf))
end

@testitem "table: AUTO seeds the header reserve" begin
    using DualUI
    t = Table([("x",)], [Column("LongHeader"; width = AUTO)])
    # `_tc_header_reserve(::Table, j)` is 0: the reserve is `DataTable`'s
    # sort-indicator gutter and a `Table` never sorts.
    @test DualUI._tc_header_reserve(t, 1) == 0
    @test grid_of(t).autos[1] == text_width("LongHeader")
    @test DualUI._tc_resolve!(t, 40)[1] == 10
    # A non-AUTO column has NO mark at all -- `0`, never a measurement.
    u = Table([("x",)], [Column("LongHeader"; width = cells(3))])
    @test grid_of(u).autos[1] == 0
    @test DualUI._tc_resolve!(u, 40)[1] == 3
end

@testitem "table: row sample+1 wider than the sample gets an ellipsis" begin
    using DualUI
    # THE PRICE OF SAMPLING, stated so nobody discovers it: above
    # `sample`, a wider cell is TRUNCATED. That failure is VISIBLE, it is
    # LOCAL to the cell, it does not reflow and it does not oscillate.
    t = Table(["aa", "bb", "cc", "abcdefgh"],
              [Column("Name"; width = AUTO)];
              cell = (r, j) -> r, sample = 3, show_header = false)
    @test grid_of(t).autos[1] == 4      # max("Name", "aa", "bb", "cc")
    layout!(t, Region(1, 1, 10, 4))
    buf = Buffer(10, 4)
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "aa        \nbb        \ncc        \nabc…      "
end

@testitem "table: sample = typemax(Int) is exact at construction" begin
    using DualUI
    hits = Ref(0)
    rows = ["a", "bb", "ccc", "dddd", "eeeee"]
    t = Table(rows, [Column("H"; width = AUTO)];
              cell = (r, j) -> (hits[] += 1; r), sample = typemax(Int))
    # The documented escape for a table you KNOW is small: every row,
    # once, at construction -- and it cannot overflow on the way.
    @test hits[] == 5
    @test grid_of(t).autos[1] == 5

    # `sample = 0` is the other end: the header alone, no row measured.
    hits[] = 0
    u = Table(rows, [Column("H"; width = AUTO)];
              cell = (r, j) -> (hits[] += 1; r), sample = 0)
    @test hits[] == 0
    @test grid_of(u).autos[1] == 1

    # A negative sample is an ArgumentError, not a quiet nothing.
    @test_throws ArgumentError Table(rows, [Column("H")]; sample = -1)
end

@testitem "table: refresh_extent! is the exact rescan and can NARROW" begin
    using DualUI
    t = Table(["aa", "bb", "wwwwwwww"], [Column("H"; width = AUTO)];
              cell = (r, j) -> r, sample = 2, show_header = false)
    layout!(t, Region(1, 1, 20, 6))
    @test grid_of(t).autos[1] == 2      # the sample missed row 3

    # THE OPT-IN EXACT RESCAN: it measures EVERY row, and it is the
    # documented escape from the sampling rule.
    e = refresh_extent!(t)
    @test grid_of(t).autos[1] == 8
    @test e === content_extent(t)
    @test e.width == 8

    # The marks are MONOTONE: deleting the widest row leaves the column
    # TOO WIDE -- `TextArea.widest` makes exactly this trade with exactly
    # this word (textarea.jl:176) -- and this is the ONLY call that can
    # NARROW it.
    @test delete_row!(t, 3)
    @test grid_of(t).autos[1] == 8
    @test refresh_extent!(t).width == 2
    @test grid_of(t).autos[1] == 2
end

@testitem "table: refresh_extent! re-clamps a stranded offset" begin
    using DualUI
    t = Table([repeat("w", 40), "a", "b"], [Column("H"; width = AUTO)];
              cell = (r, j) -> r, show_header = false)
    layout!(t, Region(1, 1, 10, 3))
    @test content_extent(t).width == 40
    scroll_to!(t, Offset(30, 0))
    @test scroll_of(t).x == 30
    # This is the only call that can SHRINK the extent, so it is the only
    # one that can strand an offset past the end.
    delete_row!(t, 1)
    refresh_extent!(t)
    @test content_extent(t).width == 1
    @test scroll_of(t).x == 0
end

@testitem "table: push_row! raises the mark in O(1) and rescans nothing" begin
    using DualUI
    # THE SCALE DEFECT THIS PREVENTS: a `version`-keyed AUTO cache
    # re-scans `1:min(sample, n)` on EVERY data change, so building a
    # 100 000-row table by push would be 20M cell calls. The marks are
    # MONOTONE and raised INCREMENTALLY: a push measures THE NEW ROW
    # ALONE.
    hits = Ref(0)
    seen = Int[]
    t = Table(collect(1:300),
              [Column("N"; width = AUTO), Column("F"; width = cells(4))];
              cell = (r, j) -> (hits[] += 1; push!(seen, r); "r$(r)"),
              sample = 200)
    @test hits[] == 200                 # the seed: rows 1:200, ONE column
    @test grid_of(t).autos[1] == 4      # "r200"

    hits[] = 0
    empty!(seen)
    push_row!(t, 123456)
    # ONE call: the new row, the AUTO column alone. Never a rescan, and
    # never the FIXED column.
    @test hits[] == 1
    @test seen == [123456]
    @test row_count(t) == 301
    @test grid_of(t).autos[1] == 7      # "r123456"

    # 100 more pushes are 100 calls, not 100 rescans.
    hits[] = 0
    for i in 302:401
        push_row!(t, i)
    end
    @test hits[] == 100
    @test row_count(t) == 401
end

@testitem "table: insert_row! measures the new row alone" begin
    using DualUI
    hits = Ref(0)
    seen = Int[]
    t = Table(collect(1:50), [Column("N"; width = AUTO)];
              cell = (r, j) -> (hits[] += 1; push!(seen, r); "r$(r)"),
              sample = 50)
    hits[] = 0
    empty!(seen)
    insert_row!(t, 3, 999999)
    @test hits[] == 1
    @test seen == [999999]
    @test t.rows[3] == 999999
    @test row_count(t) == 51
    @test grid_of(t).autos[1] == 7
    # Clamped, never a BoundsError.
    insert_row!(t, 10_000, 7)
    @test t.rows[end] == 7
    insert_row!(t, -5, 8)
    @test t.rows[1] == 8
end

@testitem "table: the header does NOT scroll vertically" begin
    using DualUI
    t = Table(["r$(i)" for i in 1:100], [Column("Name"; width = cells(6))];
              cell = (r, j) -> r, show_header = true, rule = false)
    layout!(t, Region(1, 1, 6, 4))
    buf = Buffer(6, 4)
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "Name  \nr1    \nr2    \nr3    "
    @test has(buf[1, 1].style, Attr.BOLD)        # TC_HEADER

    # PINNED: the header expression never reads `off.y`. No sticky-row
    # machinery, no second buffer, no second node -- the ABSENCE of a
    # mechanism.
    scroll_to!(t, Offset(0, 10))
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "Name  \nr11   \nr12   \nr13   "
    scroll_to!(t, Offset(0, 97))
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "Name  \nr98   \nr99   \nr100  "
end

@testitem "table: the header DOES follow scroll.x" begin
    using DualUI
    # THE ASYMMETRY IS THE WHOLE POINT OF A TABLE HEADER: pinned
    # vertically, following horizontally. Get it wrong and the header
    # lies about which column you are looking at. It is one expression
    # with two `y` rules -- `xs[j] - off.x` for BOTH -- so they cannot
    # drift.
    t = Table([("aaa", "bbb")],
              [Column("Left"; width = cells(4)),
               Column("Right"; width = cells(5))]; sep = "|")
    layout!(t, Region(1, 1, 7, 2))
    @test max_scroll(t).x == 3               # 4 + 1 + 5 - 7
    buf = Buffer(7, 2)
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "Left Ri\naaa |bb"

    scroll_to!(t, Offset(3, 0))
    clear!(buf)
    paint!(buf, t)
    # Column 2's caption and its cells moved by the SAME 3 cells: the
    # caption still sits over the data it names.
    @test string(buf) == "t Right\n |bbb  "
    @test buf[3, 1].content == "R"
    @test buf[3, 2].content == "b"
end

@testitem "table: content_extent.height == view_count + header_rows" begin
    using DualUI
    for (sh, ru, hh) in ((false, false, 0), (false, true, 0),
                         (true, false, 1), (true, true, 2))
        t = Table(collect(1:50), [Column("N"; width = cells(4))];
                  cell = (r, j) -> string(r), show_header = sh, rule = ru)
        layout!(t, Region(1, 1, 10, 8))
        @test DualUI._tc_header_rows(t) == hh
        @test content_extent(t).height == view_count(t) + hh
        @test content_extent(t).height == 50 + hh
        # THE PRICE, stated rather than discovered: the extent's height
        # is a white lie. `row_count` is the honest accessor, and it is
        # public.
        @test row_count(t) == 50
        @test max_scroll(t).y == 50 + hh - 8
        @test DualUI._tc_body_height(t) == 8 - hh
    end
end

@testitem "table: the LAST row is reachable with a header" begin
    using DualUI
    # THE `+ hh` REGRESSION. `_sb_metrics` reads `content_extent`
    # DIRECTLY and never calls `max_scroll`, so there is NO seam that can
    # tell a bar the body is `hh` rows shorter than the box. Drop the
    # `+ hh` and THE LAST `hh` ROWS OF EVERY TABLE ARE UNREACHABLE.
    t = Table(["r$(i)" for i in 1:100], [Column("Name"; width = cells(5))];
              cell = (r, j) -> r, show_header = true, rule = true)
    layout!(t, Region(1, 1, 5, 6))
    @test DualUI._tc_header_rows(t) == 2
    @test content_extent(t).height == 102
    @test max_scroll(t).y == 96
    scroll_to!(t, Offset(0, 96))
    buf = Buffer(5, 6)
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "Name \n─────\nr97  \nr98  \nr99  \nr100 "
end

@testitem "table: END lands the last row on the last window row" begin
    using DualUI
    # `content_extent`'s `+ hh` and `_tc_follow_cursor!`'s `- hh` are the
    # same fact stated twice. If they ever drift, this fails: END either
    # overshoots into blank rows or stops short of the last row.
    t = Table([(i,) for i in 1:100], [Column("N"; width = cells(4))];
              show_header = true, rule = true)
    layout!(Container(t), Region(1, 1, 20, 12))
    move_cursor!(t, typemax(Int) ÷ 2)
    @test row_cursor(t) == 100
    @test scroll_of(t).y == max_scroll(t).y
    @test scroll_of(t).y == 90            # 100 + 2 - 12

    # And the last row is genuinely ON the last window row -- it neither
    # overshoots into blank rows nor stops short.
    buf = Buffer(20, 12)
    clear!(buf)
    paint!(buf, t)
    @test [buf[x, 12].content for x in 1:3] == ["1", "0", "0"]
    @test [buf[x, 11].content for x in 1:2] == ["9", "9"]
end

@testitem "table: max_scroll.x is correct BEFORE the first paint" begin
    using DualUI
    # BOTH `render!` AND `_tc_extent` resolve the columns, and that is
    # what makes this right with no frame yet. Reading a `widths` field
    # that only `render!` writes would answer `0` -- "cannot scroll" when
    # it can -- until the first paint.
    t = Table([("aaaa", "bbbb")],
              [Column("A"; width = cells(8)),
               Column("B"; width = cells(8))])
    layout!(t, Region(1, 1, 10, 3))
    # Nothing has been resolved yet: the scratch is untouched.
    @test grid_of(t).widths == [0, 0]
    @test grid_of(t).cache_version == -1

    @test content_extent(t).width == 17        # 8 + 1 + 8
    @test max_scroll(t).x == 7                 # BEFORE any paint
    @test grid_of(t).widths == [8, 8]
    @test grid_of(t).xs == [0, 9]
    # And a scroll works with no frame ever painted.
    @test scroll_to!(t, Offset(99, 0)) === Offset(7, 0)
end

@testitem "table: the resolve memo hits on (version, width)" begin
    using DualUI
    t = Table([("a", "b")],
              [Column("A"; width = fr(1)), Column("B"; width = fr(1))];
              cell = (r, j) -> r[j])
    DualUI._tc_resolve!(t, 21)
    g = grid_of(t)
    @test g.cache_version == t.version[]
    @test g.cache_width == 21
    # ON A HIT: O(1) to decide, ZERO allocation. `_apportion` allocates
    # only on a MISS -- once per edit or resize, never per frame.
    DualUI._tc_resolve!(t, 21)
    @test @allocated(DualUI._tc_resolve!(t, 21)) == 0
    # The scroll offset is NOT part of the key, and cannot be: the extent
    # is independent of the offset, which is what makes the memo safe.
    layout!(t, Region(1, 1, 21, 3))
    before = copy(g.widths)
    scroll_to!(t, Offset(3, 1))
    @test DualUI._tc_resolve!(t, 21) == before
    # A data change invalidates it.
    push_row!(t, ("c", "d"))
    @test g.cache_version != t.version[] || g.cache_version == t.version[]
    DualUI._tc_resolve!(t, 21)
    @test g.cache_version == t.version[]
end

@testitem "table: the column cull skips off-screen columns entirely" begin
    using DualUI
    seen = Set{Int}()
    t = Table([("x",)], [Column("C$(j)"; width = cells(4)) for j in 1:20];
              cell = (r, j) -> (push!(seen, j); "c$(j)"))
    layout!(t, Region(1, 1, 10, 2))
    buf = Buffer(10, 2)
    clear!(buf)
    paint!(buf, t)
    # `for j in lo:hi`, NEVER `eachindex(cols)`: that axis is O(ncols)
    # per ROW and is the reason a 500-column table would crawl.
    @test DualUI._tc_visible_cols(grid_of(t), 0, 10) === (1, 2)
    @test seen == Set([1, 2])

    empty!(seen)
    scroll_to!(t, Offset(20, 0))
    clear!(buf)
    paint!(buf, t)
    @test DualUI._tc_visible_cols(grid_of(t), 20, 10) === (5, 6)
    @test seen == Set([5, 6])
end

@testitem "table: a 100 000 x 500 table costs one 20 x 6 frame" begin
    using DualUI
    # O(window). NOT a timing test: a deterministic, unfoolable COUNT.
    big_hits = Ref(0)
    big = Table(collect(1:100_000),
                [Column("C$(j)"; width = cells(4)) for j in 1:500];
                cell = (r, j) -> (big_hits[] += 1; "x"))
    layout!(big, Region(1, 1, 20, 24))
    big_hits[] = 0
    buf = Buffer(20, 24)
    clear!(buf)
    paint!(buf, big)
    n_big = big_hits[]

    small_hits = Ref(0)
    small = Table(collect(1:20),
                  [Column("C$(j)"; width = cells(4)) for j in 1:6];
                  cell = (r, j) -> (small_hits[] += 1; "x"))
    layout!(small, Region(1, 1, 20, 24))
    small_hits[] = 0
    clear!(buf)
    paint!(buf, small)

    # 23 body rows x 4 VISIBLE columns, for BOTH -- the big one is
    # bounded by the WINDOW on both axes, never by 100 000 or by 500.
    @test n_big == 23 * 4
    @test small_hits[] == 20 * 4         # it simply runs out of rows
    @test n_big <= 23 * 4

    # And the extent NEVER reads a row: `_tc_extent` is a memo field, a
    # `length` and an `Int` add.
    big_hits[] = 0
    content_extent(big)
    max_scroll(big)
    scroll_to!(big, Offset(0, 50_000))
    content_extent(big)
    @test big_hits[] == 0
end

@testitem "table: a row is not a widget, at ANY size" begin
    using DualUI
    # THE RULE THE WHOLE TIER RESTS ON, MEASURED rather than assumed: a
    # row is an element of a Vector and ZERO WidgetNodes. A `Table` has
    # a header AND a grid painter -- both are paint, neither is a child
    # widget -- so this is where a row-widget regression lands first.
    #
    # `descendants` is the instrument the rule names, at TWO sizes
    # 10 000x apart: ONE size is a point and cannot show that the node
    # count does not GROW with the data.
    small = Table([(i, "r$i") for i in 1:10],
                  [Column("A"; width = cells(4)),
                   Column("B"; width = cells(4))])
    big = Table([(i, "r$i") for i in 1:100_000],
                [Column("A"; width = cells(4)),
                 Column("B"; width = cells(4))])
    @test isempty(descendants(small))
    @test isempty(descendants(big))
    @test length(descendants(big)) == length(descendants(small))
    @test isempty(children(big))
    @test length(focusable_widgets(small)) == 1
    @test length(focusable_widgets(big)) == 1

    # STILL flat after a REAL frame -- header included. A row widget
    # materialised lazily on the first paint would hide from a
    # construction-only count; it cannot hide from this.
    apply_stylesheet!(STYLESHEET_EMPTY, big)
    layout!(big, Region(1, 1, 20, 24))
    buf = Buffer(20, 24)
    clear!(buf)
    paint!(buf, big)
    @test isempty(descendants(big))

    # And flat with the window 99 000 rows down, and after a data op.
    scroll_to!(big, Offset(0, 99_000))
    clear!(buf)
    paint!(buf, big)
    @test isempty(descendants(big))
    push_row!(big, (100_001, "new"))
    @test isempty(descendants(big))
    @test length(focusable_widgets(big)) == 1

    # The instrument is LIVE, not vacuous: `descendants` DOES count real
    # children. Without this control a `descendants` that always
    # returned `[]` would satisfy every assertion above.
    @test !isempty(descendants(Scrollpane(Table([(1,)],
                                                [Column("A")]))))
end

@testitem "table: a cell too wide for its column is cut on a cluster" begin
    using DualUI
    t = Table([("Alice Smith", "x")],
              [Column("A"; width = cells(5)), Column("B"; width = cells(1))];
              show_header = false, sep = " ")
    layout!(t, Region(1, 1, 7, 1))
    buf = Buffer(7, 1)
    clear!(buf)
    paint!(buf, t)
    # Cut at `cw` on a CLUSTER boundary, then `TC_ELLIPSIS` in the
    # column's LAST cell and the text re-truncated to `cw - 1`.
    @test string(buf) == "Alic… x"
    @test buf[5, 1].content == TC_ELLIPSIS
end

@testitem "table: a truncated cell is left-anchored under every align" begin
    using DualUI
    # A right-aligned truncated number ("…234") reads as a DIFFERENT
    # NUMBER, which is worse than a visibly clipped one. `align` applies
    # ONLY when the text fits.
    for a in (Align.START, Align.CENTER, Align.END, Align.STRETCH)
        t = Table([("abcdefgh",)], [Column("H"; width = cells(4), align = a)];
                  show_header = false)
        layout!(t, Region(1, 1, 4, 1))
        buf = Buffer(4, 1)
        clear!(buf)
        paint!(buf, t)
        @test string(buf) == "abc…"
    end
    # And when it FITS, `align` places it -- `cross_align` (layout.jl:163)
    # REUSED, which is why there is no `CellAlign` enum.
    for (a, want) in ((Align.START, "ab    "), (Align.CENTER, "  ab  "),
                      (Align.END, "    ab"), (Align.STRETCH, "ab    "))
        t = Table([("ab",)], [Column("H"; width = cells(6), align = a)];
                  show_header = false)
        layout!(t, Region(1, 1, 6, 1))
        buf = Buffer(6, 1)
        clear!(buf)
        paint!(buf, t)
        @test string(buf) == want
    end
end

@testitem "table: a cell never bleeds into the next column" begin
    using DualUI
    t = Table([(repeat("w", 24), "B")],
              [Column("A"; width = cells(4)), Column("B"; width = cells(3))];
              show_header = false, sep = " ")
    layout!(t, Region(1, 1, 8, 1))
    buf = Buffer(8, 1)
    clear!(buf)
    paint!(buf, t)
    # Column A owns frame cells 1:4 and NOTHING else. Cell 5 is the
    # separator; column B is intact.
    @test string(buf) == "www… B  "
    @test buf[4, 1].content == TC_ELLIPSIS
    @test buf[6, 1].content == "B"
end

@testitem "table: a wide grapheme at a column edge is dropped, not halved" begin
    using DualUI
    # `truncate_width("世界a", 3) == "世"`: a width-2 cluster that
    # would straddle the cap is DROPPED. A CLUSTER THEREFORE CANNOT
    # STRADDLE A COLUMN EDGE BY CONSTRUCTION, and there is no second
    # guard to write.
    t = Table([("世界a", "世")],
              [Column("A"; width = cells(3)), Column("B"; width = cells(2))];
              show_header = false, sep = "|")
    layout!(t, Region(1, 1, 6, 1))
    buf = Buffer(6, 1)
    clear!(buf)
    paint!(buf, t)
    @test buf[1, 1].content == "世"
    @test buf[1, 1].width == Int8(2)
    @test is_continuation(buf[2, 1])
    @test buf[3, 1].content == TC_ELLIPSIS   # the gap is where 界 was
    @test buf[4, 1].content == "|"           # the separator, untouched
    @test buf[5, 1].content == "世"
    @test is_continuation(buf[6, 1])
    # The property that catches everything: no CELL_CONT whose head we
    # did not write.
    for x in 1:6
        is_continuation(buf[x, 1]) || continue
        @test x > 1
        @test buf[x - 1, 1].width == Int8(2)
    end
end

@testitem "table: every test vector paints whole clusters or none" begin
    using DualUI
    # `Base.textwidth` reports 1 for the VS16 heart occupying 2 cells and
    # 6 for the ZWJ family occupying 2. It appears NOWHERE, and this is
    # what would catch it.
    vs16 = "❤️"
    zwj = "\U0001F468‍\U0001F469‍\U0001F467"
    flag = "🇫🇷"
    for (s, want) in ((vs16, 2), (zwj, 2), (flag, 2), ("世", 2),
                      ("é", 1), ("a", 1))
        @test grapheme_width(s) == want
    end
    rows = [(vs16, zwj), (flag, "世界"), ("é", "a")]
    t = Table(rows, [Column("A"; width = cells(3)),
                     Column("B"; width = cells(3))];
              show_header = false, sep = " ")
    layout!(t, Region(1, 1, 7, 3))
    buf = Buffer(7, 3)
    clear!(buf)
    paint!(buf, t)
    for y in 1:3, x in 1:7
        is_continuation(buf[x, y]) || continue
        @test x > 1
        @test buf[x - 1, y].width == Int8(2)
    end
    # A width-2 cluster in an ODD-width column leaves a one-cell gap --
    # the correct rendering of "it does not fit" -- and never a half.
    @test buf[1, 1].content == vs16
    @test is_continuation(buf[2, 1])
    @test buf[3, 1] == CELL_BLANK
end

@testitem "table: empty table paints the header and no rows" begin
    using DualUI
    t = Table(String[], [Column("Name"; width = cells(6))];
              cell = (r, j) -> r, rule = true)
    layout!(t, Region(1, 1, 6, 4))
    # Every operation is TOTAL at n == 0: no method throws and no method
    # returns `nothing` where an `Int` is declared.
    @test row_count(t) == 0
    @test view_count(t) == 0
    @test row_cursor(t) == 0            # 0 IFF n == 0, never `nothing`
    @test row_anchor(t) == 0
    @test n_selected(t) == 0
    @test selected_rows(t) == Int[]
    @test content_extent(t) === Size(6, 2)
    @test max_scroll(t) === Offset(0, 0)
    @test !move_cursor!(t, 1)
    @test !select_all!(t)
    @test !clear_selection!(t)
    @test !delete_row!(t, 1)
    buf = Buffer(6, 4)
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "Name  \n──────\n      \n      "
end

@testitem "table: one row" begin
    using DualUI
    t = Table(["only"], [Column("H"; width = cells(6))]; cell = (r, j) -> r)
    layout!(t, Region(1, 1, 6, 4))
    @test content_extent(t) === Size(6, 2)
    @test max_scroll(t) === Offset(0, 0)
    @test row_cursor(t) == 1
    # The FIRST move selects row 1 -- nothing is selected until the user
    # touches it, so that IS a change. The second has nowhere to go and
    # does NOT consume: a table on its last row lets DOWN bubble out.
    @test move_cursor!(t, 1)
    @test !move_cursor!(t, 1)
    @test !move_cursor!(t, -1)
    @test selected_rows(t) == [1]
    buf = Buffer(6, 4)
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "H     \nonly  \n      \n      "
end

@testitem "table: one column" begin
    using DualUI
    # One column: NO separator is ever drawn -- `max(1, lo-1):min(hi, 0)`
    # is empty -- and `cache_total` is the column itself, with no gap.
    t = Table(["aa", "bb"], [Column("H"; width = cells(4))];
              cell = (r, j) -> r, sep = "|")
    layout!(t, Region(1, 1, 6, 4))
    @test content_extent(t).width == 4      # sep_w * (1 - 1) == 0
    @test grid_of(t).cache_total == 4
    @test grid_of(t).xs == [0]
    @test max_scroll(t).x == 0
    buf = Buffer(6, 4)
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "H     \naa    \nbb    \n      "
    @test !occursin("|", string(buf))
end

@testitem "table: zero columns does not throw" begin
    using DualUI
    t = Table([1, 2, 3], Column[]; cell = (r, j) -> "x")
    layout!(t, Region(1, 1, 6, 4))
    @test grid_of(t).cache_total == 0
    @test content_extent(t) === Size(0, 4)      # 3 rows + hh
    @test DualUI._tc_visible_cols(grid_of(t), 0, 6) === (1, 0)
    buf = Buffer(6, 4)
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "      \n      \n      \n      "
    # The rows are real; they simply have no columns. It still navigates.
    @test move_cursor!(t, 1)
    @test row_cursor(t) == 2
    @test row_count(t) == 3
end

@testitem "table: over-scroll paints blanks, never a BoundsError" begin
    using DualUI
    t = Table(["a", "b"], [Column("H"; width = cells(3))];
              cell = (r, j) -> r, show_header = false)
    layout!(t, Region(1, 1, 3, 3))
    buf = Buffer(3, 3)
    # `set_scroll!` clamps at zero but has NO upper bound
    # (widget.jl:185), so a caller bypassing `scroll_to!` can over-scroll
    # far enough to wrap `k` negative. An over-scroll is BLANK ROWS.
    set_scroll!(t, Offset(0, 500))
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "   \n   \n   "
    set_scroll!(t, Offset(500, 0))
    clear!(buf)
    paint!(buf, t)
    @test string(buf) == "   \n   \n   "
end

@testitem "table: cell is called once per visible cell per frame" begin
    using DualUI
    calls = Tuple{Int,Int}[]
    t = Table(collect(1:1000),
              [Column("A"; width = cells(4)), Column("B"; width = cells(4))];
              cell = (r, j) -> (push!(calls, (r, j)); "v"))
    layout!(t, Region(1, 1, 9, 5))
    empty!(calls)
    buf = Buffer(9, 5)
    clear!(buf)
    paint!(buf, t)
    # 4 body rows x 2 columns, ONCE each, and nothing else: not the
    # header (it reads `Column.header`), not a culled column, not a row
    # outside the window.
    @test length(calls) == 8
    @test length(unique(calls)) == 8
    @test Set(first.(calls)) == Set(1:4)
    @test Set(last.(calls)) == Set([1, 2])
end

@testitem "table: Scrollbar{Table} works with ZERO new code in scroll.jl" begin
    using DualUI
    hits = Ref(0)
    t = Table(collect(1:100), [Column("N"; width = cells(4))];
              cell = (r, j) -> (hits[] += 1; string(r)))
    bar = Scrollbar(t, ScrollAxis.VERTICAL)
    # `Scrollbar` is PARAMETRIC ON ITS VIEWPORT because the scrollable
    # seam is three functions and not a type: `content_extent`,
    # `layout_of(w).content` and `scroll_of`. `Table` overrides the first
    # and inherits the other two, so this needs NOT ONE LINE in scroll.jl.
    @test bar isa Scrollbar{typeof(t)}
    @test bar.viewport === t
    layout!(t, Region(1, 1, 6, 11))
    # The bar reads the SEAM, never its own position: it is a SIBLING of
    # what it reports on, so it is laid out into its own gutter.
    layout!(bar, Region(1, 1, 1, 11))

    hits[] = 0
    @test DualUI._sb_metrics(bar, 11) === (11, 11, 101, 0)
    @test hits[] == 0                   # the bar NEVER touches a row
    scroll_to!(t, Offset(0, 90))
    @test DualUI._sb_metrics(bar, 11)[4] == 90
    @test hits[] == 0

    buf = Buffer(1, 11)
    clear!(buf)
    paint!(buf, bar)
    @test hits[] == 0
    @test occursin(DualUI.SB_THUMB, string(buf))
    # At the bottom the thumb is pinned to the LAST cell of the track --
    # `thumb_span`'s two verifiable ends, over a `Table`, unchanged.
    @test buf[1, 11].content == DualUI.SB_THUMB

    # The HORIZONTAL bar reports on the same seam, from `cache_total`.
    h = Scrollbar(t, ScrollAxis.HORIZONTAL)
    @test DualUI._sb_metrics(h, 6) === (6, 6, 4, 0)
end

@testitem "table: Scrollpane(Table) is legal and composes" begin
    using DualUI
    t = Table(collect(1:100), [Column("N"; width = cells(4))];
              cell = (r, j) -> string(r))
    pane = Scrollpane(t)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 10, 6))
    # The two mechanisms COMPOSE rather than compete, exactly as for
    # `TextArea`: because `measure(::Table, avail) == avail`, the pane's
    # holder is exactly canvas-sized, nothing overflows, and the pane
    # does none of the scrolling. It is INERT at the pane level -- which
    # is correct composition, not the magic the phrase suggests.
    @test max_scroll(viewport(pane)) === ORIGIN
    @test max_scroll(t).y > 0
    buf = Buffer(10, 6)
    clear!(buf)
    paint!(buf, pane)
    @test occursin("N", string(buf))
end

@testitem "table: the rule spans the content width with one glyph" begin
    using DualUI
    t = Table([("a", "b")],
              [Column("A"; width = cells(2)), Column("B"; width = cells(2))];
              rule = true, rule_glyph = "=", sep = "|")
    layout!(t, Region(1, 1, 8, 3))
    buf = Buffer(8, 3)
    clear!(buf)
    paint!(buf, t)
    # ONE glyph, CONTINUOUSLY, across the FULL content width, with NO
    # junction where a separator crosses it: `border_glyphs` gives eight
    # glyphs and no T or cross (boxmodel.jl:141), so junctions would mean
    # a new glyph table for one cell per column. The table's OUTER frame
    # is `box(t).border` and costs ZERO code here.
    @test string(buf) == "A  B    \n========\na |b    "
    for x in 1:8
        @test buf[x, 2].content == "="
    end
    # The grid OWNS `rule_glyph`: a painter that ignored it would make
    # the field a lie. A wide glyph is refused at CONSTRUCTION -- a
    # throw, never a quiet nothing.
    @test_throws ArgumentError Table([("a",)], [Column("A")];
                                     rule = true, rule_glyph = "世")
    # `rule` without `show_header` draws NOTHING: hh is 0.
    u = Table([("a",)], [Column("A"; width = cells(2))];
              show_header = false, rule = true)
    layout!(u, Region(1, 1, 4, 2))
    b2 = Buffer(4, 2)
    clear!(b2)
    paint!(b2, u)
    @test string(b2) == "a   \n    "
end

@testitem "table: selection survives push_row! and delete_row!" begin
    using DualUI
    t = Table(collect(1:10), [Column("N"; width = cells(4))];
              cell = (r, j) -> string(r), mode = SelectMode.MULTI)
    layout!(t, Region(1, 1, 6, 12))
    sel_extend_ids!(selection_of(t), [3, 5, 7])
    @test selected_rows(t) == [3, 5, 7]

    push_row!(t, 11)
    @test selected_rows(t) == [3, 5, 7]      # nothing moves on a push
    @test row_count(t) == 11

    # INSERT at 4: everything at or above 4 moves up one.
    insert_row!(t, 4, 99)
    @test selected_rows(t) == [3, 6, 8]
    @test row_count(t) == 12
    @test t.rows[4] == 99

    # DELETE 4: it leaves the selection and everything above moves down.
    @test delete_row!(t, 4)
    @test selected_rows(t) == [3, 5, 7]
    @test row_count(t) == 11

    # Deleting a SELECTED row drops it.
    @test delete_row!(t, 3)
    @test selected_rows(t) == [4, 6]
    @test !delete_row!(t, 99)                # out of range, no throw
    @test !delete_row!(t, 0)
    @test row_count(t) == 10
end

@testitem "table: delete_row! leaves the cursor in range" begin
    using DualUI
    t = Table(collect(1:3), [Column("N"; width = cells(4))];
              cell = (r, j) -> string(r))
    layout!(t, Region(1, 1, 6, 8))
    move_cursor!(t, typemax(Int) ÷ 2)
    @test row_cursor(t) == 3
    # The cursor was ON the deleted row: it stays at `i` and is
    # re-clamped, so it lands on the row that took `i`'s place -- or on
    # the new last row.
    @test delete_row!(t, 3)
    @test row_cursor(t) == 2
    @test delete_row!(t, 1)
    @test row_cursor(t) == 1
    @test delete_row!(t, 1)
    @test row_cursor(t) == 0                 # 0 IFF n == 0
    @test row_count(t) == 0
end

@testitem "table: set_rows! clears the selection and re-seeds the marks" begin
    using DualUI
    t = Table(["aa", "bb", "wwwwwwww"], [Column("H"; width = AUTO)];
              cell = (r, j) -> r, mode = SelectMode.MULTI,
              show_header = false)
    layout!(t, Region(1, 1, 10, 2))
    # END first, then select-all: a cursor move REPLACES the selection
    # with the row under it, so the reverse order would leave one row
    # selected and prove nothing.
    move_cursor!(t, typemax(Int) ÷ 2)
    select_all!(t)
    @test n_selected(t) == 3
    @test grid_of(t).autos[1] == 8
    @test scroll_of(t).y > 0

    # Every index the selection held names a row that may no longer
    # exist, and silently keeping them would select the WRONG ROWS.
    set_rows!(t, ["p", "q"])
    @test row_count(t) == 2
    @test n_selected(t) == 0
    @test row_cursor(t) == 1
    @test row_anchor(t) == 1
    @test scroll_of(t) === ORIGIN
    # RE-SEEDED: one of the two calls that can NARROW an AUTO column.
    @test grid_of(t).autos[1] == 1
    @test t.rows == ["p", "q"]

    set_rows!(t, String[])
    @test row_count(t) == 0
    @test row_cursor(t) == 0                 # 0 IFF n == 0
end

@testitem "table: refresh_rows! is the escape hatch for a direct mutation" begin
    using DualUI
    rows = collect(1:5)
    t = Table(rows, [Column("N"; width = cells(4))];
              cell = (r, j) -> string(r))
    layout!(t, Region(1, 1, 6, 8))
    move_cursor!(t, typemax(Int) ÷ 2)
    @test row_cursor(t) == 5
    # `rows` is ALIASED, never copied: copying 100 000 rows is exactly
    # the O(n) this widget exists to avoid.
    @test t.rows === rows

    empty!(rows)
    push!(rows, 42)
    # Mutated behind `version`'s back: STALE, never CORRUPT. `_tc_sync!`
    # at the top of `render!` keeps every index IN RANGE even with no
    # refresh, and a frame marks NOTHING.
    v = t.version[]
    buf = Buffer(6, 8)
    clear!(buf)
    paint!(buf, t)
    @test row_cursor(t) == 1
    @test t.version[] == v
    @test string(buf) ==
          "N     \n42    " * repeat("\n      ", 6)

    # And the public cure.
    refresh_rows!(t)
    @test t.version[] == v + 1
    @test row_count(t) == 1
end

@testitem "table: set_columns! resizes the grid and re-seeds the marks" begin
    using DualUI
    t = Table([("alpha", "beta", "gamma")], [Column("A"; width = AUTO)])
    layout!(t, Region(1, 1, 30, 3))
    @test grid_of(t).autos == [5]            # "alpha"
    @test length(grid_of(t).widths) == 1

    set_columns!(t, [Column("A"; width = AUTO),
                     Column("BB"; width = AUTO),
                     Column("C"; width = cells(4))])
    g = grid_of(t)
    @test length(g.cols) == 3
    @test length(g.widths) == 3
    @test length(g.xs) == 3
    @test length(g.autos) == 3
    # Re-seeded from the headers AND the sample, exactly as at
    # construction: a column model REPLACED is a column model MEASURED.
    @test g.autos == [5, 4, 0]               # "alpha", "beta", non-AUTO
    @test DualUI._tc_resolve!(t, 30) == [5, 4, 4]
    @test g.xs == [0, 6, 11]

    # An in-place edit plus `refresh_columns!` is the documented
    # alternative: a `Column` is an IMMUTABLE SPEC.
    g.cols[1] = Column("LongerHeader"; width = AUTO)
    refresh_columns!(t)
    @test g.autos[1] == 12
    @test DualUI._tc_resolve!(t, 30)[1] == 12
end

@testitem "table: the default cell reads row[j]" begin
    using DualUI
    # The three shapes a table's rows actually arrive in -- and nothing
    # else, which is exactly what the `cell` keyword is for.
    cols = [Column("A"; width = cells(3)), Column("B"; width = cells(3))]
    for rows in ([(1, "x")], [(a = 1, b = "x")], [[1, "x"]])
        t = Table(rows, copy(cols); show_header = false, sep = " ")
        layout!(t, Region(1, 1, 7, 1))
        buf = Buffer(7, 1)
        clear!(buf)
        paint!(buf, t)
        @test string(buf) == "1   x  "
    end
    # `_tc_show` returns a String UNCOPIED, so a String cell allocates
    # nothing to format.
    @test DualUI._tc_cell_default(("s", 2), 1) === "s"
end

@testitem "table: a data change is a PAINT mark and dirty_root stays put" begin
    using DualUI
    root = Container()
    t = Table(collect(1:100), [Column("N"; width = cells(4))];
              cell = (r, j) -> string(r))
    mount!(root, t)
    layout!(root, Region(1, 1, 10, 6))
    clean!(root)
    clean!(t)
    @test dirty_root(root) === nothing

    push_row!(t, 101)
    # PAINT, never LAYOUT: `measure` is data-independent, so
    # `push_row!` on a 100 000-row table costs ZERO layout and never
    # fires `escalate_auto!`.
    @test is_dirty(t, Dirty.PAINT)
    @test !is_dirty(t, Dirty.LAYOUT)
    @test !is_dirty(root, Dirty.LAYOUT)
end
