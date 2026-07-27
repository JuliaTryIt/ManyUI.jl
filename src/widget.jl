# widget.jl -- Core Widget definitions

module Dirty
@enum T::UInt8 begin
    NONE = 0x00
    PAINT = 0x01
    LAYOUT = 0x02
    STYLE = 0x04
    SUBTREE = 0x08
end
end

const DirtyMask = UInt8
const DIRTY_ALL = UInt8(0x07)

has_dirty(m::DirtyMask, k::Dirty.T)::Bool = (m & UInt8(k)) != 0x00
set_dirty(m::DirtyMask, k::Dirty.T)::DirtyMask = m | UInt8(k)
clear_dirty(m::DirtyMask, k::Dirty.T)::DirtyMask = m & ~UInt8(k)

mutable struct WidgetNode
    const id::Symbol
    const classes::Set{Symbol}
    const type_name::Symbol
    parent::Union{Nothing,Widget}
    const children::Vector{Widget}
    
    inline_style::Any
    inline_box::Any
    computed_style::Any
    box::Any
    layout::Any
    scroll::Any
    
    dirty::DirtyMask
    visible::Bool
    focusable::Bool
    app::Union{Nothing,AbstractApp}
end

function WidgetNode(; id::Symbol = gensym(:w),
             classes = Symbol[],
             type_name::Symbol = :Widget,
             visible::Bool = true,
             focusable::Bool = false)::WidgetNode
    WidgetNode(id, Set{Symbol}(classes), type_name, nothing, Widget[],
               nothing, nothing, nothing, nothing, nothing, nothing,
               DIRTY_ALL, visible, focusable, nothing)
end

function WidgetNode(id::Symbol, classes::Set{Symbol}, type_name::Symbol,
           parent::Union{Nothing,Widget}, children::Vector{Widget},
           inline_style::Any, inline_box::Any,
           computed_style::Any, box::Any, layout::Any,
           dirty::DirtyMask, visible::Bool, focusable::Bool,
           app::Union{Nothing,AbstractApp})::WidgetNode
    WidgetNode(id, classes, type_name, parent, children, inline_style,
               inline_box, computed_style, box, layout, nothing, dirty,
               visible, focusable, app)
end

node(w::Widget)::WidgetNode = w.node
id(w::Widget)::Symbol = node(w).id
classes(w::Widget)::Set{Symbol} = node(w).classes
type_name(w::Widget)::Symbol = node(w).type_name
parent(w::Widget)::Union{Nothing,Widget} = node(w).parent
children(w::Widget)::Vector{Widget} = node(w).children

is_visible(w::Widget)::Bool = node(w).visible
is_focusable(w::Widget)::Bool = node(w).focusable
app(w::Widget)::Union{Nothing,AbstractApp} = node(w).app

function _attach!(p::Widget, c::Widget)::Nothing
    node(c).parent = p
    a = app(p)
    walk(c) do w
        node(w).app = a
        on_mount!(w)
        nothing
    end
    mark!(c, Dirty.STYLE)
    mark!(c, Dirty.LAYOUT)
    return nothing
end

function mount!(p::Widget, c::Widget)::Widget
    parent(c) === nothing || throw(ArgumentError("already mounted"))
    push!(children(p), c)
    _attach!(p, c)
    return p
end

function mount!(p::Widget, cs::Widget...)::Widget
    for c in cs
        mount!(p, c)
    end
    return p
end

function insert_child!(p::Widget, i::Int, c::Widget)::Widget
    parent(c) === nothing || throw(ArgumentError("already mounted"))
    insert!(children(p), i, c)
    _attach!(p, c)
    return p
end

function unmount!(c::Widget)::Widget
    p = parent(c)
    walk(w -> (on_unmount!(w); nothing), c)
    if p !== nothing
        cs = children(p)
        i = findfirst(x -> x === c, cs)
        i === nothing || deleteat!(cs, i)
        node(c).parent = nothing
    end
    walk(w -> (node(w).app = nothing; nothing), c)
    p === nothing || mark!(p, Dirty.LAYOUT)
    return c
end

function replace_child!(p::Widget, old::Widget, new::Widget)::Widget
    i = findfirst(x -> x === old, children(p))
    i === nothing && throw(ArgumentError("not a child"))
    unmount!(old)
    insert_child!(p, i, new)
    return p
end

function root_of(w::Widget)::Widget
    r = w
    while true
        p = parent(r)
        p === nothing && return r
        r = p
    end
end

function ancestors(w::Widget)::Vector{Widget}
    out = Widget[]
    p = parent(w)
    while p !== nothing
        push!(out, p)
        p = parent(p)
    end
    return out
end

function descendants(w::Widget)::Vector{Widget}
    out = Widget[]
    for c in children(w)
        walk(x -> (push!(out, x); nothing), c)
    end
    return out
end

function path_from_root(w::Widget)::Vector{Widget}
    out = ancestors(w)
    reverse!(out)
    push!(out, w)
    return out
end

function walk(f, w::Widget)::Nothing
    f(w)
    for c in children(w)
        walk(f, c)
    end
    return nothing
end

function walk_visible(f, w::Widget)::Nothing
    is_visible(w) || return nothing
    f(w)
    for c in children(w)
        walk_visible(f, c)
    end
    return nothing
end

Base.getindex(w::Widget, i::Int)::Widget = children(w)[i]

function add_class!(w::Widget, c::Symbol)::Widget
    cs = classes(w)
    if !(c in cs)
        push!(cs, c)
        mark!(w, Dirty.STYLE)
    end
    return w
