# test_paint.jl -- tests for src/paint.jl (the compositor / render pass).
# Test item names follow the contract, section 4.
#
# U1: the tree paints itself. E2: into a plain Buffer, which is exactly
# what `diff` consumes. 2.1: no Driver, no terminal and no ANSI is named
# anywhere on this path.
#
# Every @testitem is self-contained: TestItemRunner 1.1.5 does not
# detect `@testsetup`, so the fixture is repeated rather than shared.
# The fixtures call the POSITIONAL constructors of `BoxStyle` and
# `WidgetNode`, because the keyword constructors are still
# `error("TODO")` stubs owned by boxmodel.jl and widget.jl; this keeps
# these tests a test of paint.jl alone.

# --------------------------------------------------------------------
# U1 -- the tree paints itself, and cannot paint anywhere else.
# --------------------------------------------------------------------

@testitem "paint: render! cannot paint outside its view" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox() = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                       Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                       AUTO, NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                       Overflow.HIDDEN, Overflow.HIDDEN, 0f0, 1f0)
    pnt(fn, lay) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                Widget[], STYLE_NONE, BOX_PATCH_NONE,
                                STYLE_NONE, mkbox(), lay, DIRTY_ALL,
                                true, false, nothing), fn)
    lay1(r) = LayoutBox(r, r, r, r)

    content = Region(3, 3, 4, 2)
    # Deliberately hostile: fills far outside the box on every side.
    root = pnt(b -> fill_region!(b, Region(-5, -5, 40, 40),
                                 Cell("X", STYLE_NONE)), lay1(content))
    buf = Buffer(10, 6)
    paint!(buf, root)

    for y in 1:6, x in 1:10
        want = Offset(x, y) in content ? "X" : " "
        @test String(buf[x, y].content) == want
    end

    # (1, 1) of the view IS the content-box origin, so a widget writing
    # at its own local (1, 1) lands on the box corner and nowhere else.
    origin_w = pnt(b -> set_cell!(b, 1, 1, "A", STYLE_NONE),
                   lay1(Region(4, 3, 3, 2)))
    b2 = Buffer(8, 5)
    paint!(b2, origin_w)
    @test String(b2[4, 3].content) == "A"
    @test count(c -> String(c.content) == "A", b2) == 1
end

@testitem "paint: children paint over parents" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox() = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                       Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                       AUTO, NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                       Overflow.VISIBLE, Overflow.VISIBLE, 0f0, 1f0)
    pnt(fn, lay) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                Widget[], STYLE_NONE, BOX_PATCH_NONE,
                                STYLE_NONE, mkbox(), lay, DIRTY_ALL,
                                true, false, nothing), fn)
    lay1(r) = LayoutBox(r, r, r, r)
    att!(p, c) = (push!(DualUI.node(p).children, c);
                  DualUI.node(c).parent = p; c)
    rows(b) = [join(String(b[x, y].content) for x in 1:size(b, 1))
               for y in 1:size(b, 2)]
    fillc(ch) = b -> fill_region!(b, buffer_region(b),
                                  Cell(ch, STYLE_NONE))

    root = pnt(fillc("P"), lay1(Region(1, 1, 8, 4)))
    kid = pnt(fillc("C"), lay1(Region(3, 2, 3, 2)))
    att!(root, kid)

    buf = Buffer(8, 4)
    paint!(buf, root)
    @test rows(buf) == ["PPPPPPPP",
                        "PPCCCPPP",
                        "PPCCCPPP",
                        "PPPPPPPP"]

    # Overlapping siblings: the LATER one wins. Paint order IS document
    # order -- there is no z-index in the model.
    root2 = pnt(_ -> nothing, lay1(Region(1, 1, 8, 3)))
    att!(root2, pnt(fillc("1"), lay1(Region(1, 1, 5, 3))))
    att!(root2, pnt(fillc("2"), lay1(Region(4, 1, 5, 3))))
    b2 = Buffer(8, 3)
    paint!(b2, root2)
    @test rows(b2) == ["11122222", "11122222", "11122222"]

    # Pre-order: a parent is painted before (under) its children.
    seen = Symbol[]
    r = Region(1, 1, 4, 2)
    root3 = pnt(_ -> push!(seen, :root), lay1(r))
    a = pnt(_ -> push!(seen, :a), lay1(r))
    att!(root3, a)
    att!(a, pnt(_ -> push!(seen, :gc), lay1(r)))
    att!(root3, pnt(_ -> push!(seen, :b), lay1(r)))
    paint!(Buffer(4, 2), root3)
    @test seen == [:root, :a, :gc, :b]
