# widgets/overlay.jl -- layer 7. X2.
#
# X2 is a WIDGET, not a special-cased branch of the painter: the
# overlay dogfoods the framework and is CSS'd like anything else. But
# below the size at which layout is meaningful, running the layout
# engine is exactly the wrong thing -- so there are two paths and a
# pure predicate to choose between them.

"""
X2. PURE predicate, so the threshold is testable with no App:

    should_suspend(Size(12, 3), Size(20, 5)) === true
    should_suspend(Size(80, 24), Size(20, 5)) === false
"""
should_suspend(actual::Size, min::Size)::Bool =
    actual.width < min.width || actual.height < min.height

"""
X2. The smallest area in which `MinSizeOverlay` can lay out. Below
this, `render_min_size_overlay!` is used instead.
"""
const OVERLAY_MIN_SIZE = Size(12, 1)

"""
The default headline. Shared by the widget and by the tree-free
fallback, so the two X2 paths cannot drift apart.
"""
const OVERLAY_MESSAGE = "Increase Terminal Size"

"""
The last thing worth saying when there is no room left to say the
headline.
"""
const OVERLAY_TINY_MESSAGE = "Too small"

"""
X2. The "Increase Terminal Size" fallback, as an ordinary widget.
"""
mutable struct MinSizeOverlay <: Widget
    "Per-widget state."
    node::WidgetNode
    "The minimum the app needs."
    required::Reactive{Size}
    "What the target currently offers."
    actual::Reactive{Size}
    "The headline message."
    message::Reactive{String}
end

"""
A fresh overlay. Its id defaults to `:_min_size_overlay` so a
stylesheet can target it.
"""
function MinSizeOverlay(; message::AbstractString = OVERLAY_MESSAGE,
                        id::Symbol = :_min_size_overlay)::MinSizeOverlay
    w = MinSizeOverlay(WidgetNode(; id = id,
                                  type_name = :MinSizeOverlay),
                       Reactive(Size(0, 0)), Reactive(Size(0, 0)),
                       Reactive(String(message)))
    attach_reactives!(w)
    return w
end

"""
The dimensions line: what the app needs against what it has. Pure.
"""
_ov_dims(required::Size, actual::Size)::String =
    string("Need ", required.width, "x", required.height, " - have ",
           actual.width, "x", actual.height)

"""
Write `line` centred on row `y`, truncated to `width`. A wide cluster
that would straddle the right edge is dropped by `truncate_width`, not
halved.
"""

"""
Write `lines` as a block centred on both axes, dropping any line that
does not fit vertically.
"""

"""
The extent of the message plus the dimensions line: the wider of the
two, by two rows. Pure with respect to the tree.
"""
function measure(w::MinSizeOverlay, avail::Size)::Size
    dims = _ov_dims(w.required[], w.actual[])
    return Size(max(text_width(w.message[]), text_width(dims)), 2)
end

"""
Paint `message` and "Need {rw}x{rh} - have {aw}x{ah}", centred.
"""

"""
X2. PURE and TREE-FREE fallback: paint the overlay directly into `buf`,
centred, BYPASSING the widget tree and the layout engine entirely.

Degrades in three steps as space runs out:

    message + dimensions  ->  message only  ->  "Too small"  ->  nothing

`buf` is cleared first, so the result is a function of its size and the
two `Size` arguments alone: the caller need not have blanked it, and
painting twice paints the same thing twice.

MUST NOT call `layout!`, `measure` or `cascade`. This is the path taken
when `buffer_size(buf)` is below `OVERLAY_MIN_SIZE` -- layout is by
definition unusable at that size.
"""
