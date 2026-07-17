# widgets/container.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode.

"""
A bare grouping widget: no content of its own, all behaviour from its
`BoxStyle` and its children.
"""
mutable struct Container <: Widget
    "Per-widget state."
    node::WidgetNode
end

"""
An empty container.

It defines neither `measure` nor `render!`, and that is the point: the
defaults -- the union of the children's outer measures, and a no-op
paint -- are already exactly right for a widget whose whole job is to
hold other widgets. Direction, gap, padding, border and background all
come from its `BoxStyle`, which is the cascade's business.
"""
Container(; id::Symbol = gensym(:container),
            classes = Symbol[])::Container =
    Container(WidgetNode(; id = id, classes = classes,
                         type_name = :Container))

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
