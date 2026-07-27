# boxmodel.jl -- layer 2. May reference: types, geometry, color, style.
#
# Types only, and it must NOT name `Widget`. It exists so `widget.jl`
# can hold a `BoxStyle` field without depending on the layout engine.

"""
How a `Length` value is to be resolved.
"""
module Dimension
@enum T::UInt8 begin
    AUTO = 0      # size to content
    CELLS = 1     # absolute cell count
    PERCENT = 2   # % of the parent's content box
    FRACTION = 3  # flex "fr" of the remaining free space
end
end

"""
A resolvable length. `isbits`.
"""
struct Length
    "How to read `value`."
    kind::Dimension.T
    "Cells, percent, or fr weight, per `kind`."
    value::Float32
end

const AUTO = Length(Dimension.AUTO, 0f0)

"""
An absolute length in cells. Pure.
"""
cells(n::Real)::Length = Length(Dimension.CELLS, Float32(n))

"""
A percentage of the parent's content box. Pure.
"""
pct(n::Real)::Length = Length(Dimension.PERCENT, Float32(n))

"""
A fraction of the remaining free space. Pure.
"""
fr(n::Real)::Length = Length(Dimension.FRACTION, Float32(n))

"""
True for CELLS and PERCENT -- the kinds resolvable without measuring
content. Pure.
"""
is_definite(d::Length)::Bool =
    d.kind === Dimension.CELLS || d.kind === Dimension.PERCENT

"""
Resolve a definite length against `available`. CELLS and PERCENT only;
PERCENT rounds via `round(Int)`. Pure.

Throws `ArgumentError` for AUTO and FRACTION: neither can be resolved
without measuring content or knowing the free space, so a silent 0
would be a layout bug that never announces itself.
"""
function definite_size(d::Length, available::Int)::Int
    d.kind === Dimension.CELLS && return round(Int, d.value)
    d.kind === Dimension.PERCENT &&
        return round(Int, available * d.value / 100)
    throw(ArgumentError("definite_size: $(d.kind) is not definite"))
end

"""
Parse a length, returning `nothing` instead of throwing.

Accepts `"auto"`, `"10"`, `"10cells"`, `"50%"`, `"1fr"`, `"3fr"`.
Case-insensitive; surrounding whitespace is ignored. Pure.
"""
function Base.tryparse(::Type{Length},
                       s::AbstractString)::Union{Length,Nothing}
    t = lowercase(strip(s))
    isempty(t) && return nothing
    t == "auto" && return AUTO
    if endswith(t, "%")
        v = tryparse(Float32, strip(t[1:prevind(t, lastindex(t))]))
        return v === nothing ? nothing : pct(v)
    elseif endswith(t, "fr")
        v = tryparse(Float32, strip(t[1:prevind(t, lastindex(t), 2)]))
        return v === nothing ? nothing : fr(v)
    elseif endswith(t, "cells")
        v = tryparse(Float32, strip(t[1:prevind(t, lastindex(t), 5)]))
        return v === nothing ? nothing : cells(v)
    end
    v = tryparse(Float32, t)
    return v === nothing ? nothing : cells(v)
end

"""
Parse a length, throwing `ArgumentError` on garbage. Pure.
"""
function Base.parse(::Type{Length}, s::AbstractString)::Length
    r = tryparse(Length, s)
    r === nothing && throw(ArgumentError("invalid Length: $(repr(s))"))
    return r
end

"""
Border line styles. `BLANK` still occupies its cells.
"""
module BorderKind
@enum T::UInt8 begin
    NONE = 0
    SOLID
    ROUND
    DOUBLE
    THICK
    DASHED
    ASCII
    BLANK
end
end

"""
A border: a line style plus the style its glyphs are drawn in.
`isbits`.
"""
struct Border
    "Line style."
    kind::BorderKind.T
    "Style the glyphs are painted with."
    style::Style
end

const BORDER_NONE = Border(BorderKind.NONE, STYLE_NONE)

"""
The eight glyphs of a border kind: `(tl, top, tr, right, br, bottom,
bl, left)` -- clockwise from the top-left. Pure.

`NONE` and `BLANK` both yield spaces. They differ in `thickness`, not
in their glyphs: `NONE` reserves no cells and is never drawn, whereas
`BLANK` reserves its cells and paints them blank.

Every glyph is width-1 by construction (verified in `test_paint.jl`);
a width-2 glyph here would desynchronise the grid on every border.
"""
function border_glyphs(k::BorderKind.T)::NTuple{8,Char}
    k === BorderKind.SOLID  && return ('┌', '─', '┐', '│',
                                       '┘', '─', '└', '│')
    k === BorderKind.ROUND  && return ('╭', '─', '╮', '│',
                                       '╯', '─', '╰', '│')
    k === BorderKind.DOUBLE && return ('╔', '═', '╗', '║',
                                       '╝', '═', '╚', '║')
    k === BorderKind.THICK  && return ('┏', '━', '┓', '┃',
                                       '┛', '━', '┗', '┃')
    k === BorderKind.DASHED && return ('┌', '┄', '┐', '┆',
                                       '┘', '┄', '└', '┆')
    k === BorderKind.ASCII  && return ('+', '-', '+', '|',
                                       '+', '-', '+', '|')
    return (' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ')
