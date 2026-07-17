# Styling

```@meta
CurrentModule = DualUI
```

Appearance is declarative. Rules are written in a CSS-like syntax,
matched against widget ids, classes and types, and cascaded onto the
tree by specificity.

## Stylesheets

`parse_css` builds a `Stylesheet`; the `css"..."` string macro does the
same at parse time:

```@example css
using DualUI

sheet = parse_css("""
    Container { layout: column; padding: 1; gap: 1; border: round cyan; }
    Label     { color: cyan; }
    .warn     { color: yellow; }
    #title    { color: red; }
""")

length(sheet.rules)
```

Bad input throws a `CssParseError` carrying the line and column, never
a bare `ArgumentError`:

```@example css
try
    parse_css("Label { color: }")
    false
catch e
    e isa CssParseError
end
```

## Selectors and specificity

Three selector kinds are supported, and they rank exactly as CSS ranks
them — id beats class beats type:

```@example css
[(src, specificity(parse_css(src).rules[1].selector))
 for src in ("#title { color: red; }",
             ".warn { color: red; }",
             "Label { color: red; }")]
```

`Specificity(id, class, type)` is compared field by field. Between two
rules of equal specificity, the later one wins.

Applying the sheet resolves each node's computed style. A label that is
`#title`, `.warn` *and* a `Label` matches all three rules, and the id
wins:

```@example css
label = Label("hi"; id = :title, classes = [:warn])
root = Container(label)
apply_stylesheet!(sheet, root)

computed_style(label).fg
```

`apply_stylesheet!` walks the whole tree; `recascade!` is the
incremental form the frame loop uses, doing the work only where the
style is dirty.

## Properties

| Property | Value |
|:--|:--|
| `color` | foreground color |
| `background` | background color |
| `border` | `<kind>` or `<kind> <color>` |
| `display` | `none`, `block`, `flex` |
| `layout` | a direction; shorthand for `display: flex` plus `direction` |
| `direction` | `row`, `column`, `row-reverse`, `column-reverse` |
| `justify` | `start`, `center`, `end`, `space-between`, `space-around`, `space-evenly` |
| `align` | `start`, `center`, `end`, `stretch` |
| `width`, `height` | a length |
| `margin`, `padding` | 1, 2 or 4 cell counts, in CSS order |
| `gap` | cells between flex children |
| `grow`, `shrink` | flex weights |
| `overflow` | `visible`, `hidden`, `scroll` |

Adding a property is adding a `parse_property` method — the table is
extensible, and is used only by the parser, never in a render loop.

## Colors

Colors come in four kinds:

```@example color
using DualUI
(rgb(0xFF, 0x64, 0x00), ansi256(202), ansi16(9), COLOR_DEFAULT)
```

## Color degradation

Not every terminal speaks 24-bit color. Rather than refuse to draw,
DualUI maps a color down to whatever the target actually supports.
`degrade` is a pure function of the color and the depth:

```@example color
orange = rgb(0xFF, 0x64, 0x00)
(truecolor = orange,
 at_256 = degrade(orange, ColorDepth.ANSI256),
 at_16 = degrade(orange, ColorDepth.ANSI16))
```

The 256-color step maps into the 6×6×6 cube and the grayscale ramp; the
16-color step picks the nearest perceptual match.

The depth is never guessed from `ENV` inside the render path. It comes
from the driver's `capabilities`, so a web client reporting no
truecolor support degrades exactly like a limited tty:

```@example color
caps = capabilities(HeadlessDriver(Size(10, 2); depth = ColorDepth.ANSI16))
caps.color_depth
```

`detect_color_depth` is what a `TerminalDriver` uses to answer that
question for a real terminal, from `COLORTERM` and `TERM`.

## Text attributes

Attributes live on `Style`:

```@example color
s = with(STYLE_NONE, Attr.BOLD, true)
(bold = has(s, Attr.BOLD), italic = has(s, Attr.ITALIC))
```

Styles merge with the child winning wherever it specifies something —
the same rule the cascade itself is built from.
