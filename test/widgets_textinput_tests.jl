# widgets_textinput_tests.jl -- single-line text entry (layer 7).
#
# The grapheme discipline is the requirement, not a nicety: a cursor
# steps by CLUSTER, a wide cluster is ONE step and TWO cells, and a
# cluster that would straddle a window edge is dropped WHOLE. Every
# vector of the contract's § 4.4 table is exercised here.
#
# Every testitem is self-contained, needs no tty and never sleeps.

@testitem "textinput: measure is Size(avail.width, 1) whatever the text" begin
    using ManyUI
    @test measure(TextInput(""), Size(20, 5)) == Size(20, 1)
    @test measure(TextInput("short"), Size(20, 5)) == Size(20, 1)
    long = TextInput(repeat("long text ", 40))
    @test measure(long, Size(20, 5)) == Size(20, 1)
    # A TextInput NEVER sizes to its content: that is what licenses
    # PAINT-reactive text, and what the horizontal scroll is for.
    @test measure(TextInput("👨‍👩‍👧‍👦"), Size(3, 9)) == Size(3, 1)
    @test measure(TextInput("世界世界"), Size(1, 1)) == Size(1, 1)
    @test measure(TextInput("abc"), Size(0, 1)) == Size(0, 1)
end

@testitem "textinput: the ZWJ family is ONE cursor step and TWO cells" begin
    using ManyUI
    fam = "👨‍👩‍👧‍👦"
    # 7 codepoints, 25 bytes, 1 cluster, 2 cells. Stepping by codepoint
    # would take 7 moves; stepping by byte would take 25.
    @test ncodeunits(fam) == 25
    @test length(collect(fam)) == 7
    @test text_width(fam) == 2

    ti = TextInput(fam)
    @test move_to!(ti, typemax(Int)) == 1      # ONE step to the end
    @test move_by!(ti, -1) == 0                # ONE step back over it
    @test move_by!(ti, -1) == 0                # and no further
    @test move_by!(ti, 1) == 1
    @test move_by!(ti, 1) == 1

    # TWO cells on the grid, as one head plus one continuation.
    buf = Buffer(4, 1)
    clear!(buf)
    render!(ti, buf)
    @test buf[1, 1].content == fam
    @test buf[1, 1].width == 2
    @test is_continuation(buf[2, 1])
    @test buf[3, 1] == CELL_BLANK
end

@testitem "textinput: backspace deletes one cluster, not one codepoint" begin
    using ManyUI
    ti = TextInput("a👍🏽b")
    @test move_to!(ti, typemax(Int)) == 3      # "a", "👍🏽", "b"
    @test move_to!(ti, 2) == 2                 # caret after the emoji
    @test backspace!(ti)
    @test ti.text[] == "ab"                    # the WHOLE cluster went
    @test ti.cursor[] == 1

    # The skin-tone modifier is not a separate cluster and never was.
    ti2 = TextInput("👍🏽")
    @test move_to!(ti2, typemax(Int)) == 1
    @test backspace!(ti2)
    @test ti2.text[] == ""

    # A regional-indicator flag is one cluster of two codepoints.
    ti3 = TextInput("a🇫🇷")
    @test move_to!(ti3, typemax(Int)) == 2
    @test backspace!(ti3)
    @test ti3.text[] == "a"
end

@testitem "textinput: a combining mark merges and the caret is recomputed" begin
    using ManyUI
    ti = TextInput("e")
    @test move_to!(ti, typemax(Int)) == 1
    insert_text!(ti, "́")          # COMBINING ACUTE ACCENT
    # ONE cluster, and the caret did NOT advance by the inserted
    # cluster count -- it was recomputed from the new prefix.
    @test ti.text[] == "é"
    @test text_width(ti.text[]) == 1
    @test ti.cursor[] == 1
    @test move_to!(ti, typemax(Int)) == 1
    # One backspace takes the whole merged cluster, base and all.
    @test backspace!(ti)
    @test ti.text[] == ""

    # NFC and NFD spellings agree on width and cluster count.
    for s in ("é", "é")
        t = TextInput(s)
        @test text_width(t.text[]) == 1
        @test move_to!(t, typemax(Int)) == 1
    end