end

"""
Cells the border occupies per edge: `NO_SPACING` for `NONE`, one cell
on every edge otherwise (`BLANK` included). Pure.
"""
thickness(b::Border)::Spacing =
    b.kind === BorderKind.NONE ? NO_SPACING : Spacing(1)

"""
Whether and how a box participates in layout.
"""
module Display
@enum T::UInt8 begin
    NONE = 0
    BLOCK = 1
    FLEX = 2
end
end

"""
Main-axis direction of a flex container.
"""
module Direction
@enum T::UInt8 begin
    ROW = 0
    COLUMN
    ROW_REVERSE
    COLUMN_REVERSE
end
end

"""
Main-axis distribution. Split from `Align` so that
`align: space-between` is unrepresentable.
"""
module Justify
@enum T::UInt8 begin
    START = 0
    CENTER
    END
    SPACE_BETWEEN
    SPACE_AROUND
    SPACE_EVENLY
end
end

"""
Cross-axis alignment.
"""
module Align
@enum T::UInt8 begin
    START = 0
    CENTER
    END
    STRETCH
end
end

"""
What happens to content that exceeds its box.
"""
module Overflow
@enum T::UInt8 begin
    VISIBLE = 0
    HIDDEN
    SCROLL
end
end

"""
The cascade's output and the layout engine's input. `isbits`, and it
lives inline in `WidgetNode` -- no pointer chasing during layout.
"""
struct BoxStyle
    "Whether and how the box participates in layout."
    display::Display.T
    "Main axis of the flex container."
    direction::Direction.T
    "Main-axis distribution of the children."
    justify::Justify.T
    "Cross-axis alignment of the children."
    align::Align.T
    "Preferred width."
    width::Length
    "Preferred height."
    height::Length
    "Lower width bound."
    min_width::Length
    "Lower height bound."
    min_height::Length
    "Upper width bound."
    max_width::Length
    "Upper height bound."
    max_height::Length
    "Space outside the border box."
    margin::Spacing
    "Space between the border and the content."
    padding::Spacing
    "Border drawn on the perimeter of the border box."
    border::Border
    "Cells inserted between adjacent children."
    gap::Int
    "Horizontal overflow policy."
    overflow_x::Overflow.T
    "Vertical overflow policy."
    overflow_y::Overflow.T
    "Flex grow factor."
    grow::Float32
    "Flex shrink factor."
    shrink::Float32
end

"""
Keyword constructor with the documented defaults.
"""
BoxStyle(; display = Display.BLOCK,
           direction = Direction.COLUMN,
           justify = Justify.START,
           align = Align.STRETCH,
           width = AUTO, height = AUTO,
           min_width = AUTO, min_height = AUTO,
           max_width = AUTO, max_height = AUTO,
           margin = NO_SPACING, padding = NO_SPACING,
           border = BORDER_NONE, gap = 0,
           overflow_x = Overflow.HIDDEN,
           overflow_y = Overflow.HIDDEN,
           grow = 0f0, shrink = 1f0)::BoxStyle =
    BoxStyle(display, direction, justify, align,
             width, height, min_width, min_height, max_width, max_height,
             margin, padding, border, Int(gap),
             overflow_x, overflow_y, Float32(grow), Float32(shrink))

# Spelled positionally so it is correct independently of the keyword
# constructor above; it MUST stay equal to `BoxStyle()`.
const BOX_DEFAULT = BoxStyle(Display.BLOCK, Direction.COLUMN,
                             Justify.START, Align.STRETCH,
                             AUTO, AUTO, AUTO, AUTO, AUTO, AUTO,
                             NO_SPACING, NO_SPACING, BORDER_NONE, 0,
                             Overflow.HIDDEN, Overflow.HIDDEN,
                             0f0, 1f0)

# Guards the functional-update constructors against typo'd keywords.
const _BOX_FIELDS = fieldnames(BoxStyle)

