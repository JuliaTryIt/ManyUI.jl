# input.jl -- layer 3. May reference: types, events, geometry.
# W4 (web input is zero new code) and E3.
#
# Source-agnostic BY CONSTRUCTION: bytes in, events out. Nothing in
# this file names a byte source, a terminal, a console or a network
# type. `TerminalDriver` pushes bytes from a raw keyboard;
# `WebSocketDriver` pushes bytes from a web frame. Same parser, same
# tests. A guard @testitem greps this file to keep it that way.

"Bit of `Modifier.SHIFT`, as carried in `Modifiers.bits`."
const _BIT_SHIFT = UInt8(Modifier.SHIFT)
"Bit of `Modifier.ALT`, as carried in `Modifiers.bits`."
const _BIT_ALT = UInt8(Modifier.ALT)
"Bit of `Modifier.CTRL`, as carried in `Modifiers.bits`."
const _BIT_CTRL = UInt8(Modifier.CTRL)
"Bit of `Modifier.SUPER`, as carried in `Modifiers.bits`."
const _BIT_SUPER = UInt8(Modifier.SUPER)

"The escape byte that introduces every recognised sequence."
const _ESC = 0x1b

# ---------------------------------------------------------------- UTF-8

"""
Number of bytes in the UTF-8 sequence introduced by `b`, or `0` when
`b` is not a valid leading byte. Pure.
"""
function _utf8_len(b::UInt8)::Int
    b < 0x80 && return 1
    (b & 0xe0) == 0xc0 && return 2
    (b & 0xf0) == 0xe0 && return 3
    (b & 0xf8) == 0xf0 && return 4
    return 0
end

"""
Decode the `len`-byte UTF-8 sequence at index `i`, or `nothing` when a
continuation byte is malformed, the encoding is overlong, or the code
point is not a valid `Char`. Never throws. Pure.
"""
function _utf8_decode(bytes::AbstractVector{UInt8}, i::Int,
                      len::Int)::Union{Char,Nothing}
    b = bytes[i]
    cp = len == 2 ? UInt32(b & 0x1f) :
         len == 3 ? UInt32(b & 0x0f) : UInt32(b & 0x07)
    for k in 1:(len - 1)
        c = bytes[i + k]
        (c & 0xc0) == 0x80 || return nothing
        cp = (cp << 6) | UInt32(c & 0x3f)
    end
    lo = len == 2 ? 0x00000080 : len == 3 ? 0x00000800 : 0x00010000
    cp < lo && return nothing
    isvalid(Char, cp) || return nothing
    return Char(cp)
end

# ----------------------------------------------------------- modifiers

"""
Turn an xterm modifier parameter into a `Modifiers` set: `m - 1` is a
bitfield of shift (1), alt (2), ctrl (4) and super (8). A missing or
`1` parameter means no modifiers. Pure.
"""
function _xterm_mods(m::Int)::Modifiers
    m <= 1 && return MOD_NONE
    f = (m - 1) & 0x0f
    r = 0x00
    (f & 0x01) != 0 && (r |= _BIT_SHIFT)
    (f & 0x02) != 0 && (r |= _BIT_ALT)
    (f & 0x04) != 0 && (r |= _BIT_CTRL)
    (f & 0x08) != 0 && (r |= _BIT_SUPER)
    return Modifiers(r)
end

"""
Add `Modifier.ALT` to a key event. This is how `ESC <key>` reports the
alt modifier on terminals with no dedicated encoding for it. Pure.
"""
_with_alt(e::KeyEvent)::KeyEvent =
    KeyEvent(e.code, e.char, Modifiers(e.mods.bits | _BIT_ALT))

"""
Modifier bits carried by an encoded mouse button value: shift (4),
alt (8) and ctrl (16). Pure.
"""
function _mouse_mods(b::Int)::Modifiers
    r = 0x00
    (b & 0x04) != 0 && (r |= _BIT_SHIFT)
    (b & 0x08) != 0 && (r |= _BIT_ALT)
    (b & 0x10) != 0 && (r |= _BIT_CTRL)
    return Modifiers(r)
