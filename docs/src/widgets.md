# Widgets

```@meta
CurrentModule = ManyUI
```

ManyUI ships a small library of built-in widgets. They are ordinary
widgets with no privileged access: anything they do, your own widget
types can do too.

## Label

Wrapping text. It measures and paints through `wrap_width` and
`write_text!`, never through `Base.textwidth`, so a wide grapheme that
would straddle the right edge moves to the next line rather than being
cut in half.

```@example widgets
using ManyUI

l = Label("Hello, ManyUI!")
measure(l, Size(40, 4))
```

Its text is reactive: assigning to it marks the label dirty for layout,
because new text wraps differently and can move its siblings.

```@example widgets
l.text[] = "Some considerably longer text that will wrap"
measure(l, Size(20, 4))
```

## Container

A box that holds children, optionally with a border and a title. It is
the workhorse of layout — give it a `layout:` and a `gap:` and it
arranges whatever you put in it.

```@example widgets
ui = Container(Label("first"), Label("second"))
layout!(ui, Region(1, 1, 20, 6))
length(children(ui))
```

## Button

A focusable, clickable widget that calls its callback when pressed —
whether by mouse, routed through hit testing, or by ENTER when it holds
focus.

Wiring one to a `Label` gives a counter, and shows the reactive loop
end to end: the callback writes the label's text, the write marks it
dirty, and the next frame repaints it.

```@example widgets
clicks = Ref(0)
readout = Label("Count: 0"; id = :count)

b = Button("Click me", _ -> begin
               clicks[] += 1
               readout.text[] = "Count: $(clicks[])"
               nothing
           end; id = :go)

root = Container(readout, b)
layout!(root, Region(1, 1, 20, 4))

r = region(b)
for _ in 1:3
    dispatch_event!(root, MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                                     r.x, r.y, MOD_NONE))
end

(clicks = clicks[], text = readout.text[])
```

A button also fires on ENTER when it holds focus, so the same counter
works without a mouse:

```@example widgets
dispatch_event!(root, parse(KeyEvent, "enter"), b)
readout.text[]
```

`is_focusable(b)` is true, so it takes part in the tab order:

```@example widgets
is_focusable(b)
```

## Scrollpane

A window over exactly one child, for content bigger than the room you
have. Wrap several children in a `Container`, as CSS makes you.

The offset lives on the tree, not in the pane — so a wheel tick marks
`Dirty.PAINT` and layout never runs. `viewport(pane)` is the node that
scrolls, and it is what the scrolling API takes:

```@example widgets
lines = Container([Static("line $i") for i in 1:8]...)
pane = Scrollpane(lines)
apply_stylesheet!(STYLESHEET_EMPTY, pane)
layout!(pane, Region(1, 1, 9, 3))

vp = viewport(pane)
(window = layout_of(vp).content.height, content = content_extent(vp).height)
```

Eight rows of content in a three-row window, so five rows can scroll
past. `scroll_to!` clamps and returns what it actually stored:

```@example widgets
(max = max_scroll(vp), stored = scroll_to!(vp, Offset(0, 99)))
```

The wheel, the arrows, `pageup`/`pagedown` and `home`/`end` all work,
and a pane at its limit does not consume the event — so it bubbles to
the pane outside it and scroll chaining costs no code at all.
[Scrolling](scrolling.md) covers the whole story.

## Scrollbar

The visible indicator for one axis. It is a sibling of what it reports
on, never a child, so it never scrolls with the content — and it is
parametric on its viewport, so one `Scrollbar` serves a `Container`, a
`Scrollpane`'s canvas or a `TextArea` alike. It reads three functions
and touches nothing else.

`Scrollpane` builds its own, but the geometry is a pure function you can
check on its own — `(start, len)` on the track, for a window over some
content at an offset:

```@example widgets
thumb_span(3, 3, 8, 0)
```

## TextInput

Single-line entry, with a caret, a placeholder and a submit handler. It
takes the width it is offered and scrolls horizontally rather than
resizing, so a keystroke costs zero layout.

```@example widgets
field = TextInput("hi", i -> nothing; placeholder = "name?")
insert_text!(field, "!")
(text = field.text[], cursor = field.cursor[])
```

The cursor is a 0-based count of **grapheme clusters**, so it steps over
a wide emoji in one move and never lands inside one.

## TextArea

Multi-line entry over a `Vector{String}`. It scrolls by indexing its
lines, so painting is O(window) and a huge document costs the same frame
as a small one.

```@example widgets
notes = TextArea("alpha\nbeta")
insert_newline!(notes)
(text = text(notes), extent = content_extent(notes))
```

It overrides `content_extent`, which is the whole of its integration
with `Scrollbar`. [Text entry](textentry.md) covers both widgets, and
the grapheme rules they are built on.

## MinSizeOverlay

The "Increase Terminal Size" screen. When the rendering area drops
below the root's minimum, the App suspends normal rendering and paints
this instead — no layout of your tree runs at all until there is room
for it again.

```@example widgets
should_suspend(Size(12, 3), Size(20, 5))
```

```@example widgets
should_suspend(Size(80, 24), Size(20, 5))
```

You rarely construct it yourself; `AppConfig(; min_size = ...)` decides
when it appears.

```@example widgets
AppConfig().min_size
```

Below a certain size even the overlay cannot be laid out, so a
tree-free painter takes over. The framework never crashes because the
window got small.

## List, Table and DataTable

The data widgets, covered in full on the [Data widgets](@ref) page.
`List` shows items, `Table` shows columns, `DataTable` also sorts.

```@example widgets
l = List(["alpha", "beta", "gamma"])
(rows = row_count(l), nodes = length(descendants(l)))
```

`nodes` is zero, and stays zero at a hundred thousand items: unlike
every other widget here, their rows are **data rather than widgets**, so
a frame costs the same however much data you hand them.

## Writing your own

A widget is a mutable struct holding a `WidgetNode`, plus whatever
state it needs:

```@example custom
using ManyUI

mutable struct Spinner <: ManyUI.Widget
    node::WidgetNode
    frame::Int
end
Spinner() = Spinner(WidgetNode(; type_name = :Spinner), 1)

const FRAMES = ('|', '/', '-', '\\')

ManyUI.measure(w::Spinner, avail::Size) = Size(1, 1)

function ManyUI.render!(w::Spinner, buf::AbstractMatrix{Cell})
    write_text!(buf, 1, 1, string(FRAMES[w.frame]), STYLE_NONE)
    nothing
end

s = Spinner()
measure(s, Size(10, 10))
```

Two methods make it real: `measure`, which reports how much room it
wants, and `render!`, which paints into the content box it was granted.
The buffer's `(1, 1)` is the content origin, and its size is the
content box — so a widget cannot paint outside its own region, and
`type_name` makes it addressable from CSS as `Spinner { ... }`.
