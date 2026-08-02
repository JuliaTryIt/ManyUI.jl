# widgets/button.jl -- layer 7.
# May reference: widget, reactive, paint, buffer, layout, unicode.
#
# E3 in practice: the two `on_event!` methods below are the whole
# handler story. No callback registry, no Dict{Symbol,Function}, no
# closure table -- just double dispatch on (widget type, event type).

"""
A pressable button. Parametric on the handler, so `on_click` is a
CONCRETE field and never a boxed closure.
"""
mutable struct Button{F} <: Widget
    "Per-widget state."
    node::WidgetNode
    "The caption; writing it marks the button dirty."
    label::Reactive{String}
    "True while the button is held."
    pressed::Reactive{Bool}
    "Called as `on_click(button)` when activated."
    on_click::F
    "True if the button is disabled and cannot be pressed."
    disabled::Reactive{Bool}
end

"""
A button captioned `label` that calls `on_click(button)` when
activated.

Focusable by construction, so it appears in `focusable_widgets` and is
reachable by TAB with no further wiring.

`label` is `Dirty.LAYOUT`-reactive (a new caption is a new extent);
`pressed` is `Dirty.PAINT`-reactive (it cannot move a single cell).
"""
function Button(label::AbstractString, on_click::F;
                disabled::Bool = false,
                id::Symbol = gensym(:button),
                classes = Symbol[])::Button{F} where {F}
    w = Button{F}(WidgetNode(; id = id, classes = classes,
                             type_name = :Button, focusable = true),
                  Reactive(String(label)),
                  Reactive(false; kind = Dirty.PAINT),
                  on_click,
                  Reactive(disabled; kind = Dirty.PAINT))
    attach_reactives!(w)
    return w
end

"""
The caption's extent, `Size(text_width(label), 1)`. Pure with respect
to the tree.

This is a CONTENT extent, like every other `measure`. The box overhead
-- margin, border, padding -- is added by the layout engine through
`outer_size`; adding it here as well would count it twice.
"""
measure(w::Button, avail::Size)::Size = Size(text_width(w.label[]), 1)

"""
Paint the caption, centred in the content box, reversed while held.

Truncated at the content box's right edge; a wide cluster that would
straddle it is dropped rather than halved.
"""

"""
True while `d` is live and at or past its target -- everywhere except
the capture phase.

A button activates on the way UP: capture belongs to ancestors that
want to intercept, and a button is never an interceptor. `AT_TARGET`
counts because a childless button IS the target, and the bubble phase
excludes the target, so bubble alone would never visit it.
"""
_bt_activates(d::Dispatch)::Bool =
    d.phase !== Phase.CAPTURE && !is_consumed(d)

"""
Fire the handler and stop the event.
"""
function _bt_fire!(w::Button, d::Dispatch)::Nothing
    w.on_click(w)
    consume!(d)
    return nothing
end

"""
Activate on ENTER or SPACE: calls `w.on_click(w)` and `consume!(d)`.

Unmodified keys only. `ctrl+enter` and friends belong to an
application-level binding, and consuming them here would silently
shadow it.
"""
function on_event!(w::Button, d::Dispatch{KeyEvent})::Nothing
    _bt_activates(d) || return nothing
    w.disabled[] && return nothing
    e = event(d)
    isempty(e.mods) || return nothing
    if e.code === Key.ENTER || e.code === Key.SPACE ||
       (e.code === Key.CHAR && e.char == ' ')
        _bt_fire!(w, d)
    end
    return nothing
end

"""
Activate on a LEFT press: calls `w.on_click(w)` and `consume!(d)`.

The matching LEFT release clears `pressed` -- that is what makes "True
while the button is held" true -- but activates nothing and consumes
nothing: the press already did the work.
"""
function on_event!(w::Button, d::Dispatch{MouseEvent})::Nothing
    _bt_activates(d) || return nothing
    w.disabled[] && return nothing
    e = event(d)
    e.button === MouseButton.LEFT || return nothing
    if e.action === MouseAction.PRESS
        w.pressed[] = true
        _bt_fire!(w, d)
    elseif e.action === MouseAction.RELEASE
        w.pressed[] = false
    end
    return nothing
end
