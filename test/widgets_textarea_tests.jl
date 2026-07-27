# widgets_textarea_tests.jl -- multi-line text entry (layer 7).
#
# Every testitem is self-contained, starts `using ManyUI`, needs no tty,
# never sleeps and bounds every wait.
#
# The grapheme discipline asserted here is the SAME one `TextInput`
# obeys: the caret steps by CLUSTER, a wide cluster is ONE step and TWO
# cells, and `Base.textwidth` appears nowhere.

@testitem "textarea: lines is never empty" begin
    using ManyUI
    a = TextArea()
    @test a isa Widget
    @test a.lines == [""]
    @test a.line == 1
    @test a.col == 0
    @test type_name(a) === :TextArea
    @test is_focusable(a)

    @test TextArea("").lines == [""]

    c = TextArea("a\nb")
    move_by!(c, 100)
    @test backspace!(c)
    @test backspace!(c)
    @test backspace!(c)
    @test c.lines == [""]
    @test c.line == 1
    @test c.col == 0

    set_text!(c, "")
    @test c.lines == [""]
end

@testitem "textarea: ids are unique by default" begin
    using ManyUI
    @test id(TextArea("x")) !== id(TextArea("x"))
end

@testitem "textarea: measure takes the space it is offered" begin
    using ManyUI
    @test measure(TextArea("x"), Size(20, 7)) == Size(20, 7)
    tall = TextArea(join(fill("y", 100), "\n"))
    @test measure(tall, Size(4, 3)) == Size(4, 3)
    @test measure(TextArea(), Size(0, 0)) == Size(0, 0)
end

@testitem "textarea: insert_text! inserts at the caret" begin
    using ManyUI
    a = TextArea("ac")
    move_by!(a, 1)
    insert_text!(a, "b")
    @test a.lines == ["abc"]
    @test a.line == 1
    @test a.col == 2

    b = TextArea("ad")
    move_by!(b, 1)
    insert_text!(b, "b\nc")
    @test b.lines == ["ab", "cd"]
    @test b.line == 2
    @test b.col == 1

    c = TextArea("xy")
    move_by!(c, 1)
    insert_text!(c, "1\n2\n3")
    @test c.lines == ["x1", "2", "3y"]
    @test c.line == 3
    @test c.col == 1

    d = TextArea("q")
    insert_text!(d, "")
    @test d.lines == ["q"]
    @test d.col == 0
end

@testitem "textarea: ENTER splits the line at the caret" begin
    using ManyUI
    a = TextArea("hello")
    move_by!(a, 2)
    insert_newline!(a)
    @test a.lines == ["he", "llo"]
    @test a.line == 2
    @test a.col == 0

    # At the very start: a fresh empty line ABOVE.
    b = TextArea("hi")
    insert_newline!(b)
    @test b.lines == ["", "hi"]
    @test b.line == 2
    @test b.col == 0

    # At the very end: a fresh empty line BELOW.
    c = TextArea("hi")
    move_by!(c, 2)
    insert_newline!(c)
    @test c.lines == ["hi", ""]
    @test c.line == 2
    @test c.col == 0
end

@testitem "textarea: backspace at column 0 joins the previous line" begin
    using ManyUI
    a = TextArea("ab\ncd")
    move_line!(a, 1)
    @test a.line == 2
    @test a.col == 0
    @test backspace!(a)
    @test a.lines == ["abcd"]
    @test a.line == 1
    @test a.col == 2                # the caret lands ON the join

    # Joining onto an EMPTY previous line.
    b = TextArea("\nxy")
    move_line!(b, 1)
    @test backspace!(b)
    @test b.lines == ["xy"]
    @test b.line == 1
    @test b.col == 0
end

@testitem "textarea: delete at end of line joins the next line" begin
    using ManyUI
    a = TextArea("ab\ncd")
    move_by!(a, 2)
    @test (a.line, a.col) == (1, 2)
    @test delete_forward!(a)
    @test a.lines == ["abcd"]
    @test a.line == 1
    @test a.col == 2

    # At the end of the LAST line there is nothing to join.
    b = TextArea("ab")
    move_by!(b, 2)
    @test delete_forward!(b) === false
    @test b.lines == ["ab"]

    # Joining an EMPTY next line just removes it.
    c = TextArea("ab\n")
    move_by!(c, 2)
    @test delete_forward!(c)
    @test c.lines == ["ab"]
    @test c.col == 2
