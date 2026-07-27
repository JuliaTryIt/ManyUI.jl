# layout_tests.jl -- U2 (CSS box model + flex), E1 (minimal relayout),
# E4 (full reflow on resize). Written BEFORE src/layout.jl per CLAUDE.md.

@testitem "layout: flex_distribute sums exactly to available" begin
    using ManyUI
    g3 = Float32[1, 1, 1]
    s3 = Float32[1, 1, 1]
    r = flex_distribute([0, 0, 0], g3, s3, 10)
    @test sum(r) == 10
    @test r == [4, 3, 3]
    r = flex_distribute([1, 1, 1], g3, s3, 100)
    @test sum(r) == 100
    @test r == [34, 33, 33]
    # A run of awkward totals: never a lost or gained column.
    for avail in 0:97
        rr = flex_distribute([0, 0, 0, 0, 0, 0, 0],
                             Float32[1, 1, 1, 1, 1, 1, 1],
                             Float32[1, 1, 1, 1, 1, 1, 1], avail)
        @test sum(rr) == avail
    end
end

@testitem "layout: flex_distribute largest remainder first" begin
    using ManyUI
    r = flex_distribute([0, 0, 0], Float32[1, 2, 3], Float32[1, 1, 1], 10)
    # exact shares 1.667 / 3.333 / 5.0 -> floors 1/3/5 = 9, the single
    # leftover cell goes to the LARGEST remainder (index 1), not to the
    # last item.
    @test r == [2, 3, 5]
    @test sum(r) == 10
    # The discriminating case: the largest remainder is at the LAST
    # index, so handing leftovers out in index order would give
    # [6, 3, 1] instead. Weights descend; remainders 0 / .333 / .667.
    r = flex_distribute([0, 0, 0], Float32[3, 2, 1], Float32[1, 1, 1], 10)
    @test r == [5, 3, 2]
    @test sum(r) == 10
    # Two leftovers, both owed to the two highest remainders (3 and 4),
    # not to the first two items.
    r = flex_distribute([0, 0, 0, 0], Float32[4, 4, 1, 1],
                        Float32[1, 1, 1, 1], 12)
    # exact 4.8 / 4.8 / 1.2 / 1.2 -> floors 4/4/1/1 = 10, remainders
    # .8/.8/.2/.2 -> the two cells go to indices 1 and 2.
    @test r == [5, 5, 1, 1]
    @test sum(r) == 12
end

@testitem "layout: flex_distribute ties go to lower index" begin
    using ManyUI
    @test flex_distribute([0, 0], Float32[1, 1], Float32[1, 1], 5) ==
          [3, 2]
    @test flex_distribute([0, 0, 0, 0], Float32[1, 1, 1, 1],
                          Float32[1, 1, 1, 1], 6) == [2, 2, 1, 1]
end

@testitem "layout: flex_distribute shrinks on overflow" begin
    using ManyUI
    z = Float32[0, 0]
    @test flex_distribute([10, 10], z, Float32[1, 1], 10) == [5, 5]
    # Shrink is weighted by shrink factor * base size (CSS scaled
    # shrink), and the leftover still lands largest-remainder-first.
    r = flex_distribute([10, 10], z, Float32[3, 1], 10)
    @test r == [2, 8]
    @test sum(r) == 10
    # Nobody can shrink: sizes are preserved, paint clips the overflow.
    @test flex_distribute([10, 10], z, Float32[0, 0], 5) == [10, 10]
    # A shrink share larger than the item freezes it at zero, never
    # negative.
    r = flex_distribute([10, 10], z, Float32[10, 0], 5)
    @test all(>=(0), r)
    @test r[1] == 0
end

@testitem "layout: flex_distribute is pure" begin
    using ManyUI
    base = [10, 20]
    g = Float32[1, 1]
    s = Float32[1, 1]
    flex_distribute(base, g, s, 100)
    @test base == [10, 20]
    @test g == Float32[1, 1]
    @test s == Float32[1, 1]
    @test flex_distribute(Int[], Float32[], Float32[], 10) == Int[]
end

