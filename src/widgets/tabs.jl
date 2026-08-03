# widgets/tabs.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode,
# `_sp_box!` (scroll.jl), `_tc_local`/`_tc_slice!`/`_tc_noop`
# (tablecore.jl) -- USED, never redefined, exactly as `list.jl` treats
# `tablecore.jl`.
#
# A CAPTION IS NOT A WIDGET. Captions are `String`s and panels are
# children: an INACTIVE panel is `set_visible!(false)` and that is the
# WHOLE implementation. From that one flag come four properties, none of
# them code in this file -- an invisible panel paints nothing
# (paint.jl:103), claims no layout space (layout.jl:267,377), drops out
# of the tab order (`walk_visible`, dispatch.jl:184) and is unclickable
# (dispatch.jl:43). A lookup table would reimplement all four.

"Cells of padding on each side of a caption. `\" One \"` is width 5."
const TABS_PAD = 1
"The active caption. `TC_SELECTED`'s meaning, one file over."
const TABS_ACTIVE = Style(; reverse = true)
"The strip while focused: which caption the arrows will move from."
const TABS_FOCUS = Style(; underline = true)

"""
The clickable row of captions. INTERNAL machinery of `Tabs`, exactly as
`Scrollpane`'s `row`/`canvas` are (scroll.jl:216), but a WIDGET rather
than a `render!` branch of `Tabs` for one hard reason: `_paint_node!`
hands `render!` the CONTENT box (paint.jl:134), so a `Tabs` that drew
its own strip would have to reserve row 1 with `padding.top = 1` --
which puts the strip OUTSIDE the very buffer it would draw into.
"""
mutable struct TabStrip <: Widget
    "Per-widget state."
    node::WidgetNode
    "Captions in order. ALIASED with the owner `Tabs`: the SAME
     `Vector`, so the strip cannot go stale and nothing is copied."
    const titles::Vector{String}
    """
    The chosen tab, 1-based; `0` IFF `isempty(titles)`. THE single
    source of truth -- `Tabs` has NO `selected` field and reads this.
    One cell, one meaning, no mirror to keep in step.

    `Dirty.PAINT`-reactive, and the licence is the one `TextInput` states
    verbatim (textinput.jl:158) and `List` cites (list.jl:43): `measure`
    must be independent of the state. It is -- `measure` below is a
    function of `titles` alone. THE PANELS' `Dirty.LAYOUT` COMES FROM
    `set_visible!`, NOT FROM THIS CELL, which is why PAINT here is
    provable and not optimistic.
    """
    selected::Reactive{Int}
    "True while focused. PAINT-reactive."
    focused::Reactive{Bool}
    "True if the tabs are disabled."
    disabled::Reactive{Bool}
end

"""
A tab strip plus panels.

`Tabs` SIZES TO CONTENT and is NOT greedy. It defines no `measure` and
no `render!` -- the Container defaults are already exactly right
(container.jl:27), and the inactive panels are absent from the
children's measure union because they are invisible. Give it `grow: 1`
or a `height` for a full-height tab view. A `measure` returning `avail`
here would make a one-row `Label` beside a `Tabs` into a ZERO-row label.
"""
mutable struct Tabs <: Widget
    "Per-widget state."
    node::WidgetNode
    const strip::TabStrip
    "True if the tabs are disabled."
    disabled::Reactive{Bool}
end

"""
A `Tabs` whose captions and panels are given as `title => panel` pairs,
in order. The first tab is selected; the rest of the panels start
hidden.

The strip is mounted as child 1 through `invoke` (the `Scrollpane`
idiom, scroll.jl:37), because `mount!(::Tabs, ::Widget)` throws to force
`add_tab!`.
"""
function Tabs(pairs::Pair{<:AbstractString,<:Widget}...;
              id::Symbol = gensym(:tabs), classes = Symbol[],
              disabled::Bool = false)::Tabs
    strip = TabStrip(
        WidgetNode(; id = Symbol(id, :_strip), type_name = :TabStrip,
                   focusable = !disabled),
        String[],
        Reactive(0; kind = Dirty.PAINT),
        Reactive(false; kind = Dirty.PAINT),
        Reactive(disabled; kind = Dirty.PAINT))
    attach_reactives!(strip)
    _sp_box!(strip, BoxPatch(; height = cells(1), shrink = 0f0,
                             grow = 0f0))
    w = Tabs(WidgetNode(; id = id, classes = classes,
                        type_name = :Tabs), strip,
             Reactive(disabled; kind = Dirty.PAINT))
    _sp_box!(w, BoxPatch(; display = Display.FLEX,
                         direction = Direction.COLUMN))
    invoke(mount!, Tuple{Widget,Widget}, w, strip)
    for (title, panel) in pairs
        add_tab!(w, title, panel)
    end
    attach_reactives!(w)
    return w
