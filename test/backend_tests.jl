# backend_tests.jl -- the Backend seam and `launch`.
#
# The point of `launch` is that ONE call runs an app on any target, so the
# tests that matter are the ones that pin the parts a user would otherwise
# have to change by hand: who calls the factory, how many times, what the
# handle protocol is, and whether an out-of-tree Backend can join without
# touching ManyUI. ManyUIWeb's WebBackend is exactly such an out-of-tree
# backend, so the custom-backend testitem below is the standing proof that
# it can exist.

@testitem "backend: TerminalBackend and HeadlessBackend are Backends" begin
    using ManyUI

    @test TerminalBackend <: Backend
    @test HeadlessBackend <: Backend
    @test TerminalBackend() isa Backend
    @test HeadlessBackend() isa Backend
end

@testitem "backend: make_driver builds the right Driver" begin
    using ManyUI

    d = ManyUI.make_driver(HeadlessBackend(Size(40, 8)))
    @test d isa HeadlessDriver
    @test display_size(d) == Size(40, 8)

    # A TerminalDriver over pipes rather than a real tty: the point is the
    # TYPE, not that it can find a terminal.
    t = ManyUI.make_driver(TerminalBackend(; in_stream = IOBuffer(),
                                             out_stream = IOBuffer(),
                                             caps = CAPS_MINIMAL))
    @test t isa TerminalDriver
    @test capabilities(t) == CAPS_MINIMAL
end

@testitem "backend: make_driver has no fallback" begin
    using ManyUI

    struct UnimplementedBackend <: ManyUI.Backend end
    # A Backend that forgets make_driver must fail loudly, not silently
    # produce a default driver on someone's terminal.
    @test_throws MethodError ManyUI.make_driver(UnimplementedBackend())
end

@testitem "backend: launch(wait = false) returns a live App" begin
    using ManyUI

    app = launch(() -> Container(Label("hi"));
                 backend = HeadlessBackend(Size(40, 8)), wait = false)
    try
        @test app isa App
        @test app.driver isa HeadlessDriver
        @test isopen(app)
    finally
        close(app)
        wait(app)
    end
    @test !isopen(app)
end

@testitem "backend: launch calls the factory exactly once" begin
    using ManyUI

    calls = Ref(0)
    factory = () -> (calls[] += 1; Container(Label("x")))
    app = launch(factory; backend = HeadlessBackend(), wait = false)
    try
        @test calls[] == 1
    finally
        close(app)
        wait(app)
    end
end

@testitem "backend: launch(wait = true) blocks and returns an exit code" begin
    using ManyUI

    # The blocking path hands back no handle -- that IS the contract -- so
    # queue the QuitEvent BEFORE launching and let the loop find it on its
    # first pass. Returns like run!: 0 for a clean exit.
    struct PrebuiltBackend <: ManyUI.Backend
        driver::HeadlessDriver
    end
    ManyUI.make_driver(b::PrebuiltBackend) = b.driver

    d = HeadlessDriver(Size(20, 5))
    push_event!(d, QuitEvent())
    code = launch(() -> Container(Label("bye"));
                  backend = PrebuiltBackend(d), wait = true)
    @test code isa Int
    @test code == 0
end

@testitem "backend: launch(wait = false) returns a handle that is already live" begin
    using ManyUI

    # The bug this pins: start! only SPAWNS run!, and run! is what sets
    # app.running -- so a launch that returned straight from start! handed
    # back a handle whose isopen was still false, and whose close raced the
    # loop into existence. No sleep here on purpose: if the wait is real,
    # isopen is true on the very next line, every time.
    for _ in 1:25
        app = launch(() -> Container(Label("x"));
                     backend = HeadlessBackend(), wait = false)
        try
            @test isopen(app)
        finally
            close(app)
            wait(app)
        end
    end
end

@testitem "backend: launch threads config and stylesheet through" begin
    using ManyUI

    sheet = parse_css("label { color: red; }")
    cfg = AppConfig(; title = "launched", min_size = Size(11, 3))
    app = launch(() -> Container(Label("x"; id = :l));
                 backend = HeadlessBackend(), config = cfg,
                 stylesheet = sheet, wait = false)
    try
        @test app.config.title == "launched"
        @test app.config.min_size == Size(11, 3)
        @test app.stylesheet === sheet
    finally
        close(app)
        wait(app)
    end
end

@testitem "backend: an out-of-tree Backend needs only make_driver" begin
    using ManyUI

    # This is ManyUIWeb's situation in miniature: a Backend defined outside
    # ManyUI, joining by dispatch alone. If this testitem ever needs a
    # second method to pass, the seam has leaked.
    struct FakeBackend <: ManyUI.Backend
        size::Size
    end
    ManyUI.make_driver(b::FakeBackend) = HeadlessDriver(b.size)

    app = launch(() -> Container(Label("out of tree"));
                 backend = FakeBackend(Size(30, 5)), wait = false)
    try
        @test app isa App
        @test display_size(app.driver) == Size(30, 5)
    finally
        close(app)
        wait(app)
    end
end

@testitem "backend: close(app) is the uniform stop verb" begin
    using ManyUI

    # `launch` promises the handle answers wait/close/isopen whatever the
    # backend is. WebServer already does; App has to learn `close`.
    app = launch(() -> Container(Label("x"));
                 backend = HeadlessBackend(), wait = false)
    @test isopen(app)
    close(app)
    wait(app)
    @test !isopen(app)
    # Idempotent: a second close on a dead app is not an error.
    @test close(app) === nothing
end

@testitem "backend: a factory returning a non-Widget is rejected" begin
    using ManyUI

    # The factory is user code called deep inside launch; a wrong return
    # should name the problem rather than fail later as a MethodError in
    # the layout engine.
    @test_throws TypeError launch(() -> "not a widget";
                                  backend = HeadlessBackend(), wait = false)
end