end

@testitem "textarea: backspace at (1, 0) is a no-op returning false" begin
    using ManyUI
    a = TextArea("abc")
    v = a.version[]
    @test backspace!(a) === false
    @test a.lines == ["abc"]
    @test a.line == 1
    @test a.col == 0
    @test a.version[] == v

    empty = TextArea()
    @test backspace!(empty) === false
    @test empty.lines == [""]
end

@testitem "textarea: left and right cross line boundaries" begin
    using ManyUI
    a = TextArea("ab\ncd")
    move_by!(a, 3)
    @test (a.line, a.col) == (2, 0)
    move_by!(a, -1)
    @test (a.line, a.col) == (1, 2)
    move_by!(a, 1)
    @test (a.line, a.col) == (2, 0)

    # Clamped at both ends of the DOCUMENT, never past them.
    move_by!(a, 1000)
    @test (a.line, a.col) == (2, 2)
    move_by!(a, 1)
    @test (a.line, a.col) == (2, 2)
    move_by!(a, -1000)
    @test (a.line, a.col) == (1, 0)
    move_by!(a, -1)
    @test (a.line, a.col) == (1, 0)
end

@testitem "textarea: goal survives UP/DOWN through a short line" begin
    using ManyUI
    a = TextArea("abcdefgh\nxy\nijklmnop")
    move_by!(a, 6)
    @test (a.line, a.col) == (1, 6)
    @test a.goal == 6

    move_line!(a, 1)                # through the SHORT line
    @test (a.line, a.col) == (2, 2)
    @test a.goal == 6               # remembered, not clobbered

    move_line!(a, 1)
    @test (a.line, a.col) == (3, 6) # the goal SURVIVED the short line

    move_line!(a, -1)
    @test (a.line, a.col) == (2, 2)
    move_line!(a, -1)
    @test (a.line, a.col) == (1, 6) # back where the user started
end

@testitem "textarea: a horizontal move resets goal" begin
    using ManyUI
    a = TextArea("abcdefgh\nxy\nijklmnop")
    move_by!(a, 6)
    @test a.goal == 6
    move_line!(a, 2)
    @test (a.line, a.col) == (3, 6)
    @test a.goal == 6

    move_by!(a, -1)                 # a HORIZONTAL move re-pins the goal
    @test (a.line, a.col) == (3, 5)
    @test a.goal == 5
    move_line!(a, -2)
    @test (a.line, a.col) == (1, 5)

    # So does an EDIT.
    b = TextArea("abcdefgh\nxy\nijklmnop")
    move_by!(b, 6)
    move_line!(b, 1)
    @test b.goal == 6
    insert_text!(b, "Z")
    @test b.lines[2] == "xyZ"
    @test b.goal == 3
end

@testitem "textarea: UP/DOWN never land inside a wide cluster" begin
    using ManyUI
    # Line 2 is three CJK clusters, ENDING at cells 2, 4 and 6.
    a = TextArea("abcde\n世世世")
    move_by!(a, 3)
    @test a.goal == 3
    move_line!(a, 1)
    # Goal 3 falls INSIDE the second cluster (cells 3-4); the caret
    # lands on the boundary BEFORE it, never in the middle.
    @test (a.line, a.col) == (2, 1)
    cells = grapheme_cells(a.lines[2])
    @test sum(c[2] for c in cells[1:a.col]) == 2

    move_line!(a, -1)
    @test (a.line, a.col) == (1, 3)   # and the goal brought it back

    # A goal landing exactly ON a boundary lands exactly there.
    b = TextArea("abcde\n世世世")
    move_by!(b, 4)
    @test b.goal == 4
    move_line!(b, 1)
    @test (b.line, b.col) == (2, 2)
end

@testitem "textarea: goal is in CELLS, not graphemes" begin
    using ManyUI
    a = TextArea("世界ab\nabcdef")
    move_by!(a, 2)                  # after TWO clusters == FOUR cells
    @test a.col == 2
    @test a.goal == 4               # cells, not the grapheme count 2

    move_line!(a, 1)
    # A grapheme goal would land on col 2; a CELL goal lands on col 4.
    @test (a.line, a.col) == (2, 4)
end