@testitem "layout: justify_offsets for all six modes" begin
    using ManyUI
    sizes = [2, 2]
    # available 10, content 4, gap 0 -> free 6
    @test justify_offsets(sizes, Justify.START, 0, 10) == [0, 2]
    @test justify_offsets(sizes, Justify.CENTER, 0, 10) == [3, 5]
    @test justify_offsets(sizes, Justify.END, 0, 10) == [6, 8]
    @test justify_offsets(sizes, Justify.SPACE_BETWEEN, 0, 10) == [0, 8]
    @test justify_offsets(sizes, Justify.SPACE_AROUND, 0, 10) == [2, 7]
    @test justify_offsets(sizes, Justify.SPACE_EVENLY, 0, 10) == [2, 6]
    # gap is consumed before free space is measured
    @test justify_offsets(sizes, Justify.START, 3, 10) == [0, 5]
    # single item degenerates correctly
    @test justify_offsets([2], Justify.SPACE_BETWEEN, 0, 10) == [0]
    @test justify_offsets([2], Justify.SPACE_EVENLY, 0, 10) == [4]
    @test justify_offsets(Int[], Justify.CENTER, 0, 10) == Int[]
end

@testitem "layout: justify_offsets degrades to START on overflow" begin
    using ManyUI
    # free space is negative; every mode clamps it to zero so no item is
    # ever placed at a negative offset.
    for j in (Justify.START, Justify.CENTER, Justify.END,
              Justify.SPACE_BETWEEN, Justify.SPACE_AROUND,
              Justify.SPACE_EVENLY)
        @test justify_offsets([8, 8], j, 0, 10) == [0, 8]
    end
end

@testitem "layout: cross_align STRETCH fills" begin
    using ManyUI
    @test cross_align(3, Align.STRETCH, 10) == (0, 10)
    @test cross_align(0, Align.STRETCH, 24) == (0, 24)
end

@testitem "layout: cross_align START CENTER END" begin
    using ManyUI
    @test cross_align(3, Align.START, 10) == (0, 3)
    @test cross_align(3, Align.CENTER, 10) == (3, 3)
    @test cross_align(3, Align.END, 10) == (7, 3)
    # oversized item is never given a negative offset
    @test cross_align(12, Align.CENTER, 10) == (0, 12)
    @test cross_align(12, Align.END, 10) == (0, 12)
end

@testitem "layout: box model four regions nest" begin
    using ManyUI
    mutable struct NestBox <: Widget
        node::WidgetNode
    end
    w = NestBox(WidgetNode(; type_name = :NestBox))
    node(w).box = BoxStyle(; margin = Spacing(1, 2, 3, 4),
                             border = Border(BorderKind.SOLID,
                                             STYLE_NONE),
                             padding = Spacing(2, 1, 1, 2))
    lm = compute_layout(w, Region(1, 1, 20, 10))
    lb = lm[w]
    @test lb.margin_box == Region(1, 1, 20, 10)
    @test lb.border_box == Region(5, 2, 14, 6)
    @test lb.padding_box == Region(6, 3, 12, 4)
    @test lb.content == Region(8, 5, 9, 1)
    # U2: the four boxes nest, outermost first.
    @test issubset(lb.content, lb.padding_box)
    @test issubset(lb.padding_box, lb.border_box)
    @test issubset(lb.border_box, lb.margin_box)
end

@testitem "layout: margin border padding shrink content on 4 sides" begin
    using ManyUI
    mutable struct SideBox <: Widget
        node::WidgetNode
    end
    mk(bs) = (w = SideBox(WidgetNode(; type_name = :SideBox));
              node(w).box = bs; w)
    outer = Region(1, 1, 30, 20)
    plain = mk(BoxStyle())
    base = compute_layout(plain, outer)[plain].content
    @test base == outer
    # margin only: 2 top, 3 right, 4 bottom, 5 left
    w1 = mk(BoxStyle(; margin = Spacing(2, 3, 4, 5)))
    c1 = compute_layout(w1, outer)[w1].content
    @test c1 == Region(1 + 5, 1 + 2, 30 - 5 - 3, 20 - 2 - 4)
    # border only: exactly one cell on every side
    w2 = mk(BoxStyle(; border = Border(BorderKind.DOUBLE, STYLE_NONE)))
    c2 = compute_layout(w2, outer)[w2].content
    @test c2 == Region(2, 2, 28, 18)
    # padding only
    w3 = mk(BoxStyle(; padding = Spacing(1, 2, 3, 4)))
    c3 = compute_layout(w3, outer)[w3].content
    @test c3 == Region(1 + 4, 1 + 1, 30 - 4 - 2, 20 - 1 - 3)
    # all three stack additively on each of the four sides
    w4 = mk(BoxStyle(; margin = Spacing(2, 3, 4, 5),
                       border = Border(BorderKind.SOLID, STYLE_NONE),
                       padding = Spacing(1, 2, 3, 4)))
    c4 = compute_layout(w4, outer)[w4].content
    @test c4 == Region(1 + 5 + 1 + 4, 1 + 2 + 1 + 1,
                       30 - (5 + 1 + 4) - (3 + 1 + 2),
                       20 - (2 + 1 + 1) - (4 + 1 + 3))
    # underflow degrades to an empty region, never to negative extents
    w5 = mk(BoxStyle(; padding = Spacing(50)))
    c5 = compute_layout(w5, outer)[w5].content
    @test isempty(c5)
    @test c5.width >= 0 && c5.height >= 0