end

@testitem "textinput: the caret at 0 refuses to move left" begin
    using ManyUI
    ti = TextInput("abc")
    @test move_to!(ti, 0) == 0
    @test move_by!(ti, -1) == 0
    @test move_by!(ti, -100) == 0
    @test move_by!(ti, typemin(Int)) == 0      # no underflow
    @test move_to!(ti, -5) == 0
    @test ti.cursor[] == 0
    @test ti.text[] == "abc"
    @test !backspace!(ti)                      # nothing before it
end

@testitem "textinput: the caret at n refuses to move right" begin
    using ManyUI
    ti = TextInput("abc")
    @test move_to!(ti, typemax(Int)) == 3
    @test move_by!(ti, 1) == 3
    @test move_by!(ti, 100) == 3
    @test move_by!(ti, typemax(Int)) == 3      # no overflow
    @test move_to!(ti, 99) == 3
    @test ti.cursor[] == 3
    @test ti.text[] == "abc"
    @test !delete_forward!(ti)                 # nothing at it
end

@testitem "textinput: Home and End go to both extremes" begin
    using ManyUI
    ti = TextInput("世界")                     # 2 clusters, 4 cells
    @test move_to!(ti, typemax(Int)) == 2      # End
    @test move_to!(ti, 0) == 0                 # Home
    @test move_to!(ti, typemax(Int)) == 2

    # And through the key handler, which is the way a user gets there.
    for (k, want) in (("home", 0), ("end", 2))
        d = Dispatch(parse(KeyEvent, k), ti)
        d.phase = Phase.AT_TARGET
        on_event!(ti, d)
        @test ti.cursor[] == want
        @test is_consumed(d)
    end
end

@testitem "textinput: deleting the last grapheme empties the text" begin
    using ManyUI
    ti = TextInput("👨‍👩‍👧‍👦")
    @test move_to!(ti, typemax(Int)) == 1
    @test backspace!(ti)
    @test ti.text[] == ""
    @test ti.cursor[] == 0
    @test !backspace!(ti)                      # and no further
    @test content_extent(ti) == Size(1, 1)

    # Forward, from the other end.
    ti2 = TextInput("世")
    @test move_to!(ti2, 0) == 0
    @test delete_forward!(ti2)
    @test ti2.text[] == ""
    @test ti2.cursor[] == 0
    @test !delete_forward!(ti2)
end

@testitem "textinput: backspace on empty text returns false" begin
    using ManyUI
    ti = TextInput()
    @test ti.text[] == ""
    @test ti.cursor[] == 0
    @test !backspace!(ti)
    @test !delete_forward!(ti)
    @test ti.text[] == ""
    @test ti.cursor[] == 0
    # Still false after a real edit takes it back to empty.
    insert_text!(ti, "x")
    @test backspace!(ti)
    @test !backspace!(ti)
end

@testitem "textinput: delete removes the cluster AT the caret" begin
    using ManyUI
    ti = TextInput("a世b")
    @test move_to!(ti, 1) == 1
    @test delete_forward!(ti)                  # takes "世" whole
    @test ti.text[] == "ab"
    @test ti.cursor[] == 1                     # the caret does NOT move
    @test delete_forward!(ti)
    @test ti.text[] == "a"
    @test ti.cursor[] == 1
    @test !delete_forward!(ti)                 # at the end: refused
    @test ti.text[] == "a"
end

