# error_boundary.jl -- a widget that catches crashes in its children

"""
A widget that acts like a React Error Boundary.
It attempts to layout and paint its `child`. If the child throws an exception
during any phase (event dispatch, layout, or paint), the `ErrorBoundary` catches it
and replaces the child with a fallback error widget displaying the crash details,
preventing the entire application from tearing down.
"""
mutable struct ErrorBoundary <: Widget
    node::WidgetNode
    child::Widget
    err::Union{Nothing, Exception}
    err_widget::Union{Nothing, Widget}

    function ErrorBoundary(child::Widget;
                           id::Symbol = gensym(:error_boundary),
                           classes = Symbol[])
        new(WidgetNode(; type_name=:ErrorBoundary, id=id, classes=classes), child, nothing, nothing)
    end
end

children(w::ErrorBoundary)::Tuple{Widget} = w.err === nothing ? (w.child,) : (w.err_widget,)

"""
Safely execute `f`. If it throws, transition to the error state.
"""
function _catch_error!(w::ErrorBoundary, f)::Bool
    w.err !== nothing && return false # already crashed
    try
        f()
        return true
    catch e
        w.err = e isa Exception ? e : ErrorException(string(e))
        msg = sprint(showerror, w.err)
        w.err_widget = Container(
            Label("💥 WIDGET CRASHED"; color=:white, background=:red),
            Label(msg; color=:red);
            border=:round, color=:red, layout=:column
        )
        node(w.err_widget).app = node(w).app
        return false
    end
end
