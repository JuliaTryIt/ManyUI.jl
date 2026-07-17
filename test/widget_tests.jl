# widget_tests.jl -- U1 (the tree) and E1 (dirty flagging).
#
# E1 is the requirement everyone hand-waves. The tests below assert the
# NEGATIVE half of it as hard as the positive half: a mutation at a
# mid-tree node must leave its siblings, its uncles and their subtrees
# with a literally zero dirty mask, and must leave its ancestors with
# the SUBTREE breadcrumb and nothing that counts as dirt.

@testitem "widget: fresh node defaults" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end

    w = TW(WidgetNode(; id = :w, type_name = :TW))
    @test @inferred(node(w)) isa WidgetNode
    @test id(w) === :w
    @test type_name(w) === :TW
    @test isempty(classes(w))
    @test isempty(children(w))
    @test parent(w) === nothing
    @test root_of(w) === w
    @test app(w) === nothing
    @test is_visible(w)
    @test !is_focusable(w)
    @test layout_of(w) === LAYOUT_BOX_EMPTY
    @test region(w) === EMPTY_REGION
    @test content_region(w) === EMPTY_REGION
    @test computed_style(w) === STYLE_NONE
    @test box(w) === BOX_DEFAULT
    # A node that has never been cascaded or laid out is fully dirty.
    @test node(w).dirty == DIRTY_ALL
    @test is_dirty(w)
    # ... but the breadcrumb is not part of DIRTY_ALL.
    @test !is_dirty(w, Dirty.SUBTREE)

    auto = TW(WidgetNode(; type_name = :TW))
    @test id(auto) !== id(w)
    @test node(auto).id isa Symbol
end

@testitem "widget: tree mount and query" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol; cls = Symbol[]) =
        TW(WidgetNode(; id = i, classes = cls, type_name = :TW))

    root = TW(:root)
    a = TW(:a; cls = [:box])
    b = TW(:b; cls = [:box, :hi])
    c = TW(:c)
    mount!(root, a, b)
    mount!(a, c)

    @test children(root) == Widget[a, b]
    @test children(a) == Widget[c]
    @test parent(c) === a
    @test parent(a) === root
    @test parent(root) === nothing
    @test root[1] === a
    @test root[2] === b
    @test a[1] === c
    @test root_of(c) === root
    @test mount!(TW(:p), TW(:q)) isa Widget

    @test query(root, "#b") == Widget[b]
    @test query(root, ".box") == Widget[a, b]
    @test query(root, "TW") == Widget[root, a, c, b]
    @test query(root, "*") == Widget[root, a, c, b]
    @test query(root, "TW.box#b") == Widget[b]
    @test query(root, "#a, #b") == Widget[a, b]
    @test query(root, ".nope") == Widget[]
    @test query(a, "#b") == Widget[]

    @test query_one(root, ".hi") === b
    @test query_one(root, "#nope") === nothing
    @test query_one(root, ".box") === a

    @test_throws ArgumentError query(root, "")
    @test_throws ArgumentError query(root, "#a >")
end

@testitem "widget: query_one typed returns the concrete type" begin
    using DualUI

    mutable struct TA <: Widget
        node::WidgetNode
    end
    mutable struct TB <: Widget
        node::WidgetNode
    end

    root = TA(WidgetNode(; id = :root, type_name = :TA))
    b = TB(WidgetNode(; id = :b, type_name = :TB))
    mount!(root, b)

    @test query_one(root, "#b", TB) === b
    @test @inferred(query_one(root, "#b", TB)) isa TB
    @test query_one(root, "TB", TB) === b
    @test_throws KeyError query_one(root, "#zz", TB)
    @test_throws TypeError query_one(root, "#b", TA)
end