@testitem "textinput: the window slides only as far as it must" begin
    using ManyUI
    ti = TextInput("abcdefghij")               # 10 clusters, 10 cells
    root = Container(ti)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 5, 1))
    @test content_region(ti).width == 5

    # Home: nothing is scrolled.
    @test move_to!(ti, 0) == 0
    @test scroll_of(ti) === Offset(0, 0)
    @test visible_scroll(ti, 5) == 0

    # Walking right inside the window moves nothing at all.
    for i in 1:4
        move_to!(ti, i)
        @test scroll_of(ti) === Offset(0, 0)
    end

    # The first caret position past the right edge slides by EXACTLY
    # one cell, not by a window and not to the end.
    @test move_to!(ti, 5) == 5
    @test scroll_of(ti) === Offset(1, 0)
    @test move_to!(ti, 6) == 6
    @test scroll_of(ti) === Offset(2, 0)

    # Coming back left inside the window moves nothing.
    @test move_to!(ti, 3) == 3
    @test scroll_of(ti) === Offset(2, 0)
    # Past the left edge: minimal again.
    @test move_to!(ti, 1) == 1
    @test scroll_of(ti) === Offset(1, 0)
end

@testitem "textinput: the window follows the caret right and left" begin
    using ManyUI
    ti = TextInput("abcdefghij")
    root = Container(ti)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 5, 1))

    buf = Buffer(5, 1)
    render_row(t) = (clear!(buf); render!(t, buf); string(buf))

    @test move_to!(ti, 0) == 0
    @test render_row(ti) == "abcde"

    # End. The content extent is text_width + 1, so the caret's own
    # cell is reachable: the window shows the LAST four glyphs and one
    # cell for the caret past them.
    @test move_to!(ti, typemax(Int)) == 10
    @test scroll_of(ti) === Offset(6, 0)
    @test render_row(ti) == "ghij "
    @test visible_scroll(ti, 5) == 6

    # Home again: all the way back, in one move.
    @test move_to!(ti, 0) == 0
    @test scroll_of(ti) === Offset(0, 0)
    @test render_row(ti) == "abcde"

    # Typing at the end drags the window along with the caret.
    move_to!(ti, typemax(Int))
    insert_text!(ti, "k")
    @test ti.text[] == "abcdefghijk"
    @test scroll_of(ti) === Offset(7, 0)
    @test render_row(ti) == "hijk "
end

@testitem "textinput: a wide cluster at a window edge is dropped whole" begin
    using ManyUI
    # "世界世界": 4 clusters, 8 cells, every one of them width 2.
    ti = TextInput("世界世界")
    buf = Buffer(5, 1)

    # RIGHT edge, unscrolled: cells 1-2, 3-4, then a cluster that would
    # need cells 5-6. It is refused WHOLE; cell 5 stays blank.
    ti.cursor[] = 0
    clear!(buf)
    render!(ti, buf)
    @test buf[1, 1].content == "世"
    @test buf[1, 1].width == 2
    @test is_continuation(buf[2, 1])
    @test buf[3, 1].content == "界"
    @test is_continuation(buf[4, 1])
    @test buf[5, 1] == CELL_BLANK              # dropped, NOT halved
    @test !is_continuation(buf[5, 1])
    @test string(buf) == "世界 "

    # LEFT edge: scroll by one cell so cluster 1 straddles it. The head
    # is off-window, so the WHOLE cluster goes and cell 1 stays blank --
    # an orphaned continuation there would desynchronise every column
    # to its right.
    @test set_scroll!(ti, Offset(1, 0))
    ti.cursor[] = 1                            # keeps the window put
    @test visible_scroll(ti, 5) == 1
    clear!(buf)
    render!(ti, buf)
    @test buf[1, 1] == CELL_BLANK
    @test !is_continuation(buf[1, 1])
    @test buf[2, 1].content == "界"
    @test is_continuation(buf[3, 1])
    @test buf[4, 1].content == "世"
    @test is_continuation(buf[5, 1])
    @test string(buf) == " 界世"

    # Sweep every offset: no cell is ever an orphaned continuation.
    for off in 0:8
        set_scroll!(ti, Offset(off, 0))
        ti.cursor[] = ManyUI._col_at_cell(ti.text[], off)
        clear!(buf)
        render!(ti, buf)
        for x in 1:5
            is_continuation(buf[x, 1]) || continue
            @test x > 1
            @test buf[x-1, 1].width == 2
        end
    end
