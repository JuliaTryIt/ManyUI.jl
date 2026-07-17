# DualUI.jl

```@meta
CurrentModule = DualUI
```

A user interface framework for Julia that targets the terminal *and*
the web browser, without rewriting the application or the interface.

Inspired by Python's [Textual](https://textual.textualize.io/), DualUI
does not compile your interface into HTML. It applies web development
paradigms — a virtual DOM, a CSS-like box model, an asynchronous
reactive event loop — directly onto a 2D character grid. The output is
a stream of ANSI escape sequences.

Targeting the browser does not change the nature of the application. It
only offloads the final step, drawing those ANSI bytes, to a terminal
emulator running in the browser. That is what `DualUIWeb` does, and it
is why this package has no HTTP dependency:

```@docs
DualUI
```

## Installation

```julia
using Pkg
Pkg.develop(path = "path/to/DualUI")
```

To also serve your application in a browser, add `DualUIWeb`. It
depends on `DualUI`, so a pure terminal application never pays for
`HTTP.jl` or WebSocket handling.

## Quickstart

A counter: a label, a button, and a click that updates what the label
says.

```@example quickstart
using DualUI

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
# `DualUIWeb.serve` to draw it in a browser.
driver = HeadlessDriver(Size(40, 8))
app = App(ui, driver)

DualUI.start!(driver, Size(40, 8))
handle!(app, ResizeEvent(Size(40, 8)))
frame!(app)

nothing # hide
```

Assigning to `readout.text` is the whole update. `Label.text` is
reactive, so writing it marks the label dirty and the next frame
repaints it — nothing calls a render function by hand.

Widgets are addressable by their CSS id, and a click routed through hit
testing reaches the right one:

```@example quickstart
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

```@example quickstart
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
using DualUI

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