end

# --------------------------------------------------------------------
# Clipping -- strict, at every edge, and composing down the tree.
# --------------------------------------------------------------------

@testitem "paint: overflow HIDDEN clips children to content" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox(ox, oy) = BoxStyle(Display.BLOCK, Direction.COLUMN,
                             Justify.START, Align.STRETCH, AUTO, AUTO,
                             AUTO, AUTO, AUTO, AUTO, NO_SPACING,
                             NO_SPACING, BORDER_NONE, 0, ox, oy,
                             0f0, 1f0)
    pnt(fn, lay, bx) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                    Widget[], STYLE_NONE,
                                    BOX_PATCH_NONE, STYLE_NONE, bx,
                                    lay, DIRTY_ALL, true, false,
                                    nothing), fn)
    hid() = mkbox(Overflow.HIDDEN, Overflow.HIDDEN)
    lay1(r) = LayoutBox(r, r, r, r)
    lay2(o, c) = LayoutBox(o, o, o, c)
    att!(p, c) = (push!(DualUI.node(p).children, c);
                  DualUI.node(c).parent = p; c)

    content = Region(2, 2, 4, 3)
    root = pnt(_ -> nothing, lay2(Region(1, 1, 8, 6), content), hid())
    # The child's own box is far bigger than the parent's content box.
    att!(root, pnt(b -> fill_region!(b, buffer_region(b),
                                     Cell("C", STYLE_NONE)),
                   lay1(Region(1, 1, 8, 6)), hid()))

    buf = Buffer(8, 6)
    paint!(buf, root)
    for y in 1:6, x in 1:8
        want = Offset(x, y) in content ? "C" : " "
        @test String(buf[x, y].content) == want
    end

    # SCROLL clips exactly like HIDDEN.
    root2 = pnt(_ -> nothing, lay2(Region(1, 1, 8, 6), content),
                mkbox(Overflow.SCROLL, Overflow.SCROLL))
    att!(root2, pnt(b -> fill_region!(b, buffer_region(b),
                                      Cell("S", STYLE_NONE)),
                    lay1(Region(1, 1, 8, 6)), hid()))
    b2 = Buffer(8, 6)
    paint!(b2, root2)
    for y in 1:6, x in 1:8
        want = Offset(x, y) in content ? "S" : " "
        @test String(b2[x, y].content) == want
    end
end

@testitem "paint: overflow VISIBLE clips to the inherited clip" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox(ox, oy) = BoxStyle(Display.BLOCK, Direction.COLUMN,
                             Justify.START, Align.STRETCH, AUTO, AUTO,
                             AUTO, AUTO, AUTO, AUTO, NO_SPACING,
                             NO_SPACING, BORDER_NONE, 0, ox, oy,
                             0f0, 1f0)
    pnt(fn, lay, bx) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                    Widget[], STYLE_NONE,
                                    BOX_PATCH_NONE, STYLE_NONE, bx,
                                    lay, DIRTY_ALL, true, false,
                                    nothing), fn)
    hid() = mkbox(Overflow.HIDDEN, Overflow.HIDDEN)
    lay1(r) = LayoutBox(r, r, r, r)
    lay2(o, c) = LayoutBox(o, o, o, c)
    att!(p, c) = (push!(DualUI.node(p).children, c);
                  DualUI.node(c).parent = p; c)
    rows(b) = [join(String(b[x, y].content) for x in 1:size(b, 1))
               for y in 1:size(b, 2)]
    fillc(ch) = b -> fill_region!(b, buffer_region(b),
                                  Cell(ch, STYLE_NONE))

    root = pnt(_ -> nothing, lay2(Region(1, 1, 8, 4), Region(2, 2, 3, 2)),
               mkbox(Overflow.VISIBLE, Overflow.VISIBLE))
    att!(root, pnt(fillc("C"), lay1(Region(1, 1, 8, 4)), hid()))

    buf = Buffer(8, 4)
    paint!(buf, root)
    # VISIBLE escapes the content box, but NEVER the inherited clip --
    # here the buffer itself.
    @test rows(buf) == ["CCCCCCCC", "CCCCCCCC", "CCCCCCCC", "CCCCCCCC"]

    # Overflow is per axis: VISIBLE on x, HIDDEN on y.
    root2 = pnt(_ -> nothing,
                lay2(Region(1, 1, 8, 4), Region(2, 2, 3, 2)),
                mkbox(Overflow.VISIBLE, Overflow.HIDDEN))
    att!(root2, pnt(fillc("C"), lay1(Region(1, 1, 8, 4)), hid()))
    b2 = Buffer(8, 4)
    paint!(b2, root2)
    # x spans the whole buffer; y stays inside the content box (2:3).
    @test rows(b2) == ["        ", "CCCCCCCC", "CCCCCCCC", "        "]
