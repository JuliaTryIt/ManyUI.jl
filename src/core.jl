# core.jl -- The Declarative Core Model

"""
A projection represents a specific target channel for the application UI.
"""
abstract type Projection end

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
