# ansi.jl -- layer 4. May reference: diff, buffer, style, color, geometry.
# E2 (minimal byte stream), S2 (alt screen sequences), X1 (degradation).
#
# Everything here writes to an `IO` -- an `IOBuffer` in tests, the
# driver's `outbuf` in production. NOTHING in this file knows what a
# terminal is.

"""
Raw escape-sequence vocabulary. Constants and pure builders only.
"""
module Ansi

using DocStringExtensions
using ..DualUI: Color, ColorKind, ColorDepth, degrade

@template (FUNCTIONS, METHODS) = """
    $(TYPEDSIGNATURES)
    $(DOCSTRING)
    """

const ESC = "\e"
const CSI = "\e["

const ALT_SCREEN_ENTER = "\e[?1049h"
const ALT_SCREEN_EXIT = "\e[?1049l"
const CURSOR_HIDE = "\e[?25l"
const CURSOR_SHOW = "\e[?25h"
const CURSOR_SAVE = "\e7"
const CURSOR_RESTORE = "\e8"
const CLEAR_SCREEN = "\e[2J"
const CLEAR_LINE_RIGHT = "\e[0K"
const SGR_RESET = "\e[0m"
const MOUSE_ON = "\e[?1000h\e[?1002h\e[?1003h\e[?1006h"
const MOUSE_OFF = "\e[?1006l\e[?1003l\e[?1002l\e[?1000l"
const PASTE_ON = "\e[?2004h"
const PASTE_OFF = "\e[?2004l"
const FOCUS_ON = "\e[?1004h"
const FOCUS_OFF = "\e[?1004l"
const SYNC_BEGIN = "\e[?2026h"
const SYNC_END = "\e[?2026l"

"""
Cursor position: `\\e[{y};{x}H`. 1-based, and ROW FIRST on the wire even
though the API is `(x, y)`. Pure.
"""
cup(x::Int, y::Int)::String = string(CSI, y, ';', x, 'H')

"""
Write `cup(x, y)` straight to `io` without building the intermediate
`String`. Byte-identical to `write(io, cup(x, y))`; exists because this
runs once per non-contiguous span, every frame. Internal.
"""
function cup!(io::IO, x::Int, y::Int)::Nothing
    write(io, CSI)
    print(io, y)
    write(io, UInt8(';'))
    print(io, x)
    write(io, UInt8('H'))
    return nothing
end

"""
Cursor forward `n` columns. Pure.
"""
cuf(n::Int)::String = string(CSI, n, 'C')

"""
Select Graphic Rendition with the given codes. Pure.
"""
function sgr(codes::Int...)::String
    io = IOBuffer()
    write(io, CSI)
    for (i, c) in enumerate(codes)
        i == 1 || write(io, UInt8(';'))
        print(io, c)
    end
    write(io, UInt8('m'))
    return String(take!(io))
end

"""
Set the window title (OSC 0), BEL-terminated. Pure.
"""
title(s::AbstractString)::String = string("\e]0;", s, '\a')

"""
X1. Write the SGR sequence selecting `c` at `depth` to `io`.

`base` is `30` for a foreground and `40` for a background; every other
code is derived from it, so the two planes cannot drift apart. `c` is
degraded HERE -- this is the one place in the package where an
authorial-intent color meets a device. An `UNSET` color writes nothing:
it means "inherit", which on the wire is silence. Internal.
"""
function color_seq!(io::IO, c::Color, depth::ColorDepth.T,
                    base::Int)::Nothing
    d = degrade(c, depth)
    k = d.kind
    if k === ColorKind.UNSET
        return nothing
    elseif k === ColorKind.DEFAULT
        write(io, CSI)
        print(io, base + 9)
        write(io, UInt8('m'))
    elseif k === ColorKind.ANSI16
        i = Int(d.r)
        write(io, CSI)
        print(io, i < 8 ? base + i : base + 60 + (i - 8))
        write(io, UInt8('m'))
    elseif k === ColorKind.ANSI256
        write(io, CSI)
        print(io, base + 8)
        write(io, ";5;")
        print(io, Int(d.r))
        write(io, UInt8('m'))
    else
        write(io, CSI)
        print(io, base + 8)
        write(io, ";2;")
        print(io, Int(d.r))
        write(io, UInt8(';'))
        print(io, Int(d.g))
        write(io, UInt8(';'))
        print(io, Int(d.b))
        write(io, UInt8('m'))
    end
    return nothing
