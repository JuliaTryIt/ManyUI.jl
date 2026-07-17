# style.jl -- layer 2. May reference: color.
# U4 (the cascade fold) and X1 (attribute degradation).

"""
Text rendition attributes. Values are powers of two: they are used as
bit positions in an `AttrMask`.
"""
module Attr
@enum T::UInt16 begin
    BOLD = 0x0001
    DIM = 0x0002
    ITALIC = 0x0004
    UNDERLINE = 0x0008
    BLINK = 0x0010
    REVERSE = 0x0020
    HIDDEN = 0x0040
    STRIKE = 0x0080
end
end

"""
Bitset over `Attr.T` values.
"""
const AttrMask = UInt16

"""
A resolved text style: two colors plus a tri-state attribute set.
`isbits`, 12 bytes.

`attrs` holds attribute VALUES; `mask` holds which of them are
EXPLICITLY SPECIFIED. The tri-state is required: without the mask,
`bold: false` in a stylesheet cannot override an inherited bold -- the
same problem `COLOR_UNSET` solves for colors.
"""
struct Style
    "Foreground color; `COLOR_UNSET` means inherit."
    fg::Color
    "Background color; `COLOR_UNSET` means inherit. Not inheritable."
    bg::Color
    "Attribute values: bit set means the attribute is ON."
    attrs::AttrMask
    "Attribute mask: bit set means the attribute is SPECIFIED."
    mask::AttrMask
end

const STYLE_NONE = Style(COLOR_UNSET, COLOR_UNSET, 0x0000, 0x0000)
const STYLE_DEFAULT = Style(COLOR_DEFAULT, COLOR_DEFAULT, 0x0000, 0xffff)

# Folds one tri-state kwarg into an (attrs, mask) pair. `nothing`
# leaves both words alone; `true`/`false` both set the mask.
@inline function _fold_attr(attrs::AttrMask, mask::AttrMask, a::Attr.T,
                            v::Union{Nothing,Bool})
    v === nothing && return (attrs, mask)
    bit = UInt16(a)
    return (v ? (attrs | bit) : (attrs & ~bit), mask | bit)
end

"""
Keyword constructor. `nothing` leaves an attribute UNSPECIFIED; `true`
and `false` both SET the mask, with the value on or off respectively.
"""
function Style(; fg::Color = COLOR_UNSET,
               bg::Color = COLOR_UNSET,
               bold::Union{Nothing,Bool} = nothing,
               dim::Union{Nothing,Bool} = nothing,
               italic::Union{Nothing,Bool} = nothing,
               underline::Union{Nothing,Bool} = nothing,
               blink::Union{Nothing,Bool} = nothing,
               reverse::Union{Nothing,Bool} = nothing,
               hidden::Union{Nothing,Bool} = nothing,
               strike::Union{Nothing,Bool} = nothing)::Style
    a = 0x0000
    m = 0x0000
    (a, m) = _fold_attr(a, m, Attr.BOLD, bold)
    (a, m) = _fold_attr(a, m, Attr.DIM, dim)
    (a, m) = _fold_attr(a, m, Attr.ITALIC, italic)
    (a, m) = _fold_attr(a, m, Attr.UNDERLINE, underline)
    (a, m) = _fold_attr(a, m, Attr.BLINK, blink)
    (a, m) = _fold_attr(a, m, Attr.REVERSE, reverse)
    (a, m) = _fold_attr(a, m, Attr.HIDDEN, hidden)
    (a, m) = _fold_attr(a, m, Attr.STRIKE, strike)
    return Style(fg, bg, a, m)
end

"""
True when `a` is both specified AND on. Pure.
"""
has(s::Style, a::Attr.T)::Bool = (s.attrs & s.mask & UInt16(a)) != 0

"""
True when `a` is specified at all, on or off. Pure.
"""
specified(s::Style, a::Attr.T)::Bool = (s.mask & UInt16(a)) != 0

"""
Copy of `s` with `a` specified and set to `on`. Pure.
"""
function with(s::Style, a::Attr.T, on::Bool)::Style
    bit = UInt16(a)
    attrs = on ? (s.attrs | bit) : (s.attrs & ~bit)
    return Style(s.fg, s.bg, attrs, s.mask | bit)
end

