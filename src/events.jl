# events.jl -- layer 2. May reference: types, geometry.
# E3 (capture/bubble propagation) and E4 (resize) event vocabulary.

"""
Logical key identity. `CHAR` means "see `KeyEvent.char`".
"""
module Key
@enum T::UInt16 begin
    CHAR = 0
    ENTER
    TAB
    BACK_TAB
    BACKSPACE
    ESCAPE
    SPACE
    UP
    DOWN
    LEFT
    RIGHT
    HOME
    END
    PAGE_UP
    PAGE_DOWN
    INSERT
    DELETE
    F1
    F2
    F3
    F4
    F5
    F6
    F7
    F8
    F9
    F10
    F11
    F12
    UNKNOWN
end
end

"""
Keyboard modifier bits. Powers of two: used as a bitset in `Modifiers`.
"""
module Modifier
@enum T::UInt8 begin
    SHIFT = 0x01
    ALT = 0x02
    CTRL = 0x04
    SUPER = 0x08
end
end

"""
A bitset of `Modifier.T` values. `isbits`.
"""
struct Modifiers
    "Bitwise OR of the active `Modifier.T` values."
    bits::UInt8
end

"""
Mouse buttons, including the four wheel pseudo-buttons.
"""
module MouseButton
@enum T::UInt8 begin
    NONE = 0
    LEFT
    MIDDLE
    RIGHT
    WHEEL_UP
    WHEEL_DOWN
    WHEEL_LEFT
    WHEEL_RIGHT
end
end

"""
What the mouse did.
"""
module MouseAction
@enum T::UInt8 begin
    PRESS = 0
    RELEASE
    MOVE
    DRAG
end
end

"""
A keystroke. `char` is meaningful only when `code === Key.CHAR`;
otherwise it is `'\\0'`.
"""
struct KeyEvent <: Event
    "Logical key."
    code::Key.T
    "Character produced, when `code === Key.CHAR`."
    char::Char
    "Active modifiers."
    mods::Modifiers
end

"""
A mouse action. `x`/`y` are 1-based ABSOLUTE screen cells; widget-local
coordinates come from `local_offset(d)`, never hand-rolled at the call
site.
"""
struct MouseEvent <: Event
    "Press, release, move or drag."
    action::MouseAction.T
    "Button involved, or a wheel direction."
    button::MouseButton.T
    "Absolute 1-based column."
    x::Int
    "Absolute 1-based row."
    y::Int
    "Active modifiers."
    mods::Modifiers
end

"""
The renderable area changed. Never parsed from bytes: injected by a
driver through `notify_resize!`.
"""
struct ResizeEvent <: Event
    "The new renderable area."
    size::Size
end

"""
A completed bracketed paste.
"""
struct PasteEvent <: Event
    "The pasted text, verbatim."
    text::String
end

"""
The terminal or browser tab gained or lost focus.
"""
struct FocusEvent <: Event
    "True on focus gained, false on focus lost."
    gained::Bool
end

"""
A timer tick.
"""
struct TickEvent <: Event
    "Wall clock stamp of the tick."
    time::Float64
end

"""
Forces a full repaint. THE reconnect / wake seam: because it travels
the same `Channel{Event}` as everything else, `events(d)` really is the
only way into the App. `handle!(app, ::RefreshEvent)` calls
`invalidate!` internally.
"""
struct RefreshEvent <: Event
end

"""
Requests loop shutdown. `handle!` sets `app.running = false`.
"""
struct QuitEvent <: Event
end

const MOD_NONE = Modifiers(0x00)

"""
No modifiers.
"""
Modifiers()::Modifiers = MOD_NONE

"""
The bitset of the given modifiers. Duplicates collapse and the argument
order is irrelevant: this is a set union. Pure.
"""
function Modifiers(ms::Modifier.T...)::Modifiers
    bits = 0x00
    for m in ms
        bits |= UInt8(m)
    end
    return Modifiers(bits)
end

"""
True when `m` is in the set. Pure.
"""
Base.in(m::Modifier.T, ms::Modifiers)::Bool =
    (ms.bits & UInt8(m)) != 0x00

"""
Add a modifier to the set. Pure.
"""
Base.:|(a::Modifiers, b::Modifier.T)::Modifiers =
    Modifiers(a.bits | UInt8(b))

"""
Union of two modifier sets. Pure.
"""
Base.:|(a::Modifiers, b::Modifiers)::Modifiers =
    Modifiers(a.bits | b.bits)