end

@testitem "layout: compute_layout is pure" begin
    using ManyUI
    mutable struct PureBox <: Widget
        node::WidgetNode
    end
    root = PureBox(WidgetNode(; type_name = :PureBox))
    kid = PureBox(WidgetNode(; type_name = :PureBox))
    mount!(root, kid)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(kid).box = BoxStyle(; width = fr(1))
    before = [(node(w).layout, node(w).dirty) for w in (root, kid)]
    lm = compute_layout(root, Region(1, 1, 40, 10))
    after = [(node(w).layout, node(w).dirty) for w in (root, kid)]
    @test before == after
    @test node(root).layout === LAYOUT_BOX_EMPTY
    @test node(kid).layout === LAYOUT_BOX_EMPTY
    @test lm isa LayoutMap
    @test haskey(lm, root) && haskey(lm, kid)
    # calling twice yields the same answer -- no hidden state
    lm2 = compute_layout(root, Region(1, 1, 40, 10))
    @test lm2[root] === lm[root]
    @test lm2[kid] === lm[kid]
end

@testitem "layout: compute_layout omits Display.NONE subtrees" begin
    using ManyUI
    mutable struct NoneBox <: Widget
        node::WidgetNode
    end
    nb() = NoneBox(WidgetNode(; type_name = :NoneBox))
    root, a, b, bkid = nb(), nb(), nb(), nb()
    mount!(root, a)
    mount!(root, b)
    mount!(b, bkid)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = fr(1))
    node(b).box = BoxStyle(; display = Display.NONE, width = fr(1))
    lm = compute_layout(root, Region(1, 1, 40, 10))
    @test haskey(lm, root)
    @test haskey(lm, a)
    @test !haskey(lm, b)
    @test !haskey(lm, bkid)
    # b takes no main-axis space either: a gets the whole row
    @test lm[a].margin_box == Region(1, 1, 40, 10)
end

@testitem "layout: compute_layout omits invisible subtrees" begin
    using ManyUI
    mutable struct HidBox <: Widget
        node::WidgetNode
    end
    hb() = HidBox(WidgetNode(; type_name = :HidBox))
    root, a, b, bkid = hb(), hb(), hb(), hb()
    mount!(root, a)
    mount!(root, b)
    mount!(b, bkid)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = fr(1))
    node(b).box = BoxStyle(; width = fr(1))
    node(b).visible = false
    lm = compute_layout(root, Region(1, 1, 40, 10))
    @test haskey(lm, a)
    @test !haskey(lm, b)
    @test !haskey(lm, bkid)
    @test lm[a].margin_box == Region(1, 1, 40, 10)
end

@testitem "layout: percent resolves against parent content box" begin
    using ManyUI
    mutable struct PctBox <: Widget
        node::WidgetNode
    end
    pb() = PctBox(WidgetNode(; type_name = :PctBox))
    root, a = pb(), pb()
    mount!(root, a)
    # root margin box is 100 wide, but its CONTENT box is only 90.
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW,
                                padding = Spacing(0, 5, 0, 5))
    node(a).box = BoxStyle(; width = pct(50))
    lm = compute_layout(root, Region(1, 1, 100, 20))
    @test lm[root].content == Region(6, 1, 90, 20)
    # 50% of the CONTENT box (90) is 45, not 50% of the margin box.
    @test lm[a].margin_box == Region(6, 1, 45, 20)
    @test lm[a].margin_box.width != 50
