# Scrolling

```@meta
CurrentModule = ManyUI
```

Scrolling in ManyUI is not a widget. Every `WidgetNode` carries a
`scroll::Offset`, and `paint!` accumulates it down the tree and applies
it to that node's **children**. `compute_layout` never reads the field.

That single fact is the whole design: the `LayoutMap` is *invariant*
under scrolling, so a wheel tick is a repaint and never a relayout. A
`Scrollpane` is policy over a compositor that already knows how to shift
an origin — where the offset may go, who moves it, and what the
indicator looks like.

## Scrollpane

A `Scrollpane` is a window over exactly **one** child. Mount several by
wrapping them in a `Container`, exactly as CSS makes you.

Here is a twelve-line document in an eight-row window, painted through a
`HeadlessDriver` — no tty, no terminal, the full pipeline:

```@example scrolling
using ManyUI

log = Container([Static("line $i"; id = Symbol("line$i")) for i in 1:12]...)
pane = Scrollpane(log; id = :log)

driver = HeadlessDriver(Size(24, 8))
app = App(pane, driver)
frame!(app)                # cascade, layout, paint, diff, emit
app.back                   # the frame just painted
```

Four lines never fit, and the bar on the right says so: a five-cell
thumb on an eight-cell track is `8 / 12` of the document, drawn to
scale.

`viewport(pane)` is the node that actually scrolls — the pane's internal
canvas. It is what `scroll_to!`, `max_scroll` and `content_extent` take:

```@example scrolling
vp = viewport(pane)
(window = layout_of(vp).content,      # what you can see
 content = content_extent(vp),        # what there is
 max = max_scroll(vp))                # how far it can go
```

The window and the content extent are two different numbers, and a pane
can scroll exactly when they differ. `content_extent` is the bounding
box of the laid-out children's margin boxes, read straight from the
`LayoutMap` the engine already computed — no re-measure, no relayout.

## A wheel tick is a repaint, not a relayout

Feed the app a wheel event and watch what it dirties:

```@example scrolling
before = layout_of(vp)

handle!(app, MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_DOWN,
                        1, 1, MOD_NONE))

(scroll = scroll_of(vp),
 paint = is_dirty(vp, Dirty.PAINT),
 layout = is_dirty(vp, Dirty.LAYOUT),
 relayout_root = dirty_root(pane),   # nothing: relayout! returns at once
 boxes_moved = layout_of(vp) !== before)
```

`Dirty.PAINT` and nothing else. `dirty_root` finds no real layout work,
so `relayout!` returns on its first line and every box in the tree keeps
the value it had. The next frame simply paints the same boxes at a
different origin:

```@example scrolling
frame!(app)
app.back
```

Three rows moved up, the thumb moved down, and the diff sent only the
cells that changed. This matters more than it looks: a `Container` is
auto-sized, so a layout mark would promote all the way to the root — a
full-tree relayout per wheel notch.

Layout and paint disagree about where a scrolled widget is, and that is
deliberate: `region(w)` is where layout put it, `painted_region(w)` is
where it ended up.

```@example scrolling
sixth = children(log)[6]
(laid_out = region(sixth),
 painted = painted_region(sixth),
 shift = paint_offset(sixth))
```

`hit_test` compares the pointer against `painted_region`, so a click
lands on what the user can actually see rather than on whatever occupies
that widget's unscrolled slot.

```@example scrolling
ManyUI.id(hit_test(pane, 1, 1))
```

## Wheel and keyboard

`Scrollpane` handles `MouseEvent` and `KeyEvent`:

| Input | Effect |
|:--|:--|
| wheel up/down | `wheel_step` cells vertically (default 3) |
| wheel left/right, or `shift`+wheel | `wheel_step_x` cells (default 6) |
| `up` / `down` / `left` / `right` | `wheel_step` cells |
| `pageup` / `pagedown` | one window less one row, so a landmark stays |
| `home` / `end` | the extremes of the vertical axis |

Each of those returns whether the event was consumed:

```@example scrolling
scroll_to!(vp, ORIGIN)

(down = dispatch_event!(pane, parse(KeyEvent, "down")),
 to_the_end = dispatch_event!(pane, parse(KeyEvent, "end")),
 end_again = dispatch_event!(pane, parse(KeyEvent, "end")),
 scroll = scroll_of(vp))
```

The second `end` returns `false`: the pane was already at its limit, so
it did not move and **did not consume** the event. That rule is the
whole of scroll chaining — a pane at its end lets the notch bubble to
the next pane out, and no pane needs to know another exists.

Keys are handled on the way up and only when unmodified, so a focused
`TextInput` consuming `left`/`right` at target takes precedence with no
special-casing anywhere, and `ctrl+a` still reaches your own bindings.

## Clamping

Clamping is split across two layers, on purpose.

`set_scroll!` is the core mutator. It clamps at **zero** per axis and
nothing more — it cannot see the content extent from where it lives:

```@example scrolling
(changed = set_scroll!(vp, Offset(0, -5)), stored = scroll_of(vp))
```

`scroll_to!` owns the upper bound, because it can ask `content_extent`.
It clamps to `0:max_scroll(w)` and returns the offset **actually
stored**:

```@example scrolling
(asked_for = Offset(0, 999), stored = scroll_to!(vp, Offset(0, 999)))
```

Returning the stored offset is what lets a caller detect "this pane is
at its limit" with `scroll_to!(w, o) === before`. `scroll_by!` is the
same thing relative to the current offset.

Both are built from two pure functions you can call yourself, and which
every scrolling widget shares so they cannot disagree:

```@example scrolling
(clamped = clamp_scroll(99, 4, 12),        # window 4, content 12
 minimal = scroll_into_view(0, 4, 7, 7))   # show row 7 in a 4-row window
```

`clamp_scroll` is the definition of "in range". `scroll_into_view` moves
the **minimum** needed: content already visible does not move at all,
and an item taller than the window shows its top rather than its bottom.

## Scrolling something into view

`scroll_into_view!(vp, w)` scrolls `vp` the minimum needed to bring a
descendant's margin box inside its content box. It reads unshifted
layout geometry, so it is correct whatever the current offset is, and
idempotent.

You rarely call it. `on_focus!` defaults to `reveal!(w)`, which asks
every ancestor — nearest first — to reveal `w` through the
`reveal_child!` hook, and `Scrollpane` implements that hook. So tabbing
to a widget buried in nested panes scrolls it into view with no wiring
at the call site and no `isa Scrollpane` anywhere in the core:

```@example scrolling
buttons = Container([Button("B$i", b -> nothing) for i in 1:8]...)
p2 = Scrollpane(buttons; bar_y = ScrollMode.NEVER)
apply_stylesheet!(STYLESHEET_EMPTY, p2)
layout!(p2, Region(1, 1, 9, 3))

on_focus!(children(buttons)[8])          # what TAB does
scroll_of(viewport(p2))
```

Nearest-first is load-bearing: an inner pane must finish moving before
an outer pane can measure where the widget ended up. If your widget
overrides `on_focus!`, it must call `reveal!(w)` itself — overriding
replaces the default. `TextInput` and `TextArea` are the worked
examples.

## The Scrollbar

A `Scrollbar` is an ordinary widget, parametric on the thing it reports
on, and a **sibling** of the canvas rather than a child of it — so it is
never inside a scrolled subtree and never shifts with the content.

It knows nothing about `Scrollpane`. It reads three functions and
nothing else:

```
content_extent(w)::Size      -- how big the content is
layout_of(w).content::Region -- how big the window is
scroll_of(w)::Offset         -- where the window currently is
```

That seam is three functions rather than a supertype, which is exactly
why one `Scrollbar` serves a bare `Container`, a `Scrollpane`'s canvas
and a `TextArea` — whose content is a `Vector{String}` and not children
at all.

The geometry is a pure function of four integers, so you can check it
without a widget, a layout or a buffer:

```@example scrolling
[thumb_span(8, 8, 12, off) for off in 0:4]   # track, window, content
```

`(start, len)`, 1-based within the track. Two rules are normative: the
thumb is **never** zero cells long — an invisible thumb is a broken
scrollbar, and a one-cell thumb on a forty-cell track is the honest
rendering of a forty-screen document — and the two ends are exact. At
offset `0` the thumb starts at cell 1; at the maximum offset it ends on
the last cell of the track. Those are the only two positions a user can
verify at a glance, so the arithmetic is written around them.

`ScrollMode` decides when the bar is drawn:

| Mode | Gutter | Ink |
|:--|:--|:--|
| `ScrollMode.NEVER` | none | none — the wheel and keys still scroll |
| `ScrollMode.AUTO` | always reserved | only when there is something to scroll |
| `ScrollMode.ALWAYS` | always reserved | always, full-length when it all fits |

`AUTO` reserves the gutter **unconditionally** and toggles only the ink.
This is CSS's `scrollbar-gutter: stable`, not `overflow: auto`, and the
reason is oscillation: removing the gutter rewraps the content, which
may then no longer overflow, which brings the gutter back. The price is
one wasted column on a pane that does not overflow. Take it.

## `overflow: scroll` on any node

`overflow` is a `BoxStyle` field on every node and `css.jl` already
parses it, so a design where the property silently did nothing unless
the widget happened to be a `Scrollpane` would make the stylesheet lie.
Any node can carry an offset — it is CSS's `scrollTop` and `scrollLeft`:

```@example overflow
using ManyUI

sheet = css"""
#box { overflow: scroll; }
#doc { shrink: 0; }
"""

doc = Container([Static("row $i") for i in 1:5]...; id = :doc)
box = Container(doc; id = :box)
apply_stylesheet!(sheet, box)
layout!(box, Region(1, 1, 6, 2))

(window = layout_of(box).content,
 content = content_extent(box),
 max = max_scroll(box))
```

```@example overflow
scroll_to!(box, Offset(0, 2))
buf = Buffer(6, 2)
clear!(buf)
paint!(buf, box)
buf
```

`shrink: 0` on the document is not decoration and it is the trap worth
knowing about: the default `shrink` is `1`, so the flex kernel absorbs
the overflow and squeezes a five-row document into a two-row window —
after which there is nothing left to scroll. `Scrollpane` sets it for
you on an internal holder node, which is why it works out of the box.

`Overflow` and `ScrollMode` are deliberately different axes of choice.
`Overflow` is a clipping policy owned by the box model — `HIDDEN` and
`SCROLL` both clamp the child clip to the content box, `VISIBLE` lets a
child spill. `ScrollMode` is a scrollbar visibility policy owned by the
widget. Neither implies the other: `ScrollMode.NEVER` still scrolls.

## Writing a scrolling widget

Store the offset in `node(w).scroll` through `set_scroll!` or
`scroll_to!`, and nothing else writes the field.

A node's scroll shifts its **children** and never its own render frame.
That is what keeps `size(buf)` inside `render!` equal to the widget's
real content box, invariant under scroll — so a scrolled `Label` does
not rewrap and a scrolled `Button` does not re-centre. A widget with no
children that scrolls its own content reads `scroll_of(w)` in its own
`render!` and slices explicitly; `TextArea` does exactly that, which is
also how it stays O(window) instead of O(document).

Override `content_extent` when your content is data rather than
children, and a `Scrollbar` will report on it with no further code.

When a genuinely clipped node paints, `paint!` hands `render!` a
`ScrolledView` rather than a `BufferView`: a window whose local origin
and writable clip are independent, where the clip is the only authority
and the frame is only a coordinate system. Writes outside the clip are
silently dropped and reads return `CELL_BLANK`, so a widget cannot paint
outside its box even if it tries — and a wide grapheme that would
straddle a clip edge is dropped whole rather than halved, at the left
edge as well as the right.