"""
True when no modifier is active. Pure.
"""
Base.isempty(ms::Modifiers)::Bool = ms.bits == 0x00

"""
The modifier bitset for the three keyword flags `key` and the key
parser share. Pure.
"""
function _mods(ctrl::Bool, alt::Bool, shift::Bool)::Modifiers
    bits = 0x00
    shift && (bits |= UInt8(Modifier.SHIFT))
    alt && (bits |= UInt8(Modifier.ALT))
    ctrl && (bits |= UInt8(Modifier.CTRL))
    return Modifiers(bits)
end

"""
A character keystroke. Pure.
"""
key(c::Char; ctrl = false, alt = false, shift = false)::KeyEvent =
    KeyEvent(Key.CHAR, c, _mods(ctrl, alt, shift))

"""
A non-character keystroke. `char` is `'\\0'`, because it is meaningful
only when `code === Key.CHAR`. Pure.
"""
key(k::Key.T; ctrl = false, alt = false, shift = false)::KeyEvent =
    KeyEvent(k, '\0', _mods(ctrl, alt, shift))

"""
The four wheel pseudo-buttons. Scroll-ness is a property of the button,
never of the action.
"""
const _WHEEL_BUTTONS = (MouseButton.WHEEL_UP, MouseButton.WHEEL_DOWN,
                        MouseButton.WHEEL_LEFT, MouseButton.WHEEL_RIGHT)

"""
True for the four wheel pseudo-buttons. Pure.
"""
is_scroll(e::MouseEvent)::Bool = e.button in _WHEEL_BUTTONS

"""
Every accepted key NAME, already lowercased. Keys not listed here are
single characters, which are taken literally (case included) -- only
names fold case.
"""
const _KEY_NAMES = Dict{String,Key.T}(
    "enter" => Key.ENTER,
    "return" => Key.ENTER,
    "tab" => Key.TAB,
    "back_tab" => Key.BACK_TAB,
    "backtab" => Key.BACK_TAB,
    "backspace" => Key.BACKSPACE,
    "escape" => Key.ESCAPE,
    "esc" => Key.ESCAPE,
    "space" => Key.SPACE,
    "up" => Key.UP,
    "down" => Key.DOWN,
    "left" => Key.LEFT,
    "right" => Key.RIGHT,
    "home" => Key.HOME,
    "end" => Key.END,
    "page_up" => Key.PAGE_UP,
    "pageup" => Key.PAGE_UP,
    "pgup" => Key.PAGE_UP,
    "page_down" => Key.PAGE_DOWN,
    "pagedown" => Key.PAGE_DOWN,
    "pgdn" => Key.PAGE_DOWN,
    "insert" => Key.INSERT,
    "delete" => Key.DELETE,
    "del" => Key.DELETE,
    "f1" => Key.F1,
    "f2" => Key.F2,
    "f3" => Key.F3,
    "f4" => Key.F4,
    "f5" => Key.F5,
    "f6" => Key.F6,
    "f7" => Key.F7,
    "f8" => Key.F8,
    "f9" => Key.F9,
    "f10" => Key.F10,
    "f11" => Key.F11,
    "f12" => Key.F12,
)

"""
The `Modifier.T` a name denotes, or `nothing`. Case-insensitive. The
four canonical names only -- an unknown name is garbage, not a key.
Pure.
"""
function _parse_modifier(name::AbstractString)::Union{Nothing,Modifier.T}
    n = lowercase(name)
    n == "shift" && return Modifier.SHIFT
    n == "alt" && return Modifier.ALT
    n == "ctrl" && return Modifier.CTRL
    n == "super" && return Modifier.SUPER
    return nothing
end

"""
Split a key description into its modifier names and its key name, or
`nothing` when the shape is garbage.

`+` is both the separator and a legitimate key, so a trailing `+` is the
key itself: `"+"` is plus, `"ctrl++"` is ctrl plus. `"ctrl+"` is
ambiguous and is therefore rejected rather than guessed at. Pure.
"""
function _split_key_spec(
    s::AbstractString,
)::Union{Nothing,Tuple{Vector{String},String}}
    str = String(s)
    str == "+" && return (String[], "+")
    if endswith(str, '+')
        head = chop(str)                 # drop the literal '+' key
        endswith(head, '+') || return nothing
        mod_str = chop(head)             # drop the separator '+'
        isempty(mod_str) && return nothing
        parts = split(mod_str, '+')
        any(isempty, parts) && return nothing
        return (String.(parts), "+")
    end
    parts = split(str, '+')
    any(isempty, parts) && return nothing
    return (String.(parts[1:(end - 1)]), String(parts[end]))
