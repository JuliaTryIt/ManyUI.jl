# widgets_tree_tests.jl -- the hierarchical TreeView (layer 7).
#
# Every testitem is self-contained, starts `using ManyUI`, needs no tty
# and never sleeps.
#
# NODES ARE DATA. A 10 000-node tree is 10 000 `TreeNode`s and ZERO
# `WidgetNode`s: the suite asserts it (`descendants` is empty at two
# sizes 1000x apart) rather than trusting it. `render!` is O(window) and
# the flattened visible-row list is the thing to get right: collapsing a
# node removes its whole subtree from navigation, and the cursor never
# ends up pointing inside a collapsed branch.
#
# A test that builds a widget and asserts it did not throw proves
# NOTHING: these paint into a headless `Buffer` and assert the CELLS.

@testitem "tree: construction aliases roots and is focusable" begin
    using ManyUI
    rs = [TreeNode("a"), TreeNode("b")]
    w = TreeView(rs)
    @test w isa Widget
    @test w isa RowsWidget
    @test w.roots === rs
    @test type_name(w) === :TreeView
    @test is_focusable(w)
    @test w in focusable_widgets(w)
    @test !is_focused(w)
    # Two roots, both leaves: two visible rows and the cursor on row 1.
    @test row_count(w) == 2
    @test row_cursor(w) == 1
    @test n_selected(w) == 0
end

@testitem "tree: the seam is one line each" begin
    using ManyUI
    w = TreeView([TreeNode("a"), TreeNode("b"), TreeNode("c")])
    @test selection_of(w) === w.sel
    @test row_count(w) == 3
    @test view_count(w) == 3
    for k in 1:3
        @test view_source(w, k) == k
        @test view_rank(w, k) == k
    end
    @test select_mode(w) === SelectMode.SINGLE
end

@testitem "tree: TreeNode and is_leaf / is_expanded" begin
    using ManyUI
    leaf = TreeNode("x")
    @test is_leaf(leaf)
    @test !is_expanded(leaf)
    branch = TreeNode("p", [TreeNode("c")])
    @test !is_leaf(branch)
    # Collapsed by default.
    @test !is_expanded(branch)
    branch.expanded = true
    @test is_expanded(branch)
    # A LEAF flagged expanded is still not expanded: `isempty(kids)` IS
    # the leaf test, so there is no separate flag to fall out of step.
    leaf.expanded = true
    @test !is_expanded(leaf)
end

@testitem "tree: a 10 000-node COLLAPSED tree flattens to roots" begin
    using ManyUI
    big = TreeNode("r", [TreeNode("c$i") for i in 1:9999])
    w = TreeView([big])
    # 10 000 NODES, but a collapsed root contributes EXACTLY ONE ROW
    # however deep it is -- that is what expand/collapse MEANS.
    @test row_count(w) == 1
    @test length(w.roots) == 1
    @test content_extent(w).height == length(w.roots)
    expand_node!(w, big)
    @test row_count(w) == 10000
    @test content_extent(w).height == 10000
end

@testitem "tree: nodes are DATA -- descendants empty at two sizes" begin
    using ManyUI
    small = TreeView([TreeNode("r", [TreeNode("a") for _ in 1:9])])
    big = TreeView([TreeNode("r", [TreeNode("a$i") for i in 1:9999])])
    @test isempty(descendants(small))
    @test isempty(descendants(big))
    @test length(descendants(big)) == length(descendants(small))
    @test isempty(children(big))
    @test length(focusable_widgets(small)) == 1
    @test length(focusable_widgets(big)) == 1

    # STILL flat after a REAL frame: no row widget is materialised on
    # the first paint, which is where such a regression would hide.
    apply_stylesheet!(STYLESHEET_EMPTY, big)
    layout!(big, Region(1, 1, 20, 24))
    buf = Buffer(20, 24)
    clear!(buf)
    paint!(buf, big)
    @test isempty(descendants(big))

    # The instrument is LIVE, not vacuous: `descendants` DOES count real
    # children. Without this control an always-empty `descendants` would
    # satisfy every assertion above.
    @test !isempty(descendants(Scrollpane(TreeView([TreeNode("a")]))))
end

