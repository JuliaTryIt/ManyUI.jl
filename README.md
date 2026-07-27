# ManyUI.jl

**ManyUI** is a unified, declarative User Interface framework for Julia. 

Its philosophy is simple: **write your domain model and UI presentation once, and render it anywhere.** 
Instead of tightly coupling your code to a single platform, `ManyUI` uses a hierarchical widget tree and an event-driven architecture that can be projected onto multiple backends seamlessly.

## The `ManyUI` Ecosystem

This repository is the core engine of the framework. It defines the fundamental widget primitives (`Container`, `Label`, `Button`, etc.), the reactive model, and the rendering pipeline.

The ecosystem is extended by companion packages that provide different rendering projections:

1. **Terminal UI (TUI)** (Built-in)
   Render your application directly in the terminal with full interactivity, utilizing an optimized diffing renderer that emits minimal ANSI escape sequences.
2. **WebTerminal (`ManyUIWeb.jl`)**
   Serve your TUI application over the web. The terminal is emulated in the browser via WebSockets, allowing remote access with zero changes to your code.
3. **WebNative (`ManyUIWeb.jl`)**
   Translate the exact same `ManyUI.Widget` tree into native HTML and DOM elements (`<div>`, `<button>`, `<span>`). This provides a true, semantic web experience with vanilla CSS styling, fully driven by the Julia backend.
4. **CLI (`ManyUICLI.jl`)**
   Automatically generate a Command-Line Interface from your declarative UI model using `Comonicon.jl`. Expose your domain actions as flags and subcommands instantly.

## Quickstart

```julia
using ManyUI

# 1. Define your Domain Model
mutable struct CounterModel
    clicks::Int
end

struct Increment <: Action end

# 2. Define your Domain Logic
function ManyUI.execute!(model::CounterModel, ::Increment)
    model.clicks += 1
end

# 3. Define your UI Projection
function ManyUI.render(model::CounterModel, proj::ManyUI.Projection)
    Container(
        Label("Count: $(model.clicks)"),
        Button("Click me", _ -> ManyUI.execute!(model, Increment()))
    )
end

# 4. Launch!
model = CounterModel(0)

# Launch in Terminal
ManyUI.launch(model, TUI())

# Launch as a Native Web App (requires ManyUIWeb)
# ManyUI.launch(model, WebNative(); port=8080)
```

## Architecture & Layout

| Path | Responsibility |
|---|---|
| `src/core.jl` | Core primitives: `Action`, `Widget`, `Projection` and the `execute!` / `render` / `launch` interfaces |
| `src/widgets/` | Standard widgets (`Container`, `Label`, `Button`, `TextInput`, etc.) |
| `src/events.jl` | Event definitions (`Click`, `KeyPress`, etc.) and the dispatch mechanism |
| `src/style.jl` | Declarative CSS-like styling constraints and layout engine |
| `src/terminal/` | The ANSI backend, terminal raw mode, diffing engine, and input parsing |
| `src/reactive.jl` | Reactive state primitives for the TUI event loop |

## Testing

```julia
julia --project=ManyUI -e 'using Pkg; Pkg.test()'
```

Tests are written using `@testitem` and run via [TestItemRunner.jl](https://github.com/julia-vscode/TestItemRunner.jl).
The core logic and rendering pipeline are thoroughly tested in a headless environment.
