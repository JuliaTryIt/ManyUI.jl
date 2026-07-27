# driver_tests.jl -- the Driver seam (driver.jl) and the native TUI
# target (terminal.jl).
#
# NO test in this file may require a TTY, and none may flip the real
# terminal into raw mode: every driver is built over an `IOBuffer`.

@testitem "driver: DriverCaps is isbits" begin
    using ManyUI

    @test isbitstype(DriverCaps)
    @test isconcretetype(DriverCaps)
end

@testitem "driver: DriverCaps keyword constructor matches the field order" begin
    using ManyUI

    c = DriverCaps()
    @test c.color_depth === ColorDepth.TRUECOLOR
    @test c.mouse
    @test c.bracketed_paste
    @test c.focus_events
    @test c.alt_screen
    @test !c.title
    @test c.unicode
    @test c.sync_output

    # Every keyword must land in its own field, so spell them all out
    # with a value distinct from the default.
    d = DriverCaps(color_depth = ColorDepth.ANSI16,
                   mouse = false,
                   bracketed_paste = false,
                   focus_events = false,
                   alt_screen = false,
                   title = true,
                   unicode = false,
                   sync_output = false)
    @test d === DriverCaps(ColorDepth.ANSI16, false, false, false,
                           false, true, false, false)

    # One keyword at a time: nothing bleeds into a neighbour.
    @test DriverCaps(mouse = false) ===
          DriverCaps(ColorDepth.TRUECOLOR, false, true, true, true,
                     false, true, true)
    @test DriverCaps(title = true) ===
          DriverCaps(ColorDepth.TRUECOLOR, true, true, true, true,
                     true, true, true)

    @test CAPS_MINIMAL === DriverCaps(color_depth = ColorDepth.ANSI16,
                                      mouse = false,
                                      bracketed_paste = false,
                                      focus_events = false,
                                      alt_screen = false,
                                      title = false,
                                      unicode = false,
                                      sync_output = false)
end

@testitem "driver: REQUIRED_DRIVER_METHODS has nine entries" begin
    using ManyUI

    @test length(REQUIRED_DRIVER_METHODS) == 9
    @test REQUIRED_DRIVER_METHODS ===
          (:start!, :stop!, :restore!, :emit!, :flush!, :display_size,
           :capabilities, :events, :isopen)
    @test allunique(REQUIRED_DRIVER_METHODS)
end

@testitem "driver: check_driver_interface finds gaps" begin
    using ManyUI

    struct GapDriver <: ManyUI.Driver end

    @test check_driver_interface(GapDriver) ==
          collect(REQUIRED_DRIVER_METHODS)

    mutable struct AlmostDriver <: ManyUI.Driver
        ch::Channel{ManyUI.Event}
    end
    ManyUI.start!(::AlmostDriver, ::Union{Nothing,Size} = nothing) = nothing
    ManyUI.stop!(::AlmostDriver) = nothing
    ManyUI.restore!(::AlmostDriver) = nothing
    ManyUI.emit!(::AlmostDriver, b::AbstractVector{UInt8}) = length(b)
    ManyUI.display_size(::AlmostDriver) = Size(80, 24)
    ManyUI.capabilities(::AlmostDriver) = CAPS_MINIMAL
    ManyUI.events(d::AlmostDriver) = d.ch
    Base.isopen(d::AlmostDriver) = isopen(d.ch)
    # `flush!` deliberately left out.

    @test check_driver_interface(AlmostDriver) == [:flush!]

    ManyUI.flush!(::AlmostDriver) = nothing
    @test check_driver_interface(AlmostDriver) == Symbol[]
end

@testitem "driver: check_driver_interface accepts the shipped drivers" begin
    using ManyUI

    @test check_driver_interface(HeadlessDriver) == Symbol[]
    @test check_driver_interface(TerminalDriver) == Symbol[]
end

