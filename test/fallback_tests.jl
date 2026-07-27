# fallback_tests.jl -- @testitem tests for the App's X2 fallback path:
# frame! step 3'.
#
# EARS 2.5 / X2: "If the available terminal rendering area drops below
# the root layout's defined minimum dimensions, then suspend standard
# rendering and display an 'Increase Terminal Size' fallback overlay."
#
# The predicate (`should_suspend`) and the two painters live in
# src/widgets/overlay.jl and are tested there. What is asserted here is
# the APP's half: that suspension actually SUSPENDS the normal pipeline,
# that the overlay reaches the driver through the ordinary diff/encode
# path, and that growing back resumes cleanly.

@testitem "app: suspends below min_size and recovers" begin
    using ManyUI

    mutable struct Leaf1 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        text::String
    end
    Leaf1(t::AbstractString) =
        Leaf1(ManyUI.WidgetNode(type_name = :Leaf1), String(t))
    ManyUI.measure(w::Leaf1, avail::Size) = Size(text_width(w.text), 1)
    function ManyUI.render!(w::Leaf1, buf::AbstractMatrix{Cell})
        write_text!(buf, 1, 1, w.text)
        nothing
    end

    dr = HeadlessDriver(Size(80, 24))
    ap = App(Leaf1("CONTENT"), dr,
             config = AppConfig(min_size = Size(20, 5)))

    handle!(ap, ResizeEvent(Size(80, 24)))
    @test !ap.suspended
    frame!(ap)
    @test occursin("CONTENT", string(ap.back))

    # Drop below the minimum on the height axis alone.
    handle!(ap, ResizeEvent(Size(80, 3)))
    @test ap.suspended
    frame!(ap)
    @test occursin("Increase Terminal Size", string(ap.back))
    @test !occursin("CONTENT", string(ap.back))

    # ... and on the width axis alone. How much of the message fits in
    # 14 cells is the overlay's business; that the tree is suspended is
    # this test's business.
    handle!(ap, ResizeEvent(Size(14, 24)))
    @test ap.suspended
    frame!(ap)
    @test !occursin("CONTENT", string(ap.back))

    # Grow back: rendering resumes cleanly, no residue.
    handle!(ap, ResizeEvent(Size(80, 24)))
    @test !ap.suspended
    frame!(ap)
    @test occursin("CONTENT", string(ap.back))
    @test !occursin("Increase Terminal Size", string(ap.back))
    # And the tree is live again: a clean frame is still free.
    @test frame!(ap) == 0
end

@testitem "fallback: suspended frames never lay out the root" begin
    using ManyUI

    # X2 says SUSPEND standard rendering. Not "paint it anyway and cover
    # it up": the root must not be measured, laid out or painted at all.
    mutable struct Spy2 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        measured::Ref{Int}
        painted::Ref{Int}
    end
    Spy2() = Spy2(ManyUI.WidgetNode(type_name = :Spy2), Ref(0), Ref(0))
    function ManyUI.measure(w::Spy2, avail::Size)
        w.measured[] += 1
        Size(7, 1)
    end
    function ManyUI.render!(w::Spy2, buf::AbstractMatrix{Cell})
        w.painted[] += 1
        write_text!(buf, 1, 1, "CONTENT")
        nothing
    end

    rt = Spy2()
    dr = HeadlessDriver(Size(80, 24))
    ap = App(rt, dr, config = AppConfig(min_size = Size(20, 5)))

    handle!(ap, ResizeEvent(Size(10, 2)))
    @test ap.suspended
    rt.measured[] = 0
    rt.painted[] = 0

    frame!(ap)
    frame!(ap)
    @test rt.measured[] == 0
    @test rt.painted[] == 0
    @test !occursin("CONTENT", string(ap.back))

    handle!(ap, ResizeEvent(Size(80, 24)))
    @test !ap.suspended
    frame!(ap)
    @test rt.painted[] >= 1
    @test occursin("CONTENT", string(ap.back))
end