@testitem "widget: mount! binds the app and fires the hooks" begin
    using DualUI

    const LOG = Symbol[]

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    struct FakeApp <: AbstractApp end

    DualUI.on_mount!(w::TW) = (push!(LOG, id(w)); nothing)
    DualUI.on_unmount!(w::TW) = (push!(LOG, Symbol(:un_, id(w))); nothing)

    root = TW(:root)
    node(root).app = FakeApp()
    a = TW(:a)
    c = TW(:c)

    mount!(a, c)
    @test app(c) === nothing   # `a` is not in an app yet

    empty!(LOG)
    @test mount!(root, a) === root
    @test LOG == [:a, :c]      # pre-order over the whole mounted subtree
    @test app(a) isa FakeApp
    @test app(c) isa FakeApp

    @test_throws ArgumentError mount!(root, a)   # already mounted

    empty!(LOG)
    @test unmount!(a) === a
    @test LOG == [:un_a, :un_c]
    @test parent(a) === nothing
    @test app(a) === nothing
    @test app(c) === nothing
    @test isempty(children(root))
    @test children(a) == Widget[c]   # the detached subtree stays intact
end

@testitem "widget: insert_child! and replace_child! keep order" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    a, b, c, d = TW(:a), TW(:b), TW(:c), TW(:d)
    mount!(root, a, c)
    @test insert_child!(root, 2, b) === root
    @test children(root) == Widget[a, b, c]
    @test parent(b) === root

    @test replace_child!(root, b, d) === root
    @test children(root) == Widget[a, d, c]
    @test parent(d) === root
    @test parent(b) === nothing

    @test_throws ArgumentError replace_child!(root, b, TW(:e))
end

@testitem "widget: tree walking ancestors descendants path" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    a, b, c = TW(:a), TW(:b), TW(:c)
    mount!(root, a, b)
    mount!(a, c)

    @test ancestors(c) == Widget[a, root]
    @test ancestors(root) == Widget[]
    @test descendants(root) == Widget[a, c, b]
    @test descendants(c) == Widget[]
    @test path_from_root(c) == Widget[root, a, c]
    @test path_from_root(root) == Widget[root]

    seen = Symbol[]
    walk(w -> (push!(seen, id(w)); nothing), root)
    @test seen == [:root, :a, :c, :b]

    only_c = Symbol[]
    walk(w -> (push!(only_c, id(w)); nothing), c)
    @test only_c == [:c]
end

@testitem "widget: walk_visible skips invisible subtrees" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    a, b, c = TW(:a), TW(:b), TW(:c)
    mount!(root, a, b)
    mount!(a, c)

    set_visible!(a, false)
    @test !is_visible(a)
    @test is_visible(c)        # `c` itself is untouched ...

    seen = Symbol[]
    walk_visible(w -> (push!(seen, id(w)); nothing), root)
    @test seen == [:root, :b]  # ... but it is not reached through `a`

    set_visible!(root, false)
    seen2 = Symbol[]
    walk_visible(w -> (push!(seen2, id(w)); nothing), root)
    @test isempty(seen2)

    all_seen = Symbol[]
    walk(w -> (push!(all_seen, id(w)); nothing), root)
    @test all_seen == [:root, :a, :c, :b]
end

@testitem "widget: dirty mask helpers are pure" begin
    using DualUI

    m = DirtyMask(0)
    @test !has_dirty(m, Dirty.PAINT)
    m2 = set_dirty(m, Dirty.PAINT)
    @test m == DirtyMask(0)          # `set_dirty` did not mutate `m`
    @test has_dirty(m2, Dirty.PAINT)
    @test !has_dirty(m2, Dirty.LAYOUT)

    m3 = set_dirty(m2, Dirty.LAYOUT)
    @test has_dirty(m3, Dirty.PAINT)
    @test has_dirty(m3, Dirty.LAYOUT)
    @test clear_dirty(m3, Dirty.PAINT) == set_dirty(m, Dirty.LAYOUT)
    @test clear_dirty(m3, Dirty.STYLE) == m3   # clearing an unset bit
    @test set_dirty(m3, Dirty.PAINT) == m3     # idempotent

    @test set_dirty(m, Dirty.NONE) == m
    @test !has_dirty(DIRTY_ALL, Dirty.NONE)

    @test DIRTY_ALL == UInt8(Dirty.PAINT) | UInt8(Dirty.LAYOUT) |
                       UInt8(Dirty.STYLE)
    @test !has_dirty(DIRTY_ALL, Dirty.SUBTREE)

    # Bitmask enums must be powers of two, or a mask cannot hold them.
    for k in (Dirty.PAINT, Dirty.LAYOUT, Dirty.STYLE, Dirty.SUBTREE)
        v = UInt8(k)
        @test count_ones(v) == 1
    end
    @test UInt8(Dirty.NONE) == 0x00

    @test @inferred(set_dirty(m, Dirty.PAINT)) isa DirtyMask
    @test @inferred(has_dirty(m, Dirty.PAINT)) isa Bool
