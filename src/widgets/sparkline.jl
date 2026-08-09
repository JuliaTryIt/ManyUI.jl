# widgets/sparkline.jl -- layer 7.
# May reference: widget, reactive, layout, unicode.
#
# A SERIES IS DATA, not a widget per point -- the seam `List` and the
# table widgets already use. A 10 000-sample series is a `Vector` of
# 10 000 `Float64` and ONE node, and a frame costs the width of the
# widget rather than the length of the series, because only the last
# `width` samples can be on screen at all.

"""
The eight levels a sparkline draws with, lowest first. One cell each,
so a sparkline of `n` samples is exactly `n` cells wide.
"""
const SPARK_GLYPHS = ("▁", "▂", "▃", "▄", "▅", "▆", "▇", "█")

"""
Drawn for a sample when the series is flat -- every value equal, so
there is no range to scale against and every level would be a lie
except the one that says "no change".
"""
const SPARK_FLAT = SPARK_GLYPHS[1]

"""
A one-row plot of a numeric series, one cell per sample.

The series is ALIASED and mutated in place: `push_value!` costs a
`push!` and one `Dirty.PAINT` mark, never a rebuild. `version` is the
reactive cell, exactly as `List` uses one, because the data is a plain
`Vector` with nothing to make reactive.
"""
mutable struct Sparkline <: Widget
    "Per-widget state."
    node::WidgetNode
    "The samples, oldest first. ALIASED. Mutated IN PLACE."
    const values::Vector{Float64}
    "Bumped by every data change. THE reactive cell. `Dirty.PAINT`."
    version::Reactive{Int}
    """
    Lower bound of the scale, or `nothing` to take it from the data.

    A FIXED bound is what makes two sparklines comparable: auto-scaling
    redraws the same series differently the moment one outlier arrives,
    which is exactly when a reader most needs the picture to hold still.
    """
    lo::Union{Nothing,Float64}
    "Upper bound of the scale, or `nothing` to take it from the data."
    hi::Union{Nothing,Float64}
    "Samples kept; the oldest are dropped past it. `0` keeps every one."
    cap::Int
end

"""
A sparkline over `values`.

`lo`/`hi` fix the scale; left at `nothing` they are taken from the
data. `cap` bounds how many samples are kept, so a live series cannot
grow without limit -- `0` keeps every one.
"""
function Sparkline(values::AbstractVector{<:Real} = Float64[];
                   lo::Union{Nothing,Real} = nothing,
                   hi::Union{Nothing,Real} = nothing,
                   cap::Int = 0,
                   id::Symbol = gensym(:sparkline),
                   classes = Symbol[])::Sparkline
    cap >= 0 || throw(ArgumentError("cap must be >= 0, got $cap"))
    w = Sparkline(WidgetNode(; id = id, classes = classes,
                             type_name = :Sparkline),
                  Float64.(values),
                  Reactive(0; kind = Dirty.PAINT),
                  lo === nothing ? nothing : Float64(lo),
                  hi === nothing ? nothing : Float64(hi),
                  cap)
    attach_reactives!(w)
    _spark_trim!(w)
    return w
end

"""
Drop the oldest samples past `cap`. Internal.
"""
function _spark_trim!(w::Sparkline)::Nothing
    w.cap == 0 && return nothing
    n = length(w.values) - w.cap
    n > 0 && deleteat!(w.values, 1:n)
    return nothing
end

"""
Append `v`, dropping the oldest sample if that would exceed `cap`.

`Dirty.PAINT` and not `Dirty.LAYOUT` even though the series got longer:
`measure` is a function of the WIDGET, not of the series -- see below.
"""
function push_value!(w::Sparkline, v::Real)::Nothing
    push!(w.values, Float64(v))
    _spark_trim!(w)
    w.version[] += 1
    return nothing
end

"""
Replace the whole series.
"""
function set_values!(w::Sparkline, vs::AbstractVector{<:Real})::Nothing
    empty!(w.values)
    append!(w.values, Float64.(vs))
    _spark_trim!(w)
    w.version[] += 1
    return nothing
end

"""
How many samples the series holds.
"""
n_values(w::Sparkline)::Int = length(w.values)

"""
The scale in force: `(lo, hi)`, from the fixed bounds where they are
given and from the data otherwise. `(0, 1)` for an empty series.

`hi <= lo` is reported as-is rather than repaired -- `render!` reads it
as "flat" and draws the lowest level, which is the truthful picture of
a series with no range.
"""
function spark_bounds(w::Sparkline)::Tuple{Float64,Float64}
    isempty(w.values) && return (0.0, 1.0)
    lo = w.lo === nothing ? minimum(w.values) : w.lo
    hi = w.hi === nothing ? maximum(w.values) : w.hi
    return (lo, hi)
end

"""
The glyph index `1:8` for `v` under the scale `(lo, hi)`, clamped.

Pure and total: a value outside a FIXED scale is pinned to the end it
overshot rather than dropped, because a sparkline that silently omits
its outliers is worse than one that flattens them.
"""
function spark_level(v::Real, lo::Real, hi::Real)::Int
    hi <= lo && return 1
    t = (Float64(v) - Float64(lo)) / (Float64(hi) - Float64(lo))
    return clamp(1 + floor(Int, t * length(SPARK_GLYPHS)),
                 1, length(SPARK_GLYPHS))
end

"""
`Size(n_values, 1)`: one cell per sample, one row.

Independent of `avail`, so a sparkline beside a `Label` does not eat
the row. Give it `grow` or a `width` to stretch it; `render!` then
shows the LAST samples that fit, which is what a live series wants --
new data arrives on the right and the oldest scrolls off the left.
"""
measure(w::Sparkline, avail::Size)::Size = Size(length(w.values), 1)
