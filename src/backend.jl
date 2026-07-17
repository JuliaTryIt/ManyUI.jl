# backend.jl -- one verb for "run this app", whatever the target.
#
# The Driver seam already makes targets swappable; what it does not do is
# make them swappable WITHOUT EDITING THE CALL. Compare what a user wrote
# before this file existed:
#
#     run!(App(gallery(), TerminalDriver()))            # terminal
#     server = serve(gallery; port = 8000)              # browser
#     try wait(server) finally stop!(server) end
#
# Six things differ across those two lines: an instance vs a factory, who
# constructs the App, whether the call blocks, where `stylesheet` goes,
# whether a driver type is named at all, and which config struct holds
# `title`. None of that is essential -- it is just two entry points that
# grew separately. `launch` is the one entry point:
#
#     launch(gallery)                                   # terminal
#     launch(gallery; backend = WebBackend(port = 8000))  # browser
#
# A `Backend` is a DESCRIPTION of a target, not the target itself: it is
# inert, comparable and cheap to pass around, and `make_driver` turns it
# into a live `Driver` at `launch` time. That indirection is what lets the
# web backend exist at all -- it needs ONE DRIVER PER BROWSER SESSION, so
# it cannot be handed a single pre-built driver.

"""
A description of where an app should run.

Inert on purpose: a `Backend` names a target and carries its settings, but
holds no live resource. `make_driver` turns it into a `Driver` when
`launch` needs one, which is what lets a backend mint a driver per client
rather than being handed one.

Implement a new backend with two things and nothing else:

    struct MyBackend <: DualUI.Backend end
    DualUI.make_driver(::MyBackend) = MyDriver()

If a backend ever needs more than `make_driver` to work with `launch`, the
seam has leaked -- fix the seam, do not widen the backend.

A backend whose target multiplexes -- one app per connection, as the web
does -- instead defines its own [`launch`](@ref) method and never uses
`make_driver`. See `DualUIWeb.WebBackend`.
"""
abstract type Backend end

"""
$(SIGNATURES)

A fresh [`Driver`](@ref) for `b`.

Called once per [`launch`](@ref) on the single-driver path. There is
deliberately no fallback: a `Backend` that forgets this gets a
`MethodError` naming the type, not a silent default driver writing to
somebody's terminal.
"""
function make_driver end

# --------------------------------------------------------------- terminal

"""
The real terminal: raw mode, the alt screen, a tty.

The default target, and the one `launch(factory)` picks when asked for
nothing in particular. Fields mirror [`TerminalDriver`](@ref)'s keywords;
`caps === nothing` means probe the environment.
"""
struct TerminalBackend <: Backend
    "Where input comes from."
    in_stream::IO
    "Where frames go."
    out_stream::IO
    "Forced capabilities, or `nothing` to probe."
    caps::Union{Nothing,DriverCaps}
    "Event channel depth."
    buffer::Int
    "Seconds between size polls."
    resize_poll::Float64
end

"""
$(SIGNATURES)

A [`TerminalBackend`](@ref). Every keyword is a [`TerminalDriver`](@ref)
keyword and means the same thing there.
"""
TerminalBackend(; in_stream::IO = stdin,
                  out_stream::IO = stdout,
                  caps::Union{Nothing,DriverCaps} = nothing,
                  buffer::Int = 256,
                  resize_poll::Real = 0.05)::TerminalBackend =
    TerminalBackend(in_stream, out_stream, caps, buffer, Float64(resize_poll))

"""
$(SIGNATURES)
"""
make_driver(b::TerminalBackend)::TerminalDriver =
    TerminalDriver(; in_stream = b.in_stream, out_stream = b.out_stream,
                     caps = b.caps, buffer = b.buffer,
                     resize_poll = b.resize_poll)

# --------------------------------------------------------------- headless