end

# -------------------------------------------------------- single bytes

"""
The event for one 7-bit byte seen outside an escape sequence, per the
§2.11 grammar table. Total: every byte below `0x80` maps to an event.
Pure.
"""
function _ascii_event(b::UInt8)::KeyEvent
    b == 0x0d && return KeyEvent(Key.ENTER, '\0', MOD_NONE)
    b == 0x0a && return KeyEvent(Key.ENTER, '\0', MOD_NONE)
    b == 0x09 && return KeyEvent(Key.TAB, '\0', MOD_NONE)
    b == _ESC && return KeyEvent(Key.ESCAPE, '\0', MOD_NONE)
    b == 0x7f && return KeyEvent(Key.BACKSPACE, '\0', MOD_NONE)
    b == 0x20 && return KeyEvent(Key.SPACE, '\0', MOD_NONE)
    b == 0x00 && return KeyEvent(Key.CHAR, ' ', Modifiers(_BIT_CTRL))
    if 0x01 <= b <= 0x1a
        c = Char(UInt32('a') + UInt32(b) - UInt32(1))
        return KeyEvent(Key.CHAR, c, Modifiers(_BIT_CTRL))
    end
    if 0x1c <= b <= 0x1f
        c = Char(UInt32(b) + UInt32(0x40))
        return KeyEvent(Key.CHAR, c, Modifiers(_BIT_CTRL))
    end
    b < 0x20 && return KeyEvent(Key.UNKNOWN, '\0', MOD_NONE)
    return KeyEvent(Key.CHAR, Char(b), MOD_NONE)
end

# ---------------------------------------------------------- key tables

"""
The key named by a CSI or SS3 final byte, or `nothing` when the final
byte is not a key. Pure.
"""
function _final_key(fb::UInt8)::Union{Key.T,Nothing}
    fb == UInt8('A') && return Key.UP
    fb == UInt8('B') && return Key.DOWN
    fb == UInt8('C') && return Key.RIGHT
    fb == UInt8('D') && return Key.LEFT
    fb == UInt8('F') && return Key.END
    fb == UInt8('H') && return Key.HOME
    fb == UInt8('P') && return Key.F1
    fb == UInt8('Q') && return Key.F2
    fb == UInt8('R') && return Key.F3
    fb == UInt8('S') && return Key.F4
    fb == UInt8('Z') && return Key.BACK_TAB
    return nothing
end

"""
The key named by `n` in a `CSI n ~` sequence, or `nothing` when `n` is
not a known code. Pure.
"""
function _tilde_key(n::Int)::Union{Key.T,Nothing}
    n == 1 && return Key.HOME
    n == 2 && return Key.INSERT
    n == 3 && return Key.DELETE
    n == 4 && return Key.END
    n == 5 && return Key.PAGE_UP
    n == 6 && return Key.PAGE_DOWN
    n == 7 && return Key.HOME
    n == 8 && return Key.END
    n == 11 && return Key.F1
    n == 12 && return Key.F2
    n == 13 && return Key.F3
    n == 14 && return Key.F4
    n == 15 && return Key.F5
    n == 17 && return Key.F6
    n == 18 && return Key.F7
    n == 19 && return Key.F8
    n == 20 && return Key.F9
    n == 21 && return Key.F10
    n == 23 && return Key.F11
    n == 24 && return Key.F12
    return nothing
end

# ----------------------------------------------------------------- mouse

