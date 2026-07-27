# types.jl -- layer 0. Abstract declarations ONLY.
# This file breaks every forward reference in the package: it is what
# lets `events.jl` name `Widget` without a dependency cycle. No methods, no constants, no structs.

"""
Base type of every UI component. Implementors provide exactly one
required method: `node(w::MyWidget)::WidgetNode`.
"""
abstract type Widget end

"""
Supertype of every input/system event.
"""
abstract type Event end
