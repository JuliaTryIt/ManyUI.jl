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
using Markdown
using JuliaSyntaxHighlighting
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
include("theme.jl")
include("richtext.jl")
include("events.jl")
include("boxmodel.jl")
include("widget.jl")
include("reactive.jl")
include("dispatch.jl")
include("layout.jl")
include("css.jl")
include("widgets/container.jl")
include("widgets/label.jl")
include("widgets/button.jl")
include("widgets/progressbar.jl")
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
include("widgets/error_boundary.jl")
# `toggle.jl` defines `Checkbox`/`RadioGroup`, `tabs.jl` defines `Tabs`,
# `tree.jl` defines `TreeView` (needs `tablecore.jl`). `popup.jl` defines
# the `Popup` value BEFORE app.jl, because `App` carries an `App.popup`
# field; `dropdown.jl` opens one (`DropDown` needs the popup layer) and
# `form.jl` USES `Checkbox`/`RadioGroup`/`DropDown`/`Tabs`, so both come
# after. The App-facing popup verbs are in `popup_ops.jl`, AFTER app.jl.
include("widgets/toggle.jl")
include("widgets/tabs.jl")
include("widgets/tree.jl")
include("widgets/spinner.jl")
include("widgets/slider.jl")
include("widgets/popup.jl")
include("widgets/dropdown.jl")
include("widgets/sparkline.jl")
include("widgets/progresslist.jl")
include("widgets/statusbar.jl")
include("widgets/splitter.jl")
include("widgets/markdownpane.jl")
include("widgets/codeeditor.jl")
include("widgets/dialog.jl")
include("widgets/form.jl")
include("precompile.jl")

# core.jl
export Projection, CLI, TUI, WebTerminal, WebNative
export backend_available, backend_kind, backend_capabilities
export Action, execute!, render, post!

# types.jl
export Widget, Event

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
export to_rgb, luminance, color_distance, is_token
export rgb_to_ansi256, ansi256_to_ansi16, rgb_to_ansi16
export degrade, detect_color_depth

# style.jl
export Attr, AttrMask, Style, STYLE_NONE, STYLE_DEFAULT
export has, specified, with, without
export inheritable, resolve, parse_attrs

# theme.jl
export Theme, theme, set_theme!, register_theme!, themes
export token, token_name, token_names, register_token!, theme_color
export resolve_token

# richtext.jl
export TextRun, RichText, TextLike, RICHTEXT_EMPTY, plain

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

# widget.jl
export Dirty, DirtyMask, DIRTY_ALL
export has_dirty, set_dirty, clear_dirty
export WidgetNode, node, id, classes, type_name, parent, children
export layout_of, region, content_region, computed_style, box
export is_visible, is_focusable, app
export border_title, border_title_align
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
export focusable_widgets, focus!

# layout.jl
export LayoutMap, measure
export flex_distribute, justify_offsets, cross_align
export compute_layout, apply_layout!, layout!, relayout!

# css.jl
export SelectorKind, Combinator, SimpleSelector, CompoundSelector
export Selector, Specificity, Rule, Stylesheet, STYLESHEET_EMPTY
export CssParseError, specificity, matches, parse_css, matching_rules
export cascade, apply_stylesheet!, recascade!, @css_str

# widgets/
export Container, Label, Static, Button
export ScrollMode, ScrollAxis, Scrollpane, Scrollbar, viewport
export content_extent, max_scroll, scroll_to!, scroll_by!
export scroll_into_view!, thumb_span
export TextInput, TextArea, visible_scroll
export insert_text!, backspace!, delete_forward!, move_by!, move_to!
export insert_newline!, move_line!, set_text!, text, refresh_extent!
export should_suspend, OVERLAY_MIN_SIZE, MinSizeOverlay
export ErrorBoundary
# widgets/progressbar.jl
export ProgressBar, progress_cells, PROGRESS_FILL
# widgets/sparkline.jl
export Sparkline, SPARK_GLYPHS, SPARK_FLAT, push_value!, set_values!, n_values
export spark_bounds, spark_level

# widgets/statusbar.jl
export StatusBar, segments, status_layout

# widgets/progresslist.jl
export ProgressList, ProgressItem, n_items, set_progress!
export pl_label_width, PL_GAP, PL_MIN_BAR

# widgets/codeeditor.jl
export CodeEditor, code_lines, highlight_julia, code_face_style
export CODE_FACES

# widgets/markdownpane.jl
export MarkdownPane, set_source!, md_lines, md_inline
export MD_HEADING, MD_CODE, MD_QUOTE, MD_LINK, MD_MARKER

# widgets/dialog.jl
export Dialog, dialog_size, DIALOG_PAD, DIALOG_BUTTON_GAP

# widgets/spinner.jl
export Spinner
# widgets/slider.jl
export Slider
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
# widgets/splitter.jl
export Splitter, SplitHandle, panes, handles, pane_count
export weights_of, set_weights!, is_horizontal
export SPLIT_MIN_PANE

# widgets/tree.jl
export TreeNode, TreeRow, TreeView, is_leaf, is_expanded
export expand_node!, collapse_node!, toggle_node!, expand_all!, collapse_all!
export tree_rows, tree_cursor, node_at, set_roots!, refresh_tree!
# widgets/popup.jl
export Popup, PopupPlacement, MODAL_DIM, popup_region, popup_of, open_popup!, close_popup!, on_popup_close!
# widgets/dropdown.jl
export DropDown, DropDownList, options, selected_item, is_open, set_open!
# widgets/form.jl
export Form, form_value, add_field!, field, submit!, form_values
export sort_column, sort_direction, source_index, sort_indicator

# immediate.jl
include("immediate.jl")
export Immediate

end # module