@testitem "tree: render! is O(window) -- alloc independent of nodes" begin
    using ManyUI
    small = TreeView([TreeNode("r",
        [TreeNode("c$i") for i in 1:9]; expanded = true)])
    big = TreeView([TreeNode("r",
        [TreeNode("c$i") for i in 1:9999]; expanded = true)])
    @test row_count(small) == 10
    @test row_count(big) == 10000
    apply_stylesheet!(STYLESHEET_EMPTY, small)
    apply_stylesheet!(STYLESHEET_EMPTY, big)
    layout!(small, Region(1, 1, 20, 5))
    layout!(big, Region(1, 1, 20, 5))
    buf = Buffer(20, 5)
    clear!(buf)
    # Warm up: the first paint compiles and pays the ONE O(visible)
    # flatten. Every paint after is a memo HIT.
    render!(small, buf)
    render!(big, buf)
    a_small = @allocated render!(small, buf)
    a_big = @allocated render!(big, buf)
    # 10 nodes and 10 000 nodes cost the SAME frame: paint is O(window).
    @test a_big == a_small
end

@testitem "tree: an EMPTY tree does not throw and paints nothing" begin
    using ManyUI
    w = TreeView(TreeNode{String}[])
    @test tree_cursor(w) === nothing
    @test row_count(w) == 0
    @test content_extent(w).height == 0
    @test node_at(w, 1) === nothing
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 4, 2))
    buf = Buffer(4, 2)
    clear!(buf)
    render!(w, buf)
    @test string(buf) == "    \n    "
    # Every key is a no-op on nothing: it moves nothing and consumes
    # nothing, so it bubbles.
    for e in (key(Key.SPACE), key(' '), key(Key.LEFT), key(Key.RIGHT),
              key(Key.UP), key(Key.DOWN), key(Key.HOME), key(Key.END))
        d = Dispatch(e, w)
        d.phase = Phase.AT_TARGET
        on_event!(w, d)
        @test !is_consumed(d)
    end
    @test tree_cursor(w) === nothing
end

@testitem "tree: one node paints its label past the twisty" begin
    using ManyUI
    w = TreeView([TreeNode("hello")])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 2))
    buf = Buffer(10, 2)
    clear!(buf)
    render!(w, buf)
    # A leaf twisty is a SPACE, so the text column is INVARIANT: twisty
    # col 1, one-cell gap, label at col 3.
    @test buf[1, 1].content == " "
    @test buf[3, 1].content == "h"
    @test buf[7, 1].content == "o"
end

@testitem "tree: deep nesting indents by depth" begin
    using ManyUI
    d = TreeNode("d")
    c = TreeNode("c", [d]; expanded = true)
    b = TreeNode("b", [c]; expanded = true)
    a = TreeNode("a", [b]; expanded = true)
    root = TreeNode("r", [a]; expanded = true)
    w = TreeView([root])
    @test row_count(w) == 5            # r, a, b, c, d
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 20, 6))
    buf = Buffer(20, 6)
    clear!(buf)
    render!(w, buf)
    # TV_INDENT == 2 cells per level; the twisty sits at 1 + 2*depth.
    @test buf[1, 1].content == "-"     # r,  depth 0
    @test buf[3, 2].content == "-"     # a,  depth 1
    @test buf[5, 3].content == "-"     # b,  depth 2
    @test buf[7, 4].content == "-"     # c,  depth 3
    @test buf[9, 5].content == " "     # d,  depth 4 leaf twisty
    @test buf[11, 5].content == "d"    # d's label
end

@testitem "tree: key(Key.SPACE) toggles the cursor node" begin
    using ManyUI
    w = TreeView([TreeNode("r", [TreeNode("a"), TreeNode("b")])])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 4))
    buf = Buffer(10, 4)
    clear!(buf)
    render!(w, buf)
    # Collapsed: the twisty says "+".
    @test buf[1, 1].content == "+"
    @test row_count(w) == 1

    d = Dispatch(key(Key.SPACE), w)
    d.phase = Phase.AT_TARGET
    on_event!(w, d)
    @test is_consumed(d)
    @test row_count(w) == 3            # r, a, b
    clear!(buf)
    render!(w, buf)
    # The TWISTY CELL flipped, and the children appeared. Child "a" is
    # at depth 1: its leaf twisty is the space at column 3, and its
    # label sits one indent + twisty + gap in, at column 5.
    @test buf[1, 1].content == "-"
    @test buf[3, 2].content == " "
    @test buf[5, 2].content == "a"
