# popup_ops.jl -- the App-facing popup verbs.
#
# These need `App` (they reach `app.popup`, `frame!`'s buffer and the
# dispatch walk), so they live AFTER app.jl. The `Popup` value and its
# placement math are framework-neutral and live in widgets/popup.jl.
#
# The layer is the min-size overlay's, generalized: `_paint_popup!` paints
# the content over the tree in the same `frame!` slot `_paint_overlay!`
# uses, and `_popup_dismiss!` gives the open popup first refusal on a mouse
# press.

"""
$(SIGNATURES)

The open [`Popup`](@ref), or `nothing`.
"""
popup_of(app::App)::Union{Nothing,Popup} = app.popup

"""
$(SIGNATURES)

Bind (or unbind) `app` across the popup content's subtree, so `app(w)`
resolves for a second root that is not in `app.root`'s tree. Internal.
"""
function _bind_popup_app!(content::Widget, app::Union{Nothing,App})::Nothing
    walk(content) do w
        node(w).app = app
        nothing
    end
    return nothing
end

"""
$(SIGNATURES)

Lay the popup's content out at its on-screen region: cascade its styles,
place it with [`popup_region`](@ref) off the owner's head, and lay it out
as a second root. Returns the region. Internal.
"""
function _place_popup!(app::App, p::Popup)::Region
    r = popup_region(region(p.owner), p.size, p.placement, app.viewport)
    recascade!(app.stylesheet, p.content)
    layout!(p.content, r)
    return r
end

"""
$(SIGNATURES)

Open `p` on `app`: whatever popup was open closes first (its owner is
notified), then `p` becomes the one, its content is bound to `app` and laid
out so a hit-test or a paint can find it immediately.

`open_popup!` is the unguarded form. A widget closing its OWN popup uses
`close_popup!(app, owner)`, which no-ops when the open popup belongs to
someone else -- the guard that stops a blur from slamming a popup a
different widget just opened.
"""
function open_popup!(app::App, p::Popup)::Nothing
    old = app.popup
    if old !== nothing
        app.popup = nothing
        _bind_popup_app!(old.content, nothing)
        on_popup_close!(old.owner)
    end
    app.popup = p
    _bind_popup_app!(p.content, app)
    _place_popup!(app, p)
    return nothing
end

"""
$(SIGNATURES)

Close the open popup IF it belongs to `owner`, and notify it. Returns true
iff it closed one.

`app.popup` is cleared BEFORE `on_popup_close!`, so an owner that reopens
from its own close hook cannot loop.
"""
function close_popup!(app::App, owner::Widget)::Bool
    p = app.popup
    (p !== nothing && p.owner === owner) || return false
    app.popup = nothing
    _bind_popup_app!(p.content, nothing)
    on_popup_close!(owner)
    return true
end

"""
$(SIGNATURES)

Paint the open popup's content over `app.back`, re-laying it out first so
its region tracks a resize. The `frame!` step that puts the popup over the
tree. Internal.
"""
function _paint_popup!(app::App)::Nothing
    p = app.popup
    p === nothing && return nothing
    _place_popup!(app, p)
    paint!(app.back, p.content)
    return nothing
end

"""
$(SIGNATURES)

Give the open popup first refusal on a mouse event. Returns true when it
took the event, so the tree never sees it.

    inside the popup   -> route to the content (a row commits, the list
                          scrolls); taken.
    a scroll outside   -> NOT taken: a wheel notch is never a dismiss.
    a press outside    -> close the popup and SWALLOW the press, so the
                          click that dismissed it does not also fire the
                          widget beneath. The NEXT press reaches the tree.

Internal.
"""
function _popup_dismiss!(app::App, e::MouseEvent)::Bool
    p = app.popup
    p === nothing && return false
    o = Offset(e.x, e.y)
    if o in painted_region(p.content)
        target = something(hit_test(p.content, o), p.content)
        propagate!(p.content, target, e)
        return true
    end
    is_scroll(e) && return false
    if e.action === MouseAction.PRESS
        close_popup!(app, p.owner)
        return true
    end
    return false
end