"""
Decode an SGR (1006) mouse report. `b` is the encoded button and
modifier value, `x` and `y` are 1-based absolute cells, and `press`
distinguishes final `M` from final `m`. Pure.
"""
function _sgr_mouse(b::Int, x::Int, y::Int, press::Bool)::MouseEvent
    mods = _mouse_mods(b)
    low = b & 0x03
    if (b & 0x40) != 0
        btn = low == 0 ? MouseButton.WHEEL_UP :
              low == 1 ? MouseButton.WHEEL_DOWN :
              low == 2 ? MouseButton.WHEEL_LEFT :
              MouseButton.WHEEL_RIGHT
        return MouseEvent(MouseAction.PRESS, btn, x, y, mods)
    end
    btn = low == 0 ? MouseButton.LEFT :
          low == 1 ? MouseButton.MIDDLE :
          low == 2 ? MouseButton.RIGHT : MouseButton.NONE
    act = !press ? MouseAction.RELEASE :
          (b & 0x20) == 0 ? MouseAction.PRESS :
          btn === MouseButton.NONE ? MouseAction.MOVE : MouseAction.DRAG
    return MouseEvent(act, btn, x, y, mods)
end

"""
Decode a legacy X10 mouse report: the button value and the column and
row are each offset by 32. Low button bits `0b11` mean a release whose
button is not reported. Pure.
"""
function _x10_mouse(cb::UInt8, cx::UInt8, cy::UInt8)::MouseEvent
    b = max(Int(cb) - 32, 0)
    x = max(Int(cx) - 32, 1)
    y = max(Int(cy) - 32, 1)
    if (b & 0x40) == 0 && (b & 0x03) == 0x03
        return MouseEvent(MouseAction.RELEASE, MouseButton.NONE, x, y,
                          _mouse_mods(b))
    end
    return _sgr_mouse(b, x, y, true)
end

# ------------------------------------------------------------ sequences

"""
Parse the numeric parameters of a CSI or SS3 sequence from
`bytes[a:b]`.

Returns up to six values plus the parameter count. An omitted parameter
is `-1`; only the first element of a `:` sub-parameter list is kept; a
leading private-marker byte is ignored. Pure, allocation-free.
"""
function _parse_params(bytes::AbstractVector{UInt8}, a::Int,
                       b::Int)::Tuple{NTuple{6,Int},Int}
    ps = (-1, -1, -1, -1, -1, -1)
    a > b && return (ps, 0)
    n = 1
    cur = -1
    sub = false
    for i in a:b
        c = bytes[i]
        if 0x30 <= c <= 0x39
            if !sub
                cur = (cur < 0 ? 0 : cur) * 10 + Int(c - 0x30)
                cur > 65535 && (cur = 65535)
            end
        elseif c == UInt8(';')
            n <= 6 && (ps = Base.setindex(ps, cur, n))
            n += 1
            cur = -1
            sub = false
        elseif c == UInt8(':')
            sub = true
        end
    end
    n <= 6 && (ps = Base.setindex(ps, cur, n))
    return (ps, n)
end

"""
Index of the `CSI 201~` bracketed-paste terminator within `bytes[a:b]`,
or `0` when it is not there yet. Pure.
"""
function _find_paste_end(bytes::AbstractVector{UInt8}, a::Int,
                         b::Int)::Int
    for t in a:(b - 5)
        bytes[t] == _ESC || continue
        bytes[t + 1] == UInt8('[') || continue
        bytes[t + 2] == UInt8('2') || continue
        bytes[t + 3] == UInt8('0') || continue
        bytes[t + 4] == UInt8('1') || continue
        bytes[t + 5] == UInt8('~') || continue
        return t
    end
    return 0
end

"""
Copy `bytes[a:b]` into a fresh `String`; empty when `a > b`. Pure.
"""
function _slice_string(bytes::AbstractVector{UInt8}, a::Int,
                       b::Int)::String
    a > b && return ""
    buf = Vector{UInt8}(undef, b - a + 1)
    for t in 0:(b - a)
        buf[t + 1] = bytes[a + t]
    end
    return String(buf)
end