"""
Functional update: a copy of `base` with the given fields replaced.
Pure.

An unknown keyword throws `ArgumentError` rather than being ignored:
a silently dropped `BoxStyle(b; witdh = cells(3))` is a layout bug with
no symptom at the call site.
"""
function BoxStyle(base::BoxStyle; kwargs...)::BoxStyle
    nt = values(kwargs)
    for k in keys(nt)
        k in _BOX_FIELDS ||
            throw(ArgumentError("BoxStyle has no field '$k'"))
    end
    return BoxStyle(get(nt, :display, base.display),
                    get(nt, :direction, base.direction),
                    get(nt, :justify, base.justify),
                    get(nt, :align, base.align),
                    get(nt, :width, base.width),
                    get(nt, :height, base.height),
                    get(nt, :min_width, base.min_width),
                    get(nt, :min_height, base.min_height),
                    get(nt, :max_width, base.max_width),
                    get(nt, :max_height, base.max_height),
                    get(nt, :margin, base.margin),
                    get(nt, :padding, base.padding),
                    get(nt, :border, base.border),
                    Int(get(nt, :gap, base.gap)),
                    get(nt, :overflow_x, base.overflow_x),
                    get(nt, :overflow_y, base.overflow_y),
                    Float32(get(nt, :grow, base.grow)),
                    Float32(get(nt, :shrink, base.shrink)))
end

"""
The optional-every-field twin of `BoxStyle`: `nothing` means "not
specified".

Deliberately NOT `isbits`, and that is fine -- it exists only at parse
and cascade time, never in the render loop.
"""
struct BoxPatch
    "Overrides `BoxStyle.display` when set."
    display::Union{Nothing,Display.T}
    "Overrides `BoxStyle.direction` when set."
    direction::Union{Nothing,Direction.T}
    "Overrides `BoxStyle.justify` when set."
    justify::Union{Nothing,Justify.T}
    "Overrides `BoxStyle.align` when set."
    align::Union{Nothing,Align.T}
    "Overrides `BoxStyle.width` when set."
    width::Union{Nothing,Length}
    "Overrides `BoxStyle.height` when set."
    height::Union{Nothing,Length}
    "Overrides `BoxStyle.min_width` when set."
    min_width::Union{Nothing,Length}
    "Overrides `BoxStyle.min_height` when set."
    min_height::Union{Nothing,Length}
    "Overrides `BoxStyle.max_width` when set."
    max_width::Union{Nothing,Length}
    "Overrides `BoxStyle.max_height` when set."
    max_height::Union{Nothing,Length}
    "Overrides `BoxStyle.margin` when set."
    margin::Union{Nothing,Spacing}
    "Overrides `BoxStyle.padding` when set."
    padding::Union{Nothing,Spacing}
    "Overrides `BoxStyle.border` when set."
    border::Union{Nothing,Border}
    "Overrides `BoxStyle.gap` when set."
    gap::Union{Nothing,Int}
    "Overrides `BoxStyle.overflow_x` when set."
    overflow_x::Union{Nothing,Overflow.T}
    "Overrides `BoxStyle.overflow_y` when set."
    overflow_y::Union{Nothing,Overflow.T}
    "Overrides `BoxStyle.grow` when set."
    grow::Union{Nothing,Float32}
    "Overrides `BoxStyle.shrink` when set."
    shrink::Union{Nothing,Float32}
end

"""
Keyword constructor; every field defaults to `nothing`.

An unknown keyword throws `ArgumentError`: a stylesheet property that
silently patched nothing would be invisible at every layer above.
"""
function BoxPatch(; kwargs...)::BoxPatch
    nt = values(kwargs)
    for k in keys(nt)
        k in _BOX_FIELDS ||
            throw(ArgumentError("BoxPatch has no field '$k'"))
    end
    g = get(nt, :gap, nothing)
    gr = get(nt, :grow, nothing)
    sh = get(nt, :shrink, nothing)
    return BoxPatch(get(nt, :display, nothing),
                    get(nt, :direction, nothing),
                    get(nt, :justify, nothing),
                    get(nt, :align, nothing),
                    get(nt, :width, nothing),
                    get(nt, :height, nothing),
                    get(nt, :min_width, nothing),
                    get(nt, :min_height, nothing),
                    get(nt, :max_width, nothing),
                    get(nt, :max_height, nothing),
                    get(nt, :margin, nothing),
                    get(nt, :padding, nothing),
                    get(nt, :border, nothing),
                    g === nothing ? nothing : Int(g),
                    get(nt, :overflow_x, nothing),
                    get(nt, :overflow_y, nothing),
                    gr === nothing ? nothing : Float32(gr),
                    sh === nothing ? nothing : Float32(sh))
end

# Spelled positionally so it is correct independently of the keyword
# constructor above; it MUST stay equal to `BoxPatch()`.
const BOX_PATCH_NONE = BoxPatch(nothing, nothing, nothing, nothing,
                                nothing, nothing, nothing, nothing,
                                nothing, nothing, nothing, nothing,
                                nothing, nothing, nothing, nothing,
                                nothing, nothing)

