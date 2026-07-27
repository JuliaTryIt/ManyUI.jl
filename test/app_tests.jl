# app_tests.jl -- @testitem tests for src/app.jl.
#
# EARS covered here: 2.1 (the reactive asynchronous event loop), E2 (the
# frame cycle and its coalescing), E4 (resize relayouts the whole tree),
# X3 (an unhandled exception restores the target BEFORE the trace
# escapes), X4 (pause/resume). X2 lives in fallback_tests.jl.
#
# No test sleeps and no test needs a TTY: the loop is parameterised over
# the Driver, so `HeadlessDriver` runs it end to end.

@testitem "app: App{HeadlessDriver} is concrete" begin
    using ManyUI

    mutable struct Box1 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Box1() = Box1(ManyUI.WidgetNode(type_name = :Box1))

    dr = HeadlessDriver(Size(20, 5))
    ap = App(Box1(), dr)

    @test ap isa App{HeadlessDriver}
    @test isconcretetype(typeof(ap))
    @test isconcretetype(App{HeadlessDriver})
    @test ap isa AbstractApp
    @test fieldtype(App{HeadlessDriver}, :driver) === HeadlessDriver
end

@testitem "app: App binds itself to every node" begin
    using ManyUI

    mutable struct Box2 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Box2() = Box2(ManyUI.WidgetNode(type_name = :Box2))

    rt = Box2()
    kid = Box2()
    grandkid = Box2()
    mount!(kid, grandkid)
    mount!(rt, kid)

    dr = HeadlessDriver(Size(20, 5))
    ap = App(rt, dr)

    @test ManyUI.app(rt) === ap
    @test ManyUI.app(kid) === ap
    @test ManyUI.app(grandkid) === ap
    @test ManyUI.app(ap.overlay) === ap
    @test ap.viewport == Size(20, 5)
    @test size(ap.front) == (20, 5)
    @test size(ap.back) == (20, 5)
end

@testitem "app: frame! on a clean tree writes zero bytes" begin
    using ManyUI

    mutable struct Leaf3 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        text::String
    end
    Leaf3(t::AbstractString) =
        Leaf3(ManyUI.WidgetNode(type_name = :Leaf3), String(t))
    ManyUI.measure(w::Leaf3, avail::Size) = Size(text_width(w.text), 1)
    function ManyUI.render!(w::Leaf3, buf::AbstractMatrix{Cell})
        write_text!(buf, 1, 1, w.text)
        nothing
    end

    dr = HeadlessDriver(Size(20, 5))
    ap = App(Leaf3("hello"), dr)
    handle!(ap, ResizeEvent(Size(20, 5)))

    n1 = frame!(ap)
    @test n1 > 0
    @test occursin("hello", string(ap.back))

    # THE law: nothing changed, so nothing goes on the wire.
    @test frame!(ap) == 0
    @test frame!(ap) == 0
    @test frame!(ap) == 0
end

@testitem "app: resize relayouts entire tree" begin
    using ManyUI

    mutable struct Box4 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Box4() = Box4(ManyUI.WidgetNode(type_name = :Box4))

    leaf = Box4()
    rt = Box4()
    mount!(rt, leaf)

    dr = HeadlessDriver(Size(80, 24))
    ap = App(rt, dr)

    handle!(ap, ResizeEvent(Size(80, 24)))
    @test region(rt).width == 80
    @test region(leaf).width == 80

    # E4 is unconditional: even a perfectly clean tree is recomputed.
    walk(w -> (ManyUI.clean!(w); nothing), rt)
    @test !ManyUI.is_dirty(leaf)

    handle!(ap, ResizeEvent(Size(40, 10)))
    @test ap.viewport == Size(40, 10)
    @test region(rt).width == 40
    @test region(rt).height == 10
    @test region(leaf).width == 40
    @test size(ap.front) == (40, 10)
    @test size(ap.back) == (40, 10)
end

@testitem "app: throw restores driver before rethrow" begin
    using ManyUI

    # X3. A widget that explodes mid-frame, inside the app task.
    mutable struct Boom5 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Boom5() = Boom5(ManyUI.WidgetNode(type_name = :Boom5))
    ManyUI.measure(w::Boom5, avail::Size) = Size(1, 1)
    ManyUI.render!(w::Boom5, buf::AbstractMatrix{Cell}) =
        error("widget exploded")

    dr = HeadlessDriver(Size(20, 5))
    ap = App(Boom5(), dr)

    caught = Ref{Any}(nothing)
    restored_when_caught = Ref(false)
    try
        run!(ap)
    catch err
        # The earliest moment the trace could reach stderr is here: the
        # terminal MUST already be restored by now.
        restored_when_caught[] = dr.restored
        caught[] = err
    end

    @test restored_when_caught[]
    # The error still propagates -- it is never swallowed.
    @test caught[] isa ErrorException
    @test occursin("widget exploded", caught[].msg)
    # ... and it is recorded on the app.
    @test ap.error === caught[]
    # restore! ran, and stop! (the finally) ran after it.
    @test dr.restored
    @test !isopen(dr)
    @test !isopen(events(dr))