"""
Copy of `s` with `a` unspecified -- clears both the value and the mask.
Pure.
"""
function without(s::Style, a::Attr.T)::Style
    bit = UInt16(a)
    return Style(s.fg, s.bg, s.attrs & ~bit, s.mask & ~bit)
end

"""
Right-biased, per-property merge: `over` wins wherever it specifies.

A monoid -- associative, with identity `STYLE_NONE`. This IS the
cascade fold. NORMATIVE:

    fg    = is_set(over.fg) ? over.fg : base.fg
    bg    = is_set(over.bg) ? over.bg : base.bg
    mask  = base.mask | over.mask
    attrs = (base.attrs & ~over.mask) | (over.attrs & over.mask)

Pure.
"""
function Base.merge(base::Style, over::Style)::Style
    fg = is_set(over.fg) ? over.fg : base.fg
    bg = is_set(over.bg) ? over.bg : base.bg
    attrs = (base.attrs & ~over.mask) | (over.attrs & over.mask)
    return Style(fg, bg, attrs, base.mask | over.mask)
end

"""
The inheritable subset of `s`: the foreground and all text attributes.
NOT the background. Pure.
"""
inheritable(s::Style)::Style = Style(s.fg, COLOR_UNSET, s.attrs, s.mask)

"""
Replace UNSET colors with DEFAULT. Call once, at the root, before
emission. Pure.
"""
function resolve(s::Style)::Style
    fg = is_unset(s.fg) ? COLOR_DEFAULT : s.fg
    bg = is_unset(s.bg) ? COLOR_DEFAULT : s.bg
    return Style(fg, bg, s.attrs, s.mask)
end

# The attributes a MONOCHROME target cannot render. BOLD, UNDERLINE and
# REVERSE survive: every one of them is a shape change, not a colour.
const MONO_DROP_MASK = UInt16(Attr.DIM) | UInt16(Attr.ITALIC) |
                       UInt16(Attr.BLINK) | UInt16(Attr.HIDDEN) |
                       UInt16(Attr.STRIKE)

"""
X1. Degrade `fg` and `bg` to `depth`.

At MONOCHROME, also drops DIM/ITALIC/BLINK/STRIKE/HIDDEN from the mask
and keeps BOLD/UNDERLINE/REVERSE. Pure and idempotent.
"""
function degrade(s::Style, depth::ColorDepth.T)::Style
    fg = degrade(s.fg, depth)
    bg = degrade(s.bg, depth)
    if depth === ColorDepth.MONOCHROME
        # Cleared from BOTH words, not just the mask, so the result
        # stays canonical (`attrs & ~mask == 0`) and a later merge
        # cannot resurrect a dropped bit.
        return Style(fg, bg, s.attrs & ~MONO_DROP_MASK,
                     s.mask & ~MONO_DROP_MASK)
    end
    return Style(fg, bg, s.attrs, s.mask)
end

# name => Attr.T, in `Attr.T` declaration order.
const ATTR_NAMES = (("bold", Attr.BOLD),
                    ("dim", Attr.DIM),
                    ("italic", Attr.ITALIC),
                    ("underline", Attr.UNDERLINE),
                    ("blink", Attr.BLINK),
                    ("reverse", Attr.REVERSE),
                    ("hidden", Attr.HIDDEN),
                    ("strike", Attr.STRIKE))

function _attr_bit(name::AbstractString)
    for (n, a) in ATTR_NAMES
        n == name && return UInt16(a)
    end
    return nothing
end

"""
Parse a `text-style` property value into `(attrs, mask)`.

`"bold italic"` sets both bits in both words. A leading `no-` sets the
mask with the value off: `"no-bold"` -> `attrs = 0`, `mask = BOLD`.
Pure.
"""
function parse_attrs(s::AbstractString)::Tuple{AttrMask,AttrMask}
    attrs = 0x0000
    mask = 0x0000
    for tok in eachsplit(lowercase(s))
        negated = startswith(tok, "no-")
        name = negated ? SubString(tok, 4) : SubString(tok, 1)
        bit = _attr_bit(name)
        bit === nothing && throw(ArgumentError(
            "unknown text-style token $(repr(String(tok)))"))
        mask |= bit
        attrs = negated ? (attrs & ~bit) : (attrs | bit)
    end
    return (attrs, mask)
end
