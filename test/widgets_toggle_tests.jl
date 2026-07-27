# widgets_toggle_tests.jl -- Checkbox and RadioGroup (layer 7).
#
# Every testitem is self-contained, starts `using ManyUI`, needs no tty
# and never sleeps.
#
# THE SPACE BAR IS `Key.SPACE`, NOT `Key.CHAR(' ')`. The input parser
# emits `Key.SPACE` for byte 0x20 and NEVER `Key.CHAR(' ')`; a checkbox
# that toggles only on `e.char == ' '` is a checkbox with a dead space
# bar. Both forms are pressed below, and the `Key.SPACE` form is the one
# that has shipped broken before.
#
# A test that builds a widget and asserts it did not throw proves
# NOTHING. These paint into a headless `Buffer` and assert the CELLS.

@testitem "toggle: a checkbox is focusable and starts unchecked" begin
    using ManyUI
    cb = Checkbox("Accept")
    @test cb isa Widget
    @test type_name(cb) === :Checkbox
    @test is_focusable(cb)
    @test cb in focusable_widgets(cb)
    @test check_state(cb) === CheckState.UNCHECKED
    @test !is_checked(cb)
    @test cb.label[] == "Accept"
end

@testitem "toggle: a checkbox seeds its state at construction" begin
    using ManyUI
    @test check_state(Checkbox("x"; state = CheckState.CHECKED)) ===
        CheckState.CHECKED
    @test check_state(Checkbox("x"; state = CheckState.MIXED)) ===
        CheckState.MIXED
    @test is_checked(Checkbox("x"; state = CheckState.CHECKED))
end

@testitem "toggle: ids are unique by default, settable by hand" begin
    using ManyUI
    @test id(Checkbox("a")) !== id(Checkbox("a"))
    @test id(Checkbox("a"; id = :fixed)) === :fixed
    @test id(RadioGroup(["a"])) !== id(RadioGroup(["a"]))
    @test id(RadioGroup(["a"]; id = :rg)) === :rg
end

@testitem "toggle: all five glyphs are exactly CB_WIDTH cells" begin
    using ManyUI
    # LOAD-BEARING, not tidiness: equal widths are what make `measure`
    # independent of `state`, which is what LICENSES `state`'s
    # `Dirty.PAINT` reactivity. A width-1 "check" against a width-3
    # "[ ]" would make a click a LAYOUT pass.
    @test ManyUI.CB_WIDTH == 3
    for g in (ManyUI.CB_UNCHECKED, ManyUI.CB_CHECKED, ManyUI.CB_MIXED,
              ManyUI.RB_ON, ManyUI.RB_OFF)
        @test text_width(g) == ManyUI.CB_WIDTH
    end
end

@testitem "toggle: an unchecked checkbox paints [ ] and its caption" begin
    using ManyUI
    cb = Checkbox("Accept")
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 20, 1))
    buf = Buffer(20, 1)
    clear!(buf)
    render!(cb, buf)
    @test buf[1, 1].content == "["
    @test buf[2, 1].content == " "
    @test buf[3, 1].content == "]"
    @test buf[4, 1].content == " "        # CB_GAP
    @test buf[5, 1].content == "A"
    @test buf[6, 1].content == "c"
end

@testitem "toggle: a checked checkbox paints [x]" begin
    using ManyUI
    cb = Checkbox("Accept"; state = CheckState.CHECKED)
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 20, 1))
    buf = Buffer(20, 1)
    clear!(buf)
    render!(cb, buf)
    @test buf[1, 1].content == "["
    @test buf[2, 1].content == "x"
    @test buf[3, 1].content == "]"
end

@testitem "toggle: a mixed checkbox paints [-]" begin
    using ManyUI
    cb = Checkbox("Accept"; state = CheckState.MIXED)
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 20, 1))
    buf = Buffer(20, 1)
    clear!(buf)
    render!(cb, buf)
    @test buf[2, 1].content == "-"
end

@testitem "toggle: a bare checkbox paints only its box" begin
    using ManyUI
    cb = Checkbox("")
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 6, 1))
    buf = Buffer(6, 1)
    clear!(buf)
    render!(cb, buf)
    @test string(buf) == "[ ]   "
end