end

"""
Foreground SGR sequence for `c` at `depth`; `""` when `c` is UNSET.
Pure.
"""
function fg_seq(c::Color, depth::ColorDepth.T)::String
    io = IOBuffer()
    color_seq!(io, c, depth, 30)
    return String(take!(io))
end

"""
Background SGR sequence for `c` at `depth`; `""` when `c` is UNSET.
Pure.
"""
function bg_seq(c::Color, depth::ColorDepth.T)::String
    io = IOBuffer()
    color_seq!(io, c, depth, 40)
    return String(take!(io))
end

end # module Ansi

"""
`Attr.T` paired with its SGR "turn on" sequence, in ascending code
order. Pre-rendered so the encoder writes a `const String` instead of
building one per cell. Code 6 is unassigned; 22/23/... (the "off"
codes) are deliberately absent -- see `sgr!`.
"""
const SGR_ATTR_ON = ((Attr.BOLD, "\e[1m"),
                     (Attr.DIM, "\e[2m"),
                     (Attr.ITALIC, "\e[3m"),
                     (Attr.UNDERLINE, "\e[4m"),
                     (Attr.BLINK, "\e[5m"),
                     (Attr.REVERSE, "\e[7m"),
                     (Attr.HIDDEN, "\e[8m"),
                     (Attr.STRIKE, "\e[9m"))

"""
The attributes of `s` that are both specified AND on, as a raw bitset.
An unspecified attribute is not on. Internal.
"""
@inline attrs_on(s::Style)::AttrMask = s.attrs & s.mask

"""
Stateful minimal-byte encoder.

Tracks the last emitted SGR state and cursor position ACROSS FRAMES, so
redundant sequences are never written -- the other half of E2's
"minimal set". `depth` drives X1's degradation, applied HERE and
NOWHERE ELSE.
"""
mutable struct AnsiEncoder
    "Target color depth; the sole input to X1's degradation."
    depth::ColorDepth.T
    "Last SGR state actually emitted."
    style::Style
    "Last known cursor position."
    cursor::Offset
    "False when cursor/style tracking is not trustworthy."
    synced::Bool
    "Emit SYNC_BEGIN/SYNC_END around each patch."
    sync_frames::Bool
end

"""
A fresh encoder for `depth`, with no trusted cursor or style state.
"""
AnsiEncoder(depth::ColorDepth.T;
            sync_frames::Bool = true)::AnsiEncoder =
    AnsiEncoder(depth, STYLE_NONE, ORIGIN, false, sync_frames)

"""
Invalidate tracking: `synced = false`, `style = STYLE_NONE`. Forces a
full re-emit on the next `encode!`.

MUST be called from `invalidate!(app)`. Discarding the front buffer
alone is NOT sufficient for reconnect: a fresh xterm.js has default SGR
while the encoder still believes it last emitted bold.

`STYLE_NONE` is the right "unknown" here rather than `STYLE_DEFAULT`:
its colors are UNSET, so the next cell re-states its fg and bg
explicitly instead of assuming the target already shows them.
"""
function reset!(e::AnsiEncoder)::Nothing
    e.synced = false
    e.style = STYLE_NONE
    e.cursor = ORIGIN
    return nothing
end