"""
Complete a bracketed paste whose `CSI 200~` introducer ends at index
`j`.

Returns `(0, nothing)` while the closing `CSI 201~` has not arrived, so
the whole paste stays unconsumed until it is complete -- exactly the
rule that lets a paste straddle any number of chunk boundaries. Pure.
"""
function _parse_paste(bytes::AbstractVector{UInt8}, i::Int, j::Int,
                      last::Int)::Tuple{Int,Union{Event,Nothing}}
    k = _find_paste_end(bytes, j + 1, last)
    k == 0 && return (0, nothing)
    return (k + 6 - i, PasteEvent(_slice_string(bytes, j + 1, k - 1)))
end

"""
Parse the CSI sequence starting at `i`, where `bytes[i]` is `ESC` and
`bytes[i + 1]` is `[`.

Returns the number of bytes consumed plus the event produced, `nothing`
for a complete but unrecognised sequence, and `(0, nothing)` when the
sequence is still incomplete. Never throws. Pure.
"""
function _parse_csi(bytes::AbstractVector{UInt8}, i::Int,
                    last::Int)::Tuple{Int,Union{Event,Nothing}}
    pa = i + 2
    j = pa
    while j <= last && 0x30 <= bytes[j] <= 0x3f
        j += 1
    end
    pb = j - 1
    while j <= last && 0x20 <= bytes[j] <= 0x2f
        j += 1
    end
    j > last && return (0, nothing)
    fb = bytes[j]
    # Not a final byte: abandon the sequence and resynchronise ON the
    # offending byte rather than swallowing it.
    (0x40 <= fb <= 0x7e) || return (j - i, nothing)
    n = j - i + 1
    priv = (pb >= pa && 0x3c <= bytes[pa] <= 0x3f) ? bytes[pa] : 0x00
    (ps, np) = _parse_params(bytes, pa, pb)
    if priv == UInt8('<')
        (fb == UInt8('M') || fb == UInt8('m')) || return (n, nothing)
        np >= 3 || return (n, nothing)
        return (n, _sgr_mouse(max(ps[1], 0), max(ps[2], 1),
                              max(ps[3], 1), fb == UInt8('M')))
    end
    priv == 0x00 || return (n, nothing)
    if fb == UInt8('M') && pb < pa
        j + 3 <= last || return (0, nothing)
        return (j - i + 4,
                _x10_mouse(bytes[j + 1], bytes[j + 2], bytes[j + 3]))
    end
    mods = _xterm_mods(ps[2])
    if fb == UInt8('~')
        ps[1] == 200 && return _parse_paste(bytes, i, j, last)
        kt = _tilde_key(ps[1])
        kt === nothing && return (n, nothing)
        return (n, KeyEvent(kt, '\0', mods))
    end
    fb == UInt8('I') && return (n, FocusEvent(true))
    fb == UInt8('O') && return (n, FocusEvent(false))
    k = _final_key(fb)
    k === nothing && return (n, nothing)
    # A bare CSI P/Q/R/S is a terminal report, not a function key; only
    # the parameterised form (`CSI 1;5P`) is F1..F4.
    if UInt8('P') <= fb <= UInt8('S') && ps[1] < 0
        return (n, nothing)
    end
    return (n, KeyEvent(k, '\0', mods))
end

"""
Parse the SS3 sequence starting at `i`, where `bytes[i]` is `ESC` and
`bytes[i + 1]` is `O`. Never throws. Pure.
"""
function _parse_ss3(bytes::AbstractVector{UInt8}, i::Int,
                    last::Int)::Tuple{Int,Union{Event,Nothing}}
    pa = i + 2
    j = pa
    while j <= last && 0x30 <= bytes[j] <= 0x3f
        j += 1
    end
    pb = j - 1
    j > last && return (0, nothing)
    fb = bytes[j]
    (0x40 <= fb <= 0x7e) || return (j - i, nothing)
    n = j - i + 1
    fb == UInt8('M') && return (n, KeyEvent(Key.ENTER, '\0', MOD_NONE))
    k = _final_key(fb)
    k === nothing && return (n, nothing)
    (ps, _) = _parse_params(bytes, pa, pb)
    return (n, KeyEvent(k, '\0', _xterm_mods(ps[2])))
end

