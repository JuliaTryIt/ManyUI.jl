# color.jl -- layer 1. May reference: types.
# X1 lives here. Colors are ALWAYS authorial-intent in the model;
# `degrade` is applied once, in `AnsiEncoder`, and nowhere else.

"""
How a `Color`'s bytes are to be read.
"""
module ColorKind
@enum T::UInt8 begin
    UNSET = 0    # not specified -- inherit; the cascade sentinel
    DEFAULT = 1  # explicit terminal default (SGR 39 / 49)
    ANSI16 = 2   # palette index in `r`, 0:15
    ANSI256 = 3  # palette index in `r`, 0:255
    RGB = 4      # 24-bit `r`, `g`, `b`
end
end

"""
What a target can display. ORDERED, so `depth < ColorDepth.TRUECOLOR`
is a legal capability test.
"""
module ColorDepth
@enum T::UInt8 begin
    MONOCHROME = 0
    ANSI16 = 1
    ANSI256 = 2
    TRUECOLOR = 3
end
end

"""
A 4-byte tagged color value. `isbits`, deliberately NOT an abstract
hierarchy: `Style` is a field of `Cell` and a `Matrix{Cell}` is copied
every frame.
"""
struct Color
    "How to read `r`, `g`, `b`."
    kind::ColorKind.T
    "Red channel, or the palette index for ANSI16/ANSI256."
    r::UInt8
    "Green channel."
    g::UInt8
    "Blue channel."
    b::UInt8
end

const COLOR_UNSET = Color(ColorKind.UNSET, 0, 0, 0)
const COLOR_DEFAULT = Color(ColorKind.DEFAULT, 0, 0, 0)

# --- construction ---------------------------------------------------

@inline function _channel(v::Integer, what::String)::UInt8
    0 <= v <= 255 ||
        throw(ArgumentError("$what channel must be in 0:255, got $v"))
    return UInt8(v)
end

"""
A TrueColor value from three 0:255 channels. Pure.
"""
rgb(r::Integer, g::Integer, b::Integer)::Color =
    Color(ColorKind.RGB, _channel(r, "red"), _channel(g, "green"),
          _channel(b, "blue"))

"""
A TrueColor value from a packed hex literal, e.g. `rgb(0xff8800)`.
Accepts `0 <= hex <= 0xffffff`. Pure.
"""
function rgb(hex::Integer)::Color
    0 <= hex <= 0xffffff ||
        throw(ArgumentError("hex must be in 0:0xffffff, got $hex"))
    h = UInt32(hex)
    return Color(ColorKind.RGB, UInt8((h >> 16) & 0xff),
                 UInt8((h >> 8) & 0xff), UInt8(h & 0xff))
end

"""
A 16-color palette entry, `0 <= i <= 15`. Throws `ArgumentError`
otherwise. Pure.
"""
function ansi16(i::Integer)::Color
    0 <= i <= 15 ||
        throw(ArgumentError("ansi16 index must be in 0:15, got $i"))
    return Color(ColorKind.ANSI16, UInt8(i), 0x00, 0x00)
end

"""
A 256-color palette entry, `0 <= i <= 255`. Throws `ArgumentError`
otherwise. Pure.
"""
function ansi256(i::Integer)::Color
    0 <= i <= 255 ||
        throw(ArgumentError("ansi256 index must be in 0:255, got $i"))
    return Color(ColorKind.ANSI256, UInt8(i), 0x00, 0x00)
end

"""
True when `c` specifies nothing and must inherit. Pure.
"""
is_unset(c::Color)::Bool = c.kind === ColorKind.UNSET

"""
True when `c` specifies something. Pure.
"""
is_set(c::Color)::Bool = !is_unset(c)

"""
Palette index of an ANSI16/ANSI256 color. Pure.
"""
function color_index(c::Color)::UInt8
    c.kind === ColorKind.ANSI16 || c.kind === ColorKind.ANSI256 ||
        throw(ArgumentError(
            "color_index is defined for ANSI16/ANSI256 only, got " *
            string(c.kind)))
    return c.r
