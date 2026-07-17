# headless.jl -- layer 6. May reference: driver, input, events, ansi,
# color, geometry.
#
# THE proof the seam is right. It ships in DualUI, and every DualUI test
# and every DualUIWeb test uses it. If `HeadlessDriver` needs nothing
# from DualUI internals, neither does `WebSocketDriver`. No test in
# either suite requires a TTY.

"""
A driver with no target at all: bytes go to an `IOBuffer`, events come
from whatever a test pushes.
"""
mutable struct HeadlessDriver <: Driver
    "The App's only input."
    const chan::Channel{Event}
    "Everything ever emitted."
    const sink::IOBuffer
    "Shared byte parser, so fed bytes behave exactly as on a TTY."
    const parser::InputParser
    "Current renderable area."
    size::Size
    "What this fake target claims to do."
    caps::DriverCaps
    "False once stopped."
    open::Bool
    "True between `start!` and `stop!`."
    started::Bool
    "True once `restore!` has run."
    restored::Bool
end

"""
A headless driver of `size`, claiming `depth` and an event channel of
capacity `buffer`.
"""
HeadlessDriver(size::Size = Size(80, 24);
               depth::ColorDepth.T = ColorDepth.TRUECOLOR,
               buffer::Int = 256)::HeadlessDriver =
    HeadlessDriver(Channel{Event}(buffer), IOBuffer(), InputParser(),
                   size, DriverCaps(; color_depth = depth), true, false,
                   false)

"""
Mark the driver started; adopt `size_hint` when given. Idempotent.
"""
function start!(d::HeadlessDriver,
                size_hint::Union{Nothing,Size} = nothing)::Nothing
    size_hint === nothing || (d.size = size_hint)
    d.started = true
    return nothing
end

"""
Close the event channel and `restore!`. Idempotent.
"""
function stop!(d::HeadlessDriver)::Nothing
    d.started = false
    d.open = false
    isopen(d.chan) && close(d.chan)
    restore!(d)
    return nothing
end

"""
X3. Nothing to undo, but it still records that it ran, and it never
throws. Idempotent.
"""
function restore!(d::HeadlessDriver)::Nothing
    d.restored = true
    return nothing
end

"""
Append `b` to the sink; returns the number of bytes accepted.
"""
emit!(d::HeadlessDriver, b::AbstractVector{UInt8})::Int = write(d.sink, b)

"""
A no-op: the sink is always current.
"""
flush!(d::HeadlessDriver)::Nothing = nothing

"""
The current renderable area.
"""
display_size(d::HeadlessDriver)::Size = d.size

"""
What this fake target claims to do.
"""
capabilities(d::HeadlessDriver)::DriverCaps = d.caps

"""
The event channel.
"""
events(d::HeadlessDriver)::Channel{Event} = d.chan

"""
True while the driver can still deliver events.
"""
Base.isopen(d::HeadlessDriver)::Bool = d.open && isopen(d.chan)

"""
Test affordance: put `e` on the channel.
"""
function push_event!(d::HeadlessDriver, e::Event)::Nothing
    isopen(d.chan) || return nothing
    try
        put!(d.chan, e)
    catch err
        # Closed between the check and the put!: dropping the event is
        # what a detached target does, and a test tearing down is not a
        # failure.
        err isa InvalidStateException || rethrow()
    end
    return nothing
end

"""
Test affordance: drain the sink and return everything emitted.
"""
take_bytes!(d::HeadlessDriver)::Vector{UInt8} = take!(d.sink)

"""
Test affordance: peek at the sink without draining it. Pure.
"""
output(d::HeadlessDriver)::Vector{UInt8} =
    copy(view(d.sink.data, 1:d.sink.size))

"""
Test affordance: discard everything emitted so far.
"""
function clear_output!(d::HeadlessDriver)::Nothing
    take!(d.sink)
    return nothing
end

"""
Test affordance: inject `parse(KeyEvent, key)`.
"""
press!(d::HeadlessDriver, key::AbstractString)::Nothing =
    push_event!(d, parse(KeyEvent, key))

"""
Test affordance: inject one `Key.CHAR` event per grapheme of `s`.
"""
function type!(d::HeadlessDriver, s::AbstractString)::Nothing
    for g in Unicode.graphemes(s)
        # `KeyEvent.char` is one `Char`, so a multi-codepoint cluster is
        # carried by its base codepoint. Tests needing the exact byte
        # fidelity of a real keystroke use `feed_bytes!` instead.
        push_event!(d, key(first(g)))
    end
    return nothing
end

"""
Test affordance: inject a press at the absolute 1-based cell `(x, y)`.
"""
click!(d::HeadlessDriver, x::Int, y::Int;
       button::MouseButton.T = MouseButton.LEFT)::Nothing =
    push_event!(d, MouseEvent(MouseAction.PRESS, button, x, y, MOD_NONE))

"""
Test affordance: set the size AND call `notify_resize!`.
"""
function resize!(d::HeadlessDriver, sz::Size)::Nothing
    d.size = sz
    notify_resize!(d, sz)
    return nothing
end

"""
Test affordance: push raw bytes through `pump_input!` -- the same pump
a TTY and a web socket use.
"""
feed_bytes!(d::HeadlessDriver, b::AbstractVector{UInt8})::Int =
    pump_input!(d.parser, d.chan, b)