@testitem "driver: an unimplemented seam throws DriverInterfaceError" begin
    using ManyUI

    struct BareDriver <: ManyUI.Driver end
    d = BareDriver()

    for f in (start!, stop!, restore!, flush!, display_size,
              capabilities, events)
        @test_throws DriverInterfaceError f(d)
    end
    @test_throws DriverInterfaceError emit!(d, UInt8[0x61])
    @test_throws DriverInterfaceError isopen(d)

    e = try
        flush!(d)
    catch err
        err
    end
    @test e isa DriverInterfaceError
    @test e.driver === BareDriver
    @test e.method === :flush!
    msg = sprint(showerror, e)
    @test occursin("BareDriver", msg)
    @test occursin("does not implement ManyUI.flush!", msg)
end

@testitem "driver: Base.close forwards to stop!" begin
    using ManyUI

    mutable struct CloseDriver <: ManyUI.Driver
        stopped::Int
    end
    ManyUI.stop!(d::CloseDriver) = (d.stopped += 1; nothing)

    d = CloseDriver(0)
    close(d)
    @test d.stopped == 1
    close(d)
    @test d.stopped == 2
end

@testitem "driver: negative invariant holds" begin
    using ManyUI

    # 2.1 / U3. A Driver moves bytes, reports a size and capabilities,
    # and yields events. If any required method mentions a render-path
    # type in its signature, the abstraction has leaked and ManyUIWeb
    # can no longer implement it from outside.
    banned = (ManyUI.Buffer, ManyUI.BufferView, ManyUI.Patch,
              ManyUI.Span, ManyUI.Widget, ManyUI.Region,
              ManyUI.LayoutBox, ManyUI.LayoutMap, ManyUI.Style,
              ManyUI.Cell)

    leaks = Tuple{Symbol,Any}[]
    for name in REQUIRED_DRIVER_METHODS
        f = name === :isopen ? Base.isopen : getfield(ManyUI, name)
        for m in methods(f)
            sig = Base.unwrap_unionall(m.sig)
            params = sig.parameters
            length(params) >= 2 || continue
            first = params[2]
            first isa Type || continue
            first <: ManyUI.Driver || continue
            for p in params[2:end]
                p isa Type || continue
                p === Any && continue
                for b in banned
                    p <: b && push!(leaks, (name, p))
                end
            end
        end
    end
    @test leaks == Tuple{Symbol,Any}[]
end

@testitem "driver: notify_resize! default puts a ResizeEvent" begin
    using ManyUI

    # 2.2. A SIGWINCH poll, a web control frame and a test harness all
    # funnel through this one door.
    mutable struct NotifyDriver <: ManyUI.Driver
        ch::Channel{ManyUI.Event}
    end
    ManyUI.events(d::NotifyDriver) = d.ch

    d = NotifyDriver(Channel{ManyUI.Event}(4))
    @test notify_resize!(d, Size(100, 30)) === nothing
    e = take!(d.ch)
    @test e isa ResizeEvent
    @test e.size === Size(100, 30)
end

@testitem "driver: a foreign driver needs only the nine methods" begin
    using ManyUI

    # 2.1. THE seam test. `TapeDriver` stands in for ManyUIWeb's
    # `WebSocketDriver`: an in-memory driver that captures every emitted
    # byte into a buffer and feeds input bytes back through the shared
    # pump. It is written using ONLY names in `WEB_BRIDGE_SURFACE` --
    # it reaches into no ManyUI internal, and it never mentions a
    # Buffer, Patch, Widget or Region.
    mutable struct TapeDriver <: ManyUI.Driver
        const ch::Channel{ManyUI.Event}
        const sink::IOBuffer
        const parser::InputParser
        size::Size
        caps::DriverCaps
        started::Bool
        restored::Bool
    end
    TapeDriver(sz::Size) = TapeDriver(Channel{ManyUI.Event}(64),
                                      IOBuffer(), InputParser(), sz,
                                      DriverCaps(), false, false)

    ManyUI.start!(d::TapeDriver, hint::Union{Nothing,Size} = nothing) =
        (hint === nothing || (d.size = hint); d.started = true; nothing)
    ManyUI.stop!(d::TapeDriver) =
        (close(d.ch); ManyUI.restore!(d); nothing)
    ManyUI.restore!(d::TapeDriver) = (d.restored = true; nothing)
    ManyUI.emit!(d::TapeDriver, b::AbstractVector{UInt8}) =
        Int(write(d.sink, b))
    ManyUI.flush!(::TapeDriver) = nothing
    ManyUI.display_size(d::TapeDriver) = d.size
    ManyUI.capabilities(d::TapeDriver) = d.caps
    ManyUI.events(d::TapeDriver) = d.ch
    Base.isopen(d::TapeDriver) = isopen(d.ch)

    d = TapeDriver(Size(80, 24))
    @test check_driver_interface(TapeDriver) == Symbol[]

    # start!'s size_hint spares a foreign target one wrong frame.
    start!(d, Size(100, 30))
    @test display_size(d) === Size(100, 30)
    @test isopen(d)

    # Bytes out land in the buffer verbatim -- no tty anywhere.
    @test emit!(d, codeunits("\e[1;1Hxy")) == 8
    flush!(d)
    @test String(take!(d.sink)) == "\e[1;1Hxy"

    # Bytes in go through the ONE shared pump, so a foreign driver
    # inherits the whole input grammar for free.
    n = pump_input!(d.parser, events(d), codeunits("a\e[A"))
    @test n == 2
    @test take!(events(d)) == key('a')
    @test take!(events(d)) == key(Key.UP)

    # Out-of-band resize uses the same door as everything else.
    notify_resize!(d, Size(40, 12))
    @test take!(events(d)) == ResizeEvent(Size(40, 12))

    stop!(d)
    @test !isopen(d)
    @test d.restored
