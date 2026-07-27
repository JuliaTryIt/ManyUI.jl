module ManyUI

using DocStringExtensions

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
include("widget.jl")

include("widgets/container.jl")
include("widgets/label.jl")
include("widgets/button.jl")
include("widgets/scroll.jl")
include("widgets/textinput.jl")
include("widgets/textarea.jl")
include("widgets/tablecore.jl")
include("widgets/list.jl")
include("widgets/table.jl")
include("widgets/datatable.jl")
include("widgets/overlay.jl")
include("widgets/toggle.jl")
include("widgets/tabs.jl")
include("widgets/tree.jl")
include("widgets/popup.jl")
include("widgets/dropdown.jl")
include("widgets/form.jl")

# core.jl
export Projection, CLI, TUI, WebTerminal, WebNative
export Action, execute!, render

# types.jl
export Widget, Driver, AbstractApp, Event

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
export List, set_items!, push_item!, insert_item!, delete_item!
export Table, set_rows!, push_row!, insert_row!, delete_row!
export set_columns!, refresh_columns!, refresh_rows!
export DataTable, sort_by!, toggle_sort!
export CheckState, Checkbox, RadioGroup
export check_state, is_checked, set_state!, toggle!
export selected, selected_option, radio_cursor, choose!
export Tabs, TabStrip, n_tabs, tab_title, tab_panel
export add_tab!, select_tab!, tab_at
export TreeNode, TreeRow, TreeView, is_leaf, is_expanded
export expand_node!, collapse_node!, toggle_node!, expand_all!, collapse_all!
export tree_rows, tree_cursor, node_at, set_roots!, refresh_tree!
export Popup, PopupPlacement, popup_region, on_popup_close!
export popup_of, open_popup!, close_popup!
export DropDown, DropDownList, options, selected_item, is_open, set_open!
export Form, form_value, add_field!, field, submit!, form_values
export sort_column, sort_direction, source_index, sort_indicator

end # module
