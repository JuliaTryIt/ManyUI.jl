# widgets/dropdown.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode, popup
# (`Popup`, `PopupPlacement`, `open_popup!`, `close_popup!`, `popup_of`,
# `on_popup_close!`), `_sp_box!` (scroll.jl), `List`/`set_items!`
# (list.jl), `_tc_noop`/`_tc_show`/`_tc_row_at`/`_tc_slice!`/
# `set_cursor!`/`move_cursor!`/`row_cursor` (tablecore.jl), `_lst_scan!`
# (list.jl) -- USED, never redefined, exactly as `list.jl` treats
# `tablecore.jl`.
#
# A `DropDown` is the widget the whole popup layer exists for. Closed it
# is a one-row head showing its selection; open it is a `List` painted
# OVER the tree through the popup layer, clipped only by the screen. The
# head keeps focus while open and FORWARDS the keyboard, exactly as an
# HTML `<select>` does -- the popup is a paint-and-hit layer, never a
# focus layer.

"Arrow, closed. Width 1 BY CONSTRUCTION, asserted."
const DD_CLOSED = "v"
"Arrow, open. Width 1 BY CONSTRUCTION, asserted."
const DD_OPEN = "^"
"Cells the arrow and its separating space claim on the closed row."
const DD_ARROW_W = 2
"The focused head. `TC_CURSOR`'s meaning."
const DD_FOCUS = Style(; underline = true)
"Rows a `DropDown` shows before its list scrolls, by default."
const DD_MAX_ROWS = 8

# --- DropDownList: the popup's content root ---------------------------

"""
A `DropDown`'s open list: the popup's CONTENT ROOT, its BORDER, and its
click interceptor.

INTERNAL machinery -- the `Scrollpane` `row`/`canvas`/`holder` pattern
(scroll.jl:216) -- with one difference that matters: IT IS NOT IN
`app.root`'s TREE AT ALL. It is what `Popup.content` points at, it is
UNPARENTED, and `open_popup!` throws if it ever stops being.

IT EXISTS FOR EXACTLY ONE REASON, and the reason is two source lines. A
row click must COMMIT, and a `List` click cannot: `_tc_mouse!` calls
`set_cursor!`, which under SINGLE selects AND CONSUMES
(tablecore.jl:1145), and `_walk!` RETURNS THE INSTANT `is_consumed(d)`
(dispatch.jl:88) -- so nothing above the list ever hears about it. This
node sits between the popup's root and the `List` and takes the LEFT
PRESS IN CAPTURE, BEFORE the list can eat it. "Capture belongs to
ancestors that want to intercept" (button.jl:78) -- a `DropDown` is
precisely an interceptor of its own list, and this is the one widget in
the codebase for which that sentence is a specification rather than an
aside.

It earns its keep TWICE: it is also the frame (the border) the list
needs, and the node `popup_opaque!` makes opaque.

`owner` is `Union{Nothing,Widget}` and bound AFTER construction:
`DropDown` holds this and this holds the `DropDown`, and a
self-referential parametric type is not expressible in Julia. ONE
dynamic dispatch per CLICK; NEVER on the frame path.

`list` is CONCRETE (`L<:Widget`), so `_tc_row_at(w.list, e)` dispatches
STATICALLY -- the `Scrollbar{V}`/`Button{F}`/`List{T,F,A}` pattern.
"""
mutable struct DropDownList{L<:Widget} <: Widget
    "Per-widget state."
    node::WidgetNode
    "The options, as a `List`. A CHILD of this node."
    const list::L
    "The `DropDown` a row click commits to. Bound by the constructor."
    owner::Union{Nothing,Widget}
end

"""
Intercept a LEFT PRESS on a row IN CAPTURE and COMMIT it, before the
`List` can select-and-consume it.

`is_scroll` FIRST, so a wheel notch over the open list falls through to
the `List` at target and `_tc_wheel!` scrolls it -- a wheel over a
dropdown's list is a scroll, not a choice. A DRAG likewise falls
through. `_tc_row_at` and NOT `row_cursor`: at capture the `List` has
not moved its cursor yet, so `row_cursor` is still the OLD row;
`_tc_row_at` reads the POINTER, over `painted_region`, and is correct
inside a scrolled pane.
"""
function on_event!(w::DropDownList, d::Dispatch{MouseEvent})::Nothing
    d.phase === Phase.CAPTURE || return nothing
    is_consumed(d) && return nothing
    e = event(d)
    is_scroll(e) && return nothing
    (e.button === MouseButton.LEFT &&
     e.action === MouseAction.PRESS) || return nothing
    o = w.owner
    o === nothing && return nothing
    k = _tc_row_at(w.list, e)
    k == 0 && return nothing
    _dd_commit!(o, k)
    consume!(d)
    return nothing
