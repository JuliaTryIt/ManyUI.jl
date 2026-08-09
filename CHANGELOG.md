# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `RichText` and `TextRun`: one line of text whose style varies along
  it. A `Style` is per-widget and comes from the cascade; this is the
  escape hatch for the styled things that are not nodes -- the key in a
  tab caption, the level in a log line, the units in a status readout.
  Making each of those a widget would put three nodes on a tab strip
  and one per log row.
- A run's style is folded OVER the painting widget's style with
  `merge`, the cascade's own monoid, so a run describes a DIFFERENCE,
  never an absolute appearance. `STYLE_NONE` -- the default -- means
  exactly the widget's style, and a run naming only `bold` keeps the
  widget's colours. One `RichText` therefore paints correctly under a
  light and a dark theme without being rebuilt.
- `RichText` normalises at construction: empty runs dropped, adjacent
  runs of equal style coalesced. `RichText("ab")` and
  `RichText(TextRun("a"), TextRun("b"))` are `==`, so a line may be
  built however is convenient, and a wrap that emits one run per
  grapheme costs two `write_text!` calls to paint, not forty.
- `text_width`, `truncate_width` and `wrap_width` accept a `RichText`.
  Wrapping runs the PLAIN text through the existing string wrap and
  reattaches the styling, which is the whole design: it makes
  `plain.(wrap_width(rt, w)) == wrap_width(plain(rt), w)` true by
  construction, so colouring a paragraph cannot move one of its breaks.
  A second wrap implementation would have to be kept in step forever to
  promise that; there is only one wrap. A joining space inherits the
  style of the whitespace run it stands for -- that cell still has a
  background, and resetting it would leave a hole in a highlighted line.
- `truncate_width` on a `RichText` yields a PREFIX: it stops at the
  first cluster that does not fit rather than skipping it, so a wide
  cluster refused at the edge does not let a narrow run behind it slide
  forward. Same rule as the string method, which breaks out of its scan.
- `plain` returns the text with the styling dropped, and a plain string
  converts to a `RichText` implicitly, so `label.text[] = "hi"` --
  spelled verbatim in `reactive.jl`'s own docstring -- keeps working.
- Modal popups: `Popup(...; modal = true)`. What makes one modal rather
  than merely large is that the user cannot walk around the question it
  asks -- a press outside does not dismiss it, TAB does not leave it,
  and a keystroke does not reach the tree behind it. The popup layer
  dismisses an ordinary popup on exactly that outside press, so this
  had to be carved out of it.
- `focus_root(app)` is THE focus trap, and it is one function rather
  than a flag threaded through the dispatch: the tab order and the
  keyboard belong to an open modal's content, and to the tree
  otherwise. It asks about `modal` and not merely about `popup`,
  because a `DropDown` keeps focus itself and forwards -- a non-modal
  popup must not take the keyboard.
- Opening a modal moves focus into it and closing puts it back where it
  was, through the new `App.focus_before_modal`. A field rather than a
  guess: without it, closing a dialog can only put focus at the top of
  the tree, and a user who opened it from the eighth field of a form
  lands on the first. Focus is restored only if the widget is still in
  the tree.
- A modal dims what it covers before painting itself, with
  `MODAL_DIM`. `DIM` and not a fill: dimming keeps the tree readable
  underneath, which is what says the application is still there and
  waiting rather than gone.
- `Splitter`: a row or column of panes separated by draggable handles.
  A HANDLE IS A WIDGET, and that is the whole design -- a node between
  two panes, so it is hit-tested, painted and laid out by machinery
  that already exists. A pane's share of the main axis is its `grow`,
  so the layout engine distributes it and this widget only ever
  rewrites two numbers.
- The one thing a handle cannot do for itself is follow a drag: a
  pointer that outruns the redraw leaves the one-cell handle and the
  DRAG lands on a pane. So the SPLITTER consumes drags, in the CAPTURE
  phase, while a handle is down. Capture runs root-first, so it sees
  the event before the pane the pointer strayed onto -- pointer capture
  obtained from the propagation order that already exists, rather than
  from a new mechanism in the app.
