@testitem "content_children: a plain widget's content is its mounted children" begin
    using ManyUI

    box = Container(Label("a"), Label("b"))
    @test length(content_children(box)) == 2
    @test content_children(box) === ManyUI.node(box).children
end

@testitem "content_children: a wrapper holding its child in a field declares it" begin
    using ManyUI

    # An `ErrorBoundary` keeps the widget it guards in `child`, and mounts
    # nothing, so a backend walking `node.children` finds an empty box. That is
    # how a boundary came to make its own content vanish in the browser — the
    # opposite of what a boundary is for.
    inner = Label("guarded")
    boundary = ErrorBoundary(inner)

    @test isempty(ManyUI.node(boundary).children)
    @test content_children(boundary) == [inner]
end

@testitem "content_children: the seam answers for every widget type" begin
    using ManyUI
    using InteractiveUtils

    # The point of a seam is that it is TOTAL. A backend may rely on it for any
    # widget, so a type that answers with an error would put the silence back.
    # Only ManyUI's OWN widgets: other test files define their own `Widget`
    # subtypes as fixtures, and auditing those says nothing about the backend.
    concrete = Type[]
    walk(T) = for S in subtypes(T)
        isabstracttype(S) ? walk(S) :
            (parentmodule(S) === ManyUI && push!(concrete, S))
    end
    walk(ManyUI.Widget)

    @test !isempty(concrete)
    for S in concrete
        @test hasmethod(content_children, Tuple{S})
    end
end
