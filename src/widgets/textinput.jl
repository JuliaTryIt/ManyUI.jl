# widgets/textinput.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode.
#
# This file also DEFINES the shared grapheme helpers that `textarea.jl`
# uses. They live here rather than in `widget.jl` because layer 4 may not
# reference `unicode.jl`; the include order guarantees `textarea.jl` sees
# them, and keeps ONE definition of each.
#
# NORMATIVE grapheme discipline for this file and `textarea.jl`:
#
#   1. A cursor steps by GRAPHEME CLUSTER -- never a codepoint, never a
#      byte. One `move_by!(w, 1)` crosses exactly one cluster however
#      many codepoints or cells it is.
#   2. A wide cluster is ONE step and TWO cells. The index counts
#      clusters; the column is DERIVED via `text_width` of the prefix.
#   3. `Base.textwidth` is FORBIDDEN on a string or a char. It sums
#      codepoints and ignores clustering: `textwidth("👨‍👩‍👧") == 6`,
#      `textwidth("❤️") == 1`. Use `grapheme_width` / `text_width`.
#   4. Byte indexing into user text is FORBIDDEN except through the
#      helpers below, which are the one place byte and cluster indices
#      are allowed to meet.
#   5. The cursor is 0-based, `0:n`: a COUNT of clusters before the
#      caret, not a coordinate. The package's 1-based rule governs
#      `Region`, `Buffer` and `MouseEvent`, none of which this is.
#   6. On insert the caret is RECOMPUTED from the new prefix, never
#      advanced by the inserted cluster count -- a combining mark MERGES
#      into the preceding cluster and the count may not increase at all.
#   7. A wide cluster that would straddle an edge is dropped WHOLE, at
#      the LEFT edge as well as the right.

# --- the shared grapheme helpers --------------------------------------

"""
Code units in the first `k` graphemes of `s`; `0` for `k <= 0` and
`ncodeunits(s)` past the end. O(k). Pure.

The sum of whole clusters' `ncodeunits`, so the result is always a whole
number of CLUSTERS and can never split one. This is THE one place byte
and cluster indices meet. Internal.

It is a code-unit COUNT and NOT a character index, so `SubString(s, 1,
b)` is WRONG: that form wants the INDEX of the last character and throws
a `StringIndexError` the moment the prefix ends inside a multi-byte
cluster -- which is every CJK and every emoji. Split with `_ti_head` and
`_ti_tail`, which take the same `thisind` precaution `truncate_width`
already takes.
"""
function _byte_after(s::AbstractString, k::Int)::Int
    k <= 0 && return 0
    n = 0
    i = 0
    for g in Unicode.graphemes(s)
        n += ncodeunits(g)
        i += 1
        i >= k && return n
    end
    return ncodeunits(s)
end

"""
Number of grapheme clusters in `s`. Pure. Internal.
"""
_ngraphemes(s::AbstractString)::Int = length(Unicode.graphemes(s))

"""
Clusters of `s` that END at or before byte `b` -- the caret index for a
caret sitting at byte `b`. Rounds DOWN inside a cluster. Pure. Internal.
"""
function _gindex_at(s::AbstractString, b::Int)::Int
    b <= 0 && return 0
    n = 0
    acc = 0
    for g in Unicode.graphemes(s)
        acc += ncodeunits(g)
        acc > b && break
        n += 1
    end
    return n
end

"""
Cells of the cluster starting just after byte `b`; `1` at the end of
`s`, so the caret always has a cell to sit in. Pure. Internal.
"""
function _cluster_width_at(s::AbstractString, b::Int)::Int
    acc = 0
    for g in Unicode.graphemes(s)
        acc >= b && return grapheme_width(g)
        acc += ncodeunits(g)
    end
    return 1
end

