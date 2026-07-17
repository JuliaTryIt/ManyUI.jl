# scrolloffset_tests.jl -- @testitem blocks for the scroll-offset core:
# the `ScrolledView` origin/clip split in buffer.jl, the
# `WidgetNode.scroll` field and the pure clamps in widget.jl, and the
# frame/clip separation in paint.jl.
#
# The thesis under test, in one line: `lb.content` is the FRAME (where
# local (1, 1) is) and `intersect(lb.content, clip)` is the CLIP (which
# cells may be touched), and conflating the two -- which is what the
# package did until now -- misplaces a glyph the moment a clip cuts a
# content box's TOP-LEFT corner.
#
# Every @testitem is self-contained: TestItemRunner 1.1.5 does not
# detect `@testsetup`, so the fixtures are repeated rather than shared.
# None needs a tty, none sleeps, none waits.

# --------------------------------------------------------------------
# The regression guard. This one must pass BEFORE and AFTER the change.
# --------------------------------------------------------------------

@testitem "scrolloffset: an unscrolled tree paints exactly as before" begin
    using DualUI

    mutable struct RG <: DualUI.Widget
        node::DualUI.WidgetNode
        seen::Vector{Symbol}
    end
    DualUI.measure(w::RG, avail::Size)::Size = Size(4, 1)
    function DualUI.render!(w::RG, b::AbstractMatrix{Cell})::Nothing
        push!(w.seen, nameof(typeof(b)))
        write_text!(b, 1, 1, "abcd", STYLE_NONE)
        return nothing
    end

    seen = Symbol[]
    root = Container(; id = :root)
    node(root).inline_box = BoxPatch(; display = Display.FLEX,
                                     direction = Direction.COLUMN,
                                     border = Border(BorderKind.SOLID,
                                                     STYLE_NONE))
    lab = Label("hello world")
    stub = RG(WidgetNode(; id = :stub, type_name = :RG), seen)
    btn = Button("OK", b -> nothing)
    mount!(root, lab)
    mount!(root, stub)
    mount!(root, btn)

    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 14, 6))
    buf = Buffer(14, 6)
    clear!(buf)
    paint!(buf, root)

    # A golden picture, captured from the pre-scroll compositor. The
    # whole point of the origin/clip split is that this does not move.
    @test string(buf) == join(["┌────────────┐",
                               "│hello world │",
                               "│abcd        │",
                               "│     OK     │",
                               "│            │",
                               "└────────────┘"], '\n')

    # Nothing in this tree scrolls, so `intersect(content, clip) ===
    # content` at every node and the compositor must build THE EXACT
    # view it built before -- a `BufferView`, never a `ScrolledView`.
    @test seen == [:BufferView]
    @test all(w -> scroll_of(w) === ORIGIN, descendants(root))
    @test scroll_of(root) === ORIGIN
    @test paint_offset(stub) === ORIGIN
    @test painted_region(stub) === region(stub)
end

# --------------------------------------------------------------------
# The pure clamp vocabulary (widget.jl).
# --------------------------------------------------------------------

@testitem "scrolloffset: an unscrolled node's scroll is ORIGIN" begin
    using DualUI

    c = Container()
    @test node(c).scroll === ORIGIN
    @test scroll_of(c) === Offset(0, 0)
    @test paint_offset(c) === ORIGIN
    @test WidgetNode(; type_name = :X).scroll === ORIGIN
end

@testitem "scrolloffset: clamp_scroll pins to 0 when content fits" begin
    using DualUI

    # content <= viewport: there is nowhere to go but 0.
    @test clamp_scroll(0, 10, 4) == 0
    @test clamp_scroll(5, 10, 4) == 0
    @test clamp_scroll(-3, 10, 4) == 0
    @test clamp_scroll(9999, 10, 10) == 0     # an exact fit still fits
    # A degenerate extent must not produce a negative range.
    @test clamp_scroll(3, 0, 0) == 0
    @test clamp_scroll(3, 4, 0) == 0
end

