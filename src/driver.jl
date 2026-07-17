# driver.jl -- layer 4. May reference: types, geometry, color, events.
# U3: THE contract that makes DualUIWeb possible. NINE methods.
#
# NORMATIVE NEGATIVE INVARIANT: no method in REQUIRED_DRIVER_METHODS
# accepts or returns a Buffer, BufferView, Patch, Span, Widget, Region,
# LayoutBox, LayoutMap, Style or Cell. A driver moves bytes, reports a
# size and capabilities, and yields events. If DualUIWeb ever needs a
# tenth method, the abstraction has leaked and the fix is to reshape the
# seam -- not to reach inside. This invariant is a @testitem, not a
# comment.

"""
What a rendering target can do. `isbits`.

`color_depth` is the SOLE input to X1's degradation: the App asks the
DRIVER, never `ENV`.
"""
struct DriverCaps
    "Deepest color the target can show."
    color_depth::ColorDepth.T
    "Target reports mouse events."
    mouse::Bool
    "Target brackets pastes."
    bracketed_paste::Bool
    "Target reports focus in/out."
    focus_events::Bool
    "Target has an alternate screen buffer."
    alt_screen::Bool
    "Target has a settable window title."
    title::Bool
    "Target renders non-ASCII graphemes."
    unicode::Bool
    "Target honours synchronised output (2026h/2026l)."
    sync_output::Bool
end

"""
Keyword constructor with the documented defaults.
"""
DriverCaps(; color_depth::ColorDepth.T = ColorDepth.TRUECOLOR,
             mouse::Bool = true,
             bracketed_paste::Bool = true,
             focus_events::Bool = true,
             alt_screen::Bool = true,
             title::Bool = false,
             unicode::Bool = true,
             sync_output::Bool = true)::DriverCaps =
    DriverCaps(color_depth, mouse, bracketed_paste, focus_events,
               alt_screen, title, unicode, sync_output)

# Spelled positionally so it is correct independently of the keyword
# constructor above.
const CAPS_MINIMAL = DriverCaps(ColorDepth.ANSI16, false, false, false,
                                false, false, false, false)

"""
A driver type is missing one of the nine required methods.
"""
struct DriverInterfaceError <: Exception
    "The offending driver type."
    driver::DataType
    "The required method it does not implement."
    method::Symbol
end

"""
Report the driver type and the missing method by name, so a
half-implemented driver fails with "WebSocketDriver does not implement
DualUI.flush!" rather than with a MethodError soup.
"""
Base.showerror(io::IO, e::DriverInterfaceError)::Nothing =
    print(io, e.driver, " does not implement DualUI.", e.method)

"""
Acquire the target: raw mode, alternate screen, socket attach. Spawn
any reader tasks. IDEMPOTENT.

After this returns, `events(d)` yields and `display_size(d)` is
authoritative.

`size_hint` lets a caller that already knows the size -- a web HELLO
carries cols/rows -- avoid one wrong frame per session.
"""
start!(d::Driver, size_hint::Union{Nothing,Size} = nothing)::Nothing =
    throw(DriverInterfaceError(typeof(d), :start!))

"""
Graceful shutdown, the exact reverse of `start!`: stop tasks, close the
event channel, then `restore!`. Idempotent. MAY throw.
"""
stop!(d::Driver)::Nothing = throw(DriverInterfaceError(typeof(d), :stop!))

"""
Forward to `stop!`.
"""
Base.close(d::Driver)::Nothing = stop!(d)

"""
X3. The crash path: return the target to its pre-`start!` state.

MUST be idempotent. MUST NOT throw -- it runs inside a `catch`, inside a
`finally`, and from `atexit`. Swallow, and never mask the original
error.
"""
restore!(d::Driver)::Nothing = throw(DriverInterfaceError(typeof(d), :restore!))

"""
Queue encoded ANSI bytes; returns the number accepted. May buffer --
`flush!` is the commit point.

MUST NOT block indefinitely: a detached driver DISCARDS, and the App
forces a full repaint on reattach via `RefreshEvent`.
"""
emit!(d::Driver, bytes::AbstractVector{UInt8})::Int =
    throw(DriverInterfaceError(typeof(d), :emit!))

"""
Ensure everything `emit!`ted is on its way. The end of a frame.

MUST NOT block indefinitely, and MUST NOT be used as a pause mechanism.
"""
flush!(d::Driver)::Nothing = throw(DriverInterfaceError(typeof(d), :flush!))