end

@testitem "paint: clipping is strict at each edge" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox() = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                       Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                       AUTO, NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                       Overflow.HIDDEN, Overflow.HIDDEN, 0f0, 1f0)
    pnt(fn, lay) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                Widget[], STYLE_NONE, BOX_PATCH_NONE,
                                STYLE_NONE, mkbox(), lay, DIRTY_ALL,
                                true, false, nothing), fn)
    lay1(r) = LayoutBox(r, r, r, r)
    lay2(o, c) = LayoutBox(o, o, o, c)
    att!(p, c) = (push!(DualUI.node(p).children, c);
                  DualUI.node(c).parent = p; c)

    content = Region(3, 3, 4, 3)   # x 3:6, y 3:5, inside an 8x7 buffer
    # One child per edge, each overhanging exactly that edge.
    overs = [(:left, Region(1, 3, 4, 3)), (:right, Region(5, 3, 4, 3)),
             (:top, Region(3, 1, 4, 3)), (:bottom, Region(3, 4, 4, 3))]

    for (edge, cr) in overs
        root = pnt(_ -> nothing, lay2(Region(1, 1, 8, 7), content))
        att!(root, pnt(b -> fill_region!(b, buffer_region(b),
                                         Cell("C", STYLE_NONE)),
                       lay1(cr)))
        buf = Buffer(8, 7)
        paint!(buf, root)

        want = intersect(cr, content)
        @test !isempty(want)     # the case would otherwise be vacuous
        for y in 1:7, x in 1:8
            got = String(buf[x, y].content)
            @test (edge, got) == (edge, Offset(x, y) in want ? "C" : " ")
        end
    end

    # Clipping COMPOSES: each level intersects and can only narrow, so a
    # grandchild cannot escape its grandparent's content box.
    g_root = pnt(_ -> nothing,
                 lay2(Region(1, 1, 10, 6), Region(2, 2, 6, 4)))
    mid = pnt(_ -> nothing, lay2(Region(2, 2, 6, 4), Region(3, 3, 4, 2)))
    att!(g_root, mid)
    att!(mid, pnt(b -> fill_region!(b, Region(-9, -9, 40, 40),
                                    Cell("G", STYLE_NONE)),
                  lay1(Region(1, 1, 10, 6))))
    gb = Buffer(10, 6)
    paint!(gb, g_root)
    inner = Region(3, 3, 4, 2)
    for y in 1:6, x in 1:10
        @test String(gb[x, y].content) ==
              (Offset(x, y) in inner ? "G" : " ")
    end

    # An empty content box clips its children away entirely.
    e_root = pnt(_ -> nothing,
                 lay2(Region(1, 1, 6, 3), Region(3, 2, 0, 0)))
    att!(e_root, pnt(b -> fill_region!(b, Region(1, 1, 20, 20),
                                       Cell("C", STYLE_NONE)),
                     lay1(Region(1, 1, 6, 3))))
    eb = Buffer(6, 3)
    paint!(eb, e_root)
    @test all(c -> c == CELL_BLANK, eb)
end

# --------------------------------------------------------------------
# Skipping.
# --------------------------------------------------------------------