end

"""
The `(code, char)` a key name denotes, or `nothing`. A one-character
name is a literal character; anything longer must be in `_KEY_NAMES`.
Pure.
"""
function _parse_key_name(
    name::AbstractString,
)::Union{Nothing,Tuple{Key.T,Char}}
    length(name) == 1 && return (Key.CHAR, first(name))
    k = get(_KEY_NAMES, lowercase(name), nothing)
    k === nothing && return nothing
    return (k, '\0')
end

"""
Parse a key description.

Accepts `"q"`, `"ctrl+c"`, `"shift+tab"`, `"f1"`, `"alt+enter"`,
`"ctrl+shift+left"`, `"escape"`, `"space"`. Case-insensitive on names.
Throws `ArgumentError` on garbage. This is what makes every binding and
every `press!` test a one-liner.
"""
function Base.parse(::Type{KeyEvent}, s::AbstractString)::KeyEvent
    e = tryparse(KeyEvent, s)
    e === nothing &&
        throw(ArgumentError("invalid key description: $(repr(s))"))
    return e
end

"""
Parse a key description, returning `nothing` instead of throwing. Pure.
"""
function Base.tryparse(::Type{KeyEvent},
                       s::AbstractString)::Union{KeyEvent,Nothing}
    spec = _split_key_spec(s)
    spec === nothing && return nothing
    mod_names, key_name = spec
    mods = MOD_NONE
    for name in mod_names
        m = _parse_modifier(name)
        m === nothing && return nothing
        mods = mods | m
    end
    ck = _parse_key_name(key_name)
    ck === nothing && return nothing
    return KeyEvent(ck[1], ck[2], mods)
end

"""
Where an event is in its propagation. `AT_TARGET` exists because
capture + bubble alone visit the target twice with no way for a handler
to tell the two visits apart.
"""
module Phase
@enum T::UInt8 begin
    CAPTURE = 0
    AT_TARGET = 1
    BUBBLE = 2
end
end

"""
Mutable envelope around an IMMUTABLE event.

Consumption state lives here, so an event can be replayed, logged, or
fed to a second tree without contamination. Parametric on `E` so
handlers dispatch on the concrete event type with no boxing.
"""
mutable struct Dispatch{E<:Event}
    "The event being propagated. Never mutated."
    const event::E
    "The widget the event was routed to."
    const target::Widget
    "The widget currently being visited."
    current::Widget
    "Capture, at-target or bubble."
    phase::Phase.T
    "Set by `consume!`; stops propagation."
    consumed::Bool
end

"""
Envelope `e` for `target`, starting in `Phase.CAPTURE`, unconsumed.

`current` starts at `target` so an envelope that is never walked still
reads consistently; a walk overwrites it before each `on_event!`.
"""
Dispatch(e::E, target::Widget) where {E<:Event} =
    Dispatch{E}(e, target, target, Phase.CAPTURE, false)

"""
Stop propagation. One-way: an event cannot be un-consumed, which is why
a walk need only ever test `is_consumed`, never a phase-specific flag.
"""
function consume!(d::Dispatch)::Nothing
    d.consumed = true
    return nothing
end

"""
True once `consume!` has been called. Pure.
"""
is_consumed(d::Dispatch)::Bool = d.consumed

"""
The wrapped event. Type-stable accessor. Pure.
"""
event(d::Dispatch{E}) where {E} = d.event

"""
The event position relative to `region(d.current)`, as 1-based
widget-local coordinates. Defined only for `Dispatch{MouseEvent}`.

Relative to `current`, NOT to `target`: a capture-phase handler on an
ancestor gets the point in ITS own box. Out-of-box points are returned
as-is, never clamped -- the caller decides what a miss means. Pure.
"""
function local_offset(d::Dispatch{MouseEvent})::Offset
    r = region(d.current)
    e = d.event
    return Offset(e.x - r.x + 1, e.y - r.y + 1)
end

"""
E3. THE handler hook, with a default no-op fallback. Users add methods
on (their widget type, their event type):

    on_event!(b::MyButton, d::Dispatch{KeyEvent}) = ...

Dispatch on both axes -- no callback registry, no
`Dict{Symbol,Function}`, no closures. Call `consume!(d)` to stop
propagation.
"""
on_event!(w::Widget, d::Dispatch)::Nothing = nothing