end

@testitem "textinput: typing a wide grapheme at a boundary" begin
    using ManyUI
    ti = TextInput("ab")
    root = Container(ti)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 4, 1))

    @test move_to!(ti, 1) == 1                 # between "a" and "b"
    insert_text!(ti, "世")
    @test ti.text[] == "a世b"
    # ONE cluster inserted -> the caret advanced by ONE step, over TWO
    # cells.
    @test ti.cursor[] == 2
    @test text_width(ti.text[]) == 4

    buf = Buffer(4, 1)
    clear!(buf)
    render!(ti, buf)
    @test string(buf) == "a世b"
    @test buf[2, 1].content == "世"
    @test buf[2, 1].width == 2
    @test is_continuation(buf[3, 1])
    @test buf[4, 1].content == "b"

    # Now push it past the right edge: the caret stays reachable and the
    # wide cluster is never halved.
    @test move_to!(ti, typemax(Int)) == 3
    insert_text!(ti, "世")
    @test ti.text[] == "a世b世"
    @test scroll_of(ti) === Offset(3, 0)
    clear!(buf)
    render!(ti, buf)
    for x in 1:4
        is_continuation(buf[x, 1]) || continue
        @test x > 1
        @test buf[x-1, 1].width == 2
    end
end

@testitem "textinput: the caret cell is reversed only when focused" begin
    using ManyUI
    ti = TextInput("ab")
    ti.cursor[] = 0
    buf = Buffer(5, 1)

    clear!(buf)
    render!(ti, buf)
    @test !has(buf[1, 1].style, Attr.REVERSE)
    @test buf[1, 1].content == "a"

    ti.focused[] = true
    clear!(buf)
    render!(ti, buf)
    @test has(buf[1, 1].style, Attr.REVERSE)
    @test buf[1, 1].content == "a"             # content is untouched
    @test !has(buf[2, 1].style, Attr.REVERSE)

    # It tracks the caret, and rests ONE cell past the last glyph.
    ti.cursor[] = 2
    clear!(buf)
    render!(ti, buf)
    @test !has(buf[1, 1].style, Attr.REVERSE)
    @test has(buf[3, 1].style, Attr.REVERSE)

    # on_blur! puts it away again.
    on_blur!(ti)
    @test !ti.focused[]
    clear!(buf)
    render!(ti, buf)
    @test !has(buf[3, 1].style, Attr.REVERSE)
end

@testitem "textinput: the caret over a wide cluster reverses the HEAD" begin
    using ManyUI
    ti = TextInput("世界")
    ti.focused[] = true
    ti.cursor[] = 0
    buf = Buffer(6, 1)
    clear!(buf)
    render!(ti, buf)

    # The head carries the reverse; its continuation stays a bare
    # continuation, so the grid never desynchronises.
    @test buf[1, 1].content == "世"
    @test buf[1, 1].width == 2
    @test has(buf[1, 1].style, Attr.REVERSE)
    @test is_continuation(buf[2, 1])
    @test !has(buf[2, 1].style, Attr.REVERSE)
    @test buf[2, 1] == CELL_CONT

    # One step right is ONE cluster and TWO cells.
    ti.cursor[] = 1
    clear!(buf)
    render!(ti, buf)
    @test !has(buf[1, 1].style, Attr.REVERSE)
    @test has(buf[3, 1].style, Attr.REVERSE)
    @test buf[3, 1].content == "界"
    @test is_continuation(buf[4, 1])
end