@testitem "toggle: SPACE via Key.SPACE toggles the checkbox" begin
    using ManyUI
    # The adversarial case. `Key.SPACE`, NOT `Key.CHAR(' ')`, is what the
    # parser emits for the space bar; this is the press that has shipped
    # dead before.
    cb = Checkbox("x")
    d = Dispatch(key(Key.SPACE), cb)
    d.phase = Phase.AT_TARGET
    on_event!(cb, d)
    @test check_state(cb) === CheckState.CHECKED
    @test is_consumed(d)
    d2 = Dispatch(key(Key.SPACE), cb)
    d2.phase = Phase.AT_TARGET
    on_event!(cb, d2)
    @test check_state(cb) === CheckState.UNCHECKED
    @test is_consumed(d2)
end

@testitem "toggle: SPACE via Key.CHAR space also toggles" begin
    using ManyUI
    cb = Checkbox("x")
    d = Dispatch(key(' '), cb)
    d.phase = Phase.AT_TARGET
    on_event!(cb, d)
    @test check_state(cb) === CheckState.CHECKED
    @test is_consumed(d)
end

@testitem "toggle: a checkbox does NOT toggle or consume ENTER" begin
    using ManyUI
    # ENTER in a form is SUBMIT. A checkbox that eats ENTER makes ENTER
    # the one key an app cannot bind.
    cb = Checkbox("x")
    d = Dispatch(key(Key.ENTER), cb)
    d.phase = Phase.AT_TARGET
    on_event!(cb, d)
    @test check_state(cb) === CheckState.UNCHECKED
    @test !is_consumed(d)
end

@testitem "toggle: a checkbox leaves TAB alone" begin
    using ManyUI
    # A control that consumes TAB traps focus forever. Consume ONLY what
    # you handle.
    cb = Checkbox("x")
    for e in (key(Key.TAB), key(Key.BACK_TAB), key(Key.ESCAPE),
              key(' '; ctrl = true), key(Key.SPACE; alt = true))
        d = Dispatch(e, cb)
        d.phase = Phase.AT_TARGET
        on_event!(cb, d)
        @test !is_consumed(d)
    end
    @test check_state(cb) === CheckState.UNCHECKED
end

@testitem "toggle: a LEFT click toggles, its release does not" begin
    using ManyUI
    cb = Checkbox("x")
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 20, 1))
    dp = Dispatch(MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                             2, 1, MOD_NONE), cb)
    dp.phase = Phase.AT_TARGET
    on_event!(cb, dp)
    @test check_state(cb) === CheckState.CHECKED
    @test is_consumed(dp)
    # The release activates nothing and consumes nothing -- the press
    # did the work (Button's rule).
    dr = Dispatch(MouseEvent(MouseAction.RELEASE, MouseButton.LEFT,
                             2, 1, MOD_NONE), cb)
    dr.phase = Phase.AT_TARGET
    on_event!(cb, dr)
    @test check_state(cb) === CheckState.CHECKED
    @test !is_consumed(dr)
end

@testitem "toggle: a click on the caption toggles too" begin
    using ManyUI
    # The box is ONE widget: a caption you cannot click is a bug users
    # file.
    cb = Checkbox("Accept")
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 20, 1))
    d = Dispatch(MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                            8, 1, MOD_NONE), cb)
    d.phase = Phase.AT_TARGET
    on_event!(cb, d)
    @test check_state(cb) === CheckState.CHECKED
end

@testitem "toggle: a non-LEFT press is ignored" begin
    using ManyUI
    cb = Checkbox("x")
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 20, 1))
    d = Dispatch(MouseEvent(MouseAction.PRESS, MouseButton.RIGHT,
                            2, 1, MOD_NONE), cb)
    d.phase = Phase.AT_TARGET
    on_event!(cb, d)
    @test check_state(cb) === CheckState.UNCHECKED
    @test !is_consumed(d)
end

@testitem "toggle: toggle! NEVER produces MIXED" begin
    using ManyUI
    # The user has two reachable states; MIXED is set BY CODE. "some are
    # on" answered by a human means "now all of them".
    cb = Checkbox("x"; state = CheckState.MIXED)
    @test toggle!(cb) === CheckState.CHECKED
    @test toggle!(cb) === CheckState.UNCHECKED
    @test toggle!(cb) === CheckState.CHECKED