@testitem "textarea: content_extent is (widest, line count)" begin
    using ManyUI
    a = TextArea("ab\n世界世\nx")
    @test content_extent(a) == Size(6, 3)
    @test content_extent(TextArea()) == Size(0, 1)
    @test content_extent(TextArea("abc")) == Size(3, 1)

    # An edit RAISES the high-water mark in O(1).
    b = TextArea("ab")
    @test content_extent(b) == Size(2, 1)
    move_by!(b, 2)
    insert_text!(b, "cdef")
    @test content_extent(b) == Size(6, 1)
    insert_newline!(b)
    @test content_extent(b) == Size(6, 2)
end

@testitem "textarea: refresh_extent! lowers the high-water mark" begin
    using ManyUI
    a = TextArea("abcdef\nx")
    @test content_extent(a) == Size(6, 2)
    move_by!(a, 6)
    for _ in 1:6
        @test backspace!(a)
    end
    @test a.lines == ["", "x"]
    # The mark is MONOTONE: nothing lowers it until asked.
    @test content_extent(a) == Size(6, 2)
    @test refresh_extent!(a) == Size(1, 2)
    @test content_extent(a) == Size(1, 2)
end

@testitem "textarea: version bumps exactly once per edit" begin
    using ManyUI
    changes = Ref(0)
    a = TextArea("ab", _ -> (changes[] += 1; nothing))
    v = a.version[]

    insert_text!(a, "x")
    @test a.version[] == v + 1
    @test changes[] == 1

    insert_newline!(a)
    @test a.version[] == v + 2
    @test changes[] == 2

    @test backspace!(a)
    @test a.version[] == v + 3
    @test changes[] == 3

    # A REFUSED edit bumps nothing and fires nothing.
    move_by!(a, -1000)
    @test backspace!(a) === false
    @test a.version[] == v + 3
    @test changes[] == 3

    # A MOVE is not an edit.
    move_by!(a, 1)
    move_line!(a, 1)
    @test a.version[] == v + 3
    @test changes[] == 3
end

@testitem "textarea: paste splits on newlines into real lines" begin
    using ManyUI
    a = TextArea("ab")
    move_by!(a, 1)
    d = Dispatch(PasteEvent("X\nY\nZ"), a)
    d.phase = Phase.AT_TARGET
    on_event!(a, d)
    @test is_consumed(d)
    @test a.lines == ["aX", "Y", "Zb"]
    @test a.line == 3
    @test a.col == 1

    # A single-line paste is an ordinary insert.
    b = TextArea("ab")
    move_by!(b, 1)
    e = Dispatch(PasteEvent("QQ"), b)
    e.phase = Phase.AT_TARGET
    on_event!(b, e)
    @test b.lines == ["aQQb"]
    @test b.col == 3

    # A paste ENDING in a newline leaves a real empty line.
    c = TextArea("ab")
    move_by!(c, 2)
    f = Dispatch(PasteEvent("z\n"), c)
    f.phase = Phase.AT_TARGET
    on_event!(c, f)
    @test c.lines == ["abz", ""]
    @test c.line == 2
    @test c.col == 0
end

@testitem "textarea: set_text! resets the caret, scroll and extent" begin
    using ManyUI
    a = TextArea("aaaaaaaaaaaa\nbbb")
    move_line!(a, 1)
    move_by!(a, 2)
    @test set_scroll!(a, Offset(3, 1))
    @test scroll_of(a) === Offset(3, 1)

    set_text!(a, "x\ny")
    @test a.lines == ["x", "y"]
    @test a.line == 1
    @test a.col == 0
    @test a.goal == 0
    @test scroll_of(a) === ORIGIN
    @test content_extent(a) == Size(1, 2)
end

@testitem "textarea: text round-trips the document" begin
    using ManyUI
    @test ManyUI.text(TextArea("a\nb\nc")) == "a\nb\nc"
    @test ManyUI.text(TextArea("")) == ""
    @test ManyUI.text(TextArea()) == ""
    @test ManyUI.text(TextArea("solo")) == "solo"

    a = TextArea("ab")
    move_by!(a, 1)
    insert_newline!(a)
    @test ManyUI.text(a) == "a\nb"
end

@testitem "textarea: a single line paints into the content box" begin
    using ManyUI
    a = TextArea("hi")
    buf = Buffer(4, 3)
    clear!(buf)
    render!(a, buf)
    @test string(buf) == "hi  \n    \n    "
