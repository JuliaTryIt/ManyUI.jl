# widgets_scroll_tests.jl -- Scrollpane and Scrollbar (layer 7).
#
# Every assertion below is about CELLS or about integers, never about
# vibes: a scroll bug is invisible in a type signature and obvious in a
# painted buffer.
#
# Every testitem is self-contained, needs no tty, never sleeps, and
# follows the mandatory recipe: `apply_stylesheet!` BEFORE `layout!`.
# `layout!` does not apply `inline_box` -- only the cascade does -- and
# `apply_stylesheet!` OVERWRITES `node(w).box`, so a widget that sets its
# own geometry must set both and a test that skips the cascade is
# testing `BOX_DEFAULT`.

@testitem "scroll: the canvas overflows its viewport" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:8]...)
    pane = Scrollpane(inner)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))

    vp = viewport(pane)
    win = layout_of(vp).content
    ext = content_extent(vp)
    # The window is the canvas's content box: 3 rows tall, one column
    # surrendered to the AUTO gutter.
    @test win == Region(1, 1, 8, 3)
    # The content genuinely overhangs it -- this is the whole recipe,
    # as an assertion. Without it there is nothing to scroll.
    @test ext.height == 8
    @test ext.height > win.height
    @test max_scroll(vp) === Offset(0, 5)
end

@testitem "scroll: an empty Scrollpane has zero extent and cannot scroll" begin
    using DualUI
    pane = Scrollpane()
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))

    vp = viewport(pane)
    @test content_extent(vp) === Size(0, 0)
    @test max_scroll(vp) === Offset(0, 0)
    @test scroll_to!(vp, Offset(4, 4)) === Offset(0, 0)
    @test scroll_of(vp) === Offset(0, 0)

    buf = Buffer(9, 3)
    clear!(buf)
    paint!(buf, pane)
    # An empty pane with an AUTO bar and nothing to scroll: the gutter
    # is reserved and blank, so the whole surface is blank.
    @test string(buf) == "         \n         \n         "
end

@testitem "scroll: content_extent unions the children's margin boxes" begin
    using DualUI
    a = Static("ab")
    b = Static("cdef")
    holder = Container(a, b)
    pane = Scrollpane(holder; bar_y = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 10, 4))

    vp = viewport(pane)
    c = layout_of(vp).content
    ma = layout_of(a).margin_box
    mb = layout_of(b).margin_box
    u = union(ma, mb)
    ext = content_extent(vp)
    # Measured from the CONTENT-BOX ORIGIN, not from the screen origin.
    @test ext === Size(right(u) - c.x + 1, bottom(u) - c.y + 1)
    @test ext === Size(4, 2)
end

@testitem "scroll: content_extent is independent of the current offset" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:8]...)
    pane = Scrollpane(inner)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    base = content_extent(vp)
    for off in (0, 1, 3, 5)
        scroll_to!(vp, Offset(0, off))
        # Reads the UNSHIFTED LayoutMap, so a scroll can never feed back
        # into the extent -- the property that stops the oscillation.
        @test content_extent(vp) === base
        @test max_scroll(vp) === Offset(0, 5)
    end
end

@testitem "scroll: max_scroll is zero when the content fits" begin
    using DualUI
    inner = Container(Static("L1"), Static("L2"))
    pane = Scrollpane(inner)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 6))
    vp = viewport(pane)

    @test content_extent(vp).height == 2
    @test layout_of(vp).content.height == 6
    @test max_scroll(vp) === Offset(0, 0)
    @test scroll_to!(vp, Offset(0, 3)) === Offset(0, 0)
end

@testitem "scroll: wheel up/down/left/right scroll by wheel_step" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:20]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER,
                      wheel_step = 3, wheel_step_x = 6)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 4))
    vp = viewport(pane)

    wheel(b) = MouseEvent(MouseAction.PRESS, b, 1, 1, MOD_NONE)

    @test dispatch_event!(pane, wheel(MouseButton.WHEEL_DOWN))
    @test scroll_of(vp) === Offset(0, 3)
    @test dispatch_event!(pane, wheel(MouseButton.WHEEL_DOWN))
    @test scroll_of(vp) === Offset(0, 6)
    @test dispatch_event!(pane, wheel(MouseButton.WHEEL_UP))
    @test scroll_of(vp) === Offset(0, 3)

    # Horizontal: this content is only 3 cells wide, so a WHEEL_RIGHT
    # cannot move and must not consume.
    @test !dispatch_event!(pane, wheel(MouseButton.WHEEL_RIGHT))
    @test scroll_of(vp) === Offset(0, 3)
end