# `BoxPatch` is the optional-every-field twin of `BoxStyle`: the two
# MUST agree field-for-field, in order, or `apply` and `merge` below
# silently mis-assign. Checked at load time so drift cannot ship.
@assert fieldnames(BoxPatch) === _BOX_FIELDS

# The one rule both `apply` and `merge` are made of: the override wins
# iff it is set. Unannotated because `merge(::BoxPatch, ::BoxPatch)` folds
# patches whose own fields may be `nothing`, so `base` is not always a
# set value; inference splits the Union on `=== nothing` regardless, which
# is what keeps the fold type-stable.
@inline _pick(base, over) = over === nothing ? base : over

"""
Apply `p` onto `base`: `p` wins wherever it is set. Pure.

The identity is `BOX_PATCH_NONE`: `apply(b, BOX_PATCH_NONE) === b`.
"""
apply(base::BoxStyle, p::BoxPatch)::BoxStyle =
    BoxStyle(_pick(base.display, p.display),
             _pick(base.direction, p.direction),
             _pick(base.justify, p.justify),
             _pick(base.align, p.align),
             _pick(base.width, p.width),
             _pick(base.height, p.height),
             _pick(base.min_width, p.min_width),
             _pick(base.min_height, p.min_height),
             _pick(base.max_width, p.max_width),
             _pick(base.max_height, p.max_height),
             _pick(base.margin, p.margin),
             _pick(base.padding, p.padding),
             _pick(base.border, p.border),
             _pick(base.gap, p.gap),
             _pick(base.overflow_x, p.overflow_x),
             _pick(base.overflow_y, p.overflow_y),
             _pick(base.grow, p.grow),
             _pick(base.shrink, p.shrink))

"""
Merge two patches: `b` wins wherever it is set. Pure.

A monoid with identity `BOX_PATCH_NONE`, matching `merge(::Style,
::Style)`. This is the box half of the cascade fold.
"""
Base.merge(a::BoxPatch, b::BoxPatch)::BoxPatch =
    BoxPatch(_pick(a.display, b.display),
             _pick(a.direction, b.direction),
             _pick(a.justify, b.justify),
             _pick(a.align, b.align),
             _pick(a.width, b.width),
             _pick(a.height, b.height),
             _pick(a.min_width, b.min_width),
             _pick(a.min_height, b.min_height),
             _pick(a.max_width, b.max_width),
             _pick(a.max_height, b.max_height),
             _pick(a.margin, b.margin),
             _pick(a.padding, b.padding),
             _pick(a.border, b.border),
             _pick(a.gap, b.gap),
             _pick(a.overflow_x, b.overflow_x),
             _pick(a.overflow_y, b.overflow_y),
             _pick(a.grow, b.grow),
             _pick(a.shrink, b.shrink))

"""
True when `p` sets no field at all. Pure.

`BoxPatch` is an immutable struct, so `===` is structural (field-wise
egal, recursively) rather than pointer identity -- comparing against
the all-`nothing` value is exactly "sets no field", in one shot.
"""
Base.isempty(p::BoxPatch)::Bool = p === BOX_PATCH_NONE

"""
The four resolved boxes of one node, in ABSOLUTE 1-based screen
coordinates.

INVARIANT: `margin_box` includes `border_box` includes `padding_box`
includes `content`.
"""
struct LayoutBox
    "Outermost box; includes the margin."
    margin_box::Region
    "`margin_box` shrunk by the margin. The border is drawn ON its
    perimeter."
    border_box::Region
    "`border_box` shrunk by the border thickness."
    padding_box::Region
    "`padding_box` shrunk by the padding."
    content::Region
end

const LAYOUT_BOX_EMPTY = LayoutBox(EMPTY_REGION, EMPTY_REGION,
                                   EMPTY_REGION, EMPTY_REGION)

"""
Derive all four boxes from an outer `margin_box` and a `BoxStyle`.

THE single definition of the box model: no other file may re-derive
these. Pure.
"""
function layout_box(bs::BoxStyle, margin_box::Region)::LayoutBox
    border_box = shrink(margin_box, bs.margin)
    padding_box = shrink(border_box, thickness(bs.border))
    content = shrink(padding_box, bs.padding)
    return LayoutBox(margin_box, border_box, padding_box, content)
end

"""
Total non-content spacing: margin + border + padding. Pure.
"""
box_overhead(bs::BoxStyle)::Spacing =
    bs.margin + thickness(bs.border) + bs.padding

"""
The margin-box size needed to hold a content box of `inner`. Pure.

This is the sole content-box -> outer-box conversion in the package,
and so it is what pins `BoxStyle.width`/`height` to the CONTENT box
(the CSS `box-sizing: content-box` default).
"""
function outer_size(bs::BoxStyle, inner::Size)::Size
    o = box_overhead(bs)
    return Size(inner.width + horizontal(o), inner.height + vertical(o))
end
