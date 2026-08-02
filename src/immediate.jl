"""
Immediate mode UI for ManyUI.

Provides a procedural API for building interfaces.
The interface is rebuilt automatically when interactive elements are triggered.
"""
module Immediate

using ..ManyUI
using DocStringExtensions

export ImmediateContext, ImmediateContainer, @immediate
export text, button, textinput, progressbar

"""
Context for an immediate mode UI render pass.
Retains state across frames and reconciles the widget tree.

$(TYPEDFIELDS)
"""
mutable struct ImmediateContext
    "Counts the number of widgets generated in the current frame to generate stable IDs."
    counter::Int
    "Persisted state across renders (e.g. input values, trigger flags)."
    state::Dict{String, Any}
    "The list of widgets generated in the current frame."
    children::Vector{ManyUI.Widget}
    "A reactive variable used to force a layout/re-render of the container."
    trigger::ManyUI.Reactive{Int}
end

"""
Task-local storage key for the current immediate context.
"""
const CURRENT_CTX = task_local_storage()

# =========================================================
# Widget Builders
# =========================================================

"""
    text(s::String)

Creates a static label displaying `s`.
"""
function text(s::String)
    ctx = CURRENT_CTX[:manyui_immediate_ctx]::ImmediateContext
    ctx.counter += 1
    push!(ctx.children, ManyUI.Label(s; id=Symbol("text_", ctx.counter)))
    return nothing
end

"""
    button(label::String; id=nothing) -> Bool

Creates a button with `label`. Returns `true` if the button was clicked
during the current event loop, otherwise `false`.
"""
function button(label::String; id=nothing)
    ctx = CURRENT_CTX[:manyui_immediate_ctx]::ImmediateContext
    ctx.counter += 1
    widget_id = isnothing(id) ? "btn_$(ctx.counter)" : string(id)

    # Has it been clicked in this frame?
    clicked = get(ctx.state, "TRIGGERED", "") == widget_id
    if clicked
        ctx.state["TRIGGERED"] = "" # consume
    end

    b = ManyUI.Button(label, (w) -> begin
        # When clicked, we set the trigger ID in state and bump the version
        ctx.state["TRIGGERED"] = widget_id
        ctx.trigger[] += 1
    end; id=Symbol(widget_id))

    push!(ctx.children, b)
    return clicked
end

"""
    textinput(placeholder::String; id=nothing, is_password=false) -> String

Creates a text input field. Returns the current text entered by the user.
"""
function textinput(placeholder::String; id=nothing, is_password=false)
    ctx = CURRENT_CTX[:manyui_immediate_ctx]::ImmediateContext
    ctx.counter += 1
    widget_id = isnothing(id) ? "input_$(ctx.counter)" : string(id)

    current_val = get(ctx.state, widget_id, "")

    inp = ManyUI.TextInput(current_val, (w) -> begin
        # On submit, update state and trigger rebuild
        ctx.state[widget_id] = w.text[]
        ctx.state["TRIGGERED"] = widget_id
        ctx.trigger[] += 1
    end; placeholder=placeholder, is_password=is_password, id=Symbol(widget_id))

    push!(ctx.children, inp)
    return current_val
end

"""
    progressbar(value::Real; id=nothing)

Creates a progress bar filled to `value` (clamped between 0.0 and 1.0).
"""
function progressbar(value::Real; id=nothing)
    ctx = CURRENT_CTX[:manyui_immediate_ctx]::ImmediateContext
    ctx.counter += 1
    widget_id = isnothing(id) ? "prog_$(ctx.counter)" : string(id)

    pb = ManyUI.ProgressBar(Float64(value); id=Symbol(widget_id))
    push!(ctx.children, pb)
    return nothing
end

# =========================================================
# Container
# =========================================================

"""
A container that evaluates a UI building function procedurally,
and reconciles the resulting widgets with its existing children
so that focus and cursor positions are preserved.

$(TYPEDFIELDS)
"""
mutable struct ImmediateContainer <: ManyUI.Widget
    "The generic widget node state."
    node::ManyUI.WidgetNode
    "The procedural function to execute."
    ui_func::Function
    "The immediate mode state context."
    ctx::ImmediateContext
    "The actual layout container holding the widgets."
    container::ManyUI.Container
end

"""
    ImmediateContainer(ui_func::Function)

Constructs a new `ImmediateContainer` that will execute `ui_func`
procedurally to build its children.
"""
function ImmediateContainer(ui_func::Function)
    trigger = ManyUI.Reactive(0; kind = ManyUI.Dirty.LAYOUT)
    ctx = ImmediateContext(0, Dict{String,Any}(), ManyUI.Widget[], trigger)

    container = ManyUI.Container()
    w = ImmediateContainer(ManyUI.WidgetNode(type_name=:ImmediateContainer), ui_func, ctx, container)
    ManyUI.bind_owner!(trigger, w)
    ManyUI.attach_reactives!(w)

    # Initial build
    _rebuild!(w)
    ManyUI.node(container).parent = w
    return w
end

"""
    _rebuild!(w::ImmediateContainer)

Re-evaluates the `ui_func`, diffs the new widgets with the old ones,
and updates the container's children accordingly.
"""
function _rebuild!(w::ImmediateContainer)
    w.ctx.counter = 0
    empty!(w.ctx.children)
    CURRENT_CTX[:manyui_immediate_ctx] = w.ctx

    try
        w.ui_func()
    finally
        delete!(CURRENT_CTX, :manyui_immediate_ctx)
    end

    old_children = collect(ManyUI.children(w.container))
    old_by_id = Dict(ManyUI.node(c).id => c for c in old_children)

    new_children = ManyUI.Widget[]
    for c in w.ctx.children
        id = ManyUI.node(c).id
        if haskey(old_by_id, id) && typeof(old_by_id[id]) === typeof(c)
            old_c = old_by_id[id]
            if old_c isa ManyUI.Label
                old_c.text[] = c.text[]
            elseif old_c isa ManyUI.Button
                old_c.label[] = c.label[]
                old_c.on_click = c.on_click
                old_c.disabled[] = c.disabled[]
            elseif old_c isa ManyUI.TextInput
                # Text inputs manage their own typing state.
                old_c.placeholder = c.placeholder
                old_c.on_submit = c.on_submit
                old_c.disabled[] = c.disabled[]
            elseif old_c isa ManyUI.ProgressBar
                old_c.progress[] = c.progress[]
            end
            push!(new_children, old_c)
        else
            push!(new_children, c)
        end
    end

    for c in old_children
        ManyUI.unmount!(c)
    end

    for c in new_children
        ManyUI.mount!(w.container, c)
    end
end

ManyUI.children(w::ImmediateContainer) = (w.container,)

ManyUI.measure(w::ImmediateContainer, avail::ManyUI.Size) = ManyUI.measure(w.container, avail)

function ManyUI.layout!(w::ImmediateContainer)
    _rebuild!(w)
    ManyUI.layout!(w.container)
end

"""
    @immediate(func)

Helper macro to transform a function into a `ImmediateContainer`.
"""
macro immediate(func)
    return :(ImmediateContainer($(esc(func))))
end

end # module