end

@testitem "textarea: an empty area paints nothing but the caret" begin
    using ManyUI
    a = TextArea()
    buf = Buffer(3, 2)
    clear!(buf)
    render!(a, buf)
    @test string(buf) == "   \n   "
    @test !has(buf[1, 1].style, Attr.REVERSE)

    a.focused[] = true
    clear!(buf)
    render!(a, buf)
    @test string(buf) == "   \n   "
    @test has(buf[1, 1].style, Attr.REVERSE)
end

@testitem "textarea: the caret cell is reversed only when focused" begin
    using ManyUI
    a = TextArea("ab")
    move_by!(a, 1)
    buf = Buffer(4, 1)
    clear!(buf)
    render!(a, buf)
    @test !has(buf[2, 1].style, Attr.REVERSE)

    a.focused[] = true
    clear!(buf)
    render!(a, buf)
    @test has(buf[2, 1].style, Attr.REVERSE)
    @test buf[2, 1].content == "b"
    @test !has(buf[1, 1].style, Attr.REVERSE)
end

@testitem "textarea: the caret over a wide cluster reverses the HEAD" begin
    using ManyUI
    a = TextArea("世界")
    a.focused[] = true
    buf = Buffer(6, 1)
    clear!(buf)
    render!(a, buf)
    @test buf[1, 1].content == "世"
    @test buf[1, 1].width == Int8(2)
    @test has(buf[1, 1].style, Attr.REVERSE)
    # The continuation stays a continuation: the grid never
    # desynchronises.
    @test is_continuation(buf[2, 1])
    @test !has(buf[2, 1].style, Attr.REVERSE)
end

@testitem "textarea: render! is O(viewport) on a 10 000-line doc" begin
    using ManyUI
    doc = fill("line", 10_000)
    # A monster line that is NEVER visible: any per-line work at all --
    # a `text_width`, a `graphemes`, a slice -- shows up as allocation
    # the moment `render!` looks past the viewport.
    doc[9_000] = "x"^100_000
    big = TextArea(join(doc, "\n"))
    small = TextArea(join(fill("line", 20), "\n"))
    @test length(big.lines) == 10_000

    buf = Buffer(10, 10)
    render!(small, buf)             # warm up: the first call compiles
    render!(big, buf)
    a_small = @allocated render!(small, buf)
    a_big = @allocated render!(big, buf)
    # A 500x longer document costs the SAME frame: paint is O(viewport),
    # NEVER O(lines).
    @test a_big == a_small
    @test split(string(buf), '\n')[1] == "line      "

    # And the cost does not depend on WHERE the window sits: paint never
    # scans from the top of the document.
    @test set_scroll!(big, Offset(0, 9_500))
    render!(big, buf)
    @test (@allocated render!(big, buf)) == a_small
    @test split(string(buf), '\n')[1] == "line      "
end

@testitem "textarea: the vertical window follows the caret" begin
    using ManyUI
    a = TextArea(join(["L$i" for i in 1:20], "\n"))
    apply_stylesheet!(STYLESHEET_EMPTY, a)
    layout!(a, Region(1, 1, 10, 5))
    @test layout_of(a).content == Region(1, 1, 10, 5)
    @test scroll_of(a).y == 0

    move_line!(a, 4)                # line 5: the last VISIBLE row
    @test a.line == 5
    @test scroll_of(a).y == 0       # minimal movement: nothing moved

    move_line!(a, 1)                # line 6: one past the bottom
    @test scroll_of(a).y == 1

    move_line!(a, 100)              # all the way down
    @test a.line == 20
    @test scroll_of(a).y == 15

    buf = Buffer(10, 5)
    clear!(buf)
    render!(a, buf)
    rows = split(string(buf), '\n')
    @test rows[1] == "L16       "
    @test rows[5] == "L20       "

    move_line!(a, -100)             # and back to the top
    @test a.line == 1
    @test scroll_of(a).y == 0
    clear!(buf)
    render!(a, buf)
    rows = split(string(buf), '\n')
    @test rows[1] == "L1        "
    @test rows[5] == "L5        "
end

