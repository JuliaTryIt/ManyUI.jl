# geometry.jl -- layer 1. May reference: types.
# 1-based, inclusive coordinates EVERYWHERE (contract 0.1).

"""
A width x height extent in terminal cells. `isbits`.

Always `width`/`height`, never `cols`/`rows`.
"""
struct Size
    "Horizontal extent, in cells."
    width::Int
    "Vertical extent, in cells."
    height::Int
end

"""
A 2D displacement in cells. `isbits`.
"""
struct Offset
    "Horizontal component."
    x::Int
    "Vertical component."
    y::Int
end

"""
An axis-aligned rectangle. 1-based and inclusive: the origin is the
top-left cell `(x, y)` and the last cell is `(x + width - 1,
y + height - 1)`. `isbits`.
"""
struct Region
    "Left edge, 1-based."
    x::Int
    "Top edge, 1-based."
    y::Int
    "Horizontal extent, in cells."
    width::Int
    "Vertical extent, in cells."
    height::Int
end

"""
Per-edge insets, in cells, in CSS order. `isbits`.
"""
struct Spacing
    "Top inset."
    top::Int
    "Right inset."
    right::Int
    "Bottom inset."
    bottom::Int
    "Left inset."
    left::Int
end

"""
The region covering a `Size` anchored at the origin: `Region(1, 1, w, h)`.
"""
Region(s::Size) = Region(1, 1, s.width, s.height)

"""
Uniform spacing on all four edges.
"""
Spacing(all::Int) = Spacing(all, all, all, all)

"""
CSS two-value shorthand: `vert` on top/bottom, `horz` on left/right.
"""
Spacing(vert::Int, horz::Int) = Spacing(vert, horz, vert, horz)

const NO_SPACING = Spacing(0, 0, 0, 0)
const EMPTY_REGION = Region(1, 1, 0, 0)
const ORIGIN = Offset(0, 0)

"""
Total horizontal inset: `left + right`. Pure.
"""
horizontal(s::Spacing)::Int = s.left + s.right

"""
Total vertical inset: `top + bottom`. Pure.
"""
vertical(s::Spacing)::Int = s.top + s.bottom

"""
Fieldwise sum of two `Spacing` values. Pure.
"""
Base.:+(a::Spacing, b::Spacing)::Spacing =
    Spacing(a.top + b.top, a.right + b.right,
            a.bottom + b.bottom, a.left + b.left)

"""
Top-left cell of `r` as an `Offset`. Pure.
"""
origin(r::Region)::Offset = Offset(r.x, r.y)

"""
Extent of `r` as a `Size`. Deliberately NOT `Base.size`: a `Region` is
not an array. Pure.
"""
size_of(r::Region)::Size = Size(r.width, r.height)

"""
Rightmost column of `r`, inclusive: `r.x + r.width - 1`. Pure.
"""
right(r::Region)::Int = r.x + r.width - 1

"""
Bottom row of `r`, inclusive: `r.y + r.height - 1`. Pure.
"""
bottom(r::Region)::Int = r.y + r.height - 1

"""
Cell count of `r`, clamped at zero per axis. Pure.
"""
area(r::Region)::Int = max(0, r.width) * max(0, r.height)

"""
True when `r` covers no cell (`width <= 0 || height <= 0`). Pure.
"""
Base.isempty(r::Region)::Bool = r.width <= 0 || r.height <= 0

"""
Containment test, inclusive at both ends. Pure.
"""
Base.in(o::Offset, r::Region)::Bool =
    !isempty(r) && r.x <= o.x <= right(r) && r.y <= o.y <= bottom(r)