- A drag moves ONLY the two panes it is between: their `grow` total is
  preserved, so a third pane cannot shift under a resize it had nothing
  to do with. Both are clamped to `SPLIT_MIN_PANE`, which is what stops
  a drag past the end from inverting them.
- `panes`, `handles`, `pane_count`, `weights_of` and `set_weights!`
  exist so callers never index `children` and count in twos; `mount!`
  on a `Splitter` throws, because a stray child would shift the parity
  and silently turn a pane into a handle.
- `on_resize` fires once per actual change, not once per mouse event: a
  drag that lands on the coordinate it was already at reports nothing.
- The web projection needed no code. A `Splitter` is a flex box whose
  panes carry `grow`, so `flex-direction` and `flex-grow` already carry
  the split to the browser -- though dragging it there does not work
  yet.
- A theme system: semantic colour TOKENS, named palettes, and a swap
  that costs a repaint. `token(:warning)` is a `Color` of the new
  `ColorKind.TOKEN`, carrying a token id rather than channels, so a
  token fits an isbits `Style` and travels wherever a colour does.
- WHEN A TOKEN BECOMES A COLOUR IS THE WHOLE DESIGN, and it is at
  EMISSION -- inside `color_seq!`/`sgr!` on the terminal and
  `_css_color` on the web, the one place an authorial-intent colour
  meets a device. Not at parse time, and not at cascade time. Three
  consequences follow, and they are the reason for the choice: one
  parsed stylesheet serves every theme; `merge` carries a token
  through, so a `TextRun` naming `:warning` is built once and is right
  under every theme rather than frozen to whichever was current when it
  was built; and `set_theme!` needs neither a re-cascade nor a
  re-parse, because nothing in the tree holds a resolved colour.
- `set_theme!` therefore requires a full REPAINT and says so: the frame
  diff compares cells, the cells did not change, and it will not find
  the swap on its own. On the terminal backend that is `refresh!`.
- Ten tokens -- `bg`, `text`, `text_dim`, `accent`, `border`,
  `success`, `warning`, `error`, `selection_bg`, `selection_fg` -- and
  two built-in themes, `:dark` and `:light`. `register_token!` and
  `register_theme!` extend both sets.
- A `Theme` need not be total. A token it does not name falls back to
  the colour declared with the token, so a theme that cares about three
  colours is three entries long. The alternative fails as one
  unreadable widget discovered at runtime, far from the theme that
  caused it.
- CSS names a token with `var(--accent)`, and an unknown name is a
  `CssParseError` with a position, like every other bad value.
- `is_token`, `token_name`, `token_names`, `theme_color` and
  `resolve_token` round out the API. `resolve_token` is idempotent and
  returns its argument ITSELF when there is no token, so the common
  case on the emission path allocates nothing and compares by identity.
- Border captions. `border_title(w)` and `border_title_align(w)` are a
  SEAM, not a field: a caption belongs to the handful of widgets that
  frame something, and a slot on every `WidgetNode` would charge the
  other thousands for it. Override either and any widget gains one.
  `Container` ships with `title` and `title_align` keywords.
- It is a seam AT ALL because a widget cannot draw this itself:
  `_paint_node!` hands `render!` the CONTENT box and the border is
  outside it, so a titled box drawing its own caption would have to
  reserve a content row -- which puts the caption INSIDE the frame
  rather than on it. The paint pass asks each node instead, through
  `paint_border_title!`.
- A caption never touches a corner. It may use the top edge less one
  glyph at each end, less two pad cells, and is truncated to what is
  left; a box too narrow keeps its frame and drops the caption. An
  overwritten corner is a broken frame, and it is the failure mode of
  every hand-rolled version of this.
- Each run of a caption folds over the BORDER's style rather than the
  widget's, so an unstyled caption matches the line it sits on instead
  of resetting against it.
- `title` is `Dirty.PAINT`-reactive, and provably so rather than
  optimistically: `Container` defines no `measure`, so a new caption
  cannot move the widget or its siblings, and the border row it lands
  on exists whether or not there is a caption on it.
- `TextLike`, the union a widget accepts where it wants one line of
  text. `List`'s `format`, `Table`'s and `DataTable`'s `cell`, and a
  tab caption may all return either spelling. The widget neither
  converts eagerly -- which would allocate a `RichText` per row per
  frame for the overwhelmingly common plain case -- nor grows a second
  code path, because `text_width`, `truncate_width` and the painters
  all take the union.