end

@testitem "widget: mark! PAINT touches only the widget" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    mid = TW(:mid)
    kid = TW(:kid)
    sib = TW(:sib)
    mount!(root, mid, sib)
    mount!(mid, kid)
    walk(clean!, root)

    mark!(mid, Dirty.PAINT)

    # The widget itself, and only the PAINT bit.
    @test is_dirty(mid, Dirty.PAINT)
    @test !is_dirty(mid, Dirty.LAYOUT)
    @test !is_dirty(mid, Dirty.STYLE)

    # A repaint does not invalidate layout, so descendants are clean.
    @test node(kid).dirty == DirtyMask(0)
    @test !is_dirty(kid)

    # Siblings are never touched.
    @test node(sib).dirty == DirtyMask(0)

    # The ancestor gets the breadcrumb and nothing else.
    @test is_dirty(root, Dirty.SUBTREE)
    @test !is_dirty(root, Dirty.PAINT)
    @test !is_dirty(root, Dirty.LAYOUT)
    @test !is_dirty(root)
end

@testitem "widget: mark! LAYOUT marks all descendants" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    mid = TW(:mid)
    kid = TW(:kid)
    deep = TW(:deep)
    mount!(root, mid)
    mount!(mid, kid)
    mount!(kid, deep)
    walk(clean!, root)

    mark!(mid, Dirty.LAYOUT)

    # A layout change invalidates the whole subtree: every descendant's
    # ABSOLUTE region derives from `mid`'s, so all of them are stale.
    for w in (mid, kid, deep)
        @test is_dirty(w, Dirty.LAYOUT)
        @test is_dirty(w, Dirty.PAINT)
    end
    @test !is_dirty(deep, Dirty.STYLE)
    @test mark!(mid) === nothing   # the default kind is LAYOUT
end

@testitem "widget: mark! never dirties siblings" begin
    using DualUI

    # THE headline E1 test.
    #
    #   root
    #   |-- uncle -- uncle_kid
    #   |-- branch
    #   |   |-- sib1 -- sib1_kid
    #   |   |-- mid          <- the only widget we mutate
    #   |   |   |-- kid1
    #   |   |   `-- kid2
    #   |   `-- sib2
    #   `-- uncle2

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    uncle, uncle_kid = TW(:uncle), TW(:uncle_kid)
    uncle2 = TW(:uncle2)
    branch = TW(:branch)
    sib1, sib1_kid, sib2 = TW(:sib1), TW(:sib1_kid), TW(:sib2)
    mid, kid1, kid2 = TW(:mid), TW(:kid1), TW(:kid2)

    mount!(root, uncle, branch, uncle2)
    mount!(uncle, uncle_kid)
    mount!(branch, sib1, mid, sib2)
    mount!(sib1, sib1_kid)
    mount!(mid, kid1, kid2)

    for kind in (Dirty.PAINT, Dirty.LAYOUT, Dirty.STYLE)
        walk(clean!, root)
        mark!(mid, kind)

        # The mutated widget is flagged.
        @test is_dirty(mid, kind)

        # Not one sibling, uncle, or sibling's descendant is touched --
        # not even with the SUBTREE breadcrumb.
        for w in (sib1, sib1_kid, sib2, uncle, uncle_kid, uncle2)
            @test node(w).dirty == DirtyMask(0)
            @test !is_dirty(w)
            @test !is_dirty(w, Dirty.SUBTREE)
            @test !is_dirty(w, Dirty.LAYOUT)
            @test !is_dirty(w, Dirty.PAINT)
            @test !is_dirty(w, Dirty.STYLE)
        end
    end

    # And the affected descendants of `mid` ARE flagged for the kinds
    # that genuinely reach them, while its siblings still are not.
    walk(clean!, root)
    mark!(mid, Dirty.LAYOUT)
    @test is_dirty(kid1, Dirty.LAYOUT)
    @test is_dirty(kid2, Dirty.LAYOUT)
    @test node(sib1).dirty == DirtyMask(0)
    @test node(sib2).dirty == DirtyMask(0)