end

@testitem "tree: key(' ') also toggles the cursor node" begin
    using ManyUI
    w = TreeView([TreeNode("r", [TreeNode("a")])])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 4))
    # THE space bar is `Key.SPACE`, but the parser also emits
    # `Key.CHAR(' ')`; a checkbox that checks only one is a checkbox
    # that silently does nothing. A tree owes the same both-forms test.
    d = Dispatch(key(' '), w)
    d.phase = Phase.AT_TARGET
    on_event!(w, d)
    @test is_consumed(d)
    @test row_count(w) == 2
end

@testitem "tree: SPACE on a LEAF does not consume" begin
    using ManyUI
    w = TreeView([TreeNode("r")])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 4))
    for e in (key(Key.SPACE), key(' '))
        d = Dispatch(e, w)
        d.phase = Phase.AT_TARGET
        on_event!(w, d)
        # Nothing to toggle on a leaf, so the key bubbles.
        @test !is_consumed(d)
    end
    buf = Buffer(10, 4)
    clear!(buf)
    render!(w, buf)
    @test buf[1, 1].content == " "     # still a leaf twisty
end

@testitem "tree: collapsing an ANCESTOR re-pins the cursor onto it" begin
    using ManyUI
    a1 = TreeNode("a1")
    a2 = TreeNode("a2")
    a = TreeNode("a", [a1, a2])
    b = TreeNode("b")
    root = TreeNode("root", [a, b])
    w = TreeView([root])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 12, 8))
    expand_all!(w)
    # visible: root, a, a1, a2, b
    @test row_count(w) == 5
    set_cursor!(w, 4)
    @test tree_cursor(w) === a2

    # Collapsing `a` removes a1/a2 from navigation; the cursor cannot be
    # left pointing inside a branch nobody can see, so it lands ON `a`.
    @test collapse_node!(w, a)
    @test row_count(w) == 3            # root, a, b
    @test tree_cursor(w) === a
end

@testitem "tree: expanding re-pins the cursor by IDENTITY" begin
    using ManyUI
    rootA = TreeNode("A", [TreeNode("A1"), TreeNode("A2")])
    rootB = TreeNode("B")
    w = TreeView([rootA, rootB])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 8))
    # collapsed: A(row 1), B(row 2). Put the cursor on B.
    set_cursor!(w, 2)
    @test tree_cursor(w) === rootB
    @test row_cursor(w) == 2

    @test expand_node!(w, rootA)
    # A, A1, A2, B -- B is now row 4, but the cursor FOLLOWS THE NODE.
    @test row_count(w) == 4
    @test tree_cursor(w) === rootB
    @test row_cursor(w) == 4
end

@testitem "tree: RIGHT expands; RIGHT again moves to the first child" begin
    using ManyUI
    c1 = TreeNode("c1")
    c2 = TreeNode("c2")
    root = TreeNode("r", [c1, c2])
    w = TreeView([root])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 6))
    press(e) = (d = Dispatch(e, w); d.phase = Phase.AT_TARGET;
                on_event!(w, d); is_consumed(d))

    @test tree_cursor(w) === root
    @test press(key(Key.RIGHT))        # first RIGHT expands
    @test root.expanded
    @test tree_cursor(w) === root       # cursor stays on the parent
    @test press(key(Key.RIGHT))        # second RIGHT descends
    @test tree_cursor(w) === c1
end

@testitem "tree: LEFT at a collapsed node walks to the PARENT" begin
    using ManyUI
    grand = TreeNode("g")
    c1 = TreeNode("c1", [grand])       # a COLLAPSED branch
    root = TreeNode("r", [c1]; expanded = true)
    w = TreeView([root])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 6))
    # visible: r(row 1), c1(row 2). Put the cursor on c1.
    set_cursor!(w, 2)
    @test tree_cursor(w) === c1

    d = Dispatch(key(Key.LEFT), w)
    d.phase = Phase.AT_TARGET
    on_event!(w, d)
    @test is_consumed(d)
    # No parent pointer: the parent is RECOVERED from the flattened rows
    # -- the nearest earlier row with a smaller depth.
    @test tree_cursor(w) === root
