# widgets/progressbar.jl -- layer 7.
# May reference: widget, reactive, layout, unicode.

"""
A progress bar indicating a percentage of completion.
"""
mutable struct ProgressBar <: Widget
    "Per-widget state."
    node::WidgetNode
    "The progress value, clamped between 0.0 and 1.0; writing it marks the bar dirty."
    progress::Reactive{Float64}
end

"""
A progress bar showing `progress` (0.0 to 1.0).

`progress` is `Dirty.PAINT`-reactive, meaning it updates visually without forcing a layout recalculation.
"""
function ProgressBar(progress::Float64 = 0.0;
                     id::Symbol = gensym(:progressbar),
                     classes = Symbol[])::ProgressBar

    w = ProgressBar(WidgetNode(; id = id, classes = classes,
                               type_name = :ProgressBar),
                    Reactive(clamp(progress, 0.0, 1.0); kind = Dirty.PAINT))
    attach_reactives!(w)
    return w
end

"""
The default extent of a progress bar, `Size(10, 1)`.

Progress bars usually expand using Flex layout.
"""
measure(w::ProgressBar, avail::Size)::Size = Size(10, 1)
