# widgets/progressbar.jl -- layer 7.
# May reference: widget, reactive, layout, unicode.

"""
What a LABELLED bar folds over its filled span.

`REVERSE` rather than a colour: the caption is written across the whole
bar, so the boundary has to stay legible THROUGH the text, and
reversing does that whatever the theme has made the two colours.
"""
const PROGRESS_FILL = Style(; reverse = true)

"""
A progress bar indicating a percentage of completion.
"""
mutable struct ProgressBar <: Widget
    "Per-widget state."
    node::WidgetNode
    "The progress value, clamped between 0.0 and 1.0; writing it marks the bar dirty."
    progress::Reactive{Float64}
    """
    Text drawn ACROSS the bar, centred, or empty for none. A labelled
    bar is what other toolkits call a gauge; it is a field here rather
    than a second widget, because a `Gauge` would differ from this by
    exactly one of them.

    `Dirty.PAINT`: `measure` does not read it, so a new label cannot
    move the bar.
    """
    label::Reactive{RichText}
end

"""
A progress bar showing `progress` (0.0 to 1.0), optionally
captioned by `label` drawn across it.

`progress` is `Dirty.PAINT`-reactive, meaning it updates visually without forcing a layout recalculation.
"""
function ProgressBar(progress::Float64 = 0.0;
                     label::TextLike = RICHTEXT_EMPTY,
                     id::Symbol = gensym(:progressbar),
                     classes = Symbol[])::ProgressBar

    w = ProgressBar(WidgetNode(; id = id, classes = classes,
                               type_name = :ProgressBar),
                    Reactive(clamp(progress, 0.0, 1.0); kind = Dirty.PAINT),
                    Reactive(convert(RichText, label); kind = Dirty.PAINT))
    attach_reactives!(w)
    return w
end

"""
How many of `width` cells are filled at the bar's current progress.

Pure, so the split is testable without a buffer, and shared by both
render paths so a labelled and an unlabelled bar can never disagree
about where the boundary is.
"""
progress_cells(w::ProgressBar, width::Int)::Int =
    clamp(round(Int, w.progress[] * width), 0, max(0, width))

"""
The default extent of a progress bar, `Size(10, 1)`.

Progress bars usually expand using Flex layout.
"""
measure(w::ProgressBar, avail::Size)::Size = Size(10, 1)