@testitem "scroll: the wheel scrolls horizontally on wide content" begin
    using DualUI
    pane = Scrollpane(Static("ABCDEFGHIJKLMNOP");
                      bar_y = ScrollMode.NEVER, wheel_step_x = 6)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 6, 2))
    vp = viewport(pane)

    wheel(b) = MouseEvent(MouseAction.PRESS, b, 1, 1, MOD_NONE)
    @test content_extent(vp) === Size(16, 1)
    @test max_scroll(vp) === Offset(10, 0)

    @test dispatch_event!(pane, wheel(MouseButton.WHEEL_RIGHT))
    @test scroll_of(vp) === Offset(6, 0)
    buf = Buffer(6, 2)
    clear!(buf)
    paint!(buf, pane)
    @test string(buf) == "GHIJKL\n      "

    @test dispatch_event!(pane, wheel(MouseButton.WHEEL_LEFT))
    @test scroll_of(vp) === Offset(0, 0)
end

@testitem "scroll: shift+wheel scrolls the horizontal axis" begin
    using DualUI
    pane = Scrollpane(Static("ABCDEFGHIJKLMNOP");
                      bar_y = ScrollMode.NEVER, wheel_step_x = 4)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 6, 2))
    vp = viewport(pane)

    shift = Modifiers(Modifier.SHIFT)
    e = MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_DOWN, 1, 1,
                   shift)
    @test dispatch_event!(pane, e)
    # shift SWAPS the axis: a vertical notch moved the horizontal offset
    # and left the vertical one alone.
    @test scroll_of(vp) === Offset(4, 0)

    up = MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_UP, 1, 1, shift)
    @test dispatch_event!(pane, up)
    @test scroll_of(vp) === Offset(0, 0)
end

@testitem "scroll: scrolling past the end clamps and does not consume" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:8]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER, wheel_step = 3)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    wheel(b) = MouseEvent(MouseAction.PRESS, b, 1, 1, MOD_NONE)
    @test dispatch_event!(pane, wheel(MouseButton.WHEEL_DOWN))
    @test scroll_of(vp) === Offset(0, 3)
    # 3 -> 6 would overshoot the maximum of 5: it CLAMPS to 5, which IS
    # a movement, so it consumes.
    @test dispatch_event!(pane, wheel(MouseButton.WHEEL_DOWN))
    @test scroll_of(vp) === Offset(0, 5)
    # Now it is pinned: no movement, no consumption -- this is what lets
    # the notch chain to an outer pane.
    @test !dispatch_event!(pane, wheel(MouseButton.WHEEL_DOWN))
    @test scroll_of(vp) === Offset(0, 5)

    buf = Buffer(9, 3)
    clear!(buf)
    paint!(buf, pane)
    # Pinned at the end shows the LAST three lines, never blank cells
    # past them.
    @test string(buf) == "L6       \nL7       \nL8       "
end

@testitem "scroll: scrolling before the start clamps at zero" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:8]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER, wheel_step = 3)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    @test scroll_to!(vp, Offset(-5, -5)) === Offset(0, 0)
    @test scroll_by!(vp, Offset(0, -99)) === Offset(0, 0)

    wheel(b) = MouseEvent(MouseAction.PRESS, b, 1, 1, MOD_NONE)
    @test !dispatch_event!(pane, wheel(MouseButton.WHEEL_UP))
    @test scroll_of(vp) === Offset(0, 0)

    buf = Buffer(9, 3)
    clear!(buf)
    paint!(buf, pane)
    @test string(buf) == "L1       \nL2       \nL3       "
end

@testitem "scroll: an exhausted inner pane chains to the outer pane" begin
    using DualUI
    inner_content = Container([Static("i$i") for i in 1:6]...)
    inner = Scrollpane(inner_content; bar_y = ScrollMode.NEVER,
                       wheel_step = 2, id = :inner)
    # MERGE, never assign: the pane's own structural geometry lives in
    # its `inline_box`, and replacing it would turn the pane into a
    # BLOCK and break it.
    inner.node.inline_box = merge(inner.node.inline_box,
                                  BoxPatch(; height = cells(2),
                                           shrink = 0f0))
    outer_content = Container(inner, Static("x1"), Static("x2"),
                              Static("x3"))
    outer = Scrollpane(outer_content; bar_y = ScrollMode.NEVER,
                       wheel_step = 1, id = :outer)
    apply_stylesheet!(STYLESHEET_EMPTY, outer)
    layout!(outer, Region(1, 1, 8, 3))

    vi = viewport(inner)
    vo = viewport(outer)
    @test max_scroll(vi).y > 0
    @test max_scroll(vo).y > 0

    down = MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_DOWN, 1, 1,
                      MOD_NONE)
    # Drain the inner pane. The pointer is over the inner pane, so the
    # notch reaches it first and it keeps the whole of it.
    for _ in 1:20
        dispatch_event!(outer, down)
        scroll_of(vi) === max_scroll(vi) && break
    end
    @test scroll_of(vi) === max_scroll(vi)
    before_outer = scroll_of(vo)

    # Exhausted, the inner pane refuses to consume and the SAME notch
    # bubbles to the outer pane. Scroll chaining, out of the phase rule
    # alone.
    @test dispatch_event!(outer, down)
    @test scroll_of(vi) === max_scroll(vi)
    @test scroll_of(vo) !== before_outer