@testitem "fallback: overlay reaches the driver through the diff" begin
    using ManyUI

    mutable struct Leaf3 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Leaf3() = Leaf3(ManyUI.WidgetNode(type_name = :Leaf3))

    dr = HeadlessDriver(Size(40, 6))
    ap = App(Leaf3(), dr, config = AppConfig(min_size = Size(20, 5)))

    handle!(ap, ResizeEvent(Size(40, 3)))
    @test ap.suspended
    clear_output!(dr)
    n = frame!(ap)
    # Steps 4-7 run normally: the overlay is diffed, encoded, emitted
    # and flushed exactly like any other frame.
    @test n > 0
    @test n == length(take_bytes!(dr))
    @test occursin("Increase Terminal Size", string(ap.back))

    # X2 costs no special path downstream: it is just a different
    # Buffer, so an unchanged overlay still diffs to nothing.
    @test frame!(ap) == 0
end

@testitem "fallback: tiny areas take the tree-free painter" begin
    using ManyUI

    mutable struct Leaf4 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Leaf4() = Leaf4(ManyUI.WidgetNode(type_name = :Leaf4))

    # Below OVERLAY_MIN_SIZE the layout engine is by definition
    # unusable, so the overlay widget must NOT be driven at all.
    dr = HeadlessDriver(Size(8, 1))
    ap = App(Leaf4(), dr, config = AppConfig(min_size = Size(20, 5)))

    handle!(ap, ResizeEvent(Size(8, 1)))
    @test ap.suspended
    @test should_suspend(Size(8, 1), OVERLAY_MIN_SIZE)

    frame!(ap)
    # The overlay widget was never laid out on this path.
    @test region(ap.overlay) == EMPTY_REGION
    # Whatever fits, fits; the point is that it did not throw and did
    # not paint the tree.
    @test size(ap.back) == (8, 1)

    # A zero-area viewport is the degenerate case: still no throw.
    handle!(ap, ResizeEvent(Size(0, 0)))
    @test ap.suspended
    frame!(ap)
    @test frame!(ap) == 0
end

@testitem "fallback: should_suspend drives app.suspended on resize" begin
    using ManyUI

    mutable struct Leaf5 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Leaf5() = Leaf5(ManyUI.WidgetNode(type_name = :Leaf5))

    mn = Size(20, 5)
    dr = HeadlessDriver(Size(80, 24))
    ap = App(Leaf5(), dr, config = AppConfig(min_size = mn))

    for sz in (Size(80, 24), Size(20, 5), Size(19, 5), Size(20, 4),
               Size(19, 4), Size(1, 1), Size(21, 6))
        handle!(ap, ResizeEvent(sz))
        @test ap.suspended === should_suspend(sz, mn)
        @test ap.viewport == sz
    end

    # The boundary is inclusive: exactly the minimum is enough.
    handle!(ap, ResizeEvent(Size(20, 5)))
    @test !ap.suspended
end

@testitem "fallback: suspension survives the async loop" begin
    using ManyUI

    mutable struct Leaf6 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        text::String
    end
    Leaf6(t::AbstractString) =
        Leaf6(ManyUI.WidgetNode(type_name = :Leaf6), String(t))
    ManyUI.measure(w::Leaf6, avail::Size) = Size(text_width(w.text), 1)
    function ManyUI.render!(w::Leaf6, buf::AbstractMatrix{Cell})
        write_text!(buf, 1, 1, w.text)
        nothing
    end

    dr = HeadlessDriver(Size(80, 24))
    ap = App(Leaf6("CONTENT"), dr,
             config = AppConfig(min_size = Size(20, 5)))
    task = start!(ap)
    @test timedwait(() -> ap.frame >= 1, 10.0; pollint = 0.001) === :ok
    @test !ap.suspended

    resize!(dr, Size(10, 3))
    @test timedwait(() -> ap.suspended, 10.0; pollint = 0.001) === :ok

    resize!(dr, Size(80, 24))
    @test timedwait(() -> !ap.suspended, 10.0; pollint = 0.001) === :ok
    @test timedwait(() -> occursin("CONTENT", string(ap.back)), 10.0;
                    pollint = 0.001) === :ok

    quit!(ap)
    wait(ap)
    @test ap.error === nothing
end
