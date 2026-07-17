# widgets_tabs_tests.jl -- the tab strip plus panels (layer 7).
#
# Every testitem is self-contained, starts `using DualUI`, needs no tty
# and never sleeps.
#
# A CAPTION IS NOT A WIDGET: captions are `String`s and panels are
# children. The two facts the suite pins are that an INACTIVE panel
# paints NOTHING, costs no layout space, is out of the tab order and is
# unclickable -- all four from one `set_visible!(false)` -- and that the
# strip SIZES TO CONTENT so a neighbour is never shrunk to zero.
#
# `Base.textwidth` appears nowhere: captions truncate on a grapheme
# boundary through `_tc_slice!`, never by halving a wide cluster.

@testitem "tabs: construction, aliasing and focus wiring" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    @test t isa Widget
    @test type_name(t) === :Tabs
    # `Tabs` itself is NOT focusable -- its strip is.
    @test !is_focusable(t)
    @test is_focusable(t.strip)
    @test type_name(t.strip) === :TabStrip
    # The strip's titles are the source of truth and are ALIASED.
    @test t.strip.titles == ["One", "Two"]
    @test n_tabs(t) == 2
    @test tab_title(t, 1) == "One"
    @test tab_title(t, 2) == "Two"
    # The strip is child 1; panels follow.
    @test children(t)[1] === t.strip
    @test tab_panel(t, 1) === children(t)[2]
    @test tab_panel(t, 2) === children(t)[3]
end

@testitem "tabs: add_tab! selects the FIRST tab and no other" begin
    using DualUI
    t = Tabs()
    @test selected(t) == 0
    i = add_tab!(t, "One", Static("A"))
    @test i == 1
    @test selected(t) == 1
    j = add_tab!(t, "Two", Static("B"))
    @test j == 2
    # Adding a second tab must NOT steal the selection.
    @test selected(t) == 1
    # The first panel is visible, the second is not.
    @test is_visible(tab_panel(t, 1))
    @test !is_visible(tab_panel(t, 2))
end

@testitem "tabs: an empty Tabs has selected == 0 and does not throw" begin
    using DualUI
    t = Tabs()
    @test n_tabs(t) == 0
    @test selected(t) == 0
    @test measure(t.strip, Size(80, 24)) === Size(0, 1)
    # Every navigation on nothing is a no-op that consumes nothing.
    for k in ("left", "right", "home", "end", "1")
        d = Dispatch(parse(KeyEvent, k), t.strip)
        d.phase = Phase.AT_TARGET
        on_event!(t.strip, d)
        @test !is_consumed(d)
    end
    @test !select_tab!(t, 1)
    @test selected(t) == 0
    # It paints nothing rather than throwing.
    apply_stylesheet!(STYLESHEET_EMPTY, t.strip)
    layout!(t.strip, Region(1, 1, 4, 1))
    buf = Buffer(4, 1)
    clear!(buf)
    render!(t.strip, buf)
    @test string(buf) == "    "
end

@testitem "tabs: measure is NOT avail" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    m = measure(t.strip, Size(80, 24))
    # A strip that returned `avail` would demand the whole viewport and
    # shrink its neighbours to zero. It is exactly as wide as its
    # captions and exactly one row tall.
    @test m.width < 80
    @test m.width == (3 + 2 * DualUI.TABS_PAD) * 2   # " One " + " Two "
    @test m.height == 1
end

@testitem "tabs: tab_at is pure over titles" begin
    using DualUI
    # A table test: a `Vector{String}` and an `Int`, no widget, no
    # layout, no buffer. Captions abut with no separator; " One " is
    # columns 1-5, " Two " is 6-10.
    titles = ["One", "Two"]
    @test tab_at(titles, 0) == 0
    @test tab_at(titles, 1) == 1
    @test tab_at(titles, 5) == 1
    @test tab_at(titles, 6) == 2
    @test tab_at(titles, 10) == 2
    @test tab_at(titles, 11) == 0
    @test tab_at(titles, 100) == 0
    @test tab_at(String[], 1) == 0
    # A wide cluster is never halved: an emoji caption is TWO cells wide
    # plus its padding, and `tab_at` walks the same running sum.
    wide = ["🚀", "x"]
    @test tab_at(wide, 1) == 1
    @test tab_at(wide, 4) == 1        # " 🚀 " is columns 1-4
    @test tab_at(wide, 5) == 2        # " x " is columns 5-7
    @test tab_at(wide, 7) == 2
