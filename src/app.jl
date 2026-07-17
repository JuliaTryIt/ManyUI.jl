# app.jl -- layer 8. May reference: everything above.
# E1-E4, X2, X3, U3.

"""
Knobs that do not change while an app runs.
"""
struct AppConfig
    "X2. Below this, rendering suspends and the overlay shows."
    min_size::Size
    "E2. Unchanged cells tolerated inside one span."
    diff_gap::Int
    "Seconds a lone ESC waits before resolving to the Escape key."
    esc_timeout::Float64
    "Window title, when the target has one."
    title::String
    "Wrap each frame in synchronised-output markers."
    sync_frames::Bool
end

"""
Config with the documented defaults.
"""
AppConfig(; min_size::Size = Size(20, 5),
            diff_gap::Int = 4,
            esc_timeout::Float64 = 0.05,
            title::AbstractString = "DualUI",
            sync_frames::Bool = true)::AppConfig =
    AppConfig(min_size, diff_gap, esc_timeout, String(title),
              sync_frames)

"""
The event loop, the render pipeline and the tree, bound to one driver.

Parametric on the driver: `App{TerminalDriver}` and
`App{WebSocketDriver}` are separate CONCRETE types, so `emit!`,
`flush!`, `events` and `capabilities` all statically dispatch inside the
hot loop. Zero dynamic dispatch per frame from the driver seam -- and it
holds ACROSS the package boundary.
"""
mutable struct App{D<:Driver} <: AbstractApp
    "The rendering target."
    const driver::D
    "The widget tree."
    const root::Widget
    "X2. Shown instead of `root` while suspended."
    const overlay::MinSizeOverlay
    "Immutable knobs."
    const config::AppConfig
    "X1. Owns the color depth and the cross-frame SGR state."
    const encoder::AnsiEncoder
    "The active stylesheet."
    stylesheet::Stylesheet
    "The last painted frame."
    front::Buffer
    "The frame being painted."
    back::Buffer
    "The focused widget, or `nothing`."
    focus::Union{Nothing,Widget}
    "The open popup painted over the tree, or `nothing`."
    popup::Union{Nothing,Popup}
    "Key to action name."
    const bindings::Dict{KeyEvent,Symbol}
    "The current renderable area."
    viewport::Size
    "False ends the loop."
    running::Bool
    "X4. True stops frame production; events still queue."
    paused::Bool
    "X2. True while the overlay is showing."
    suspended::Bool
    "Forces the next diff to be a full repaint."
    needs_full::Bool
    "Frames painted so far."
    frame::Int
    "The error that ended the loop, if any."
    error::Union{Nothing,Exception}
    "Timers owned by this app; closed on exit."
    const timers::Vector{Timer}
end

"""
The task currently running each App's loop.

`App` has no task field -- it is a fixed, contract-owned struct shared
with `DualUIWeb` -- so `start!` records its task here and `wait(::App)`
reads it back. Weak keys: a collected App takes its entry with it.
"""
const _APP_TASKS = WeakKeyDict{AbstractApp,Task}()

"""
Remember the task running `app`'s loop. Internal.
"""
function _register_task!(app::App, t::Task)::Nothing
    _APP_TASKS[app] = t
    return nothing
end

"""
The task running `app`'s loop, or `nothing` when it is not running.
Internal.
"""
_app_task(app::App)::Union{Nothing,Task} = get(_APP_TASKS, app, nothing)

"""
An app over `root` and `driver`. Sets `node(w).app` on every node via
`walk`.
"""
function App(root::Widget, driver::D;
             config::AppConfig = AppConfig(),
             stylesheet::Stylesheet = STYLESHEET_EMPTY,
             overlay::MinSizeOverlay = MinSizeOverlay()) where {D<:Driver}
    caps = capabilities(driver)
    vp = display_size(driver)
    enc = AnsiEncoder(caps.color_depth;
                      sync_frames = config.sync_frames &&
                                    caps.sync_output)
    a = App{D}(driver, root, overlay, config, enc, stylesheet,
               Buffer(vp), Buffer(vp), nothing, nothing,
               Dict{KeyEvent,Symbol}(), vp, false, false,
               should_suspend(vp, config.min_size), true, 0, nothing,
               Timer[])
    walk(root) do w
        node(w).app = a
        nothing
    end
    walk(overlay) do w
        node(w).app = a
        nothing
    end
    return a