end

@testitem "scroll: scrolled-inside-scrolled composes offsets" begin
    using DualUI
    inner_content = Container([Static("i$i") for i in 1:6]...)
    inner = Scrollpane(inner_content; bar_y = ScrollMode.NEVER,
                       id = :inner)
    inner.node.inline_box = merge(inner.node.inline_box,
                                  BoxPatch(; height = cells(2),
                                           shrink = 0f0))
    outer_content = Container(Static("top"), inner, Static("bot"))
    outer = Scrollpane(outer_content; bar_y = ScrollMode.NEVER,
                       id = :outer)
    apply_stylesheet!(STYLESHEET_EMPTY, outer)
    layout!(outer, Region(1, 1, 6, 3))
    # top(1) + inner(2) + bot(1) = 4 rows of content in a 3-row window.
    @test max_scroll(viewport(outer)) === Offset(0, 1)

    buf = Buffer(6, 3)
    clear!(buf)
    paint!(buf, outer)
    @test string(buf) == "top   \ni1    \ni2    "

    # Scroll the INNER pane only: its own window moves, the outer one
    # does not.
    scroll_to!(viewport(inner), Offset(0, 2))
    clear!(buf)
    paint!(buf, outer)
    @test string(buf) == "top   \ni3    \ni4    "

    # Now scroll the OUTER pane too: the two offsets COMPOSE. The inner
    # pane's BOX slides up one row while its own window stays where the
    # inner offset put it, so i3/i4 ride up together and `bot` arrives.
    scroll_to!(viewport(outer), Offset(0, 1))
    clear!(buf)
    paint!(buf, outer)
    @test string(buf) == "i3    \ni4    \nbot   "
    @test scroll_of(viewport(inner)) === Offset(0, 2)
end

@testitem "scroll: arrows, PageUp/PageDown, Home/End" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:20]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER, wheel_step = 2)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 4))
    vp = viewport(pane)
    @test max_scroll(vp) === Offset(0, 16)

    press(k) = dispatch_event!(pane, key(k), pane)

    @test press(Key.DOWN)
    @test scroll_of(vp) === Offset(0, 2)
    @test press(Key.UP)
    @test scroll_of(vp) === Offset(0, 0)
    # At the top, UP cannot move and must not consume.
    @test !press(Key.UP)

    @test press(Key.PAGE_DOWN)          # one viewport LESS one row
    @test scroll_of(vp) === Offset(0, 3)
    @test press(Key.PAGE_UP)
    @test scroll_of(vp) === Offset(0, 0)

    @test press(Key.END)
    @test scroll_of(vp) === Offset(0, 16)
    @test !press(Key.END)               # already there
    @test press(Key.HOME)
    @test scroll_of(vp) === Offset(0, 0)
    @test !press(Key.HOME)

    # A modified key belongs to an application binding: never consumed.
    @test !dispatch_event!(pane, key(Key.DOWN; ctrl = true), pane)
    @test scroll_of(vp) === Offset(0, 0)
end

@testitem "scroll: arrows scroll the horizontal axis too" begin
    using DualUI
    pane = Scrollpane(Static("ABCDEFGHIJKLMNOP");
                      bar_y = ScrollMode.NEVER, wheel_step = 2)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 6, 2))
    vp = viewport(pane)

    @test dispatch_event!(pane, key(Key.RIGHT), pane)
    @test scroll_of(vp) === Offset(2, 0)
    @test dispatch_event!(pane, key(Key.LEFT), pane)
    @test scroll_of(vp) === Offset(0, 0)
    @test !dispatch_event!(pane, key(Key.LEFT), pane)
end

@testitem "scroll: PageDown overlaps by one row" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:20]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 4))
    vp = viewport(pane)
    @test layout_of(vp).content.height == 4

    buf = Buffer(9, 4)
    clear!(buf)
    paint!(buf, pane)
    @test string(buf) == "L1       \nL2       \nL3       \nL4       "

    @test dispatch_event!(pane, key(Key.PAGE_DOWN), pane)
    # A 4-row viewport pages by 3, NOT by 4: the last row of the old
    # page is the first row of the new one, so the reader keeps a
    # landmark instead of losing their place.
    @test scroll_of(vp) === Offset(0, 3)
    clear!(buf)
    paint!(buf, pane)
    @test string(buf) == "L4       \nL5       \nL6       \nL7       "
end