end

@testitem "app: restore! precedes stop! on the error path" begin
    using ManyUI

    mutable struct RecDriver6 <: ManyUI.Driver
        chan::Channel{Event}
        log::Vector{Symbol}
        sz::Size
        open::Bool
    end
    RecDriver6() = RecDriver6(Channel{Event}(64), Symbol[],
                              Size(20, 5), true)

    # `size_hint` must be typed: an untyped second argument is
    # genuinely ambiguous with driver.jl's
    # `start!(::Driver, ::Union{Nothing,Size})` fallback.
    ManyUI.start!(d::RecDriver6,
                  size_hint::Union{Nothing,Size} = nothing) =
        (push!(d.log, :start!); nothing)
    ManyUI.stop!(d::RecDriver6) = (push!(d.log, :stop!);
                                   d.open = false;
                                   isopen(d.chan) && close(d.chan);
                                   nothing)
    ManyUI.restore!(d::RecDriver6) = (push!(d.log, :restore!); nothing)
    ManyUI.emit!(d::RecDriver6, b::AbstractVector{UInt8}) = length(b)
    ManyUI.flush!(d::RecDriver6) = nothing
    ManyUI.display_size(d::RecDriver6) = d.sz
    ManyUI.capabilities(d::RecDriver6) = DriverCaps()
    ManyUI.events(d::RecDriver6) = d.chan
    Base.isopen(d::RecDriver6) = d.open

    mutable struct Boom6 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Boom6() = Boom6(ManyUI.WidgetNode(type_name = :Boom6))
    ManyUI.render!(w::Boom6, buf::AbstractMatrix{Cell}) =
        error("kaboom")

    dr = RecDriver6()
    ap = App(Boom6(), dr)

    @test_throws ErrorException run!(ap)

    @test dr.log[1] === :start!
    @test :restore! in dr.log
    @test :stop! in dr.log
    # X3: restore! sits in the catch, AHEAD of the rethrow, so it can
    # never come after the finally's stop!.
    @test findfirst(==(:restore!), dr.log) <
          findfirst(==(:stop!), dr.log)
    @test ap.error isa ErrorException
end

@testitem "app: RefreshEvent forces a full repaint" begin
    using ManyUI

    mutable struct Leaf7 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        text::String
    end
    Leaf7(t::AbstractString) =
        Leaf7(ManyUI.WidgetNode(type_name = :Leaf7), String(t))
    ManyUI.measure(w::Leaf7, avail::Size) = Size(text_width(w.text), 1)
    function ManyUI.render!(w::Leaf7, buf::AbstractMatrix{Cell})
        write_text!(buf, 1, 1, w.text)
        nothing
    end

    dr = HeadlessDriver(Size(40, 10))
    ap = App(Leaf7("hi"), dr)
    handle!(ap, ResizeEvent(Size(40, 10)))
    frame!(ap)
    clear_output!(dr)

    @test frame!(ap) == 0
    @test isempty(output(dr))

    # The channel is the only way in: a RefreshEvent, not a direct call.
    handle!(ap, RefreshEvent())
    @test ap.needs_full
    n = frame!(ap)
    @test n > 0

    out = String(take_bytes!(dr))
    @test occursin(ManyUI.Ansi.CLEAR_SCREEN, out)
    @test occursin("hi", out)
    @test !ap.needs_full
    @test frame!(ap) == 0
end

@testitem "app: pause! stops frame production" begin
    using ManyUI

    mutable struct Leaf8 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        text::String
    end
    Leaf8(t::AbstractString) =
        Leaf8(ManyUI.WidgetNode(type_name = :Leaf8), String(t))
    ManyUI.measure(w::Leaf8, avail::Size) = Size(text_width(w.text), 1)
    function ManyUI.render!(w::Leaf8, buf::AbstractMatrix{Cell})
        write_text!(buf, 1, 1, w.text)
        nothing
    end

    dr = HeadlessDriver(Size(40, 10))
    ap = App(Leaf8("hi"), dr)
    task = start!(ap)
    @test task isa Task
    @test timedwait(() -> ap.frame >= 1, 10.0; pollint = 0.001) === :ok

    pause!(ap)
    @test ap.paused
    n0 = ap.frame
    push_event!(dr, TickEvent(1.0))
    push_event!(dr, TickEvent(2.0))
    # X4: frame production stops...
    @test timedwait(() -> ap.frame > n0, 0.25;
                    pollint = 0.001) === :timed_out
    @test ap.frame == n0

    # ... but the queued events were still handled, and resume! paints.
    resume!(ap)
    @test !ap.paused
    @test timedwait(() -> ap.frame > n0, 10.0; pollint = 0.001) === :ok

    quit!(ap)
    @test timedwait(() -> !ap.running, 10.0; pollint = 0.001) === :ok
    wait(task)