end

@testitem "driver: ManyUI has no HTTP dependency" begin
    using ManyUI

    # Invariant 1, as a diff anyone can check.
    path = joinpath(pkgdir(ManyUI), "Project.toml")
    src = read(path, String)
    deps = split(src, "[deps]")[2]
    deps = split(deps, "\n[")[1]
    for banned in ("HTTP", "Sockets", "JSON3")
        @test !occursin(Regex("^\\s*$banned\\s*=", "m"), deps)
    end
    @test occursin("REPL", deps)
end

@testitem "terminal: detect_caps color depth follows detect_color_depth" begin
    using ManyUI

    truecolor = Dict("TERM" => "xterm", "COLORTERM" => "truecolor")
    c256 = Dict("TERM" => "xterm-256color")
    dumb = Dict("TERM" => "dumb")
    unset = Dict{String,String}()

    # The rule table, direct.
    @test detect_color_depth(truecolor) === ColorDepth.TRUECOLOR
    @test detect_color_depth(Dict("COLORTERM" => "24bit")) ===
          ColorDepth.TRUECOLOR
    @test detect_color_depth(c256) === ColorDepth.ANSI256
    @test detect_color_depth(dumb) === ColorDepth.MONOCHROME
    @test detect_color_depth(unset) === ColorDepth.MONOCHROME
    @test detect_color_depth(Dict("TERM" => "xterm")) ===
          ColorDepth.ANSI16
    @test detect_color_depth(Dict("NO_COLOR" => "",
                                  "COLORTERM" => "truecolor")) ===
          ColorDepth.MONOCHROME

    # ... and the same table as seen through the driver's caps, which
    # is the SOLE input to X1's degradation.
    @test detect_caps(truecolor).color_depth === ColorDepth.TRUECOLOR
    @test detect_caps(c256).color_depth === ColorDepth.ANSI256
    @test detect_caps(dumb).color_depth === ColorDepth.MONOCHROME
    @test detect_caps(unset).color_depth === ColorDepth.MONOCHROME
end

@testitem "terminal: detect_caps rule table" begin
    using ManyUI

    # TERM == dumb or unset: every optional feature is off, title is on.
    for env in (Dict("TERM" => "dumb"), Dict{String,String}())
        c = detect_caps(env)
        @test !c.alt_screen
        @test !c.mouse
        @test !c.bracketed_paste
        @test !c.focus_events
        @test !c.sync_output
        @test c.title
    end

    c = detect_caps(Dict("TERM" => "xterm-256color"))
    @test c.alt_screen
    @test c.mouse
    @test c.bracketed_paste
    @test c.focus_events
    @test c.sync_output
    @test c.title

    # unicode tracks LANG / LC_ALL.
    @test detect_caps(Dict("TERM" => "xterm",
                           "LANG" => "en_US.UTF-8")).unicode
    @test detect_caps(Dict("TERM" => "xterm",
                           "LC_ALL" => "fr_FR.UTF-8")).unicode
    @test detect_caps(Dict("TERM" => "xterm",
                           "LANG" => "en_US.utf8")).unicode
    @test !detect_caps(Dict("TERM" => "xterm", "LANG" => "C")).unicode
    @test !detect_caps(Dict("TERM" => "xterm")).unicode

    # Pure: it reads the dict it is handed and no global.
    @test detect_caps(Dict("TERM" => "dumb")) ===
          detect_caps(Dict("TERM" => "dumb"))