end

@testitem "widget: ancestors get SUBTREE only never LAYOUT" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    # A COLUMN box whose main axis (height) is a definite cell count:
    # its size cannot depend on its children, so `escalate_auto!` must
    # not promote it.
    fixed = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                     Align.STRETCH, AUTO, Length(Dimension.CELLS, 10f0),
                     AUTO, AUTO, AUTO, AUTO, NO_SPACING, NO_SPACING,
                     BORDER_NONE, 0, Overflow.HIDDEN, Overflow.HIDDEN,
                     0f0, 1f0)

    root = TW(:root)
    parentw = TW(:parentw)
    mid = TW(:mid)
    kid = TW(:kid)
    mount!(root, parentw)
    mount!(parentw, mid)
    mount!(mid, kid)
    node(root).box = fixed
    node(parentw).box = fixed

    breadcrumb = set_dirty(DirtyMask(0), Dirty.SUBTREE)

    for kind in (Dirty.PAINT, Dirty.STYLE, Dirty.LAYOUT)
        walk(clean!, root)
        mark!(mid, kind)
        for a in (parentw, root)
            @test node(a).dirty == breadcrumb
            @test is_dirty(a, Dirty.SUBTREE)
            @test !is_dirty(a, Dirty.LAYOUT)
            @test !is_dirty(a, Dirty.PAINT)
            @test !is_dirty(a, Dirty.STYLE)
            # The breadcrumb is a routing hint, NOT dirt.
            @test !is_dirty(a)
        end
    end
end

@testitem "widget: SUBTREE is a breadcrumb not dirt" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    leaf = TW(:leaf)
    mount!(root, leaf)
    walk(clean!, root)

    mark!(leaf, Dirty.PAINT)
    @test is_dirty(root, Dirty.SUBTREE)
    @test !is_dirty(root)              # <- the whole point
    @test is_dirty(leaf)

    clean!(leaf)
    @test node(leaf).dirty == DirtyMask(0)
    @test !is_dirty(leaf)
    @test !is_dirty(leaf, Dirty.SUBTREE)
end

@testitem "widget: escalate_auto! promotes only AUTO ancestors" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    # Every box keeps the default AUTO main axis, so every ancestor
    # genuinely re-measures when a descendant changes size.
    root = TW(:root)
    midw = TW(:midw)
    leaf = TW(:leaf)
    sib = TW(:sib)
    mount!(root, midw)
    mount!(midw, leaf, sib)
    @test box(root) === BOX_DEFAULT
    walk(clean!, root)

    mark!(leaf, Dirty.LAYOUT)

    @test is_dirty(leaf, Dirty.LAYOUT)
    @test is_dirty(leaf, Dirty.PAINT)
    for a in (midw, root)
        @test is_dirty(a, Dirty.SUBTREE)
        @test is_dirty(a, Dirty.LAYOUT)    # promoted: AUTO on main axis
        @test !is_dirty(a, Dirty.PAINT)    # its box may not change
    end
    # Promotion walks UP a single path; it never crosses to a sibling.
    @test node(sib).dirty == DirtyMask(0)

    # PAINT never escalates, however AUTO the ancestors are.
    walk(clean!, root)
    mark!(leaf, Dirty.PAINT)
    @test !is_dirty(midw, Dirty.LAYOUT)
    @test !is_dirty(root, Dirty.LAYOUT)
    @test is_dirty(midw, Dirty.SUBTREE)

    # A bare escalate_auto! call is a no-op at the root.
    @test escalate_auto!(root) === nothing