end

@testitem "app: resume! implies invalidate!" begin
    using ManyUI

    mutable struct Leaf9 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        text::String
    end
    Leaf9(t::AbstractString) =
        Leaf9(ManyUI.WidgetNode(type_name = :Leaf9), String(t))
    ManyUI.measure(w::Leaf9, avail::Size) = Size(text_width(w.text), 1)
    function ManyUI.render!(w::Leaf9, buf::AbstractMatrix{Cell})
        write_text!(buf, 1, 1, w.text)
        nothing
    end

    dr = HeadlessDriver(Size(40, 10))
    ap = App(Leaf9("hi"), dr)
    handle!(ap, ResizeEvent(Size(40, 10)))
    frame!(ap)
    @test frame!(ap) == 0
    @test !ap.needs_full

    pause!(ap)
    @test ap.paused
    resume!(ap)
    @test !ap.paused
    # X4: resume! implies invalidate! -- a reattached client has a fresh
    # screen and default SGR, so the next frame must be full.
    @test ap.needs_full
    @test !ap.encoder.synced

    clear_output!(dr)
    @test frame!(ap) > 0
    @test occursin(ManyUI.Ansi.CLEAR_SCREEN, String(take_bytes!(dr)))
end

@testitem "app: burst of events coalesces into one frame" begin
    using ManyUI

    mutable struct Leaf10 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        text::String
    end
    Leaf10(t::AbstractString) =
        Leaf10(ManyUI.WidgetNode(type_name = :Leaf10), String(t))
    ManyUI.measure(w::Leaf10, avail::Size) = Size(text_width(w.text), 1)
    function ManyUI.render!(w::Leaf10, buf::AbstractMatrix{Cell})
        write_text!(buf, 1, 1, w.text)
        nothing
    end

    dr = HeadlessDriver(Size(40, 10))
    ap = App(Leaf10("hi"), dr)
    task = start!(ap)
    @test timedwait(() -> ap.frame >= 1, 10.0; pollint = 0.001) === :ok

    n0 = ap.frame
    # The app task is sticky and cannot run until this task yields, so
    # the whole burst lands in the channel before the loop wakes.
    for i in 1:8
        push_event!(dr, TickEvent(Float64(i)))
    end
    @test timedwait(() -> ap.frame > n0, 10.0; pollint = 0.001) === :ok
    @test timedwait(() -> !isready(events(dr)), 10.0;
                    pollint = 0.001) === :ok
    # Eight events in, ONE repaint out: the inner drain is the frame
    # limiter.
    @test ap.frame == n0 + 1

    quit!(ap)
    @test timedwait(() -> !ap.running, 10.0; pollint = 0.001) === :ok
    wait(task)
end

@testitem "app: key binding fires after propagation is unconsumed" begin
    using ManyUI

    mutable struct Box11 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Box11() = Box11(ManyUI.WidgetNode(type_name = :Box11))

    mutable struct Eater11 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Eater11() = Eater11(ManyUI.WidgetNode(type_name = :Eater11))
    ManyUI.on_event!(w::Eater11, d::Dispatch{KeyEvent}) =
        (consume!(d); nothing)

    dr = HeadlessDriver(Size(20, 5))
    ap = App(Box11(), dr)
    bind!(ap, "ctrl+c", :quit)
    @test ap.bindings[parse(KeyEvent, "ctrl+c")] === :quit

    ap.running = true
    handle!(ap, parse(KeyEvent, "ctrl+c"))
    @test !ap.running

    # A consumed event never reaches the bindings table.
    dr2 = HeadlessDriver(Size(20, 5))
    ap2 = App(Eater11(), dr2)
    bind!(ap2, "ctrl+c", :quit)
    ap2.running = true
    handle!(ap2, parse(KeyEvent, "ctrl+c"))
    @test ap2.running

    # An unbound key is simply ignored.
    ap2.running = true
    handle!(ap2, parse(KeyEvent, "x"))
    @test ap2.running
end

@testitem "app: focus_next follows pre-order tab order" begin
    using ManyUI

    mutable struct Box12 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Box12() = Box12(ManyUI.WidgetNode(type_name = :Box12))

    mutable struct Tab12 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Tab12(i::Symbol) = Tab12(ManyUI.WidgetNode(id = i, type_name = :Tab12,
                                               focusable = true))

    f1 = Tab12(:f1)
    f2 = Tab12(:f2)
    f3 = Tab12(:f3)
    inner = Box12()
    mount!(inner, f3)
    rt = Box12()
    mount!(rt, f1, f2, inner)

    dr = HeadlessDriver(Size(20, 5))
    ap = App(rt, dr)

    @test focused(ap) === nothing
    focus_next!(ap)
    @test focused(ap) === f1
    focus_next!(ap)
    @test focused(ap) === f2
    focus_next!(ap)
    @test focused(ap) === f3
    focus_next!(ap)
    @test focused(ap) === f1
    focus_prev!(ap)
    @test focused(ap) === f3
    focus_prev!(ap)
    @test focused(ap) === f2

    focus!(ap, f1)
    @test focused(ap) === f1