end

"""
Blocking. Runs to completion; returns an exit code (0 is clean).

X3 -- the exception path, VERBATIM. Implement exactly this shape:

    function run!(app::App)
        start!(app.driver, app.viewport)
        try
            _bootstrap!(app)
            _loop!(app)
        catch err
            app.error = err
            restore!(app.driver)   # X3: BEFORE the error escapes
            rethrow()              # trace reaches stderr uncorrupted
        finally
            for t in app.timers; close(t); end
            stop!(app.driver)      # idempotent; no-op after restore!
        end
        return app.error === nothing ? 0 : 1
    end

`restore!` sits in the `catch`, AHEAD of `rethrow()`, so by the time
Julia's default handler prints the backtrace to stderr, raw mode is off
and the main screen is back -- the trace is readable instead of a
staircase. `stop!` in the `finally` covers the normal path. Both are
idempotent, so a double restore is safe.

The one refinement: `err` is wrapped when it is not an `Exception`, so
recording it can never itself throw and mask the original.
"""
function run!(app::App)::Int
    _register_task!(app, current_task())
    start!(app.driver, app.viewport)
    try
        _bootstrap!(app)
        _loop!(app)
    catch err
        app.error = err isa Exception ? err : ErrorException(string(err))
        restore!(app.driver)
        rethrow()
    finally
        app.running = false
        for t in app.timers
            close(t)
        end
        stop!(app.driver)
    end
    return app.error === nothing ? 0 : 1
end

"""
2.1. The reactive asynchronous event loop.

Channels, with burst coalescing as the frame limiter: the task BLOCKS on
`take!` and the OS scheduler does the rest -- no timer, no fixed FPS, no
busy-wait. A resize storm or a 10 kB paste drains through the inner
`isready` loop and collapses into ONE repaint for free.

A closed channel ends the loop cleanly; anything else a handler throws
propagates to `run!`, which restores the target before it escapes.
Internal.
"""
function _loop!(app::App)::Nothing
    ch = events(app.driver)
    while app.running && isopen(ch)
        e = _take_event(ch)
        e === nothing && break
        handle!(app, e)
        while isready(ch)                # drain the burst, paint once
            e2 = _take_event(ch)
            e2 === nothing && break
            handle!(app, e2)
        end
        app.paused || frame!(app)
    end
    return nothing
end

"""
`take!(ch)`, or `nothing` once the driver has closed the channel.

A shutdown is not a crash: only `InvalidStateException` is absorbed, so
a channel closed with a cause still propagates. Internal.
"""
function _take_event(ch::Channel{Event})::Union{Nothing,Event}
    try
        return take!(ch)
    catch err
        err isa InvalidStateException && return nothing
        rethrow()
    end
end

"""
Bring the app up: cascade, size, focus, and paint the first frame.

The cascade runs BEFORE the first layout because `BoxStyle` is the
cascade's output and the layout engine's input. Internal.
"""
function _bootstrap!(app::App)::Nothing
    app.running = true
    apply_stylesheet!(app.stylesheet, app.root)
    capabilities(app.driver).title &&
        set_title!(app.driver, app.config.title)
    handle!(app, ResizeEvent(display_size(app.driver)))
    app.focus === nothing && focus_next!(app)
    invalidate!(app)
    app.paused || frame!(app)
    return nothing
end

"""
Non-blocking: spawn `run!` and return its task.
"""
function start!(app::App)::Task
    t = @async run!(app)
    _register_task!(app, t)
    return t
end

"""
Ask the loop to stop, by posting a `QuitEvent`.
"""
quit!(app::App)::Nothing = post!(app, QuitEvent())

"""
Forward to `quit!`.

`launch` promises that whatever handle it returns answers `isopen`, `close`
and `wait`, so that a caller can stop an app without knowing which backend
produced it. `WebServer` already closes; this is the `App` half of that
promise. Idempotent, because `post!` on a finished app is a no-op rather
than an error.
"""
Base.close(app::App)::Nothing = quit!(app)