"""
The largest grapheme index of `s` whose clusters END at or before cell
column `cell`. The inverse of "cells before the caret", and the reason
an UP/DOWN move can never land INSIDE a wide cluster. Pure. Internal.
"""
function _col_at_cell(s::AbstractString, cell::Int)::Int
    cell <= 0 && return 0
    n = 0
    acc = 0
    for g in Unicode.graphemes(s)
        acc += grapheme_width(g)
        acc > cell && break
        n += 1
    end
    return n
end

"""
`s`'s first `b` CODE UNITS, where `b` came from `_byte_after`. Pure.
Internal.

`thisind` is the whole point and is not defensive programming:
`SubString(s, 1, b)` reads `b` as the INDEX of the last CHARACTER, so it
throws a `StringIndexError` for any prefix ending inside a multi-byte
cluster -- `SubString("a世", 1, 4)` throws, verified. `thisind` maps the
count onto the index of the character it lands on, which for a cluster
boundary is that character's start, so the split is exact and never
loses a byte. `truncate_width` takes the same precaution.
"""
_ti_head(s::String, b::Int)::SubString{String} =
    SubString(s, 1, thisind(s, b))

"""
`s` from byte `b + 1` on, where `b` came from `_byte_after`. Pure.
Internal.

Legal at BOTH ends without a special case: `b` is a cluster boundary, so
`b + 1` starts a character, and one past the last byte yields the empty
string rather than a `BoundsError`.
"""
_ti_tail(s::String, b::Int)::SubString{String} = SubString(s, b + 1)

# --- TextInput --------------------------------------------------------

"""
The default `on_submit`: do nothing. Internal.
"""
_ti_noop(::Widget)::Nothing = nothing

"""
The caret's own style: REVERSE video, MERGED onto whatever cell the
caret rests on so the glyph under it survives. Internal.
"""
const _TI_CARET = Style(; reverse = true)

"""
Single-line text entry.

`text` and `cursor` are `Dirty.PAINT`-reactive, and that is a design
commitment rather than an optimisation: `measure` returns
`Size(avail.width, 1)`, so a `TextInput` NEVER resizes to its content --
that is what the horizontal scroll is for. A keystroke provably cannot
move a single box, so a keystroke costs ZERO layout.

`Reactive`'s default is the conservative `Dirty.LAYOUT` precisely
because choosing PAINT for state that can change size is a correctness
bug. The text-independent `measure` above is what licenses PAINT here;
do not copy the choice to a widget without that property.

The horizontal scroll lives in `node(w).scroll.x`. The core never
applies it (a `TextInput` has no children) -- `render!` reads it and
slices. Storing it there anyway is what lets a `Scrollbar` observe a
`TextInput` with no new code.

Parametric on the submit handler, the `Button{F}` pattern.
"""
mutable struct TextInput{F} <: Widget
    "Per-widget state."
    node::WidgetNode
    "The content. PAINT-reactive: the box cannot move."
    text::Reactive{String}
    "Caret, a 0-based GRAPHEME index in `0:n`. PAINT-reactive."
    cursor::Reactive{Int}
    "True while focused; drives the caret cell. PAINT-reactive."
    focused::Reactive{Bool}
    "Shown dimmed while `text` is empty."
    const placeholder::String
    "Called as `on_submit(input)` on ENTER."
    on_submit::F
end

"""
An input holding `text`, calling `on_submit(input)` on ENTER.

Focusable by construction, so it appears in `focusable_widgets` and is
reachable by TAB with no further wiring.

The caret starts at the END of `text`, where a user who is handed a
pre-filled field expects to carry on typing.
"""
function TextInput(text::AbstractString = "",
                   on_submit::F = _ti_noop;
                   placeholder::AbstractString = "",
                   id::Symbol = gensym(:textinput),
                   classes = Symbol[])::TextInput{F} where {F}
    s = String(text)
    w = TextInput{F}(WidgetNode(; id = id, classes = classes,
                                type_name = :TextInput,
                                focusable = true),
                     Reactive(s; kind = Dirty.PAINT),
                     Reactive(_ngraphemes(s); kind = Dirty.PAINT),
                     Reactive(false; kind = Dirty.PAINT),
                     String(placeholder),
                     on_submit)
    attach_reactives!(w)
    return w
