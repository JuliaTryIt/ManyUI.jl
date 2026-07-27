# widgets/form.jl -- layer 7, LAST.
# May reference: widget, reactive, paint, buffer, layout, unicode, and
# every field-type file above it -- it names TextInput, TextArea,
# Checkbox, RadioGroup, DropDown and Tabs to give each a `form_value`.
#
# THE HONEST SCOPE, up front: a Form is a Container that can be submitted
# and read. It adds `submit!`, the `form_value` protocol and
# `form_values`, and NOTHING ELSE -- no `on_event!`, no focus concept, no
# validation DSL. TAB traversal is `focusable_widgets`', which already
# works through a bare Container; a Form that "added" it would only add a
# docstring, and a Form that TRAPPED it would be a bug.

"""
THE value protocol: what `w` MEANS to a form. Add ONE method to make a
widget a form field.

THROWS `MethodError` BY DEFAULT ON PURPOSE, and does NOT return
`nothing`: a `Label` has no value, and a form that silently reports
`nothing` for a field the author expected to read is a form that SAVES A
BLANK. A `MethodError` names the type.

`form_value` and not `value`: `value` is far too generic a name for a UI
package to export, and `form_values` below would then read as its
plural. `grid_of` (tablecore.jl) is the precedent -- a seam is a
FUNCTION, not a supertype, which is what lets six unrelated widget types
share it.

THE METHODS LIVE HERE, NOT IN EACH WIDGET'S FILE, and the layering and
the manifest agree for once: "what this widget means to a form" is the
FORM'S concept, not the text field's.
"""
function form_value end

# SOURCE wins over the contract here: there is no `text(::TextInput)`
# method (only `text(::TextArea)`), so a `TextInput`'s content is read
# through its `text` reactive. Reported as a deviation.
form_value(w::TextInput)::String = w.text[]
form_value(w::TextArea)::String = text(w)
form_value(w::Checkbox)::CheckState.T = w.state[]
form_value(w::RadioGroup)::Int = w.selected[]
form_value(w::DropDown)::Int = w.selected[]
form_value(w::Tabs)::Int = selected(w)

"The default validator: everything passes. Internal."
_fm_ok(::Widget)::Bool = true

"""
A `Container` that can be submitted and read. Parametric on the two
handlers, so `on_submit` and `on_validate` are CONCRETE fields and never
boxed closures -- the `Button{F}` pattern.
"""
mutable struct Form{S,V} <: Widget
    "Per-widget state."
    node::WidgetNode
    "Named fields, in `add_field!` order. NOT the tab order -- that is
     `children`, pre-order, and it always was."
    const fields::Vector{Pair{Symbol,Widget}}
    "Called as `on_submit(form)` when `submit!` passes validation."
    on_submit::S
    "Called as `on_validate(form)::Bool`. False VETOES the submit."
    on_validate::V
end

"""
A `Container` that can be submitted and read.

WHAT THIS ADDS OVER A `Container`, EXHAUSTIVELY, BECAUSE THE HONEST
ANSWER IS "NOT MUCH":

  1. `submit!(f)` -- `on_validate(f)` and, iff it returns true,
     `on_submit(f)`.
  2. `form_value(w)` -- a PROTOCOL, and the only reusable thing here.
  3. `form_values(f)` -- every named field's value, once, at the
     boundary.

WHAT IT DOES NOT ADD, and the claims are worth refuting because every
framework makes them:

  * "It groups fields."   -- so does a `Container`. It IS one, and it
    defines no `render!` and no `measure` for `Container`'s reason.
  * "It traverses focus." -- `focusable_widgets` is a pre-order
    `walk_visible`. TAB ALREADY WORKS through a bare `Container`. This is
    not a feature, it is the core.
  * "ENTER submits."      -- IT DOES NOT, AND IT CANNOT. `TextInput`
    consumes ENTER unconditionally and `_walk!` STOPS DEAD on a consume,
    so a bubble handler here is NEVER REACHED from a text field.
    Capture-phase would fire and silently kill `TextInput.on_submit`,
    which is shipped and tested. So this widget DEFINES NO `on_event!` AT
    ALL, and you wire `TextInput("", _ -> submit!(f))` -- one closure,
    explicit, and exactly as many characters as the magic would have
    been. A testitem PINS this limitation, so it is a fact and not a
    comment somebody deletes.

Validation is ONE PREDICATE AND A VETO. No rule objects, no error
vector, no `:invalid` class, no DSL. Validation is a function you already
know how to write; a Form that ships a validation framework ships a DSL,
and this codebase has no DSL.

IF THAT LIST DOES NOT EARN A FILE FOR YOU, USE A `Container`. A `Form` IS
one, and nothing built on a `Form` is out of a `Container`'s reach. It
earns its forty lines because `form_value` is worth a protocol and
because "wire ENTER through the field that consumes it" is the thing
every app gets wrong once.

The Form exists BEFORE its fields, so the closure has something to
capture:

    f = Form(save_it)
    add_field!(f, :name, TextInput("", _ -> submit!(f)))
    add_field!(f, :remember, Checkbox("Remember me"))
    mount!(f, Button("Save", _ -> submit!(f)))

No chicken-and-egg, no registry, no `Ref`.
"""
function Form(on_submit::S = _tc_noop; on_validate::V = _fm_ok,
              id::Symbol = gensym(:form),
              classes = Symbol[])::Form{S,V} where {S,V}
    return Form{S,V}(WidgetNode(; id = id, classes = classes,
                                type_name = :Form),
                     Pair{Symbol,Widget}[], on_submit, on_validate)
end

"""
Mount `w` as a field NAMED `name` and return `f`.

`children(f)` is the TAB ORDER -- pre-order, unchanged -- and `f.fields`
is the NAME MAP; they are the same widgets in the same order. Plain
`mount!(f, w)` still works and adds an UNNAMED field: a field with no
name is one `form_values` does not report, which is right for a `Button`.
"""
function add_field!(f::Form, name::Symbol, w::Widget)::Form
    mount!(f, w)
    push!(f.fields, name => w)
    return f
end

"""
The field named `name`, or `nothing`. O(fields); a form has ten. Pure.
"""
function field(f::Form, name::Symbol)::Union{Nothing,Widget}
    for (n, w) in f.fields
        n === name && return w
    end
    return nothing
end

"""
Validate, then submit. `on_validate(f) || return false; on_submit(f);
return true`. THE whole validation story: one predicate and a veto. True
iff the submit ran.
"""
function submit!(f::Form)::Bool
    f.on_validate(f) || return false
    f.on_submit(f)
    return true
end

"""
Every NAMED field's `form_value`, keyed by its name.

ALLOCATES and is TYPE-UNSTABLE BY CONSTRUCTION -- a form is heterogeneous
by definition, its `String`s and `CheckState.T`s and `Int`s sharing one
`Dict{Symbol,Any}`. A BOUNDARY call, made once on submit and NEVER on a
frame path, which is what licenses both.
"""
function form_values(f::Form)::Dict{Symbol,Any}
    out = Dict{Symbol,Any}()
    for (n, w) in f.fields
        out[n] = form_value(w)
    end
    return out
end
