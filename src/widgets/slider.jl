# widgets/slider.jl -- layer 7.
# May reference: widget, reactive, layout, unicode, events.

"""
A slider for picking numeric values from a range.
"""
mutable struct Slider{F} <: Widget
    "Per-widget state."
    node::WidgetNode
    "The current value."
    value::Reactive{Float64}
    "Minimum allowed value."
    const min::Float64
    "Maximum allowed value."
    const max::Float64
    "Step size for keyboard navigation."
    const step::Float64
    "True while focused."
    focused::Reactive{Bool}
    "True if the slider is disabled."
    disabled::Reactive{Bool}
    "Called as `on_change(slider)` when the value changes."
    on_change::F
end

"""
A slider from `min` to `max`.
"""
function Slider(value::Float64 = 0.0, on_change::F = _ -> nothing;
                min::Float64 = 0.0, max::Float64 = 1.0, step::Float64 = 0.1,
                id::Symbol = gensym(:slider),
                classes = Symbol[],
                disabled::Bool = false)::Slider{F} where {F}
    w = Slider{F}(WidgetNode(; id = id, classes = classes,
                             type_name = :Slider, focusable = !disabled),
                  Reactive(clamp(value, min, max); kind = Dirty.PAINT),
                  min, max, step,
                  Reactive(false; kind = Dirty.PAINT),
                  Reactive(disabled; kind = Dirty.PAINT),
                  on_change)
    attach_reactives!(w)
    return w
end

"""
A slider is 1 row high and greedily takes horizontal space.
"""
measure(w::Slider, avail::Size)::Size = Size(avail.width, 1)

"""
Handle left/right arrows for the slider.
"""
function on_event!(w::Slider, d::Dispatch{KeyEvent})::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    w.disabled[] && return nothing
    e = event(d)
    isempty(e.mods) || return nothing
    c = e.code
    changed = false
    if c === Key.LEFT
        w.value[] = clamp(w.value[] - w.step, w.min, w.max)
        changed = true
    elseif c === Key.RIGHT
        w.value[] = clamp(w.value[] + w.step, w.min, w.max)
        changed = true
    elseif c === Key.HOME
        w.value[] = w.min
        changed = true
    elseif c === Key.END
        w.value[] = w.max
        changed = true
    end
    
    if changed
        w.on_change(w)
        consume!(d)
    end
    return nothing
end

"""
Focus tracking for the slider.
"""
function on_event!(w::Slider, d::Dispatch{FocusEvent})::Nothing
    w.focused[] = event(d).gained
    return nothing
end

"""
Mouse clicking and dragging for the slider.
"""
function on_event!(w::Slider, d::Dispatch{MouseEvent})::Nothing
    (d.phase === Phase.CAPTURE || is_consumed(d)) && return nothing
    w.disabled[] && return nothing
    e = event(d)
    e.button === MouseButton.LEFT || return nothing
    
    if e.action === MouseAction.PRESS || e.action === MouseAction.DRAG
        if e.action === MouseAction.PRESS
            a = app(w)
            a === nothing || focus!(a, w)
        end
        
        width = w.node.layout.content.width
        track_width = max(1, width)
        ex = e.x - 1 # 0-based coordinate
        pct = track_width > 1 ? clamp(ex / (track_width - 1), 0.0, 1.0) : 0.0
        
        range = w.max - w.min
        raw_val = w.min + pct * range
        steps = round((raw_val - w.min) / w.step)
        stepped_val = clamp(w.min + steps * w.step, w.min, w.max)
        
        if w.value[] != stepped_val
            w.value[] = stepped_val
            w.on_change(w)
        end
        consume!(d)
    end
    return nothing
end