end

"""
`Size(avail.width, 1)`. A `TextInput` takes the width it is offered and
scrolls the rest; it never sizes to its content. Give it `width: 20` for
a narrow box. Pure with respect to the tree.
"""
measure(w::TextInput, avail::Size)::Size = Size(avail.width, 1)

"""
The content extent for the scrollable seam: `Size(text_width(text) + 1,
1)`.

The `+ 1` is load-bearing: the caret must be able to rest ONE cell past
the last glyph, and without it End scrolls one cell short.
"""
content_extent(w::TextInput)::Size = Size(text_width(w.text[]) + 1, 1)

"""
The caret, clamped into `0:n`. Internal.

`text` and `cursor` are two independent `Reactive`s, so an application
that assigns `w.text[]` behind the editing ops' back can leave the caret
past the end. Clamping on every READ makes every op below total, instead
of scattering the same guard through each of them.
"""
_ti_caret(w::TextInput)::Int =
    clamp(w.cursor[], 0, _ngraphemes(w.text[]))

"""
`(cells before the caret, cells of the cluster AT the caret)`. Pure with
respect to the tree. Internal.

The second element is at least `1` even over a zero-width cluster, so
the caret always has a cell of its own to reverse.

ONE pass over the graphemes, and this is the frame path: the obvious
spelling -- `_byte_after`, then `text_width` of the head, then
`_cluster_width_at` -- walks the clusters THREE times and each
`Unicode.graphemes` costs an iterator per call. Walking once and
stopping AT the caret subsumes all three, and it clamps `cursor` into
`0:n` on the way for free: a `want` below the range returns on the first
cluster and one past it falls out of the loop.
"""
function _ti_caret_cells(w::TextInput)::Tuple{Int,Int}
    want = w.cursor[]
    cells = 0
    i = 0
    for g in Unicode.graphemes(w.text[])
        i >= want && return (cells, max(1, grapheme_width(g)))
        cells += grapheme_width(g)
        i += 1
    end
    return (cells, 1)       # at the end: the caret still gets a cell
end

"""
The window for a caret whose cluster spans cells `lo:(lo + cw - 1)`,
0-based, in a `width`-cell content box. Pure. Internal.

Split out of `visible_scroll` so `render!` can pay for the caret's
column ONCE and reuse it, rather than walking the prefix twice per
frame.
"""
function _ti_window(w::TextInput, width::Int, lo::Int, cw::Int)::Int
    pos = scroll_of(w).x
    width <= 0 && return pos
    pos = scroll_into_view(pos, width, lo, lo + cw - 1)
    return clamp_scroll(pos, width, content_extent(w).width)
end

"""
The first visible CELL column, 0-based, for a `width`-cell content box.

THE single definition of "scrolled so the caret is visible", called by
`render!` (which MUST NOT mutate) AND by every editing op (which stores
the result). One function, so the painted scroll and the stored one
cannot drift. Pure.

MINIMAL MOVEMENT falls out of `scroll_into_view`: content already inside
the window does not move, and the clamp at `content_extent` is what lets
End rest on the caret's own cell instead of one short of it.
"""
function visible_scroll(w::TextInput, width::Int)::Int
    lo, cw = _ti_caret_cells(w)
    return _ti_window(w, width, lo, cw)
end

"""
Store the window `visible_scroll` computes, so the caret is visible on
the next frame. Internal.

A no-op before the first layout: with no content box there is no window
to be inside, and `render!` recomputes the offset from the width it is
actually given in any case.
"""
function _ti_sync_scroll!(w::TextInput)::Nothing
    width = content_region(w).width
    width <= 0 && return nothing
    set_scroll!(w, Offset(visible_scroll(w, width), 0))
    return nothing
end