end

@testitem "toggle: set_state! fires on_change only on a real change" begin
    using ManyUI
    hits = Ref(0)
    cb = Checkbox("x", c -> (hits[] += 1; nothing))
    @test set_state!(cb, CheckState.CHECKED)
    @test hits[] == 1
    # Redundant write: no change, no callback.
    @test !set_state!(cb, CheckState.CHECKED)
    @test hits[] == 1
    @test set_state!(cb, CheckState.UNCHECKED)
    @test hits[] == 2
end

@testitem "toggle: checkbox measure is content-sized, never avail" begin
    using ManyUI
    # A `measure` returning `avail` would make a one-row Label beside a
    # checkbox into a ZERO-row label and vanish it.
    huge = Size(500, 40)
    @test measure(Checkbox(""), huge) == Size(ManyUI.CB_WIDTH, 1)
    m = measure(Checkbox("Accept"), huge)
    @test m == Size(ManyUI.CB_WIDTH + ManyUI.CB_GAP +
                    text_width("Accept"), 1)
    @test m != huge
end

@testitem "toggle: focusing a checkbox underlines it, blur clears it" begin
    using ManyUI
    cb = Checkbox("Ok")
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 10, 1))
    on_focus!(cb)
    @test cb.focused[]
    buf = Buffer(10, 1)
    clear!(buf)
    render!(cb, buf)
    @test has(buf[1, 1].style, Attr.UNDERLINE)
    @test has(buf[5, 1].style, Attr.UNDERLINE)
    on_blur!(cb)
    @test !cb.focused[]
    clear!(buf)
    render!(cb, buf)
    @test !has(buf[1, 1].style, Attr.UNDERLINE)
end

@testitem "toggle: a disabled checkbox refuses TAB, click and paint" begin
    using ManyUI
    # There is no `disabled` field (contract 3.6): "disabled" is
    # `focusable = false` (out of the tab order) plus `set_visible!` when
    # clicks must be refused too. A hidden, non-focusable checkbox
    # refuses BOTH delivery paths -- keyboard reaches it only through
    # focus, the mouse only through `hit_test`, and it is in neither.
    cb = Checkbox("x")
    node(cb).focusable = false
    apply_stylesheet!(STYLESHEET_EMPTY, cb)
    layout!(cb, Region(1, 1, 10, 1))
    # Keyboard: not focusable => not in the tab order => never focused.
    @test !is_focusable(cb)
    @test isempty(focusable_widgets(cb))
    set_visible!(cb, false)
    # Mouse: an invisible widget is not hit, so a click never routes
    # here.
    @test hit_test(cb, 2, 1) === nothing
    # And it paints nothing at all.
    buf = Buffer(10, 1)
    clear!(buf)
    paint!(buf, cb)
    @test string(buf) == "          "
end

# ---- RadioGroup -----------------------------------------------------

@testitem "toggle: a radiogroup chooses nothing initially" begin
    using ManyUI
    opts = ["Small", "Medium", "Large"]
    rg = RadioGroup(opts)
    @test rg isa Widget
    @test type_name(rg) === :RadioGroup
    @test is_focusable(rg)
    @test rg in focusable_widgets(rg)
    # ALIASED, never copied.
    @test rg.options === opts
    # NOTHING is chosen: a group that pre-selects has chosen for the
    # user. The cursor starts at row 1 -- where SPACE would act.
    @test selected(rg) == 0
    @test selected_option(rg) === nothing
    @test radio_cursor(rg) == 1
end

@testitem "toggle: a radiogroup collects an AbstractVector once" begin
    using ManyUI
    # `split` yields a Vector{SubString{String}}: an
    # AbstractVector{<:AbstractString} that is NOT a Vector{String}, so
    # it exercises the collecting constructor.
    src = split("a b c")
    @test !(src isa Vector{String})
    rg = RadioGroup(src)
    @test rg.options == ["a", "b", "c"]
    @test rg.options isa Vector{String}
end