@testitem "textarea: the horizontal window follows the caret" begin
    using ManyUI
    a = TextArea("abcdefghijklmnop")
    apply_stylesheet!(STYLESHEET_EMPTY, a)
    layout!(a, Region(1, 1, 5, 1))
    @test layout_of(a).content == Region(1, 1, 5, 1)
    @test scroll_of(a).x == 0

    move_by!(a, 4)                  # caret at cell 4: still visible
    @test scroll_of(a).x == 0
    move_by!(a, 1)                  # caret at cell 5: one past the edge
    @test scroll_of(a).x == 1

    move_by!(a, 5)                  # caret at cell 10
    @test scroll_of(a).x == 6

    a.focused[] = true
    buf = Buffer(5, 1)
    clear!(buf)
    render!(a, buf)
    @test string(buf) == "ghijk"
    @test has(buf[5, 1].style, Attr.REVERSE)   # the caret cell

    move_by!(a, -1000)              # Home: the window comes back
    @test scroll_of(a).x == 0
    clear!(buf)
    render!(a, buf)
    @test string(buf) == "abcde"
end

@testitem "textarea: a wide cluster at the LEFT edge is dropped whole" begin
    using ManyUI
    a = TextArea("世界世界")
    @test set_scroll!(a, Offset(1, 0))
    buf = Buffer(6, 1)
    clear!(buf)
    render!(a, buf)
    # `世` straddles the left edge, so it is dropped WHOLE: cell 1 is
    # BLANK and emphatically NOT an orphaned continuation.
    @test buf[1, 1] === CELL_BLANK
    @test !is_continuation(buf[1, 1])
    @test buf[2, 1].content == "界"
    @test buf[2, 1].width == Int8(2)
    @test is_continuation(buf[3, 1])

    # THE discriminating case: a wide cluster straddling the left edge
    # with NOTHING after it on the line. Everywhere else a later write
    # heals a clamped one through the continuation invariant, so this is
    # the only shape that tells "dropped" from "clamped to column 1".
    lone = TextArea("世")
    set_scroll!(lone, Offset(1, 0))
    small = Buffer(4, 1)
    clear!(small)
    render!(lone, small)
    @test string(small) == "    "

    two = TextArea("世界")
    set_scroll!(two, Offset(3, 0))
    clear!(small)
    render!(two, small)
    @test string(small) == "    "

    # No orphaned continuation at ANY horizontal offset.
    for sx in 0:8
        set_scroll!(a, Offset(sx, 0))
        clear!(buf)
        render!(a, buf)
        for x in 1:6
            is_continuation(buf[x, 1]) || continue
            @test x > 1
            @test buf[x-1, 1].width == Int8(2)
        end
    end
end

@testitem "textarea: a wide cluster at the RIGHT edge is dropped whole" begin
    using ManyUI
    a = TextArea("世界世")
    buf = Buffer(5, 1)
    clear!(buf)
    render!(a, buf)
    @test buf[1, 1].content == "世"
    @test is_continuation(buf[2, 1])
    @test buf[3, 1].content == "界"
    @test is_continuation(buf[4, 1])
    # The third cluster would straddle column 5: dropped, not halved.
    @test buf[5, 1] === CELL_BLANK
end

@testitem "textarea: Home and End go to the extremes of the line" begin
    using ManyUI
    a = TextArea("abc\ndef")
    d1 = Dispatch(key(Key.END), a)
    d1.phase = Phase.AT_TARGET
    on_event!(a, d1)
    @test is_consumed(d1)
    @test (a.line, a.col) == (1, 3)
    @test a.goal == 3

    d2 = Dispatch(key(Key.HOME), a)
    d2.phase = Phase.AT_TARGET
    on_event!(a, d2)
    @test is_consumed(d2)
    @test (a.line, a.col) == (1, 0)
    @test a.goal == 0

    # END is per LINE, not per document.
    move_line!(a, 1)
    d3 = Dispatch(key(Key.END), a)
    d3.phase = Phase.AT_TARGET
    on_event!(a, d3)
    @test (a.line, a.col) == (2, 3)
end