end

@testitem "terminal: conforms to the driver interface" begin
    using ManyUI

    @test TerminalDriver <: ManyUI.Driver
    @test check_driver_interface(TerminalDriver) == Symbol[]

    d = TerminalDriver(in_stream = IOBuffer(), out_stream = IOBuffer(),
                       caps = CAPS_MINIMAL)
    @test capabilities(d) === CAPS_MINIMAL
    @test events(d) isa Channel{ManyUI.Event}
    @test isopen(d)
    @test display_size(d) isa Size

    # A driver built with no caps probes the environment.
    d2 = TerminalDriver(in_stream = IOBuffer(), out_stream = IOBuffer())
    @test capabilities(d2) isa DriverCaps
end

@testitem "terminal: emit! buffers and flush! commits" begin
    using ManyUI

    out = IOBuffer()
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = CAPS_MINIMAL)

    @test emit!(d, codeunits("abc")) == 3
    @test emit!(d, codeunits("de")) == 2
    # flush! is the commit point: nothing is on the wire before it.
    @test isempty(take!(out))

    @test flush!(d) === nothing
    @test String(take!(out)) == "abcde"

    # A flush! with an empty staging buffer writes nothing.
    flush!(d)
    @test isempty(take!(out))
end

@testitem "terminal: start! emits alt screen then hide cursor" begin
    using ManyUI

    # 2.3 (S2). The alternate screen keeps the user's scrollback
    # intact; the order is part of the contract.
    out = IOBuffer()
    caps = DriverCaps(title = true)
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = caps, resize_poll = 3600.0)
    try
        start!(d)
        got = String(take!(out))
        @test got == string(ManyUI.Ansi.ALT_SCREEN_ENTER,
                            ManyUI.Ansi.CURSOR_HIDE,
                            ManyUI.Ansi.MOUSE_ON,
                            ManyUI.Ansi.PASTE_ON,
                            ManyUI.Ansi.FOCUS_ON)
        @test d.alt
        @test d.mouse_on
        @test d.started

        # Idempotent: a second start! is silent.
        start!(d)
        @test isempty(take!(out))
    finally
        stop!(d)
    end
end

@testitem "terminal: caps gate every optional sequence" begin
    using ManyUI

    out = IOBuffer()
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = CAPS_MINIMAL, resize_poll = 3600.0)
    try
        start!(d)
        got = String(take!(out))
        # CAPS_MINIMAL has no alt screen, mouse, paste or focus: only
        # the unconditional cursor hide goes out.
        @test got == ManyUI.Ansi.CURSOR_HIDE
        @test !d.alt
        @test !d.mouse_on
    finally
        stop!(d)
    end
end

@testitem "terminal: alt screen entered and left in order" begin
    using ManyUI

    # 2.3 (S2) + 2.5. restore! is the EXACT reverse of start!: leaving
    # the alternate screen before showing the cursor would strand an
    # invisible cursor on the user's shell.
    out = IOBuffer()
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = DriverCaps(), resize_poll = 3600.0)
    start!(d)
    take!(out)
    restore!(d)

    got = String(take!(out))
    @test got == string(ManyUI.Ansi.FOCUS_OFF,
                        ManyUI.Ansi.PASTE_OFF,
                        ManyUI.Ansi.MOUSE_OFF,
                        ManyUI.Ansi.CURSOR_SHOW,
                        ManyUI.Ansi.ALT_SCREEN_EXIT)
    @test !d.alt
    @test !d.mouse_on
    @test d.restored

    # The whole point of the ordering, stated as an assertion.
    @test findfirst(ManyUI.Ansi.CURSOR_SHOW, got).start <
          findfirst(ManyUI.Ansi.ALT_SCREEN_EXIT, got).start
    stop!(d)