- A row widget's styled text costs ONE method: every one of them paints
  through `_tc_slice!`, so `List`, `Table`, `DataTable`, `TreeView`,
  `Tabs` and `Checkbox` gained it from a single `RichText` overload of
  that painter rather than from six edits.

- `PopupPlacement.CENTER` centres popup content in the viewport independently
  of its owner, providing a backend-neutral placement for modal dialogs.
- Every `WidgetNode` can carry universal `on_focus` and `on_blur` callbacks.
  They run in addition to widget-specific focus hooks, including for widgets
  that manage their own focused appearance.
- Disabled states for interactive widgets, password text inputs, a
  `ProgressBar`, an `ErrorBoundary`, and the `Immediate` procedural API.

- A popup layer, and the two widgets that ride it. `DropDown` (a `<select>`
  over any vector, with `set_open!`/`options`/`selected_item`) opens its
  list on the new popup layer -- a second root painted over the tree and
  hit-tested before it, owned by the `App` via a new `App.popup` slot,
  opened with `open_popup!` and closed through `close_popup!`/
  `on_popup_close!`. `Form` collects a set of fields (`add_field!`,
  `submit!`, `form_values`) over the input widgets, reading each through
  `form_value`. The popup layer generalizes the min-size overlay the app
  already paints over the tree.
- Three widgets: `Checkbox`/`RadioGroup` (with `CheckState`, `toggle!`,
  `set_state!`, `choose!`, ...), `Tabs` (a tab strip over swappable panels,
  with `add_tab!`/`select_tab!`), and `TreeView` (a collapsible tree over
  `TreeNode`s, with `expand_node!`/`collapse_all!`/`toggle_node!`/...). Each
  follows the existing widget seam -- `measure`/`render!`/`on_event!` -- and
  ships with its test suite.

- `Backend`, an inert description of where an app should run, and `launch`,
  one verb that runs an app on any of them. Swapping a target is now an
  argument rather than a rewrite: `launch(ui)` for this terminal,
  `launch(ui; backend = WebBackend(port = 8000))` for a browser. `config`
  and `stylesheet` describe the app and so are spelled the same way on
  every backend; target settings live on the backend.
- `TerminalBackend` and `HeadlessBackend`, plus `make_driver`, the single
  method a new backend implements. A backend defined in another package
  joins by dispatch alone -- `ManyUIWeb.WebBackend` is the worked example.
- `Base.close(::App)`, forwarding to `quit!`. Every `launch` handle now
  answers the same three verbs -- `isopen`, `close`, `wait` -- whichever
  backend produced it.
- A "Backends" page in the documentation.

### Changed (breaking)

- `Label.text` and `Static.text` are `Reactive{RichText}` rather than
  `Reactive{String}`. Both constructors still accept a plain string and
  both cells still accept a string assignment, so only code READING
  `label.text[]` as a `String` needs changing: wrap it in `plain`.
  Styling is now a different value, never a different widget or a
  different code path -- and a `Label` coloured mid-line wraps exactly
  where the same text wraps unstyled.
- `TabStrip.titles` is a `Vector{RichText}`, and `tab_title` returns
  one. `Tabs(...)` and `add_tab!` still take plain strings. `tab_at`
  and `_tb_title_x` stayed generic over `TextLike`: they need nothing
  but `text_width`, so a caller holding strings does not have to
  convert in order to ask which tab a column falls in.
- Widget callbacks now use one event vocabulary across projections:
  `Button.on_press` is `on_click`, and row widgets use `on_submit` instead
  of `on_activate`. `List`, `Table`, `DataTable`, and `TreeView` also accept
  `on_change`, fired exactly once when their cursor or selection changes.

### Fixed

- `launch(...; wait = false)` returns a handle whose loop is already
  running. `start!` only spawns `run!`, and `run!` is what sets
  `app.running`, so a handle returned straight from `start!` reported
  `isopen == false` and could race a `close` against the loop starting. An
  app that throws on the way up now rethrows at the launch site rather
  than from a task nobody is waiting on.

