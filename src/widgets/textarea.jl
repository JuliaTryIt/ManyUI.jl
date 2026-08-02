# widgets/textarea.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode, and
# the shared grapheme helpers DEFINED in widgets/textinput.jl -- which
# this file USES and MUST NOT redefine.
#
# A TextArea REUSES the scroll core and contains no Scrollpane. The
# argument, in one sentence: `node(w).scroll` shifts a node's CHILDREN,
# and a TextArea's content is a `Vector{String}`, not children -- a
# Scrollpane inside would mean one widget per line, so a 10 000-line
# document becomes 10 000 WidgetNodes, a full layout pass per edit and
# 10 000 `render!` dispatches per frame.
#
# What it reuses, exactly:
#   * the same field: `node(w).scroll`, via `set_scroll!`/`scroll_to!`;
#   * the same clamps: `clamp_scroll`, `scroll_into_view` (widget.jl);
#   * the same seam: it OVERRIDES `content_extent`, so a
#     `Scrollbar{TextArea}` reports on it with no new code. That
#     override is exactly why `Scrollbar` is parametric on its viewport.
#
# `Scrollpane(TextArea(...))` remains legal and scrolls the TextArea's
# whole box -- the two mechanisms compose instead of competing.

"""
The default `on_change`: do nothing. Internal.
"""
_ta_noop(::Widget)::Nothing = nothing

"""
The caret's cell: REVERSE video, merged onto whatever is under it.

A caret is not a hardware cursor -- the tree paints into a `Buffer` and
the `Driver` seam has no cursor-placement method. Internal.
"""
const _TA_CARET = Style(; reverse = true)

"""
Multi-line text entry.

Scrolls by INDEXING `lines`, never by shifting an origin: `render!`
touches `scroll.y + 1 : scroll.y + height` and nothing else, so paint is
O(viewport) and a 100k-line buffer costs the same frame as a 10-line
one.

`lines` is a PLAIN field, deliberately NOT a `Reactive`: `Reactive`'s
`==` guard would be an O(n) elementwise compare of a `Vector{String}` on
every keystroke, AND an in-place edit would never trip it. `version` is
the reactive cell instead -- an `Int` compare is O(1) for the O(1) edit
that actually happened. THE PRICE, stated so nobody discovers it:
`lines` mutated behind `version`'s back will not repaint, so every edit
goes through the ops below.

The cursor is `(line, col)`: `line` 1-based into `lines`, `col` a
0-based GRAPHEME index within `lines[line]`. Same unit discipline as
`TextInput`.
"""
mutable struct TextArea{F} <: Widget
    "Per-widget state."
    node::WidgetNode
    """
    The document, one entry per line, never containing a newline.
    ALWAYS non-empty: an empty document is `[""]`, so `lines[line]` is
    total. Mutated IN PLACE.
    """
    const lines::Vector{String}
    """
    Bumped by every edit. THE reactive cell. LAYOUT-reactive: a new line
    genuinely changes the extent.
    """
    version::Reactive{Int}
    "Cursor line, 1-based."
    line::Int
    "Cursor column, a 0-based GRAPHEME index within `lines[line]`."
    col::Int
    "The CELL column UP/DOWN aim for. See `_ta_set_goal!`."
    goal::Int
    "Monotone high-water mark of the widest line, in cells."
    widest::Int
    "True while focused."
    focused::Reactive{Bool}
    "True if the text area is disabled."
    disabled::Reactive{Bool}
    "Called as `on_change(area)` after every edit."
    on_change::F
end

"""
`s` split on newlines into a document. NEVER empty: an empty string is
`[""]`, which is exactly what makes `lines[line]` total. Pure. Internal.
"""
function _ta_split(s::AbstractString)::Vector{String}
    out = String[]
    for part in split(s, '\n')
        push!(out, String(part))
    end
    isempty(out) && push!(out, "")
    return out
end