end

@testitem "tree: LEFT at a root leaf does NOT consume" begin
    using ManyUI
    w = TreeView([TreeNode("r")])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 4))
    d = Dispatch(key(Key.LEFT), w)
    d.phase = Phase.AT_TARGET
    on_event!(w, d)
    # A top-level leaf has no parent to walk to: LEFT is a dead key here
    # and must bubble.
    @test !is_consumed(d)
    @test tree_cursor(w) === w.roots[1]
end

@testitem "tree: UP/DOWN/HOME/END/PAGE delegate to _tc_key!" begin
    using ManyUI
    w = TreeView([TreeNode("L$i") for i in 1:20])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 5))
    press(e) = (d = Dispatch(e, w); d.phase = Phase.AT_TARGET;
                on_event!(w, d); is_consumed(d))

    @test press(key(Key.DOWN))
    @test row_cursor(w) == 2
    @test press(key(Key.END))
    @test row_cursor(w) == 20
    @test press(key(Key.HOME))
    @test row_cursor(w) == 1
    @test press(key(Key.PAGE_DOWN))
    @test row_cursor(w) > 1
    # DOWN on the LAST row moves nothing, so it bubbles -- chaining.
    set_cursor!(w, 20)
    @test !press(key(Key.DOWN))
end

@testitem "tree: a TreeView does not consume tab" begin
    using ManyUI
    w = TreeView([TreeNode("r", [TreeNode("a")])])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 5))
    # A control that consumes TAB traps focus forever. Consume ONLY what
    # you handle -- and a tree does not handle TAB in any state.
    for e in (key(Key.TAB), key(Key.TAB; shift = true))
        d = Dispatch(e, w)
        d.phase = Phase.AT_TARGET
        on_event!(w, d)
        @test !is_consumed(d)
    end
end

@testitem "tree: clicking the TWISTY toggles; the LABEL moves cursor" begin
    using ManyUI
    r0 = TreeNode("r0", [TreeNode("x"), TreeNode("y")])
    r1 = TreeNode("r1")
    w = TreeView([r0, r1])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 5))
    click(x, y) = dispatch_event!(w, MouseEvent(MouseAction.PRESS,
                                                MouseButton.LEFT, x, y,
                                                MOD_NONE))
    # The twisty of r0 is at content column 1 (depth 0).
    @test click(1, 1)
    @test r0.expanded
    @test row_count(w) == 4           # r0, x, y, r1

    # Clicking a LABEL (not the twisty column) just moves the cursor.
    # r1 is now row 4; its label sits at column 3.
    @test click(3, 4)
    @test tree_cursor(w) === r1
    @test !r1.expanded                # a leaf: the label click did NOT
                                      # toggle anything
end

@testitem "tree: a TreeView inside a scrolled pane clicks the right row" begin
    using ManyUI
    w = TreeView([TreeNode("L$i") for i in 1:20])
    # A tree takes the height it is OFFERED, so a pane wrapped round one
    # scrolls nothing until the tree is given a box TALLER than the pane.
    w.node.inline_box = BoxPatch(; height = cells(10), shrink = 0f0,
                                 grow = 0f0)
    pane = Scrollpane(w; bar_y = ScrollMode.NEVER,
                      bar_x = ScrollMode.NEVER)
    apply_stylesheet!(STYLESHEET_EMPTY, pane)
    layout!(pane, Region(1, 1, 10, 5))
    @test layout_of(w).content.height == 10

    # `_tc_local` honours every scrolled ancestor -- `local_offset`
    # would select the row two ABOVE the pointer once the pane shifts.
    @test dispatch_event!(pane, MouseEvent(MouseAction.PRESS,
                                           MouseButton.LEFT, 1, 3,
                                           MOD_NONE))
    @test row_cursor(w) == 3
    @test scroll_to!(pane, Offset(0, 2)) === Offset(0, 2)
    @test dispatch_event!(pane, MouseEvent(MouseAction.PRESS,
                                           MouseButton.LEFT, 1, 3,
                                           MOD_NONE))
    @test row_cursor(w) == 5