end

@testitem "tabs: the active caption is REVERSED and the others are not" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    apply_stylesheet!(STYLESHEET_EMPTY, t.strip)
    layout!(t.strip, Region(1, 1, 10, 1))
    buf = Buffer(10, 1)
    clear!(buf)
    render!(t.strip, buf)
    @test string(buf) == " One  Two "
    # Tab 1 is selected, so its whole caption cell -- padding and all --
    # carries REVERSE; tab 2 does not.
    @test has(buf[2, 1].style, Attr.REVERSE)    # 'O' of " One "
    @test has(buf[1, 1].style, Attr.REVERSE)    # the leading pad
    @test !has(buf[7, 1].style, Attr.REVERSE)   # 'T' of " Two "

    @test select_tab!(t, 2)
    clear!(buf)
    render!(t.strip, buf)
    @test !has(buf[2, 1].style, Attr.REVERSE)
    @test has(buf[7, 1].style, Attr.REVERSE)    # now tab 2 is active
end

@testitem "tabs: the focused strip underlines" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    apply_stylesheet!(STYLESHEET_EMPTY, t.strip)
    layout!(t.strip, Region(1, 1, 10, 1))
    buf = Buffer(10, 1)
    t.strip.focused[] = true
    clear!(buf)
    render!(t.strip, buf)
    # The unselected caption still shows the FOCUS underline.
    @test has(buf[7, 1].style, Attr.UNDERLINE)
end

@testitem "tabs: '2' selects tab 2" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"),
             "Three" => Static("C"))
    # `key('2')` is `Key.CHAR`, not a `Key.TWO` -- there is no such key.
    e = parse(KeyEvent, "2")
    @test e.code === Key.CHAR
    @test e.char == '2'
    d = Dispatch(e, t.strip)
    d.phase = Phase.AT_TARGET
    on_event!(t.strip, d)
    @test is_consumed(d)
    @test selected(t) == 2
    # Re-pressing the same ordinal moves nothing and consumes nothing.
    d2 = Dispatch(parse(KeyEvent, "2"), t.strip)
    d2.phase = Phase.AT_TARGET
    on_event!(t.strip, d2)
    @test !is_consumed(d2)
end

@testitem "tabs: LEFT/RIGHT/HOME/END move and clamp" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"),
             "Three" => Static("C"))
    key(k) = (d = Dispatch(parse(KeyEvent, k), t.strip);
              d.phase = Phase.AT_TARGET;
              on_event!(t.strip, d); is_consumed(d))
    @test selected(t) == 1
    @test key("right")
    @test selected(t) == 2
    @test key("end")
    @test selected(t) == 3
    @test key("left")
    @test selected(t) == 2
    @test key("home")
    @test selected(t) == 1
end

@testitem "tabs: RIGHT on the LAST tab does NOT consume" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    @test select_tab!(t, 2)
    d = Dispatch(parse(KeyEvent, "right"), t.strip)
    d.phase = Phase.AT_TARGET
    on_event!(t.strip, d)
    # Clamped, no wrap: nothing moved, so the key bubbles to an outer
    # pane rather than being swallowed.
    @test !is_consumed(d)
    @test selected(t) == 2
end

@testitem "tabs: LEFT on the FIRST tab does NOT consume" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    @test selected(t) == 1
    d = Dispatch(parse(KeyEvent, "left"), t.strip)
    d.phase = Phase.AT_TARGET
    on_event!(t.strip, d)
    @test !is_consumed(d)
    @test selected(t) == 1
end