@testitem "scroll: a shrinking resize re-clamps the offset" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:8]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    scroll_to!(vp, Offset(0, 99))
    @test scroll_of(vp) === Offset(0, 5)

    # The viewport grows until the content fits: the stored offset of 5
    # is now out of range and would paint five blank rows.
    layout!(pane, Region(1, 1, 9, 8))
    @test max_scroll(vp) === Offset(0, 0)

    buf = Buffer(9, 8)
    clear!(buf)
    paint!(buf, pane)
    # The pane re-clamps as it paints, so the frame is correct rather
    # than blank-topped, and the STORED offset is corrected too.
    @test scroll_of(vp) === Offset(0, 0)
    @test string(buf) == "L1       \nL2       \nL3       \nL4       " *
                         "\nL5       \nL6       \nL7       \nL8       "
end

@testitem "scroll: reveal_child! brings a focused child into view" begin
    using DualUI
    kids = [Static("L$i") for i in 1:8]
    inner = Container(kids...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    # L8 is five rows below the window: reveal it and it must sit on the
    # LAST row, not the first -- the minimum move that works.
    reveal!(kids[8])
    @test scroll_of(vp) === Offset(0, 5)
    buf = Buffer(9, 3)
    clear!(buf)
    paint!(buf, pane)
    @test string(buf) == "L6       \nL7       \nL8       "

    # Back up to L1: it must sit on the FIRST row.
    reveal!(kids[1])
    @test scroll_of(vp) === Offset(0, 0)
    clear!(buf)
    paint!(buf, pane)
    @test string(buf) == "L1       \nL2       \nL3       "

    # Idempotent: revealing again moves nothing.
    reveal!(kids[1])
    @test scroll_of(vp) === Offset(0, 0)
end

@testitem "scroll: reveal_child! does not move already-visible content" begin
    using DualUI
    kids = [Static("L$i") for i in 1:8]
    inner = Container(kids...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    scroll_to!(vp, Offset(0, 3))       # window shows L4, L5, L6
    for i in 4:6
        reveal!(kids[i])
        @test scroll_of(vp) === Offset(0, 3)
    end
    # L7 is one row past the bottom: the MINIMUM move is exactly one.
    reveal!(kids[7])
    @test scroll_of(vp) === Offset(0, 4)
end

@testitem "scroll: reveal_child! is a no-op for the pane's own machinery" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:8]...)
    pane = Scrollpane(inner)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    scroll_to!(vp, Offset(0, 3))
    # The canvas is not CONTENT, it is the window itself; revealing it
    # must not rewind the pane to the top.
    reveal_child!(pane, vp)
    @test scroll_of(vp) === Offset(0, 3)
    # A widget in another tree entirely is not a descendant: no-op.
    reveal_child!(pane, Static("elsewhere"))
    @test scroll_of(vp) === Offset(0, 3)
end

@testitem "scroll: reveal_child! through NESTED panes" begin
    using DualUI
    kids = [Static("i$i") for i in 1:6]
    inner_content = Container(kids...)
    inner = Scrollpane(inner_content; bar_y = ScrollMode.NEVER,
                       id = :inner)
    inner.node.inline_box = merge(inner.node.inline_box,
                                  BoxPatch(; height = cells(2),
                                           shrink = 0f0))
    outer_content = Container(Static("t1"), Static("t2"), inner)
    outer = Scrollpane(outer_content; bar_y = ScrollMode.NEVER,
                       id = :outer)
    apply_stylesheet!(STYLESHEET_EMPTY, outer)
    layout!(outer, Region(1, 1, 6, 3))

    vi = viewport(inner)
    vo = viewport(outer)

    # i6 is out of view on BOTH panes at once: the inner pane must
    # scroll to reach it AND the outer pane must scroll to reveal the
    # inner pane's box.
    reveal!(kids[6])
    @test scroll_of(vi) === Offset(0, 4)

    buf = Buffer(6, 3)
    clear!(buf)
    paint!(buf, outer)
    # Nearest-first is load-bearing: the inner pane finished moving
    # before the outer pane measured where i6 had landed, so i6 really
    # is on screen.
    @test occursin("i6", string(buf))
end

@testitem "scroll: on_focus! reveals a focused child through the pane" begin
    using DualUI
    kids = [Button("B$i", b -> nothing) for i in 1:8]
    inner = Container(kids...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    # The default `on_focus!` is `reveal!`, so TAB-ing to a deep widget
    # scrolls it into view with no wiring at the call site.
    on_focus!(kids[8])
    @test scroll_of(vp) === Offset(0, 5)
end

@testitem "scroll: a wheel tick does not re-run layout" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:20]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 4))
    vp = viewport(pane)
    clean!(pane)
    for w in descendants(pane)
        clean!(w)
    end
    @test dirty_root(pane) === nothing

    before = layout_of(vp)
    lm_before = compute_layout(pane, Region(1, 1, 9, 4))

    down = MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_DOWN, 1, 1,
                      MOD_NONE)
    @test dispatch_event!(pane, down)
    @test scroll_of(vp) === Offset(0, 3)

    # THE central claim of the whole design: a wheel tick marks PAINT and
    # nothing else, so `relayout!` returns on its first line and a
    # 20-node tree -- or a 20 000-node one -- costs one repaint.
    @test is_dirty(vp, Dirty.PAINT)
    @test !is_dirty(vp, Dirty.LAYOUT)
    @test dirty_root(pane) === nothing
    @test layout_of(vp) === before

    # The LayoutMap itself is invariant under scroll: same boxes, every
    # node, at a nonzero offset.
    lm_after = compute_layout(pane, Region(1, 1, 9, 4))
    @test length(lm_after) == length(lm_before)
    for (w, lb) in lm_before
        @test lm_after[w] === lb
    end
