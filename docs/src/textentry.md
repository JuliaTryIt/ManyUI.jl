# Text entry

```@meta
CurrentModule = ManyUI
```

Two widgets: `TextInput` for one line, `TextArea` for many. They share a
discipline rather than a supertype — the same cursor units, the same
clamps, the same grapheme rules — and they differ exactly where a line
break makes them differ.

## TextInput

A single-line field with a placeholder, a submit handler and a caret:

```julia
using ManyUI

submitted = String[]
field = TextInput("", i -> push!(submitted, i.text[]);
                  placeholder = "name?", id = :name)
apply_stylesheet!(STYLESHEET_EMPTY, field)
layout!(field, Region(1, 1, 10, 1))

buf = Buffer(10, 1)
clear!(buf)
paint!(buf, field)
buf
```

The placeholder shows while the text is empty, and it is painted dimmed
rather than as content:

```julia
has(buf[1, 1].style, Attr.DIM)
```

Type into it and press `enter`:

```julia
for c in "ada"
    dispatch_event!(field, key(c), field)
end
dispatch_event!(field, parse(KeyEvent, "enter"), field)

(text = field.text[], cursor = field.cursor[], submitted = submitted)
```

`text` and `cursor` are `Reactive`, but with `Dirty.PAINT` rather than
the conservative `Dirty.LAYOUT` default — and that is a design
commitment, not an optimisation. `measure` is text-independent:

```julia
measure(field, Size(30, 9))
```

A `TextInput` takes the width it is offered and is always one row tall,
so it never resizes to its content — that is what its horizontal scroll
is for. A keystroke provably cannot move a single box, so a keystroke
costs **zero** layout. Do not copy the `PAINT` choice to a widget whose
size depends on its state; there it would be a correctness bug.

Give it a narrow box with `width: 20` if you want one.

## TextArea

A multi-line editor over a `Vector{String}`:

```julia
notes = TextArea("alpha\nbeta")
apply_stylesheet!(STYLESHEET_EMPTY, notes)
layout!(notes, Region(1, 1, 10, 3))

insert_text!(notes, "X")
insert_newline!(notes)
(text = text(notes), line = notes.line, col = notes.col)
```

`measure` returns everything it is offered:

```julia
measure(notes, Size(30, 9))
```

An auto-height `TextArea` would be as tall as its document and would
never scroll at all, so give it a `height: 10` or a `grow: 1` parent.

It scrolls by **indexing** its lines rather than by shifting an origin:
`render!` touches `scroll.y + 1 : scroll.y + height` and nothing else,
so painting is O(window) and a 100 000-line document costs the same
frame as a ten-line one.

The document is a plain field, deliberately not a `Reactive`: an `==`
guard over a `Vector{String}` would be an O(n) elementwise compare on
every keystroke, and an in-place edit would never trip it anyway.
`version` is the reactive cell instead — an `Int` compare, O(1), for the
O(1) edit that actually happened. The price is worth stating plainly:
**mutate `lines` behind `version`'s back and it will not repaint**, so
every edit goes through the operations below.

`content_extent` is overridden to report the document rather than the
(nonexistent) children, and that override is the whole of its
integration with the scrolling machinery. A `Scrollbar` reports on a
`TextArea` with no new code at all:

```julia
using ManyUI

area = TextArea(join(["line $i" for i in 1:20], "\n"); id = :area)
bar = Scrollbar(area, ScrollAxis.VERTICAL; id = :bar)
row = Container(area, bar; id = :row)

apply_stylesheet!(css"""
                  #row  { display: flex; layout: row; }
                  #area { grow: 1; }
                  #bar  { width: 1; shrink: 0; }
                  """, row)
layout!(row, Region(1, 1, 10, 4))

(content = content_extent(area), window = layout_of(area).content)
```

```julia
scroll_to!(area, Offset(0, 8))
buf = Buffer(10, 4)
clear!(buf)
paint!(buf, row)
buf
```

`Scrollpane(TextArea(...))` is also legal and scrolls the area's whole
box — the two mechanisms compose rather than compete. But a `TextArea`
contains no `Scrollpane`, and never should: a pane scrolls *children*,
so a 10 000-line document would become 10 000 widgets.