end

@testitem "terminal: start! enters raw, restore! exits" begin
    using ManyUI

    # 2.3 (S1). Raw mode is REQUESTED here; the OS toggle is a no-op on
    # an IOBuffer, which is exactly why no test needs a tty. `d.raw`
    # tracks the requested mode, so restore! always undoes what start!
    # asked for.
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = IOBuffer(),
                       caps = CAPS_MINIMAL, resize_poll = 3600.0)
    @test !d.raw
    start!(d)
    @test d.raw
    restore!(d)
    @test !d.raw
    stop!(d)
end

@testitem "terminal: set_raw! never throws on a non-tty" begin
    using ManyUI

    # REPL.Terminals.raw! reaches for a libuv handle; an IOBuffer has
    # none. It must degrade to a false return, never an exception --
    # otherwise the whole suite would need a tty.
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = IOBuffer(),
                       caps = CAPS_MINIMAL)
    @test set_raw!(d, true) === false
    @test d.raw
    @test set_raw!(d, false) === false
    @test !d.raw
end

@testitem "terminal: restore! is idempotent" begin
    using ManyUI

    out = IOBuffer()
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = DriverCaps(), resize_poll = 3600.0)
    start!(d)
    take!(out)

    @test restore!(d) === nothing
    first = take!(out)
    @test !isempty(first)

    # 2.5: restore! runs from a catch, from a finally AND from atexit.
    # The second and third calls must be silent no-ops.
    @test restore!(d) === nothing
    @test isempty(take!(out))
    @test restore!(d) === nothing
    @test isempty(take!(out))
    @test d.restored
    stop!(d)
end

@testitem "terminal: restore! on a driver that never started is a no-op" begin
    using ManyUI

    out = IOBuffer()
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = DriverCaps())
    @test restore!(d) === nothing
    @test isempty(take!(out))
end

@testitem "terminal: restore! runs every step despite a throw" begin
    using ManyUI

    # 2.5. THE crash-safety requirement. Every step must run even when
    # an earlier one throws, and restore! itself must never throw --
    # it is called from inside a `catch`, before the rethrow.
    out = IOBuffer()
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = DriverCaps(), resize_poll = 3600.0)
    start!(d)
    @test d.raw

    # Sabotage the staging buffer: now EVERY sequence-writing step of
    # restore! (focus off, paste off, mouse off, show cursor, leave alt)
    # throws.
    close(d.outbuf)
    @test_throws ArgumentError write(d.outbuf, 0x61)

    @test restore!(d) === nothing          # never throws
    @test !d.raw                           # step 6 ran after 5 throws
    @test d.restored                       # the loop completed
    stop!(d)                               # also must not throw
end

@testitem "terminal: restore! survives a throwing out_stream" begin
    using ManyUI

    mutable struct DeadOut <: IO
        writes::Int
    end
    Base.write(o::DeadOut, ::UInt8) = (o.writes += 1; error("pipe gone"))
    Base.unsafe_write(o::DeadOut, ::Ptr{UInt8}, ::UInt) =
        (o.writes += 1; error("pipe gone"))
    Base.flush(::DeadOut) = error("pipe gone")
    Base.displaysize(::DeadOut) = (24, 80)

    out = DeadOut(0)
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = DriverCaps(), resize_poll = 3600.0)
    d.started = true
    @test restore!(d) === nothing
    @test d.restored
    @test out.writes > 0
end

@testitem "terminal: displaysize rows cols are swapped into Size" begin
    using ManyUI

    # `displaysize` is (rows, cols); `Size` is (width, height). This is
    # a known off-by-orientation trap, so it gets its own test.
    inner = IOBuffer()
    out = IOContext(inner, :displaysize => (30, 100))
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = CAPS_MINIMAL, resize_poll = 3600.0)
    try
        start!(d)
        @test display_size(d) === Size(100, 30)
        @test display_size(d).width == 100
        @test display_size(d).height == 30
    finally
        stop!(d)
    end