end

# --- palettes -------------------------------------------------------

"""
The 16 system colors, in the xterm/VGA arrangement: 0:7 are the dim
half, 8:15 the bright half. `[I]` data owned by this file.
"""
const ANSI16_PALETTE = ((0x00, 0x00, 0x00),   #  0 black
                        (0x80, 0x00, 0x00),   #  1 red
                        (0x00, 0x80, 0x00),   #  2 green
                        (0x80, 0x80, 0x00),   #  3 yellow
                        (0x00, 0x00, 0x80),   #  4 blue
                        (0x80, 0x00, 0x80),   #  5 magenta
                        (0x00, 0x80, 0x80),   #  6 cyan
                        (0xc0, 0xc0, 0xc0),   #  7 white
                        (0x80, 0x80, 0x80),   #  8 bright black
                        (0xff, 0x00, 0x00),   #  9 bright red
                        (0x00, 0xff, 0x00),   # 10 bright green
                        (0xff, 0xff, 0x00),   # 11 bright yellow
                        (0x00, 0x00, 0xff),   # 12 bright blue
                        (0xff, 0x00, 0xff),   # 13 bright magenta
                        (0x00, 0xff, 0xff),   # 14 bright cyan
                        (0xff, 0xff, 0xff))   # 15 bright white

"""
The six per-channel levels of the 6x6x6 cube: 0, 95, 135, 175, 215,
255. `[I]`.
"""
const CUBE_LEVELS = (0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff)

function _build_ansi256_palette()
    v = Vector{NTuple{3,UInt8}}(undef, 256)
    for i in 0:15                       # the 16 system colors
        v[i+1] = ANSI16_PALETTE[i+1]
    end
    for i in 16:231                     # the 6x6x6 cube
        n = i - 16
        v[i+1] = (CUBE_LEVELS[(n ÷ 36)+1],
                  CUBE_LEVELS[((n ÷ 6) % 6)+1],
                  CUBE_LEVELS[(n % 6)+1])
    end
    for i in 232:255                    # the 24-step grey ramp
        l = UInt8(8 + 10 * (i - 232))
        v[i+1] = (l, l, l)
    end
    return NTuple{256,NTuple{3,UInt8}}(v)
end

"""
The xterm 256-color palette: 0:15 system, 16:231 the 6x6x6 cube
(`16 + 36r + 6g + b`), 232:255 the grey ramp (`8 + 10i`). `[I]`.
"""
const ANSI256_PALETTE = _build_ansi256_palette()

"""
The color names `parse(Color, s)` and `color(name)` accept. `[I]`.
"""
const NAMED_COLORS = Dict{Symbol,Color}(
    :black => ansi16(0),
    :red => ansi16(1),
    :green => ansi16(2),
    :yellow => ansi16(3),
    :blue => ansi16(4),
    :magenta => ansi16(5),
    :cyan => ansi16(6),
    :white => ansi16(7),
    :bright_black => ansi16(8),
    :bright_red => ansi16(9),
    :bright_green => ansi16(10),
    :bright_yellow => ansi16(11),
    :bright_blue => ansi16(12),
    :bright_magenta => ansi16(13),
    :bright_cyan => ansi16(14),
    :bright_white => ansi16(15),
    :grey => ansi16(8),
    :gray => ansi16(8),
    :default => COLOR_DEFAULT,
    :transparent => COLOR_UNSET,
)

"""
Look up a named color, e.g. `color(:bright_black)`. Throws `KeyError`
when unknown. Pure.
"""
color(name::Symbol)::Color = NAMED_COLORS[name]