"""
Paint the visible window of the text, then the caret.

The caret is REVERSE video on the cell under it, not a hardware cursor:
the tree paints into a `Buffer` and the `Driver` seam has no
cursor-placement method. Over a wide cluster the caret reverses the HEAD
cell; its continuation stays a continuation, so the grid never
desynchronises.

ONE pass over the graphemes, no `grapheme_cells`: it allocates a
`Vector` per call and this is the frame path. `write_text!` is handed a
NEGATIVE start column when the text is scrolled -- clusters left of the
window land at `x <= 0` and are skipped, and a wide cluster straddling
either edge is dropped WHOLE, never halved.

Reads the scroll rather than writing it: a paint MUST NOT mutate, and
`visible_scroll` is the same function the editing ops stored, so the two
cannot disagree.
"""
function render!(w::TextInput, buf::AbstractMatrix{Cell})::Nothing
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    st = computed_style(w)
    s = w.text[]
    lo, cw = _ti_caret_cells(w)
    off = _ti_window(w, width, lo, cw)
    if isempty(s)
        isempty(w.placeholder) ||
            write_text!(buf, 1, 1, w.placeholder,
                        with(st, Attr.DIM, true))
    else
        write_text!(buf, 1 - off, 1, s, st)
    end
    w.focused[] || return nothing
    # `style_region!` clips, so a caret column outside the box is a
    # no-op rather than a throw, and it keeps the cell's content and
    # width -- reversing a head must not turn it into a fresh cell.
    style_region!(buf, Region(lo - off + 1, 1, 1, 1), _TI_CARET)
    return nothing
end

"""
Insert `t` at the caret. The caret is RECOMPUTED from the new prefix,
never advanced by the inserted cluster count.

Recomputing is the only rule that is right for every input: a combining
mark MERGES into the preceding cluster, so the cluster count may not
increase at all, and an advance-by-`n` caret would then sit past the end
of a string that never grew.
"""
function insert_text!(w::TextInput, t::AbstractString)::Nothing
    isempty(t) && return nothing
    s = w.text[]
    b = _byte_after(s, _ti_caret(w))
    new = string(_ti_head(s, b), t, _ti_tail(s, b))
    w.text[] = new
    w.cursor[] = _gindex_at(new, b + ncodeunits(t))
    _ti_sync_scroll!(w)
    return nothing
end

"""
Delete the cluster BEFORE the caret. False at the start of the text.

The WHOLE cluster goes: one backspace over a ZWJ family takes all 25 of
its bytes, not the last codepoint of it.
"""
function backspace!(w::TextInput)::Bool
    cur = _ti_caret(w)
    cur <= 0 && return false
    s = w.text[]
    b = _byte_after(s, cur - 1)
    new = string(_ti_head(s, b), _ti_tail(s, _byte_after(s, cur)))
    w.text[] = new
    w.cursor[] = _gindex_at(new, b)
    _ti_sync_scroll!(w)
    return true
end

"""
Delete the cluster AT the caret. False at the end of the text.

The caret does not move: it is the same count of clusters from the start
as it was, which is why it is recomputed from the same byte offset.
"""
function delete_forward!(w::TextInput)::Bool
    cur = _ti_caret(w)
    s = w.text[]
    b = _byte_after(s, cur)
    b >= ncodeunits(s) && return false
    new = string(_ti_head(s, b), _ti_tail(s, _byte_after(s, cur + 1)))
    w.text[] = new
    w.cursor[] = _gindex_at(new, b)
    _ti_sync_scroll!(w)
    return true
end

"""
Move the caret to cluster `i`, clamped to `0:n`: `0` is Home and
`typemax(Int)` is End. Returns the new caret.
"""
function move_to!(w::TextInput, i::Int)::Int
    v = clamp(i, 0, _ngraphemes(w.text[]))
    w.cursor[] = v
    _ti_sync_scroll!(w)
    return v
end

