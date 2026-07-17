# widgets_list_tests.jl -- the scrollable list of items (layer 7).
#
# Every testitem is self-contained, starts `using DualUI`, needs no tty
# and never sleeps.
#
# A ROW IS NOT A WIDGET, and the suite asserts it rather than trusting
# it: `render!` is measured on a 100 000-item list and must cost what a
# 20-item one costs, and the constructor must not call the formatter
# even once. Those two facts are the whole widget.
#
# `Base.textwidth` appears nowhere. The grapheme discipline asserted
# here is the SAME one `TextInput` and `TextArea` obey: a wide cluster
# is ONE step and TWO cells, and it is never halved -- at either edge.

@testitem "list: construction aliases items and is focusable" begin
    using DualUI
    xs = ["a", "b", "c"]
    l = List(xs)
    @test l isa Widget
    @test l isa RowsWidget
    # ALIASED, never copied: copying 100 000 rows is exactly the O(n)
    # this widget exists to avoid.
    @test l.items === xs
    @test type_name(l) === :List
    @test is_focusable(l)
    @test l in focusable_widgets(l)
    @test !is_focused(l)
    @test l.version[] == 0
    # `widest` starts at ZERO: the mark records what has been SEEN
    # painted, and nothing has been painted yet.
    @test l.widest == 0
end

@testitem "list: the seam is one line each" begin
    using DualUI
    l = List(["a", "b", "c"])
    @test selection_of(l) === l.sel
    @test row_count(l) == 3
    @test view_count(l) == 3
    # A `List` has no permutation: view and source are the same index.
    for k in 1:3
        @test view_source(l, k) == k
        @test view_rank(l, k) == k
    end
    @test select_mode(l) === SelectMode.SINGLE
    @test row_cursor(l) == 1
    @test row_anchor(l) == 1
    # NOTHING is selected initially, in every mode -- including SINGLE:
    # a list that selects row 1 before the user has touched it has made
    # a choice on their behalf.
    @test n_selected(l) == 0
    @test selected_rows(l) == Int[]
    @test !is_selected(l, 1)
    # A `List` has no columns, so it answers `grid_of` with a
    # MethodError rather than a nothing.
    @test_throws MethodError grid_of(l)
end

@testitem "list: ids are unique by default" begin
    using DualUI
    @test id(List(["x"])) !== id(List(["x"]))
    @test id(List(["x"]; id = :fixed)) === :fixed
end

@testitem "list: the mode is a construction-time choice" begin
    using DualUI
    for m in (SelectMode.NONE, SelectMode.SINGLE, SelectMode.MULTI)
        l = List(["a", "b"]; mode = m)
        @test select_mode(l) === m
        @test n_rows(selection_of(l)) == 2
    end
end

@testitem "list: an AbstractVector is collected ONCE" begin
    using DualUI
    l = List(1:5)
    @test l.items == [1, 2, 3, 4, 5]
    @test l.items isa Vector{Int}
    @test row_count(l) == 5
    # The element type survives the collect: `items[i]` is a TYPED load.
    @test l isa List{Int}
end

@testitem "list: the constructor calls the formatter ZERO times" begin
    using DualUI
    # THE doctrine, asserted rather than trusted: `List(1:100_000)`
    # collects once and formats NOTHING. A constructor that seeded
    # `widest` exactly would be O(items) formatter calls -- the very
    # cost this widget exists to avoid.
    #
    # DEFERRED, NOT SKIPPED. The mark is measured from the DATA at the
    # first query (`_lst_scan!`), never from the paint: a paint-fed mark
    # is a FIXPOINT that pins `max_scroll.x` at zero forever -- see
    # "list: the horizontal mark cannot deadlock its own axis".
    calls = Ref(0)
    f = x -> (calls[] += 1; string(x))
    l = List(collect(1:1000); format = f)
    @test calls[] == 0
    @test l.widest == 0
    @test !l.scanned

    # The first query -- the first time anyone ASKS how wide the content
    # is, and so the first time the answer can matter -- pays O(items),
    # ONCE. "1000" is 4 cells.
    @test content_extent(l) === Size(4, 1000)
    @test calls[] == 1000
    @test l.widest == 4

    # `refresh_extent!` is still the exact rescan, and it is now the
    # only thing that can LOWER the mark rather than the only thing that
    # can set it at all.
    @test refresh_extent!(l) === Size(4, 1000)
    @test calls[] == 2000
    @test l.widest == 4
end

@testitem "list: measure takes the space it is offered" begin
    using DualUI
    @test measure(List(["x"]), Size(20, 7)) === Size(20, 7)
    tall = List(["y$i" for i in 1:100])
    # An auto-HEIGHT List would be as tall as its data and would never
    # scroll at all. This is also what licenses `version`'s PAINT
    # reactivity.
    @test measure(tall, Size(4, 3)) === Size(4, 3)
    @test measure(List(String[]), Size(0, 0)) === Size(0, 0)
end

@testitem "list: content_extent is Size(widest, n) and O(1)" begin
    using DualUI
    l = List(["a", "bbbb", "cc"])
    # OVERRIDES the container default: a List's content is DATA, not
    # children, so the bounding box of its (nonexistent) children is
    # not its extent. Measured from that DATA on the first query, so it
    # is right BEFORE the first paint -- "cannot scroll" when it can is
    # the anti-pattern `_tc_resolve!` names and this refuses it too.
    @test content_extent(l) === Size(4, 3)
    refresh_extent!(l)
    @test content_extent(l) === Size(4, 3)
    push_item!(l, "d")
    @test content_extent(l) === Size(4, 4)
    # `_tc_header_rows(::List) == 0`, so `_tc_extent`'s `+ hh`
    # degenerates and this is `Size(widest, n)` EXACTLY.
    @test DualUI._tc_header_rows(l) == 0
    @test DualUI._tc_extent_width(l) == l.widest
    @test content_extent(l).height == row_count(l)

    # O(1) and ZERO allocation: `_sb_metrics`, `max_scroll`,
    # `scroll_to!` and `Scrollpane.render!` all reach this several
    # times per frame. `maximum(text_width, items)` on EVERY call would
    # make every frame O(rows) and IS FORBIDDEN -- so the scan is
    # MEMOIZED on `scanned` and every frame after the first is a hit.
    big = List(["item $i" for i in 1:100_000])
    content_extent(big)                 # the one O(items) scan
    @test big.scanned
    @test (@allocated content_extent(big)) == 0
    @test content_extent(big) === Size(11, 100_000)   # "item 100000"
end

@testitem "list: an empty list is total" begin
    using DualUI
    l = List(String[])
    @test row_count(l) == 0
    @test view_count(l) == 0
    @test content_extent(l) === Size(0, 0)
    # `0`, never `nothing`: every operation is total at `n == 0`.
    @test row_cursor(l) == 0
    @test row_anchor(l) == 0
    @test n_selected(l) == 0
    @test selected_rows(l) == Int[]

    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 4, 2))
    buf = Buffer(4, 2)
    clear!(buf)
    render!(l, buf)
    @test string(buf) == "    \n    "

    # Navigation on nothing moves nothing and throws nothing.
    @test !move_cursor!(l, 1)
    @test !move_cursor!(l, -1)
    @test !set_cursor!(l, 0)
    @test !set_cursor!(l, typemax(Int))
    @test !select_only!(l, 1)
    @test !toggle_row!(l, 1)
    @test !clear_selection!(l)
    @test row_cursor(l) == 0
    @test !delete_item!(l, 1)
    @test !delete_item!(l, 0)