"""
Stop the loop and record `code`.

`App` carries no exit-code field, only `error`, and `run!` returns
`error === nothing ? 0 : 1`. A non-zero `code` is therefore recorded as
the error that ended the loop, which is what makes `run!` report it.
"""
function exit!(app::App, code::Int = 0)::Nothing
    if code != 0 && app.error === nothing
        app.error = ErrorException("exit: code $code")
    end
    post!(app, QuitEvent())
    app.running = false
    return nothing
end

"""
Block until the loop has finished.

Re-throws whatever ended the loop, wrapped in a `TaskFailedException`,
exactly as `wait` on the task would. Returns immediately when the app
was never started.
"""
function Base.wait(app::App)::Nothing
    t = _app_task(app)
    t === nothing && return nothing
    wait(t)
    return nothing
end

"""
True while the loop is running.
"""
Base.isopen(app::App)::Bool = app.running

"""
Inject an event from ANYWHERE -- tests, worker tasks, drivers,
`Reactive`. Never blocks: a closed channel is a silent no-op.
"""
function post!(app::App, e::Event)::Nothing
    ch = events(app.driver)
    isopen(ch) || return nothing
    try
        put!(ch, e)
    catch err
        err isa InvalidStateException || rethrow()
    end
    return nothing
end

"""
Call `f(app)` once after `delay` seconds. Returns the timer, which the
app closes on exit.

A `TickEvent` follows `f`, so the loop wakes and repaints whatever `f`
changed without forcing a full frame.
"""
function call_later!(f, app::App, delay::Real)::Timer
    t = Timer(Float64(delay))
    push!(app.timers, t)
    @async begin
        try
            wait(t)
            f(app)
            post!(app, TickEvent(time()))
        catch err
            err isa EOFError || rethrow()   # closed on exit: expected
        finally
            close(t)
        end
    end
    return t
end

"""
Call `f(app)` every `period` seconds. Returns the timer, which the app
closes on exit.
"""
function set_interval!(f, app::App, period::Real)::Timer
    p = Float64(period)
    t = Timer(p; interval = p)
    push!(app.timers, t)
    @async begin
        try
            while isopen(t)
                wait(t)
                f(app)
                post!(app, TickEvent(time()))
            end
        catch err
            err isa EOFError || rethrow()   # closed on exit: expected
        end
    end
    return t
end

"""
Force the next diff to be a FULL repaint: `reset!(app.encoder)` AND
discard `app.front`.

Both are required -- discarding the front buffer alone leaves the
encoder believing it last emitted bold on a client whose SGR is
default.

INTERNAL to the App: external callers post a `RefreshEvent` instead, so
the channel remains the only way in.
"""
function invalidate!(app::App)::Nothing
    reset!(app.encoder)
    app.front = Buffer(app.viewport)
    app.needs_full = true
    return nothing
end

"""
X4. Explicit loop pause: stops FRAME PRODUCTION. Queued events still
accumulate and are handled on `resume!`.

Target-agnostic -- a loop pause is not a web concept, and DualUIWeb
calls it on socket drop. This REPLACES any scheme where a bounded
output channel implicitly stalls the loop via a blocking `put!`: that
is untestable, and one bounded channel away from deadlock.
"""
function pause!(app::App)::Nothing
    app.paused = true
    return nothing
end

"""
X4. Resume frame production. Implies `invalidate!(app)`.

Also posts a `RefreshEvent`, because a resumed loop is asleep on `take!`
and something has to wake it.
"""
function resume!(app::App)::Nothing
    app.paused = false
    invalidate!(app)
    post!(app, RefreshEvent())
    return nothing
end

"""
Fallback: route `e` through `dispatch_event!`.
"""
function handle!(app::App, e::Event)::Nothing
    dispatch_event!(app.root, e, app.focus)
    return nothing
end

"""
E3. Propagate, then -- if unconsumed -- look up `app.bindings`, then
`on_action` up the focus chain, then the app defaults.
"""
function handle!(app::App, e::KeyEvent)::Nothing
    dispatch_event!(app.root, e, app.focus) && return nothing
    action = get(app.bindings, e, nothing)
    action === nothing && return nothing
    _run_action!(app, action)
    return nothing
end

"""
Run `action` up the focus chain, then fall back to the app defaults.
True iff something handled it. Internal.
"""
function _run_action!(app::App, action::Symbol)::Bool
    v = Val(action)
    w = app.focus
    while w !== nothing
        on_action(w, v) && return true
        w = parent(w)
    end
    return on_action(app, v)