## The cursor

The caret is **reverse video on the cell it rests on**, not a hardware
cursor: the tree paints into a `Buffer`, and the `Driver` seam has no
cursor-placement method at all. It appears while the widget is focused.

Cursor indices are 0-based and count **grapheme clusters**: `0` is
before the first cluster and `n` is after the last. This is not a
violation of the package's 1-based rule — that rule governs `Region`,
`Buffer` and `MouseEvent`, and a cursor is none of those. It is a count
of what lies behind the caret, which makes `0:n` the natural range and
both ends legal split points.

| Widget | Cursor |
|:--|:--|
| `TextInput` | `cursor[]`, a cluster index in `0:n` |
| `TextArea` | `line` (1-based into `lines`) and `col` (a cluster index) |

`TextArea` also keeps a `goal` column, in **cells**, which `up` and
`down` aim for and which every horizontal move re-pins. Cells are the
unit the user can see; a goal measured in graphemes would land in a
visually different column across wide clusters. Its absence is the
single most-noticed bug in a text editor — run down through a short line
and back up, and the caret comes home:

```julia
g = TextArea("aaaaaaaa\nbb\ncccccccc")
apply_stylesheet!(STYLESHEET_EMPTY, g)
layout!(g, Region(1, 1, 10, 3))

move_by!(g, 6)                              # line 1, cell column 6
down1 = (move_line!(g, 1), g.col)           # line 2 is only 2 wide
down2 = (move_line!(g, 1), g.col)           # line 3 is wide again
(goal = g.goal, down1 = down1, down2 = down2)
```

`move_line!` lands on the cluster whose prefix width is the largest not
exceeding `goal`, so `up`/`down` can never come to rest *inside* a wide
cluster.

## Editing keys

Both widgets act on the way up, on unmodified keys only, and consume
what they act on.

| Key | `TextInput` | `TextArea` |
|:--|:--|:--|
| a character, `space` | insert at the caret | insert at the caret |
| `enter` | calls `on_submit` | splits the line |
| `backspace` | delete the cluster before | at column 0: join the line above |
| `delete` | delete the cluster at | at end of line: join the line below |
| `left` / `right` | one cluster | one cluster, wrapping across lines |
| `up` / `down` | — | one line, aiming at `goal` |
| `pageup` / `pagedown` | — | one window less one row |
| `home` / `end` | start / end of the text | start / end of the **line** |
| `tab`, `escape` | fall through | fall through |
| `ctrl+…`, `alt+…` | fall through | fall through |

`tab` and `escape` falling through is what keeps the tab order alive,
and modified keys falling through is what stops a focused field silently
shadowing your application bindings:

```julia
box = TextInput("x")
(tab = dispatch_event!(box, parse(KeyEvent, "tab"), box),
 letter = dispatch_event!(box, parse(KeyEvent, "a"), box),
 ctrl_a = dispatch_event!(box, parse(KeyEvent, "ctrl+a"), box),
 text = box.text[])
```

Only the plain letter was consumed, and only it was inserted.

Every key has a function behind it, so you never need to synthesise
events to drive a field: `insert_text!`, `insert_newline!`,
`backspace!`, `delete_forward!`, `move_by!`, `move_to!` (`TextInput`),
`move_line!` (`TextArea`), plus `set_text!`, `text` and
`refresh_extent!` on `TextArea`.

`home` and `end` are `move_to!` with the extremes of `Int` and let the
clamp decide — "go as far as you can" *is* the implementation. In a
`TextArea` they are per **line**, because that is what a caret in an
editor means; a `Scrollpane`'s document-wide `home`/`end` still reaches
an ancestor pane whenever the area is not focused.

`TextArea` keeps `widest` as a monotone high-water mark, raised in O(1)
by every edit and lowered by nothing. The tradeoff, stated so nobody has
to discover it: after you delete the longest line the horizontal range
stays too wide — the thumb is slightly too small — until
`refresh_extent!` rescans. Paying O(lines) per keystroke to save a
scrollbar thumb one cell is not a trade worth making. `set_text!` calls
it for you.

## Paste