end

"""
`parent(w)` as a `Tabs`, or `nothing`.

THE ONE `isa` IN THIS FILE, and its scope is why it is affordable: both
types are in THIS file, at THIS layer, and the check runs on a KEYSTROKE
or a CLICK, NEVER on the frame path. The owner is `parent(w)` BY
CONSTRUCTION: `Tabs` mounts its strip as child 1 and nothing else ever
mounts a `TabStrip`.

A strip with no `Tabs` parent is INERT rather than an error: a bare
`TabStrip` is a legal, if useless, widget, and a test that builds one
must not throw. Internal.
"""
function _tb_owner(w::TabStrip)::Union{Nothing,Tabs}
    p = parent(w)
    return p isa Tabs ? p : nothing
end

"""
The strip-local column at which caption `i` begins. Captions abut with
no separator, so this is one running sum -- the SAME one `render!` and
`tab_at` walk. Internal.
"""
function _tb_title_x(titles::Vector{String}, i::Int)::Int
    x = 1
    for k in 1:(i - 1)
        x += text_width(titles[k]) + 2 * TABS_PAD
    end
    return x
end

"""
The 1-based caption covering strip-local column `x`; `0` for none.

PURE -- a `Vector{String}` and an `Int`, no widget, no layout, no
buffer. `tab_at` and `render!` walk the SAME running sum in the SAME
direction, which is what makes "click the caption you see" true by
construction rather than by two arithmetics agreeing by luck.
"""
function tab_at(titles::Vector{String}, x::Int)::Int
    x < 1 && return 0
    c = 1
    for (i, t) in enumerate(titles)
        w = text_width(t) + 2 * TABS_PAD
        x < c + w && return i
        c += w
    end
    return 0
end

"""
Set exactly the selected panel visible and every other hidden.

`set_visible!` returns early on the value it already has
(widget.jl:513), so this is O(tabs) compares and at most TWO
`Dirty.LAYOUT` marks. Internal.
"""
function _tb_sync!(w::Tabs)::Nothing
    sel = w.strip.selected[]
    cs = children(w)
    for i in 2:length(cs)
        set_visible!(cs[i], (i - 1) == sel)
    end
    return nothing
end

"""
The number of tabs. Pure.
"""
n_tabs(w::Tabs)::Int = length(w.strip.titles)

"""
The chosen tab, 1-based; `0` iff there are no tabs. Pure.
"""
selected(w::Tabs)::Int = w.strip.selected[]

"""
The caption of tab `i`. Pure. Throws on a bad index -- a caller naming a
tab that does not exist has a bug.
"""
tab_title(w::Tabs, i::Int)::String = w.strip.titles[i]

"""
The panel of tab `i`. The strip is child 1, so panel `i` is child
`i + 1`. Pure.
"""
tab_panel(w::Tabs, i::Int)::Widget = children(w)[i + 1]

"""
Append a tab captioned `title` showing `panel`, and return its index.

The panel is mounted through `invoke` (the strip's own idiom), given
`grow = 1f0`, and hidden unless it is the FIRST -- the first tab becomes
the selection. `mark!(w.strip, Dirty.LAYOUT)` because a new caption is a
new strip extent.
"""
function add_tab!(w::Tabs, title::AbstractString, panel::Widget)::Int
    push!(w.strip.titles, String(title))
    invoke(mount!, Tuple{Widget,Widget}, w, panel)
    _sp_box!(panel, BoxPatch(; grow = 1f0))
    i = length(w.strip.titles)
    i == 1 && (w.strip.selected[] = 1)
    _tb_sync!(w)
    mark!(w.strip, Dirty.LAYOUT)
    return i
end