@testitem "scrolloffset: clamp_scroll pins to content - viewport" begin
    using DualUI

    @test clamp_scroll(100, 3, 10) == 7
    @test clamp_scroll(7, 3, 10) == 7
    @test clamp_scroll(2, 3, 10) == 2
    @test clamp_scroll(0, 3, 10) == 0
    @test clamp_scroll(-1, 3, 10) == 0
    # Idempotent: clamping a clamped value changes nothing.
    @test clamp_scroll(clamp_scroll(100, 3, 10), 3, 10) == 7
end

@testitem "scrolloffset: scroll_into_view keeps visible content still" begin
    using DualUI

    # Window 2:6 (0-based, viewport 5); the extent 3:5 is already in it.
    @test scroll_into_view(2, 5, 3, 5) == 2
    @test scroll_into_view(2, 5, 2, 6) == 2
    @test scroll_into_view(0, 5, 0, 4) == 0
    # Minimal movement below: 8 must become visible, 4:8 is nearest.
    @test scroll_into_view(0, 5, 7, 8) == 4
    # Minimal movement above: 2 must become visible, 2:6 is nearest.
    @test scroll_into_view(10, 5, 2, 3) == 2
    # Not laid out yet: a non-positive viewport moves nothing.
    @test scroll_into_view(4, 0, 100, 200) == 4
    @test scroll_into_view(4, -1, 100, 200) == 4
    # Never negative.
    @test scroll_into_view(0, 5, -3, -2) == 0
end

@testitem "scrolloffset: scroll_into_view prefers an over-long START" begin
    using DualUI

    # The extent 1:10 cannot fit a 3-cell window: its START wins, so the
    # reader sees the top of the over-long item rather than its bottom.
    @test scroll_into_view(0, 3, 1, 10) == 1
    @test scroll_into_view(9, 3, 1, 10) == 1
    # Idempotent.
    @test scroll_into_view(scroll_into_view(9, 3, 1, 10), 3, 1, 10) == 1
end

# --------------------------------------------------------------------
# ScrolledView: the origin/clip split made structural (buffer.jl).
# --------------------------------------------------------------------

@testitem "scrolloffset: ScrolledView size is the FRAME not the clip" begin
    using DualUI

    buf = Buffer(10, 6)
    v = ScrolledView(buf, Region(1, 1, 8, 6), Region(2, 2, 4, 3))
    @test v isa AbstractMatrix{Cell}
    @test size(v) == (8, 6)               # the FRAME
    @test buffer_size(v) === Size(8, 6)
    @test buffer_region(v) === Region(1, 1, 8, 6)
    @test writable_region(v) === Region(2, 2, 4, 3)   # the CLIP, local

    # The inner constructor makes a malformed view unrepresentable:
    # `clip` is intersected with BOTH the frame and the parent.
    w = ScrolledView(buf, Region(3, 3, 4, 2), Region(1, 1, 40, 40))
    @test w.clip === Region(3, 3, 4, 2)
    @test issubset(w.clip, w.frame)
    @test issubset(w.clip, buffer_region(buf))
    x = ScrolledView(buf, Region(-4, -4, 6, 6), Region(-9, -9, 99, 99))
    @test x.clip === Region(1, 1, 1, 1)
    @test issubset(x.clip, x.frame)
end

@testitem "scrolloffset: a shifted frame places glyphs by the frame" begin
    using DualUI

    buf = Buffer(8, 3)
    clear!(buf)
    # The frame starts three cells LEFT of the buffer: local (1, 1) is
    # absolute (-2, 1), so "ABC" is scrolled off and "D" lands first.
    v = ScrolledView(buf, Region(-2, 1, 8, 3), Region(1, 1, 6, 3))
    @test size(v) == (8, 3)
    @test write_text!(v, 1, 1, "ABCDEFGH", STYLE_NONE) == 8

    @test String(buf[1, 1].content) == "D"
    @test String(buf[2, 1].content) == "E"
    @test String(buf[3, 1].content) == "F"
    @test String(buf[4, 1].content) == "G"
    @test String(buf[5, 1].content) == "H"

    # A read through the view uses the FRAME's coordinates too.
    @test String(v[4, 1].content) == "D"
    @test v[1, 1] === CELL_BLANK      # scrolled off: outside the clip