end

@testitem "app: the event loop is asynchronous over the channel" begin
    using ManyUI

    # EARS 2.1: the framework maintains a reactive ASYNCHRONOUS event
    # loop. `start!` must not block, and the driver's channel must be
    # the only way in.
    mutable struct Counter13 <: ManyUI.Widget
        node::ManyUI.WidgetNode
        seen::Vector{Char}
    end
    Counter13() = Counter13(ManyUI.WidgetNode(type_name = :Counter13),
                            Char[])
    function ManyUI.on_event!(w::Counter13, d::Dispatch{KeyEvent})
        e = event(d)
        e.code === Key.CHAR && push!(w.seen, e.char)
        nothing
    end

    rt = Counter13()
    dr = HeadlessDriver(Size(40, 10))
    ap = App(rt, dr)

    task = start!(ap)
    @test task isa Task
    @test timedwait(() -> ap.running, 10.0; pollint = 0.001) === :ok
    @test isopen(ap)

    press!(dr, "a")
    press!(dr, "b")
    @test timedwait(() -> length(rt.seen) == 2, 10.0;
                    pollint = 0.001) === :ok
    @test rt.seen == ['a', 'b']

    quit!(ap)
    @test timedwait(() -> !ap.running, 10.0; pollint = 0.001) === :ok
    wait(task)
    @test !isopen(ap)
    @test ap.error === nothing
end

@testitem "app: quit! ends the loop through the channel" begin
    using ManyUI

    mutable struct Box14 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Box14() = Box14(ManyUI.WidgetNode(type_name = :Box14))

    dr = HeadlessDriver(Size(40, 10))
    ap = App(Box14(), dr)
    task = start!(ap)
    @test timedwait(() -> ap.running, 10.0; pollint = 0.001) === :ok

    quit!(ap)
    wait(ap)
    @test istaskdone(task)
    @test !ap.running
    @test !isopen(dr)
    @test dr.restored
    @test fetch(task) == 0
end

@testitem "app: post! on a closed channel is a silent no-op" begin
    using ManyUI

    mutable struct Box15 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Box15() = Box15(ManyUI.WidgetNode(type_name = :Box15))

    dr = HeadlessDriver(Size(40, 10))
    ap = App(Box15(), dr)
    start!(dr, Size(40, 10))
    @test post!(ap, TickEvent(0.0)) === nothing
    stop!(dr)
    @test !isopen(events(dr))
    @test post!(ap, TickEvent(1.0)) === nothing
    @test refresh!(ap) === nothing
    @test quit!(ap) === nothing
end

@testitem "app: call_later! fires and its timer closes on exit" begin
    using ManyUI

    mutable struct Box16 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    Box16() = Box16(ManyUI.WidgetNode(type_name = :Box16))

    dr = HeadlessDriver(Size(40, 10))
    ap = App(Box16(), dr)
    task = start!(ap)
    @test timedwait(() -> ap.frame >= 1, 10.0; pollint = 0.001) === :ok

    fired = Ref(0)
    tm = call_later!(ap, 0.01) do a
        fired[] += 1
        nothing
    end
    @test tm isa Timer
    @test tm in ap.timers
    @test timedwait(() -> fired[] == 1, 10.0; pollint = 0.001) === :ok

    ticks = Ref(0)
    iv = set_interval!(ap, 0.005) do a
        ticks[] += 1
        nothing
    end
    @test iv in ap.timers
    @test timedwait(() -> ticks[] >= 3, 10.0; pollint = 0.001) === :ok

    quit!(ap)
    wait(ap)
    # Timers are owned by the app and closed on exit.
    @test !isopen(tm)
    @test !isopen(iv)
end

@testitem "app: AppConfig defaults and overrides" begin
    using ManyUI

    c = AppConfig()
    @test c.min_size == Size(20, 5)
    @test c.diff_gap == 4
    @test c.esc_timeout == 0.05
    @test c.title == "ManyUI"
    @test c.sync_frames

    c2 = AppConfig(min_size = Size(40, 10), diff_gap = 0,
                   title = "app", sync_frames = false)
    @test c2.min_size == Size(40, 10)
    @test c2.diff_gap == 0
    @test c2.title == "app"
    @test !c2.sync_frames
    @test isbits(c2.min_size)
end