end

# --- DropDown ---------------------------------------------------------

"""
A drop-down selection control: a one-row head, and an open list the App
paints OVER the tree through the popup layer.

`panel` is THE popup's content; NOT a child, and absent from
`children(w)` -- so it is not laid out with the tree, not painted with
the tree, and NOT IN THE TAB ORDER. The popup is a paint-and-hit layer,
not a focus layer: the DropDown KEEPS FOCUS while it is open and
forwards, exactly as an HTML `<select>` does.

`selected` is the COMMITTED option and `row_cursor(w.panel.list)` is the
BROWSING position while open -- TWO fields on purpose. ESCAPE and a
click-away abandon the highlight and KEEP the selection; ENTER and a row
click promote the highlight TO the selection. ONE field could not
express "arrowed to Large, pressed ESCAPE, still Medium".

`open` and `selected` are `Dirty.PAINT`-reactive: the arrow is one cell,
and `measure` is `_lst_scan!`'s widest-over-ALL-options plus a constant,
a function of the DATA and not of the selection, so the box does not
jump when you pick a shorter option.
"""
mutable struct DropDown{T,F,C} <: Widget
    "Per-widget state."
    node::WidgetNode
    """
    The open list and its frame. THE popup's content; NOT a child, and
    absent from `children(w)`. The popup is a paint-and-hit layer, not a
    focus layer: the DropDown KEEPS FOCUS while it is open and forwards.
    """
    const panel::DropDownList{List{T,F,typeof(_tc_noop)}}
    "True while the popup is open. PAINT-reactive: the arrow flips."
    open::Reactive{Bool}
    "The COMMITTED option, 1-based; `0` when nothing is chosen."
    selected::Reactive{Int}
    "True while focused. PAINT-reactive."
    focused::Reactive{Bool}
    "Rows the open list shows at most, before it scrolls."
    const max_rows::Int
    "Shown when `selected == 0`."
    const placeholder::String
    "Called as `on_change(dd)` when the selection COMMITS."
    on_change::C
end

"""
A drop-down over `items`, calling `on_change(dropdown)` when the
selection COMMITS.

`items` is ALIASED by the underlying `List`, never copied. `format`,
`max_rows` and `placeholder` shape the head and the open list; the head
sizes to the WIDEST option (never `avail`), so a `Label` beside it keeps
its rows.

Focusable by construction; the open list is NOT -- it is the popup and
the popup is not a focus layer.
"""
function DropDown(items::Vector{T}, on_change::C = _tc_noop;
                  format::F = _tc_show, max_rows::Int = DD_MAX_ROWS,
                  placeholder::AbstractString = "",
                  id::Symbol = gensym(:dropdown),
                  classes = Symbol[])::DropDown{T,F,C} where {T,F,C}
    lst = List(items, _tc_noop; format = format,
               mode = SelectMode.SINGLE, id = Symbol(id, :_list))
    node(lst).focusable = false
    _sp_box!(lst, BoxPatch(; grow = 1f0))
    panel = DropDownList{typeof(lst)}(
        WidgetNode(; id = Symbol(id, :_panel),
                   type_name = :DropDownList), lst, nothing)
    _sp_box!(panel, BoxPatch(; display = Display.FLEX,
                             direction = Direction.COLUMN,
                             border = Border(BorderKind.SOLID,
                                             STYLE_NONE)))
    mount!(panel, lst)
    w = DropDown{T,F,C}(
        WidgetNode(; id = id, classes = classes,
                   type_name = :DropDown, focusable = true),
        panel,
        Reactive(false; kind = Dirty.PAINT),
        Reactive(0; kind = Dirty.PAINT),
        Reactive(false; kind = Dirty.PAINT),
        max_rows, String(placeholder), on_change)
    attach_reactives!(w)
    w.panel.owner = w
    return w
