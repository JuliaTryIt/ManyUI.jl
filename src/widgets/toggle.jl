# widgets/toggle.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode, and
# `_tc_local`/`_tc_slice!`/`_tc_noop`, which widgets/tablecore.jl DEFINES
# and this file USES and MUST NOT redefine.
#
# THE SPACE BAR IS `Key.SPACE`, NOT `Key.CHAR(' ')`. The input parser
# emits `Key.SPACE` for byte 0x20 and NEVER `Key.CHAR(' ')`; `Button`
# gets this right and the two `on_event!(::Any)` methods below check
# BOTH forms exactly as it does (button.jl:105). A checkbox is the widget
# most likely in this project to ship with a dead space bar; it does not.

"""
A `Checkbox`'s state.

AN ENUM AND NOT A `Bool` BECAUSE OF `MIXED`, and that value is not
decoration: it is the "select all" box over a partially-selected set,
which is exactly what a `TreeView` with checkable nodes needs. Two values
would be a `Bool` and this module would be a lie.

NORMATIVE: `toggle!` NEVER PRODUCES `MIXED`. The user has two reachable
states; the third is set BY CODE, from a fact the user cannot express
with one keystroke. `MIXED` toggles to `CHECKED`, because "some are on"
answered by a human means "now all of them". A box a PROGRAM set to
`MIXED` must be clickable OUT of it, or "select all" over a partial
selection is a dead control.
"""
module CheckState
@enum T::UInt8 begin
    UNCHECKED = 0
    CHECKED = 1
    MIXED = 2
end
end

"Unchecked glyph. Width `CB_WIDTH` BY CONSTRUCTION, asserted."
const CB_UNCHECKED = "[ ]"
"Checked glyph. Width `CB_WIDTH` BY CONSTRUCTION, asserted."
const CB_CHECKED = "[x]"
"Mixed glyph. Width `CB_WIDTH` BY CONSTRUCTION, asserted."
const CB_MIXED = "[-]"
"Selected radio. Width `CB_WIDTH` BY CONSTRUCTION, asserted."
const RB_ON = "(o)"
"Unselected radio. Width `CB_WIDTH` BY CONSTRUCTION, asserted."
const RB_OFF = "( )"

"""
Cells every glyph in this file occupies.

ALL FIVE GLYPHS ARE THE SAME WIDTH AND THAT IS LOAD-BEARING, not
tidiness: it is what makes `measure` independent of `state`, which is
what LICENSES `state`'s `Dirty.PAINT` reactivity -- the exact criterion
textinput.jl:158 states and list.jl:43 cites. A width-1 check against a
width-3 `[ ]` would make a click on a checkbox a LAYOUT pass, and the
suite asserts the widths so nobody discovers that by measuring frames.
ASCII, not `[check]`/`(dot)`: a checkbox that renders as a tofu box is
worse than one that renders as an `x`.
"""
const CB_WIDTH = 3
"Cells between the glyph and the caption."
const CB_GAP = 1
"The focused control: what SPACE will act on. `TC_CURSOR`'s meaning."
const CB_FOCUS = (; underline = true)

# --- Checkbox --------------------------------------------------------

"""
A toggleable box with a caption. Parametric on the handler, so
`on_change` is a CONCRETE field and never a boxed closure.
"""
mutable struct Checkbox{F} <: Widget
    "Per-widget state."
    node::WidgetNode
    "The caption. LAYOUT-reactive: a new caption is a new extent."
    label::Any
    "UNCHECKED, CHECKED or MIXED. PAINT-reactive; see `CB_WIDTH`."
    state::Any
    "True while focused. PAINT-reactive."
    focused::Any
    "Called as `on_change(checkbox)` after a REAL change."
    on_change::Any
end

"""
A checkbox captioned `label` that calls `on_change(checkbox)` after a
real state change.

Focusable by construction, so it appears in `focusable_widgets` and is
reachable by TAB with no further wiring. The `label`/`state` split is
`Button`'s exactly (button.jl:30-31): `label` is `Dirty.LAYOUT`-reactive
(a new caption is a new extent), `state` is `Dirty.PAINT`-reactive (every
glyph is `CB_WIDTH` wide, so it cannot move a cell).
"""
function Checkbox(label::AbstractString, on_change::Any = _tc_noop;
                  state::Any = CheckState.UNCHECKED,
                  id::Symbol = gensym(:checkbox),
                  classes = Symbol[])::Any where {F}
    w = Checkbox{F}(WidgetNode(; id = id, classes = classes,
                               type_name = :Checkbox, focusable = true),
                    Reactive(String(label)),
                    Reactive(state; kind = Dirty.PAINT),
                    Reactive(false; kind = Dirty.PAINT),
                    on_change)
    attach_reactives!(w)
    return w
