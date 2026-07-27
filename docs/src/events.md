# Events

```@meta
CurrentModule = ManyUI
```

Input propagates through the widget tree in two phases, exactly as it
does in a browser: down from the root to the target (capture), then
back up (bubble), stopping the moment something consumes it.

## Handling an event

Handlers are methods on `on_event!`, dispatched on both the widget type
and the event type. There is no callback registry and no closures:

```julia
ManyUI.on_event!(w::MyButton, d::Dispatch{KeyEvent}) = begin
    if d.event.code === Key.ENTER
        activate!(w)
        consume!(d)      # stop here; nobody above sees this key
    end
    nothing
end
```

The default `on_event!` is a no-op, so a widget only implements the
events it cares about.

## Capture, target, bubble

`propagate!` walks the path from the root to the target and back:

```@example events
using ManyUI

mutable struct Trace <: ManyUI.Widget
    node::WidgetNode
    log::Vector{Tuple{Symbol,Phase.T}}
end
Trace(name::Symbol, log) = Trace(WidgetNode(; id = name), log)

function ManyUI.on_event!(w::Trace, d::Dispatch{KeyEvent})
    push!(w.log, (ManyUI.id(w), d.phase))
    nothing
end

log = Tuple{Symbol,Phase.T}[]
root, mid, leaf = Trace(:root, log), Trace(:mid, log), Trace(:leaf, log)
mount!(root, mid)
mount!(mid, leaf)

propagate!(root, leaf, key('a'))
log
```

The root and mid see the key on the way down, the target sees it as
`AT_TARGET`, and the walk unwinds back up. The target is visited
exactly once.

## Consumption

`consume!(d)` ends propagation immediately. Anything that has not yet
been visited never sees the event — that is how a focused input
swallows a keystroke a global binding would otherwise act on.

```@example events
empty!(log)

function ManyUI.on_event!(w::Trace, d::Dispatch{KeyEvent})
    push!(w.log, (ManyUI.id(w), d.phase))
    ManyUI.id(w) === :mid && consume!(d)
    nothing
end

consumed = propagate!(root, leaf, key('a'))
(consumed = consumed, visited = log)
```

`mid` consumed the key during capture, so `leaf` was never reached and
no bubble phase ran.

## Routing

`dispatch_event!` picks the target before propagating, by event class:

| Event | Target |
|:--|:--|
| `MouseEvent` | the widget under the pointer, else the root |
| `KeyEvent`, `PasteEvent` | the focused widget, else the root |
| `ResizeEvent`, `FocusEvent`, `TickEvent` | the root |
| `RefreshEvent`, `QuitEvent` | not routed; these are App-level only |

Mouse events find their target by hit testing, which returns the
deepest visible widget under the point. Because paint order is document
order, a later sibling covers an earlier one — and `hit_test` honours
that, so a click always reaches what the user can actually see.

```@example events
using ManyUI

ui = Container(Label("title"; id = :t), Button("OK", identity; id = :ok))
layout!(ui, Region(1, 1, 20, 4))

r = region(query_one(ui, "#ok"))
hit_test(ui, r.x, r.y) === query_one(ui, "#ok")
```

## Focus

`focusable_widgets` is the tab order: every visible, focusable widget
in pre-order. Hiding a subtree removes it from the order entirely.

```@example events
app = App(ui, HeadlessDriver(Size(20, 4)))
focus_next!(app)
ManyUI.id(focused(app))
```

## Where events come from

Events are parsed from a byte stream by `InputParser`, which is
deliberately source-agnostic: it never touches `stdin`. A tty driver
feeds it bytes read from the terminal; the web bridge feeds it bytes
that arrived over a WebSocket. Both produce identical events.

The parser is incremental and keeps partial state, so a sequence split
across two reads parses the same as one delivered whole:

```@example input
using ManyUI

whole = InputParser()
split = InputParser()

all_at_once = feed!(whole, Vector{UInt8}("\e[A"))       # up arrow
byte_at_a_time = vcat((feed!(split, [b]) for b in Vector{UInt8}("\e[A"))...)

all_at_once == byte_at_a_time
```

That property is what makes the web target possible without ManyUI
knowing the web exists.