end

@testitem "list: an empty list consumes no key" begin
    using DualUI
    l = List(String[])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 4, 2))
    for k in ("up", "down", "home", "end", "pageup", "pagedown",
              "space")
        d = Dispatch(parse(KeyEvent, k), l)
        d.phase = Phase.AT_TARGET
        on_event!(l, d)
        # Nothing moved, so nothing is consumed: the key bubbles to an
        # outer pane.
        @test !is_consumed(d)
    end
    @test row_cursor(l) == 0
end

@testitem "list: the CAPTURE phase belongs to ancestors" begin
    using DualUI
    l = List(["a", "b", "c"])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 3))
    # CAPTURE belongs to ancestors that want to intercept, and a list is
    # never an interceptor. `Dispatch(e, target)` STARTS in CAPTURE, so
    # a test that forgets to advance the phase passes for the wrong
    # reason -- this is the one that would catch it.
    d = Dispatch(parse(KeyEvent, "down"), l)
    @test d.phase === Phase.CAPTURE
    on_event!(l, d)
    @test !is_consumed(d)
    @test row_cursor(l) == 1            # untouched

    d.phase = Phase.AT_TARGET
    on_event!(l, d)
    @test is_consumed(d)
    @test row_cursor(l) == 2

    # An already-consumed envelope is dead, whatever the phase.
    d2 = Dispatch(parse(KeyEvent, "down"), l)
    d2.phase = Phase.BUBBLE
    consume!(d2)
    on_event!(l, d2)
    @test row_cursor(l) == 2
end

@testitem "list: one item paints into the content box" begin
    using DualUI
    l = List(["hi"])
    buf = Buffer(4, 3)
    clear!(buf)
    render!(l, buf)
    @test string(buf) == "hi  \n    \n    "
    # The mark is raised from what was painted, in O(1) per row.
    @test l.widest == 2
    @test content_extent(l) === Size(2, 1)
end

@testitem "list: more items than rows paints only the window" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    @test layout_of(l).content === Region(1, 1, 10, 5)
    @test scroll_of(l).y == 0

    buf = Buffer(10, 5)
    clear!(buf)
    render!(l, buf)
    rows = split(string(buf), '\n')
    @test length(rows) == 5
    @test rows[1] == "L1        "
    @test rows[5] == "L5        "

    # Scrolls by INDEXING `items`, never by shifting an origin.
    @test scroll_to!(l, Offset(0, 15)) === Offset(0, 15)
    clear!(buf)
    render!(l, buf)
    rows = split(string(buf), '\n')
    @test rows[1] == "L16       "
    @test rows[5] == "L20       "

    # Past the last row is BLANK, never a BoundsError.
    @test set_scroll!(l, Offset(0, 18))
    clear!(buf)
    render!(l, buf)
    rows = split(string(buf), '\n')
    @test rows[1] == "L19       "
    @test rows[2] == "L20       "
    @test rows[3] == "          "
    @test rows[5] == "          "
end

@testitem "list: an over-scroll is blank rows, never a BoundsError" begin
    using DualUI
    l = List(["a", "b"])
    buf = Buffer(4, 3)
    # `set_scroll!` clamps at zero but has NO upper bound
    # (widget.jl:185), so a caller bypassing `scroll_to!` can
    # over-scroll far enough to wrap the row index negative.
    @test set_scroll!(l, Offset(0, typemax(Int) - 1))
    clear!(buf)
    render!(l, buf)                 # must not throw
    @test string(buf) == "    \n    \n    "

    @test set_scroll!(l, Offset(0, 500))
    clear!(buf)
    render!(l, buf)
    @test string(buf) == "    \n    \n    "
end

@testitem "list: render! is O(viewport) on a 100 000-item list" begin
    using DualUI
    items = fill("item", 100_000)
    # A monster item that is NEVER visible: any per-item work at all --
    # a `text_width`, a `graphemes`, a `format` -- shows up as
    # allocation the moment `render!` looks past the viewport.
    items[90_000] = "x"^100_000
    big = List(items)
    small = List(fill("item", 20))
    @test row_count(big) == 100_000

    buf = Buffer(10, 10)
    render!(small, buf)             # warm up: the first call compiles
    render!(big, buf)
    a_small = @allocated render!(small, buf)
    a_big = @allocated render!(big, buf)
    # A 5000x longer list costs the SAME frame: paint is O(viewport),
    # NEVER O(items). A 100 000-item list costs what a 20-item one does.
    @test a_big == a_small
    @test split(string(buf), '\n')[1] == "item      "

    # And the cost does not depend on WHERE the window sits: paint never
    # scans from the top of the data.
    @test set_scroll!(big, Offset(0, 95_000))
    render!(big, buf)
    @test (@allocated render!(big, buf)) == a_small
    @test split(string(buf), '\n')[1] == "item      "

    # A `List{String,typeof(_tc_show)}` formats for ZERO allocation per
    # row, because `_tc_show(::String)` returns its argument.
    @test big.format === DualUI._tc_show
    @test big.format("k") === "k"
end

@testitem "list: a row is not a widget, at ANY size" begin
    using DualUI
    # A row is an element of a Vector and ZERO WidgetNodes -- so
    # `hit_test` is not O(n) on every POINTER MOVE, and `push_item!` is
    # not a full layout pass.
    #
    # Measured with `descendants`, the instrument the rule names, and at
    # TWO sizes 10 000x apart. ONE size is a point; it cannot show that
    # the node count does not GROW with the data.
    small = List(["L$i" for i in 1:10])
    big = List(["L$i" for i in 1:100_000])
    @test isempty(descendants(small))
    @test isempty(descendants(big))
    @test length(descendants(big)) == length(descendants(small))
    @test isempty(children(big))
    @test length(focusable_widgets(small)) == 1
    @test length(focusable_widgets(big)) == 1

    # STILL flat after a REAL frame: no row widget is materialised
    # lazily on the first paint, which is where such a regression would
    # hide from a construction-only count.
    apply_stylesheet!(STYLESHEET_EMPTY, big)
    layout!(big, Region(1, 1, 20, 24))
    buf = Buffer(20, 24)
    clear!(buf)
    paint!(buf, big)
    @test isempty(descendants(big))
    @test length(focusable_widgets(big)) == 1

    # And after 5 000 more rows arrive one at a time.
    for i in 1:5_000
        push_item!(big, "P$i")
    end
    @test length(big.items) == 105_000
    @test isempty(descendants(big))

    # The instrument is LIVE, not vacuous: `descendants` DOES count real
    # children. Without this control a `descendants` that always
    # returned `[]` would satisfy every assertion above.
    @test !isempty(descendants(Scrollpane(List(["a"]))))
end

@testitem "list: a data change costs ZERO layout" begin
    using DualUI
    l = List(["a"])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    clean!(l)
    push_item!(l, "b")
    # `version` is Dirty.PAINT-reactive: `measure(::List, avail) =
    # avail`, so a data change PROVABLY cannot move a box.
    @test is_dirty(l, Dirty.PAINT)
    @test !is_dirty(l, Dirty.LAYOUT)
    @test dirty_root(l) === nothing