@testitem "textinput: the placeholder shows dimmed only while empty" begin
    using ManyUI
    ti = TextInput(""; placeholder = "name")
    buf = Buffer(8, 1)
    clear!(buf)
    render!(ti, buf)
    @test string(buf) == "name    "
    @test has(buf[1, 1].style, Attr.DIM)
    @test has(buf[4, 1].style, Attr.DIM)

    # One character and it is gone -- and the real text is NOT dimmed.
    insert_text!(ti, "x")
    clear!(buf)
    render!(ti, buf)
    @test string(buf) == "x       "
    @test !has(buf[1, 1].style, Attr.DIM)

    # Emptying the field brings it back.
    @test backspace!(ti)
    clear!(buf)
    render!(ti, buf)
    @test string(buf) == "name    "
    @test has(buf[1, 1].style, Attr.DIM)

    # No placeholder: an empty field paints nothing at all.
    plain = TextInput()
    clear!(buf)
    render!(plain, buf)
    @test string(buf) == "        "
end

@testitem "textinput: ENTER calls on_submit" begin
    using ManyUI
    fired = Ref(0)
    seen = Ref{Any}(nothing)
    ti = TextInput("hi", w -> (fired[] += 1; seen[] = w.text[]; nothing))

    d = Dispatch(parse(KeyEvent, "enter"), ti)
    d.phase = Phase.AT_TARGET
    on_event!(ti, d)
    @test fired[] == 1
    @test seen[] == "hi"
    @test is_consumed(d)
    @test ti.text[] == "hi"                    # ENTER inserts nothing

    # Never during the capture phase: capture belongs to ancestors.
    d = Dispatch(parse(KeyEvent, "enter"), ti)
    @test d.phase === Phase.CAPTURE
    on_event!(ti, d)
    @test fired[] == 1
    @test !is_consumed(d)

    # A modified ENTER belongs to an app-level binding.
    d = Dispatch(parse(KeyEvent, "ctrl+enter"), ti)
    d.phase = Phase.AT_TARGET
    on_event!(ti, d)
    @test fired[] == 1
    @test !is_consumed(d)

    # The default handler submits nothing and throws nothing.
    plain = TextInput("x")
    d = Dispatch(parse(KeyEvent, "enter"), plain)
    d.phase = Phase.AT_TARGET
    @test on_event!(plain, d) === nothing
end

@testitem "textinput: TAB and ESCAPE are NOT consumed" begin
    using ManyUI
    ti = TextInput("hi")
    move_to!(ti, typemax(Int))
    for k in ("tab", "shift+tab", "escape", "f1")
        d = Dispatch(parse(KeyEvent, k), ti)
        d.phase = Phase.AT_TARGET
        on_event!(ti, d)
        @test !is_consumed(d)
        @test ti.text[] == "hi"                # and inserts nothing
    end
    @test ti.cursor[] == 2
end

@testitem "textinput: ctrl+a is NOT consumed" begin
    using ManyUI
    ti = TextInput("hi")
    for k in ("ctrl+a", "alt+b", "ctrl+left", "ctrl+shift+left")
        d = Dispatch(parse(KeyEvent, k), ti)
        d.phase = Phase.AT_TARGET
        on_event!(ti, d)
        @test !is_consumed(d)
        @test ti.text[] == "hi"
    end
    # An unmodified letter, by contrast, is typed and consumed.
    move_to!(ti, typemax(Int))
    d = Dispatch(key('a'), ti)
    d.phase = Phase.AT_TARGET
    on_event!(ti, d)
    @test is_consumed(d)
    @test ti.text[] == "hia"
end

@testitem "textinput: typed keys insert at the caret" begin
    using ManyUI
    ti = TextInput()
    for e in (key('h'), key('i'), parse(KeyEvent, "space"), key('世'))
        d = Dispatch(e, ti)
        d.phase = Phase.AT_TARGET
        on_event!(ti, d)
        @test is_consumed(d)
    end
    @test ti.text[] == "hi 世"
    @test ti.cursor[] == 4

    # Editing keys, each consuming. LEFT steps over the wide cluster in
    # ONE move, so backspace then takes the space before it.
    for (k, want) in (("left", "hi 世"), ("backspace", "hi世"),
                      ("home", "hi世"), ("delete", "i世"))
        d = Dispatch(parse(KeyEvent, k), ti)
        d.phase = Phase.AT_TARGET
        on_event!(ti, d)
        @test is_consumed(d)
        @test ti.text[] == want
    end
    @test ti.cursor[] == 0