end

@testitem "tree: Scrollbar{TreeView} needs no new code" begin
    using ManyUI
    w = TreeView([TreeNode("L$i") for i in 1:20])
    bar = Scrollbar(w, ScrollAxis.VERTICAL; mode = ScrollMode.ALWAYS)
    # PARAMETRIC on the viewport type: the scrollable seam is three
    # functions (content_extent, layout, scroll), not a type.
    @test bar isa Scrollbar{<:TreeView}
    @test bar.viewport === w

    w.node.inline_box = BoxPatch(; grow = 1f0)
    bar.node.inline_box = BoxPatch(; width = cells(1), shrink = 0f0,
                                   grow = 0f0)
    root = Container(w, bar)
    root.node.inline_box = BoxPatch(; display = Display.FLEX,
                                    direction = Direction.ROW)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 6, 4))
    buf = Buffer(6, 4)
    clear!(buf)
    paint!(buf, root)
    col = [buf[6, y].content for y in 1:4]
    # 20 rows, a 4-cell track: a 1-cell thumb pinned to the top.
    @test col[1] == ManyUI.SB_THUMB
    @test all(==(ManyUI.SB_TRACK_V), col[2:4])

    scroll_to!(w, Offset(0, 16))
    clear!(buf)
    paint!(buf, root)
    col = [buf[6, y].content for y in 1:4]
    @test col[4] == ManyUI.SB_THUMB   # pinned to the BOTTOM
end

@testitem "tree: measure IS avail (greedy by design)" begin
    using ManyUI
    w = TreeView([TreeNode("a"), TreeNode("b")])
    # GREEDY: a tree takes the space it is OFFERED and scrolls its
    # content, because an auto-height tree would be as tall as its data
    # and would never scroll at all.
    @test measure(w, Size(20, 7)) === Size(20, 7)
    @test measure(w, Size(4, 3)) === Size(4, 3)
    @test measure(w, Size(0, 0)) === Size(0, 0)
end

@testitem "tree: expand_all! then collapse_all! is a round trip" begin
    using ManyUI
    root = TreeNode("r",
        [TreeNode("a", [TreeNode("a1")]), TreeNode("b")])
    w = TreeView([root])
    @test row_count(w) == 1            # collapsed: just the root
    expand_all!(w)
    @test row_count(w) == 4            # r, a, a1, b
    collapse_all!(w)
    @test row_count(w) == 1
    @test length(w.roots) == 1
    # Nothing below the roots is expanded any more.
    @test !root.expanded
    @test !root.kids[1].expanded
end

@testitem "tree: refresh_tree! picks up a push! into kids" begin
    using ManyUI
    root = TreeNode("r", [TreeNode("c1")]; expanded = true)
    w = TreeView([root])
    @test row_count(w) == 2            # r, c1
    # Mutating `kids` behind the memo's back does NOT repaint on its
    # own -- that is the stated price -- but `refresh_tree!` is the
    # escape hatch that flattens it in.
    push!(root.kids, TreeNode("c2"))
    @test row_count(w) == 2            # still stale
    refresh_tree!(w)
    @test row_count(w) == 3            # r, c1, c2
end

@testitem "tree: set_roots! replaces and rewinds" begin
    using ManyUI
    w = TreeView([TreeNode("a"), TreeNode("b"), TreeNode("c")])
    apply_stylesheet!(STYLESHEET_EMPTY, w)
    layout!(w, Region(1, 1, 10, 2))
    set_cursor!(w, 3)
    set_scroll!(w, Offset(0, 1))
    set_roots!(w, [TreeNode("x")])
    @test row_count(w) == 1
    @test scroll_of(w) === ORIGIN
    @test tree_cursor(w) === w.roots[1]
end

@testitem "tree: the twisty glyphs are width 1" begin
    using ManyUI
    # ASCII, and the text column is invariant only if all three are one
    # cell wide. `Base.textwidth` is forbidden; `text_width` is the
    # grapheme-aware measure.
    @test text_width(ManyUI.TV_OPEN) == 1
    @test text_width(ManyUI.TV_CLOSED) == 1
    @test text_width(ManyUI.TV_LEAF) == 1
    @test ManyUI.TV_INDENT == 2
end