@testitem "paint: Display.NONE subtree is skipped" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox(disp) = BoxStyle(disp, Direction.COLUMN, Justify.START,
                           Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                           AUTO, NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                           Overflow.VISIBLE, Overflow.VISIBLE, 0f0, 1f0)
    pnt(fn, lay, disp) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                      Widget[], STYLE_NONE,
                                      BOX_PATCH_NONE, STYLE_NONE,
                                      mkbox(disp), lay, DIRTY_ALL, true,
                                      false, nothing), fn)
    lay1(r) = LayoutBox(r, r, r, r)
    att!(p, c) = (push!(DualUI.node(p).children, c);
                  DualUI.node(c).parent = p; c)
    fillc(ch) = b -> fill_region!(b, buffer_region(b),
                                  Cell(ch, STYLE_NONE))

    r = Region(1, 1, 6, 3)
    root = pnt(_ -> nothing, lay1(r), Display.BLOCK)
    gone = pnt(fillc("N"), lay1(r), Display.NONE)
    att!(root, gone)
    # A VISIBLE grandchild under a NONE parent must be skipped too:
    # the subtree is skipped ENTIRELY, not just the node.
    att!(gone, pnt(fillc("G"), lay1(r), Display.BLOCK))

    buf = Buffer(6, 3)
    paint!(buf, root)
    @test all(c -> c == CELL_BLANK, buf)

    # A NONE root paints nothing at all.
    nb = Buffer(6, 3)
    @test paint!(nb, pnt(fillc("R"), lay1(r), Display.NONE)) === nb
    @test all(c -> c == CELL_BLANK, nb)
end

@testitem "paint: invisible subtree is skipped" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox() = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                       Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                       AUTO, NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                       Overflow.VISIBLE, Overflow.VISIBLE, 0f0, 1f0)
    pnt(fn, lay, vis) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                     Widget[], STYLE_NONE,
                                     BOX_PATCH_NONE, STYLE_NONE,
                                     mkbox(), lay, DIRTY_ALL, vis,
                                     false, nothing), fn)
    lay1(r) = LayoutBox(r, r, r, r)
    att!(p, c) = (push!(DualUI.node(p).children, c);
                  DualUI.node(c).parent = p; c)
    fillc(ch) = b -> fill_region!(b, buffer_region(b),
                                  Cell(ch, STYLE_NONE))

    r = Region(1, 1, 6, 3)
    root = pnt(_ -> nothing, lay1(r), true)
    hidden = pnt(fillc("H"), lay1(r), false)
    att!(root, hidden)
    att!(hidden, pnt(fillc("G"), lay1(r), true))

    buf = Buffer(6, 3)
    paint!(buf, root)
    @test all(c -> c == CELL_BLANK, buf)

    # An invisible root paints nothing, and still returns its buffer.
    ib = Buffer(6, 3)
    @test paint!(ib, pnt(fillc("R"), lay1(r), false)) === ib
    @test all(c -> c == CELL_BLANK, ib)
end

# --------------------------------------------------------------------
# Background and border.
# --------------------------------------------------------------------

@testitem "paint: paint_border! draws only the perimeter" begin
    using DualUI

    buf = Buffer(6, 4)
    g = border_glyphs(BorderKind.SOLID)
    paint_border!(buf, Region(1, 1, 6, 4),
                  Border(BorderKind.SOLID, STYLE_NONE))

    # (tl, top, tr, right, br, bottom, bl, left), clockwise from
    # the top-left.
    @test String(buf[1, 1].content) == string(g[1])
    @test String(buf[6, 1].content) == string(g[3])
    @test String(buf[6, 4].content) == string(g[5])
    @test String(buf[1, 4].content) == string(g[7])
    for x in 2:5
        @test String(buf[x, 1].content) == string(g[2])
        @test String(buf[x, 4].content) == string(g[6])
    end
    for y in 2:3
        @test String(buf[1, y].content) == string(g[8])
        @test String(buf[6, y].content) == string(g[4])
    end
    # The interior is never touched.
    for y in 2:3, x in 2:5
        @test buf[x, y] == CELL_BLANK
    end

    # NONE is a no-op.
    nb = Buffer(4, 3)
    @test paint_border!(nb, Region(1, 1, 4, 3), BORDER_NONE) === nothing
    @test all(c -> c == CELL_BLANK, nb)

    # BLANK occupies its cells and shows nothing: the perimeter is
    # overwritten with spaces, the interior is left alone.
    bb = Buffer(4, 3)
    fill_region!(bb, Region(1, 1, 4, 3), Cell("k", STYLE_NONE))
    paint_border!(bb, Region(1, 1, 4, 3),
                  Border(BorderKind.BLANK, STYLE_NONE))
    rows(b) = [join(String(b[x, y].content) for x in 1:size(b, 1))
               for y in 1:size(b, 2)]
    @test rows(bb) == ["    ", " kk ", "    "]

    # The glyphs carry the border's own style.
    sb = Buffer(5, 3)
    st = Style(fg = rgb(255, 0, 0), bold = true)
    paint_border!(sb, Region(1, 1, 5, 3), Border(BorderKind.SOLID, st))
    @test sb[1, 1].style.fg == rgb(255, 0, 0)
    @test has(sb[3, 1].style, Attr.BOLD)

    # Bounds-clipped, never throws: out of bounds, empty, and oversized.
    cb = Buffer(4, 3)
    sol = Border(BorderKind.SOLID, STYLE_NONE)
    @test paint_border!(cb, Region(-20, -20, 5, 5), sol) === nothing
    @test paint_border!(cb, EMPTY_REGION, sol) === nothing
    @test paint_border!(cb, Region(2, 2, 40, 40), sol) === nothing
    @test size(cb) == (4, 3)