end

@testitem "scrolloffset: a shifted frame clips by the clip" begin
    using DualUI

    buf = Buffer(8, 3)
    clear!(buf)
    v = ScrolledView(buf, Region(-2, 1, 8, 3), Region(1, 1, 6, 3))
    @test writable_region(v) === Region(4, 1, 5, 3)
    write_text!(v, 1, 1, "ABCDEFGH", STYLE_NONE)

    # The clip's right edge is absolute 5; 6..8 are untouched even
    # though the FRAME reaches them.
    for x in 6:8
        @test buf[x, 1] === CELL_BLANK
    end
    # Rows the frame covers but nothing wrote are untouched.
    @test String(buf[1, 2].content) == " "
end

@testitem "scrolloffset: a ScrolledView drops writes above and left" begin
    using DualUI

    buf = Buffer(6, 4)
    clear!(buf)
    # Local (3, 3) is absolute (1, 1): everything above and left of it
    # is scrolled off.
    v = ScrolledView(buf, Region(-1, -1, 6, 4), Region(1, 1, 6, 4))
    @test writable_region(v) === Region(3, 3, 4, 2)

    # A dropped write still reports the cells it would have advanced --
    # that is what keeps `write_text!` aligned across the edge.
    @test set_cell!(v, 1, 1, "X", STYLE_NONE) == 1
    @test v[1, 1] === CELL_BLANK
    @test all(c -> String(c.content) == " ", buf)

    @test set_cell!(v, 3, 3, "X", STYLE_NONE) == 1
    @test String(buf[1, 1].content) == "X"
    @test count(c -> String(c.content) == "X", buf) == 1

    # A sub-view inherits BOTH the shifted origin and the clip, and
    # stays two-level.
    s = view(v, Region(3, 3, 4, 2))
    @test s isa ScrolledView
    @test s.parent === buf
    @test s.frame === Region(1, 1, 4, 2)
    @test s.clip === Region(1, 1, 4, 2)
end

@testitem "scrolloffset: writable_region == buffer_region on old grids" begin
    using DualUI

    # THE no-regression lemma: for every grid that existed before this
    # change, the frame IS the clip, so every writer that swapped
    # `buffer_region` for `writable_region` behaves identically -- by
    # construction, not by luck.
    b = Buffer(9, 4)
    @test writable_region(b) === buffer_region(b) === Region(1, 1, 9, 4)

    for r in (Region(2, 2, 4, 3), Region(1, 1, 9, 4),
              Region(-3, -3, 40, 40), Region(5, 5, 0, 0))
        v = view(b, r)
        @test v isa BufferView
        @test writable_region(v) === buffer_region(v)
    end

    v = view(b, Region(2, 2, 4, 3))
    @test writable_region(view(v, Region(2, 2, 2, 2))) ===
          buffer_region(view(v, Region(2, 2, 2, 2)))
    @test writable_region(Buffer(0, 0)) === buffer_region(Buffer(0, 0))
end

# --------------------------------------------------------------------
# S3 across a clip edge: scrolling is the first thing in this package
# that can cut a wide grapheme's HEAD off.
# --------------------------------------------------------------------

@testitem "scrolloffset: a wide cluster at the LEFT clip edge is dropped" begin
    using DualUI

    buf = Buffer(6, 1)
    clear!(buf)
    # Local 1 is absolute 0: a width-2 cluster there would put only its
    # CONTINUATION on screen.
    v = ScrolledView(buf, Region(0, 1, 6, 1), Region(1, 1, 6, 1))
    @test writable_region(v) === Region(2, 1, 5, 1)

    @test set_cell!(v, 1, 1, "世", STYLE_NONE) == 0   # refused, whole
    @test buf[1, 1] === CELL_BLANK
    @test !is_continuation(buf[1, 1])

    # One cell further right it fits, and lands whole.
    @test set_cell!(v, 2, 1, "世", STYLE_NONE) == 2
    @test String(buf[1, 1].content) == "世"
    @test buf[1, 1].width == Int8(2)
    @test is_continuation(buf[2, 1])