"""
Parse the sequence introduced by `bytes[i] == 0x1b`.

A trailing lone `ESC` yields `(0, nothing)`: it is ambiguous until
either more bytes arrive or `flush_escape!` times it out. Never throws.
Pure.
"""
function _parse_escape(bytes::AbstractVector{UInt8}, i::Int,
                       last::Int)::Tuple{Int,Union{Event,Nothing}}
    i == last && return (0, nothing)
    b2 = bytes[i + 1]
    b2 == UInt8('[') && return _parse_csi(bytes, i, last)
    b2 == UInt8('O') && return _parse_ss3(bytes, i, last)
    # ESC ESC: the first is the Escape key; the second re-enters this
    # parser on the next turn of the loop.
    b2 == _ESC && return (1, KeyEvent(Key.ESCAPE, '\0', MOD_NONE))
    b2 < 0x80 && return (2, _with_alt(_ascii_event(b2)))
    len = _utf8_len(b2)
    len == 0 && return (2, nothing)
    i + len > last && return (0, nothing)
    c = _utf8_decode(bytes, i + 1, len)
    c === nothing && return (2, nothing)
    return (1 + len, KeyEvent(Key.CHAR, c, Modifiers(_BIT_ALT)))
end

# ---------------------------------------------------------- the parser

"""
PURE. Parse as many events as possible from `bytes`; returns the events
and the number of bytes CONSUMED.

A trailing INCOMPLETE sequence -- a partial CSI, a partial UTF-8
codepoint, an open bracketed paste -- is left UNCONSUMED for the caller
to re-present with more data. That property is the entire reason a CSI
split across two web frames parses correctly.

NEVER throws. Unrecognised complete sequences are consumed and dropped.
A lone trailing ESC is left unconsumed; see `flush_escape!`.
"""
function parse_events(
        bytes::AbstractVector{UInt8})::Tuple{Vector{Event},Int}
    evs = Event[]
    lo = firstindex(bytes)
    hi = lastindex(bytes)
    i = lo
    while i <= hi
        b = bytes[i]
        if b == _ESC
            (n, ev) = _parse_escape(bytes, i, hi)
            n == 0 && break
            ev === nothing || push!(evs, ev)
            i += n
        elseif b < 0x80
            push!(evs, _ascii_event(b))
            i += 1
        else
            len = _utf8_len(b)
            if len == 0
                i += 1                     # stray byte: drop, resync
            elseif i + len - 1 > hi
                break                      # partial codepoint: hold it
            else
                c = _utf8_decode(bytes, i, len)
                if c === nothing
                    i += 1                 # malformed: drop, resync
                else
                    push!(evs, KeyEvent(Key.CHAR, c, MOD_NONE))
                    i += len
                end
            end
        end
    end
    return (evs, i - lo)
end

"""
A thin stateful shell over `parse_events`.

Retains the unconsumed tail across `feed!` calls, so events survive
arbitrary chunk boundaries.

There is NO implicit clock read anywhere in this struct: `esc_at` is an
INJECTED stamp. That is what keeps the lone-ESC test from needing to
sleep.
"""
mutable struct InputParser
    "Unconsumed bytes carried to the next `feed!`."
    const tail::Vector{UInt8}
    "Bytes accumulated inside an open bracketed paste."
    const paste::Vector{UInt8}
    "True between the paste start and end markers."
    in_paste::Bool
    "Injected stamp of a pending lone ESC; `NaN` when none."
    esc_at::Float64
    "Seconds a lone ESC waits before resolving to the Escape key."
    esc_timeout::Float64
end

"""
A parser with empty buffers and no pending escape.
"""
InputParser(; esc_timeout::Real = 0.05)::InputParser =
    InputParser(UInt8[], UInt8[], false, NaN, Float64(esc_timeout))