end

@testitem "layout: AUTO calls measure" begin
    using ManyUI
    mutable struct MeasBox <: Widget
        node::WidgetNode
    end
    mutable struct MeasLeaf <: Widget
        node::WidgetNode
        w::Int
        h::Int
    end
    ManyUI.measure(l::MeasLeaf, ::Size) = Size(l.w, l.h)
    root = MeasBox(WidgetNode(; type_name = :MeasBox))
    leaf = MeasLeaf(WidgetNode(; type_name = :MeasLeaf), 7, 3)
    mount!(root, leaf)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW,
                                align = Align.START)
    node(leaf).box = BoxStyle()   # width AUTO, height AUTO
    lm = compute_layout(root, Region(1, 1, 40, 10))
    @test lm[leaf].margin_box == Region(1, 1, 7, 3)
    # measure feeds the OUTER box: overhead is added on top of it
    node(leaf).box = BoxStyle(; padding = Spacing(1))
    lm = compute_layout(root, Region(1, 1, 40, 10))
    @test lm[leaf].margin_box == Region(1, 1, 9, 5)
    @test lm[leaf].content == Region(2, 2, 7, 3)
end

@testitem "layout: fixed and fractional siblings fill the row exactly" begin
    using ManyUI
    mutable struct MixBox <: Widget
        node::WidgetNode
    end
    mb() = MixBox(WidgetNode(; type_name = :MixBox))
    root, a, b, c = mb(), mb(), mb(), mb()
    mount!(root, a)
    mount!(root, b)
    mount!(root, c)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = cells(20))
    node(b).box = BoxStyle(; width = fr(1))
    node(c).box = BoxStyle(; width = fr(3))
    lm = compute_layout(root, Region(1, 1, 80, 24))
    # 80 - 20 fixed = 60 free, split 1:3 -> 15 / 45
    @test lm[a].margin_box == Region(1, 1, 20, 24)
    @test lm[b].margin_box == Region(21, 1, 15, 24)
    @test lm[c].margin_box == Region(36, 1, 45, 24)
    # no lost column: the three margin boxes tile the row exactly
    @test right(lm[c].margin_box) == right(lm[root].content)
    total = lm[a].margin_box.width + lm[b].margin_box.width +
            lm[c].margin_box.width
    @test total == 80
end

@testitem "layout: fractional split never loses a column" begin
    using ManyUI
    mutable struct FrBox <: Widget
        node::WidgetNode
    end
    fb() = FrBox(WidgetNode(; type_name = :FrBox))
    for width in 1:60, n in 2:4
        root = fb()
        kids = [fb() for _ in 1:n]
        for k in kids
            mount!(root, k)
            node(k).box = BoxStyle(; width = fr(1))
        end
        node(root).box = BoxStyle(; display = Display.FLEX,
                                    direction = Direction.ROW)
        lm = compute_layout(root, Region(1, 1, width, 3))
        total = sum(lm[k].margin_box.width for k in kids)
        @test total == width
        # and they tile with no hole and no overlap
        x = 1
        for k in kids
            @test lm[k].margin_box.x == x
            x += lm[k].margin_box.width
        end
    end
end

@testitem "layout: grow distributes the residual by weight" begin
    using ManyUI
    mutable struct GrowBox <: Widget
        node::WidgetNode
    end
    gb() = GrowBox(WidgetNode(; type_name = :GrowBox))
    root, a, b = gb(), gb(), gb()
    mount!(root, a)
    mount!(root, b)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = cells(10), grow = 1f0)
    node(b).box = BoxStyle(; width = cells(10), grow = 3f0)
    lm = compute_layout(root, Region(1, 1, 100, 10))
    # 80 free, split 1:3 -> +20 / +60
    @test lm[a].margin_box == Region(1, 1, 30, 10)
    @test lm[b].margin_box == Region(31, 1, 70, 10)
end