end

@testitem "list: version is a DIRECT field and is attached" begin
    using DualUI
    l = List(["a"])
    # `attach_reactives!` walks `fieldnames` ONE level and binds only
    # DIRECT `Reactive` fields: a `Reactive` one level down silently
    # never gets an owner and never marks anything dirty, and THAT
    # FAILURE HAS NO ERROR MESSAGE.
    @test l.version isa Reactive{Int}
    @test l.focused isa Reactive{Bool}
    @test :version in fieldnames(typeof(l))
    @test :focused in fieldnames(typeof(l))
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    clean!(l)
    l.version[] = l.version[] + 1
    @test is_dirty(l, Dirty.PAINT)
    clean!(l)
    l.focused[] = true
    @test is_dirty(l, Dirty.PAINT)
end

@testitem "list: the cursor clamps at both ends" begin
    using DualUI
    l = List(["a", "b", "c"])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 3))
    @test row_cursor(l) == 1

    # The first op on a fresh list changes the SELECTION even when the
    # cursor does not move -- nothing was selected.
    @test move_cursor!(l, -1)
    @test row_cursor(l) == 1
    @test is_selected(l, 1)
    # NOW nothing at all changes, and `false` says so.
    @test !move_cursor!(l, -1)
    @test row_cursor(l) == 1

    @test move_cursor!(l, 1)
    @test row_cursor(l) == 2
    @test move_cursor!(l, 100)          # clamped to the last row
    @test row_cursor(l) == 3
    @test !move_cursor!(l, 1)           # already at the end
    @test !move_cursor!(l, typemax(Int) ÷ 2)
    @test row_cursor(l) == 3
    @test move_cursor!(l, -typemax(Int) ÷ 2)
    @test row_cursor(l) == 1

    # `0` is Home and `typemax(Int)` is End.
    @test set_cursor!(l, typemax(Int))
    @test row_cursor(l) == 3
    @test set_cursor!(l, 0)
    @test row_cursor(l) == 1
    # Already home AND already selected: nothing changes at all.
    @test !set_cursor!(l, -999)
    @test row_cursor(l) == 1
end

@testitem "list: a NONE list has a cursor and no selection" begin
    using DualUI
    l = List(["a", "b", "c"]; mode = SelectMode.NONE)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 3))
    # A browsable list with no selection at all is a real widget (a log
    # viewer), not a degenerate one.
    @test !move_cursor!(l, -1)          # at the top: nothing to change
    @test move_cursor!(l, 1)
    @test row_cursor(l) == 2
    @test n_selected(l) == 0
    @test !select_only!(l, 3)
    @test !toggle_row!(l, 3)
    @test !select_all!(l)
    @test n_selected(l) == 0
end

@testitem "list: keyboard navigation moves the cursor" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))

    press(k) = (d = Dispatch(parse(KeyEvent, k), l);
                d.phase = Phase.AT_TARGET;
                on_event!(l, d); is_consumed(d))

    @test press("down")
    @test row_cursor(l) == 2
    @test press("up")
    @test row_cursor(l) == 1
    # One body LESS ONE ROW of overlap, so the reader keeps a landmark.
    @test DualUI._tc_page(l) == 4
    @test press("pagedown")
    @test row_cursor(l) == 5
    @test press("pagedown")
    @test row_cursor(l) == 9
    @test press("pageup")
    @test row_cursor(l) == 5
    @test press("end")
    @test row_cursor(l) == 20
    @test press("home")
    @test row_cursor(l) == 1
end

@testitem "list: navigation past both ends clamps and bubbles" begin
    using DualUI
    l = List(["a", "b"])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))

    press(k) = (d = Dispatch(parse(KeyEvent, k), l);
                d.phase = Phase.AT_TARGET;
                on_event!(l, d); is_consumed(d))

    @test press("up")                   # selects row 1: a change
    @test !press("up")                  # now genuinely at the top
    @test row_cursor(l) == 1
    @test !press("home")                # already home: no change
    @test press("down")
    @test row_cursor(l) == 2
    # CONSUMES ONLY WHEN SOMETHING ACTUALLY MOVED: a List on its LAST
    # row lets DOWN bubble to an outer Scrollpane. That is the whole of
    # chaining.
    @test !press("down")
    @test !press("pagedown")
    @test !press("end")
    @test row_cursor(l) == 2
    @test press("pageup")
    @test row_cursor(l) == 1
    @test !press("pageup")
    @test row_cursor(l) == 1
end

@testitem "list: ENTER fires on_activate and TAB falls through" begin
    using DualUI
    fired = Ref(0)
    seen = Ref{Any}(nothing)
    l = List(["a", "b"], w -> (fired[] += 1; seen[] = w))
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))

    d = Dispatch(parse(KeyEvent, "enter"), l)
    d.phase = Phase.AT_TARGET
    on_event!(l, d)
    @test is_consumed(d)                # firing IS the something
    @test fired[] == 1
    @test seen[] === l

    # TAB and ESCAPE FALL THROUGH UNCONSUMED, which is what keeps the
    # tab order alive.
    for k in ("tab", "shift+tab", "escape")
        e = Dispatch(parse(KeyEvent, k), l)
        e.phase = Phase.AT_TARGET
        on_event!(l, e)
        @test !is_consumed(e)
    end
    # ctrl+*, alt+* and super+* are left ENTIRELY to the app. CTRL+A IS
    # NOT BOUND: `select_all!(w)` is public; `bind!` it.
    for k in ("ctrl+a", "ctrl+down", "alt+down", "ctrl+enter")
        e = Dispatch(parse(KeyEvent, k), l)
        e.phase = Phase.AT_TARGET
        on_event!(l, e)
        @test !is_consumed(e)
    end
    @test fired[] == 1
    @test row_cursor(l) == 1
end

@testitem "list: the default on_activate does nothing" begin
    using DualUI
    l = List(["a"])
    @test l.on_activate === DualUI._tc_noop
    d = Dispatch(parse(KeyEvent, "enter"), l)
    d.phase = Phase.AT_TARGET
    on_event!(l, d)
    @test is_consumed(d)
end

@testitem "list: SPACE toggles under MULTI only" begin
    using DualUI
    m = List(["a", "b", "c"]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, m)
    layout!(m, Region(1, 1, 10, 5))
    press(w, k) = (d = Dispatch(parse(KeyEvent, k), w);
                   d.phase = Phase.AT_TARGET;
                   on_event!(w, d); is_consumed(d))
    @test press(m, "space")
    @test is_selected(m, 1)
    @test press(m, "space")
    @test !is_selected(m, 1)
    @test press(m, "down")
    # A bare move RE-PINS the anchor and selects the row ALONE, so the
    # SPACE that follows toggles that very row back OFF.
    @test selected_rows(m) == [2]
    @test press(m, "space")
    @test selected_rows(m) == Int[]
    @test press(m, "space")
    @test selected_rows(m) == [2]

    # Under SINGLE, toggling the one selected row off would leave a
    # single-select list with nothing selected, which is a
    # contradiction.
    s = List(["a", "b"])
    apply_stylesheet!(STYLESHEET_EMPTY, s)
    layout!(s, Region(1, 1, 10, 5))
    @test !press(s, "space")
    @test n_selected(s) == 0
end