end

"""
E3. Route to `hit_test`, falling back to the root.
"""
function handle!(app::App, e::MouseEvent)::Nothing
    # A popup is a modal-ish layer: it is hit-tested BEFORE the tree, and a
    # press outside it dismisses it and is swallowed. `_popup_dismiss!`
    # returns true when it has taken the event; only then is the tree
    # spared. See popup_ops.jl.
    if app.popup !== nothing && _popup_dismiss!(app, e)
        return nothing
    end
    dispatch_event!(app.root, e, app.focus)
    return nothing
end

"""
E4 + X2. Normative:

    function handle!(app::App, e::ResizeEvent)
        app.viewport = e.size
        app.front = Buffer(e.size)     # forces a full diff
        app.back  = Buffer(e.size)
        reset!(app.encoder)
        app.suspended =
            should_suspend(e.size, app.config.min_size)   # X2
        if !app.suspended
            vp = Region(e.size)
            layout!(app.root, vp)   # E4: ENTIRE tree, unconditional
            mark_subtree_dirty!(app.root, Dirty.PAINT)
        end
        nothing
    end

`needs_full` is set alongside the discarded buffers: after a resize the
target's own grid has been reflowed by the terminal, so "a full diff"
must reach the wire as a full patch (CLEAR_SCREEN + SGR reset), not as
a diff against a blank front buffer that happens to agree cell for cell.
"""
function handle!(app::App, e::ResizeEvent)::Nothing
    app.viewport = e.size
    app.front = Buffer(e.size)         # forces a full diff
    app.back = Buffer(e.size)
    reset!(app.encoder)
    app.needs_full = true
    app.suspended = should_suspend(e.size, app.config.min_size)   # X2
    if !app.suspended
        vp = Region(e.size)
        layout!(app.root, vp)          # E4: ENTIRE tree, unconditional
        mark_subtree_dirty!(app.root, Dirty.PAINT)
    end
    return nothing
end

"""
Route to the focused widget, falling back to the root.
"""
function handle!(app::App, e::PasteEvent)::Nothing
    dispatch_event!(app.root, e, app.focus)
    return nothing
end

"""
Route to the root.
"""
function handle!(app::App, e::FocusEvent)::Nothing
    dispatch_event!(app.root, e)
    return nothing
end

"""
Route to the root.
"""
function handle!(app::App, e::TickEvent)::Nothing
    dispatch_event!(app.root, e)
    return nothing
end

"""
Not routed: calls `invalidate!(app)`.
"""
function handle!(app::App, e::RefreshEvent)::Nothing
    invalidate!(app)
    return nothing
end

"""
Not routed: sets `app.running = false`.
"""
function handle!(app::App, e::QuitEvent)::Nothing
    app.running = false
    return nothing
end

"""
E2 + X2. One turn of the pipeline; impure only at the last step.
Returns BYTES WRITTEN.

    1. Dirty.STYLE  -> recascade!(app.stylesheet, app.root)      E1/U4
    2. Dirty.LAYOUT -> relayout!(app.root, Region(app.viewport))  E1/U2
    3. fill!(app.back, CELL_BLANK); paint!(app.back, app.root)    U1
       (or the X2 overlay -- step 3')
    4. p = diff(app.front, app.back; gap = app.config.diff_gap)   E2
    5. bytes = encode(app.encoder, p)  -- degrades to depth       X1
    6. emit!(driver, bytes); flush!(driver)                       U3
    7. copyto!(app.front, app.back); app.frame += 1

Step 3' (X2): when `app.suspended`,

  * if `buffer_size(app.back) >= OVERLAY_MIN_SIZE`, drive the
    `MinSizeOverlay` widget (set `required`/`actual`, `layout!` it
    against the viewport, `paint!` it), so it is CSS-able;
  * else call `render_min_size_overlay!(app.back, app.viewport,
    app.config.min_size)` -- tree-free, no layout.

Either way steps 4-7 run normally: the overlay costs no special path
downstream, it is just a different Buffer.

Steps 1 and 2 are skipped entirely while suspended -- X2 says SUSPEND
standard rendering, and `recascade!`/`relayout!` are no-ops on a clean
tree anyway.

LAW: `frame!` on a clean, unchanged tree returns 0.
"""
function frame!(app::App)::Int
    if !app.suspended
        recascade!(app.stylesheet, app.root)                   # 1
        relayout!(app.root, Region(app.viewport))              # 2
    end
    fill!(app.back, CELL_BLANK)                                # 3
    if app.suspended
        _paint_overlay!(app)                                   # 3'
    else
        paint!(app.back, app.root)
        # 3''. The popup paints OVER the tree, the same slot the min-size
        # overlay uses, but only when one is open. See popup_ops.jl.
        app.popup === nothing || _paint_popup!(app)
    end
    p = app.needs_full ? full_patch(app.back) :
        diff(app.front, app.back; gap = app.config.diff_gap)   # 4
    bytes = encode(app.encoder, p)                             # 5
    n = emit!(app.driver, bytes)                               # 6
    flush!(app.driver)
    copyto!(app.front.cells, app.back.cells)                   # 7
    app.needs_full = false
    app.frame += 1
    return n