"""
Select tab `i`, CLAMPED to `1:n_tabs`. True iff the selection moved;
`false` when it was unmoved or there are no tabs.

THE single exit: it writes `w.strip.selected[]` and then `_tb_sync!`.
Clamped rather than thrown -- `set_cursor!` clamps for the same reason
(tablecore.jl:353).
"""
function select_tab!(w::Tabs, i::Int)::Bool
    n = n_tabs(w)
    n == 0 && return false
    j = clamp(i, 1, n)
    j == w.strip.selected[] && return false
    w.strip.selected[] = j
    _tb_sync!(w)
    return true
end

"""
`Size(sum(text_width(t) + 2 * TABS_PAD), 1)`.

NOT `avail`, and this is browser-lesson 2 written into a signature: a
`measure` that returns `avail` demands the whole viewport and flex then
shrinks its neighbours -- a one-row `Label` beside it becomes a ZERO-row
label and VANISHES. A strip is exactly as wide as its captions and
exactly one row tall. IT IS NOT GREEDY. Give the `Tabs` `grow: 1`, not
the strip. Pure w.r.t. the tree.
"""
function measure(w::TabStrip, avail::Size)::Size
    n = length(w.titles)
    n == 0 && return Size(0, 1)
    total = 0
    for t in w.titles
        total += text_width(t) + 2 * TABS_PAD
    end
    return Size(total, 1)
end

"""
Paint the captions on row 1, each padded ` title `, the selected one
REVERSED and the whole strip UNDERLINED while focused.

Truncated at the right edge, never scrolled: a tab strip that scrolls is
a strip with too many tabs. Captions abut with no separator and a wide
cluster is never halved -- `_tc_slice!` steps by grapheme.
"""

"""
Panels are added with `add_tab!`, never `mount!`: mounting one directly
would leave the strip's titles and the children out of step. Throws.
"""
function mount!(::Tabs, ::Widget)
    throw(ArgumentError("use add_tab! to add a panel to a Tabs"))
end

"""
The strip gained focus: light the focus underline and reveal it.

`reveal!` is called EXPLICITLY because overriding `on_focus!` REPLACES
the default that would have called it (widget.jl:666).
"""
on_focus!(w::TabStrip)::Nothing =
    (w.focused[] = true; reveal!(w); _focus_callback!(w))

"""
The strip lost focus: drop the focus underline.
"""
on_blur!(w::TabStrip)::Nothing =
    (w.focused[] = false; _blur_callback!(w))

"""
Keyboard: LEFT/RIGHT step the selection (clamped, no wrap), HOME/END go
to the ends, and `'1'`-`'9'` select by ordinal. Consumes ONLY when the
selection actually moved, so RIGHT on the last tab bubbles.

TAB, ESCAPE, modified keys and everything else are left untouched: a
strip that ate TAB would trap focus forever.
"""
function on_event!(w::TabStrip, d::Dispatch{KeyEvent})::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    w.disabled[] && return nothing
    t = _tb_owner(w)
    t === nothing && return nothing
    e = event(d)
    isempty(e.mods) || return nothing
    n = n_tabs(t)
    n == 0 && return nothing
    sel = w.selected[]
    moved = false
    if e.code === Key.LEFT
        moved = select_tab!(t, sel - 1)
    elseif e.code === Key.RIGHT
        moved = select_tab!(t, sel + 1)
    elseif e.code === Key.HOME
        moved = select_tab!(t, 1)
    elseif e.code === Key.END
        moved = select_tab!(t, n)
    elseif e.code === Key.CHAR && '1' <= e.char <= '9'
        moved = select_tab!(t, Int(e.char - '0'))
    else
        return nothing
    end
    moved && consume!(d)
    return nothing
end

"""
Mouse: a LEFT press selects the caption under the pointer, located
through `_tc_local` (NOT `local_offset`, which ignores scrolled
ancestors). Consumes only on a real change.
"""
function on_event!(w::TabStrip, d::Dispatch{MouseEvent})::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    w.disabled[] && return nothing
    t = _tb_owner(w)
    t === nothing && return nothing
    e = event(d)
    (e.button === MouseButton.LEFT &&
     e.action === MouseAction.PRESS) || return nothing
    i = tab_at(w.titles, _tc_local(w, e).x)
    i == 0 && return nothing
    select_tab!(t, i) && consume!(d)
    return nothing
end
