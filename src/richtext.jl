# richtext.jl -- layer 5.5.
# May reference: style, unicode, color.
#
# One line of text whose STYLE VARIES ALONG IT. A `Style` is per-widget
# and comes from the cascade; this is the escape hatch for the cases the
# cascade cannot reach, because the styled thing is not a node: the key
# in a tab caption, the level in a log line, the units in a status
# readout. Making each of those a widget would put three nodes on a
# tab strip and one per log row.
#
# S3 applies here exactly as it does in unicode.jl and label.jl: every
# width, cut and break goes through `text_width` / `truncate_width` /
# `wrap_width`, never through `Base.textwidth` and never by codepoint.

"""
A run of text carrying its own style override.

`style` is folded OVER the painting widget's computed style with
`merge`, the cascade's own monoid, so `STYLE_NONE` -- the default --
means "exactly the widget's style" and a run that names only `bold`
inherits the widget's colours. A run therefore describes a DIFFERENCE,
never an absolute appearance, which is what lets one `RichText` be
painted into a light and a dark theme without being rebuilt.
"""
struct TextRun
    "The text of the run. May be empty; `RichText` drops such runs."
    text::String
    "The override, folded over the widget's style at paint time."
    style::Style
end

TextRun(text::AbstractString)::TextRun = TextRun(String(text), STYLE_NONE)

# The field is a `String`, so the default `===` would call two equal
# runs different unless they shared an object. Every comparison in this
# file, and every test that uses one as an oracle, needs value equality.
Base.:(==)(a::TextRun, b::TextRun)::Bool =
    a.text == b.text && a.style == b.style
Base.hash(r::TextRun, h::UInt)::UInt = hash(r.style, hash(r.text, h))

"""
A single logical run of text whose style varies along it: a sequence of
`TextRun`s, painted left to right.

NORMALISED at construction -- empty runs dropped, adjacent runs with
equal styles coalesced. The invariant costs one pass and buys a
meaningful `==`: `RichText("ab") == RichText(TextRun("a"), TextRun("b"))`,
so callers may build a line however is convenient without two spellings
of the same line comparing unequal.

`RichText` is a VALUE, not a widget. It has no node, no identity and no
dirty state; a widget holds one and repaints when it is replaced.
"""
struct RichText
    "The runs, in paint order. Normalised; never contains an empty run."
    runs::Vector{TextRun}

    RichText(runs::AbstractVector{TextRun}) = new(_rt_coalesce(runs))
end

"""
Drop empty runs and merge adjacent runs sharing a style.

Runs out of a `wrap` or a `truncate` arrive one grapheme at a time, so
without this a 40-cell line would be 40 runs and every paint would pay
40 `write_text!` calls instead of two.
"""
function _rt_coalesce(runs::AbstractVector{TextRun})::Vector{TextRun}
    out = TextRun[]
    for r in runs
        isempty(r.text) && continue
        if !isempty(out) && out[end].style == r.style
            out[end] = TextRun(out[end].text * r.text, r.style)
        else
            push!(out, r)
        end
    end
    return out
end

"""
A `RichText` of the given runs, in order.
"""
RichText(runs::TextRun...)::RichText = RichText(collect(TextRun, runs))

"""
A `RichText` of one run: `text` under `style`, which defaults to the
painting widget's own style.
"""
RichText(text::AbstractString, style::Style = STYLE_NONE)::RichText =
    RichText([TextRun(String(text), style)])

"""
A plain string IS a `RichText` of one unstyled run.

This method is what keeps `label.text[] = "hi"` -- spelled verbatim in
`reactive.jl`'s own docstring -- working on a cell that now holds a
`RichText`: `setindex!(::Reactive{T}, v)` converts, and this is the
conversion. Widgets that take text therefore accept either spelling
without a method per widget per spelling.
"""
Base.convert(::Type{RichText}, s::AbstractString)::RichText = RichText(s)
Base.convert(::Type{RichText}, rt::RichText)::RichText = rt

Base.:(==)(a::RichText, b::RichText)::Bool = a.runs == b.runs
Base.hash(rt::RichText, h::UInt)::UInt = hash(rt.runs, h)
Base.isempty(rt::RichText)::Bool = isempty(rt.runs)

"""
The text with the styling dropped.

THE bridge to every string-shaped operation: widths, cuts and breaks
are decided on this and only then carried back onto the runs, so a
styled line can never measure or wrap differently from the same line
unstyled.
"""
function plain(rt::RichText)::String
    isempty(rt.runs) && return ""
    length(rt.runs) == 1 && return rt.runs[1].text
    io = IOBuffer()
    for r in rt.runs
        write(io, r.text)
    end
    return String(take!(io))
