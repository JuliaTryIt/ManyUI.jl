# widgets_dropdown_tests.jl -- @testitem tests for src/widgets/dropdown.jl.
#
# Each block is self-contained and starts `using ManyUI`. No test needs a
# tty and none sleeps. Cell-level assertions PAINT into a headless Buffer
# (or the App's back buffer) and read the CELLS -- a test that only
# asserts "it did not throw" proves nothing.
#
# The open list rides the popup layer: `frame!` paints it OVER `app.root`
# and `handle!(app, ::MouseEvent)` hit-tests it BEFORE the root. These
# tests drive that real API.

@testitem "dropdown: closed, not greedy, panel unparented" begin
    using ManyUI
    dd = DropDown(["Small", "Medium", "Large"])
    @test !is_open(dd)
    @test selected(dd) == 0
    @test selected_item(dd) === nothing
    @test options(dd) == ["Small", "Medium", "Large"]
    # ALIASED, never copied.
    @test options(dd) === dd.panel.list.items

    # measure sizes to the WIDEST option plus the arrow, NEVER `avail`:
    # a greedy measure would shrink a Label beside it to zero rows.
    m = measure(dd, Size(80, 24))
    @test m == Size(text_width("Medium") + ManyUI.DD_ARROW_W, 1)
    @test m != Size(80, 24)

    # The panel is NOT a child of the DropDown and NOT in the tab order;
    # the inner list is machinery, not a tab stop.
    @test isempty(children(dd))
    @test length(focusable_widgets(dd)) == 1
    @test !ManyUI.node(dd.panel.list).focusable
    # The knot: panel points back at its owner, and it is UNPARENTED so
    # `open_popup!` will accept it as a second root.
    @test dd.panel.owner === dd
    @test ManyUI.parent(dd.panel) === nothing
end

@testitem "dropdown: DD_CLOSED and DD_OPEN are each width 1" begin
    using ManyUI
    # This is what licenses `open`'s PAINT reactivity: the arrow flips a
    # single cell and can never move the box.
    @test text_width(ManyUI.DD_CLOSED) == 1
    @test text_width(ManyUI.DD_OPEN) == 1
    @test ManyUI.DD_ARROW_W == 2
end

@testitem "dropdown: the closed head paints caption then arrow" begin
    using ManyUI
    dd = DropDown(["Small", "Medium", "Large"]; placeholder = "pick")
    apply_stylesheet!(STYLESHEET_EMPTY, dd)
    layout!(dd, Region(1, 1, 8, 1))
    buf = Buffer(8, 1)
    clear!(buf)
    render!(dd, buf)
    # placeholder while nothing is selected, arrow 'v' in the last cell.
    @test string(buf) == "pick   v"

    # A committed selection replaces the placeholder; the arrow stays.
    @test ManyUI._dd_select!(dd, 2)
    clear!(buf)
    render!(dd, buf)
    @test string(buf) == "Medium v"
end

@testitem "dropdown: an empty option list paints an arrow and cannot open" begin
    using ManyUI
    dd = DropDown(String[])
    @test measure(dd, Size(20, 4)) == Size(ManyUI.DD_ARROW_W, 1)
    apply_stylesheet!(STYLESHEET_EMPTY, dd)
    layout!(dd, Region(1, 1, 2, 1))
    buf = Buffer(2, 1)
    clear!(buf)
    render!(dd, buf)
    @test string(buf) == " v"
    # No App, no options: opening is a no-op, never a throw.
    @test !set_open!(dd, true)
    @test !is_open(dd)
end

@testitem "dropdown: closed UP/DOWN cycle the selection, fire on_change" begin
    using ManyUI
    hits = Int[]
    dd = DropDown(["a", "b", "c"], w -> push!(hits, selected(w)))
    key(s) = begin
        d = Dispatch(parse(KeyEvent, s), dd)
        d.phase = Phase.AT_TARGET
        on_event!(dd, d)
        d.consumed
    end
    @test key("down")            # 0 -> 1
    @test selected(dd) == 1
    @test key("down")            # 1 -> 2
    @test selected(dd) == 2
    @test key("up")              # 2 -> 1
    @test selected(dd) == 1
    @test !is_open(dd)           # cycling closed NEVER opens
    # at the top edge UP does not move and does NOT fire on_change.
    @test key("up")              # 1 -> clamp 1: consumed, unchanged
    @test selected(dd) == 1
    @test hits == [1, 2, 1]
