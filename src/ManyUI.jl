"""
Terminal-first UI framework: a widget tree, a CSS-like box model, a
diffing renderer and an ANSI encoder, behind a nine-method `Driver`
seam.

This package has NO web, HTTP or socket dependency and never will;
`ManyUIWeb` plugs into the `Driver` seam from the outside.
"""
module ManyUI

using Unicode
using InlineStrings
using DocStringExtensions
import REPL

# Names below are Base generics whose semantics we match exactly; they
# are extended (not shadowed) so the unqualified definitions in the
# per-file sources below resolve to the Base binding.
import Base: parent, diff, resize!

@template (FUNCTIONS, METHODS, MACROS) = """
    $(TYPEDSIGNATURES)
    $(DOCSTRING)
    """
@template TYPES = """
    $(TYPEDEF)
    $(DOCSTRING)

    # Fields
    $(TYPEDFIELDS)
    """

include("core.jl")
include("types.jl")
include("geometry.jl")
include("unicode.jl")
include("color.jl")
include("style.jl")
include("events.jl")
include("boxmodel.jl")
include("buffer.jl")
include("diff.jl")
include("ansi.jl")
include("input.jl")
include("driver.jl")
include("widget.jl")
include("reactive.jl")
include("dispatch.jl")
include("layout.jl")
include("css.jl")
include("paint.jl")
include("widgets/container.jl")
include("widgets/label.jl")
include("widgets/button.jl")
# The order within these is NORMATIVE: `scroll.jl` defines
# `content_extent`, which `textarea.jl` and the three row widgets
# override; `textinput.jl` defines the shared grapheme helpers, which
# `textarea.jl` uses; `tablecore.jl` defines `RowsWidget`, `Selection`,
# `Column` and `TableGrid`, which `list.jl`, `table.jl` and
# `datatable.jl` USE and MUST NOT redefine.
include("widgets/scroll.jl")
include("widgets/textinput.jl")
include("widgets/textarea.jl")
include("widgets/tablecore.jl")
include("widgets/list.jl")
include("widgets/table.jl")
include("widgets/datatable.jl")
include("widgets/overlay.jl")
# `toggle.jl` defines `Checkbox`/`RadioGroup`, `tabs.jl` defines `Tabs`,
# `tree.jl` defines `TreeView` (needs `tablecore.jl`). `popup.jl` defines
# the `Popup` value BEFORE app.jl, because `App` carries an `App.popup`
# field; `dropdown.jl` opens one (`DropDown` needs the popup layer) and
# `form.jl` USES `Checkbox`/`RadioGroup`/`DropDown`/`Tabs`, so both come
# after. The App-facing popup verbs are in `popup_ops.jl`, AFTER app.jl.
include("widgets/toggle.jl")
include("widgets/tabs.jl")
include("widgets/tree.jl")
include("widgets/popup.jl")
include("widgets/dropdown.jl")
include("widgets/form.jl")
include("headless.jl")
include("terminal.jl")
include("app.jl")
include("popup_ops.jl")
include("backend.jl")
include("precompile.jl")

# core.jl
export Projection, CLI, TUI, WebTerminal, WebNative
export Action, execute!, render

# types.jl
export Widget, Driver, AbstractApp, Event

# geometry.jl
export Size, Offset, Region, Spacing
export NO_SPACING, EMPTY_REGION, ORIGIN
export horizontal, vertical, origin, size_of, right, bottom, area
export translate, shrink, grow, clamp_to, clamp_size
export split_row, split_col

# unicode.jl
export char_width, is_wide, is_combining, is_regional_indicator
export grapheme_width, text_width, grapheme_cells
export truncate_width, wrap_width

# color.jl
export ColorKind, ColorDepth, Color
export COLOR_UNSET, COLOR_DEFAULT
export rgb, ansi16, ansi256, color
export is_unset, is_set, color_index
export to_rgb, luminance, color_distance
export rgb_to_ansi256, ansi256_to_ansi16, rgb_to_ansi16
export degrade, detect_color_depth

# style.jl
export Attr, AttrMask, Style, STYLE_NONE, STYLE_DEFAULT
export has, specified, with, without
export inheritable, resolve, parse_attrs

# events.jl
export Key, Modifier, Modifiers, MouseButton, MouseAction, Phase
export KeyEvent, MouseEvent, ResizeEvent, PasteEvent, FocusEvent
export TickEvent, RefreshEvent, QuitEvent
export MOD_NONE, key, is_scroll
export Dispatch, consume!, is_consumed, event, local_offset, on_event!

# boxmodel.jl
export Dimension, Length, AUTO, cells, pct, fr
export is_definite, definite_size
export BorderKind, Border, BORDER_NONE, border_glyphs, thickness
export Display, Direction, Justify, Align, Overflow
export BoxStyle, BOX_DEFAULT, BoxPatch, BOX_PATCH_NONE, apply
export LayoutBox, LAYOUT_BOX_EMPTY, layout_box
export box_overhead, outer_size

# buffer.jl
export Cell, CELL_BLANK, CELL_CONT, is_continuation
export Buffer, BufferView, buffer_size, buffer_region
export clear!, resize_buffer
export set_cell!, write_text!, fill_region!, style_region!, blit!
export ScrolledView, writable_region