"""
True when `t` begins with an unterminated `CSI 200~` introducer. Pure.
"""
function _is_paste_open(t::Vector{UInt8})::Bool
    length(t) >= 6 || return false
    return t[1] == _ESC && t[2] == UInt8('[') && t[3] == UInt8('2') &&
           t[4] == UInt8('0') && t[5] == UInt8('0') &&
           t[6] == UInt8('~')
end

"""
Refresh the derived state -- the open-paste mirror and the pending
lone-ESC stamp -- from the tail a parse left behind.

`now` is the INJECTED clock and is used only to stamp an ESC that is
newly pending; an already-pending stamp is never refreshed, so the
timeout measures from the first sighting.
"""
function _sync_state!(p::InputParser, now::Float64)::Nothing
    empty!(p.paste)
    if _is_paste_open(p.tail)
        p.in_paste = true
        n = length(p.tail) - 6
        resize!(p.paste, n)
        copyto!(p.paste, 1, p.tail, 7, n)
    else
        p.in_paste = false
    end
    if length(p.tail) == 1 && p.tail[1] == _ESC
        isnan(p.esc_at) && (p.esc_at = now)
    else
        p.esc_at = NaN
    end
    return nothing
end

"""
Append `bytes`, parse greedily, and return the events produced.

`now` is INJECTED and is used only to stamp a pending lone ESC.
"""
function feed!(p::InputParser, bytes::AbstractVector{UInt8},
               now::Float64 = time())::Vector{Event}
    append!(p.tail, bytes)
    (evs, n) = parse_events(p.tail)
    n > 0 && deleteat!(p.tail, 1:n)
    _sync_state!(p, now)
    return evs
end

"""
Append the code units of `s`, parse greedily, and return the events
produced.
"""
feed!(p::InputParser, s::AbstractString,
      now::Float64 = time())::Vector{Event} =
    feed!(p, codeunits(s), now)

"""
Resolve the lone-ESC ambiguity: a bare `0x1b` is either the Escape key
or the prefix of a longer sequence, and only elapsed time distinguishes
them.

Returns `[key(Key.ESCAPE)]` iff an ESC is pending and
`now - p.esc_at >= p.esc_timeout`; otherwise empty.

`now` is INJECTED so tests never sleep.
"""
function flush_escape!(p::InputParser,
                       now::Float64 = time())::Vector{Event}
    evs = Event[]
    isnan(p.esc_at) && return evs
    (now - p.esc_at) >= p.esc_timeout || return evs
    empty!(p.tail)
    p.esc_at = NaN
    push!(evs, KeyEvent(Key.ESCAPE, '\0', MOD_NONE))
    return evs
end

"""
Drop ALL buffered state.

MUST be called on web reattach: a half-parsed CSI from before the drop
would corrupt the first keystroke after reconnect.
"""
function Base.empty!(p::InputParser)::InputParser
    empty!(p.tail)
    empty!(p.paste)
    p.in_paste = false
    p.esc_at = NaN
    return p
end

"""
True when nothing is buffered and no escape is pending. Pure.
"""
Base.isempty(p::InputParser)::Bool =
    isempty(p.tail) && isempty(p.paste) && !p.in_paste &&
    isnan(p.esc_at)

"""
Number of unconsumed bytes held in the tail. Pure.
"""
pending(p::InputParser)::Int = length(p.tail)

"""
THE shared pump. `TerminalDriver._reader_loop!` and
`ManyUIWeb.feed_bytes!` BOTH call this and nothing else -- the loop that
must not drop a CSI split across a chunk boundary is implemented and
tested ONCE, here, in ManyUI.

Returns the number of events put. Never blocks indefinitely: if `ch` is
closed, returns 0 without throwing.
"""
function pump_input!(p::InputParser, ch::Channel{Event},
                     bytes::AbstractVector{UInt8},
                     now::Float64 = time())::Int
    evs = feed!(p, bytes, now)
    isempty(evs) && return 0
    isopen(ch) || return 0
    n = 0
    for e in evs
        try
            put!(ch, e)
        catch err
            err isa InvalidStateException || rethrow()
            return n
        end
        n += 1
    end
    return n
end