end

@testitem "paint: a border draws on the border box and clips kids" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox(bd) = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                         Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                         AUTO, NO_SPACING, NO_SPACING, bd, 0,
                         Overflow.HIDDEN, Overflow.HIDDEN, 0f0, 1f0)
    pnt(fn, lay, bd) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                    Widget[], STYLE_NONE,
                                    BOX_PATCH_NONE, STYLE_NONE,
                                    mkbox(bd), lay, DIRTY_ALL, true,
                                    false, nothing), fn)
    att!(p, c) = (push!(DualUI.node(p).children, c);
                  DualUI.node(c).parent = p; c)
    rows(b) = [join(String(b[x, y].content) for x in 1:size(b, 1))
               for y in 1:size(b, 2)]
    sol = Border(BorderKind.SOLID, STYLE_NONE)
    g = border_glyphs(BorderKind.SOLID)

    # The border sits on the perimeter of the BORDER box; the widget's
    # own render! is confined to the content box inside it.
    bbox = Region(1, 1, 5, 3)
    lb = LayoutBox(bbox, bbox, Region(2, 2, 3, 1), Region(2, 2, 3, 1))
    root = pnt(b -> fill_region!(b, buffer_region(b),
                                 Cell("i", STYLE_NONE)), lb, sol)
    buf = Buffer(5, 3)
    paint!(buf, root)
    @test rows(buf)[1] == string(g[1]) * string(g[2])^3 * string(g[3])
    @test rows(buf)[2] == string(g[8]) * "iii" * string(g[4])
    @test rows(buf)[3] == string(g[7]) * string(g[6])^3 * string(g[5])

    # A child is clipped to the parent's content box, so it can never
    # paint over its parent's frame.
    bbox2 = Region(1, 1, 6, 4)
    lb2 = LayoutBox(bbox2, bbox2, Region(2, 2, 4, 2), Region(2, 2, 4, 2))
    root2 = pnt(_ -> nothing, lb2, sol)
    att!(root2, pnt(b -> fill_region!(b, Region(1, 1, 20, 20),
                                      Cell("C", STYLE_NONE)),
                    LayoutBox(bbox2, bbox2, bbox2, bbox2), BORDER_NONE))
    b2 = Buffer(6, 4)
    paint!(b2, root2)
    @test rows(b2)[2] == string(g[8]) * "CCCC" * string(g[4])
    @test rows(b2)[3] == string(g[8]) * "CCCC" * string(g[4])
    @test String(b2[1, 1].content) == string(g[1])
    @test String(b2[1, 4].content) == string(g[7])
end