end

"""
A drop-down over any `AbstractVector`, collected ONCE into a `Vector`.
"""
DropDown(items::AbstractVector, args...; kwargs...) =
    DropDown(collect(items), args...; kwargs...)

"""
The head's extent: the widest option (or the placeholder) plus the
arrow. NOT `avail` -- a greedy `measure` would shrink a `Label` beside
this to zero rows.

O(1) after the first call, because `_lst_scan!` is MEMOIZED on
`List.scanned` (list.jl:200), and THIS IS THE FRAME PATH. Writing
`maximum(text_width, items)` here is forbidden.
"""
measure(w::DropDown, avail::Size)::Size =
    Size(max(_lst_scan!(w.panel.list),
             text_width(w.placeholder)) + DD_ARROW_W, 1)

"""
The head's caption: the placeholder when nothing is selected, else the
committed option through the `List`'s own formatter. Internal.
"""
function _dd_caption(w::DropDown)::String
    s = w.selected[]
    s == 0 && return w.placeholder
    lst = w.panel.list
    return String(lst.format(lst.items[s]))
end

"""
Paint the caption, truncated to leave room for the arrow, and the arrow
in the last column. Underlined while focused, and the arrow flips
`v`/`^` with `open`.
"""
function render!(w::DropDown, buf::AbstractMatrix{Cell})::Nothing
    width, height = size(buf)
    (width <= 0 || height <= 0) && return nothing
    st = computed_style(w)
    w.focused[] && (st = merge(st, DD_FOCUS))
    _tc_slice!(buf, 1, 1, width - DD_ARROW_W, _dd_caption(w), st)
    arrow = w.open[] ? DD_OPEN : DD_CLOSED
    write_text!(buf, width, 1, arrow, st)
    return nothing
end

# --- pure / read-only API ---------------------------------------------

"The options, ALIASED. Pure."
options(w::DropDown) = w.panel.list.items

"The committed option index, `0` when nothing is chosen. Pure."
selected(w::DropDown)::Int = w.selected[]

"""
The committed option, or `nothing` when nothing is chosen. Pure.
"""
function selected_item(w::DropDown{T})::Union{Nothing,T} where {T}
    s = w.selected[]
    s == 0 && return nothing
    return w.panel.list.items[s]
end

"True while the popup is open. Pure."
is_open(w::DropDown)::Bool = w.open[]

# --- keyboard: the head OWNS the keyboard and FORWARDS ----------------

"""
True while `d` is live and at or past its target, with no modifiers.

A `DropDown` activates on the way up, never in capture -- the same rule
`Button` uses -- and leaves MODIFIED keys, TAB and BACK_TAB unconsumed
so the tab order stays alive and `ctrl+*` bindings are not shadowed.
Internal.
"""
_dd_acts(d::Dispatch, e::KeyEvent)::Bool =
    d.phase !== Phase.CAPTURE && !is_consumed(d) && isempty(e.mods)

"""
Keys while OPEN: UP/DOWN move the list's browsing cursor, ENTER and
SPACE COMMIT the highlight, ESCAPE closes without committing. SPACE is
`Key.SPACE` (and the legacy `Key.CHAR(' ')` form), never one or the
other. Consumes ONLY what it handles. Internal.
"""
function _dd_key_open!(w::DropDown, d::Dispatch, e::KeyEvent)::Nothing
    if e.code === Key.UP
        move_cursor!(w.panel.list, -1)
        consume!(d)
    elseif e.code === Key.DOWN
        move_cursor!(w.panel.list, 1)
        consume!(d)
    elseif e.code === Key.ENTER || e.code === Key.SPACE ||
           (e.code === Key.CHAR && e.char == ' ')
        _dd_commit!(w, row_cursor(w.panel.list))
        consume!(d)
    elseif e.code === Key.ESCAPE
        _dd_close!(w)
        consume!(d)
    end
    return nothing
end