"""
An area holding `text`, calling `on_change(area)` after every edit.

Focusable by construction, so it appears in `focusable_widgets` and is
reachable by TAB with no further wiring.
"""
function TextArea(text::AbstractString = "", on_change::F = _ta_noop;
                  disabled::Bool = false,
                  id::Symbol = gensym(:textarea),
                  classes = Symbol[])::TextArea{F} where {F}
    w = TextArea{F}(WidgetNode(; id = id, classes = classes,
                               type_name = :TextArea, focusable = true),
                    _ta_split(text),
                    Reactive(0; kind = Dirty.LAYOUT),
                    1, 0, 0, 0,
                    Reactive(false; kind = Dirty.PAINT),
                    Reactive(disabled; kind = Dirty.PAINT),
                    on_change)
    refresh_extent!(w)
    attach_reactives!(w)
    return w
end

"""
`s` cut at grapheme `k`: the prefix of the first `k` clusters, and the
rest. Neither half can split a codepoint, let alone a cluster. Pure.
Internal.

`_byte_after` returns a COUNT of code units, and a code-unit count is
NOT a Julia string index: `SubString("世界", 1, 3)` THROWS, because 3 is
a continuation byte, while `SubString("世界", 1, 1)` is the whole first
cluster. `thisind` maps the count back onto the character it lands in,
which is what makes the prefix legal; the SUFFIX takes the count `+ 1`
directly, because that always IS a character start. This is the one
place in the file where a byte and a cluster index meet, and it meets
them through the shared helpers alone.
"""
function _ta_split_at(s::String,
                      k::Int)::Tuple{SubString{String},
                                     SubString{String}}
    b = _byte_after(s, k)
    return (SubString(s, 1, thisind(s, b)), SubString(s, b + 1))
end

"""
Cells of the first `k` clusters of `s` -- the CELL column of a caret at
grapheme `k`, 0-based. Pure. Internal.
"""
_ta_cells_before(s::String, k::Int)::Int =
    text_width(first(_ta_split_at(s, k)))

"""
Raise the high-water mark to fit `s`. O(text_width(s)), never O(lines).
Internal.
"""
function _ta_widen!(w::TextArea, s::AbstractString)::Nothing
    w.widest = max(w.widest, text_width(s))
    return nothing
end

"""
`Size(widest, length(lines))`. OVERRIDES the container default: a
`TextArea`'s content is data, not children, so the bounding box of its
(nonexistent) children is not its extent. This override IS the whole
integration with `Scrollbar`.
"""
content_extent(w::TextArea)::Size = Size(w.widest, length(w.lines))

"""
`avail`. A `TextArea` takes the space it is offered and scrolls its
content: an auto-HEIGHT `TextArea` would be as tall as its text and
would never scroll at all. Give it `height: 10` or a `grow: 1` parent.
Pure with respect to the tree.
"""
measure(w::TextArea, avail::Size)::Size = avail

"""
Recompute `widest` from scratch. O(lines).

`widest` is a MONOTONE HIGH-WATER MARK: every edit raises it to
`max(widest, text_width(changed_line))` in O(1) and nothing lowers it.
THE TRADEOFF, stated so nobody discovers it: after the longest line is
deleted the horizontal range stays too wide -- the thumb is slightly too
small and there is slack to the right -- until this is called.
`set_text!` calls it. The alternative, an O(lines) rescan per keystroke,
costs the editor to save a scrollbar thumb one cell.
"""
function refresh_extent!(w::TextArea)::Size
    m = 0
    for line in w.lines
        m = max(m, text_width(line))
    end
    w.widest = m
    return content_extent(w)
end

"""
Replace the document with `s`, split on newlines. Resets the caret, the
scroll and the extent.
"""
function set_text!(w::TextArea, s::AbstractString)::Nothing
    empty!(w.lines)
    append!(w.lines, _ta_split(s))
    w.line = 1
    w.col = 0
    set_scroll!(w, ORIGIN)
    refresh_extent!(w)
    _ta_edited!(w)
    return nothing
end

