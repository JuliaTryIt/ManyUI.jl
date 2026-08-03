# widgets/spinner.jl -- layer 7.
# May reference: widget, reactive, layout, unicode, events.

"""
A spinner indicating a loading or indeterminate process.
Advances its animation frame on `TickEvent`.
"""
mutable struct Spinner <: Widget
    "Per-widget state."
    node::WidgetNode
    "Animation frames."
    const frames::Vector{String}
    "The current frame index, 1-based."
    tick::Reactive{Int}
end

"""
A spinner with the given `frames`.
"""
function Spinner(frames::Vector{String} = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
                 id::Symbol = gensym(:spinner),
                 classes = Symbol[])::Spinner
    w = Spinner(WidgetNode(; id = id, classes = classes,
                           type_name = :Spinner),
                frames,
                Reactive(1; kind = Dirty.PAINT))
    attach_reactives!(w)
    return w
end

"""
A spinner is 1x1 cell by default.
"""
measure(w::Spinner, avail::Size)::Size = Size(1, 1)

"""
Advance the spinner on each tick.
"""
function on_event!(w::Spinner, d::Dispatch{TickEvent})::Nothing
    w.tick[] = mod1(w.tick[] + 1, length(w.frames))
    return nothing
end