@testitem "layout: min and max clamp the resolved size" begin
    using ManyUI
    mutable struct ClampBox <: Widget
        node::WidgetNode
    end
    cb() = ClampBox(WidgetNode(; type_name = :ClampBox))
    root, a, b = cb(), cb(), cb()
    mount!(root, a)
    mount!(root, b)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = cells(80), max_width = cells(30))
    node(b).box = BoxStyle(; width = cells(5), min_width = cells(20))
    lm = compute_layout(root, Region(1, 1, 100, 10))
    @test lm[a].margin_box == Region(1, 1, 30, 10)
    @test lm[b].margin_box == Region(31, 1, 20, 10)
    # max also caps a grow that would otherwise overshoot
    node(a).box = BoxStyle(; width = cells(10), grow = 1f0,
                             max_width = cells(25))
    node(b).box = BoxStyle(; width = cells(10), grow = 1f0)
    lm = compute_layout(root, Region(1, 1, 100, 10))
    @test lm[a].margin_box.width == 25
end

@testitem "layout: cross axis aligns and stretches" begin
    using ManyUI
    mutable struct CrossBox <: Widget
        node::WidgetNode
    end
    xb() = CrossBox(WidgetNode(; type_name = :CrossBox))
    for (al, want) in ((Align.START, Region(1, 1, 10, 4)),
                       (Align.CENTER, Region(1, 4, 10, 4)),
                       (Align.END, Region(1, 7, 10, 4)),
                       (Align.STRETCH, Region(1, 1, 10, 10)))
        root, a = xb(), xb()
        mount!(root, a)
        node(root).box = BoxStyle(; display = Display.FLEX,
                                    direction = Direction.ROW,
                                    align = al)
        node(a).box = BoxStyle(; width = cells(10),
                                 height = al === Align.STRETCH ?
                                          AUTO : cells(4))
        lm = compute_layout(root, Region(1, 1, 40, 10))
        @test lm[a].margin_box == want
    end
end

@testitem "layout: STRETCH does not override a definite cross size" begin
    using ManyUI
    mutable struct DefBox <: Widget
        node::WidgetNode
    end
    db() = DefBox(WidgetNode(; type_name = :DefBox))
    root, a = db(), db()
    mount!(root, a)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW,
                                align = Align.STRETCH)
    node(a).box = BoxStyle(; width = cells(10), height = cells(4))
    lm = compute_layout(root, Region(1, 1, 40, 10))
    @test lm[a].margin_box == Region(1, 1, 10, 4)
end

@testitem "layout: gap separates siblings without eating a column" begin
    using ManyUI
    mutable struct GapBox <: Widget
        node::WidgetNode
    end
    pb() = GapBox(WidgetNode(; type_name = :GapBox))
    root, a, b, c = pb(), pb(), pb(), pb()
    mount!(root, a)
    mount!(root, b)
    mount!(root, c)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW, gap = 2)
    for k in (a, b, c)
        node(k).box = BoxStyle(; width = fr(1))
    end
    lm = compute_layout(root, Region(1, 1, 20, 5))
    # 20 - 2 gaps * 2 = 16, split three ways -> 6/5/5
    @test lm[a].margin_box == Region(1, 1, 6, 5)
    @test lm[b].margin_box == Region(9, 1, 5, 5)
    @test lm[c].margin_box == Region(16, 1, 5, 5)
    @test right(lm[c].margin_box) == 20
end

@testitem "layout: COLUMN is the main axis for BLOCK display" begin
    using ManyUI
    mutable struct ColBox <: Widget
        node::WidgetNode
    end
    cb() = ColBox(WidgetNode(; type_name = :ColBox))
    root, a, b = cb(), cb(), cb()
    mount!(root, a)
    mount!(root, b)
    node(root).box = BoxStyle()   # BLOCK == FLEX/COLUMN/STRETCH/grow 0
    node(a).box = BoxStyle(; height = cells(3))
    node(b).box = BoxStyle(; height = fr(1))
    lm = compute_layout(root, Region(1, 1, 20, 10))
    @test lm[a].margin_box == Region(1, 1, 20, 3)
    @test lm[b].margin_box == Region(1, 4, 20, 7)
    @test bottom(lm[b].margin_box) == 10
end

