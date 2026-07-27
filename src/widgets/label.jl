# widgets/label.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode.
#
# S3 lives or dies here: both widgets measure and paint through
# `text_width` / `wrap_width` / `write_text!`, never through
# `Base.textwidth` and never by codepoint. A wide cluster that would
# straddle the right edge is moved to the next line or refused, never
# halved.

"""
Wrapping text. `measure` wraps to `avail.width` via `wrap_width`.
"""
mutable struct Label <: Widget
    "Per-widget state."
    node::WidgetNode
    "The text; writing it marks the label dirty."
    text::Reactive{String}
end

"""
A label showing `text`.

`text` is `Dirty.LAYOUT`-reactive: new text wraps differently, so it
can change the label's extent and therefore its siblings' positions.
"""
function Label(text::AbstractString; id::Symbol = gensym(:label),
               classes = Symbol[])::Label
    w = Label(WidgetNode(; id = id, classes = classes,
                         type_name = :Label),
              Reactive(String(text)))
    attach_reactives!(w)
    return w
end

"""
The wrapped extent of the text at `avail.width`: the widest wrapped
line by the number of lines. Pure with respect to the tree.

`Size(0, 0)` when there is no text or no width -- a label that cannot
be laid out is empty, not an error.
"""
function measure(w::Label, avail::Size)::Size
    lines = wrap_width(w.text[], avail.width)
    isempty(lines) && return Size(0, 0)
    widest = 0
    for line in lines
        widest = max(widest, text_width(line))
    end
    return Size(widest, length(lines))
end

"""
Paint the wrapped text into the content box.

`buf`'s `(1, 1)` IS the content origin and its size IS the content box,
so wrapping to `size(buf)[1]` wraps to the width layout actually
granted -- which may be less than `measure` asked for.
"""
function render!(w::Label, buf::AbstractMatrix{Cell})::Nothing
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    st = computed_style(w)
    y = 1
    for line in wrap_width(w.text[], width)
        y > height && break
        write_text!(buf, 1, y, line, st)
        y += 1
    end
    return nothing
end

"""
Non-wrapping, single-line text; no wrap cost in `measure`.
"""
mutable struct Static <: Widget
    "Per-widget state."
    node::WidgetNode
    "The text; writing it marks the widget dirty."
    text::Reactive{String}
end

"""
A single-line label showing `text`.
"""
function Static(text::AbstractString; id::Symbol = gensym(:static),
                classes = Symbol[])::Static
    w = Static(WidgetNode(; id = id, classes = classes,
                          type_name = :Static),
               Reactive(String(text)))
    attach_reactives!(w)
    return w
end

"""
`Size(text_width(text), 1)`, independent of `avail`. Pure with respect
to the tree.

A `Static` never wraps, so it never pays the allocation `wrap_width`
costs `Label` on every `measure` -- which is the whole reason the two
types are separate.
"""
measure(w::Static, avail::Size)::Size = Size(text_width(w.text[]), 1)

"""
Paint one line of text into the content box, truncated to its width.

`write_text!` stops at the right edge and refuses a wide cluster that
would straddle it, so the truncation is grapheme-exact and costs
nothing extra here.
"""
function render!(w::Static, buf::AbstractMatrix{Cell})::Nothing
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    write_text!(buf, 1, 1, w.text[], computed_style(w))
    return nothing
end