end

@testitem "textinput: paste strips newlines" begin
    using ManyUI
    ti = TextInput()
    d = Dispatch(PasteEvent("a\nb\r\nc\td"), ti)
    d.phase = Phase.AT_TARGET
    on_event!(ti, d)
    @test ti.text[] == "abcd"          # nowhere to put a line break
    @test ti.cursor[] == 4
    @test is_consumed(d)

    # A paste lands AT the caret, not at the end.
    move_to!(ti, 2)
    d = Dispatch(PasteEvent("XY"), ti)
    d.phase = Phase.AT_TARGET
    on_event!(ti, d)
    @test ti.text[] == "abXYcd"
    @test ti.cursor[] == 4

    # Graphemes survive a paste whole.
    ti2 = TextInput()
    d = Dispatch(PasteEvent("👨‍👩‍👧‍👦\n世"), ti2)
    d.phase = Phase.AT_TARGET
    on_event!(ti2, d)
    @test ti2.text[] == "👨‍👩‍👧‍👦世"
    @test ti2.cursor[] == 2
    @test text_width(ti2.text[]) == 4

    # An all-control paste inserts nothing and still throws nothing.
    ti3 = TextInput("k")
    d = Dispatch(PasteEvent("\n\r\n"), ti3)
    d.phase = Phase.AT_TARGET
    on_event!(ti3, d)
    @test ti3.text[] == "k"

    # Not during capture.
    ti4 = TextInput()
    d = Dispatch(PasteEvent("z"), ti4)
    @test d.phase === Phase.CAPTURE
    on_event!(ti4, d)
    @test ti4.text[] == ""
    @test !is_consumed(d)
end

@testitem "textinput: typing does not mark Dirty.LAYOUT" begin
    using ManyUI
    ti = TextInput("ab")
    root = Container(ti)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 5, 1))

    # `measure` is text-independent, so a keystroke provably cannot move
    # a single box. That is what licenses PAINT-reactive state here.
    clean!(ti)
    insert_text!(ti, "c")
    @test is_dirty(ti, Dirty.PAINT)
    @test !is_dirty(ti, Dirty.LAYOUT)

    clean!(ti)
    @test backspace!(ti)
    @test is_dirty(ti, Dirty.PAINT)
    @test !is_dirty(ti, Dirty.LAYOUT)

    clean!(ti)
    move_to!(ti, 0)
    @test is_dirty(ti, Dirty.PAINT)
    @test !is_dirty(ti, Dirty.LAYOUT)

    # A scroll is a repaint too, never a relayout.
    clean!(ti)
    move_to!(ti, typemax(Int))
    insert_text!(ti, "defghij")
    @test scroll_of(ti).x > 0
    @test is_dirty(ti, Dirty.PAINT)
    @test !is_dirty(ti, Dirty.LAYOUT)

    # And a redundant write costs nothing at all.
    clean!(ti)
    ti.text[] = ti.text[]
    @test !is_dirty(ti)
end

@testitem "textinput: on_focus! reveals through an ancestor pane" begin
    using ManyUI

    # A stand-in for any scrolling ancestor: the core knows only that a
    # node MAY reveal a descendant, never how. `Scrollpane` overrides
    # exactly this hook.
    mutable struct RevealSpy <: Widget
        node::WidgetNode
        seen::Vector{Widget}
    end
    RevealSpy() = RevealSpy(WidgetNode(; type_name = :RevealSpy),
                            Widget[])
    ManyUI.reveal_child!(w::RevealSpy, d::Widget)::Nothing =
        (push!(w.seen, d); nothing)

    ti = TextInput("hi")
    inner = RevealSpy()
    outer = RevealSpy()
    mount!(inner, ti)
    mount!(outer, inner)

    @test !ti.focused[]
    @test on_focus!(ti) === nothing
    @test ti.focused[]
    # Overriding `on_focus!` REPLACES the default, so `TextInput` calls
    # `reveal!` itself -- and every ancestor hears about it.
    @test inner.seen == Widget[ti]
    @test outer.seen == Widget[ti]

    on_blur!(ti)
    @test !ti.focused[]
    @test length(inner.seen) == 1              # blur reveals nothing

    # A parentless input focuses without a throw.
    lone = TextInput()
    @test on_focus!(lone) === nothing
    @test lone.focused[]