end

@testitem "widget: escalate_auto! stops at a definite ancestor" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    mkbox(dir, w, h) =
        BoxStyle(Display.FLEX, dir, Justify.START, Align.STRETCH,
                 w, h, AUTO, AUTO, AUTO, AUTO, NO_SPACING, NO_SPACING,
                 BORDER_NONE, 0, Overflow.HIDDEN, Overflow.HIDDEN,
                 0f0, 1f0)
    ten = Length(Dimension.CELLS, 10f0)
    half = Length(Dimension.PERCENT, 50f0)

    root = TW(:root)
    fixed = TW(:fixed)
    midw = TW(:midw)
    leaf = TW(:leaf)
    mount!(root, fixed)
    mount!(fixed, midw)
    mount!(midw, leaf)
    node(fixed).box = mkbox(Direction.COLUMN, AUTO, ten)
    walk(clean!, root)

    mark!(leaf, Dirty.LAYOUT)

    @test is_dirty(midw, Dirty.LAYOUT)      # AUTO -> promoted
    @test !is_dirty(fixed, Dirty.LAYOUT)    # definite -> escalation stops
    @test is_dirty(fixed, Dirty.SUBTREE)
    @test !is_dirty(fixed)
    # `root` is above the stop, so it only ever gets the breadcrumb.
    @test !is_dirty(root, Dirty.LAYOUT)
    @test is_dirty(root, Dirty.SUBTREE)
    @test !is_dirty(root)

    # PERCENT is definite too.
    node(fixed).box = mkbox(Direction.COLUMN, AUTO, half)
    walk(clean!, root)
    mark!(leaf, Dirty.LAYOUT)
    @test !is_dirty(fixed, Dirty.LAYOUT)

    # The RELEVANT axis is the main axis. For a ROW the main axis is
    # width, so a definite HEIGHT does not stop the escalation ...
    node(fixed).box = mkbox(Direction.ROW, AUTO, ten)
    walk(clean!, root)
    mark!(leaf, Dirty.LAYOUT)
    @test is_dirty(fixed, Dirty.LAYOUT)

    # ... but a definite WIDTH does.
    node(fixed).box = mkbox(Direction.ROW, ten, AUTO)
    walk(clean!, root)
    mark!(leaf, Dirty.LAYOUT)
    @test !is_dirty(fixed, Dirty.LAYOUT)
    @test is_dirty(fixed, Dirty.SUBTREE)

    # A FRACTION main axis is not definite: it still re-measures.
    node(fixed).box = mkbox(Direction.COLUMN, AUTO,
                            Length(Dimension.FRACTION, 1f0))
    walk(clean!, root)
    mark!(leaf, Dirty.LAYOUT)
    @test is_dirty(fixed, Dirty.LAYOUT)
end

@testitem "widget: dirty_root is the highest LAYOUT node" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    fixed = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                     Align.STRETCH, AUTO, Length(Dimension.CELLS, 10f0),
                     AUTO, AUTO, AUTO, AUTO, NO_SPACING, NO_SPACING,
                     BORDER_NONE, 0, Overflow.HIDDEN, Overflow.HIDDEN,
                     0f0, 1f0)

    root = TW(:root)
    b, c, d, leaf = TW(:b), TW(:c), TW(:d), TW(:leaf)
    mount!(root, b)
    mount!(b, c)
    mount!(c, d)
    mount!(d, leaf)
    node(root).box = fixed
    node(b).box = fixed        # escalation stops here

    walk(clean!, root)
    @test dirty_root(root) === nothing        # a layout-clean tree

    mark!(leaf, Dirty.LAYOUT)
    # LAYOUT reaches leaf, d and c; `b` is definite so it keeps only the
    # breadcrumb. The highest node carrying real LAYOUT is `c`.
    @test is_dirty(c, Dirty.LAYOUT)
    @test !is_dirty(b, Dirty.LAYOUT)
    @test dirty_root(root) === c

    walk(clean!, root)
    mark!(root, Dirty.LAYOUT)
    @test dirty_root(root) === root

    # PAINT-only dirt is not a layout invalidation.
    walk(clean!, root)
    mark!(leaf, Dirty.PAINT)
    @test dirty_root(root) === nothing

    # STYLE-only dirt is not one either.
    walk(clean!, root)
    mark!(leaf, Dirty.STYLE)
    @test dirty_root(root) === nothing
