# core.jl -- The Declarative Core Model

"""
A projection represents a specific target channel for the application UI.
"""
abstract type Projection end

"""Whether a backend or projection can be used in the current process."""
function backend_available end

"""Stable backend identifier, suitable for UI selectors and logs."""
function backend_kind end

"""Capabilities advertised by a backend.

The tuple is intentionally semantic rather than library-specific. Backends
may add fields in their own metadata, but these common fields are stable:
`mouse`, `keyboard`, `text_input`, `focus`, `resize`, `transparency`,
`animations`, `native_window`, `gpu` and `multi_session`.
"""
function backend_capabilities end

const DEFAULT_BACKEND_CAPABILITIES = (
    mouse = true, keyboard = true, text_input = true, focus = true,
    resize = true, transparency = false, animations = true,
    native_window = false, gpu = false, multi_session = false,
)

backend_available(::Projection) = true
backend_kind(p::Projection) = Symbol(nameof(typeof(p)))
backend_capabilities(::Projection) = DEFAULT_BACKEND_CAPABILITIES

"""
Command-Line Interface projection.
"""
struct CLI <: Projection end

"""
Terminal User Interface projection.
"""
struct TUI <: Projection end

"""
Web Terminal Emulation projection (e.g., using xterm.js over WebSockets).
"""
struct WebTerminal <: Projection end

"""
Native Web projection (e.g., HTML/DOM/CSS).
"""
struct WebNative <: Projection end

"""
An Action represents a discrete user intent or domain operation.
"""
abstract type Action end

"""
    execute!(app, action::Action)

Domain logic entry point. Applications should implement this method for each
of their specific `Action` subtypes to mutate the application model.
"""
function execute! end

"""
    render(app, projection::Projection)

Presentation entry point. Applications should implement this method to 
project their current model state onto the targeted channel.
"""
function render end

render(f::Function, ::Projection) = f()

"""
    post!(app, event)

Schedule an event to be processed by the application loop.
"""
function post! end

"""
    focus!(app, widget)

Focus the specified widget.
"""
function focus! end

"""
    popup_of(app)

Get the current popup of the application.
"""
function popup_of end

"""
    open_popup!(app, popup)

Open a popup in the application.
"""
function open_popup! end

"""
    close_popup!(app, widget)

Close the popup if it belongs to the given widget.
"""
function close_popup! end

"""
    on_popup_close!(widget)

Callback invoked when a widget's popup is closed.
"""
function on_popup_close! end