"""
Move the caret by `n` CLUSTERS, clamped to `0:n`. Returns the new caret.

`n` is a count of CLUSTERS and never of codepoints or cells, so LEFT
over a ZWJ family is one call with `n = -1` and lands before all seven
of its codepoints.

Saturates instead of overflowing: the caret is non-negative, so only the
rightward sum can leave `Int`, and a request that far right is an End by
any reading.
"""
function move_by!(w::TextInput, n::Int)::Int
    cur = _ti_caret(w)
    i = (n > 0 && n > typemax(Int) - cur) ? typemax(Int) : cur + n
    return move_to!(w, i)
end

"""
True while `d` is live and at or past its target -- everywhere except
the capture phase.

A `TextInput` edits on the way UP, exactly as a `Button` activates:
capture belongs to ancestors that want to intercept, and an input is
never an interceptor. `AT_TARGET` counts because a childless input IS
the target, and the bubble phase excludes the target, so bubble alone
would never visit it. Internal.
"""
_ti_edits(d::Dispatch)::Bool =
    d.phase !== Phase.CAPTURE && !is_consumed(d)

"""
`t` with every control character removed. Pure. Internal.

Per CODEPOINT rather than per cluster, which is safe precisely because a
control is never part of a printable cluster: ZWJ, the variation
selectors and the skin-tone modifiers are format and symbol codepoints,
not `Cc`, so no cluster this strips through is one it can break. CRLF is
a single cluster of two controls and goes whole.

Returns `t` itself when there is nothing to strip, so the ordinary paste
costs one scan and no copy.
"""
function _ti_strip_controls(t::AbstractString)::String
    any(iscntrl, t) || return String(t)
    io = IOBuffer(; sizehint = ncodeunits(t))
    for c in t
        iscntrl(c) || print(io, c)
    end
    return String(take!(io))
end

"""
CHAR/SPACE insert; BACKSPACE/DELETE/LEFT/RIGHT/HOME/END edit and move;
ENTER calls `on_submit`. Each consumes.

Unmodified keys only. `ctrl+a` and friends belong to an application
binding and consuming them here would silently shadow it. TAB and
ESCAPE FALL THROUGH UNCONSUMED, which is what keeps the tab order alive.

HOME and END are `move_to!` with the extremes of `Int` and let the clamp
decide -- "go as far as you can" IS the implementation.
"""
function on_event!(w::TextInput, d::Dispatch{KeyEvent})::Nothing
    _ti_edits(d) || return nothing
    e = event(d)
    isempty(e.mods) || return nothing
    c = e.code
    if c === Key.CHAR
        insert_text!(w, string(e.char))
    elseif c === Key.SPACE
        insert_text!(w, " ")
    elseif c === Key.BACKSPACE
        backspace!(w)
    elseif c === Key.DELETE
        delete_forward!(w)
    elseif c === Key.LEFT
        move_by!(w, -1)
    elseif c === Key.RIGHT
        move_by!(w, 1)
    elseif c === Key.HOME
        move_to!(w, 0)
    elseif c === Key.END
        move_to!(w, typemax(Int))
    elseif c === Key.ENTER
        w.on_submit(w)
    else
        return nothing          # TAB, ESCAPE, the F-keys: not ours
    end
    consume!(d)
    return nothing
end

"""
Insert a paste at the caret with newlines and other controls stripped: a
single-line input has nowhere to put a line break, and silently
accepting one would make `text` unrenderable.

Consumes either way. A paste that strips to nothing was still a paste
into this input, and letting the husk bubble to an ancestor would be a
second delivery of the same event.
"""
function on_event!(w::TextInput, d::Dispatch{PasteEvent})::Nothing
    _ti_edits(d) || return nothing
    insert_text!(w, _ti_strip_controls(event(d).text))
    consume!(d)
    return nothing
end

"""
Show the caret, and scroll every ancestor pane until this input is
visible. `reveal!` is called EXPLICITLY because overriding `on_focus!`
REPLACES the default that would have called it.
"""
on_focus!(w::TextInput)::Nothing = (w.focused[] = true; reveal!(w))

"""
Hide the caret.
"""
on_blur!(w::TextInput)::Nothing = (w.focused[] = false; nothing)
