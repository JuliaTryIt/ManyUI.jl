# ManyUI

A terminal-first UI framework for Julia: a hierarchical widget tree, a
CSS-like box model with a flex layout engine, declarative styling, an
asynchronous event loop, and a diffing renderer that emits the minimal
stream of ANSI escape sequences.

ManyUI has **no** web, HTTP or socket dependency, and never will. Its
only extension point is the nine-method `Driver` seam; the companion
package [`ManyUIWeb`](https://github.com/s-celles/ManyUIWeb.jl) plugs a browser into that seam from
the outside without ManyUI knowing the web exists.

## Status

Implemented, with 8625 passing tests. The API is at `0.1.0` and should
be expected to move before `1.0`.

## Quickstart

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

run!(App(ui, TerminalDriver()))   # blocks until quit!
```

`Label.text` is reactive: writing it marks the label dirty, the next
frame repaints it, and the diff sends only the one cell that changed.

Full documentation:

```julia
julia --project=ManyUI/docs ManyUI/docs/make.jl   # then open docs/build/index.html
```

## The render pipeline

```
tree -> cascade -> layout -> Buffer -> diff -> Patch -> ANSI bytes
     -> Driver.emit!
```

A `Driver` never sees a `Buffer`, `Patch`, `Widget`, `Region` or
`LayoutMap` -- only `Vector{UInt8}`, `Size`, `DriverCaps` and `Event`.

## Layout

| Path | Responsibility |
|---|---|
| `src/types.jl` | The four abstract types: `Widget`, `Driver`, `AbstractApp`, `Event` |
| `src/geometry.jl` | `Size`, `Offset`, `Region`, `Spacing` and their algebra |
| `src/unicode.jl` | Grapheme-cluster widths; wide characters occupy two cells |
| `src/color.jl` | `Color`, palettes, and `degrade` (TrueColor to 256/16/mono) |
| `src/style.jl` | `Style` as bits plus a specified-mask; `merge` is the cascade fold |
| `src/events.jl` | Event structs, `Modifiers`, `Dispatch{E}`, `Phase` |
| `src/boxmodel.jl` | `Length`, `Border`, `BoxStyle`, `BoxPatch`, `LayoutBox` |
| `src/buffer.jl` | `Cell`, `Buffer`, `BufferView` and the clipped writers |
| `src/diff.jl` | `Span`, `Patch`, the pure `diff`, `apply!` |
| `src/ansi.jl` | Escape-sequence constants and the stateful `AnsiEncoder` |
| `src/input.jl` | `parse_events`: bytes in, events out; no byte-source type |
| `src/driver.jl` | `DriverCaps` and the nine-method seam |
| `src/widget.jl` | `WidgetNode`, the tree API, dirty flagging |
| `src/reactive.jl` | `Reactive{T}`: a write marks dirty and schedules a frame |
| `src/dispatch.jl` | `hit_test`, capture/at-target/bubble propagation |
| `src/layout.jl` | The pure `compute_layout`, the flex kernel, `layout!` |
| `src/css.jl` | Selectors, `Stylesheet`, the pure `cascade`, `@css_str` |
| `src/paint.jl` | `render!`, `paint!`, `paint_border!` |
| `src/headless.jl` | `HeadlessDriver` -- the proof the seam is right |
| `src/terminal.jl` | `TerminalDriver`: raw mode, alternate screen, restore |
| `src/widgets/` | `Container`, `Label`, `Static`, `Button`, `MinSizeOverlay` |
| `src/widgets/scroll.jl` | `Scrollpane`, `Scrollbar`, and the scrollable seam |
| `src/widgets/textinput.jl` | `TextInput` and the shared grapheme helpers |
| `src/widgets/textarea.jl` | `TextArea`: scrolls by indexing its lines |
| `src/widgets/tablecore.jl` | `Column`, `Selection`: the model List/Table/DataTable share |
| `src/widgets/list.jl` | `List`: rows are data, never widgets |
| `src/widgets/table.jl` | `Table`: columns, and a header that does not scroll away |
| `src/widgets/datatable.jl` | `DataTable`: stable, non-mutating sorting |
| `src/app.jl` | `App{D}`, `run!`, `frame!`, `handle!`, focus, bindings |

## Tests

```julia
julia --project=ManyUI -e 'using Pkg; Pkg.test()'
```

Tests are `@testitem` blocks run by
[TestItemRunner.jl](https://github.com/julia-vscode/TestItemRunner.jl);
each block is self-contained and none requires a TTY.