"""
Keys while CLOSED: UP/DOWN cycle the committed selection and fire
`on_change` -- what an HTML `<select>` does closed -- and ENTER or SPACE
open the list. SPACE is `Key.SPACE`. Consumes ONLY what it handles.
Internal.
"""
function _dd_key_closed!(w::DropDown, d::Dispatch, e::KeyEvent)::Nothing
    if e.code === Key.UP
        _dd_select!(w, w.selected[] - 1)
        consume!(d)
    elseif e.code === Key.DOWN
        _dd_select!(w, w.selected[] + 1)
        consume!(d)
    elseif e.code === Key.ENTER || e.code === Key.SPACE ||
           (e.code === Key.CHAR && e.char == ' ')
        _dd_open!(w)
        consume!(d)
    end
    return nothing
end

"""
Forward the keyboard: OPEN and CLOSED behave differently and each
consumes only what it handles, so TAB, BACK_TAB and modified keys stay
unconsumed and the tab order -- and close-on-TAB -- keep working.
"""
function on_event!(w::DropDown, d::Dispatch{KeyEvent})::Nothing
    e = event(d)
    _dd_acts(d, e) || return nothing
    w.open[] ? _dd_key_open!(w, d, e) : _dd_key_closed!(w, d, e)
    return nothing
end

"""
A LEFT press on the head TOGGLES the popup: it opens a closed list and
closes an open one. A press outside is `_popup_dismiss!`'s job; a press
ON the head is delivered here (that clause of `_popup_dismiss!` returns
false), which is why clicking the head of an open dropdown closes it
here instead of dismiss-then-reopen. Wheel and drag fall through.
"""
function on_event!(w::DropDown, d::Dispatch{MouseEvent})::Nothing
    d.phase === Phase.CAPTURE && return nothing
    is_consumed(d) && return nothing
    e = event(d)
    is_scroll(e) && return nothing
    e.button === MouseButton.LEFT || return nothing
    if e.action === MouseAction.PRESS
        w.open[] ? _dd_close!(w) : _dd_open!(w)
        consume!(d)
    end
    return nothing
end

# --- open / close / commit / select -----------------------------------

"""
`Size` the OPEN popup occupies, INCLUDING the frame's border.

`clamp(n, 1, max_rows) + 2` rows and AT LEAST as wide as the head, which
is what makes a dropdown look attached to its anchor. THIS IS THE
OWNER'S DECLARATION that `Popup.size` is a field for: asking the content
would ask a `List`, whose `measure` returns `avail` (list.jl:246) -- the
entire viewport. `popup_region` then clamps this to the screen, so a
400-item list on a 24-row terminal is not a special case here.

`_lst_scan!` is MEMOIZED (list.jl:200), so this is O(1) per open after
the first. Internal.
"""
function _dd_popup_size(w::DropDown)::Size
    n = length(w.panel.list.items)
    wd = max(_lst_scan!(w.panel.list),
             text_width(w.placeholder)) + 2      # +2: the border
    return Size(max(wd, region(w).width),
                clamp(n, 1, w.max_rows) + 2)      # +2: the border
end

"""
Open the popup. False when it is already open, when there are no
options, or when there is no App.

`focus!(a, w)` FIRST, AND IT IS NOT A COURTESY: there is no
click-to-focus in DualUI, so without it a MOUSE-OPENED dropdown leaves
focus on whatever had it and UP/DOWN/ENTER/ESCAPE go somewhere else --
an open list you cannot drive. `focus!` is a no-op when `w` is already
focused, so the keyboard path pays nothing. BEFORE `open_popup!`, so
that `on_blur!` on the previously focused widget -- which may be another
`DropDown` closing its own popup through the GUARDED `close_popup!(app,
owner)` -- cannot slam the popup we are about to open.

A DROPDOWN WITH NO APP CANNOT OPEN, stated rather than worked around:
what survives standalone is the whole of the CLOSED widget -- it
constructs, measures, paints its selection, and UP/DOWN cycle that
selection and fire `on_change`.

Puts the list's cursor on the CURRENT selection, so DOWN-DOWN-ENTER from
a selected option moves TWO, not to the top. Internal.
"""
function _dd_open!(w::DropDown)::Bool
    w.open[] && return false
    isempty(w.panel.list.items) && return false
    a = app(w)
    a isa App || return false
    focus!(a, w)                       # F3. See above.
    open_popup!(a, Popup(w.panel, w, _dd_popup_size(w);
                         placement = PopupPlacement.BELOW))
    w.open[] = true
    s = w.selected[]
    set_cursor!(w.panel.list, s == 0 ? 1 : s)
    return true
end