@testitem "list: shift+arrow extends from the anchor" begin
    using DualUI
    l = List(["L$i" for i in 1:10]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    press(k) = (d = Dispatch(parse(KeyEvent, k), l);
                d.phase = Phase.AT_TARGET;
                on_event!(l, d); is_consumed(d))

    @test press("down")                 # cursor 2, anchor 2, {2}
    @test row_anchor(l) == 2
    @test selected_rows(l) == [2]
    @test press("shift+down")
    @test row_cursor(l) == 3
    @test row_anchor(l) == 2            # the anchor STAYS
    @test selected_rows(l) == [2, 3]
    @test press("shift+down")
    @test selected_rows(l) == [2, 3, 4]
    # An extend REPLACES, it does not union: back up and the range
    # shrinks with it.
    @test press("shift+up")
    @test selected_rows(l) == [2, 3]
    @test press("shift+up")
    @test selected_rows(l) == [2]
    @test press("shift+up")             # across the anchor
    @test row_cursor(l) == 1
    @test selected_rows(l) == [1, 2]
    # A bare move RE-PINS the anchor and selects alone.
    @test press("down")
    @test row_anchor(l) == 2
    @test selected_rows(l) == [2]
end

@testitem "list: LEFT and RIGHT scroll horizontally" begin
    using DualUI
    l = List(["abcdefghijklmnop"])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 5, 1))
    refresh_extent!(l)
    @test max_scroll(l) === Offset(11, 0)
    press(k) = (d = Dispatch(parse(KeyEvent, k), l);
                d.phase = Phase.AT_TARGET;
                on_event!(l, d); is_consumed(d))

    # THERE IS NO CELL CURSOR. LEFT/RIGHT scroll; they do not walk
    # columns.
    @test !press("left")                # at the left edge already
    @test press("right")
    @test scroll_of(l) === Offset(1, 0)
    @test row_cursor(l) == 1            # the cursor did NOT move
    buf = Buffer(5, 1)
    clear!(buf)
    render!(l, buf)
    @test string(buf) == "bcdef"
    @test press("left")
    @test scroll_of(l) === Offset(0, 0)
    clear!(buf)
    render!(l, buf)
    @test string(buf) == "abcde"

    for _ in 1:20
        press("right")
    end
    @test scroll_of(l) === Offset(11, 0)  # clamped by scroll_to!
    @test !press("right")                 # at the limit: it bubbles
end

@testitem "list: the horizontal mark cannot deadlock its own axis" begin
    using DualUI
    # THE FIXPOINT, and it is not hypothetical -- this is EXACTLY the
    # test above with its `refresh_extent!` removed, which is exactly
    # what an application looks like. A mark raised ONLY by `render!`
    # from what it PAINTS can never exceed `scroll.x + width`, because
    # a CUT row reports no further (`_tc_paint_slice!`). `_tc_scroll_x!`
    # moves via `scroll_to!`, CLAMPED to `max_scroll.x == widest -
    # width`. Together:
    #
    #     widest <= scroll.x + width   AND   scroll.x <= widest - width
    #     =>  scroll.x <= scroll.x
    #
    # The mark pins at the viewport width, `max_scroll.x` pins at ZERO,
    # and cells `width+1 ..` of EVERY row are unreachable FOREVER. The
    # mark cannot bootstrap: scrolling is what would raise it, and the
    # mark is what permits scrolling. The cure is that the mark is
    # measured from the DATA, never from the paint.
    l = List(["abcdefghijklmnop"])          # 16 cells of real data
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 5, 1))
    # NO `refresh_extent!`. The axis must work without an opt-in rescan.
    @test content_extent(l) === Size(16, 1)
    @test max_scroll(l) === Offset(11, 0)

    press(k) = (d = Dispatch(parse(KeyEvent, k), l);
                d.phase = Phase.AT_TARGET;
                on_event!(l, d); is_consumed(d))
    buf = Buffer(5, 1)
    # Interleaved with repaints, because painting is what USED to be the
    # only thing that could raise the mark.
    for _ in 1:11
        clear!(buf)
        render!(l, buf)
        @test press("right")
    end
    @test scroll_of(l) === Offset(11, 0)
    clear!(buf)
    render!(l, buf)
    @test string(buf) == "lmnop"        # the LAST cells, reachable
    @test !press("right")               # and it stops there, exactly

    # THE THUMB REPORTS THE REAL DATA EXTENT -- 16, not the 5 cells that
    # happen to be on screen -- and it does so BEFORE the first paint.
    h = List(["abcdefghijklmnop"])
    apply_stylesheet!(STYLESHEET_EMPTY, h)
    layout!(h, Region(1, 1, 5, 1))
    bar = Scrollbar(h, ScrollAxis.HORIZONTAL; mode = ScrollMode.AUTO)
    @test DualUI._sb_metrics(bar, 5) === (5, 5, 16, 0)
    # `(0, 0)` here would mean the bar draws NOTHING, ever.
    @test thumb_span(DualUI._sb_metrics(bar, 5)...) === (1, 2)
end

@testitem "list: the extent scan is lazy, memoized and monotone" begin
    using DualUI
    # THE CONSTRUCTOR STILL FORMATS NOTHING: the scan is deferred to the
    # first widget that ASKS how wide the content is -- a `Scrollbar`, a
    # `Scrollpane`, a `scroll_to!`. `List(1:100_000)` that nobody
    # scrolls pays for nothing. This is `_tc_resolve!`'s memo, which is
    # keyed on `(version, avail)`; this one is keyed on the data alone,
    # because `version` also bumps on every ARROW KEY and re-scanning a
    # 100 000-row list per keystroke is the cost this widget exists to
    # avoid.
    calls = Ref(0)
    f = x -> (calls[] += 1; string(x))
    l = List(collect(1:1000); format = f)
    @test calls[] == 0
    @test l.widest == 0
    @test !l.scanned

    # The FIRST query pays O(items), once.
    @test content_extent(l) === Size(4, 1000)     # "1000" is 4 cells
    @test calls[] == 1000
    @test l.scanned
    # Every later query is a memo HIT: O(1), ZERO allocation.
    @test content_extent(l) === Size(4, 1000)
    @test calls[] == 1000
    @test (@allocated content_extent(l)) == 0

    # A data change does NOT invalidate the memo, because `_lst_widen!`
    # MAINTAINS it: `max` over `items ∪ {x}` is `max(mark, width(x))`.
    push_item!(l, 1000000)
    @test calls[] == 1001               # ONE call: the mark raise
    @test content_extent(l) === Size(7, 1001)
    @test calls[] == 1001               # still a hit

    # An EMPTY list is scanned BY CONSTRUCTION: `0` is the exact maximum
    # over no rows. No work, no lie.
    e = List(String[])
    @test e.scanned
    @test content_extent(e) === Size(0, 0)
end

