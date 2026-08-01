# Layout

```@meta
CurrentModule = ManyUI
```

The layout engine resolves a widget tree into an absolute `Region` for
every node, using a box model deliberately close to CSS.

## The box model

Every widget has four nested boxes, derived from its outer margin box:

```
┌─ margin ──────────────────────────┐
│  ┌─ border ─────────────────────┐ │
│  │  ┌─ padding ───────────────┐ │ │
│  │  │  ┌─ content ─────────┐  │ │ │
│  │  │  │  the widget draws │  │ │ │
│  │  │  └───────────────────┘  │ │ │
│  │  └─────────────────────────┘ │ │
│  └──────────────────────────────┘ │
└───────────────────────────────────┘
```

`layout_box` is the single definition of that derivation; no other part
of the framework re-derives it. `region(w)` returns the border box,
and `content_region(w)` the content box a widget may actually paint
into.

Margins, padding and borders are measured in cells:

```julia
using ManyUI

outer = Region(1, 1, 20, 6)
style = BoxStyle(; margin = Spacing(1), padding = Spacing(2),
                 border = Border(BorderKind.ROUND, STYLE_NONE))
lb = layout_box(style, outer)

(margin = lb.margin_box, border = lb.border_box,
 padding = lb.padding_box, content = lb.content)
```

Each ring shrinks the next: one cell of margin, one of border, then two
of padding, taking a 20×6 outer box down to a 12×0 content box. Ask for
more chrome than you have room for and the content box empties rather
than going negative.

## Sizing

A `Length` resolves in one of four ways:

| Constructor | Meaning |
|:--|:--|
| `AUTO` | size to content |
| `cells(n)` | exactly `n` cells |
| `pct(n)` | `n`% of the parent's content box |
| `fr(n)` | weight `n` of the *remaining* free space |

`fr` is the flex unit. After fixed and percentage children are placed,
whatever is left is split between the `fr` children in proportion to
their weights.

```julia
using ManyUI
(cells(10), pct(50), fr(1), AUTO)
```

## Flex containers

A container with `display = Display.FLEX` lays its children out along
`direction`, distributing space with `justify` and aligning them across
the axis with `align`:

```julia
(direction = instances(Direction.T),
 justify = instances(Justify.T),
 align = instances(Align.T))
```

`layout!` computes the whole tree against a viewport:

```julia
using ManyUI

root = Container(Label("first"; id = :a), Label("second"; id = :b);
                 id = :root)
layout!(root, Region(1, 1, 20, 6))

(root = region(root),
 a = region(query_one(root, "#a")),
 b = region(query_one(root, "#b")))
```

## Resize

When the terminal changes size, the entire tree's bounding boxes are
recomputed against the new viewport. A `ResizeEvent` from any source —
a `SIGWINCH` on a tty, a browser window resize reported over the
WebSocket — funnels through the same path:

```julia
using ManyUI

driver = HeadlessDriver(Size(20, 5))
app = App(Container(Label("x")), driver)
handle!(app, ResizeEvent(Size(60, 20)))
buffer_size(app.back)
```

## Pure and mutating forms

`compute_layout` is pure: it returns a `LayoutMap` from widget to box
and touches nothing. `apply_layout!` writes such a map into the tree,
and `layout!` is the two composed. `relayout!` is the incremental form
the frame loop actually uses — it recomputes only the dirty subtree,
anchored at its existing margin box.