@testitem "layout: reverse direction mirrors the main axis" begin
    using ManyUI
    mutable struct RevBox <: Widget
        node::WidgetNode
    end
    rb() = RevBox(WidgetNode(; type_name = :RevBox))
    root, a, b = rb(), rb(), rb()
    mount!(root, a)
    mount!(root, b)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW_REVERSE)
    node(a).box = BoxStyle(; width = cells(10))
    node(b).box = BoxStyle(; width = cells(30))
    lm = compute_layout(root, Region(1, 1, 40, 5))
    # first child sits at the far end
    @test lm[a].margin_box == Region(31, 1, 10, 5)
    @test lm[b].margin_box == Region(1, 1, 30, 5)
end

@testitem "layout: nested three levels deep computes exact regions" begin
    using ManyUI
    mutable struct DeepBox <: Widget
        node::WidgetNode
    end
    dbx() = DeepBox(WidgetNode(; type_name = :DeepBox))
    root, a, b, c, d, e = dbx(), dbx(), dbx(), dbx(), dbx(), dbx()
    mount!(root, a)
    mount!(root, b)
    mount!(root, c)
    mount!(b, d)
    mount!(b, e)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = cells(20))
    node(b).box = BoxStyle(; display = Display.FLEX,
                             direction = Direction.COLUMN,
                             width = fr(1),
                             border = Border(BorderKind.SOLID,
                                             STYLE_NONE),
                             padding = Spacing(1))
    node(c).box = BoxStyle(; width = fr(3))
    node(d).box = BoxStyle(; height = cells(5))
    node(e).box = BoxStyle(; height = fr(1))
    lm = compute_layout(root, Region(1, 1, 80, 24))
    # level 1: b's overhead (border 1 + padding 1 per side = 4) is
    # fixed, so free = 80 - 20 - 4 = 56, split 1:3 -> 14 / 42.
    @test lm[a].margin_box == Region(1, 1, 20, 24)
    @test lm[b].margin_box == Region(21, 1, 18, 24)
    @test lm[c].margin_box == Region(39, 1, 42, 24)
    @test right(lm[c].margin_box) == 80
    # level 2: b's own four boxes
    @test lm[b].border_box == Region(21, 1, 18, 24)
    @test lm[b].padding_box == Region(22, 2, 16, 22)
    @test lm[b].content == Region(23, 3, 14, 20)
    # level 3: d and e tile b's CONTENT box, not its border box
    @test lm[d].margin_box == Region(23, 3, 14, 5)
    @test lm[e].margin_box == Region(23, 8, 14, 15)
    @test bottom(lm[e].margin_box) == bottom(lm[b].content)
    @test issubset(lm[d].margin_box, lm[b].content)
    @test issubset(lm[e].margin_box, lm[b].content)
end

@testitem "layout: overflow leaves regions unclipped" begin
    using ManyUI
    mutable struct OvBox <: Widget
        node::WidgetNode
    end
    ob() = OvBox(WidgetNode(; type_name = :OvBox))
    for ov in (Overflow.HIDDEN, Overflow.VISIBLE, Overflow.SCROLL)
        root, a = ob(), ob()
        mount!(root, a)
        node(root).box = BoxStyle(; display = Display.FLEX,
                                    direction = Direction.ROW,
                                    overflow_x = ov, overflow_y = ov)
        node(a).box = BoxStyle(; width = cells(50), shrink = 0f0)
        lm = compute_layout(root, Region(1, 1, 20, 5))
        # layout reports true geometry; clipping is paint's job, so the
        # region is identical under every overflow policy.
        @test lm[a].margin_box == Region(1, 1, 50, 5)
    end
end

@testitem "layout: layout! is unconditional and full" begin
    using ManyUI
    mutable struct FullBox <: Widget
        node::WidgetNode
    end
    fb() = FullBox(WidgetNode(; type_name = :FullBox))
    root, a, b = fb(), fb(), fb()
    mount!(root, a)
    mount!(a, b)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; display = Display.FLEX,
                             direction = Direction.ROW, width = fr(1))
    node(b).box = BoxStyle(; width = fr(1))
    # a demonstrably CLEAN tree still gets fully recomputed: E4 says
    # layout! never consults dirty flags.
    layout!(root, Region(1, 1, 40, 10))
    for w in (root, a, b)
        clean!(w)
        @test !is_dirty(w)
    end
    layout!(root, Region(1, 1, 60, 10))
    @test node(root).layout.margin_box == Region(1, 1, 60, 10)
    @test node(a).layout.margin_box == Region(1, 1, 60, 10)
    @test node(b).layout.margin_box == Region(1, 1, 60, 10)
    # a real geometry change repaints
    @test is_dirty(b, Dirty.PAINT)