end

function remove_class!(w::Widget, c::Symbol)::Widget
    cs = classes(w)
    if c in cs
        delete!(cs, c)
        mark!(w, Dirty.STYLE)
    end
    return w
end

function toggle_class!(w::Widget, c::Symbol)::Bool
    if has_class(w, c)
        remove_class!(w, c)
        return false
    end
    add_class!(w, c)
    return true
end

has_class(w::Widget, c::Symbol)::Bool = c in classes(w)

function set_visible!(w::Widget, v::Bool)::Nothing
    n = node(w)
    n.visible == v && return nothing
    n.visible = v
    mark!(w, Dirty.LAYOUT)
    return nothing
end

const _SELECTOR_COMPOUND_RE = r"^(?:\*|[#.]?[A-Za-z_][A-Za-z0-9_-]*)+$"
const _SELECTOR_TOKEN_RE = r"\*|[#.]?[A-Za-z_][A-Za-z0-9_-]*"

function _parse_selector(sel::AbstractString)::Vector{String}
    out = String[]
    for part in split(sel, ',')
        s = String(strip(part))
        occursin(_SELECTOR_COMPOUND_RE, s) || throw(ArgumentError(
            "unsupported widget selector: $(repr(String(sel)))"))
        push!(out, s)
    end
    return out
end

function _match_compound(w::Widget, sel::AbstractString)::Bool
    for m in eachmatch(_SELECTOR_TOKEN_RE, sel)
        t = m.match
        if t == "*"
            continue
        elseif startswith(t, '#')
            id(w) === Symbol(SubString(t, 2)) || return false
        elseif startswith(t, '.')
            has_class(w, Symbol(SubString(t, 2))) || return false
        else
            type_name(w) === Symbol(t) || return false
        end
    end
    return true
end

_match_any(w::Widget, cs::Vector{String})::Bool =
    any(c -> _match_compound(w, c), cs)

function query(root::Widget, sel::AbstractString)::Vector{Widget}
    cs = _parse_selector(sel)
    out = Widget[]
    walk(root) do w
        _match_any(w, cs) && push!(out, w)
        nothing
    end
    return out
end

function _find_first(w::Widget, cs::Vector{String})::Union{Nothing,Widget}
    _match_any(w, cs) && return w
    for c in children(w)
        r = _find_first(c, cs)
        r === nothing || return r
    end
    return nothing
end

function query_one(root::Widget, sel::AbstractString)::Union{Nothing,Widget}
    return _find_first(root, _parse_selector(sel))
end

function query_one(root::Widget, sel::AbstractString, ::Type{T})::T where {T<:Widget}
    w = query_one(root, sel)
    w === nothing && throw(KeyError(sel))
    w isa T || throw(TypeError(:query_one, "", T, typeof(w)))
    return w
end

on_mount!(w::Widget)::Nothing = nothing
on_unmount!(w::Widget)::Nothing = nothing
reveal_child!(::Widget, ::Widget)::Nothing = nothing

function reveal!(w::Widget)::Nothing
    a = parent(w)
    while a !== nothing
        reveal_child!(a, w)
        a = parent(a)
    end
    return nothing
end

on_focus!(w::Widget)::Nothing = (reveal!(w); nothing)
on_blur!(w::Widget)::Nothing = nothing

function mark_dirty!(w::Widget, kind::Dirty.T = Dirty.PAINT)::Nothing
    n = node(w)
    n.dirty = set_dirty(n.dirty, kind)
    return nothing
end

function mark_subtree_dirty!(w::Widget, kind::Dirty.T)::Nothing
    walk(w) do x
        n = node(x)
        n.dirty = set_dirty(n.dirty, kind)
        nothing
    end
    return nothing
end

function _breadcrumb!(w::Widget)::Nothing
    a = parent(w)
    while a !== nothing
        n = node(a)
        n.dirty = set_dirty(n.dirty, Dirty.SUBTREE)
        a = parent(a)
    end
    return nothing
end

function mark!(w::Widget, kind::Dirty.T = Dirty.LAYOUT)::Nothing
    kind === Dirty.NONE && return nothing
    if kind === Dirty.PAINT
        mark_dirty!(w, Dirty.PAINT)
    elseif kind === Dirty.LAYOUT
        walk(w) do x
            n = node(x)
            n.dirty = set_dirty(set_dirty(n.dirty, Dirty.LAYOUT),
                                Dirty.PAINT)
            nothing
        end
    elseif kind === Dirty.STYLE
        mark_subtree_dirty!(w, Dirty.STYLE)
    else
        mark_dirty!(w, Dirty.SUBTREE)
    end
    _breadcrumb!(w)
    kind === Dirty.LAYOUT && escalate_auto!(w)
    return nothing
end

function escalate_auto!(w::Widget)::Nothing
    # Hook for layout engine in TUI
    if hasmethod(tui_escalate_auto!, Tuple{Widget})
        tui_escalate_auto!(w)
    end
    return nothing
end

function is_dirty(w::Widget, kind::Dirty.T)::Bool
    has_dirty(node(w).dirty, kind)
end

function clean!(w::Widget, kind::Dirty.T)::Nothing
    n = node(w)
    n.dirty = clear_dirty(n.dirty, kind)
    return nothing
end

function dirty_root(w::Widget, kind::Dirty.T)::Union{Nothing,Widget}
    out = nothing
    walk(w) do x
        if has_dirty(node(x).dirty, kind)
            out = out === nothing ? x : out
        end
        nothing
    end
    return out
end