@testitem "tabs: a TabStrip does not consume tab" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    for k in ("tab", "shift+tab", "escape", "ctrl+right", "a")
        d = Dispatch(parse(KeyEvent, k), t.strip)
        d.phase = Phase.AT_TARGET
        on_event!(t.strip, d)
        # A strip that ate TAB would trap focus forever. It consumes
        # ONLY the keys it handles.
        @test !is_consumed(d)
    end
    @test selected(t) == 1
end

@testitem "tabs: clicking a caption selects it" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    apply_stylesheet!(STYLESHEET_EMPTY, t)
    layout!(t, Region(1, 1, 10, 4))
    # " One " is columns 1-5, " Two " is 6-10. A press on column 7 lands
    # on tab 2.
    @test dispatch_event!(t.strip, MouseEvent(MouseAction.PRESS,
                                              MouseButton.LEFT, 7, 1,
                                              MOD_NONE))
    @test selected(t) == 2
    # A press on the ALREADY-active tab moves nothing and consumes
    # nothing.
    @test !dispatch_event!(t.strip, MouseEvent(MouseAction.PRESS,
                                               MouseButton.LEFT, 8, 1,
                                               MOD_NONE))
    @test selected(t) == 2
    # A press past the last caption hits no tab.
    @test !dispatch_event!(t.strip, MouseEvent(MouseAction.PRESS,
                                               MouseButton.LEFT, 10, 1,
                                               MOD_NONE)) ||
          selected(t) == 2
end

@testitem "tabs: a scrolled Scrollpane clicks the RIGHT caption" begin
    using DualUI
    # The `_tc_local`-vs-`local_offset` bug, as a test: with the strip
    # scrolled down, a click's ABSOLUTE row must map back to the strip's
    # OWN row through `paint_offset`, not the unshifted border box.
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    pads = [Static("pad$i") for i in 1:8]
    tall = Container(pads..., t)
    node(tall).inline_box = BoxPatch(; display = Display.FLEX,
                                     direction = Direction.COLUMN)
    pane = Scrollpane(tall)
    ap = App(pane, HeadlessDriver(Size(20, 5)))
    frame!(ap)
    before = painted_region(t.strip)
    # Scroll the content so the strip moves UP by a real, nonzero delta.
    @test scroll_to!(pane, Offset(0, 4)).y == 4
    frame!(ap)
    r = painted_region(t.strip)
    @test r.y < before.y                 # the anchor actually moved
    # A press at the strip's NEW absolute position on column 7 must
    # select tab 2 -- `_tc_local` honours the scroll where `local_offset`
    # would read the wrong row.
    @test dispatch_event!(t.strip, MouseEvent(MouseAction.PRESS,
                                              MouseButton.LEFT,
                                              r.x + 6, r.y, MOD_NONE))
    @test selected(t) == 2
end

@testitem "tabs: an inactive panel paints NOTHING" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    node(t).inline_box = BoxPatch(; display = Display.FLEX,
                                  direction = Direction.COLUMN)
    ap = App(t, HeadlessDriver(Size(24, 6)))
    frame!(ap)
    s = string(ap.back)
    # Tab 1 is active: the panel shows 'A' and the inactive panel's 'B'
    # appears NOWHERE -- not painted under the active one, not leaked.
    @test occursin("A", s)
    @test !occursin("B", s)

    @test select_tab!(t, 2)
    frame!(ap)
    s2 = string(ap.back)
    @test occursin("B", s2)
    @test !occursin("A", s2)
end

@testitem "tabs: an inactive panel's TextInput is NOT in the tab order" begin
    using DualUI
    a = TextInput("a")
    b = TextInput("b")
    t = Tabs("One" => a, "Two" => b)
    node(t).inline_box = BoxPatch(; display = Display.FLEX,
                                  direction = Direction.COLUMN)
    fw = focusable_widgets(t)
    # The strip and the ACTIVE panel's input are reachable; the inactive
    # panel's input is not -- the one a hand-rolled strip always gets
    # wrong.
    @test t.strip in fw
    @test a in fw
    @test !(b in fw)
    # Switching tabs swaps which input is in the order.
    @test select_tab!(t, 2)
    fw2 = focusable_widgets(t)
    @test b in fw2
    @test !(a in fw2)
