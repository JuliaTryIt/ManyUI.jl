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

### Changed (breaking)

- `Label.text` and `Static.text` are `Reactive{RichText}` rather than
  `Reactive{String}`. Both constructors still accept a plain string and
  both cells still accept a string assignment, so only code READING
  `label.text[]` as a `String` needs changing: wrap it in `plain`.
  Styling is now a different value, never a different widget or a
  different code path -- and a `Label` coloured mid-line wraps exactly
  where the same text wraps unstyled.
- Widget callbacks now use one event vocabulary across projections:
  `Button.on_press` is `on_click`, and row widgets use `on_submit` instead
  of `on_activate`. `List`, `Table`, `DataTable`, and `TreeView` also accept
  `on_change`, fired exactly once when their cursor or selection changes.

### Added

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

### Fixed

- `launch(...; wait = false)` returns a handle whose loop is already
  running. `start!` only spawns `run!`, and `run!` is what sets
  `app.running`, so a handle returned straight from `start!` reported
  `isopen == false` and could race a `close` against the loop starting. An
  app that throws on the way up now rethrows at the launch site rather
  than from a task nobody is waiting on.