# diff.jl
export Span, Patch, n_cells, diff, full_patch, apply!

# ansi.jl
export Ansi, AnsiEncoder, reset!, sgr!, encode!, encode

# input.jl
export parse_events, InputParser, feed!, flush_escape!, pending
export pump_input!

# driver.jl
export DriverCaps, CAPS_MINIMAL, DriverInterfaceError
export start!, stop!, restore!, emit!, flush!
export display_size, capabilities, events
export set_title!, notify_resize!
export REQUIRED_DRIVER_METHODS, check_driver_interface
export WEB_BRIDGE_SURFACE

# widget.jl
export Dirty, DirtyMask, DIRTY_ALL
export has_dirty, set_dirty, clear_dirty
export WidgetNode, node, id, classes, type_name, parent, children
export layout_of, region, content_region, computed_style, box
export is_visible, is_focusable, app
export mount!, insert_child!, unmount!, replace_child!
export root_of, ancestors, descendants, path_from_root
export walk, walk_visible
export add_class!, remove_class!, toggle_class!, has_class
export set_visible!, query, query_one
export on_mount!, on_unmount!, on_focus!, on_blur!
export mark_dirty!, mark_subtree_dirty!, mark!, escalate_auto!
export is_dirty, clean!, dirty_root
export scroll_of, set_scroll!, clamp_scroll, scroll_into_view
export paint_offset, painted_region, reveal!, reveal_child!

# reactive.jl
export Reactive, bind_owner!, attach_reactives!

# dispatch.jl
export propagation_path, hit_test, propagate!, dispatch_event!
export focusable_widgets

# layout.jl
export LayoutMap, measure
export flex_distribute, justify_offsets, cross_align
export compute_layout, apply_layout!, layout!, relayout!

# css.jl
export SelectorKind, Combinator, SimpleSelector, CompoundSelector
export Selector, Specificity, Rule, Stylesheet, STYLESHEET_EMPTY
export CssParseError, specificity, matches, parse_css, matching_rules
export cascade, apply_stylesheet!, recascade!, @css_str

# paint.jl
export render!, paint!, paint_border!

# headless.jl
export HeadlessDriver, push_event!, take_bytes!, output, clear_output!
export press!, type!, click!, resize!, feed_bytes!

# terminal.jl
export TerminalDriver, detect_caps, set_raw!

# widgets/
export Container, Label, Static, Button
export ScrollMode, ScrollAxis, Scrollpane, Scrollbar, viewport
export content_extent, max_scroll, scroll_to!, scroll_by!
export scroll_into_view!, thumb_span
export TextInput, TextArea, visible_scroll
export insert_text!, backspace!, delete_forward!, move_by!, move_to!
export insert_newline!, move_line!, set_text!, text, refresh_extent!
export should_suspend, OVERLAY_MIN_SIZE, MinSizeOverlay
export render_min_size_overlay!
# widgets/tablecore.jl
export SelectMode, SortDir, RowsWidget, Selection, Column, TableGrid
export selection_of, row_count, view_count, view_source, view_rank
export grid_of, is_focused
export select_mode, n_rows, row_cursor, row_anchor
export is_selected, n_selected, selected_rows
export resize_selection!, set_cursor!, move_cursor!, toggle_row!
export select_only!, sel_extend_ids!, select_all!, clear_selection!
export reindex_insert!, reindex_delete!
export TC_AUTO_SAMPLE, TC_ELLIPSIS, TC_RULE
export TC_SORT_ASC, TC_SORT_DESC
export TC_SELECTED, TC_CURSOR, TC_HEADER
# widgets/list.jl
export List, set_items!, push_item!, insert_item!, delete_item!
# widgets/table.jl
export Table, set_rows!, push_row!, insert_row!, delete_row!
export set_columns!, refresh_columns!, refresh_rows!
# widgets/datatable.jl
export DataTable, sort_by!, toggle_sort!
# widgets/toggle.jl
export CheckState, Checkbox, RadioGroup
export check_state, is_checked, set_state!, toggle!
export selected, selected_option, radio_cursor, choose!
# widgets/tabs.jl
export Tabs, TabStrip, n_tabs, tab_title, tab_panel
export add_tab!, select_tab!, tab_at
# widgets/tree.jl
export TreeNode, TreeRow, TreeView, is_leaf, is_expanded
export expand_node!, collapse_node!, toggle_node!, expand_all!, collapse_all!
export tree_rows, tree_cursor, node_at, set_roots!, refresh_tree!
# widgets/popup.jl + popup_ops.jl
export Popup, PopupPlacement, popup_region, on_popup_close!
export popup_of, open_popup!, close_popup!
# widgets/dropdown.jl
export DropDown, DropDownList, options, selected_item, is_open, set_open!
# widgets/form.jl
export Form, form_value, add_field!, field, submit!, form_values
export sort_column, sort_direction, source_index, sort_indicator

# app.jl
export AppConfig, App, run!, quit!, exit!, post!
export call_later!, set_interval!, invalidate!, pause!, resume!
export handle!, frame!, refresh!
export focused, focus!, focus_next!, focus_prev!, bind!, on_action

# backend.jl
export Backend, TerminalBackend, HeadlessBackend, make_driver, launch

end # module