end

@testitem "scrolloffset: a wide cluster at the RIGHT clip edge is dropped" begin
    using DualUI

    buf = Buffer(6, 1)
    clear!(buf)
    # The FRAME is 6 wide but the CLIP stops at 4, so `set_cell!`'s old
    # `x + 1 > w` guard (which tests the frame) cannot see this edge.
    v = ScrolledView(buf, Region(1, 1, 6, 1), Region(1, 1, 4, 1))
    @test size(v) == (6, 1)
    @test writable_region(v) === Region(1, 1, 4, 1)

    @test set_cell!(v, 4, 1, "界", STYLE_NONE) == 0
    @test buf[4, 1] === CELL_BLANK
    @test buf[5, 1] === CELL_BLANK

    @test set_cell!(v, 3, 1, "界", STYLE_NONE) == 2
    @test String(buf[3, 1].content) == "界"
    @test is_continuation(buf[4, 1])
end

@testitem "scrolloffset: no orphaned continuation at ANY offset" begin
    using DualUI

    # One case is not enough: the two edges fail for DIFFERENT reasons
    # -- the right via `x + 1 > w`, the left via the clip guard -- so
    # sweep the whole range on BOTH axes.
    for sy in -4:4, sx in -8:8
        buf = Buffer(8, 3)
        clear!(buf)
        v = ScrolledView(buf, Region(1 - sx, 1 - sy, 8, 3),
                         Region(1, 1, 8, 3))
        for y in 1:3
            write_text!(v, 1, y, "世界世界", STYLE_NONE)
        end
        for y in 1:3, x in 1:8
            c = buf[x, y]
            if is_continuation(c)
                # An orphaned continuation corrupts every column right
                # of it.
                @test x > 1 && buf[x-1, y].width == Int8(2)
            end
            if c.width == Int8(2)
                # A widowed head is the same bug seen from the left.
                @test x < 8 && is_continuation(buf[x+1, y])
            end
        end
    end
end

# --------------------------------------------------------------------
# paint.jl: the frame/clip separation.
# --------------------------------------------------------------------

@testitem "scrolloffset: a clip cutting the TOP-LEFT keeps the origin" begin
    using DualUI

    # The literal bug paint.jl's old comment predicted: a clip that cuts
    # the content box's TOP-LEFT corner used to move the local origin
    # with it, so a glyph at local (1, 1) landed on the CLIP's corner.
    mutable struct TL{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::TL, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)

    frames = Tuple{Int,Int}[]
    content = Region(1, 1, 8, 6)
    n = WidgetNode(; id = :tl, type_name = :TL)
    n.layout = LayoutBox(content, content, content, content)
    w = TL(n, b -> begin
        push!(frames, size(b))
        set_cell!(b, 1, 1, "A", STYLE_NONE)
        set_cell!(b, 2, 2, "B", STYLE_NONE)
        set_cell!(b, 5, 4, "C", STYLE_NONE)
        nothing
    end)

    buf = Buffer(10, 6)
    clear!(buf)
    DualUI._paint_node!(buf, w, Region(2, 2, 4, 3))

    # The frame is the FULL content box, whatever the clip cut off.
    @test frames == [(8, 6)]
    # Local (1, 1) IS absolute (1, 1) -- outside the clip, so dropped,
    # NOT relocated onto the clip's corner.
    @test count(c -> String(c.content) == "A", buf) == 0
    @test String(buf[1, 1].content) == " "
    # Local (2, 2) IS absolute (2, 2) -- inside the clip.
    @test String(buf[2, 2].content) == "B"
    # Local (5, 4) IS absolute (5, 4) -- inside the clip's last cell.
    @test String(buf[5, 4].content) == "C"
    @test count(c -> String(c.content) in ("B", "C"), buf) == 2
end