end

"""
The glyph for `s`. Pure. Internal.
"""
_cb_glyph(s::Any)::String =
    s === CheckState.CHECKED ? CB_CHECKED :
    s === CheckState.MIXED ? CB_MIXED : CB_UNCHECKED

"""
The CONTENT extent: `Size(CB_WIDTH, 1)` bare, or `CB_WIDTH + CB_GAP +
text_width(label)` wide with a caption.

A content extent, like every other `measure`: the box overhead is
`outer_size`'s job and adding it here would count it twice (button.jl:52).
NOT `avail` -- a greedy checkbox would shrink a one-row Label beside it to
ZERO rows. Pure w.r.t. the tree.
"""
measure(w::Any, avail::Any)::Any =
    isempty(w.label[]) ? Size(CB_WIDTH, 1) :
    Size(CB_WIDTH + CB_GAP + text_width(w.label[]), 1)

"""
Paint the box glyph, then the caption, underlined while focused.

The glyph goes at column 1, the caption at `CB_WIDTH + CB_GAP + 1`, and a
caption wider than the box is truncated at the content edge by
`_tc_slice!`.
"""
function render!(w::Any, buf::Any)::Nothing
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    st = computed_style(w)
    w.focused[] && (st = merge(st, CB_FOCUS))
    write_text!(buf, 1, 1, _cb_glyph(w.state[]), st)
    lbl = w.label[]
    isempty(lbl) ||
        _tc_slice!(buf, CB_WIDTH + CB_GAP + 1, 1, width, lbl, st)
    return nothing
end

"""
The current state. Pure.
"""
check_state(w::Any)::Any = w.state[]

"""
True iff the box is `CHECKED`. Pure.
"""
is_checked(w::Any)::Bool = w.state[] === CheckState.CHECKED

"""
Set the state, firing `on_change` only when it actually moves. True iff
it changed.

THE single exit. The `Reactive` `==` guard already makes a redundant
write free (reactive.jl:63); the explicit compare here is what stops
`on_change` firing on a write that changes nothing.
"""
function set_state!(w::Any, s::Any)::Bool
    w.state[] === s && return false
    w.state[] = s
    w.on_change(w)
    return true
end

"""
Toggle the box and return the NEW state.

`CHECKED` becomes `UNCHECKED`; anything else -- INCLUDING `MIXED` --
becomes `CHECKED`. See `CheckState` for why a program-set `MIXED` must
toggle out to `CHECKED`.
"""
function toggle!(w::Any)::Any
    set_state!(w, w.state[] === CheckState.CHECKED ?
                  CheckState.UNCHECKED : CheckState.CHECKED)
    return w.state[]
end

"""
SPACE toggles and consumes. ENTER does NEITHER.

BOTH space forms are checked -- `Key.SPACE` (what the parser emits) and
`Key.CHAR(' ')` -- exactly as `Button` does (button.jl:105). ENTER is
left unconsumed on purpose: ENTER in a form is SUBMIT, and a checkbox
that eats it makes ENTER the one key an app cannot bind. Unmodified keys
only; TAB, ESCAPE and modified keys pass through untouched so the tab
order stays alive.
"""
function on_event!(w::Any, d::Any)::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    e = event(d)
    isempty(e.mods) || return nothing
    if e.code === Key.SPACE || (e.code === Key.CHAR && e.char == ' ')
        toggle!(w)
        consume!(d)
    end
    return nothing
end

"""
A LEFT press toggles and consumes, anywhere in the box or caption.

`Button`'s rule (button.jl:119): the press does the work; the matching
release activates nothing and consumes nothing. The box is one widget, so
a click on the caption toggles it just like a click on the glyph.
"""
function on_event!(w::Any, d::Any)::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    e = event(d)
    e.button === MouseButton.LEFT || return nothing
    if e.action === MouseAction.PRESS
        toggle!(w)
        consume!(d)
    end
    return nothing
end

"""
Show the focus underline. `reveal!` is called EXPLICITLY because
overriding `on_focus!` REPLACES the default that would have called it
(widget.jl:666).
"""
on_focus!(w::Any)::Nothing = (w.focused[] = true; reveal!(w))

"""
Clear the focus underline.
"""
on_blur!(w::Any)::Nothing = (w.focused[] = false; nothing)

# --- RadioGroup ------------------------------------------------------