end

"""
X2, step 3'. Paint the "Increase Terminal Size" fallback into
`app.back`.

Two paths, chosen by the pure `should_suspend` predicate against
`OVERLAY_MIN_SIZE`: the overlay is an ordinary widget wherever layout
is meaningful, and a tree-free painter where it is not. Internal.
"""
function _paint_overlay!(app::App)::Nothing
    if should_suspend(buffer_size(app.back), OVERLAY_MIN_SIZE)
        render_min_size_overlay!(app.back, app.viewport,
                                 app.config.min_size)
        return nothing
    end
    ov = app.overlay
    ov.required[] = app.config.min_size
    ov.actual[] = app.viewport
    recascade!(app.stylesheet, ov)
    layout!(ov, Region(app.viewport))
    paint!(app.back, ov)
    return nothing
end

"""
Ask for a full repaint through the channel.
"""
refresh!(app::App)::Nothing = post!(app, RefreshEvent())

"""
The focused widget, or `nothing`. Pure.
"""
focused(app::App)::Union{Nothing,Widget} = app.focus

"""
Move focus to `w`: `on_blur!` the old, `on_focus!` the new.
"""
function focus!(app::App, w::Widget)::Nothing
    old = app.focus
    old === w && return nothing
    old === nothing || on_blur!(old)
    app.focus = w
    on_focus!(w)
    return nothing
end

"""
Focus the next widget in tab order -- the pre-order walk.
"""
function focus_next!(app::App)::Nothing
    ws = focusable_widgets(app.root)
    isempty(ws) && return nothing
    cur = app.focus
    i = cur === nothing ? 0 :
        something(findfirst(w -> w === cur, ws), 0)
    focus!(app, ws[mod1(i + 1, length(ws))])
    return nothing
end

"""
Focus the previous widget in tab order.
"""
function focus_prev!(app::App)::Nothing
    ws = focusable_widgets(app.root)
    isempty(ws) && return nothing
    cur = app.focus
    i = cur === nothing ? 1 :
        something(findfirst(w -> w === cur, ws), 1)
    focus!(app, ws[mod1(i - 1, length(ws))])
    return nothing
end

"""
Bind a key description, e.g. `bind!(app, "ctrl+c", :quit)`.
"""
bind!(app::App, key::AbstractString, action::Symbol)::Nothing =
    bind!(app, parse(KeyEvent, key), action)

"""
Bind a parsed key.
"""
function bind!(app::App, key::KeyEvent, action::Symbol)::Nothing
    app.bindings[key] = action
    return nothing
end

"""
Val-dispatched action handler on a widget; returns true iff handled.
Default false.
"""
function on_action(w::Widget, ::Val{A})::Bool where {A}
    false
end

"""
Val-dispatched action handler on the app; returns true iff handled.

App-level defaults: `:quit`, `:focus_next`, `:focus_prev`, `:refresh`.
One dynamic dispatch per keypress -- irrelevant next to a repaint.
"""
function on_action(app::App, ::Val{A})::Bool where {A}
    if A === :quit
        app.running = false
        return true
    elseif A === :focus_next
        focus_next!(app)
        return true
    elseif A === :focus_prev
        focus_prev!(app)
        return true
    elseif A === :refresh
        invalidate!(app)
        return true
    end
    return false
end