"""
Resolve ANSI16/ANSI256 to RGB via the palette; identity on RGB.

Throws `ArgumentError` on UNSET/DEFAULT -- they have no RGB value.
Pure.
"""
function to_rgb(c::Color)::Color
    k = c.kind
    if k === ColorKind.RGB
        return c
    elseif k === ColorKind.ANSI16
        (r, g, b) = @inbounds ANSI16_PALETTE[Int(c.r)+1]
        return Color(ColorKind.RGB, r, g, b)
    elseif k === ColorKind.ANSI256
        (r, g, b) = @inbounds ANSI256_PALETTE[Int(c.r)+1]
        return Color(ColorKind.RGB, r, g, b)
    else
        throw(ArgumentError(
            "to_rgb: " * string(k) * " has no RGB value"))
    end
end

# --- perceptual metric ----------------------------------------------

# Rec. 709 luminance coefficients. They sum to exactly 1.0, so
# `luminance` lands in 0..1 with white == 1.0 and black == 0.0.
const LUM_R = 0.2126
const LUM_G = 0.7152
const LUM_B = 0.0722

"""
Decode one sRGB byte to a linear 0..1 intensity. `[I]`, and the reason
the metric below is perceptual rather than a raw byte difference.
"""
@inline function _linearize(v::UInt8)::Float64
    f = v / 255
    return f <= 0.04045 ? f / 12.92 : ((f + 0.055) / 1.055)^2.4
end

@inline function _linear_triple(c::Color)
    t = to_rgb(c)
    return (_linearize(t.r), _linearize(t.g), _linearize(t.b))
end

@inline function _wdist2(ar::Float64, ag::Float64, ab::Float64,
                         br::Float64, bg::Float64, bb::Float64)::Float64
    dr = ar - br
    dg = ag - bg
    db = ab - bb
    return LUM_R * dr * dr + LUM_G * dg * dg + LUM_B * db * db
end

"""
Relative luminance in 0..1, computed from sRGB-decoded (linear)
channels. Pure.
"""
function luminance(c::Color)::Float64
    (lr, lg, lb) = _linear_triple(c)
    return LUM_R * lr + LUM_G * lg + LUM_B * lb
end

"""
Weighted-RGB distance in LINEAR (sRGB-decoded) space -- raw-byte
distance maps mid-greys to blue.

NORMATIVE tie-break: when two candidates are equidistant the LOWER
palette index wins. Without this, `rgb_to_ansi256`'s test vectors are
implementation-dependent. Pure.
"""
function color_distance(a::Color, b::Color)::Float64
    (ar, ag, ab) = _linear_triple(a)
    (br, bg, bb) = _linear_triple(b)
    return sqrt(_wdist2(ar, ag, ab, br, bg, bb))
end

# Linear values of the candidate sets, precomputed so a search costs no
# `^` at all: three decodes for the target, then table lookups.
const CUBE_LIN = ntuple(i -> _linearize(CUBE_LEVELS[i]), 6)
const GREY_LIN = ntuple(i -> _linearize(UInt8(8 + 10 * (i - 1))), 24)
const ANSI16_LIN = ntuple(i -> map(_linearize, ANSI16_PALETTE[i]), 16)

"""
Nearest 256-color entry: the 6x6x6 cube, the 24 greys, and the 16
system colors. Pure.
"""
function rgb_to_ansi256(c::Color)::Color
    (tr, tg, tb) = _linear_triple(c)
    best = 16
    bestd = Inf
    # The candidate set is 16:255 ONLY. The system colors 0:15 are
    # deliberately excluded: they are the entries a user has remapped
    # via OSC 4 and the ones a theme repaints, so snapping authorial
    # RGB onto them would make degradation theme-dependent. This is
    # what pins the contract's vectors -- black is 16 (not 0), white
    # 231 (not 15), red 196 (not 9), #808080 244 (not 8).
    #
    # Ascending scan + strict `<` IS the "lower index wins" tie-break.
    for lr in 0:5, lg in 0:5, lb in 0:5
        d = _wdist2(tr, tg, tb, (@inbounds CUBE_LIN[lr+1]),
                    (@inbounds CUBE_LIN[lg+1]),
                    (@inbounds CUBE_LIN[lb+1]))
        if d < bestd
            bestd = d
            best = 16 + 36 * lr + 6 * lg + lb
        end
    end
    for i in 1:24
        gl = @inbounds GREY_LIN[i]
        d = _wdist2(tr, tg, tb, gl, gl, gl)
        if d < bestd
            bestd = d
            best = 231 + i
        end
    end
    return ansi256(best)