@testitem "list: the cursor stays visible as it moves" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    @test scroll_of(l).y == 0

    set_cursor!(l, 5)                   # the last VISIBLE row
    @test scroll_of(l).y == 0           # minimal movement: no move
    set_cursor!(l, 6)                   # one past the bottom
    @test scroll_of(l).y == 1
    set_cursor!(l, typemax(Int))        # all the way down
    @test row_cursor(l) == 20
    @test scroll_of(l).y == 15

    buf = Buffer(10, 5)
    clear!(buf)
    render!(l, buf)
    rows = split(string(buf), '\n')
    @test rows[1] == "L16       "
    @test rows[5] == "L20       "

    set_cursor!(l, 0)                   # and back to the top
    @test row_cursor(l) == 1
    @test scroll_of(l).y == 0
    clear!(buf)
    render!(l, buf)
    rows = split(string(buf), '\n')
    @test rows[1] == "L1        "

    # VERTICAL ONLY: the cursor is a ROW, not a cell, so there is
    # nothing to follow horizontally.
    @test set_scroll!(l, Offset(3, 0))
    set_cursor!(l, 10)
    @test scroll_of(l).x == 3
end

@testitem "list: following the cursor is a no-op before layout" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    # No layout yet: there is no window to move.
    @test set_cursor!(l, 20)
    @test row_cursor(l) == 20
    @test scroll_of(l) === ORIGIN
end

@testitem "list: a left press selects the row under the pointer" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    click(x, y) = dispatch_event!(l, MouseEvent(MouseAction.PRESS,
                                                MouseButton.LEFT,
                                                x, y, MOD_NONE))
    @test click(1, 3)
    @test row_cursor(l) == 3
    @test row_anchor(l) == 3
    @test selected_rows(l) == [3]
    @test click(5, 1)
    @test row_cursor(l) == 1
    @test selected_rows(l) == [1]

    # Arithmetic, not a hit test, and it honours the SCROLL: a click is
    # `scroll.y + local.y`, never the raw row.
    @test scroll_to!(l, Offset(0, 5)) === Offset(0, 5)
    @test click(1, 3)
    @test row_cursor(l) == 8
    @test selected_rows(l) == [8]

    # Outside the rows: nothing changes and nothing is consumed.
    @test set_scroll!(l, Offset(0, 18))
    @test !click(1, 5)                  # past the last row: untouched
    @test row_cursor(l) == 8
    @test !click(11, 1)                 # outside the content box
    @test !click(1, 6)
end

@testitem "list: a click under NONE still moves the cursor" begin
    using DualUI
    l = List(["a", "b", "c"]; mode = SelectMode.NONE)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 3))
    # A plain press routes through `set_cursor!`, NOT `select_only!`:
    # a browsable list whose rows cannot be clicked onto is not
    # browsable.
    @test dispatch_event!(l, MouseEvent(MouseAction.PRESS,
                                        MouseButton.LEFT, 1, 2,
                                        MOD_NONE))
    @test row_cursor(l) == 2
    @test n_selected(l) == 0
end

@testitem "list: ctrl+click toggles and a drag extends" begin
    using DualUI
    l = List(["L$i" for i in 1:10]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    ctrl = Modifiers(Modifier.CTRL)
    shift = Modifiers(Modifier.SHIFT)
    press(y, m) = dispatch_event!(l, MouseEvent(MouseAction.PRESS,
                                                MouseButton.LEFT, 1, y,
                                                m))
    drag(y) = dispatch_event!(l, MouseEvent(MouseAction.DRAG,
                                            MouseButton.LEFT, 1, y,
                                            MOD_NONE))
    @test press(1, MOD_NONE)
    @test selected_rows(l) == [1]
    @test press(3, ctrl)
    @test selected_rows(l) == [1, 3]
    @test press(3, ctrl)                # flips back off
    @test selected_rows(l) == [1]

    # A press-drag paints a range.
    @test press(2, MOD_NONE)
    @test selected_rows(l) == [2]
    @test drag(4)
    @test selected_rows(l) == [2, 3, 4]
    @test drag(1)                       # back across the anchor
    @test selected_rows(l) == [1, 2]

    # shift+click extends from the anchor and REPLACES.
    @test press(5, shift)
    @test selected_rows(l) == [2, 3, 4, 5]
end

@testitem "list: the wheel scrolls the body and chains" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    wheel(b, m = MOD_NONE) =
        dispatch_event!(l, MouseEvent(MouseAction.PRESS, b, 1, 1, m))

    @test wheel(MouseButton.WHEEL_DOWN)
    @test scroll_of(l) === Offset(0, DualUI.TC_WHEEL_STEP)
    @test row_cursor(l) == 1            # the wheel does NOT move it
    @test wheel(MouseButton.WHEEL_UP)
    @test scroll_of(l) === ORIGIN
    # At the limit the notch is NOT consumed: it bubbles to the next
    # pane out. Scroll chaining, out of the phase rule alone.
    @test !wheel(MouseButton.WHEEL_UP)

    # Nothing to scroll horizontally on a mark of zero.
    @test !wheel(MouseButton.WHEEL_RIGHT)
    refresh_extent!(l)                  # "L20" is 3 cells; box is 10
    @test !wheel(MouseButton.WHEEL_RIGHT)

    # SHIFT swaps the axis.
    shift = Modifiers(Modifier.SHIFT)
    @test wheel(MouseButton.WHEEL_DOWN, shift) === false
    wide = List(["abcdefghijklmnopqrstuvwxyz"])
    apply_stylesheet!(STYLESHEET_EMPTY, wide)
    layout!(wide, Region(1, 1, 5, 1))
    refresh_extent!(wide)
    @test dispatch_event!(wide, MouseEvent(MouseAction.PRESS,
                                           MouseButton.WHEEL_DOWN, 1, 1,
                                           shift))
    @test scroll_of(wide) === Offset(DualUI.TC_WHEEL_STEP_X, 0)
end

@testitem "list: the selection survives a scroll" begin
    using DualUI
    l = List(["L$i" for i in 1:20]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    set_cursor!(l, 2)
    sel_extend_ids!(selection_of(l), 2:4)
    @test selected_rows(l) == [2, 3, 4]

    # A scroll is a claim about the WINDOW; a selection is a claim about
    # ROWS. The two cannot touch.
    @test scroll_to!(l, Offset(0, 15)) === Offset(0, 15)
    @test selected_rows(l) == [2, 3, 4]
    @test row_cursor(l) == 2
    @test scroll_to!(l, Offset(0, 0)) === ORIGIN
    @test selected_rows(l) == [2, 3, 4]
    @test row_cursor(l) == 2

    # And it survives a repaint at a scrolled window, which re-syncs the
    # selection every frame.
    @test set_scroll!(l, Offset(0, 10))
    buf = Buffer(10, 5)
    clear!(buf)
    render!(l, buf)
    @test selected_rows(l) == [2, 3, 4]
    @test n_rows(selection_of(l)) == 20
end

@testitem "list: the selection bar spans the full width" begin
    using DualUI
    l = List(["ab", "cd", "ef"])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 5, 3))
    set_cursor!(l, 2)                   # selects row 2 alone
    @test selected_rows(l) == [2]

    buf = Buffer(5, 3)
    clear!(buf)
    render!(l, buf)
    @test string(buf) == "ab   \ncd   \nef   "
    # `style_region!` MERGES onto the cells already there, and `frame!`
    # blanks the back buffer every frame -- so reversing a never-written
    # padding cell IS the bar, with no fill pass at all.
    for x in 1:5
        @test has(buf[x, 2].style, Attr.REVERSE)
        @test !has(buf[x, 1].style, Attr.REVERSE)
        @test !has(buf[x, 3].style, Attr.REVERSE)
    end
    @test buf[1, 2].content == "c"
    @test buf[5, 2].content == " "
end