"""
The document as one string, lines joined by `\\n`.
"""
text(w::TextArea)::String = join(w.lines, "\n")

"""
Paint `lines[scroll.y+1 : scroll.y+height]`, each sliced at `scroll.x`,
then the caret. O(viewport), NEVER O(lines).

A wide cluster STRADDLING the left edge is DROPPED, never halved -- the
same rule `truncate_width` applies at the right edge. A cluster left of
the window lands on `cx <= 0` and is skipped; one straddling the left
edge lands there too, so `set_cell!` never sees the half of it that
would have orphaned a continuation into column 1.

ONE pass over the graphemes, no `grapheme_cells`: it allocates a
`Vector` per call and this is the frame path.
"""

"""
Insert `t` at the caret; a `'\\n'` splits the line.

The caret is RECOMPUTED from the new prefix, never advanced by the
inserted cluster count: a combining mark MERGES into the preceding
cluster and the count may not increase at all.
"""
function insert_text!(w::TextArea, t::AbstractString)::Nothing
    isempty(t) && return nothing
    head, tail = _ta_split_at(w.lines[w.line], w.col)
    parts = split(t, '\n')
    if length(parts) == 1
        pre = string(head, parts[1])
        s = string(pre, tail)
        w.lines[w.line] = s
        w.col = _gindex_at(s, ncodeunits(pre))
        _ta_widen!(w, s)
    else
        first_line = string(head, parts[1])
        w.lines[w.line] = first_line
        _ta_widen!(w, first_line)
        for k in 2:(length(parts) - 1)
            mid = String(parts[k])
            insert!(w.lines, w.line + k - 1, mid)
            _ta_widen!(w, mid)
        end
        pre = String(parts[end])
        last_line = string(pre, tail)
        insert!(w.lines, w.line + length(parts) - 1, last_line)
        _ta_widen!(w, last_line)
        w.line += length(parts) - 1
        w.col = _gindex_at(last_line, ncodeunits(pre))
    end
    _ta_edited!(w)
    return nothing
end

"""
Split the current line at the caret.
"""
insert_newline!(w::TextArea)::Nothing = insert_text!(w, "\n")

"""
Delete the cluster BEFORE the caret; at column 0 of line `n > 1` this
JOINS with the previous line. False at `(1, 0)`.
"""
function backspace!(w::TextArea)::Bool
    if w.col > 0
        cur = w.lines[w.line]
        head, _ = _ta_split_at(cur, w.col - 1)
        _, tail = _ta_split_at(cur, w.col)
        s = string(head, tail)
        w.lines[w.line] = s
        w.col = _gindex_at(s, ncodeunits(head))
        _ta_widen!(w, s)
        _ta_edited!(w)
        return true
    end
    w.line == 1 && return false
    prev = w.lines[w.line - 1]
    s = string(prev, w.lines[w.line])
    w.lines[w.line - 1] = s
    deleteat!(w.lines, w.line)
    w.line -= 1
    w.col = _gindex_at(s, ncodeunits(prev))
    _ta_widen!(w, s)
    _ta_edited!(w)
    return true
end

"""
Delete the cluster AT the caret; at the end of line `n < end` this JOINS
the next line. False at the end of the document.
"""
function delete_forward!(w::TextArea)::Bool
    cur = w.lines[w.line]
    if w.col < _ngraphemes(cur)
        head, _ = _ta_split_at(cur, w.col)
        _, tail = _ta_split_at(cur, w.col + 1)
        s = string(head, tail)
        w.lines[w.line] = s
        w.col = _gindex_at(s, ncodeunits(head))
        _ta_widen!(w, s)
        _ta_edited!(w)
        return true
    end
    w.line == length(w.lines) && return false
    s = string(cur, w.lines[w.line + 1])
    w.lines[w.line] = s
    deleteat!(w.lines, w.line + 1)
    w.col = _gindex_at(s, ncodeunits(cur))
    _ta_widen!(w, s)
    _ta_edited!(w)
    return true
end