end

@testitem "scroll: thumb_span pins the thumb to the FIRST cell at 0" begin
    using DualUI
    for (track, view, total) in ((10, 5, 20), (3, 3, 8), (40, 1, 40),
                                 (7, 2, 3))
        (start, len) = thumb_span(track, view, total, 0)
        @test start == 1
        @test len >= 1
        @test start + len - 1 <= track
    end
end

@testitem "scroll: thumb_span pins the thumb to the LAST cell at max" begin
    using DualUI
    for (track, view, total) in ((10, 5, 20), (3, 3, 8), (40, 1, 40),
                                 (7, 2, 3))
        (start, len) = thumb_span(track, view, total, total - view)
        # The two ends are the only positions a user can verify at a
        # glance, so they are the two the arithmetic is written around.
        @test start + len - 1 == track
        @test start >= 1
    end
end

@testitem "scroll: thumb_span never returns a zero-length thumb" begin
    using DualUI
    # A 1-cell thumb on a 40-cell track is the honest rendering of a 40x
    # document; a zero-cell thumb is a broken scrollbar.
    #
    # Swept exhaustively but COLLECTED rather than asserted per case: a
    # @test per combination would add 60k assertions to a 9k suite and
    # drown every other signal in it. A counterexample list names the
    # exact `(track, view, total)` that broke, which is strictly more
    # than a failing @test at loop iteration 41 987 would tell us.
    bad = NTuple{3,Int}[]
    for track in 1:12, total in 1:60, view in 1:total
        (start, len) = thumb_span(track, view, total, 0)
        len == 0 && continue              # nothing to scroll: (0, 0)
        (len >= 1 && start >= 1 && start + len - 1 <= track) ||
            push!(bad, (track, view, total))
    end
    @test isempty(bad)

    (_, len) = thumb_span(40, 1, 4000, 0)
    @test len == 1
end

@testitem "scroll: thumb_span stays inside the track at every offset" begin
    using DualUI
    escaped = NTuple{4,Int}[]
    backwards = NTuple{4,Int}[]
    for (track, view, total) in ((10, 3, 30), (5, 2, 9), (20, 7, 8),
                                 (3, 1, 100))
        prev = 0
        for off in 0:(total - view)
            (start, len) = thumb_span(track, view, total, off)
            len == 0 && continue
            (start >= 1 && start + len - 1 <= track) ||
                push!(escaped, (track, view, total, off))
            # Monotone: a larger offset never moves the thumb backwards.
            start >= prev || push!(backwards, (track, view, total, off))
            prev = start
        end
    end
    @test isempty(escaped)
    @test isempty(backwards)
end

@testitem "scroll: thumb_span returns (0,0) when nothing can scroll" begin
    using DualUI
    @test thumb_span(10, 10, 10, 0) === (0, 0)   # content == viewport
    @test thumb_span(10, 20, 10, 0) === (0, 0)   # content < viewport
    @test thumb_span(0, 5, 20, 0) === (0, 0)     # no track
    @test thumb_span(-3, 5, 20, 0) === (0, 0)
    @test thumb_span(10, 5, 0, 0) === (0, 0)     # no content
    @test thumb_span(10, 0, 20, 0) === (0, 0)    # no window
end

@testitem "scroll: ScrollMode.AUTO reserves the gutter but omits the ink" begin
    using DualUI
    # Content that FITS: the gutter is still reserved (stable), but no
    # ink is drawn in it.
    fits = Scrollpane(Container(Static("a"), Static("b"));
                      bar_y = ScrollMode.AUTO)
    apply_stylesheet!(STYLESHEET_EMPTY, fits)
    layout!(fits, Region(1, 1, 4, 3))
    @test layout_of(viewport(fits)).content.width == 3   # gutter taken
    buf = Buffer(4, 3)
    clear!(buf)
    paint!(buf, fits)
    @test string(buf) == "a   \nb   \n    "

    # Content that OVERFLOWS: same gutter, now inked.
    over = Scrollpane(Container([Static("L$i") for i in 1:8]...);
                      bar_y = ScrollMode.AUTO)
    apply_stylesheet!(STYLESHEET_EMPTY, over)
    layout!(over, Region(1, 1, 4, 3))
    @test layout_of(viewport(over)).content.width == 3
    buf2 = Buffer(4, 3)
    clear!(buf2)
    paint!(buf2, over)
    s = string(buf2)
    @test occursin(DualUI.SB_THUMB, s)
    @test occursin(DualUI.SB_TRACK_V, s)