@testitem "toggle: with nothing selected every radio paints ( )" begin
    using ManyUI
    rg = RadioGroup(["Small", "Medium"])
    apply_stylesheet!(STYLESHEET_EMPTY, rg)
    layout!(rg, Region(1, 1, 12, 2))
    buf = Buffer(12, 2)
    clear!(buf)
    render!(rg, buf)
    for row in 1:2
        @test buf[1, row].content == "("
        @test buf[2, row].content == " "
        @test buf[3, row].content == ")"
    end
    @test buf[5, 1].content == "S"
    @test buf[5, 2].content == "M"
end

@testitem "toggle: choosing one option deselects the others" begin
    using ManyUI
    # The mutual exclusion lives in ONE Int: there is no state in which
    # two options are on.
    rg = RadioGroup(["Small", "Medium", "Large"])
    @test choose!(rg, 2)
    @test selected(rg) == 2
    @test selected_option(rg) == "Medium"
    apply_stylesheet!(STYLESHEET_EMPTY, rg)
    layout!(rg, Region(1, 1, 12, 3))
    buf = Buffer(12, 3)
    clear!(buf)
    render!(rg, buf)
    @test buf[2, 1].content == " "        # Small OFF
    @test buf[2, 2].content == "o"        # Medium ON
    @test buf[2, 3].content == " "        # Large OFF
    # Choosing another moves the single "on".
    @test choose!(rg, 1)
    @test selected(rg) == 1
    clear!(buf)
    render!(rg, buf)
    @test buf[2, 1].content == "o"
    @test buf[2, 2].content == " "
end

@testitem "toggle: SPACE selects the cursor option (both forms)" begin
    using ManyUI
    for e in (key(Key.SPACE), key(' '))
        rg = RadioGroup(["A", "B", "C"])
        # Move the cursor to row 2 without choosing.
        dm = Dispatch(key(Key.DOWN), rg)
        dm.phase = Phase.AT_TARGET
        on_event!(rg, dm)
        @test radio_cursor(rg) == 2
        @test selected(rg) == 0
        d = Dispatch(e, rg)
        d.phase = Phase.AT_TARGET
        on_event!(rg, d)
        @test selected(rg) == 2
        @test is_consumed(d)
    end
end

@testitem "toggle: ENTER selects in a radiogroup" begin
    using ManyUI
    rg = RadioGroup(["A", "B"])
    d = Dispatch(key(Key.ENTER), rg)
    d.phase = Phase.AT_TARGET
    on_event!(rg, d)
    @test selected(rg) == 1
    @test is_consumed(d)
end

@testitem "toggle: arrows move the cursor without choosing" begin
    using ManyUI
    # Selection-follows-arrow would make SPACE a no-op on the row it just
    # moved to and fire on_change on every keystroke.
    hits = Ref(0)
    rg = RadioGroup(["A", "B", "C"], g -> (hits[] += 1; nothing))
    for (e, want) in ((key(Key.DOWN), 2), (key(Key.RIGHT), 3),
                      (key(Key.UP), 2), (key(Key.LEFT), 1),
                      (key(Key.END), 3), (key(Key.HOME), 1))
        d = Dispatch(e, rg)
        d.phase = Phase.AT_TARGET
        on_event!(rg, d)
        @test radio_cursor(rg) == want
        @test is_consumed(d)
    end
    @test selected(rg) == 0
    @test hits[] == 0
end

@testitem "toggle: an arrow at the end of a radiogroup bubbles" begin
    using ManyUI
    # Consumes only on a real move, so UP on option 1 bubbles.
    rg = RadioGroup(["A", "B"])
    du = Dispatch(key(Key.UP), rg)
    du.phase = Phase.AT_TARGET
    on_event!(rg, du)
    @test radio_cursor(rg) == 1
    @test !is_consumed(du)
    # Move to the last, then DOWN bubbles.
    dd = Dispatch(key(Key.DOWN), rg)
    dd.phase = Phase.AT_TARGET
    on_event!(rg, dd)
    @test radio_cursor(rg) == 2
    dd2 = Dispatch(key(Key.DOWN), rg)
    dd2.phase = Phase.AT_TARGET
    on_event!(rg, dd2)
    @test radio_cursor(rg) == 2
    @test !is_consumed(dd2)
end