end

@testitem "layout: resize reflows the entire tree" begin
    using ManyUI
    mutable struct RszBox <: Widget
        node::WidgetNode
    end
    rb() = RszBox(WidgetNode(; type_name = :RszBox))
    root, a, b, c, d, e = rb(), rb(), rb(), rb(), rb(), rb()
    mount!(root, a)
    mount!(root, b)
    mount!(root, c)
    mount!(b, d)
    mount!(b, e)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = cells(20))
    node(b).box = BoxStyle(; display = Display.FLEX,
                             direction = Direction.COLUMN,
                             width = fr(1),
                             border = Border(BorderKind.SOLID,
                                             STYLE_NONE),
                             padding = Spacing(1))
    node(c).box = BoxStyle(; width = fr(3))
    node(d).box = BoxStyle(; height = cells(5))
    node(e).box = BoxStyle(; height = fr(1))
    layout!(root, Region(1, 1, 80, 24))
    @test node(e).layout.margin_box == Region(23, 8, 14, 15)
    # E4 / EARS 2.2: a resize recomputes the bounding boxes of the
    # ENTIRE tree, three levels down, with no dirty flag set anywhere.
    for w in (root, a, b, c, d, e)
        clean!(w)
    end
    layout!(root, Region(1, 1, 40, 12))
    @test node(root).layout.margin_box == Region(1, 1, 40, 12)
    @test node(a).layout.margin_box == Region(1, 1, 20, 12)
    @test node(b).layout.margin_box == Region(21, 1, 8, 12)
    @test node(c).layout.margin_box == Region(29, 1, 12, 12)
    @test node(b).layout.content == Region(23, 3, 4, 8)
    @test node(d).layout.margin_box == Region(23, 3, 4, 5)
    @test node(e).layout.margin_box == Region(23, 8, 4, 3)
    @test right(node(c).layout.margin_box) == 40
    @test bottom(node(e).layout.margin_box) == bottom(node(b).layout.content)
    # every node that actually moved is flagged for repaint
    for w in (root, a, b, c, d, e)
        @test is_dirty(w, Dirty.PAINT)
        @test !is_dirty(w, Dirty.LAYOUT)
    end
end

@testitem "layout: apply_layout! writes boxes and clears LAYOUT" begin
    using ManyUI
    mutable struct ApplyBox <: Widget
        node::WidgetNode
    end
    ab() = ApplyBox(WidgetNode(; type_name = :ApplyBox))
    root, a = ab(), ab()
    mount!(root, a)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = fr(1))
    lm = compute_layout(root, Region(1, 1, 30, 6))
    mark!(root, Dirty.LAYOUT)
    apply_layout!(lm)
    for w in (root, a)
        @test node(w).layout === lm[w]
        @test !is_dirty(w, Dirty.LAYOUT)
        @test !has_dirty(node(w).dirty, Dirty.SUBTREE)
        @test is_dirty(w, Dirty.PAINT)   # geometry changed
    end
    # a second identical apply is a no-op for PAINT
    for w in (root, a)
        clean!(w)
    end
    apply_layout!(compute_layout(root, Region(1, 1, 30, 6)))
    for w in (root, a)
        @test !is_dirty(w, Dirty.PAINT)
    end
end

@testitem "layout: relayout! is a no-op on a clean tree" begin
    using ManyUI
    mutable struct CleanBox <: Widget
        node::WidgetNode
    end
    cb() = CleanBox(WidgetNode(; type_name = :CleanBox))
    root, a = cb(), cb()
    mount!(root, a)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = fr(1))
    layout!(root, Region(1, 1, 40, 10))
    for w in (root, a)
        clean!(w)
    end
    before = [node(w).layout for w in (root, a)]
    # a viewport it has never seen: relayout! must NOT use it, because
    # the tree is clean.
    relayout!(root, Region(1, 1, 999, 999))
    @test [node(w).layout for w in (root, a)] == before
    @test !is_dirty(root) && !is_dirty(a)
end