A `PasteEvent` arrives whole, from bracketed paste, and the two widgets
treat it differently because their content differs.

`TextInput` strips newlines and every other control character: a
single-line field has nowhere to put a line break, and silently
accepting one would make its text unrenderable.

```julia
one = TextInput()
dispatch_event!(one, PasteEvent("one\ntwo"), one)
one.text[]
```

`TextArea` splits it into real lines — it is exactly the widget a
multi-line paste belongs in:

```julia
many = TextArea()
dispatch_event!(many, PasteEvent("one\ntwo"), many)
(text = text(many), lines = length(many.lines))
```

A paste that strips to nothing still consumes: it was a paste into this
field, and letting the husk bubble would be a second delivery of the
same event.

## Grapheme correctness

This is the section that matters, because it is the thing everyone else
gets wrong.

A terminal grid is not a string, and a user's text is not a sequence of
codepoints. Take a ZWJ family emoji — man, zero-width joiner, woman,
zero-width joiner, girl:

```julia
using ManyUI

fam = "👨‍👩‍👧"
(codepoints = length(collect(fam)),
 bytes = ncodeunits(fam),
 cells = grapheme_width(fam),
 base_textwidth = textwidth(fam))
```

Five codepoints, eighteen bytes, **two cells** — and `Base.textwidth`
says six, because it sums codepoints and knows nothing about clustering.
It is forbidden throughout ManyUI's text handling for exactly that
reason. (`textwidth("❤️")` is 1, for a cluster that renders in two: the
error goes both ways.)

The rule is: **a cursor steps by grapheme cluster.** One step, however
many codepoints or cells that cluster is.

```julia
w = TextInput("a$(fam)b")
move_to!(w, 0)                       # Home
[move_by!(w, 1) for _ in 1:4]        # four presses of `right`
```

Three clusters — `a`, the whole family, `b` — and the fourth press
saturates instead of running off the end. The family is **one step**,
not five, and not eighteen.

Now watch the same cluster occupy two cells. Put the caret on it, paint,
and find the cell the caret reversed:

```julia
apply_stylesheet!(STYLESHEET_EMPTY, w)
layout!(w, Region(1, 1, 8, 1))
w.focused[] = true
move_to!(w, 1)                       # the caret is ON the family

buf = Buffer(8, 1)
clear!(buf)
paint!(buf, w)
buf
```

```julia
caret = findfirst(x -> has(buf[x, 1].style, Attr.REVERSE), 1:8)
cell = buf[caret, 1]

(column = caret,
 glyph = String(cell.content),
 cells = Int(cell.width),
 next_is_continuation = is_continuation(buf[caret + 1, 1]))
```

One step of the cursor, one cell of caret, **two cells of grid** — and
the continuation cell after it is intact. The caret reverses the *head*
of a wide cluster and leaves its continuation a continuation, so the
grid never desynchronises. A wide cluster that would straddle either
edge of the window is dropped whole, never halved, at the left edge as
well as the right.

Deleting is the same rule. One `backspace` over the family takes all
eighteen bytes of it, not the last codepoint:

```julia
move_to!(w, 2)                       # just past the family
backspace!(w)
(text = w.text[], cursor = w.cursor[])
```

The subtlest case is insertion, and it is why the caret is always
**recomputed from the new prefix** and never advanced by the number of
clusters inserted. Type a combining acute onto an `e`:

```julia
v = TextInput("e")
move_to!(v, typemax(Int))            # End -- one cluster behind the caret
insert_text!(v, "́")            # COMBINING ACUTE ACCENT

(text = v.text[],
 bytes = ncodeunits(v.text[]),       # was 1
 cursor = v.cursor[],                # was 1
 cells = grapheme_width(v.text[]))
```

The string grew by two bytes and the cluster count did **not** change:
the mark merged into the `e`. A caret advanced by "one inserted cluster"
would now sit past the end of a string that never grew. Recomputing is
the only rule that is right for every input, which is why it is the only
rule used.

The same discipline runs all the way down: byte indices and cluster
indices meet in exactly one place, a small set of shared helpers that
`TextInput` defines and `TextArea` uses, so the two cannot drift apart —
and no widget code indexes a user's string by byte.