end

@testitem "terminal: start! honours a size_hint" begin
    using ManyUI

    inner = IOBuffer()
    out = IOContext(inner, :displaysize => (30, 100))
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = CAPS_MINIMAL, resize_poll = 3600.0)
    try
        start!(d, Size(40, 12))
        @test display_size(d) === Size(40, 12)
        @test take!(events(d)) == ResizeEvent(Size(40, 12))
    finally
        stop!(d)
    end
end

@testitem "terminal: start! posts an initial ResizeEvent" begin
    using ManyUI

    # 2.2. The app never special-cases its first frame: the size
    # arrives through the same door a SIGWINCH would use.
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = IOBuffer(),
                       caps = CAPS_MINIMAL, resize_poll = 3600.0)
    try
        start!(d)
        e = take!(events(d))
        @test e isa ResizeEvent
        @test e.size === display_size(d)
        @test e.size === Size(80, 24)
    finally
        stop!(d)
    end
end

@testitem "terminal: notify_resize! updates the cached size" begin
    using ManyUI

    # 2.2. The one seam a SIGWINCH poll, a signal handler and a web
    # control frame all share.
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = IOBuffer(),
                       caps = CAPS_MINIMAL, resize_poll = 3600.0)
    @test notify_resize!(d, Size(120, 40)) === nothing
    @test display_size(d) === Size(120, 40)
    @test take!(events(d)) == ResizeEvent(Size(120, 40))
end

@testitem "terminal: the resize poll pushes a ResizeEvent on a change" begin
    using ManyUI

    # 2.2. The SIGWINCH source. Julia 1.12 exposes no async-signal-safe
    # SIGWINCH hook, so the driver polls -- but it funnels through
    # `notify_resize!`, so the app cannot tell the difference.
    inner = IOBuffer()
    out = IOContext(inner, :displaysize => (30, 100))
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = CAPS_MINIMAL, resize_poll = 0.001)
    d.size = Size(80, 24)          # stale: the terminal just grew
    d.started = true

    # A watchdog turns a hang into a failure. No `sleep` in the test.
    guard = Timer(_ -> close(events(d)), 10.0)
    task = @async ManyUI._resize_loop!(d)
    try
        e = take!(events(d))
        @test e isa ResizeEvent
        @test e.size === Size(100, 30)
        @test display_size(d) === Size(100, 30)
    finally
        close(guard)
        isopen(events(d)) && close(events(d))
        wait(task)
    end
    @test istaskdone(task)
end

@testitem "terminal: the reader loop pumps tty bytes into events" begin
    using ManyUI

    # The byte source is an IOBuffer, but the path is the production
    # one: readavailable -> pump_input! -> the channel.
    d = TerminalDriver(in_stream = IOBuffer("hi\e[B"),
                       out_stream = IOBuffer(), caps = CAPS_MINIMAL)
    @test ManyUI._reader_loop!(d) === nothing
    @test take!(events(d)) == key('h')
    @test take!(events(d)) == key('i')
    @test take!(events(d)) == key(Key.DOWN)
end

@testitem "terminal: set_title! is gated on caps.title" begin
    using ManyUI

    out = IOBuffer()
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = DriverCaps(title = true))
    @test set_title!(d, "app") === nothing
    flush!(d)
    @test String(take!(out)) == ManyUI.Ansi.title("app")

    quiet = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                           caps = DriverCaps(title = false))
    @test set_title!(quiet, "app") === nothing
    flush!(quiet)
    @test isempty(take!(out))
end

@testitem "terminal: stop! closes the channel and restores" begin
    using ManyUI

    out = IOBuffer()
    d = TerminalDriver(in_stream = IOBuffer(), out_stream = out,
                       caps = DriverCaps(), resize_poll = 3600.0)
    start!(d)
    @test isopen(d)

    @test stop!(d) === nothing
    @test !isopen(d)
    @test !isopen(events(d))
    @test d.restored
    @test !d.raw
    @test !d.alt

    # Idempotent, and it must not throw the second time either.
    @test stop!(d) === nothing
    @test !isopen(d)
end
