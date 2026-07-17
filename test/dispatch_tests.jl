# dispatch_tests.jl -- @testitem blocks for DualUI/src/dispatch.jl.
#
# E3 / EARS 2.2: "When a user input event (keyboard stroke, mouse click,
# or scroll) occurs, the DualUI framework shall propagate the event
# through the component tree using capture and bubble phases until the
# event is consumed."
#
# events_tests.jl proves the ENVELOPE (Dispatch/Phase/consume!) can
# express such a walk on a bare node chain. What is proved here is that
# `propagate!` performs that walk on a REAL tree, that `dispatch_event!`
# routes each event class to the right target, and that consumption
# truncates the walk at every phase.

@testitem "dispatch: propagation_path is root to target inclusive" begin
    using DualUI
    leaf = Label("leaf"; id = :leaf)
    mid = Container(leaf; id = :mid)
    root = Container(mid; id = :root)

    @test propagation_path(root) == [root]
    @test propagation_path(mid) == [root, mid]
    @test propagation_path(leaf) == [root, mid, leaf]
end

@testitem "dispatch: propagate! captures then bubbles" begin
    using DualUI

    # All three probes share ONE log, so what is asserted below is the
    # chronological visit order across the whole walk rather than each
    # widget's private view of it.
    mutable struct PathProbe <: DualUI.Widget
        node::WidgetNode
        log::Vector{Tuple{Symbol,Phase.T}}
        consume_on::Union{Nothing,Phase.T}
    end
    PathProbe(name::Symbol, log::Vector{Tuple{Symbol,Phase.T}}) =
        PathProbe(WidgetNode(; id = name, type_name = :PathProbe),
                  log, nothing)

    function DualUI.on_event!(w::PathProbe, d::Dispatch{KeyEvent})
        push!(w.log, (DualUI.id(w), d.phase))
        w.consume_on === d.phase && consume!(d)
        return nothing
    end

    log = Tuple{Symbol,Phase.T}[]
    root = PathProbe(:root, log)
    mid = PathProbe(:mid, log)
    leaf = PathProbe(:leaf, log)
    mount!(root, mid)
    mount!(mid, leaf)

    # Nobody consumes: the full walk runs and reports unconsumed.
    @test !propagate!(root, leaf, key('a'))
    @test log == [(:root, Phase.CAPTURE), (:mid, Phase.CAPTURE),
                  (:leaf, Phase.AT_TARGET),
                  (:mid, Phase.BUBBLE), (:root, Phase.BUBBLE)]
    # The target is visited exactly once, and AT_TARGET marks that visit
    # apart from the capture and bubble visits it would be confused with.
    @test count(l -> l[1] === :leaf, log) == 1
    # Capture is root-first; bubble is its exact reverse.
    caps = [n for (n, p) in log if p === Phase.CAPTURE]
    bubs = [n for (n, p) in log if p === Phase.BUBBLE]
    @test caps == [:root, :mid]
    @test bubs == reverse(caps)
end

@testitem "dispatch: consuming truncates the walk at every phase" begin
    using DualUI

    mutable struct StopProbe <: DualUI.Widget
        node::DualUI.WidgetNode
        log::Vector{Tuple{Symbol,Phase.T}}
        consume_on::Union{Nothing,Phase.T}
    end
    StopProbe(name::Symbol) =
        StopProbe(DualUI.WidgetNode(; id = name, type_name = :StopProbe),
                  Tuple{Symbol,Phase.T}[], nothing)

    function DualUI.on_event!(w::StopProbe, d::Dispatch{KeyEvent})
        push!(w.log, (DualUI.id(w), d.phase))
        w.consume_on === d.phase && consume!(d)
        return nothing
    end

    function fresh()
        r, m, l = StopProbe(:root), StopProbe(:mid), StopProbe(:leaf)
        mount!(r, m)
        mount!(m, l)
        return r, m, l
    end

    # Consumed during CAPTURE at the root: the target never sees it and
    # the bubble phase never happens.
    r, m, l = fresh()
    r.consume_on = Phase.CAPTURE
    @test propagate!(r, l, key('a'))
    @test r.log == [(:root, Phase.CAPTURE)]
    @test isempty(m.log)
    @test isempty(l.log)

    # Consumed AT_TARGET: capture completed, bubble is cancelled.
    r, m, l = fresh()
    l.consume_on = Phase.AT_TARGET
    @test propagate!(r, l, key('a'))
    @test l.log == [(:leaf, Phase.AT_TARGET)]
    @test m.log == [(:mid, Phase.CAPTURE)]
    @test r.log == [(:root, Phase.CAPTURE)]

    # Consumed mid-BUBBLE: the root never sees the bubble.
    r, m, l = fresh()
    m.consume_on = Phase.BUBBLE
    @test propagate!(r, l, key('a'))
    @test m.log == [(:mid, Phase.CAPTURE), (:mid, Phase.BUBBLE)]
    @test r.log == [(:root, Phase.CAPTURE)]