@testitem "list: the cursor bar is drawn only while focused" begin
    using DualUI
    l = List(["a", "b", "c"]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 3, 3))
    set_cursor!(l, 2)
    toggle_row!(l, 2)                   # cursor 2, nothing selected
    @test n_selected(l) == 0
    @test row_cursor(l) == 2

    buf = Buffer(3, 3)
    clear!(buf)
    render!(l, buf)
    # An unfocused list shows its selection and HIDES its cursor --
    # exactly as `TextInput` hides its caret on blur.
    @test !has(buf[1, 2].style, Attr.UNDERLINE)

    on_focus!(l)
    @test is_focused(l)
    clear!(buf)
    render!(l, buf)
    for x in 1:3
        @test has(buf[x, 2].style, Attr.UNDERLINE)
        @test !has(buf[x, 2].style, Attr.REVERSE)
    end
    on_blur!(l)
    @test !is_focused(l)
    clear!(buf)
    render!(l, buf)
    @test !has(buf[1, 2].style, Attr.UNDERLINE)
end

@testitem "list: selection and cursor are two independent bits" begin
    using DualUI
    l = List(["a", "b", "c"]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 3, 3))
    on_focus!(l)
    toggle_row!(l, 3)                   # selects 3, cursor lands on 3
    set_cursor!(l, 1; extend = true)    # cursor 1, selection {1,2,3}
    @test row_cursor(l) == 1
    @test selected_rows(l) == [1, 2, 3]
    toggle_row!(l, 2)                   # drop 2; cursor re-pins to 2
    @test !is_selected(l, 2)
    @test row_cursor(l) == 2

    buf = Buffer(3, 3)
    clear!(buf)
    render!(l, buf)
    # Row 2: the cursor, NOT selected. In MULTI the cursor is
    # frequently not on a selected row, and a user who cannot see which
    # row ENTER will act on has no cursor at all.
    @test has(buf[1, 2].style, Attr.UNDERLINE)
    @test !has(buf[1, 2].style, Attr.REVERSE)
    # Rows 1 and 3: selected, not the cursor.
    @test has(buf[1, 1].style, Attr.REVERSE)
    @test !has(buf[1, 1].style, Attr.UNDERLINE)
    @test has(buf[1, 3].style, Attr.REVERSE)
    @test !has(buf[1, 3].style, Attr.UNDERLINE)

    # A row that is BOTH composes: they MERGE.
    set_cursor!(l, 3)
    clear!(buf)
    render!(l, buf)
    @test has(buf[1, 3].style, Attr.REVERSE)
    @test has(buf[1, 3].style, Attr.UNDERLINE)
end

@testitem "list: a wide cluster at the RIGHT edge is never halved" begin
    using DualUI
    l = List(["a世"])
    buf = Buffer(2, 1)
    clear!(buf)
    render!(l, buf)
    # "世" needs TWO cells and only one is left: `set_cell!` REFUSES
    # it rather than halving it. A halved cluster would orphan a
    # continuation and desynchronise the grid.
    @test buf[1, 1].content == "a"
    @test buf[2, 1].content == " "
    @test !is_continuation(buf[2, 1])

    # One more cell and it lands whole, with its continuation.
    wide = Buffer(3, 1)
    clear!(wide)
    render!(l, wide)
    @test wide[1, 1].content == "a"
    @test wide[2, 1].content == "世"
    @test wide[2, 1].width == Int8(2)
    @test is_continuation(wide[3, 1])
end

@testitem "list: a wide cluster at the LEFT edge is dropped whole" begin
    using DualUI
    l = List(["世界"])
    @test set_scroll!(l, Offset(1, 0))
    buf = Buffer(6, 1)
    clear!(buf)
    render!(l, buf)
    # A cluster straddling the LEFT edge lands on `cx <= 0` and is
    # skipped WHOLE, so `set_cell!` never sees the half of it that would
    # orphan a continuation into column 1.
    @test buf[1, 1].content == " "
    @test !is_continuation(buf[1, 1])
    @test buf[2, 1].content == "界"
    @test buf[2, 1].width == Int8(2)
    @test is_continuation(buf[3, 1])

    @test set_scroll!(l, Offset(2, 0))
    clear!(buf)
    render!(l, buf)
    @test buf[1, 1].content == "界"     # now flush at the edge
end

@testitem "list: the mark counts CELLS, never characters" begin
    using DualUI
    # `Base.textwidth` is FORBIDDEN: it reports 1 for a VS16 emoji
    # occupying 2 cells and 8 for a ZWJ family occupying 2.
    l = List(["世界", "a"])
    @test refresh_extent!(l) === Size(4, 2)   # two clusters, FOUR cells
    @test l.widest == 4

    fam = List(["👨‍👩‍👧‍👦"])      # ONE cluster, TWO cells
    @test refresh_extent!(fam) === Size(2, 1)
    @test text_width(fam.items[1]) == 2
    @test grapheme_width(fam.items[1]) == 2

    vs = List(["✌️"])                        # VS16: TWO cells
    @test refresh_extent!(vs) === Size(2, 1)

    # And the PAINTED mark agrees with the rescanned one, because both
    # count cells.
    buf = Buffer(9, 2)
    clear!(buf)
    p = List(["世界", "a"])
    render!(p, buf)
    @test p.widest == 4
    @test string(buf) == "世界     \na        "
end

@testitem "list: the painted mark is a high-water mark" begin
    using DualUI
    l = List(["short", "a much longer row", "mid row"])
    buf = Buffer(6, 3)
    clear!(buf)
    render!(l, buf)
    # A CUT row raises the mark to AT LEAST `skip + width`: understating
    # it is exactly what a high-water mark does, and it costs the paint
    # loop NOTHING.
    @test l.widest == 6
    @test string(buf) == "short \na much\nmid ro"

    # Scrolling right raises it further -- the mark records what has
    # been SEEN.
    @test set_scroll!(l, Offset(6, 0))
    clear!(buf)
    render!(l, buf)
    @test l.widest == 12
    # And the exact rescan is the mirror image of `TextArea`'s: a List
    # starts TOO NARROW and `refresh_extent!` makes it exact.
    @test refresh_extent!(l) === Size(17, 3)
    @test l.widest == 17

    # MONOTONE: nothing but `refresh_extent!` lowers it.
    @test !delete_item!(l, 9)
    @test delete_item!(l, 2)
    @test l.widest == 17                # still too wide: documented
    @test refresh_extent!(l) === Size(7, 2)
end

@testitem "list: refresh_extent! re-clamps a stranded offset" begin
    using DualUI
    l = List(["a very wide row indeed", "b"])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 5, 2))
    refresh_extent!(l)
    @test scroll_to!(l, Offset(17, 0)) === Offset(17, 0)
    @test delete_item!(l, 1)
    # This is the only call that can SHRINK the extent and strand an
    # offset past the end.
    @test refresh_extent!(l) === Size(1, 1)
    @test scroll_of(l) === ORIGIN
end