end

@testitem "scroll: ScrollMode.ALWAYS draws a full thumb when it fits" begin
    using DualUI
    pane = Scrollpane(Container(Static("a"), Static("b"));
                      bar_y = ScrollMode.ALWAYS)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 4, 3))
    buf = Buffer(4, 3)
    clear!(buf)
    paint!(buf, pane)
    t = DualUI.SB_THUMB
    # "All of it is visible" drawn honestly: the thumb fills the track.
    @test string(buf) == "a  $t\nb  $t\n   $t"
end

@testitem "scroll: ScrollMode.NEVER reserves no gutter and still scrolls" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:8]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER, wheel_step = 3)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))
    vp = viewport(pane)

    # No bar, no gutter: the canvas gets the pane's FULL width.
    @test layout_of(vp).content.width == 9
    down = MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_DOWN, 1, 1,
                      MOD_NONE)
    # A scrollbar VISIBILITY policy is not a scroll policy: NEVER still
    # scrolls.
    @test dispatch_event!(pane, down)
    @test scroll_of(vp) === Offset(0, 3)
    buf = Buffer(9, 3)
    clear!(buf)
    paint!(buf, pane)
    @test string(buf) == "L4       \nL5       \nL6       "
end

@testitem "scroll: both bar glyphs are width-1" begin
    using DualUI
    # A width-2 glyph in a 1-cell gutter would desynchronise every
    # column to its right, exactly as a width-2 border glyph would.
    for g in (DualUI.SB_TRACK_V, DualUI.SB_TRACK_H, DualUI.SB_THUMB)
        @test text_width(g) == 1
        @test grapheme_width(g) == 1
        @test length(collect(Base.Unicode.graphemes(g))) == 1
    end
end

@testitem "scroll: content never overwrites the gutter" begin
    using DualUI
    # Content far wider than the window, scrolled to the right, with a
    # vertical bar: not one glyph may reach the gutter column.
    pane = Scrollpane(Static("ABCDEFGHIJKLMNOPQRSTUVWXYZ");
                      bar_y = ScrollMode.ALWAYS)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 6, 2))
    vp = viewport(pane)
    @test layout_of(vp).content.width == 5

    t = DualUI.SB_THUMB
    for off in 0:max_scroll(vp).x
        scroll_to!(vp, Offset(off, 0))
        buf = Buffer(6, 2)
        clear!(buf)
        paint!(buf, pane)
        # Column 6 is the gutter: it is bar ink at every offset, never
        # a letter.
        @test buf[6, 1].content == t
        @test buf[6, 2].content == t
    end
end

@testitem "scroll: a scrolled child never paints outside the pane" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:8]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.NEVER, id = :pane)
    pane.node.inline_box = merge(pane.node.inline_box,
                                 BoxPatch(; height = cells(3),
                                          shrink = 0f0))
    root = Container(pane, Static("BELOW"); id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 9, 5))
    vp = viewport(pane)

    for off in 0:max_scroll(vp).y
        buf = Buffer(9, 5)
        clear!(buf)
        paint!(buf, root)
        lines = split(string(buf), '\n')
        # Row 4 belongs to the sibling and row 5 to nobody: whatever the
        # offset, legal or not, the pane's content cannot reach them.
        @test lines[4] == "BELOW    "
        @test lines[5] == "         "
        for row in 1:3
            @test !occursin("BELOW", lines[row])
        end
    end
end

@testitem "scroll: a Scrollbar observes a bare Container" begin
    using DualUI
    # The scrollable seam is THREE FUNCTIONS, not a type: a plain
    # Container carrying an offset is scrollable, and one Scrollbar
    # reports on it with no new code.
    inner = Container([Static("L$i") for i in 1:8]...)
    canvas = Container(inner; id = :canvas)
    canvas.node.inline_box = BoxPatch(; display = Display.FLEX,
                                      direction = Direction.COLUMN,
                                      align = Align.START, grow = 1f0,
                                      overflow_y = Overflow.SCROLL)
    inner.node.inline_box = BoxPatch(; shrink = 0f0, grow = 0f0)
    bar = Scrollbar(canvas, ScrollAxis.VERTICAL;
                    mode = ScrollMode.ALWAYS, id = :bar)
    bar.node.inline_box = BoxPatch(; width = cells(1), shrink = 0f0,
                                   grow = 0f0)
    root = Container(canvas, bar; id = :root)
    root.node.inline_box = BoxPatch(; display = Display.FLEX,
                                    direction = Direction.ROW)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 9, 4))

    @test bar isa Scrollbar{Container}
    @test bar.viewport === canvas
    @test content_extent(canvas).height == 8
    @test layout_of(canvas).content.height == 4

    buf = Buffer(9, 4)
    clear!(buf)
    paint!(buf, root)
    col = [buf[9, y].content for y in 1:4]
    # track 4, view 4, total 8 -> a 2-cell thumb pinned to the top.
    @test col == [DualUI.SB_THUMB, DualUI.SB_THUMB,
                  DualUI.SB_TRACK_V, DualUI.SB_TRACK_V]

    scroll_to!(canvas, Offset(0, 4))     # the maximum
    clear!(buf)
    paint!(buf, root)
    col2 = [buf[9, y].content for y in 1:4]
    # At the maximum the thumb is pinned to the LAST cell.
    @test col2 == [DualUI.SB_TRACK_V, DualUI.SB_TRACK_V,
                   DualUI.SB_THUMB, DualUI.SB_THUMB]
