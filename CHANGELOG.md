# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking)

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