@testitem "list: push_item! is O(1) plus a mark raise" begin
    using DualUI
    calls = Ref(0)
    f = x -> (calls[] += 1; string(x))
    l = List(String[]; format = f)
    @test row_count(l) == 0
    @test row_cursor(l) == 0

    push_item!(l, "abc")
    # The formatter is called EXACTLY ONCE -- for the mark raise, never
    # for the rest of the data.
    @test calls[] == 1
    @test l.items == ["abc"]
    @test l.widest == 3
    @test row_count(l) == 1
    @test n_rows(selection_of(l)) == 1
    # The cursor appears with the first row: `0` IFF `n == 0`.
    @test row_cursor(l) == 1
    @test n_selected(l) == 0

    push_item!(l, "de")
    @test calls[] == 2
    @test l.widest == 3                 # MONOTONE: "de" is narrower
    @test content_extent(l) === Size(3, 2)
    @test l.version[] > 0
end

@testitem "list: insert_item! reindexes the selection" begin
    using DualUI
    l = List(["a", "b", "c"]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    set_cursor!(l, 2)
    sel_extend_ids!(selection_of(l), 2:3)
    @test selected_rows(l) == [2, 3]
    @test row_cursor(l) == 2

    # Everything at or above `i` moves up one. Source indices are
    # structurally safe against REORDERING; they are NOT safe against
    # insertion, and this is the price -- paid by the mutation.
    insert_item!(l, 2, "new")
    @test l.items == ["a", "new", "b", "c"]
    @test selected_rows(l) == [3, 4]
    @test row_cursor(l) == 3
    @test row_count(l) == 4
    @test n_rows(selection_of(l)) == 4

    # Below the insert: nothing moves.
    insert_item!(l, 1, "top")
    @test selected_rows(l) == [4, 5]
    insert_item!(l, 99, "end")          # clamped to length + 1
    @test l.items[end] == "end"
    @test selected_rows(l) == [4, 5]
    insert_item!(l, -5, "first")        # clamped to 1
    @test l.items[1] == "first"
    @test selected_rows(l) == [5, 6]
end

@testitem "list: delete_item! reindexes the selection" begin
    using DualUI
    l = List(["a", "b", "c", "d"]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    set_cursor!(l, 2)
    sel_extend_ids!(selection_of(l), 2:3)
    @test selected_rows(l) == [2, 3]

    # `i` itself leaves the selection; everything above moves down one.
    @test delete_item!(l, 2)
    @test l.items == ["a", "c", "d"]
    @test selected_rows(l) == [2]       # old row 3 ("c") is now row 2
    @test row_count(l) == 3
    @test n_rows(selection_of(l)) == 3
    # The cursor was ON `i`: it stays at `i` and lands on the row that
    # took its place.
    @test row_cursor(l) == 2

    @test !delete_item!(l, 0)
    @test !delete_item!(l, 4)
    @test !delete_item!(l, -1)
    @test row_count(l) == 3

    # Deleting the LAST row: the cursor lands on the new last row.
    set_cursor!(l, 3)
    @test delete_item!(l, 3)
    @test row_cursor(l) == 2
    @test delete_item!(l, 1)
    @test delete_item!(l, 1)
    @test row_count(l) == 0
    @test row_cursor(l) == 0            # `0` IFF `n == 0`
    @test n_selected(l) == 0
end

@testitem "list: set_items! clears the selection and rewinds" begin
    using DualUI
    l = List(["L$i" for i in 1:20]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    refresh_extent!(l)
    set_cursor!(l, 10)
    sel_extend_ids!(selection_of(l), 8:12)
    @test scroll_of(l).y == 5           # row 10 is the LAST visible row
    @test selected_rows(l) == [8, 9, 10, 11, 12]

    # Every index the selection held names a row that may no longer
    # exist, and silently keeping them would select the WRONG ROWS.
    set_items!(l, ["x", "y"])
    @test l.items == ["x", "y"]
    @test row_count(l) == 2
    @test n_selected(l) == 0
    @test selected_rows(l) == Int[]
    @test row_cursor(l) == 1
    @test row_anchor(l) == 1
    @test scroll_of(l) === ORIGIN
    # The OLD mark was about data that no longer exists -- a stale
    # number, not a high-water mark -- so `set_items!` INVALIDATES it
    # and the new data is MEASURED, never inherited and never guessed.
    # "x"/"y" are 1 cell; the 3-cell mark "L20" left is gone.
    @test l.widest == 1
    @test content_extent(l) === Size(1, 2)

    # `items` is ALIASED, so `set_items!` fills it in place rather than
    # rebinding: the caller's Vector is the widget's Vector.
    set_items!(l, String[])
    @test row_count(l) == 0
    @test row_cursor(l) == 0
    @test content_extent(l) === Size(0, 0)
end

@testitem "list: set_items! keeps the aliased vector identity" begin
    using DualUI
    xs = ["a", "b"]
    l = List(xs)
    set_items!(l, ["c", "d", "e"])
    @test l.items === xs                # the SAME Vector, refilled
    @test xs == ["c", "d", "e"]
end

@testitem "list: refresh_rows! is the escape hatch" begin
    using DualUI
    xs = ["L$i" for i in 1:20]
    l = List(xs; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    set_cursor!(l, 20)
    @test scroll_of(l).y == 15
    v = l.version[]

    # "I mutated `items` myself": THE public escape hatch.
    resize!(xs, 3)
    refresh_rows!(l)
    @test l.version[] == v + 1          # it repaints
    @test row_count(l) == 3
    @test n_rows(selection_of(l)) == 3  # the selection re-syncs
    @test row_cursor(l) == 3            # the cursor re-clamps
    @test scroll_of(l) === ORIGIN       # the offset re-clamps
end

@testitem "list: a mutation behind version's back cannot corrupt" begin
    using DualUI
    xs = ["L$i" for i in 1:20]
    l = List(xs)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    set_cursor!(l, 20)
    @test row_cursor(l) == 20

    # THE PRICE, stated in the docstring: `items` mutated behind
    # `version`'s back will not repaint. It will NOT CORRUPT, because
    # `render!` re-syncs the row count every frame -- it downgrades the
    # footgun from CORRUPTION to STALENESS.
    resize!(xs, 2)
    buf = Buffer(10, 5)
    clear!(buf)
    render!(l, buf)                     # must not throw
    # SELF-HEALED: `_tc_sync!` makes a cursor past the end
    # STRUCTURALLY IMPOSSIBLE even here, at ONE Int compare per frame.
    @test row_cursor(l) == 2
    @test n_rows(selection_of(l)) == 2
    @test row_count(l) == 2

    # STALE, and precisely this stale: the OFFSET is still 15, because
    # `render!` does NOT re-clamp it -- `scroll_to!` would cost a
    # `content_extent` call on the frame path, every frame, to repair a
    # mistake the caller made. So the window sits past the end and the
    # frame is BLANK. Blank, not wrong, and never a BoundsError.
    @test scroll_of(l).y == 15
    @test string(buf) == repeat("          \n", 4) * "          "

    # `refresh_rows!` is the cure, and this is what it is FOR.
    refresh_rows!(l)
    @test scroll_of(l) === ORIGIN
    clear!(buf)
    render!(l, buf)
    rows = split(string(buf), '\n')
    @test rows[1] == "L1        "
    @test rows[2] == "L2        "
    @test rows[3] == "          "

    empty!(xs)
    clear!(buf)
    render!(l, buf)
    @test row_cursor(l) == 0
    @test string(buf) == repeat("          \n", 4) * "          "
end

@testitem "list: the data ops keep the cursor visible" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    set_cursor!(l, 20)
    @test scroll_of(l).y == 15
    # Deleting the row under the cursor pulls the window back with it.
    for _ in 1:10
        delete_item!(l, row_count(l))
    end
    @test row_count(l) == 10
    @test row_cursor(l) == 10
    @test scroll_of(l).y == 5
end

@testitem "list: a formatter renders non-string items" begin
    using DualUI
    l = List([1, 22, 333])
    buf = Buffer(4, 3)
    clear!(buf)
    render!(l, buf)
    @test string(buf) == "1   \n22  \n333 "
    @test l.widest == 3

    pad = List([1, 2]; format = x -> "<$x>")
    clear!(buf)
    render!(pad, buf)
    @test split(string(buf), '\n')[1] == "<1> "
    @test pad isa List{Int}
end

@testitem "list: on_focus! reveals and on_blur! hides" begin
    using DualUI
    inner = List(["L$i" for i in 1:20])
    pane = Scrollpane(Container(inner); bar_y = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 10, 5))
    @test !is_focused(inner)
    on_focus!(inner)
    # `reveal!` is called EXPLICITLY because overriding `on_focus!`
    # REPLACES the default that would have called it.
    @test is_focused(inner)
    on_blur!(inner)
    @test !is_focused(inner)
end

@testitem "list: Scrollbar{List} needs no new code in scroll.jl" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    bar = Scrollbar(l, ScrollAxis.VERTICAL)
    # PARAMETRIC on the viewport type: the scrollable seam is three
    # functions, not a type.
    @test bar isa Scrollbar{<:List}
    @test bar.viewport === l

    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 5))
    @test content_extent(l) === Size(3, 20)   # "L20" is 3 cells
    # The rows are narrower than the 10-cell box, so there is nothing to
    # scroll horizontally -- `0`, from a mark of 3 rather than from a
    # mark that never got measured.
    @test max_scroll(l) === Offset(0, 15)

    # `_sb_metrics` reads `content_extent`, `layout_of(...).content` and
    # `scroll_of` -- the whole seam -- and nothing else.
    @test DualUI._sb_metrics(bar, 5) === (5, 5, 20, 0)
    @test thumb_span(DualUI._sb_metrics(bar, 5)...) == (1, 1)

    scroll_to!(l, Offset(0, 15))
    @test DualUI._sb_metrics(bar, 5) === (5, 5, 20, 15)
    # `off == total - view` pins the thumb to the LAST cell EXACTLY.
    start, len = thumb_span(DualUI._sb_metrics(bar, 5)...)
    @test start + len - 1 == 5

    # The horizontal bar reports THE REAL DATA EXTENT -- "L20" is 3
    # cells -- and it does so without an opt-in rescan and before the
    # first paint. A `0` here would be the bar reporting that content it
    # can measure does not exist.
    h = Scrollbar(l, ScrollAxis.HORIZONTAL)
    @test DualUI._sb_metrics(h, 10) === (10, 10, 3, 0)
    refresh_extent!(l)
    @test DualUI._sb_metrics(h, 10) === (10, 10, 3, 0)
end

@testitem "list: a Scrollbar paints a List with no new code" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    bar = Scrollbar(l, ScrollAxis.VERTICAL; mode = ScrollMode.ALWAYS)
    l.node.inline_box = BoxPatch(; grow = 1f0)
    bar.node.inline_box = BoxPatch(; width = cells(1), shrink = 0f0,
                                   grow = 0f0)
    root = Container(l, bar)
    root.node.inline_box = BoxPatch(; display = Display.FLEX,
                                    direction = Direction.ROW)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 6, 4))
    @test layout_of(bar).content.width == 1
    @test layout_of(l).content === Region(1, 1, 5, 4)

    buf = Buffer(6, 4)
    clear!(buf)
    paint!(buf, root)
    col = [buf[6, y].content for y in 1:4]
    # track 4, view 4, total 20 -> a 1-cell thumb pinned to the top.
    @test col[1] == DualUI.SB_THUMB
    @test all(==(DualUI.SB_TRACK_V), col[2:4])

    scroll_to!(l, Offset(0, 16))
    clear!(buf)
    paint!(buf, root)
    col = [buf[6, y].content for y in 1:4]
    @test col[4] == DualUI.SB_THUMB     # pinned to the BOTTOM
    @test all(==(DualUI.SB_TRACK_V), col[1:3])