@testitem "scrolloffset: size(buf) in render! is invariant under scroll" begin
    using DualUI

    # The assertion a design that grows a node's own frame under scroll
    # fails, and this one passes: `size(buf)` inside `render!` is the
    # widget's REAL content box, so a scrolled Label does not rewrap and
    # a scrolled Button does not re-centre.
    mutable struct IV <: DualUI.Widget
        node::DualUI.WidgetNode
        seen::Vector{Tuple{Int,Int}}
    end
    DualUI.render!(w::IV, b::AbstractMatrix{Cell})::Nothing =
        (push!(w.seen, size(b)); nothing)

    par = Container()
    kid = IV(WidgetNode(; type_name = :IV), Tuple{Int,Int}[])
    mount!(par, kid)
    pr = Region(1, 1, 6, 3)
    kr = Region(1, 1, 6, 8)
    node(par).layout = LayoutBox(pr, pr, pr, pr)
    node(kid).layout = LayoutBox(kr, kr, kr, kr)

    for sy in 0:5, sx in 0:4
        set_scroll!(par, Offset(sx, sy))
        buf = Buffer(6, 3)
        clear!(buf)
        paint!(buf, par)
    end
    @test length(kid.seen) == 30
    @test all(s -> s === (6, 8), kid.seen)
end

@testitem "scrolloffset: scroll shifts children not the own frame" begin
    using DualUI

    mutable struct SC{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::SC, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkn(t) = (n = WidgetNode(; type_name = t);
              n.layout = LayoutBox(Region(1, 1, 6, 3), Region(1, 1, 6, 3),
                                   Region(1, 1, 6, 3), Region(1, 1, 6, 3));
              n)

    par = SC(mkn(:SC), b -> set_cell!(b, 1, 1, "P", STYLE_NONE))
    kid = SC(mkn(:SC), b -> begin
        set_cell!(b, 1, 1, "K", STYLE_NONE)
        set_cell!(b, 3, 3, "L", STYLE_NONE)
        nothing
    end)
    mount!(par, kid)
    set_scroll!(par, Offset(0, 2))

    buf = Buffer(6, 3)
    clear!(buf)
    paint!(buf, par)

    # The parent's OWN glyph is untouched by the parent's own scroll.
    @test String(buf[1, 1].content) == "P"
    # The child's is shifted UP by two: local (1, 1) is now absolute
    # (1, -1) and is dropped ...
    @test count(c -> String(c.content) == "K", buf) == 0
    # ... while local (3, 3) is absolute (3, 1) and lands.
    @test String(buf[3, 1].content) == "L"
end

@testitem "scrolloffset: a scrolled widget cannot escape its clip" begin
    using DualUI

    mutable struct ES{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::ES, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)

    par = Container()
    kr = Region(1, 1, 20, 20)
    src = Buffer(30, 30)
    fill!(src, Cell("Z", STYLE_NONE))
    kid = ES(WidgetNode(; type_name = :ES), b -> begin
        # Deliberately hostile on every side, through BOTH the raw
        # index and every clipped writer.
        for y in -3:12, x in -3:30
            b[x, y] = Cell("Z", STYLE_NONE)
        end
        fill_region!(b, Region(-40, -40, 99, 99), Cell("Z", STYLE_NONE))
        blit!(b, src, Offset(-9, -9))
        nothing
    end)
    mount!(par, kid)
    pr = Region(3, 2, 4, 3)
    node(par).layout = LayoutBox(pr, pr, pr, pr)
    node(kid).layout = LayoutBox(kr, kr, kr, kr)
    set_scroll!(par, Offset(1, 1))

    buf = Buffer(8, 6)
    clear!(buf)
    paint!(buf, par)

    # The clip -- the parent's content box -- is the ONLY authority,
    # and the frame's shifted origin buys the child nothing.
    for y in 1:6, x in 1:8
        want = Offset(x, y) in pr ? "Z" : " "
        @test String(buf[x, y].content) == want
    end
end

@testitem "scrolloffset: nested scroll offsets compose" begin
    using DualUI

    mutable struct NS{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::NS, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)

    outer = Container()
    mid = Container()
    leaf = NS(WidgetNode(; type_name = :NS),
              b -> set_cell!(b, 3, 4, "@", STYLE_NONE))
    mount!(outer, mid)
    mount!(mid, leaf)

    orr = Region(1, 1, 8, 6)
    inr = Region(1, 1, 8, 10)
    node(outer).layout = LayoutBox(orr, orr, orr, orr)
    node(mid).layout = LayoutBox(inr, inr, inr, inr)
    node(leaf).layout = LayoutBox(inr, inr, inr, inr)
    set_scroll!(outer, Offset(0, 2))
    set_scroll!(mid, Offset(2, 0))

    @test paint_offset(leaf) === Offset(-2, -2)

    buf = Buffer(8, 6)
    clear!(buf)
    paint!(buf, outer)

    # local (3, 4) - (2, 2) = absolute (1, 2).
    @test String(buf[1, 2].content) == "@"
    @test count(c -> String(c.content) == "@", buf) == 1

    # Unscroll the outer pane and the glyph moves down by exactly two.
    set_scroll!(outer, ORIGIN)
    b2 = Buffer(8, 6)
    clear!(b2)
    paint!(b2, outer)
    @test String(b2[1, 4].content) == "@"
end

# --------------------------------------------------------------------
# A wheel tick is a repaint, never a relayout.
# --------------------------------------------------------------------

@testitem "scrolloffset: a PAINT mark leaves dirty_root nothing" begin
    using DualUI

    root = Container(; id = :root)
    c = Container(; id = :c)
    mount!(root, c)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 10, 5))
    @test dirty_root(root) === nothing

    @test set_scroll!(c, Offset(0, 3)) === true
    @test is_dirty(c, Dirty.PAINT)
    @test !is_dirty(c, Dirty.LAYOUT)
    @test !is_dirty(root, Dirty.LAYOUT)
    # `mark!(w, PAINT)` drops only SUBTREE breadcrumbs, and `dirty_root`
    # descends them looking for REAL layout dirt -- and finds none.
    @test dirty_root(root) === nothing
    # So a wheel tick costs one paint and one diff, and NO relayout:
    # `relayout!` returns on its first line.
    before = region(c)
    relayout!(root, Region(1, 1, 10, 5))
    @test region(c) === before
    @test scroll_of(c) === Offset(0, 3)