end

@testitem "widget: dirty_root forks at the common ancestor" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    fixed = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                     Align.STRETCH, AUTO, Length(Dimension.CELLS, 10f0),
                     AUTO, AUTO, AUTO, AUTO, NO_SPACING, NO_SPACING,
                     BORDER_NONE, 0, Overflow.HIDDEN, Overflow.HIDDEN,
                     0f0, 1f0)

    root = TW(:root)
    p1, p2 = TW(:p1), TW(:p2)
    leaf1, leaf2 = TW(:leaf1), TW(:leaf2)
    mount!(root, p1, p2)
    mount!(p1, leaf1)
    mount!(p2, leaf2)
    node(root).box = fixed

    walk(clean!, root)
    mark!(leaf1, Dirty.LAYOUT)
    @test dirty_root(root) === p1        # one dirty branch only

    mark!(leaf2, Dirty.LAYOUT)
    # Two independent dirty branches: the minimal relayout must start at
    # their common ancestor, even though it carries only the breadcrumb.
    @test !is_dirty(root, Dirty.LAYOUT)
    @test dirty_root(root) === root
end

@testitem "widget: dirty_root is O(depth) via breadcrumbs" begin
    using DualUI

    const NODE_CALLS = Ref(0)

    mutable struct CW <: Widget
        n::WidgetNode
    end
    DualUI.node(w::CW) = (NODE_CALLS[] += 1; w.n)

    fixed = BoxStyle(Display.BLOCK, Direction.COLUMN, Justify.START,
                     Align.STRETCH, AUTO, Length(Dimension.CELLS, 10f0),
                     AUTO, AUTO, AUTO, AUTO, NO_SPACING, NO_SPACING,
                     BORDER_NONE, 0, Overflow.HIDDEN, Overflow.HIDDEN,
                     0f0, 1f0)

    function build(depth::Int)
        w = CW(WidgetNode(; type_name = :CW))
        node(w).box = fixed        # definite: nothing gets promoted
        depth > 1 && mount!(w, build(depth - 1), build(depth - 1))
        return w
    end

    root = build(8)                # a full binary tree: 2^8 - 1 nodes
    total = Ref(0)
    walk(w -> (total[] += 1; nothing), root)
    @test total[] == 255

    # Descend to the leftmost leaf: 8 nodes on the path.
    function leftmost(w::Widget)
        while !isempty(children(w))
            w = w[1]
        end
        return w
    end
    leaf = leftmost(root)
    @test length(path_from_root(leaf)) == 8

    walk(clean!, root)
    mark!(leaf, Dirty.LAYOUT)

    NODE_CALLS[] = 0
    found = dirty_root(root)
    calls = NODE_CALLS[]

    @test found === leaf
    # A full scan would have to look at all 255 nodes. Following the
    # breadcrumbs visits one root-to-leaf path plus its immediate
    # children, so the count must stay far below the tree size.
    @test calls < total[]
    @test calls <= 60
end

@testitem "widget: mount and unmount dirty the parent not the siblings" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    a = TW(:a)
    mount!(root, a)
    walk(clean!, root)

    b = TW(:b)
    bkid = TW(:bkid)
    mount!(b, bkid)
    mount!(root, b)

    # The new subtree needs a cascade and a layout ...
    @test is_dirty(b, Dirty.LAYOUT)
    @test is_dirty(b, Dirty.STYLE)
    @test is_dirty(bkid, Dirty.LAYOUT)
    @test is_dirty(bkid, Dirty.STYLE)
    # ... and the parent learns a descendant changed.
    @test is_dirty(root, Dirty.SUBTREE)

    # Removing a child restacks the parent's remaining children, so the
    # parent (and only the parent's subtree) is invalidated.
    walk(clean!, root)
    unmount!(b)
    @test is_dirty(root, Dirty.LAYOUT)
    @test is_dirty(a, Dirty.LAYOUT)
    @test node(b).dirty == DirtyMask(0)   # the detached subtree is left
    @test node(bkid).dirty == DirtyMask(0)