end

@testitem "textinput: is focusable with concrete fields" begin
    using ManyUI
    f = w -> nothing
    ti = TextInput("x", f)
    @test ti isa TextInput{typeof(f)}
    @test ti isa Widget
    @test is_focusable(ti)
    @test type_name(ti) === :TextInput
    @test id(TextInput()) !== id(TextInput())
    @test isconcretetype(typeof(ti))
    @test isconcretetype(fieldtype(typeof(ti), :on_submit))
    @test isconcretetype(fieldtype(typeof(ti), :text))
    @test isconcretetype(fieldtype(typeof(ti), :cursor))
    @test isconcretetype(fieldtype(typeof(ti), :focused))
    @test fieldtype(typeof(ti), :placeholder) === String

    # Reachable by TAB with no further wiring.
    root = Container(Label("x"), TextInput(), TextInput())
    layout!(root, Region(1, 1, 20, 10))
    tab = focusable_widgets(root)
    @test length(tab) == 2
    @test all(w -> w isa TextInput, tab)
end

@testitem "textinput: content_extent leaves a cell for the caret" begin
    using ManyUI
    # The `+ 1` is load-bearing: the caret must be able to rest ONE cell
    # past the last glyph, and without it End scrolls one cell short.
    @test content_extent(TextInput("")) == Size(1, 1)
    @test content_extent(TextInput("abc")) == Size(4, 1)
    @test content_extent(TextInput("世界")) == Size(5, 1)
    @test content_extent(TextInput("👨‍👩‍👧‍👦")) == Size(3, 1)

    # It tracks the text, and the seam is the same three functions any
    # scrolling widget answers.
    ti = TextInput("ab")
    insert_text!(ti, "cd")
    @test content_extent(ti) == Size(5, 1)
    @test scroll_of(ti) isa Offset
    @test layout_of(ti) isa ManyUI.LayoutBox
end