end

@testitem "list: Scrollpane(List(...)) composes" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    # The two mechanisms COMPOSE rather than compete, exactly as they do
    # for TextArea: the pane scrolls the List's whole BOX, the List
    # scrolls its own DATA.
    pane = Scrollpane(Container(l); bar_y = ScrollMode.NEVER,
                      bar_x = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 10, 5))
    buf = Buffer(10, 5)
    clear!(buf)
    paint!(buf, pane)
    @test split(string(buf), '\n')[1] == "L1        "

    # The List's OWN offset still moves its own data, inside the pane.
    @test scroll_to!(l, Offset(0, 3)) === Offset(0, 3)
    clear!(buf)
    paint!(buf, pane)
    @test split(string(buf), '\n')[1] == "L4        "
end

@testitem "list: a click inside a scrolled pane hits the right row" begin
    using DualUI
    l = List(["L$i" for i in 1:20])
    # A List takes the height it is OFFERED, so a pane wrapped round one
    # has nothing to scroll until the List is given a box TALLER than
    # the pane. That is the documented usage -- "give it `height: 10` or
    # a `grow: 1` parent" -- and it is what makes this test possible at
    # all.
    l.node.inline_box = BoxPatch(; height = cells(10), shrink = 0f0,
                                 grow = 0f0)
    pane = Scrollpane(l; bar_y = ScrollMode.NEVER,
                      bar_x = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 10, 5))
    @test layout_of(l).content.height == 10
    @test max_scroll(viewport(pane)) === Offset(0, 5)

    # `local_offset` is measured from the UNSHIFTED border box, so a
    # List inside a pane scrolled to `y = 2` would select the row TWO
    # ABOVE the pointer. `_tc_local` honours every scrolled ancestor,
    # and this is the test that would catch the difference.
    @test dispatch_event!(pane, MouseEvent(MouseAction.PRESS,
                                           MouseButton.LEFT, 1, 3,
                                           MOD_NONE))
    @test row_cursor(l) == 3

    @test scroll_to!(pane, Offset(0, 2)) === Offset(0, 2)
    @test dispatch_event!(pane, MouseEvent(MouseAction.PRESS,
                                           MouseButton.LEFT, 1, 3,
                                           MOD_NONE))
    # Row 5 is what is UNDER the pointer once the pane has shifted the
    # list up by two. Row 3 would be the `local_offset` bug.
    @test row_cursor(l) == 5
end

@testitem "list: select_all! and clear_selection! are public" begin
    using DualUI
    l = List(["a", "b", "c"]; mode = SelectMode.MULTI)
    apply_stylesheet!(STYLESHEET_EMPTY, l)
    layout!(l, Region(1, 1, 10, 3))
    @test select_all!(l)
    @test selected_rows(l) == [1, 2, 3]
    @test !select_all!(l)
    @test clear_selection!(l)
    @test selected_rows(l) == Int[]
    @test row_cursor(l) == 1            # the CURSOR STAYS
    @test !clear_selection!(l)

    # MULTI only.
    s = List(["a", "b"])
    @test !select_all!(s)
end