@testitem "toggle: a radiogroup leaves TAB alone" begin
    using ManyUI
    rg = RadioGroup(["A", "B"])
    for e in (key(Key.TAB), key(Key.BACK_TAB), key(Key.ESCAPE),
              key(Key.SPACE; ctrl = true))
        d = Dispatch(e, rg)
        d.phase = Phase.AT_TARGET
        on_event!(rg, d)
        @test !is_consumed(d)
    end
    @test selected(rg) == 0
end

@testitem "toggle: a LEFT click chooses that radio row" begin
    using ManyUI
    # A click is unambiguous: nobody clicks a radio button to browse.
    rg = RadioGroup(["A", "B", "C"])
    apply_stylesheet!(STYLESHEET_EMPTY, rg)
    layout!(rg, Region(1, 1, 10, 3))
    d = Dispatch(MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                            3, 2, MOD_NONE), rg)
    d.phase = Phase.AT_TARGET
    on_event!(rg, d)
    @test selected(rg) == 2
    @test radio_cursor(rg) == 2
    @test is_consumed(d)
end

@testitem "toggle: a click outside the radio rows chooses nothing" begin
    using ManyUI
    rg = RadioGroup(["A", "B"])
    apply_stylesheet!(STYLESHEET_EMPTY, rg)
    layout!(rg, Region(1, 1, 10, 4))
    d = Dispatch(MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                            3, 4, MOD_NONE), rg)
    d.phase = Phase.AT_TARGET
    on_event!(rg, d)
    @test selected(rg) == 0
    @test !is_consumed(d)
end

@testitem "toggle: choose! clamps, moves the cursor, reports change" begin
    using ManyUI
    hits = Ref(0)
    rg = RadioGroup(["A", "B", "C"], g -> (hits[] += 1; nothing))
    # Out of range clamps into 1:n.
    @test choose!(rg, 99)
    @test selected(rg) == 3
    @test radio_cursor(rg) == 3
    @test hits[] == 1
    # A choice is where you are: choosing the same again moves nothing
    # and fires nothing.
    @test !choose!(rg, 3)
    @test hits[] == 1
end

@testitem "toggle: radiogroup measure is content-sized, never avail" begin
    using ManyUI
    huge = Size(500, 40)
    rg = RadioGroup(["A", "Medium", "C"])
    m = measure(rg, huge)
    @test m == Size(ManyUI.CB_WIDTH + ManyUI.CB_GAP +
                    text_width("Medium"), 3)
    @test m != huge
end

@testitem "toggle: an empty radiogroup is inert" begin
    using ManyUI
    rg = RadioGroup(String[])
    @test selected(rg) == 0
    @test radio_cursor(rg) == 0
    @test selected_option(rg) === nothing
    @test !choose!(rg, 1)
    @test measure(rg, Size(20, 20)) == Size(0, 0)
    apply_stylesheet!(STYLESHEET_EMPTY, rg)
    layout!(rg, Region(1, 1, 6, 2))
    buf = Buffer(6, 2)
    clear!(buf)
    render!(rg, buf)                       # must not throw
    @test string(buf) == "      \n      "
    for e in (key(Key.DOWN), key(Key.SPACE), key(Key.ENTER))
        d = Dispatch(e, rg)
        d.phase = Phase.AT_TARGET
        on_event!(rg, d)
        @test !is_consumed(d)
    end
end

@testitem "toggle: focus underlines only the cursor row" begin
    using ManyUI
    rg = RadioGroup(["A", "B", "C"])
    on_focus!(rg)
    @test rg.focused[]
    dd = Dispatch(key(Key.DOWN), rg)
    dd.phase = Phase.AT_TARGET
    on_event!(rg, dd)
    @test radio_cursor(rg) == 2
    apply_stylesheet!(STYLESHEET_EMPTY, rg)
    layout!(rg, Region(1, 1, 8, 3))
    buf = Buffer(8, 3)
    clear!(buf)
    render!(rg, buf)
    @test !has(buf[1, 1].style, Attr.UNDERLINE)
    @test has(buf[1, 2].style, Attr.UNDERLINE)
    @test !has(buf[1, 3].style, Attr.UNDERLINE)
    on_blur!(rg)
    @test !rg.focused[]
    clear!(buf)
    render!(rg, buf)
    @test !has(buf[1, 2].style, Attr.UNDERLINE)
end
