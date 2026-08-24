# ManyUI.jl

**ManyUI** is a unified, declarative User Interface framework for Julia. 

Its philosophy is simple: **write your domain model and UI presentation once, and render it anywhere.** 
Instead of tightly coupling your code to a single platform, `ManyUI` uses a hierarchical widget tree and an event-driven architecture that can be projected onto multiple backends seamlessly.

This repository (`ManyUI.jl`) is the core engine of the framework. It defines the fundamental widget primitives (`Container`, `Label`, `Button`, etc.), the reactive model, and the rendering pipeline.

## 📖 Documentation

The complete documentation for the ManyUI ecosystem, including tutorials, API references, and architecture overviews, is hosted centrally:

👉 **[Read the Documentation (ManyUIDoc)](https://juliatryit.github.io/ManyUIDoc.jl/)**

## Installation

```julia
import Pkg; Pkg.add("ManyUI")
```

For full terminal rendering, you will also want to install the `ManyUITUI` backend.

Centered modal content can use the popup layer without layout-specific
positioning:

```julia
open_popup!(app, Popup(dialog, owner, Size(40, 12);
    placement=PopupPlacement.CENTER))
```

## The Ecosystem

The ManyUI framework is divided into several composable packages:
- **[ManyUI.jl](https://github.com/s-celles/ManyUI.jl)** (Core framework)
- **[ManyUITUI.jl](https://github.com/s-celles/ManyUITUI.jl)** (Terminal TUI backend)
- **[ManyUIWeb.jl](https://github.com/s-celles/ManyUIWeb.jl)** (Web backend)
- **[ManyUICImGui.jl](https://github.com/s-celles/ManyUICImGui.jl)** (Dear ImGui desktop backend, in development)
- **[ManyUICLI.jl](https://github.com/s-celles/ManyUICLI.jl)** (Command-line generator)
- **[ManyUIDemos.jl](https://github.com/s-celles/ManyUIDemos.jl)** (Showcase and examples)

## Testing

Tests are written using `@testitem` and run via [TestItemRunner.jl](https://github.com/julia-vscode/TestItemRunner.jl).

```julia
julia --project=ManyUI -e 'using Pkg; Pkg.test()'
```
