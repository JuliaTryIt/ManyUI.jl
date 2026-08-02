# popup.jl -- the popup layer: a widget painted OVER the tree.
#
# The spec (2.5) already asks for a layer that renders over the root -- the
# "Increase Terminal Size" overlay -- and the App implements it as
# `app.overlay`, an ordinary widget painted after `app.root` in `frame!`.
# A popup is that same idea made dynamic: instead of one fixed overlay, an
# owner opens a second root (a `DropDown`'s list, a menu, a tooltip) that
# paints over the tree and is hit-tested BEFORE it.
#
# This file holds the framework-neutral half -- the `Popup` value and where
# it lands on screen. The App-facing verbs (`open_popup!`, `close_popup!`,
# `popup_of`, `_popup_dismiss!`) live next to `App`, in popup_ops.jl, so
# they can dispatch on it and reach `frame!`/dispatch.

"""
Where a popup sits relative to the widget that opened it.

`BELOW` and `ABOVE` are fixed; `AUTO` prefers `BELOW` and flips to `ABOVE`
only when the popup would fall off the bottom. `CENTER` ignores the owner and
centres the popup in the viewport, for modal dialogs.
"""
module PopupPlacement
@enum T::UInt8 begin
    BELOW = 0
    ABOVE = 1
    AUTO = 2
    CENTER = 3
end
end

"""
One open popup: a `content` root painted over the tree, the `owner` that
opened it, the `size` the owner declares for it, and a `placement`.

`content` is UNPARENTED -- not in `app.root`'s tree -- which is what lets it
be laid out and painted as a second root without disturbing the first.
`owner` is the widget notified when the popup closes (`on_popup_close!`).
`size` is the owner's declaration, not the content's `measure`: a `List`'s
`measure` returns the whole viewport, so the owner is the only thing that
knows how big its own popup should be.
"""
mutable struct Popup
    "The second root, painted over the tree. Unparented."
    const content::Widget
    "The widget that opened it, notified on close."
    const owner::Widget
    "The owner's declared size, including any border."
    const size::Size
    "Where it sits relative to the owner."
    const placement::PopupPlacement.T
end

"""
$(SIGNATURES)

A popup over `content`, owned by `owner`, `size` cells, placed by
`placement` (default `AUTO`).
"""
Popup(content::Widget, owner::Widget, size::Size;
      placement::PopupPlacement.T = PopupPlacement.AUTO)::Popup =
    Popup(content, owner, size, placement)

"""
$(SIGNATURES)

Notify `w` that its popup has closed. The default is a no-op; a widget that
opens popups (a `DropDown`) overrides it to reset its own state. Called
AFTER `app.popup` is cleared, so an override may reopen without looping.
"""
on_popup_close!(::Widget)::Nothing = nothing

"""
$(SIGNATURES)

The on-screen [`Region`](@ref) a popup of `size` occupies when opened off
`head` (the owner's border box) inside `viewport`. Pure, so placement is
testable with no App.

`CENTER` is centred on both axes and does not depend on `head`. `ABOVE`
always sits above. `BELOW` and `AUTO` both ANCHOR below and flip
above only when the popup would run off the bottom and there is room above
-- an anchored dropdown wants to open downward but must stay on screen, so
"below" is a preference, not a demand. Either way the result is clamped to
the screen: a list taller than the terminal is not a special case, it is
just clipped.
"""
function popup_region(head::Region, size::Size,
                      placement::PopupPlacement.T, viewport::Size)::Region
    w = min(size.width, viewport.width)
    h = min(size.height, viewport.height)
    if placement === PopupPlacement.CENTER
        x = 1 + div(viewport.width - w, 2)
        y = 1 + div(viewport.height - h, 2)
        return Region(x, y, w, h)
    end
    # x tracks the head, then slides left just enough to stay on screen.
    x = clamp(head.x, 1, max(1, viewport.width - w + 1))
    below_y = head.y + head.height            # first row under the head
    above_y = head.y - h                       # top row of an above popup
    fits_below = below_y + h - 1 <= viewport.height
    place_above = placement === PopupPlacement.ABOVE ||
                  (!fits_below && above_y >= 1)
    y = place_above ? above_y : below_y
    y = clamp(y, 1, max(1, viewport.height - h + 1))
    return Region(x, y, w, h)
end