@testitem "layout: relayout! touches only the dirty subtree" begin
    using ManyUI
    mutable struct SubBox <: Widget
        node::WidgetNode
    end
    sb() = SubBox(WidgetNode(; type_name = :SubBox))
    root, a, b, d, e = sb(), sb(), sb(), sb(), sb()
    mount!(root, a)
    mount!(root, b)
    mount!(b, d)
    mount!(b, e)
    # root is DEFINITE on the main axis, so `escalate_auto!` stops
    # there and the dirt inside b cannot escape upward.
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW,
                                width = cells(40), height = cells(10))
    node(a).box = BoxStyle(; width = cells(20))
    node(b).box = BoxStyle(; display = Display.FLEX,
                             direction = Direction.COLUMN,
                             width = cells(20))
    node(d).box = BoxStyle(; height = cells(4))
    node(e).box = BoxStyle(; height = fr(1))
    layout!(root, Region(1, 1, 40, 10))
    for w in (root, a, b, d, e)
        clean!(w)
    end
    a_before = node(a).layout
    root_before = node(root).layout
    # change d's height and mark b's subtree dirty
    node(d).box = BoxStyle(; height = cells(6))
    mark!(b, Dirty.LAYOUT)
    @test dirty_root(root) === b
    # A viewport the tree has NEVER seen: since the dirty root is b,
    # relayout! must anchor on b's EXISTING margin box and ignore the
    # viewport entirely. A relayout! that quietly fell back to a full
    # layout! would drag root and a to 999x999 and fail here.
    relayout!(root, Region(1, 1, 999, 999))
    # the dirty subtree reflowed
    @test node(d).layout.margin_box == Region(21, 1, 20, 6)
    @test node(e).layout.margin_box == Region(21, 7, 20, 4)
    # the clean sibling and the root are untouched
    @test node(a).layout === a_before
    @test node(root).layout === root_before
    @test !is_dirty(a)
    # E1: b's subtree is layout-clean again
    @test !is_dirty(b, Dirty.LAYOUT)
    @test !is_dirty(d, Dirty.LAYOUT)
    @test !is_dirty(e, Dirty.LAYOUT)
end

@testitem "layout: relayout! falls back to layout! at the root" begin
    using ManyUI
    mutable struct RootBox <: Widget
        node::WidgetNode
    end
    rb() = RootBox(WidgetNode(; type_name = :RootBox))
    root, a = rb(), rb()
    mount!(root, a)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW)
    node(a).box = BoxStyle(; width = fr(1))
    layout!(root, Region(1, 1, 40, 10))
    for w in (root, a)
        clean!(w)
    end
    mark!(root, Dirty.LAYOUT)
    @test dirty_root(root) === root
    relayout!(root, Region(1, 1, 64, 8))
    # the whole tree took the new viewport
    @test node(root).layout.margin_box == Region(1, 1, 64, 8)
    @test node(a).layout.margin_box == Region(1, 1, 64, 8)
    @test !is_dirty(root, Dirty.LAYOUT)
    @test !is_dirty(a, Dirty.LAYOUT)
end

@testitem "layout: measure defaults to the union of children" begin
    using ManyUI
    mutable struct UnionBox <: Widget
        node::WidgetNode
    end
    mutable struct UnionLeaf <: Widget
        node::WidgetNode
        w::Int
        h::Int
    end
    ManyUI.measure(l::UnionLeaf, ::Size) = Size(l.w, l.h)
    ub() = UnionBox(WidgetNode(; type_name = :UnionBox))
    # a leaf with no children measures zero
    @test measure(ub(), Size(40, 10)) == Size(0, 0)
    root = ub()
    l1 = UnionLeaf(WidgetNode(; type_name = :UnionLeaf), 4, 2)
    l2 = UnionLeaf(WidgetNode(; type_name = :UnionLeaf), 6, 5)
    mount!(root, l1)
    mount!(root, l2)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.ROW, gap = 1)
    # ROW: main is the sum plus gaps, cross is the max
    @test measure(root, Size(40, 10)) == Size(4 + 1 + 6, 5)
    node(root).box = BoxStyle(; display = Display.FLEX,
                                direction = Direction.COLUMN, gap = 1)
    @test measure(root, Size(40, 10)) == Size(6, 2 + 1 + 5)
end