end

@testitem "scrolloffset: the LayoutMap is invariant under scroll" begin
    using DualUI

    root = Container(; id = :root)
    a = Container(; id = :a)
    b = Label("wide enough text")
    mount!(root, a)
    mount!(a, b)
    apply_stylesheet!(STYLESHEET_EMPTY, root)

    vp = Region(1, 1, 10, 5)
    lm1 = compute_layout(root, vp)
    set_scroll!(a, Offset(3, 4))
    set_scroll!(root, Offset(7, 9))
    lm2 = compute_layout(root, vp)

    @test length(lm1) == length(lm2) == 3
    for (w, lb) in lm1
        @test lm2[w] === lb
    end
end

# --------------------------------------------------------------------
# The scroll field and its derived geometry (widget.jl).
# --------------------------------------------------------------------

@testitem "scrolloffset: set_scroll! is idempotent and clamps at zero" begin
    using DualUI

    c = Container()
    @test set_scroll!(c, Offset(2, 3)) === true
    @test scroll_of(c) === Offset(2, 3)
    @test set_scroll!(c, Offset(2, 3)) === false     # no change, no mark
    @test set_scroll!(c, Offset(-4, -1)) === true
    @test scroll_of(c) === ORIGIN                    # clamped per axis
    @test set_scroll!(c, Offset(-9, -9)) === false
    @test set_scroll!(c, Offset(-9, 5)) === true
    @test scroll_of(c) === Offset(0, 5)
    # The UPPER bound is NOT this layer's business: an over-scroll is a
    # UX bug (blank cells), never corruption.
    @test set_scroll!(c, Offset(0, 10_000)) === true
    @test scroll_of(c) === Offset(0, 10_000)
end