@testitem "textarea: PageUp and PageDown move by a viewport" begin
    using ManyUI
    a = TextArea(join(["L$i" for i in 1:30], "\n"))
    apply_stylesheet!(STYLESHEET_EMPTY, a)
    layout!(a, Region(1, 1, 10, 5))

    d1 = Dispatch(key(Key.PAGE_DOWN), a)
    d1.phase = Phase.AT_TARGET
    on_event!(a, d1)
    @test is_consumed(d1)
    @test a.line == 5           # one viewport LESS one row of overlap

    d2 = Dispatch(key(Key.PAGE_DOWN), a)
    d2.phase = Phase.AT_TARGET
    on_event!(a, d2)
    @test a.line == 9

    d3 = Dispatch(key(Key.PAGE_UP), a)
    d3.phase = Phase.AT_TARGET
    on_event!(a, d3)
    @test is_consumed(d3)
    @test a.line == 5
end

@testitem "textarea: keys insert, split, delete and move" begin
    using ManyUI
    a = TextArea()
    function send!(w, e)
        d = Dispatch(e, w)
        d.phase = Phase.AT_TARGET
        on_event!(w, d)
        return d
    end

    @test is_consumed(send!(a, key('h')))
    @test is_consumed(send!(a, key('i')))
    @test a.lines == ["hi"]
    @test a.col == 2

    @test is_consumed(send!(a, key(Key.SPACE)))
    @test a.lines == ["hi "]

    @test is_consumed(send!(a, key(Key.ENTER)))
    @test a.lines == ["hi ", ""]
    @test a.line == 2

    @test is_consumed(send!(a, key('x')))
    @test a.lines == ["hi ", "x"]

    @test is_consumed(send!(a, key(Key.BACKSPACE)))
    @test a.lines == ["hi ", ""]

    @test is_consumed(send!(a, key(Key.LEFT)))
    @test (a.line, a.col) == (1, 3)
    @test is_consumed(send!(a, key(Key.RIGHT)))
    @test (a.line, a.col) == (2, 0)

    @test is_consumed(send!(a, key(Key.UP)))
    @test a.line == 1
    @test is_consumed(send!(a, key(Key.DOWN)))
    @test a.line == 2

    @test is_consumed(send!(a, key(Key.DELETE)))   # nothing to delete
    @test a.lines == ["hi ", ""]
end

@testitem "textarea: TAB ESCAPE and modified keys are NOT consumed" begin
    using ManyUI
    a = TextArea("x")
    for e in (key(Key.TAB), key(Key.ESCAPE), key(Key.BACK_TAB),
              key('a'; ctrl = true), key(Key.LEFT; shift = true),
              key(Key.ENTER; alt = true))
        d = Dispatch(e, a)
        d.phase = Phase.AT_TARGET
        on_event!(a, d)
        @test !is_consumed(d)
    end
    @test a.lines == ["x"]

    # The capture phase belongs to ancestors, never to the area.
    c = Dispatch(key('z'), a)
    c.phase = Phase.CAPTURE
    on_event!(a, c)
    @test !is_consumed(c)
    @test a.lines == ["x"]
end

@testitem "textarea: on_focus! shows the caret and reveals" begin
    using ManyUI
    a = TextArea("x")
    @test a.focused[] === false
    on_focus!(a)
    @test a.focused[] === true
    on_blur!(a)
    @test a.focused[] === false

    # `reveal!` with no scrolling ancestor is a no-op, never a throw.
    root = Container(a; id = :root)
    on_focus!(a)
    @test a.focused[] === true
    @test parent(a) === root
end

@testitem "textarea: a scroll is a PAINT mark and nothing else" begin
    using ManyUI
    a = TextArea("ab")
    root = Container(a; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 10, 5))
    clean!(root)

    move_by!(a, 2)
    @test set_scroll!(a, Offset(1, 0))
    @test dirty_root(root) === nothing
end

@testitem "textarea: a Scrollbar observes a TextArea" begin
    using ManyUI
    a = TextArea(join(["L$i" for i in 1:20], "\n"))
    apply_stylesheet!(STYLESHEET_EMPTY, a)
    layout!(a, Region(1, 1, 10, 5))
    # The scrollable seam is THREE functions, not a type: the override
    # of `content_extent` is the whole integration.
    @test content_extent(a) == Size(3, 20)
    @test layout_of(a).content.height == 5
    @test scroll_of(a) === ORIGIN

    sb = Scrollbar(a, ScrollAxis.VERTICAL)
    @test sb isa Scrollbar{<:TextArea}
    @test sb.viewport === a
    @test sb.axis === ScrollAxis.VERTICAL
end