end

Base.String(rt::RichText)::String = plain(rt)

"""
Concatenation. Associative, with `RichText()` as its identity, and
normalising -- so joining two runs of equal style yields one run.
"""
Base.:*(a::RichText, b::RichText)::RichText =
    RichText(vcat(a.runs, b.runs))
Base.:*(a::RichText, b::AbstractString)::RichText = a * RichText(b)
Base.:*(a::AbstractString, b::RichText)::RichText = RichText(a) * b

"""
The width of the line in cells: the sum of its runs' widths.

Runs are segmented into graphemes INDEPENDENTLY, so a combining mark
opening a run does not join the last cluster of the run before it.
Splitting a cluster across two runs is a caller error -- the two halves
could not be given different styles on one cell anyway.
"""
function text_width(rt::RichText)::Int
    w = 0
    for r in rt.runs
        w += text_width(r.text)
    end
    return w
end

"""
The longest PREFIX of `rt` whose `text_width` is `<= w`, styling intact.

Stops at the first cluster that does not fit rather than skipping it:
`truncate_width` yields a prefix, and a line that dropped a wide
cluster to squeeze in the narrow one behind it would not be one. This
is the rule `truncate_width(::AbstractString, ::Int)` already applies
when it breaks out of its scan, and the two agree by construction:

    plain(truncate_width(rt, w)) == truncate_width(plain(rt), w)

Pure.
"""
function truncate_width(rt::RichText, w::Int)::RichText
    w <= 0 && return RichText()
    acc = 0
    out = TextRun[]
    for r in rt.runs
        rw = text_width(r.text)
        if acc + rw <= w
            push!(out, r)
            acc += rw
            continue
        end
        head = truncate_width(r.text, w - acc)
        isempty(head) || push!(out, TextRun(String(head), r.style))
        break                      # the budget is spent; a prefix ends here
    end
    return RichText(out)
end

"""
True when `g`, a single grapheme, is whitespace.
"""
_rt_is_space(g::AbstractString)::Bool = !isempty(g) && isspace(first(g))

"""
The graphemes of `rt`, each paired with the style of the run it came
from. The working form for `wrap_width`, which has to reattach styles
to text the wrap has already rearranged.
"""
function _rt_flatten(rt::RichText)::Vector{Tuple{String,Style}}
    out = Tuple{String,Style}[]
    for r in rt.runs
        for g in Unicode.graphemes(r.text)
            push!(out, (String(g), r.style))
        end
    end
    return out
end

"""
Greedy word wrap to `w` cells, styling intact.

Wraps the PLAIN text with `wrap_width(::AbstractString, ::Int)` and
then reattaches the styling, rather than reimplementing the greedy
algorithm over styled runs. That is the whole design, and it buys the
property that matters:

    plain.(wrap_width(rt, w)) == wrap_width(plain(rt), w)

Colouring a paragraph cannot move one of its breaks. A second
implementation of the wrap would have to be kept in step with the first
forever to promise that; this one cannot drift because there is only
one wrap.

Reattaching is a resynchronising walk. The wrap only ever DROPS
whitespace and collapses a run of it to a single joining space; it
never reorders or rewrites a visible cluster. So the output graphemes
are matched against the input's in order, skipping input whitespace,
and a joining space takes the style of the whitespace it stands for --
that cell still has a background, and resetting it would leave a hole
in a highlighted line.
"""
function wrap_width(rt::RichText, w::Int)::Vector{RichText}
    lines = wrap_width(plain(rt), w)
    isempty(lines) && return RichText[]

    src = _rt_flatten(rt)
    n = length(src)
    i = 1
    out = Vector{RichText}(undef, length(lines))

    for (li, line) in enumerate(lines)
        acc = TextRun[]
        for g in Unicode.graphemes(line)
            if _rt_is_space(g)
                # A joiner: it stands for the whole whitespace run at
                # `i`, and wears that run's style.
                sty = i <= n ? src[i][2] : STYLE_NONE
                while i <= n && _rt_is_space(src[i][1])
                    i += 1
                end
                push!(acc, TextRun(String(g), sty))
            else
                while i <= n && _rt_is_space(src[i][1])
                    i += 1
                end
                sty = i <= n ? src[i][2] : STYLE_NONE
                i <= n && (i += 1)
                push!(acc, TextRun(String(g), sty))
            end
        end
        out[li] = RichText(acc)
    end
    return out
end