@testitem "scrolloffset: paint_offset excludes the node's own scroll" begin
    using DualUI

    a = Container()
    b = Container()
    c = Container()
    mount!(a, b)
    mount!(b, c)
    set_scroll!(a, Offset(1, 2))
    set_scroll!(b, Offset(10, 20))
    set_scroll!(c, Offset(100, 200))

    # A node's own scroll shifts its CHILDREN, not itself.
    @test paint_offset(a) === ORIGIN
    @test paint_offset(b) === Offset(-1, -2)
    @test paint_offset(c) === Offset(-11, -22)
end

@testitem "scrolloffset: painted_region tracks the scroll" begin
    using DualUI

    p = Container()
    k = Container()
    mount!(p, k)
    r = Region(2, 3, 4, 5)
    node(k).layout = LayoutBox(r, r, r, r)

    @test painted_region(k) === r === region(k)
    set_scroll!(p, Offset(1, 2))
    @test region(k) === r                # layout is UNTOUCHED by scroll
    @test painted_region(k) === Region(1, 1, 4, 5)
    @test painted_region(p) === region(p)
end

@testitem "scrolloffset: the 14-arg positional WidgetNode constructs" begin
    using DualUI

    # `test_paint.jl` and `css_tests.jl` build nodes positionally in the
    # pre-scroll 14-argument shape, and both are frozen: the compat
    # constructor is what keeps them compiling.
    n = WidgetNode(:x, Set{Symbol}([:a]), :T, nothing, Widget[],
                   STYLE_NONE, BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                   LAYOUT_BOX_EMPTY, DIRTY_ALL, true, false, nothing)
    @test n isa WidgetNode
    @test n.scroll === ORIGIN
    @test n.id === :x
    @test n.classes == Set([:a])
    @test n.type_name === :T
    @test n.layout === LAYOUT_BOX_EMPTY
    @test n.dirty === DIRTY_ALL
    @test n.visible
    @test !n.focusable
    @test n.app === nothing

    # The 15-argument form names the field explicitly.
    m = WidgetNode(:y, Set{Symbol}(), :T, nothing, Widget[],
                   STYLE_NONE, BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                   LAYOUT_BOX_EMPTY, Offset(4, 5), DIRTY_ALL, true,
                   false, nothing)
    @test m.scroll === Offset(4, 5)
end

# --------------------------------------------------------------------
# The reveal hook: the core knows a node MAY reveal a descendant, and
# nothing whatever about how.
# --------------------------------------------------------------------

@testitem "scrolloffset: reveal! visits ancestors nearest-first" begin
    using DualUI

    mutable struct RV <: DualUI.Widget
        node::DualUI.WidgetNode
        log::Vector{Symbol}
    end
    DualUI.reveal_child!(w::RV, d::DualUI.Widget)::Nothing =
        (push!(w.log, id(w)); nothing)

    log = Symbol[]
    outer = RV(WidgetNode(; id = :outer, type_name = :RV), log)
    mid = RV(WidgetNode(; id = :mid, type_name = :RV), log)
    leaf = Container(; id = :leaf)
    mount!(outer, mid)
    mount!(mid, leaf)

    @test reveal!(leaf) === nothing
    # Nearest first: an inner pane must finish moving before an outer
    # one measures where `leaf` ended up.
    @test log == [:mid, :outer]

    # The default hook is a no-op, and a root has nothing to ask.
    empty!(log)
    @test reveal_child!(Container(), leaf) === nothing
    @test reveal!(outer) === nothing
    @test isempty(log)
end

@testitem "scrolloffset: on_focus! calls reveal! by default" begin
    using DualUI

    mutable struct FR <: DualUI.Widget
        node::DualUI.WidgetNode
        log::Vector{Symbol}
    end
    DualUI.reveal_child!(w::FR, d::DualUI.Widget)::Nothing =
        (push!(w.log, id(w)); nothing)

    log = Symbol[]
    pane = FR(WidgetNode(; id = :pane, type_name = :FR), log)
    leaf = Button("go", b -> nothing)
    mount!(pane, leaf)

    # TAB-ing to a widget inside a pane scrolls it into view with no
    # wiring at the call site and no `isa Scrollpane` in the core.
    @test on_focus!(leaf) === nothing
    @test log == [:pane]
end
