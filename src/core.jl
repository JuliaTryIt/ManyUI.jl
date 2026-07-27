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
