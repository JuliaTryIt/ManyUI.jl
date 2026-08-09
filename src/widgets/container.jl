# widgets/container.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode.

"""
A bare grouping widget: no content of its own, all behaviour from its
`BoxStyle` and its children.
"""
mutable struct Container <: Widget
    "Per-widget state."
    node::WidgetNode
    """
    The caption painted on the top border. `Dirty.PAINT`-reactive, and
    the licence is the one `TabStrip.selected` states: `measure` must
    be independent of the state, and it is -- `Container` defines no
    `measure` at all, so a new caption cannot move this widget or its
    siblings. The border row it lands on exists whether or not there is
    a caption on it.
    """
    title::Reactive{RichText}
    "Where the caption sits along the top edge."
    title_align::Align.T
end

"""
An empty container, optionally captioned.

It defines neither `measure` nor `render!`, and that is the point: the
defaults -- the union of the children's outer measures, and a no-op
paint -- are already exactly right for a widget whose whole job is to
hold other widgets. Direction, gap, padding, border and background all
come from its `BoxStyle`, which is the cascade's business.

`title` is painted BY THE PAINT PASS on the top border, and only when
there is a border to put it on. It is not content and takes no content
row.
"""
function Container(; id::Symbol = gensym(:container),
                     classes = Symbol[], title::TextLike = RICHTEXT_EMPTY,
                     title_align::Align.T = Align.START)::Container
    w = Container(WidgetNode(; id = id, classes = classes,
                             type_name = :Container),
                  Reactive(convert(RichText, title); kind = Dirty.PAINT),
                  title_align)
    attach_reactives!(w)
    return w
end

border_title(w::Container)::RichText = w.title[]
border_title_align(w::Container)::Align.T = w.title_align

"""
A container with `children` already mounted, in order.
"""
function Container(children::Widget...; kwargs...)::Container
    c = Container(; kwargs...)
    for child in children
        mount!(c, child)
    end
    return c
end