"""
Emit the minimal SGR delta from `from` to `to` at `depth`. Pure with
respect to everything but `io`.

NORMATIVE: emits a full `SGR_RESET` first IFF any attribute must be
turned OFF -- per-attribute off codes are not used, because code 22 is
ambiguous between bold and dim. Both styles MUST already be `resolve`d.

Because `SGR_RESET` also clears the colors, the baseline after one is
`STYLE_DEFAULT`, and any color `to` still wants is re-stated.

LAW: `sgr!(io, s, s, d)` writes ZERO bytes. More strongly: two styles
that are distinct but *degrade alike* at `depth` also write zero bytes,
which is what makes the encoder minimal on a 16-color target.
"""
function sgr!(io::IO, from::Style, to::Style,
              depth::ColorDepth.T)::Nothing
    from === to && return nothing
    f = degrade(from, depth)
    t = degrade(to, depth)
    f === t && return nothing

    on_t = attrs_on(t)
    if (attrs_on(f) & ~on_t) != 0x0000
        write(io, Ansi.SGR_RESET)
        f = STYLE_DEFAULT
    end

    add = on_t & ~attrs_on(f)
    if add != 0x0000
        for (a, seq) in SGR_ATTR_ON
            (add & UInt16(a)) == 0x0000 || write(io, seq)
        end
    end
    t.fg === f.fg || Ansi.color_seq!(io, t.fg, depth, 30)
    t.bg === f.bg || Ansi.color_seq!(io, t.bg, depth, 40)
    return nothing
end

"""
Encode one `Span`, advancing `e`'s cursor and style tracking. A CUP is
written only when the cursor is not already standing on the cell.

The grid column advances by one per `Cell`; the TERMINAL cursor advances
by `cell.width`. Those differ for a wide grapheme, and keeping them
apart is what lets a `CELL_CONT` cost zero bytes. Internal.
"""
function encode_span!(io::IO, e::AnsiEncoder, s::Span)::Nothing
    y = s.y
    col = s.x
    for c in s.cells
        # S3: a continuation emits NOTHING. The head's wide glyph
        # already moved the terminal cursor across this column;
        # writing a space here is the classic wide-char corruption.
        if c.width == Int8(0)
            col += 1
            continue
        end
        if !e.synced || e.cursor.x != col || e.cursor.y != y
            Ansi.cup!(io, col, y)
            e.synced = true
        end
        sgr!(io, e.style, c.style, e.depth)
        e.style = c.style
        print(io, c.content)
        e.cursor = Offset(col + Int(c.width), y)
        col += 1
    end
    return nothing
end

"""
E2 + X1. Encode `p` into `io`.

  * `p.full` emits CLEAR_SCREEN + SGR_RESET and calls `reset!(e)` first.
  * `e.sync_frames` wraps the whole patch in SYNC_BEGIN/SYNC_END.
  * CUP is emitted only when `e.cursor` is not already in place -- spans
    run left-to-right, top-to-bottom, so intra-span advance is free.
  * SGR is emitted only when the style actually changes, tracked across
    the WHOLE patch and across frames via `e.style`.
  * Colors pass through `degrade(_, e.depth)` HERE.
  * S3: `CELL_CONT` cells emit NO bytes -- the terminal already advanced
    the cursor two columns for the wide glyph. Emitting a continuation
    as a space is the classic wide-char corruption bug.
  * `e.cursor` and `e.style` are updated to reflect what was emitted.

A patch with no spans and `full == false` writes ZERO bytes: nothing
changed, so nothing -- not even a sync wrapper -- goes on the wire.
"""
function encode!(io::IO, e::AnsiEncoder, p::Patch)::Nothing
    if !p.full && isempty(p.spans)
        return nothing
    end
    e.sync_frames && write(io, Ansi.SYNC_BEGIN)
    if p.full
        write(io, Ansi.CLEAR_SCREEN)
        write(io, Ansi.SGR_RESET)
        reset!(e)
    end
    for s in p.spans
        encode_span!(io, e, s)
    end
    e.sync_frames && write(io, Ansi.SYNC_END)
    return nothing
end

"""
`encode!` into a fresh byte vector.
"""
function encode(e::AnsiEncoder, p::Patch)::Vector{UInt8}
    io = IOBuffer()
    encode!(io, e, p)
    return take!(io)
end