@testitem "textinput: the grapheme helpers meet bytes and clusters" begin
    using ManyUI
    # THE one place byte and cluster indices are allowed to meet, and
    # `textarea.jl` codes against these exact signatures.
    fam = "👨‍👩‍👧‍👦"

    # _byte_after: 0 below the range, ncodeunits past the end, always a
    # boundary that SubString can split at.
    @test ManyUI._byte_after("abc", 0) == 0
    @test ManyUI._byte_after("abc", -3) == 0
    @test ManyUI._byte_after("abc", 2) == 2
    @test ManyUI._byte_after("abc", 99) == 3
    @test ManyUI._byte_after(fam, 1) == 25
    @test ManyUI._byte_after("世界", 1) == 3

    # A code-unit COUNT, never a character INDEX. `SubString(s, 1, b)`
    # would throw a StringIndexError the moment the prefix ends inside a
    # multi-byte cluster, so the split goes through `thisind` -- the
    # precaution `truncate_width` already takes.
    s = "a世👍🏽"
    for k in -1:5
        b = ManyUI._byte_after(s, k)
        head = SubString(s, 1, thisind(s, b))
        tail = SubString(s, b + 1)
        @test ncodeunits(head) == b            # a whole-cluster split
        @test string(head, tail) == s          # and a lossless one
    end
    @test_throws StringIndexError SubString(s, 1, ManyUI._byte_after(s, 2))

    # _ngraphemes: clusters, never codepoints and never bytes.
    @test ManyUI._ngraphemes("") == 0
    @test ManyUI._ngraphemes("abc") == 3
    @test ManyUI._ngraphemes("世界") == 2
    @test ManyUI._ngraphemes(fam) == 1
    @test ManyUI._ngraphemes("é") == 1
    @test ManyUI._ngraphemes("🇫🇷") == 1

    # _gindex_at: clusters ENDING at or before a byte; rounds DOWN.
    @test ManyUI._gindex_at("abc", 0) == 0
    @test ManyUI._gindex_at("abc", 2) == 2
    @test ManyUI._gindex_at("abc", 99) == 3
    @test ManyUI._gindex_at(fam, 24) == 0      # inside the cluster
    @test ManyUI._gindex_at(fam, 25) == 1
    @test ManyUI._gindex_at("世界", 3) == 1
    @test ManyUI._gindex_at("世界", 5) == 1    # rounds DOWN

    # _cluster_width_at: cells of the cluster after a byte; 1 at the end
    # so the caret always has a cell to sit in.
    @test ManyUI._cluster_width_at("a世", 0) == 1
    @test ManyUI._cluster_width_at("a世", 1) == 2
    @test ManyUI._cluster_width_at("a世", 4) == 1
    @test ManyUI._cluster_width_at("", 0) == 1
    @test ManyUI._cluster_width_at(fam, 0) == 2

    # _col_at_cell: the inverse of "cells before the caret". It can
    # never land INSIDE a wide cluster.
    @test ManyUI._col_at_cell("世界", 0) == 0
    @test ManyUI._col_at_cell("世界", 1) == 0  # inside cluster 1
    @test ManyUI._col_at_cell("世界", 2) == 1
    @test ManyUI._col_at_cell("世界", 3) == 1  # inside cluster 2
    @test ManyUI._col_at_cell("世界", 4) == 2
    @test ManyUI._col_at_cell("世界", 99) == 2
    @test ManyUI._col_at_cell("abc", 2) == 2
    @test ManyUI._col_at_cell("abc", -1) == 0
end

@testitem "textinput: every grapheme test vector round-trips" begin
    using ManyUI
    # The contract's § 4.4 table, entire. Each row is (text, cells,
    # clusters).
    vectors = (("abc", 3, 3),
               ("世界", 4, 2),
               ("❤️", 2, 1),
               ("☝️", 2, 1),
               ("👨‍👩‍👧‍👦", 2, 1),
               ("👩‍❤️‍💋‍👨", 2, 1),
               ("👍🏽", 2, 1),
               ("🇫🇷", 2, 1),
               ("é", 1, 1),
               ("é", 1, 1),
               ("", 0, 0))

    for (s, cells, n) in vectors
        @test text_width(s) == cells           # the frozen oracle

        # Typed in, it survives byte-for-byte.
        ti = TextInput()
        insert_text!(ti, s)
        @test ti.text[] == s
        @test ti.cursor[] == n
        @test content_extent(ti) == Size(cells + 1, 1)

        # End is n steps from Home, and every cluster is ONE step.
        @test move_to!(ti, 0) == 0
        @test move_to!(ti, typemax(Int)) == n
        for k in 1:n
            @test move_by!(ti, -1) == n - k
        end
        @test move_by!(ti, -1) == 0

        # It paints in exactly `cells` cells, and never half a cluster.
        buf = Buffer(cells + 2, 1)
        clear!(buf)
        render!(ti, buf)
        @test string(buf) == string(s, " "^2)
        for x in 1:(cells+2)
            is_continuation(buf[x, 1]) || continue
            @test x > 1
            @test buf[x-1, 1].width == 2
        end

        # And backspaces away one cluster at a time, to exactly empty.
        @test move_to!(ti, typemax(Int)) == n
        for k in 1:n
            @test backspace!(ti)
        end
        @test ti.text[] == ""
        @test ti.cursor[] == 0
        @test !backspace!(ti)
    end
end
