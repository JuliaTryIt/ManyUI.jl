# reactive.jl -- layer 5. May reference: widget, types.
# E1: a state write is what makes a frame happen, and nothing else.

"""
A reactive cell.

Assigning a value that differs (`!=`) from the current one marks
`owner` dirty with `kind` AND posts a `RefreshEvent`, so a write from a
worker task actually repaints.

Concretely typed: a widget field `count::Reactive{Int}` stays
type-stable. `owner` is a small union, NOT `Any`.

    label.text[]          # read,  zero cost
    label.text[] = "hi"   # write, marks dirty, schedules a frame

Choosing `Dirty.PAINT` for state that can change size is a correctness
bug, so the default is the conservative `Dirty.LAYOUT`.
"""
mutable struct Reactive{T}
    "The current value."
    value::T
    "The widget marked dirty on a real change."
    owner::Union{Nothing,Widget}
    "What a real change invalidates."
    const kind::Dirty.T
end

"""
An unbound cell holding `v`.

The parametric form pins `T`; the plain form infers it from `v`. Both
default to the conservative `Dirty.LAYOUT`. Call `bind_owner!` (or
`attach_reactives!`) to give the cell a widget to invalidate.
"""
function Reactive{T}(v::T; kind::Dirty.T = Dirty.LAYOUT) where {T}
    return Reactive{T}(v, nothing, kind)
end

# Documented above, with the parametric form: both methods share one
# doc signature, and documenting each would replace the other.
function Reactive(v::T; kind::Dirty.T = Dirty.LAYOUT) where {T}
    return Reactive{T}(v, nothing, kind)
end

"""
Read the value. Type-stable and allocation-free. Pure.
"""
function Base.getindex(r::Reactive{T})::T where {T}
    return r.value
end

"""
E1. Write the value.

NO-OP -- no dirty mark, no `RefreshEvent` -- when `v == r.value`. The
`==` guard means a redundant write costs one comparison and zero
frames.

On a real change: `r.value = v`; `mark!(r.owner, r.kind)`; and when
`app(r.owner) !== nothing`, `post!(app, RefreshEvent())`.
"""
function Base.setindex!(r::Reactive{T}, v::T)::T where {T}
    # The E1 guard. `==`, not `===`: two equal Strings are the same
    # state even when they are different objects, and repainting on an
    # identical write is exactly the waste E1 forbids.
    v == r.value && return r.value
    r.value = v
    o = r.owner
    o === nothing && return v
    mark!(o, r.kind)
    # An unmounted widget has no app to wake; marking it dirty is still
    # correct, and the frame happens when it is mounted.
    a = app(o)
    a === nothing || post!(a, RefreshEvent())
    return v
end

"""
Write the value, converting to `T` first.
"""
function Base.setindex!(r::Reactive{T}, v)::T where {T}
    return setindex!(r, convert(T, v))
end

"""
Point `r` at the widget it invalidates.
"""
function bind_owner!(r::Reactive, w::Widget)::Nothing
    r.owner = w
    return nothing
end

"""
Wire every `Reactive` field of `w` to `w`. Call at the END of a widget
constructor.

Uses `fieldnames` plus `getfield`, and skips non-`Reactive` fields.
"""
function attach_reactives!(w::Widget)::Nothing
    for name in fieldnames(typeof(w))
        f = getfield(w, name)
        f isa Reactive && bind_owner!(f, w)
    end
    return nothing
end