"""
One cluster right, crossing into the next line at the end of this one.
False at the end of the DOCUMENT. Internal.
"""
function _ta_step_right!(w::TextArea)::Bool
    if w.col < _ngraphemes(w.lines[w.line])
        w.col += 1
        return true
    end
    w.line >= length(w.lines) && return false
    w.line += 1
    w.col = 0
    return true
end

"""
One cluster left, crossing into the previous line at column 0. False at
the start of the DOCUMENT. Internal.
"""
function _ta_step_left!(w::TextArea)::Bool
    if w.col > 0
        w.col -= 1
        return true
    end
    w.line <= 1 && return false
    w.line -= 1
    w.col = _ngraphemes(w.lines[w.line])
    return true
end

"""
Move the caret by `n` CLUSTERS, wrapping across lines. Resets `goal`.

Clamped at both ends of the document: `move_by!(w, typemax(Int) ÷ 2)` is
End-of-document and cannot run off it.
"""
function move_by!(w::TextArea, n::Int)::Nothing
    if n > 0
        for _ in 1:n
            _ta_step_right!(w) || break
        end
    elseif n < 0
        for _ in 1:(-n)
            _ta_step_left!(w) || break
        end
    end
    _ta_moved!(w)
    return nothing
end

"""
Move the caret by `n` LINES, landing on the cluster whose prefix width
is the largest NOT EXCEEDING `goal`. Does NOT reset `goal`. Returns the
new line.

`_col_at_cell` is what makes the landing safe: an UP/DOWN move can never
come to rest INSIDE a wide cluster, and a run down through a SHORT line
and back up returns to the column the user started in.
"""
function move_line!(w::TextArea, n::Int)::Int
    w.line = clamp(w.line + n, 1, length(w.lines))
    w.col = _col_at_cell(w.lines[w.line], w.goal)
    mark!(w, Dirty.PAINT)
    _ta_follow_caret!(w)
    return w.line
end

"""
Move the caret to cluster `col` of the CURRENT line, clamped: `0` is
Home and `typemax(Int)` is End. A horizontal move, so it re-pins `goal`.
Internal.
"""
function _ta_move_col!(w::TextArea, col::Int)::Nothing
    w.col = clamp(col, 0, _ngraphemes(w.lines[w.line]))
    _ta_moved!(w)
    return nothing
end

"""
Pin `goal` to the caret's current CELL column. Called by every
HORIZONTAL move and every edit -- and by nothing else.

`goal` is in CELLS, not graphemes: cells are the unit the user can see,
and a grapheme goal lands UP/DOWN in a visually different column across
wide clusters. Internal.
"""
function _ta_set_goal!(w::TextArea)::Nothing
    w.goal = _ta_cells_before(w.lines[w.line], w.col)
    return nothing
end

"""
Re-pin `goal`, mark PAINT and follow the caret. THE single exit of every
HORIZONTAL move, so none of the three can be forgotten. Internal.
"""
function _ta_moved!(w::TextArea)::Nothing
    _ta_set_goal!(w)
    mark!(w, Dirty.PAINT)
    _ta_follow_caret!(w)
    return nothing
end

"""
Bump `version`, re-pin `goal`, fire `on_change`. THE single exit of
every edit, so none of the three can be forgotten at a call site.
Internal.
"""
function _ta_edited!(w::TextArea)::Nothing
    w.version[] = w.version[] + 1
    _ta_set_goal!(w)
    _ta_follow_caret!(w)
    w.on_change(w)
    return nothing
end