end

@testitem "dropdown: closed SPACE is Key.SPACE and opens the list" begin
    using ManyUI
    # browser-lesson 1: byte 0x20 is Key.SPACE, NEVER Key.CHAR(' ').
    dd = DropDown(["x", "y", "z"])
    ap = App(dd, HeadlessDriver(Size(20, 10)))
    frame!(ap)                   # cascade + layout
    sp = parse(KeyEvent, "space")
    @test sp.code === Key.SPACE
    d = Dispatch(sp, dd)
    d.phase = Phase.AT_TARGET
    on_event!(dd, d)
    @test d.consumed
    @test is_open(dd)
    @test ManyUI.popup_of(ap) !== nothing
    @test ManyUI.popup_of(ap).owner === dd
end

@testitem "dropdown: a LEFT click opens the list, painted OVER the tree" begin
    using ManyUI
    dd = DropDown(["Small", "Medium", "Large"])
    marker = List(fill("XXXXXXXX", 9))          # fills every row below
    root = Container(dd, marker)
    ManyUI._sp_box!(root, ManyUI.BoxPatch(; display = Display.FLEX,
                                          direction = Direction.COLUMN))
    ManyUI._sp_box!(dd, ManyUI.BoxPatch(; shrink = 0f0, grow = 0f0))
    ManyUI._sp_box!(marker, ManyUI.BoxPatch(; grow = 1f0))
    ap = App(root, HeadlessDriver(Size(24, 8)))
    frame!(ap)
    below = split(string(ap.back), '\n')
    @test occursin("X", below[3])               # marker fills below

    # Click the head: it opens and the list paints over the marker.
    handle!(ap, MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                           1, 1, MOD_NONE))
    @test is_open(dd)
    frame!(ap)
    ls = split(string(ap.back), '\n')
    @test occursin("^", ls[1])                  # arrow flipped open
    # rows 2.. are the popup: the border and an option, NOT the marker.
    joined = join(ls[2:6], "\n")
    @test occursin("Small", joined)
    @test occursin("Medium", joined)
    # the popup is OPAQUE: at least one former-marker row shows no 'X'.
    @test any(r -> !occursin("X", r), ls[2:6])
end

@testitem "dropdown: keyboard DOWN highlights, ENTER commits and closes" begin
    using ManyUI
    hits = Int[]
    dd = DropDown(["Small", "Medium", "Large"],
                  w -> push!(hits, selected(w)))
    ap = App(Container(dd), HeadlessDriver(Size(20, 12)))
    frame!(ap)
    key(s) = (d = Dispatch(parse(KeyEvent, s), dd);
              d.phase = Phase.AT_TARGET; on_event!(dd, d); d.consumed)

    @test key("enter")           # closed ENTER opens
    @test is_open(dd)
    @test ManyUI.row_cursor(dd.panel.list) == 1   # cursor seeded at 1
    @test key("down")            # highlight -> 2
    @test ManyUI.row_cursor(dd.panel.list) == 2
    @test selected(dd) == 0      # NOT committed yet
    @test key("enter")           # commit the highlight
    @test !is_open(dd)
    @test selected(dd) == 2
    @test hits == [2]
    @test ManyUI.popup_of(ap) === nothing
end

@testitem "dropdown: open SPACE commits (Key.SPACE)" begin
    using ManyUI
    dd = DropDown(["a", "b", "c"])
    ap = App(Container(dd), HeadlessDriver(Size(20, 10)))
    frame!(ap)
    key(k) = (d = Dispatch(k, dd); d.phase = Phase.AT_TARGET;
              on_event!(dd, d); d.consumed)
    @test key(parse(KeyEvent, "down"))    # closed DOWN -> select 1
    @test set_open!(dd, true)
    @test key(parse(KeyEvent, "down"))    # highlight 2
    # browser-lesson 1: commit on Key.SPACE.
    @test key(parse(KeyEvent, "space"))
    @test !is_open(dd)
    @test selected(dd) == 2
end