"""
No target at all: frames land in a buffer.

What tests and `--check` runs want. The same app code that `launch`es to a
terminal or a browser runs here with nothing attached.
"""
struct HeadlessBackend <: Backend
    "The renderable area."
    size::Size
    "Colour depth to report."
    depth::ColorDepth.T
    "Event channel depth."
    buffer::Int
end

"""
$(SIGNATURES)

A [`HeadlessBackend`](@ref) over `size`.
"""
HeadlessBackend(size::Size = Size(80, 24);
                depth::ColorDepth.T = ColorDepth.TRUECOLOR,
                buffer::Int = 256)::HeadlessBackend =
    HeadlessBackend(size, depth, buffer)

"""
$(SIGNATURES)
"""
make_driver(b::HeadlessBackend)::HeadlessDriver =
    HeadlessDriver(b.size; depth = b.depth, buffer = b.buffer)

# ----------------------------------------------------------------- launch

"""
$(SIGNATURES)

Run `factory`'s app on `backend`.

`factory` is `() -> Widget`, NOT a built widget and NOT `(driver) -> App`.
That is the whole trick: a terminal needs one app, a browser needs one app
PER CLIENT, and only a factory can serve both. Application code never
names a driver type.

    ui() = Container(Label("hello"))

    launch(ui)                                    # this terminal
    launch(ui; backend = WebBackend(port = 8000)) # a browser
    launch(ui; backend = HeadlessBackend())       # a test

`config` and `stylesheet` mean the same thing on every backend -- they
describe the APP, not the target, so they do not move house when the
backend changes. Target settings (a port, a tty) live on the backend.

With `wait = true` (the default) this blocks until the app quits and
returns its exit code, like [`run!`](@ref). With `wait = false` it returns
a handle and leaves the app running. The handle's TYPE is the backend's
business -- an `App` here, a `WebServer` for the web -- but every handle
answers the same three verbs:

    h = launch(ui; wait = false)
    isopen(h)      # still going?
    close(h)       # ask it to stop
    wait(h)        # block until it has

Returns `Int` when `wait = true`.
"""
launch(factory; backend::Backend = TerminalBackend(), kwargs...) =
    launch(factory, backend; kwargs...)

"""
$(SIGNATURES)

The single-driver path: mint one [`Driver`](@ref) from `backend`, build one
[`App`](@ref) over it, run it.

A backend that multiplexes overrides THIS method rather than
[`make_driver`](@ref).
"""
function launch(factory, backend::Backend;
                config::AppConfig = AppConfig(),
                stylesheet::Stylesheet = STYLESHEET_EMPTY,
                wait::Bool = true)
    driver = make_driver(backend)
    # Annotated so a factory that returns the wrong thing is named HERE,
    # at the boundary where user code was called, rather than surfacing
    # later as a MethodError somewhere in layout.
    root = factory()::Widget
    app = App(root, driver; config = config, stylesheet = stylesheet)
    wait || return _await_start!(app)
    return run!(app)
end

"""
$(SIGNATURES)

Start `app`'s loop and return `app` only once the loop is actually up.
Internal.

`start!` merely SPAWNS `run!`, and `run!` is what sets `app.running` --
so returning straight from `start!` hands back a handle that is
constructed but not live: `isopen` says false, and a `close` posted in the
next line races the loop into existence. `serve` has no such gap, it binds
its port before returning, and `launch` promises the same of every backend.

A loop that dies on the way up is rethrown HERE, at the launch site,
rather than left to surface later out of a task nobody is waiting on.

There is no third outcome to wait for: either `run!` reaches
`app.running = true`, or its task finishes. Both are covered, so this
cannot spin forever without a deadline.
"""
function _await_start!(app::App)::App
    t = start!(app)
    while !app.running && !istaskdone(t)
        yield()
    end
    # Finished without ever running: run! threw on the way up, and `wait`
    # is what rethrows it.
    (istaskdone(t) && !app.running) && Base.wait(t)
    return app
end
