# widgets/progresslist.jl -- layer 7.
# May reference: widget, reactive, richtext, progressbar, scroll,
# layout, unicode.
#
# A ROW IS NOT A WIDGET, the same seam `List` and the table widgets
# take: a hundred tasks are a `Vector` of a hundred `ProgressItem` and
# ONE node, and a frame costs the rows on SCREEN rather than the rows
# held. Composing this out of a hundred `ProgressBar`s would put a
# hundred nodes on the tree to show a hundred numbers.

"Cells between the label column and the bar."
const PL_GAP = 1
"Narrowest bar worth drawing; below it the row is all label."
const PL_MIN_BAR = 4

"""
One row of a `ProgressList`: a caption and a ratio.

`progress` is clamped to `0:1` on construction, so a row cannot carry
an out-of-range value into `render!` where there is nothing sensible to
do about it.
"""
struct ProgressItem
    "Row caption, drawn in the label column."
    label::RichText
    "Completion, `0.0` to `1.0`."
    progress::Float64
end

ProgressItem(label::TextLike, progress::Real)::ProgressItem =
    ProgressItem(convert(RichText, label), clamp(Float64(progress), 0.0, 1.0))

"""
A column of captioned bars, one row per item.

The label column is `label_width` cells wide, or as wide as the widest
caption when that is `AUTO` -- measured over ALL items, because a label
column that changed width as the list scrolled would make every bar
jump sideways.
"""
mutable struct ProgressList <: Widget
    "Per-widget state."
    node::WidgetNode
    "The rows, in order. ALIASED. Mutated IN PLACE."
    const items::Vector{ProgressItem}
    "Bumped by every data change. THE reactive cell. `Dirty.PAINT`."
    version::Reactive{Int}
    "Width of the label column, or `AUTO` to fit the widest caption."
    label_width::Length
end

"""
A progress list over `items`.
"""
function ProgressList(items::AbstractVector{ProgressItem} = ProgressItem[];
                      label_width::Length = AUTO,
                      id::Symbol = gensym(:progresslist),
                      classes = Symbol[])::ProgressList
    w = ProgressList(WidgetNode(; id = id, classes = classes,
                                type_name = :ProgressList),
                     collect(ProgressItem, items),
                     Reactive(0; kind = Dirty.PAINT),
                     label_width)
    attach_reactives!(w)
    return w
end

"""
How many rows the list holds.
"""
n_items(w::ProgressList)::Int = length(w.items)

"""
Replace every row.
"""
function set_items!(w::ProgressList,
                    items::AbstractVector{ProgressItem})::Nothing
    empty!(w.items)
    append!(w.items, items)
    w.version[] += 1
    return nothing
end

"""
Append a row.
"""
function push_item!(w::ProgressList, item::ProgressItem)::Nothing
    push!(w.items, item)
    w.version[] += 1
    return nothing
end

"""
Set row `i`'s progress, clamped. Returns true iff it moved.

The reason a row is a struct and not a `ProgressBar`: updating one is
this, not a widget lookup and a reactive write on a node.
"""
function set_progress!(w::ProgressList, i::Int, v::Real)::Bool
    (1 <= i <= length(w.items)) || return false
    old = w.items[i]
    p = clamp(Float64(v), 0.0, 1.0)
    p === old.progress && return false
    w.items[i] = ProgressItem(old.label, p)
    w.version[] += 1
    return true
end

"""
Cells the label column takes: `label_width` when definite, otherwise
the widest caption.

AUTO measures EVERY item and not a sample, unlike a table's AUTO
column. The two differ because the cost differs: a caption is short and
a progress list is a handful of rows, where a table's AUTO column
guards against a hundred thousand. Measuring a sample here would let
the column change width as the list scrolled, and every bar would jump
sideways.
"""
function pl_label_width(w::ProgressList)::Int
    is_definite(w.label_width) &&
        return max(0, definite_size(w.label_width, 0))
    m = 0
    for it in w.items
        m = max(m, text_width(it.label))
    end
    return m
end

"""
`avail`. `List`'s argument verbatim: a progress list takes the space it
is OFFERED and scrolls, because an auto-height one would be as tall as
its data and would never scroll at all. This is also what licenses
`version`'s PAINT reactivity.
"""
measure(w::ProgressList, avail::Size)::Size = avail

"""
One row per item, so a `Scrollbar` reports on it with no new code --
the same seam `TextArea` and the row widgets use.
"""
content_extent(w::ProgressList)::Size =
    Size(pl_label_width(w) + PL_GAP + PL_MIN_BAR, length(w.items))