"""
The current renderable area, in cells.
"""
display_size(d::Driver)::Size =
    throw(DriverInterfaceError(typeof(d), :display_size))

"""
What this target can do.
"""
capabilities(d::Driver)::DriverCaps =
    throw(DriverInterfaceError(typeof(d), :capabilities))

"""
THE integration point, and the App's ONLY input.

The driver owns the channel, fills it from whatever it likes -- TTY
bytes, web frames, a test harness -- and closes it on `stop!`.
"""
events(d::Driver)::Channel{Event} =
    throw(DriverInterfaceError(typeof(d), :events))

"""
True while the driver can still deliver events.
"""
Base.isopen(d::Driver)::Bool = throw(DriverInterfaceError(typeof(d), :isopen))

"""
Set the window title. Optional: the default is a no-op.
"""
set_title!(d::Driver, s::AbstractString)::Nothing = nothing

"""
E4. THE uniform out-of-band resize seam.

A SIGWINCH handler, a poll task, and a web `{"t":"resize"}` control
frame ALL funnel through here, so E4 needs zero web-specific code.

Override only to also update a cached size.
"""
function notify_resize!(d::Driver, sz::Size)::Nothing
    put!(events(d), ResizeEvent(sz))
    nothing
end

"""
The nine methods every `Driver` must implement. Counted, not asserted.
"""
const REQUIRED_DRIVER_METHODS = (:start!, :stop!, :restore!, :emit!,
                                 :flush!, :display_size, :capabilities,
                                 :events, :isopen)

"""
The required method names `D` fails to implement; an empty vector means
conformant.

Exported for downstream test suites, so a bridge package can PROVE it
implements the interface without reading DualUI's source:

    @test check_driver_interface(WebSocketDriver) == Symbol[]
"""
function check_driver_interface(::Type{D})::Vector{Symbol} where {D<:Driver}
    gaps = Symbol[]
    for name in REQUIRED_DRIVER_METHODS
        f = name === :isopen ? Base.isopen : getfield(@__MODULE__, name)
        _implements_driver_method(f, D) || push!(gaps, name)
    end
    return gaps
end

"""
True when `f` has a method whose FIRST argument is a driver type more
specific than `Driver` itself, and `D` satisfies it.

Deliberately arity-agnostic: it inspects the method table rather than
calling `which`, so a driver that widens an optional argument (say
`start!(d::MyDriver, hint = nothing)`) still counts as an implementor
and no ambiguity against the `Driver` fallback can produce a false
negative. Pure. Internal.
"""
function _implements_driver_method(f, ::Type{D})::Bool where {D<:Driver}
    for m in methods(f)
        sig = Base.unwrap_unionall(m.sig)
        params = sig.parameters
        length(params) >= 2 || continue
        t = params[2]
        t isa Type || continue
        # The `::Driver` fallback is the thing we are looking past.
        (t === Driver || t === Any) && continue
        D <: t && return true
    end
    return false
end

"""
The complete set of DualUI names a bridge package is permitted to use.

A DualUIWeb `@testitem` asserts that every `DualUI.<name>` occurring in
`DualUIWeb/src` is a member. That turns "a tenth method means the
abstraction leaked" from an honour-system norm into a checkable
artifact.
"""
const WEB_BRIDGE_SURFACE = (
    :Driver, :DriverCaps, :CAPS_MINIMAL, :Event, :Size,
    :ResizeEvent, :RefreshEvent, :QuitEvent, :ColorDepth,
    :InputParser, :pump_input!, :notify_resize!,
    :start!, :stop!, :restore!, :emit!, :flush!,
    :display_size, :capabilities, :events,
    :App, :AppConfig, :Widget, :Stylesheet,
    :run!, :quit!, :pause!, :resume!, :post!,
    :check_driver_interface, :REQUIRED_DRIVER_METHODS,
    # `Ansi` is here because setup is part of a driver's job, not a
    # framework internal: a terminal reports mouse only once the
    # application ASKS, so a driver that never emits `Ansi.MOUSE_ON`
    # has no mouse -- which is exactly what `WebSocketDriver` shipped
    # with until a click was tried in an actual browser. `TerminalDriver`
    # emits the same constants for the same reason; withholding them
    # from a bridge driver does not protect an internal, it just makes
    # the two targets behave differently.
    :Ansi,
)