@testitem "dropdown: ESCAPE closes WITHOUT changing the selection" begin
    using ManyUI
    dd = DropDown(["Small", "Medium", "Large"])
    ap = App(Container(dd), HeadlessDriver(Size(20, 12)))
    frame!(ap)
    key(s) = (d = Dispatch(parse(KeyEvent, s), dd);
              d.phase = Phase.AT_TARGET; on_event!(dd, d); d.consumed)
    # commit Medium first.
    set_open!(dd, true)
    key("down")                  # highlight 2
    key("enter")                 # commit 2
    @test selected(dd) == 2

    # reopen, browse away, ESCAPE: selection is KEPT, highlight abandoned.
    set_open!(dd, true)
    @test ManyUI.row_cursor(dd.panel.list) == 2   # seeded at committed
    key("down")                  # highlight 3
    @test ManyUI.row_cursor(dd.panel.list) == 3
    @test key("escape")
    @test !is_open(dd)
    @test selected(dd) == 2      # UNCHANGED
    # click-away/escape revert the browse cursor to the committed row.
    @test ManyUI.row_cursor(dd.panel.list) == 2
end

@testitem "dropdown: a row click commits and closes" begin
    using ManyUI
    hits = Int[]
    dd = DropDown(["Small", "Medium", "Large"],
                  w -> push!(hits, selected(w)))
    ap = App(Container(dd), HeadlessDriver(Size(24, 10)))
    frame!(ap)
    set_open!(dd, true)
    frame!(ap)                   # lay the popup out so hit-test works
    p = ManyUI.popup_of(ap)
    @test p !== nothing
    r = ManyUI.painted_region(p.content)
    # click the SECOND visible row inside the border (row r.y + 2).
    handle!(ap, MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                           r.x + 1, r.y + 2, MOD_NONE))
    @test !is_open(dd)
    @test selected(dd) == 2
    @test hits == [2]
end

@testitem "dropdown: a press OUTSIDE closes it and is SWALLOWED" begin
    using ManyUI
    clicks = Ref(0)
    dd = DropDown(["Small", "Medium", "Large"])
    btn = Button("go", _ -> clicks[] += 1)
    root = Container(dd, btn)
    ManyUI._sp_box!(root, ManyUI.BoxPatch(; display = Display.FLEX,
                                          direction = Direction.COLUMN))
    ManyUI._sp_box!(dd, ManyUI.BoxPatch(; shrink = 0f0, grow = 0f0))
    # push the button to the very bottom, clear of the popup.
    ManyUI._sp_box!(btn, ManyUI.BoxPatch(; grow = 1f0))
    ap = App(root, HeadlessDriver(Size(24, 12)))
    frame!(ap)
    set_open!(dd, true)
    frame!(ap)
    p = ManyUI.popup_of(ap)
    br = ManyUI.painted_region(btn)
    # a cell on the button, BELOW the popup: outside the list.
    ex, ey = br.x, ManyUI.bottom(br)
    @test !(ManyUI.Offset(ex, ey) in ManyUI.painted_region(p.content))
    handle!(ap, MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                           ex, ey, MOD_NONE))
    @test !is_open(dd)           # the press closed it
    @test clicks[] == 0          # ...and was SWALLOWED: btn never fired
    # a SECOND press now reaches the button.
    handle!(ap, MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                           ex, ey, MOD_NONE))
    @test clicks[] == 1
end

@testitem "dropdown: a wheel notch over the open list does NOT dismiss" begin
    using ManyUI
    # browser-lesson: a wheel notch is MouseAction.PRESS with a WHEEL_*
    # button; `_popup_dismiss!` tests `is_scroll` FIRST, so scrolling
    # does not close the list.
    dd = DropDown(["i$i" for i in 1:20]; max_rows = 4)
    ap = App(Container(dd), HeadlessDriver(Size(24, 12)))
    frame!(ap)
    set_open!(dd, true)
    frame!(ap)
    handle!(ap, MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_DOWN,
                           2, 3, MOD_NONE))
    @test is_open(dd)            # still open after a scroll notch
end