"""
Overlap of two regions, or `EMPTY_REGION` when disjoint.

NEVER returns `nothing`: clipping is on the per-cell hot path and must
stay type-stable. Pure.
"""
function Base.intersect(a::Region, b::Region)::Region
    (isempty(a) || isempty(b)) && return EMPTY_REGION
    x = max(a.x, b.x)
    y = max(a.y, b.y)
    w = min(right(a), right(b)) - x + 1
    h = min(bottom(a), bottom(b)) - y + 1
    (w <= 0 || h <= 0) && return EMPTY_REGION
    return Region(x, y, w, h)
end

"""
Bounding box of two regions. An empty operand is the identity. Pure.
"""
function Base.union(a::Region, b::Region)::Region
    isempty(a) && return b
    isempty(b) && return a
    x = min(a.x, b.x)
    y = min(a.y, b.y)
    w = max(right(a), right(b)) - x + 1
    h = max(bottom(a), bottom(b)) - y + 1
    return Region(x, y, w, h)
end

"""
True when every cell of `a` lies in `b`. Pure.
"""
function Base.issubset(a::Region, b::Region)::Bool
    isempty(a) && return true
    isempty(b) && return false
    return a.x >= b.x && a.y >= b.y &&
           right(a) <= right(b) && bottom(a) <= bottom(b)
end

"""
Move `r` by `o`, keeping its extent. Pure.
"""
translate(r::Region, o::Offset)::Region =
    Region(r.x + o.x, r.y + o.y, r.width, r.height)

"""
Inset `r` by `s`. Width and height CLAMP TO ZERO, never go negative:
layout underflow must degrade to an empty region, not to garbage that
crashes a writer. Pure.
"""
shrink(r::Region, s::Spacing)::Region =
    Region(r.x + s.left, r.y + s.top,
           max(0, r.width - horizontal(s)),
           max(0, r.height - vertical(s)))

"""
Outset `r` by `s`. Pure.
"""
grow(r::Region, s::Spacing)::Region =
    Region(r.x - s.left, r.y - s.top,
           r.width + horizontal(s), r.height + vertical(s))

"""
Clip `r` to `outer`; identical to `intersect`. Pure.
"""
clamp_to(r::Region, outer::Region)::Region = intersect(r, outer)

"""
Per-axis clamp of `s` between `lo` and `hi`. Pure.
"""
clamp_size(s::Size, lo::Size, hi::Size)::Size =
    Size(clamp(s.width, lo.width, hi.width),
         clamp(s.height, lo.height, hi.height))

"""
Split `r` horizontally; `at` is the number of ROWS in the top piece.
The two pieces partition `r` exactly. Pure.

`at` is clamped to `0:r.height`, so neither piece ever has a negative
extent and `area(top) + area(bottom) == area(r)` always holds.
"""
function split_row(r::Region, at::Int)::Tuple{Region,Region}
    n = clamp(at, 0, max(0, r.height))
    top = Region(r.x, r.y, r.width, n)
    bot = Region(r.x, r.y + n, r.width, max(0, r.height) - n)
    return (top, bot)
end

"""
Split `r` vertically; `at` is the number of COLUMNS in the left piece.
The two pieces partition `r` exactly. Pure.

`at` is clamped to `0:r.width`, so neither piece ever has a negative
extent and `area(left) + area(right) == area(r)` always holds.
"""
function split_col(r::Region, at::Int)::Tuple{Region,Region}
    n = clamp(at, 0, max(0, r.width))
    lft = Region(r.x, r.y, n, r.height)
    rgt = Region(r.x + n, r.y, max(0, r.width) - n, r.height)
    return (lft, rgt)
end

"""
Componentwise sum of two offsets. Pure.
"""
Base.:+(a::Offset, b::Offset)::Offset = Offset(a.x + b.x, a.y + b.y)

"""
Componentwise difference of two offsets. Pure.
"""
Base.:-(a::Offset, b::Offset)::Offset = Offset(a.x - b.x, a.y - b.y)

"""
Componentwise sum of two sizes. Pure.
"""
Base.:+(a::Size, b::Size)::Size =
    Size(a.width + b.width, a.height + b.height)
