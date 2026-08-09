# widgets/statusbar.jl -- layer 7.
# May reference: widget, reactive, richtext, layout, unicode.
#
# Three segments on one row. It is a widget rather than three `Static`s
# in a flex row for one reason: WHAT IT DROPS WHEN IT DOES NOT FIT.
# Flex would shrink all three towards nothing and leave three
# half-truncated fragments; a status bar has a priority order, and
# stating it here is the whole content of this file.

"""
A one-row bar with a left, a centre and a right segment.

Each is a `RichText`, so the parts that carry meaning can be coloured
without becoming three more nodes -- which is what a status line is
made of: a state word, a count, a hint, each in a different colour, all
on one row.

WHEN IT DOES NOT FIT, IT DROPS IN PRIORITY ORDER: the centre goes
first, then the right, and the left is truncated only when it is alone
and still too wide. A bar that shrank all three would show three
fragments and say nothing; the left segment is the one an application
puts its identity in, so it is the one that survives.
"""
mutable struct StatusBar <: Widget
    "Per-widget state."
    node::WidgetNode
    "Flush to the left edge. The last to be dropped."
    left::Reactive{RichText}
    "Centred in the full width, when there is room for it."
    center::Reactive{RichText}
    "Flush to the right edge."
    right::Reactive{RichText}
end

"""
A status bar. Each segment takes a plain string or a `RichText`.

All three are `Dirty.PAINT`-reactive: the bar is one row whatever they
say, so new text can never move it or its siblings.
"""
function StatusBar(; left::TextLike = RICHTEXT_EMPTY,
                     center::TextLike = RICHTEXT_EMPTY,
                     right::TextLike = RICHTEXT_EMPTY,
                     id::Symbol = gensym(:statusbar),
                     classes = Symbol[])::StatusBar
    w = StatusBar(WidgetNode(; id = id, classes = classes,
                             type_name = :StatusBar),
                  Reactive(convert(RichText, left); kind = Dirty.PAINT),
                  Reactive(convert(RichText, center); kind = Dirty.PAINT),
                  Reactive(convert(RichText, right); kind = Dirty.PAINT))
    attach_reactives!(w)
    return w
end

"""
The three segments, left to right.
"""
segments(w::StatusBar)::NTuple{3,RichText} =
    (w.left[], w.center[], w.right[])

"""
Where each segment goes in a bar `width` cells wide, and what is left
of it: a tuple of `(x, RichText)` for the segments that survive, in
paint order.

PURE, so the priority rule is testable with no buffer and no App --
which matters, because the rule IS the widget.

    left + right fit      -> both, flush to their edges
    centre also fits      -> centred in the FULL width, not in the gap,
                             unless that would overlap a neighbour, in
                             which case it is centred in the gap
    right does not fit    -> dropped; left keeps the row
    left alone too wide   -> truncated
"""
function status_layout(w::StatusBar, width::Int)::Vector{Tuple{Int,RichText}}
    width <= 0 && return Tuple{Int,RichText}[]
    (l, c, r) = segments(w)
    lw, cw, rw = text_width(l), text_width(c), text_width(r)

    out = Tuple{Int,RichText}[]
    # The left segment is the survivor, so it is placed first and
    # truncated only against the whole width.
    if lw > 0
        lw > width && (l = truncate_width(l, width); lw = text_width(l))
        push!(out, (1, l))
    end
    used = lw
    # The right segment needs its own width AND one cell of daylight,
    # or it reads as one word joined to the left one.
    if rw > 0 && used + rw + 1 <= width
        push!(out, (width - rw + 1, r))
        used += rw
    else
        rw = 0
    end
    if cw > 0
        # Centred in the FULL width is what a centre segment means; if
        # that collides with a neighbour, centre it in the gap instead,
        # and drop it when the gap cannot hold it.
        gap_lo = lw + (lw > 0 ? 2 : 1)
        gap_hi = width - rw - (rw > 0 ? 1 : 0)
        if gap_hi - gap_lo + 1 >= cw
            x = 1 + (width - cw) ÷ 2
            x = clamp(x, gap_lo, gap_hi - cw + 1)
            push!(out, (x, c))
        end
    end
    return out
end

"""
`Size(sum of the segments plus their gaps, 1)`.

One row, always. The width is what the bar WANTS; give it `grow` or a
`width` and `status_layout` decides what survives the width it gets.
"""
function measure(w::StatusBar, avail::Size)::Size
    (l, c, r) = segments(w)
    total = text_width(l) + text_width(c) + text_width(r)
    gaps = count(!isempty, (l, c, r))
    return Size(total + max(0, gaps - 1), 1)
end