"""
Close OUR popup. True iff it was open.

`close_popup!(a, w)` -- the GUARDED form -- because the unguarded one
would slam a popup a DIFFERENT widget opened in the same event burst,
which is exactly what TABbing from one dropdown onto another does. Also
clears `open[]` when there is no App, so a standalone widget cannot be
stranded believing it is open. Internal.
"""
function _dd_close!(w::DropDown)::Bool
    a = app(w)
    a isa App || return (w.open[] = false; false)
    return close_popup!(a, w)          # -> on_popup_close!(w)
end

"""
The App closed our popup -- by `_dd_close!`, a press outside, a resize, a
blur, an unmount, or another widget opening one. NOTIFICATION ONLY, and
provably non-looping because `app.popup` is cleared first.

REVERTS the list's cursor to the COMMITTED option, which is what makes
ESCAPE and click-away both ABANDON the highlight. After `_dd_commit!`
the two are already equal and this is a no-op -- so COMMIT NEEDS NO
SPECIAL CASE.
"""
function on_popup_close!(w::DropDown)::Nothing
    w.open[] = false
    s = w.selected[]
    s == 0 || set_cursor!(w.panel.list, s)
    return nothing
end

"""
Promote VIEW row `k` to the selection, close, and fire `on_change` IFF
it really changed. True iff `k` was in range.

THE single exit of every commit -- keyboard ENTER, keyboard SPACE and a
row click all land here. Internal.
"""
function _dd_commit!(w::DropDown, k::Int)::Bool
    n = length(w.panel.list.items)
    (1 <= k <= n) || return false
    changed = w.selected[] != k
    w.selected[] = k
    set_cursor!(w.panel.list, k)       # BEFORE the close: see above
    _dd_close!(w)
    changed && w.on_change(w)
    return true
end

"""
The CLOSED-state selection cycle: clamp to `1:n`, early-out on no
change, write `selected[]`, fire `on_change`. Does NOT touch the popup.
Internal.
"""
function _dd_select!(w::DropDown, k::Int)::Bool
    n = length(w.panel.list.items)
    n == 0 && return false
    t = clamp(k, 1, n)
    w.selected[] == t && return false
    w.selected[] = t
    w.on_change(w)
    return true
end

"""
Open or close the popup. `true` iff the state changed. Public.
"""
set_open!(w::DropDown, v::Bool)::Bool = v ? _dd_open!(w) : _dd_close!(w)

"""
Replace the options. CLOSES the popup first, clears the selection, and
marks the head for relayout EXPLICITLY.

The list is UNBOUND while closed (`close_popup!` clears `node(w).app`),
so its `Reactive` marks nothing and posts nothing, and the DropDown's
own `measure` just changed -- hence the explicit `mark!` and `post!`.
Clearing `selected` is `set_items!(::List)`'s argument verbatim
(list.jl:394): an index into data that no longer exists names the WRONG
option.
"""
function set_items!(w::DropDown, xs::AbstractVector)::Nothing
    _dd_close!(w)
    set_items!(w.panel.list, xs)
    w.selected[] = 0
    mark!(w, Dirty.LAYOUT)
    a = app(w)
    a === nothing || post!(a, RefreshEvent())
    return nothing
end

# --- lifecycle --------------------------------------------------------

"""
Gain focus: show as focused and reveal into any scrolling ancestor.
`reveal!` is called EXPLICITLY because overriding `on_focus!` REPLACES
the default that would have called it.
"""
on_focus!(w::DropDown)::Nothing = (w.focused[] = true; reveal!(w))

"""
Lose focus: the popup's lifetime is bounded by its owner's focus, which
is what makes TAB-while-open correct with ZERO code in app.jl -- TAB is
not consumed -> `:focus_next` -> `focus!` -> `on_blur!` -> here.
"""
on_blur!(w::DropDown)::Nothing =
    (w.focused[] = false; _dd_close!(w); nothing)

"""
Close on unmount: a popup outliving its owner is a list anchored to a
widget that is no longer in any tree. Relies on `unmount!` calling
`on_unmount!` BEFORE it clears `node(w).app` (widget.jl:367, 374), so
`app(w)` still finds the App and the popup actually goes.
"""
on_unmount!(w::DropDown)::Nothing = (_dd_close!(w); nothing)