end

@testitem "dispatch: hit_test finds the deepest widget" begin
    using DualUI
    leaf = Label("x"; id = :leaf)
    mid = Container(leaf; id = :mid)
    root = Container(mid; id = :root)
    layout!(root, Region(1, 1, 20, 6))

    r = region(leaf)
    @test !isempty(r)
    # A point inside the leaf resolves to the leaf, not to an ancestor
    # that also contains it: a child covers its parent.
    @test hit_test(root, r.x, r.y) === leaf
    @test hit_test(root, Offset(r.x, r.y)) === leaf
    # Outside the root entirely: nothing is hit.
    @test hit_test(root, 999, 999) === nothing
end

@testitem "dispatch: hit_test skips invisible subtrees" begin
    using DualUI
    leaf = Label("x"; id = :leaf)
    mid = Container(leaf; id = :mid)
    root = Container(mid; id = :root)
    layout!(root, Region(1, 1, 20, 6))
    r = region(leaf)
    @test hit_test(root, r.x, r.y) === leaf

    # Hiding the leaf hands the hit to whatever is still visible under
    # it -- never to the hidden widget.
    set_visible!(leaf, false)
    @test hit_test(root, r.x, r.y) !== leaf
    # Hiding the whole root makes the tree untargetable.
    set_visible!(root, false)
    @test hit_test(root, r.x, r.y) === nothing
end

@testitem "dispatch: a later sibling covers an earlier one" begin
    using DualUI
    # Paint order IS document order (paint.jl), so where two siblings
    # overlap the LATER one is what the user sees and therefore what a
    # click must reach. Descending in document order would return the
    # covered widget and route clicks to something invisible.
    a = Container(; id = :first)
    b = Container(; id = :second)
    root = Container(a, b; id = :root)
    layout!(root, Region(1, 1, 20, 6))

    # Force an exact overlap after layout has run.
    node(a).layout = layout_box(box(a), Region(2, 2, 4, 2))
    node(b).layout = layout_box(box(b), Region(2, 2, 4, 2))
    @test hit_test(root, 2, 2) === b
end

@testitem "dispatch: dispatch_event! routes by event class" begin
    using DualUI

    # A probe type of its own: adding `on_event!` methods for Container
    # or Label would install them into DualUI for every other testitem
    # sharing this process.
    mutable struct RouteProbe <: DualUI.Widget
        node::WidgetNode
        seen::Vector{DualUI.Widget}
    end
    RouteProbe(name::Symbol) =
        RouteProbe(WidgetNode(; id = name, type_name = :RouteProbe),
                   DualUI.Widget[])

    function DualUI.on_event!(w::RouteProbe, d::Dispatch)
        d.phase === Phase.AT_TARGET && push!(w.seen, d.target)
        return nothing
    end

    root, leaf = RouteProbe(:root), RouteProbe(:leaf)
    mount!(root, leaf)
    # Regions assigned directly: routing is under test here, not layout.
    node(root).layout = layout_box(box(root), Region(1, 1, 20, 6))
    node(leaf).layout = layout_box(box(leaf), Region(2, 2, 4, 2))
    targets() = vcat(root.seen, leaf.seen)
    rearm!() = (empty!(root.seen); empty!(leaf.seen))

    # Mouse routes by hit test.
    rearm!()
    dispatch_event!(root, MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                                     2, 2, MOD_NONE))
    @test targets() == [leaf]

    # A mouse event that hits nothing falls back to the root.
    rearm!()
    dispatch_event!(root, MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                                     999, 999, MOD_NONE))
    @test targets() == [root]

    # Keys route to focus, and to the root when there is no focus.
    rearm!()
    dispatch_event!(root, key('a'), leaf)
    @test targets() == [leaf]
    rearm!()
    dispatch_event!(root, key('a'))
    @test targets() == [root]

    # Resize always routes to the root, focus notwithstanding.
    rearm!()
    dispatch_event!(root, ResizeEvent(Size(30, 8)), leaf)
    @test targets() == [root]