end

@testitem "scroll: a Scrollbar jumps the viewport on a LEFT press" begin
    using DualUI
    inner = Container([Static("L$i") for i in 1:20]...)
    pane = Scrollpane(inner; bar_y = ScrollMode.ALWAYS)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 4))
    vp = viewport(pane)
    @test max_scroll(vp) === Offset(0, 16)

    # The gutter is column 9. A press at its LAST row jumps to the end;
    # at its first row, back to the start.
    press(y) = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 9, y,
                          MOD_NONE)
    @test dispatch_event!(pane, press(4))
    @test scroll_of(vp) === Offset(0, 16)
    @test dispatch_event!(pane, press(1))
    @test scroll_of(vp) === Offset(0, 0)

    # A DRAG continues the jump; a RELEASE does nothing and consumes
    # nothing.
    drag = MouseEvent(MouseAction.DRAG, MouseButton.LEFT, 9, 4,
                      MOD_NONE)
    @test dispatch_event!(pane, drag)
    @test scroll_of(vp) === Offset(0, 16)
    rel = MouseEvent(MouseAction.RELEASE, MouseButton.LEFT, 9, 1,
                     MOD_NONE)
    @test !dispatch_event!(pane, rel)
    @test scroll_of(vp) === Offset(0, 16)
end

@testitem "scroll: mount! forwards to the canvas" begin
    using DualUI
    pane = Scrollpane()
    child = Static("hi")
    @test mount!(pane, child) === pane
    # `children(pane)` is the pane's own machinery and the user never
    # addresses it: the child lives INSIDE the canvas.
    @test parent(child) !== pane
    @test child in descendants(viewport(pane))
    @test !(child in children(pane))

    # ONE child: wrap several in a Container, exactly as CSS makes you.
    @test_throws ArgumentError mount!(pane, Static("second"))

    # The constructor form mounts identically.
    c2 = Static("ho")
    p2 = Scrollpane(c2)
    @test c2 in descendants(viewport(p2))
end

@testitem "scroll: viewport is the canvas and carries the offset" begin
    using DualUI
    pane = Scrollpane(Container([Static("L$i") for i in 1:8]...))
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 9, 3))

    vp = viewport(pane)
    @test vp isa Container
    @test vp === pane.canvas
    # The pane's NODE holds no offset of its own: the offset is the
    # canvas's, the core field, so a wheel tick is one PAINT mark. This
    # is the invariant paint depends on -- `paint_offset` reads
    # `node(a).scroll` directly, and a non-zero one here would shift the
    # pane's row, dragging the scrollbar along with the content.
    @test node(pane).scroll === Offset(0, 0)
    scroll_to!(vp, Offset(0, 2))
    @test scroll_of(vp) === Offset(0, 2)
    @test node(pane).scroll === Offset(0, 0)
    # The pane nonetheless REPORTS its canvas's position, so that
    # `scroll_of`/`max_scroll`/`scroll_to!` on a pane describe what the
    # user sees rather than silently answering for the empty shell.
    @test scroll_of(pane) === Offset(0, 2)
end

@testitem "scroll: ScrollMode and ScrollAxis are module-scoped enums" begin
    using DualUI
    @test ScrollMode.AUTO isa ScrollMode.T
    @test ScrollMode.NEVER isa ScrollMode.T
    @test ScrollMode.ALWAYS isa ScrollMode.T
    @test ScrollAxis.VERTICAL isa ScrollAxis.T
    @test ScrollAxis.HORIZONTAL isa ScrollAxis.T
    @test ScrollMode.NEVER < ScrollMode.AUTO < ScrollMode.ALWAYS
    @test Set(instances(ScrollMode.T)) ==
          Set([ScrollMode.NEVER, ScrollMode.AUTO, ScrollMode.ALWAYS])
    @test Set(instances(ScrollAxis.T)) ==
          Set([ScrollAxis.VERTICAL, ScrollAxis.HORIZONTAL])
end