"""
Scroll the MINIMUM needed to bring the caret inside the content box, on
both axes, via `scroll_into_view`. Internal.

`set_scroll!` and NOT `scroll_to!`: `content_extent` is `widest` cells
wide, and the caret must be able to rest ONE cell PAST the last glyph of
the widest line. `scroll_to!` would clamp that last cell away and hide
the caret at the right edge -- the over-scroll is one blank column, and
the contract licenses it explicitly ("a UX bug, never corruption").

A no-op before the first layout, when the content box is still empty:
there is no window to move yet, and `set_text!`/`render!` are correct at
offset zero regardless.
"""
function _ta_follow_caret!(w::TextArea)::Nothing
    c = layout_of(w).content
    (c.width <= 0 || c.height <= 0) && return nothing
    off = scroll_of(w)
    y = scroll_into_view(off.y, c.height, w.line - 1, w.line - 1)
    s = w.lines[w.line]
    lo = _ta_cells_before(s, w.col)
    cw = max(1, _cluster_width_at(s, _byte_after(s, w.col)))
    x = scroll_into_view(off.x, c.width, lo, lo + cw - 1)
    set_scroll!(w, Offset(x, y))
    return nothing
end

"""
Lines one PAGE_UP/PAGE_DOWN travels: one viewport LESS ONE ROW of
overlap, so the reader keeps a landmark. At least one, so an unlaid-out
area still moves. Internal.
"""
_ta_page(w::TextArea)::Int = max(1, layout_of(w).content.height - 1)

"""
True while `d` is live and at or past its target -- everywhere except
the capture phase, which belongs to ancestors that want to intercept.
Internal.
"""
_ta_acts(d::Dispatch)::Bool =
    d.phase !== Phase.CAPTURE && !is_consumed(d)

"""
CHAR/SPACE insert; ENTER splits; BACKSPACE/DELETE edit; arrows,
PAGE_UP/PAGE_DOWN and HOME/END move. Each consumes.

Unmodified keys only: `ctrl+a` and friends belong to an application
binding and consuming them here would silently shadow it. TAB and ESCAPE
FALL THROUGH UNCONSUMED, which is what keeps the tab order alive.

HOME and END are per LINE, not per document -- that is what a caret in a
text editor means, and `Scrollpane`'s document-wide HOME/END still reach
an ancestor pane whenever this area is not focused.
"""
function on_event!(w::TextArea, d::Dispatch{KeyEvent})::Nothing
    _ta_acts(d) || return nothing
    w.disabled[] && return nothing
    e = event(d)
    isempty(e.mods) || return nothing
    c = e.code
    if c === Key.CHAR
        insert_text!(w, string(e.char))
    elseif c === Key.SPACE
        insert_text!(w, " ")
    elseif c === Key.ENTER
        insert_newline!(w)
    elseif c === Key.BACKSPACE
        backspace!(w)
    elseif c === Key.DELETE
        delete_forward!(w)
    elseif c === Key.LEFT
        move_by!(w, -1)
    elseif c === Key.RIGHT
        move_by!(w, 1)
    elseif c === Key.UP
        move_line!(w, -1)
    elseif c === Key.DOWN
        move_line!(w, 1)
    elseif c === Key.PAGE_UP
        move_line!(w, -_ta_page(w))
    elseif c === Key.PAGE_DOWN
        move_line!(w, _ta_page(w))
    elseif c === Key.HOME
        _ta_move_col!(w, 0)
    elseif c === Key.END
        _ta_move_col!(w, typemax(Int))
    else
        return nothing
    end
    consume!(d)
    return nothing
end

"""
Insert a paste at the caret, splitting it on newlines into real lines.

Unlike `TextInput`, which has nowhere to put a line break and strips
them, a `TextArea` is exactly the widget a multi-line paste belongs in.
"""
function on_event!(w::TextArea, d::Dispatch{PasteEvent})::Nothing
    _ta_acts(d) || return nothing
    w.disabled[] && return nothing
    insert_text!(w, event(d).text)
    consume!(d)
    return nothing
end

"""
Show the caret, and scroll every ancestor pane until this area is
visible. `reveal!` is called EXPLICITLY because overriding `on_focus!`
REPLACES the default that would have called it.
"""
on_focus!(w::TextArea)::Nothing =
    (w.focused[] = true; reveal!(w); _focus_callback!(w))

"""
Hide the caret.
"""
on_blur!(w::TextArea)::Nothing =
    (w.focused[] = false; _blur_callback!(w))
