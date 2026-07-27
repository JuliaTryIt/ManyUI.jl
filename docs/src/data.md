# Data widgets

```@meta
CurrentModule = ManyUI
```

`List`, `Table` and `DataTable` display collections. Reach for `List`
when you have items, `Table` when you have columns, and `DataTable` when
you also need sorting.

They differ from every other widget in one way that matters: **a row is
not a widget**. A hundred-thousand-row table is a `Vector` of a hundred
thousand elements and *zero* extra nodes in the tree.

## Rows are data

A widget per row would mean 100 000 `WidgetNode`s, a layout pass over
all of them on every edit, and 100 000 `render!` dispatches per frame.
Instead these widgets hold their rows as plain data, override
[`content_extent`](@ref), and paint only the rows you can actually see.

```@example data
using ManyUI

small = List(["a", "b", "c"])
big = List(["item $i" for i in 1:100_000])

(small_nodes = length(descendants(small)),
 big_nodes = length(descendants(big)))
```

Both are zero. The cost of a frame is proportional to the window, not to
the data, so a 100 000-row list paints in the same time as a 3-row one.

This is the same seam `TextArea` uses, which is why a
[`Scrollbar`](@ref) works on any of them with no special-casing —
`Scrollbar` is parametric on the thing it reports about, and these
widgets simply override `content_extent` to say how big their data is.

## List

A scrollable, focusable list. Items are whatever you like; `format`
turns one into a string.

```@example data
using ManyUI

l = List(["alpha", "beta", "gamma", "delta"])
apply_stylesheet!(STYLESHEET_EMPTY, l)
layout!(l, Region(1, 1, 12, 3))

buf = Buffer(Size(12, 3))
clear!(buf)
paint!(buf, l)
[join(String(buf.cells[x, y].content) for x in 1:12) for y in 1:3]
```

Three rows of window, four items: it paints the three it can show.

The cursor moves with the arrows, `home`/`end` and `pageup`/`pagedown`,
scrolling itself into view as it goes, and the wheel scrolls the list.
Clicking a row selects it. `on_activate` fires on `enter`:

```julia
List(["alpha", "beta"], w -> println("chose ", w.items[cursor_of(w)]))
```

Rows can be any type, with `format` doing the projection:

```@example data
People = [(name = "Ada", born = 1815), (name = "Alan", born = 1912)]
List(People; format = p -> "$(p.name) ($(p.born))") |> row_count
```

## Table

Columns with headers. Each [`Column`](@ref) carries its caption, width
and alignment:

```@example data
using ManyUI

rows = [("alice", 55), ("bob", 31), ("carol", 31)]
cols = [Column("name"; width = cells(6)),
        Column("age"; width = cells(4), align = Align.END)]

t = Table(rows, cols)
apply_stylesheet!(STYLESHEET_EMPTY, t)
layout!(t, Region(1, 1, 12, 4))

buf = Buffer(Size(12, 4))
clear!(buf)
paint!(buf, t)
[join(String(buf.cells[x, y].content) for x in 1:12) for y in 1:4]
```

The header behaves asymmetrically on purpose: it stays put while the
rows scroll under it, but follows the columns when you scroll sideways.
A header that scrolled away vertically would be useless; one that did
not move horizontally would lie about which column you are looking at.

### Column widths

A column width is a [`Length`](@ref), the same type the layout engine
uses:

| Width | Meaning |
|:--|:--|
| `cells(n)` | exactly `n` cells |
| `pct(n)` | `n`% of the table |
| `fr(n)` | weight `n` of the leftover space |
| `AUTO` | sized to content |

`AUTO` is the one with a catch. Sizing a column to its content means
measuring rows, and measuring 100 000 of them every frame would undo the
entire point of these widgets. So `AUTO` measures a **sample** of rows
(`sample`, defaulting to `TC_AUTO_SAMPLE`) rather than all of them. It
is a good guess, not a guarantee: a wide value outside the sample gets
truncated rather than widening the column. Give a column an explicit
width when you need certainty.

## DataTable

A `Table` that sorts. It needs a `key` telling it how to extract a
sortable value from a row and a column index:

```@example data
using ManyUI

rows = [("carol", 31), ("alice", 55), ("bob", 31)]
cols = [Column("name"; width = cells(6)), Column("age"; width = cells(4))]

dt = DataTable(rows, cols; key = (r, j) -> r[j])
apply_stylesheet!(STYLESHEET_EMPTY, dt)
layout!(dt, Region(1, 1, 12, 4))

sort_by!(dt, 1)          # by name, ascending

buf = Buffer(Size(12, 4))
clear!(buf)
paint!(buf, dt)
[join(String(buf.cells[x, y].content) for x in 1:12) for y in 1:4]
```

The `▲` marks the sorted column. [`toggle_sort!`](@ref) cycles a column
between ascending and descending.

### Sorting does not touch your data

Two properties, both load-bearing.

**Your vector is yours.** Sorting permutes an index, never the rows you
handed over:

```@example data
rows                       # untouched, still in its original order
```

[`source_index`](@ref) maps a displayed row back to where it came from,
which is what you want when the user picks row 1 and you need to know
*which* row that really is.

**The sort is stable.** Rows with equal keys keep their relative order,
so sorting by age here leaves `carol` before `bob` — the order they
arrived in — rather than shuffling ties arbitrarily:

```@example data
sort_by!(dt, 2)            # by age; 31 appears twice
[(source_index(dt, k), rows[source_index(dt, k)]) for k in 1:view_count(dt)]
```

Sorting is `O(n log n)`, and it runs when you ask — never per frame.
Painting a sorted table costs exactly what painting an unsorted one
costs.

## Cells and wide characters

A value too wide for its column is truncated on a **grapheme boundary**,
never mid-cluster. A CJK ideograph or an emoji occupies two cells, and a
wide cluster that would straddle the column edge is dropped whole rather
than sliced in half — a halved cluster would corrupt every column to its
right.

```@example data
using ManyUI
(truncate_width("漢字テキスト", 5), text_width("漢字"))
```

This is why the framework has [`text_width`](@ref) and
[`truncate_width`](@ref) and never uses `Base.textwidth`, which reports
1 for an emoji that occupies 2 cells and 8 for a ZWJ family that
occupies 2.

## Scrolling them

Each of these widgets scrolls itself, so a [`Scrollbar`](@ref) can
report on one directly:

```julia
Container(my_list, Scrollbar(ScrollAxis.VERTICAL, my_list))
```

Wrapping one in a `Scrollpane` is also legal and scrolls the
widget's whole box instead — the two mechanisms compose rather than
compete.