end

@testitem "widget: class mutation marks STYLE" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    kid = TW(:kid)
    sib = TW(:sib)
    mount!(root, kid)
    mount!(root, sib)
    walk(clean!, root)

    @test add_class!(root, :on) === root
    @test has_class(root, :on)
    @test is_dirty(root, Dirty.STYLE)
    # Inheritance and descendant selectors reach the subtree ...
    @test is_dirty(kid, Dirty.STYLE)
    # ... but a class change is not a layout change by itself.
    @test !is_dirty(root, Dirty.LAYOUT)
    @test !is_dirty(kid, Dirty.LAYOUT)

    walk(clean!, root)
    add_class!(root, :on)                 # already present: a no-op
    @test !is_dirty(root)
    @test node(kid).dirty == DirtyMask(0)

    walk(clean!, root)
    @test toggle_class!(root, :on) == false
    @test !has_class(root, :on)
    @test is_dirty(root, Dirty.STYLE)
    @test toggle_class!(root, :on) == true
    @test has_class(root, :on)

    walk(clean!, root)
    @test remove_class!(root, :on) === root
    @test !has_class(root, :on)
    @test is_dirty(root, Dirty.STYLE)
    walk(clean!, root)
    remove_class!(root, :on)              # absent: a no-op
    @test !is_dirty(root)
end

@testitem "widget: set_visible! marks LAYOUT" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    mid = TW(:mid)
    kid = TW(:kid)
    sib = TW(:sib)
    mount!(root, mid, sib)
    mount!(mid, kid)
    walk(clean!, root)

    @test set_visible!(mid, false) === nothing
    @test !is_visible(mid)
    @test is_dirty(mid, Dirty.LAYOUT)
    @test is_dirty(kid, Dirty.LAYOUT)
    @test node(sib).dirty == DirtyMask(0)
    @test is_dirty(root, Dirty.SUBTREE)

    walk(clean!, root)
    set_visible!(mid, false)              # unchanged: a no-op
    @test !is_dirty(mid)

    walk(clean!, root)
    set_visible!(mid, true)
    @test is_visible(mid)
    @test is_dirty(mid, Dirty.LAYOUT)
end

@testitem "widget: mark_dirty! and mark_subtree_dirty! are surgical" begin
    using DualUI

    mutable struct TW <: Widget
        node::WidgetNode
    end
    TW(i::Symbol) = TW(WidgetNode(; id = i, type_name = :TW))

    root = TW(:root)
    mid = TW(:mid)
    kid = TW(:kid)
    sib = TW(:sib)
    mount!(root, mid, sib)
    mount!(mid, kid)
    walk(clean!, root)

    # mark_dirty! is the primitive: no ancestor, no descendant, no
    # breadcrumb.
    @test mark_dirty!(mid, Dirty.LAYOUT) === nothing
    @test node(mid).dirty == set_dirty(DirtyMask(0), Dirty.LAYOUT)
    @test node(root).dirty == DirtyMask(0)
    @test node(kid).dirty == DirtyMask(0)
    @test node(sib).dirty == DirtyMask(0)

    walk(clean!, root)
    mark_dirty!(mid)                      # the default kind is PAINT
    @test is_dirty(mid, Dirty.PAINT)

    walk(clean!, root)
    @test mark_subtree_dirty!(mid, Dirty.STYLE) === nothing
    @test is_dirty(mid, Dirty.STYLE)
    @test is_dirty(kid, Dirty.STYLE)
    @test node(root).dirty == DirtyMask(0)   # still no breadcrumb
    @test node(sib).dirty == DirtyMask(0)
end