@testitem "paint: background fills the padding box when bg is set" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox() = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                       Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                       AUTO, NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                       Overflow.HIDDEN, Overflow.HIDDEN, 0f0, 1f0)
    pnt(fn, lay, st) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                    Widget[], STYLE_NONE,
                                    BOX_PATCH_NONE, st, mkbox(), lay,
                                    DIRTY_ALL, true, false, nothing), fn)
    rows(b) = [join(String(b[x, y].content) for x in 1:size(b, 1))
               for y in 1:size(b, 2)]

    # The fill covers the PADDING box -- not the margin box, and not
    # just the content box.
    pbox = Region(2, 2, 4, 2)
    lb = LayoutBox(Region(1, 1, 6, 4), Region(1, 1, 6, 4), pbox,
                   Region(3, 3, 2, 1))
    blue = Style(bg = rgb(0, 0, 255))
    buf = Buffer(6, 4)
    paint!(buf, pnt(_ -> nothing, lb, blue))

    for y in 1:4, x in 1:6
        if Offset(x, y) in pbox
            @test buf[x, y].style.bg == rgb(0, 0, 255)
            @test String(buf[x, y].content) == " "
        else
            @test buf[x, y] == CELL_BLANK
        end
    end

    # An UNSET bg is transparent, NOT "paint the default": whatever was
    # already in the buffer survives.
    r = Region(1, 1, 4, 2)
    b2 = Buffer(4, 2)
    fill_region!(b2, r, Cell("k", STYLE_NONE))
    paint!(b2, pnt(_ -> nothing, LayoutBox(r, r, r, r), STYLE_NONE))
    @test rows(b2) == ["kkkk", "kkkk"]
end

# --------------------------------------------------------------------
# 2.1 / 2.2 -- the seam the whole architecture rests on.
# --------------------------------------------------------------------

@testitem "paint: isolates app logic from the rendering target" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox() = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                       Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                       AUTO, NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                       Overflow.HIDDEN, Overflow.HIDDEN, 0f0, 1f0)
    pnt(fn, lay) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                Widget[], STYLE_NONE, BOX_PATCH_NONE,
                                STYLE_NONE, mkbox(), lay, DIRTY_ALL,
                                true, false, nothing), fn)
    rows(b) = [join(String(b[x, y].content) for x in 1:size(b, 1))
               for y in 1:size(b, 2)]

    # 2.1: the render pass takes a Widget and a Buffer and NOTHING
    # else. No Driver, no terminal, no ANSI, no colour depth -- so the
    # same tree paints identically no matter what the target will be.
    r = Region(1, 1, 6, 3)
    tree() = pnt(b -> write_text!(b, 1, 1, "hi", STYLE_NONE),
                 LayoutBox(r, r, r, r))

    a, c = Buffer(6, 3), Buffer(6, 3)
    paint!(a, tree())
    paint!(c, tree())
    @test rows(a) == rows(c)
    @test rows(a)[1] == "hi    "

    # The whole seam is these two argument types.
    m = only(methods(paint!))
    @test m.sig == Tuple{typeof(paint!),Buffer,Widget}
end

@testitem "paint: produces the frame buffer the diff consumes" begin
    using DualUI

    mutable struct P{F} <: DualUI.Widget
        node::DualUI.WidgetNode
        fn::F
    end
    DualUI.render!(w::P, b::AbstractMatrix{Cell})::Nothing =
        (w.fn(b); nothing)
    mkbox() = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                       Align.STRETCH, AUTO, AUTO, AUTO, AUTO, AUTO,
                       AUTO, NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                       Overflow.HIDDEN, Overflow.HIDDEN, 0f0, 1f0)
    pnt(fn, lay) = P(WidgetNode(:w, Set{Symbol}(), :P, nothing,
                                Widget[], STYLE_NONE, BOX_PATCH_NONE,
                                STYLE_NONE, mkbox(), lay, DIRTY_ALL,
                                true, false, nothing), fn)
    rows(b) = [join(String(b[x, y].content) for x in 1:size(b, 1))
               for y in 1:size(b, 2)]

    # 2.2: `diff(old::Buffer, new::Buffer)` consumes exactly what
    # `paint!` produces, and App paints the BACK buffer in place then
    # diffs it against the front -- so `paint!` must return that very
    # object, not a copy.
    r = Region(1, 1, 4, 2)
    buf = Buffer(4, 2)
    out = paint!(buf, pnt(b -> fill_region!(b, buffer_region(b),
                                            Cell("Z", STYLE_NONE)),
                          LayoutBox(r, r, r, r)))
    @test out isa Buffer
    @test out === buf
    @test rows(out) == ["ZZZZ", "ZZZZ"]

    # Painting the same tree twice into the same buffer is idempotent:
    # frame N+1 over frame N leaves nothing for the diff to find.
    again = paint!(out, pnt(b -> fill_region!(b, buffer_region(b),
                                              Cell("Z", STYLE_NONE)),
                            LayoutBox(r, r, r, r)))
    @test rows(again) == ["ZZZZ", "ZZZZ"]
end