end

@testitem "tabs: hit_test cannot reach an inactive panel" begin
    using DualUI
    t = Tabs("One" => Static("AAAA"), "Two" => Static("BBBB"))
    node(t).inline_box = BoxPatch(; display = Display.FLEX,
                                  direction = Direction.COLUMN)
    ap = App(t, HeadlessDriver(Size(24, 6)))
    frame!(ap)
    p2 = tab_panel(t, 2)
    hit = hit_test(t, 1, 2)     # a panel row
    @test hit !== nothing
    # The inactive panel is invisible, so it is unreachable.
    @test hit !== p2
    @test !(p2 in ancestors(hit)) && hit !== p2

    @test select_tab!(t, 2)
    frame!(ap)
    p1 = tab_panel(t, 1)
    hit2 = hit_test(t, 1, 2)
    @test hit2 !== p1
end

@testitem "tabs: a Tabs beside a one-row Label leaves the Label ONE row" begin
    using DualUI
    # Browser-lesson 2: a greedy `measure` would shrink the Label to a
    # ZERO-row label and make it vanish. `Tabs` sizes to content.
    lbl = Label("ZZ")
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    root = Container(lbl, t)
    node(root).inline_box = BoxPatch(; display = Display.FLEX,
                                     direction = Direction.COLUMN)
    ap = App(root, HeadlessDriver(Size(24, 6)))
    frame!(ap)
    s = string(ap.back)
    # The Label survives with its content intact.
    @test occursin("ZZ", s)
    @test region(lbl).height == 1
end

@testitem "tabs: mount! on a Tabs throws" begin
    using DualUI
    t = Tabs("One" => Static("A"))
    # A panel is added with `add_tab!`, never `mount!` -- the latter
    # would leave the strip's titles and the children out of step.
    @test_throws ArgumentError mount!(t, Static("rogue"))
end

@testitem "tabs: a bare TabStrip with no Tabs parent is INERT" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    strip = t.strip
    # Detach the strip so it has no `Tabs` parent, then drive it: a
    # parentless strip is a legal, if useless, widget and must not throw.
    unmount!(strip)
    @test parent(strip) === nothing
    d = Dispatch(parse(KeyEvent, "right"), strip)
    d.phase = Phase.AT_TARGET
    on_event!(strip, d)                 # must not throw
    @test !is_consumed(d)
    @test !dispatch_event!(strip, MouseEvent(MouseAction.PRESS,
                                             MouseButton.LEFT, 2, 1,
                                             MOD_NONE))
end

@testitem "tabs: select_tab! clamps and reports movement" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"),
             "Three" => Static("C"))
    @test !select_tab!(t, 1)            # already there
    @test select_tab!(t, 3)
    @test selected(t) == 3
    @test !select_tab!(t, 99)           # clamped to 3, no move
    @test selected(t) == 3
    @test select_tab!(t, -5)            # clamped to 1, a real move
    @test selected(t) == 1
    # `_tb_sync!` keeps exactly the selected panel visible.
    @test is_visible(tab_panel(t, 1))
    @test !is_visible(tab_panel(t, 2))
    @test !is_visible(tab_panel(t, 3))
end

@testitem "tabs: a strip too narrow truncates its captions, never scrolls" begin
    using DualUI
    t = Tabs("One" => Static("A"), "Two" => Static("B"))
    apply_stylesheet!(STYLESHEET_EMPTY, t.strip)
    layout!(t.strip, Region(1, 1, 6, 1))
    buf = Buffer(6, 1)
    clear!(buf)
    render!(t.strip, buf)
    # Six cells hold " One " and the start of " Two "; it is cut at the
    # right edge, not scrolled.
    @test string(buf) == " One  "
end

@testitem "tabs: tab_title throws on a bad index" begin
    using DualUI
    t = Tabs("One" => Static("A"))
    # A caller naming a tab that does not exist has a bug.
    @test_throws BoundsError tab_title(t, 2)
    @test_throws BoundsError tab_title(t, 0)
end