"""
A one-of-N chooser. ONE widget, N rows, ZERO child widgets. Parametric on
the handler, so `on_change` is a CONCRETE field and never boxed.

    (o) Small
    ( ) Medium
    ( ) Large

WHERE THE MUTUAL EXCLUSION LIVES: in `selected`, which is ONE `Int`.
There is no state in which two options are on, therefore there is no code
that prevents it, therefore there is no bug in which that code fails. The
alternative -- a `Radio` widget per option with a `checked::Bool` and a
back-pointer -- makes "exactly one" an INVARIANT MAINTAINED BY A LOOP,
and `radio.state[] = CHECKED` from application code leaves it broken
PERMANENTLY. An `Int` needs no maintenance, so there is no maintenance to
get wrong. This is `Selection.cursor`'s argument (tablecore.jl:236) and
`List`'s "a row is not a widget" (list.jl:14), one type down: N options
are N `String`s and ZERO `WidgetNode`s -- and, easy to miss, zero
hit-test nodes, so `hit_test` stays O(depth) on every POINTER MOVE.

THERE IS NO `Radio` WIDGET IN THIS FILE and there is not going to be.

NOT SCROLLABLE, NOT WINDOWED: `render!` is O(options), and an option IS a
row, so O(options) IS O(viewport) here. Ten options is the design centre;
two hundred options are a `List`. SIZES TO CONTENT and is NOT greedy:
`Size(CB_WIDTH + CB_GAP + widest, n)`. `options` is ALIASED, never
copied.
"""
mutable struct RadioGroup{F} <: Widget
    "Per-widget state."
    node::WidgetNode
    "The captions, one per row. ALIASED, mutated in place."
    const options::Any
    """
    The CHOSEN option, 1-based; `0` when nothing is chosen -- and NOTHING
    is chosen initially, exactly as `Selection` chooses nothing
    (tablecore.jl:258). PAINT-reactive: every glyph is `CB_WIDTH` wide and
    the box is as wide as the widest caption whatever is picked, so this
    provably cannot move a cell.
    """
    selected::Any
    """
    The cursor, 1-based; `0` when there are no options. The option SPACE
    would choose. ARROWS MOVE THIS WITHOUT CHOOSING, and that is why it is
    a SECOND field: selection-follows-arrow would make SPACE a NO-OP on
    the row it just moved to and fire `on_change` on EVERY KEYSTROKE --
    the trap `List` documents (list.jl:96). PAINT-reactive.
    """
    cursor::Any
    "True while focused. PAINT-reactive."
    focused::Any
    "Called as `on_change(group)` after a REAL choice."
    on_change::Any
end

"""
A radio group over `options`, calling `on_change(group)` after a real
choice.

Focusable by construction. `selected` seeds to `0` (nothing chosen);
`cursor` seeds to row 1, or `0` when there are no options. `options` is
ALIASED, not copied.
"""
function RadioGroup(options::Any, on_change::Any = _tc_noop;
                    id::Symbol = gensym(:radiogroup),
                    classes = Symbol[])::Any where {F}
    w = RadioGroup{F}(
        WidgetNode(; id = id, classes = classes,
                   type_name = :RadioGroup, focusable = true),
        options,
        Reactive(0; kind = Dirty.PAINT),
        Reactive(isempty(options) ? 0 : 1; kind = Dirty.PAINT),
        Reactive(false; kind = Dirty.PAINT),
        on_change)
    attach_reactives!(w)
    return w
end

"""
A radio group over any string vector, collected ONCE into a
`Vector{String}`.
"""
RadioGroup(options::Any, args...;
           kwargs...) =
    RadioGroup(collect(String, options), args...; kwargs...)

"""
The chosen option index; `0` iff nothing is chosen. Pure.
"""
selected(w::Any)::Int = w.selected[]

"""
The chosen caption, or `nothing`. Pure.
"""
selected_option(w::Any)::Any =
    w.selected[] == 0 ? nothing : w.options[w.selected[]]

"""
The cursor row; `0` iff there are no options. Pure.
"""
radio_cursor(w::Any)::Int = w.cursor[]

"""
The CONTENT extent: `Size(0, 0)` when empty, else `Size(CB_WIDTH + CB_GAP
+ widest, n)`. NOT `avail`. Pure w.r.t. the tree.
"""
function measure(w::Any, avail::Any)::Any
    n = length(w.options)
    n == 0 && return Size(0, 0)
    widest = 0
    for o in w.options
        widest = max(widest, text_width(o))
    end
    return Size(CB_WIDTH + CB_GAP + widest, n)
end

