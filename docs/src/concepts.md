# Concepts

```@meta
CurrentModule = DualUI
```

DualUI borrows the browser's ideas and applies them to a grid of
characters. If you know the DOM, CSS and `addEventListener`, you
already know the shape of this framework.

## The render pipeline

Every frame runs the same five stages. Each is a plain function over
plain data, which is why almost all of DualUI can be tested without a
terminal:

```
widget tree ─▶ layout ─▶ cell buffer ─▶ diff ─▶ ANSI bytes ─▶ driver
```

1. **Tree.** A hierarchy of widgets, each holding a `WidgetNode` with
   its id, classes, parent and children.
2. **Layout.** `compute_layout` resolves the CSS box model into an
   absolute `Region` for every node.
3. **Paint.** `paint!` walks the laid-out tree and writes `Cell`s into
   a `Buffer`.
4. **Diff.** `diff` compares the previous frame to the new one and
   yields a `Patch`: the minimal set of changed cells.
5. **Encode.** `AnsiEncoder` turns that patch into escape sequences,
   emitting a cursor move only when cells are not contiguous, and an
   SGR only when the style actually changed.

The diff is what keeps rendering cheap. An unchanged frame costs
nothing at all:

```@example pipeline
using DualUI

before = Buffer(Size(10, 2))
after = Buffer(Size(10, 2))
clear!(before)
clear!(after)

# Identical buffers produce no work whatsoever.
length(diff(before, before).spans)
```

Change two cells, and only those two cross the wire:

```@example pipeline
write_text!(after, 1, 1, "hi", STYLE_NONE)
patch = diff(before, after)
(spans = length(patch.spans), cells = n_cells(patch))
```

```@example pipeline
encoder = AnsiEncoder(ColorDepth.TRUECOLOR)
length(encode(encoder, patch))
```

## The driver seam

This is the idea the whole project rests on. A `Driver` is the *only*
thing that knows what a rendering target is, and it has exactly nine
required methods:

```@example seam
using DualUI
REQUIRED_DRIVER_METHODS
```

A driver moves bytes, reports a size and its capabilities, and yields
events. That is all. No method in the interface accepts or returns a
`Buffer`, a `Patch`, a `Widget` or a `Style`, so a driver cannot reach
into the framework and the framework cannot depend on a target.

Three drivers exist today:

| Driver | Target | Lives in |
|:--|:--|:--|
| `TerminalDriver` | the host tty | `DualUI` |
| `HeadlessDriver` | an in-memory buffer | `DualUI` |
| `WebSocketDriver` | a browser | `DualUIWeb` |

`DualUIWeb` implements those nine methods over a WebSocket and adds
nothing else. That is why `DualUI` has no HTTP dependency: a pure
terminal application never pays for the web bridge. A driver can check
its own conformance without reading DualUI's source, which is how the
bridge package proves it implements the interface:

```@example seam
check_driver_interface(HeadlessDriver)   # empty means conformant
```

`HeadlessDriver` is the proof the seam is honest. It renders into an
`IOBuffer`, so the whole framework — including the event loop — is
testable with no tty and no network. If a headless driver needs nothing
from DualUI's internals, neither does a web one.

## Reactivity and dirty flagging

Mutating a widget does not repaint the world. `mark!` flags only that
widget and the descendants a change can actually reach. Siblings,
uncles and cousins are never touched, so a deep tree with one changed
leaf costs one subtree of layout rather than a full pass.

Ancestors get a `Dirty.SUBTREE` breadcrumb so the next frame can find
the dirty node, and that breadcrumb is promoted to real layout work
only at an ancestor whose size genuinely depends on its content.

## The asynchronous event loop

`run!` blocks on a `Channel{Event}` that the driver fills. The OS
scheduler does the pacing: there is no fixed frame rate and no
busy-wait. A burst — a resize storm, a large paste — drains through the
channel and collapses into a single repaint.

The loop is parameterised over the driver, so `App{HeadlessDriver}` and
`App{WebSocketDriver}` are separate concrete types and the frame path
stays statically dispatched.

## Wide characters

A terminal grid is not a string. An emoji or a CJK ideograph occupies
two cells, and getting this wrong corrupts every column to its right.
DualUI measures by grapheme cluster, never by codepoint, and never
trusts `Base.textwidth`:

```@example width
using DualUI
[(s, grapheme_width(s), textwidth(s)) for s in ("a", "漢", "❤️", "👨‍👩‍👧‍👦")]
```

The last two are why this matters: `Base.textwidth` reports 1 for a
VS16 emoji that renders in two cells, and 8 for a ZWJ family that
renders in two.