@testitem "dropdown: near the BOTTOM edge the list flips ABOVE the head" begin
    using ManyUI
    dd = DropDown(["Small", "Medium", "Large"])
    spacer = List(fill("....", 20))
    root = Container(spacer, dd)   # dd is the LAST row
    ManyUI._sp_box!(root, ManyUI.BoxPatch(; display = Display.FLEX,
                                          direction = Direction.COLUMN))
    ManyUI._sp_box!(spacer, ManyUI.BoxPatch(; grow = 1f0))
    ManyUI._sp_box!(dd, ManyUI.BoxPatch(; shrink = 0f0, grow = 0f0))
    ap = App(root, HeadlessDriver(Size(24, 8)))
    frame!(ap)
    hr = ManyUI.region(dd)
    @test hr.y == 8               # head on the last screen row
    set_open!(dd, true)
    frame!(ap)
    p = ManyUI.popup_of(ap)
    pr = ManyUI.painted_region(p.content)
    # BELOW did not fit, so the popup flips ABOVE: it ends above the head
    # and stays on screen.
    @test ManyUI.bottom(pr) < hr.y
    @test pr.y >= 1
    ls = split(string(ap.back), '\n')
    @test occursin("Small", join(ls[1:7], "\n"))
end

@testitem "dropdown: opening the second dropdown closes the first" begin
    using ManyUI
    dd1 = DropDown(["a", "b"])
    dd2 = DropDown(["c", "d"])
    root = Container(dd1, dd2)
    ManyUI._sp_box!(root, ManyUI.BoxPatch(; display = Display.FLEX,
                                          direction = Direction.COLUMN))
    ap = App(root, HeadlessDriver(Size(24, 12)))
    frame!(ap)
    @test set_open!(dd1, true)
    @test is_open(dd1)
    # opening dd2 tears down the incumbent FIRST -> dd1 is notified.
    @test set_open!(dd2, true)
    @test is_open(dd2)
    @test !is_open(dd1)
    @test ManyUI.popup_of(ap).owner === dd2
end

@testitem "dropdown: on_blur and on_unmount close the popup" begin
    using ManyUI
    dd = DropDown(["a", "b", "c"])
    other = Button("x", ManyUI._tc_noop)
    root = Container(dd, other)
    ap = App(root, HeadlessDriver(Size(24, 10)))
    frame!(ap)

    set_open!(dd, true)
    @test is_open(dd)
    # moving focus away blurs the owner, which closes its popup.
    ManyUI.focus!(ap, other)
    @test !is_open(dd)
    @test ManyUI.popup_of(ap) === nothing

    # and unmounting a still-open dropdown closes it, never leaks it.
    set_open!(dd, true)
    @test is_open(dd)
    ManyUI.unmount!(dd)
    @test !is_open(dd)
    @test ManyUI.popup_of(ap) === nothing
end

@testitem "dropdown: set_items! closes, clears the selection, resizes" begin
    using ManyUI
    dd = DropDown(["Small", "Medium", "Large"])
    ap = App(Container(dd), HeadlessDriver(Size(20, 10)))
    frame!(ap)
    @test ManyUI._dd_select!(dd, 3)
    @test selected(dd) == 3
    set_open!(dd, true)
    @test is_open(dd)

    set_items!(dd, ["Tiny", "Enormous"])
    @test !is_open(dd)                 # closed first
    @test selected(dd) == 0            # selection cleared
    @test options(dd) == ["Tiny", "Enormous"]
    # measure now reflects the new widest option.
    @test measure(dd, Size(80, 24)) ==
          Size(text_width("Enormous") + ManyUI.DD_ARROW_W, 1)
end

@testitem "dropdown: TAB is left unconsumed so the tab order survives" begin
    using ManyUI
    dd = DropDown(["a", "b", "c"])
    ap = App(Container(dd), HeadlessDriver(Size(24, 10)))
    frame!(ap)
    set_open!(dd, true)
    # TAB must NOT be consumed: a control that eats TAB traps focus.
    d = Dispatch(parse(KeyEvent, "tab"), dd)
    d.phase = Phase.AT_TARGET
    on_event!(dd, d)
    @test !d.consumed
    # a modified key is likewise left alone.
    d2 = Dispatch(parse(KeyEvent, "ctrl+a"), dd)
    d2.phase = Phase.AT_TARGET
    on_event!(dd, d2)
    @test !d2.consumed
end

@testitem "dropdown: the head keeps focus while open (not a focus layer)" begin
    using ManyUI
    dd = DropDown(["a", "b", "c"])
    ap = App(Container(dd), HeadlessDriver(Size(24, 10)))
    frame!(ap)
    set_open!(dd, true)
    # the popup content is UNPARENTED and NOT focusable: the DropDown
    # keeps focus and forwards, exactly as an HTML <select> does.
    @test ManyUI.focused(ap) === dd
    @test length(focusable_widgets(ap.root)) == 1
end