"""
Paint one row per option: `RB_ON`/`RB_OFF` at column 1, the caption at
`CB_WIDTH + CB_GAP + 1`, and the focus underline on the CURSOR row while
focused. `break`s past the buffer height.
"""
function render!(w::Any, buf::Any)::Nothing
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    st = computed_style(w)
    foc = w.focused[]
    cur = w.cursor[]
    sel = w.selected[]
    n = length(w.options)
    for row in 1:height
        row > n && break
        rst = (foc && row == cur) ? merge(st, CB_FOCUS) : st
        write_text!(buf, 1, row, sel == row ? RB_ON : RB_OFF, rst)
        cap = w.options[row]
        isempty(cap) ||
            _tc_slice!(buf, CB_WIDTH + CB_GAP + 1, row, width, cap, rst)
    end
    return nothing
end

"""
Move the cursor to `i`, clamped to `1:n`. True iff it moved. Does NOT
choose and does NOT fire `on_change`. Internal.
"""
function _rg_cursor!(w::Any, i::Int)::Bool
    n = length(w.options)
    n == 0 && return false
    j = clamp(i, 1, n)
    w.cursor[] == j && return false
    w.cursor[] = j
    return true
end

"""
Choose option `i`, clamped to `1:n`, and move the cursor there -- a
choice is where you are. True iff the SELECTION changed; `false` when
`n == 0` or the option was already chosen. Fires `on_change` only on a
real change.

THE single exit for a choice.
"""
function choose!(w::Any, i::Int)::Bool
    n = length(w.options)
    n == 0 && return false
    j = clamp(i, 1, n)
    _rg_cursor!(w, j)
    w.selected[] == j && return false
    w.selected[] = j
    w.on_change(w)
    return true
end

"""
The 1-based option row under mouse event `e`; `0` for a miss.

`_tc_local`, NEVER `local_offset` (events.jl:450): a `RadioGroup` inside a
`Scrollpane` scrolled off the top would choose the wrong row with the
unshifted border box. Bounds-checked against `layout_of(w).content` and
the option count. Internal.
"""
function _rg_row_at(w::Any, e::Any)::Int
    c = layout_of(w).content
    (c.width <= 0 || c.height <= 0) && return 0
    o = _tc_local(w, e)
    (1 <= o.x <= c.width) || return 0
    (1 <= o.y <= c.height) || return 0
    (1 <= o.y <= length(w.options)) || return 0
    return o.y
end

"""
Arrows move the cursor; SPACE or ENTER choose it.

UP/LEFT and DOWN/RIGHT move the cursor without choosing; HOME/END jump to
the ends; SPACE (BOTH forms -- `Key.SPACE` and `Key.CHAR(' ')`) or ENTER
commit the choice. Consumes ONLY on a real move or choice, so UP on
option 1 bubbles. Unmodified keys only; TAB, ESCAPE and modified keys
pass through untouched.
"""
function on_event!(w::Any, d::Any)::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    e = event(d)
    isempty(e.mods) || return nothing
    n = length(w.options)
    moved = false
    if e.code === Key.UP || e.code === Key.LEFT
        moved = _rg_cursor!(w, w.cursor[] - 1)
    elseif e.code === Key.DOWN || e.code === Key.RIGHT
        moved = _rg_cursor!(w, w.cursor[] + 1)
    elseif e.code === Key.HOME
        moved = _rg_cursor!(w, 1)
    elseif e.code === Key.END
        moved = _rg_cursor!(w, n)
    elseif e.code === Key.ENTER || e.code === Key.SPACE ||
           (e.code === Key.CHAR && e.char == ' ')
        moved = choose!(w, w.cursor[])
    else
        return nothing
    end
    moved && consume!(d)
    return nothing
end

"""
A LEFT press on an option row chooses it, cursor and all, and consumes.

A press outside the rows chooses nothing and does not consume. `Button`'s
rule (button.jl:119): the press does the work; the release does nothing.
"""
function on_event!(w::Any, d::Any)::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    e = event(d)
    e.button === MouseButton.LEFT || return nothing
    e.action === MouseAction.PRESS || return nothing
    row = _rg_row_at(w, e)
    row == 0 && return nothing
    choose!(w, row)
    consume!(d)
    return nothing
end

"""
Show the focus underline. `reveal!` is called EXPLICITLY, as for
`Checkbox`.
"""
on_focus!(w::Any)::Nothing = (w.focused[] = true; reveal!(w))

"""
Clear the focus underline.
"""
on_blur!(w::Any)::Nothing = (w.focused[] = false; nothing)