end

"""
Nearest 16-color entry. Pure.
"""
function ansi256_to_ansi16(c::Color)::Color
    (tr, tg, tb) = _linear_triple(c)
    best = 0
    bestd = Inf
    for i in 1:16                       # ascending: ties go to 0:15 low
        (pr, pg, pb) = @inbounds ANSI16_LIN[i]
        d = _wdist2(tr, tg, tb, pr, pg, pb)
        if d < bestd
            bestd = d
            best = i - 1
        end
    end
    return ansi16(best)
end

"""
NORMATIVE: defined AS the composition, not independently.

    rgb_to_ansi16(c) === ansi256_to_ansi16(rgb_to_ansi256(c))

One tested table; TrueColor->16 and TrueColor->256->16 cannot disagree.
Pure.
"""
rgb_to_ansi16(c::Color)::Color = ansi256_to_ansi16(rgb_to_ansi256(c))

"""
X1. Map an authorial-intent color onto what `depth` can show.

Pure, TOTAL and IDEMPOTENT: `degrade(degrade(c, d), d) === degrade(c, d)`.

Called ONLY from `AnsiEncoder`. Never in the buffer, never in layout.
At MONOCHROME the result is white or black by luminance -- never
`COLOR_DEFAULT`, which would discard the fg/bg distinction.

| kind \\ depth | TRUECOLOR | ANSI256 | ANSI16 | MONOCHROME |
|:--|:--|:--|:--|:--|
| `RGB` | identity | `rgb_to_ansi256` | `rgb_to_ansi16` | lum >= 0.5 ? 15 : 0 |
| `ANSI256` | identity | identity | `ansi256_to_ansi16` | as above |
| `ANSI16` | identity | identity | identity | idx in (7, 15) ? 15 : 0 |
| `DEFAULT` | identity | identity | identity | identity |
| `UNSET` | identity | identity | identity | identity |
"""
function degrade(c::Color, depth::ColorDepth.T)::Color
    k = c.kind
    # UNSET and DEFAULT are not colors, they are instructions. No depth
    # may rewrite them.
    (k === ColorKind.UNSET || k === ColorKind.DEFAULT) && return c
    if depth === ColorDepth.TRUECOLOR
        return c
    elseif depth === ColorDepth.ANSI256
        return k === ColorKind.RGB ? rgb_to_ansi256(c) : c
    elseif depth === ColorDepth.ANSI16
        if k === ColorKind.RGB
            return rgb_to_ansi16(c)
        elseif k === ColorKind.ANSI256
            return ansi256_to_ansi16(c)
        else
            return c
        end
    else                                # MONOCHROME
        if k === ColorKind.ANSI16
            # Index-based, not luminance-based: the 16 entries are
            # user-remappable, so their nominal luminance is a guess.
            # 7 and 15 are the only two a monochrome target shows lit.
            return (c.r == 0x07 || c.r == 0x0f) ? ansi16(15) : ansi16(0)
        end
        return luminance(c) >= 0.5 ? ansi16(15) : ansi16(0)
    end
end

# --- parsing --------------------------------------------------------