@testitem "scroll: a Scrollpane is focusable by default" begin
    using DualUI
    # A pane with no focusable children is still keyboard-scrollable.
    p = Scrollpane(Container(Static("a")))
    @test is_focusable(p)
    @test p in focusable_widgets(p)
    q = Scrollpane(Container(Static("a")); focusable = false)
    @test !is_focusable(q)
end

@testitem "scroll: measure of a Scrollbar is one cell thick" begin
    using DualUI
    c = Container()
    v = Scrollbar(c, ScrollAxis.VERTICAL)
    h = Scrollbar(c, ScrollAxis.HORIZONTAL)
    # A bar claims nothing on its LONG axis: it is the flex container
    # that grants that, and claiming it here would fight the layout.
    @test measure(v, Size(80, 24)) === Size(1, 0)
    @test measure(h, Size(80, 24)) === Size(0, 1)
    @test v.axis === ScrollAxis.VERTICAL
    @test h.axis === ScrollAxis.HORIZONTAL
    @test v.mode === ScrollMode.AUTO
end

@testitem "scroll: a horizontal Scrollbar reports the horizontal axis" begin
    using DualUI
    pane = Scrollpane(Static("ABCDEFGHIJKLMNOPQRST");
                      bar_y = ScrollMode.NEVER,
                      bar_x = ScrollMode.ALWAYS)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 5, 3))
    vp = viewport(pane)

    # The horizontal bar takes one ROW, leaving two for the canvas.
    @test layout_of(vp).content === Region(1, 1, 5, 2)
    @test max_scroll(vp) === Offset(15, 0)

    buf = Buffer(5, 3)
    clear!(buf)
    paint!(buf, pane)
    row = [buf[x, 3].content for x in 1:5]
    # track 5, view 5, total 20 -> a 1-cell thumb pinned to the left.
    @test row[1] == DualUI.SB_THUMB
    @test all(==(DualUI.SB_TRACK_H), row[2:5])

    scroll_to!(vp, Offset(15, 0))
    clear!(buf)
    paint!(buf, pane)
    row2 = [buf[x, 3].content for x in 1:5]
    @test row2[5] == DualUI.SB_THUMB
    @test all(==(DualUI.SB_TRACK_H), row2[1:4])
end

@testitem "scroll: the public API scrolls the pane, not its shell" begin
    using DualUI

    # REGRESSION. `viewport(::Scrollpane)` delegates to the canvas but
    # `content_extent`, `max_scroll`, `scroll_to!` and `scroll_by!` did
    # not: they fell through to the generic ::Widget method and measured
    # the pane's internal row, whose extent IS the viewport. max_scroll
    # was therefore Offset(0, 0) and every programmatic scroll clamped to
    # nothing -- silently, with no error. The wheel worked (it routes via
    # the canvas), so this hid behind a working feature.
    function fresh()
        lines = [Label("L$i"; id = Symbol("l", i)) for i in 1:8]
        content = Container(lines...; id = :content)
        pane = Scrollpane(content; id = :pane)
        root = Container(pane; id = :root)
        apply_stylesheet!(STYLESHEET_EMPTY, root)
        layout!(root, Region(1, 1, 12, 3))
        return root, pane
    end
    rows(root) = begin
        b = Buffer(Size(12, 3))
        clear!(b)
        paint!(b, root)
        [strip(join(String(b.cells[x, y].content) for x in 1:11))
         for y in 1:3]
    end

    # The pane reports the geometry of what it SHOWS, not of its shell.
    root, pane = fresh()
    @test content_extent(pane) == content_extent(viewport(pane))
    @test max_scroll(pane) == max_scroll(viewport(pane))
    # 8 rows of content in a 3-row window leaves 5 to scroll.
    @test max_scroll(pane) == Offset(0, 5)

    # scroll_to! moves what is on screen.
    root, pane = fresh()
    @test rows(root) == ["L1", "L2", "L3"]
    scroll_to!(pane, Offset(0, 2))
    @test rows(root) == ["L3", "L4", "L5"]

    # scroll_by! is relative and also moves what is on screen.
    root, pane = fresh()
    scroll_by!(pane, Offset(0, 2))
    @test rows(root) == ["L3", "L4", "L5"]
    scroll_by!(pane, Offset(0, 1))
    @test rows(root) == ["L4", "L5", "L6"]

    # Both clamp at both ends rather than running off.
    root, pane = fresh()
    scroll_by!(pane, Offset(0, 999))
    @test rows(root) == ["L6", "L7", "L8"]
    scroll_by!(pane, Offset(0, -999))
    @test rows(root) == ["L1", "L2", "L3"]

    # And the pane agrees with its canvas about where it is scrolled to.
    root, pane = fresh()
    scroll_to!(pane, Offset(0, 4))
    @test scroll_of(pane) == scroll_of(viewport(pane))
    @test scroll_of(pane) == Offset(0, 4)
end
