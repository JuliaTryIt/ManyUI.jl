# types.jl -- layer 0. Abstract declarations ONLY.
# This file breaks every forward reference in the package: it is what
# lets `events.jl` name `Widget` and `widget.jl` name `AbstractApp`
# without a dependency cycle. No methods, no constants, no structs.

"""
Base type of every UI component. Implementors provide exactly one
required method: `node(w::MyWidget)::WidgetNode`.
"""
abstract type Widget end

"""
Abstraction isolating application logic from the rendering target.
See `driver.jl` for the required method set (nine methods, no more).
"""
abstract type Driver end

"""
Supertype of `App{D}`. Exists so `WidgetNode.app` is a small abstract
union rather than `Any`, and so `reactive.jl` can wake the app without
depending on `app.jl`.
"""
abstract type AbstractApp end

"""
Supertype of every input/system event.
"""
abstract type Event end