# Returns the integer body of `name(...)`, or nothing if `s` is not
# that call form or the body is not a bare integer.
function _paren_arg(s::AbstractString, name::String)
    n = length(name)
    (length(s) >= n + 2 && startswith(s, name) &&
     s[nextind(s, 0, n + 1)] == '(' && endswith(s, ')')) || return nothing
    body = SubString(s, nextind(s, 0, n + 2), prevind(s, lastindex(s)))
    return tryparse(Int, strip(body))
end

function _parse_hex(s::AbstractString)
    body = SubString(s, 2)
    all(c -> c in "0123456789abcdef", body) || return nothing
    if length(body) == 3
        v = tryparse(UInt16, body; base = 16)
        v === nothing && return nothing
        # #rgb -> #rrggbb: each nibble is doubled.
        r = UInt8(((v >> 8) & 0xf) * 0x11)
        g = UInt8(((v >> 4) & 0xf) * 0x11)
        b = UInt8((v & 0xf) * 0x11)
        return Color(ColorKind.RGB, r, g, b)
    elseif length(body) == 6
        v = tryparse(UInt32, body; base = 16)
        v === nothing && return nothing
        return rgb(v)
    end
    return nothing
end

function _parse_rgb_call(s::AbstractString)
    body = SubString(s, 5, prevind(s, lastindex(s)))
    parts = split(body, ',')
    length(parts) == 3 || return nothing
    vals = ntuple(i -> tryparse(Int, strip(parts[i])), 3)
    for v in vals
        (v === nothing && return nothing)
        0 <= v <= 255 || return nothing
    end
    return Color(ColorKind.RGB, UInt8(vals[1]), UInt8(vals[2]),
                 UInt8(vals[3]))
end

"""
Parse a color. Returns `nothing` instead of throwing.

Accepted forms: `#rgb`, `#rrggbb`, `rgb(255,136,0)`, `red`,
`bright_black`, `ansi(9)`, `color(200)`, `default`, `transparent`
(-> `COLOR_UNSET`). Pure.
"""
function Base.tryparse(::Type{Color},
                       s::AbstractString)::Union{Color,Nothing}
    t = lowercase(strip(s))
    isempty(t) && return nothing
    if startswith(t, '#')
        return _parse_hex(t)
    elseif startswith(t, "rgb(") && endswith(t, ')')
        return _parse_rgb_call(t)
    elseif startswith(t, "ansi(")
        i = _paren_arg(t, "ansi")
        return (i === nothing || !(0 <= i <= 15)) ? nothing : ansi16(i)
    elseif startswith(t, "color(")
        i = _paren_arg(t, "color")
        return (i === nothing || !(0 <= i <= 255)) ? nothing : ansi256(i)
    end
    return get(NAMED_COLORS, Symbol(t), nothing)
end

"""
Parse a color, throwing `ArgumentError` on garbage. Pure.
"""
function Base.parse(::Type{Color}, s::AbstractString)::Color
    c = tryparse(Color, s)
    c === nothing &&
        throw(ArgumentError("cannot parse $(repr(s)) as a Color"))
    return c
end

"""
Pure, table-testable environment probe -- no globals, no side effects.

NORMATIVE rules, in order:

    NO_COLOR set (any value)         -> MONOCHROME
    COLORTERM in {truecolor, 24bit}  -> TRUECOLOR
    TERM contains "256color"         -> ANSI256
    TERM == "dumb" or TERM unset     -> MONOCHROME
    otherwise                        -> ANSI16
"""
function detect_color_depth(env::AbstractDict = ENV)::ColorDepth.T
    haskey(env, "NO_COLOR") && return ColorDepth.MONOCHROME
    ct = get(env, "COLORTERM", "")
    (ct == "truecolor" || ct == "24bit") && return ColorDepth.TRUECOLOR
    haskey(env, "TERM") || return ColorDepth.MONOCHROME
    term = env["TERM"]
    occursin("256color", term) && return ColorDepth.ANSI256
    term == "dumb" && return ColorDepth.MONOCHROME
    return ColorDepth.ANSI16
end