end

@testitem "dispatch: RefreshEvent and QuitEvent are not routed" begin
    using DualUI
    leaf = Label("x"; id = :leaf)
    root = Container(leaf; id = :root)
    layout!(root, Region(1, 1, 20, 6))

    # These are App-level only: the tree must never see them, so
    # dispatch_event! reports "not consumed" without walking.
    @test !dispatch_event!(root, RefreshEvent())
    @test !dispatch_event!(root, QuitEvent())
end

@testitem "dispatch: focusable_widgets is visible pre-order" begin
    using DualUI
    b1 = Button("one", identity; id = :b1)
    b2 = Button("two", identity; id = :b2)
    plain = Label("not focusable"; id = :plain)
    mid = Container(b1, plain; id = :mid)
    root = Container(mid, b2; id = :root)

    @test focusable_widgets(root) == [b1, b2]

    # An invisible subtree leaves the tab order entirely.
    set_visible!(mid, false)
    @test focusable_widgets(root) == [b2]
end

@testitem "dispatch: hit_test targets the PAINTED box under scroll" begin
    using DualUI
    # Layout computes ABSOLUTE boxes and never sees scroll, so inside a
    # scrolled subtree `region(w)` is where `w` WOULD sit at scroll
    # zero. The pointer names a cell on the SCREEN, so the hit test has
    # to compare against `painted_region`. Comparing against `region`
    # targets whatever occupies the widget's unscrolled slot.
    a = Label("A"; id = :a)
    b = Label("B"; id = :b)
    stack = Container(a, b; id = :stack)
    root = Container(stack; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 20, 6))

    ra, rb = region(a), region(b)
    @test rb.y == ra.y + 1          # stacked, one row each
    @test hit_test(root, ra.x, ra.y) === a

    # Scroll the stack's CHILDREN up one row. B is now PAINTED on the
    # row A used to occupy, so a click there must reach B, not A.
    @test set_scroll!(stack, Offset(0, 1))
    @test painted_region(b) ===
          Region(rb.x, rb.y - 1, rb.width, rb.height)
    @test painted_region(a) ===
          Region(ra.x, ra.y - 1, ra.width, ra.height)
    @test hit_test(root, ra.x, ra.y) === b

    # Unscrolling restores the original targeting exactly: outside a
    # scrolled subtree `painted_region` and `region` agree.
    @test set_scroll!(stack, Offset(0, 0))
    @test painted_region(a) === region(a)
    @test hit_test(root, ra.x, ra.y) === a
end

@testitem "dispatch: a click in a Scrollpane hits the visible row" begin
    using DualUI
    # The end-to-end shape of the bug: the pane displays L4 on its first
    # row, and that is the widget the click must reach.
    labels = [Label("L$i"; id = Symbol("l", i)) for i in 1:8]
    stack = Container(labels...; id = :stack)
    pane = Scrollpane(stack; id = :pane)
    root = Container(pane; id = :root)
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 9, 3))

    @test hit_test(root, 1, 1) === labels[1]

    @test scroll_to!(viewport(pane), Offset(0, 3)) === Offset(0, 3)
    # Row 1 now shows L4 -- assert the PAINT and the HIT agree, so this
    # cannot pass by asserting the bug back into place.
    buf = Buffer(9, 3)
    clear!(buf)
    paint!(buf, root)
    @test buf[1, 1].content == "L"
    @test buf[2, 1].content == "4"
    @test hit_test(root, 1, 1) === labels[4]
    @test hit_test(root, 1, 2) === labels[5]
end
