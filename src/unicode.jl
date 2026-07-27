# unicode.jl -- layer 1. May reference: types.
#
# Why this file exists: `Base.textwidth` sums codepoints and ignores
# grapheme clustering, so it reports 6 for a family emoji and 4 for a
# skin-toned thumbs-up. Delegating to it violates S3 and corrupts
# layout on the first emoji. Cluster first, then measure.

"Variation Selector-16: forces emoji (wide) presentation."
const VS16 = '️'

"Variation Selector-15: forces text (narrow) presentation."
const VS15 = '︎'

"Zero Width Joiner."
const ZWJ = '‍'

"First regional indicator, U+1F1E6 (letter A)."
const UW_RI_FIRST = UInt32(0x1F1E6)

"Last regional indicator, U+1F1FF (letter Z)."
const UW_RI_LAST = UInt32(0x1F1FF)

"""
Display cells for a single CODEPOINT: 0, 1 or 2. Pure.

Per-codepoint width comes straight from the Unicode width tables
(`Base.textwidth` on a `Char`, which is a table lookup, NOT the
codepoint-summing string method this file exists to avoid). The result
is clamped into `0:2`, and an invalid codepoint measures 0 so this
function is total and never throws on the render hot path.
"""
char_width(c::AbstractChar)::Int =
    isvalid(c) ? clamp(textwidth(c), 0, 2) : 0

"""
True when `c` occupies two cells. Pure.
"""
is_wide(c::AbstractChar)::Bool = char_width(c) == 2

"""
True when `c` occupies no cell of its own. Pure.
"""
is_combining(c::AbstractChar)::Bool = char_width(c) == 0

"""
True for U+1F1E6..U+1F1FF, the flag building blocks. Pure.
"""
function is_regional_indicator(c::AbstractChar)::Bool
    isvalid(c) || return false
    u = UInt32(codepoint(c))
    return UW_RI_FIRST <= u <= UW_RI_LAST
end

"""
Display cells for ONE grapheme cluster: 0, 1 or 2. Pure.

NORMATIVE rule, applied in order. Peek codepoints via `iterate`; MUST
NOT `collect` (that allocates a `Vector{Char}` per cell per frame).

 1. empty cluster                                    -> 0
 2. first two codepoints are both regional indicators -> 2
 3. cluster contains VS16 (U+FE0F)                    -> 2
 4. cluster ends with VS15 (U+FE0E)                   -> 1
 5. base (first) codepoint is a control               -> 0
 6. otherwise `clamp(char_width(base), 0, 2)` -- every trailing
    codepoint (ZWJ, skin tone modifier, combining mark) contributes 0.
"""
function grapheme_width(g::AbstractString)::Int
    st = iterate(g)
    st === nothing && return 0                       # rule 1
    base, pos = st
    nxt = iterate(g, pos)
    if nxt !== nothing && is_regional_indicator(base) &&
       is_regional_indicator(first(nxt))
        return 2                                     # rule 2
    end
    # One pass, no allocation: does the cluster contain VS16, and what
    # is its final codepoint?
    seen_vs16 = base == VS16
    last = base
    while nxt !== nothing
        c, pos = nxt
        seen_vs16 |= c == VS16
        last = c
        nxt = iterate(g, pos)
    end
    seen_vs16 && return 2                            # rule 3
    last == VS15 && return 1                         # rule 4
    iscntrl(base) && return 0                        # rule 5
    return clamp(char_width(base), 0, 2)             # rule 6
end

"""
Sum of `grapheme_width` over `Unicode.graphemes(s)`. Pure.

NEVER uses `textwidth(s)`.
"""
function text_width(s::AbstractString)::Int
    w = 0
    for g in Unicode.graphemes(s)
        w += grapheme_width(g)
    end
    return w
end

"""
Split `s` into `(cluster, width)` pairs -- the unit a `Buffer` stores.
Pure.
"""
function grapheme_cells(s::AbstractString)::Vector{Tuple{String,Int}}
    out = Tuple{String,Int}[]
    for g in Unicode.graphemes(s)
        push!(out, (String(g), grapheme_width(g)))
    end
    return out
end

"""
Reinterpret any string as a `String`-backed one, without copying when
it already is. Keeps `truncate_width`'s return type `SubString{String}`
type-stable for `String` and `SubString{String}` inputs alike.
"""
_uw_string_backed(s::String) = s
_uw_string_backed(s::SubString{String}) = s
_uw_string_backed(s::AbstractString) = String(s)

"""
Longest prefix of `s` whose `text_width` is `<= w`. A width-2 cluster
that would straddle `w` is DROPPED, not halved. Pure.
"""
function truncate_width(s::AbstractString, w::Int)::SubString{String}
    str = _uw_string_backed(s)
    w <= 0 && return SubString(str, 1, 0)
    acc = 0
    stop = 0            # codeunits consumed so far
    for g in Unicode.graphemes(str)
        gw = grapheme_width(g)
        acc + gw > w && break
        acc += gw
        stop += ncodeunits(g)
    end
    return SubString(str, 1, thisind(str, stop))
end

"""
Emit whole lines for a `word` wider than `w` and return the trailing
remainder, whose `text_width` is `<= w`.

A single cluster wider than the entire budget is given a line of its
own: halving it would corrupt the grid, and dropping it would lose
content and spin this loop forever.
"""
function _uw_break_word!(out::Vector{String}, word::AbstractString,
                      w::Int)::SubString{String}
    rest = SubString(_uw_string_backed(word), 1)
    while text_width(rest) > w
        head = truncate_width(rest, w)
        n = ncodeunits(head)
        if n == 0
            g = first(Unicode.graphemes(rest))
            n = ncodeunits(g)
            push!(out, String(g))
        else
            push!(out, String(head))
        end
        rest = SubString(rest, n + 1)
    end
    return rest
end

"""
Greedy word wrap on `text_width`. Breaks mid-word only when a single
word exceeds `w`. Never splits a grapheme cluster. Pure.

Words are whitespace-separated; an explicit newline is a hard break, so
a blank input line survives as an empty output line.
"""
function wrap_width(s::AbstractString, w::Int)::Vector{String}
    out = String[]
    (w <= 0 || isempty(s)) && return out
    for line in eachsplit(s, '\n')
        _uw_wrap_line!(out, line, w)
    end
    return out
end

"""
Greedily pack the words of one hard line into `out`.
"""
function _uw_wrap_line!(out::Vector{String}, line::AbstractString,
                     w::Int)::Nothing
    cur = ""
    curw = 0
    open = false        # `cur` holds a line not yet pushed
    seen = false        # this hard line had at least one word
    for word in eachsplit(line)
        seen = true
        ww = text_width(word)
        if open && curw + 1 + ww <= w
            cur = string(cur, ' ', word)
            curw += 1 + ww
            continue
        end
        open && push!(out, cur)
        if ww <= w
            cur = String(word)
            curw = ww
            open = true
        else
            tail = _uw_break_word!(out, word, w)
            cur = String(tail)
            curw = text_width(cur)
            open = curw > 0
        end
    end
    if open
        push!(out, cur)
    elseif !seen
        push!(out, "")      # preserve a blank hard line
    end
    return nothing
end