@testitem "textarea: scrolling past the end clamps" begin
    using ManyUI
    a = TextArea(join(["L$i" for i in 1:20], "\n"))
    apply_stylesheet!(STYLESHEET_EMPTY, a)
    layout!(a, Region(1, 1, 10, 5))
    @test max_scroll(a) === Offset(0, 15)
    @test scroll_to!(a, Offset(0, 1000)) === Offset(0, 15)
    @test scroll_of(a) === Offset(0, 15)
    @test scroll_to!(a, Offset(0, -5)) === ORIGIN
    @test scroll_of(a) === ORIGIN

    # A caller BYPASSING `scroll_to!` can over-scroll -- `set_scroll!`
    # clamps at zero and has no upper bound. That is blank cells, never
    # a BoundsError, even at the arithmetic limit.
    b = TextArea("x\ny")
    buf = Buffer(3, 2)
    for o in (Offset(0, 99), Offset(99, 0), Offset(0, typemax(Int)))
        set_scroll!(b, o)
        clear!(buf)
        render!(b, buf)
        @test string(buf) == "   \n   "
    end
end

@testitem "textarea: deleting the last grapheme of the last line" begin
    using ManyUI
    a = TextArea("👨‍👩‍👧‍👦")
    move_by!(a, 1)
    @test a.col == 1
    @test backspace!(a)
    @test a.lines == [""]
    @test a.col == 0
    @test backspace!(a) === false

    b = TextArea("ab\nc")
    move_by!(b, 100)
    @test (b.line, b.col) == (2, 1)
    @test backspace!(b)
    @test b.lines == ["ab", ""]
    @test (b.line, b.col) == (2, 0)
    @test backspace!(b)             # the join
    @test b.lines == ["ab"]
    @test (b.line, b.col) == (1, 2)
end

@testitem "textarea: every grapheme test vector round-trips" begin
    using ManyUI
    # (text, cells, clusters) -- the contract's normative table.
    vectors = [("abc", 3, 3),
               ("世界", 4, 2),
               ("❤️", 2, 1),
               ("☝️", 2, 1),
               ("👨‍👩‍👧‍👦", 2, 1),
               ("👩‍❤️‍💋‍👨", 2, 1),
               ("👍🏽", 2, 1),
               ("🇫🇷", 2, 1),
               ("é", 1, 1),          # NFC, precomposed
               ("é", 1, 1),         # NFD: e + combining accent
               ("", 0, 0)]
    for (s, cells, clusters) in vectors
        a = TextArea(s)
        @test a.lines == [s]
        @test text_width(a.lines[1]) == cells
        @test content_extent(a) == Size(cells, 1)
        move_by!(a, 1000)
        @test a.col == clusters      # ONE step per CLUSTER
        @test a.goal == cells        # the goal is in CELLS
        move_by!(a, -1000)
        @test a.col == 0
        @test a.goal == 0
        @test ManyUI.text(a) == s
    end
end

@testitem "textarea: the ZWJ family is ONE cursor step and TWO cells" begin
    using ManyUI
    a = TextArea("👨‍👩‍👧‍👦")
    move_by!(a, 1)
    @test a.col == 1
    @test a.goal == 2
    move_by!(a, 1)
    @test a.col == 1                # already at the end of the document
end

@testitem "textarea: backspace deletes a cluster, not a codepoint" begin
    using ManyUI
    a = TextArea("a👍🏽b")
    move_by!(a, 2)                  # the caret sits after the emoji
    @test backspace!(a)
    @test a.lines == ["ab"]
    @test a.col == 1
end

@testitem "textarea: a combining mark merges and the caret is recomputed" begin
    using ManyUI
    a = TextArea("e")
    move_by!(a, 1)
    @test a.col == 1
    insert_text!(a, "́")
    @test a.lines == ["é"]
    # ONE cluster: the caret is RECOMPUTED from the new prefix, never
    # advanced by the inserted cluster count.
    @test a.col == 1
    @test text_width(a.lines[1]) == 1
    @test backspace!(a)             # one cluster, both codepoints
    @test a.lines == [""]
end

@testitem "textarea: delete_forward! deletes one cluster" begin
    using ManyUI
    a = TextArea("a👍🏽b")
    move_by!(a, 1)
    @test delete_forward!(a)
    @test a.lines == ["ab"]
    @test a.col == 1
    @test delete_forward!(a)
    @test a.lines == ["a"]
    @test delete_forward!(a) === false
end
