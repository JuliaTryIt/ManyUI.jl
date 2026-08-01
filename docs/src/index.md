# ManyUI.jl

```@meta
CurrentModule = ManyUI
```

**ManyUI** is a unified, declarative User Interface framework for Julia. 

Its philosophy is simple: **write your domain model and UI presentation once, and render it anywhere.** 
Instead of tightly coupling your code to a single platform, `ManyUI` uses a hierarchical widget tree and an event-driven architecture that can be projected onto multiple backends seamlessly.

The ecosystem is extended by companion packages that provide different rendering projections:

1. **[ManyUI.jl](https://github.com/s-celles/ManyUI.jl) (Core)**
   The pure domain model and reactive widget tree. Completely platform-agnostic, with zero rendering dependencies.
2. **[ManyUITUI.jl](https://github.com/s-celles/ManyUITUI.jl) (Terminal Backend)**
   Render your application directly in the terminal with full interactivity, utilizing an optimized diffing renderer that emits minimal ANSI escape sequences.
3. **[ManyUIWeb.jl](https://github.com/s-celles/ManyUIWeb.jl)**
   - *WebTerminal*: Serve your TUI application over the web. The terminal is emulated in the browser via WebSockets.
   - *WebNative*: Translate the exact same widget tree into native HTML and DOM elements for a true semantic web experience.
4. **[ManyUICLI.jl](https://github.com/s-celles/ManyUICLI.jl)**
   Automatically generate a Command-Line Interface from your declarative UI model using `Comonicon.jl`.
5. **[ManyUIDemos.jl](https://github.com/s-celles/ManyUIDemos.jl)**
   A centralized demonstration hub showcasing how to write a domain model once and launch it across all `ManyUI` projections.

```@docs
ManyUI
```

## Installation

```julia
using Pkg
Pkg.develop(path = "path/to/ManyUI")
```

To also serve your application in a browser, add `ManyUIWeb`. It
depends on `ManyUI`, so a pure terminal application never pays for
`HTTP.jl` or WebSocket handling.

## Quickstart

A counter: a label, a button, and a click that updates what the label
says.

```julia
using ManyUI

clicks = Ref(0)
readout = Label("Count: 0"; id = :count)

ui = Container(
    readout,
    Button("Click me", _ -> begin
               clicks[] += 1
               readout.text[] = "Count: $(clicks[])"
               nothing
           end; id = :go),
)

# `HeadlessDriver` renders into memory instead of a terminal, which is
# what makes the examples on this page runnable. Swap it for
# `TerminalDriver()` to draw on a real tty, or hand the same tree to
# `ManyUIWeb.serve` to draw it in a browser.
driver = HeadlessDriver(Size(40, 8))
app = App(ui, driver)

ManyUI.start!(driver, Size(40, 8))
handle!(app, ResizeEvent(Size(40, 8)))
frame!(app)

nothing # hide
```

Assigning to `readout.text` is the whole update. `Label.text` is
reactive, so writing it marks the label dirty and the next frame
repaints it — nothing calls a render function by hand.

Widgets are addressable by their CSS id, and a click routed through hit
testing reaches the right one:

```julia
button = query_one(ui, "#go")
r = region(button)
clear_output!(driver)   # forget the first frame; watch just this click

dispatch_event!(ui, MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                               r.x, r.y, MOD_NONE))
frame!(app)

(clicks = clicks[], text = readout.text[])
```

Now look at what that click actually cost. `Count: 0` became `Count: 1`,
so exactly one cell changed, and the diff sends exactly one cell:

```julia
String(take_bytes!(driver))
```

`\e[1;8H1` is the entire counter update: move the cursor to row 1,
column 8, and write `1`. The button is redrawn too because clicking
focused it, which genuinely changed how it looks. Nothing else on the
screen is touched.

## Running on a real terminal

`TerminalDriver` puts the host terminal into raw mode and the alternate
screen buffer, so an application never overwrites the user's shell
history, and restores both even if the application throws:

```julia
using ManyUI

app = App(my_ui(), TerminalDriver())
run!(app)   # blocks until quit!(app)
```

## Where to go next

- [Concepts](@ref) — the render pipeline and the driver seam, the idea
  the rest of the framework hangs off.
- [Layout](@ref) — the box model and flex sizing.
- [Styling](@ref) — the CSS-like syntax, selectors and colors.
- [Events](@ref) — capture, bubble and consumption.
- [Widgets](@ref) — the built-in widget library.
