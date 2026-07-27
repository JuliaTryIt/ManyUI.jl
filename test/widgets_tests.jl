# widgets_tests.jl -- the built-in widget library (layer 7).
#
# Covers EARS 2.1 ("the component tree made concrete and usable") and
# X2 (the minimum-size fallback overlay). Every testitem is
# self-contained, per the contract's test plan.

@testitem "widgets: Container constructs empty and with children" begin
    using ManyUI
    c = Container()
    @test c isa Container
    @test c isa Widget
    @test isempty(children(c))
    @test parent(c) === nothing
    @test type_name(c) === :Container
    @test !is_focusable(c)
    @test is_visible(c)

    a = Label("a")
    b = Label("b")
    p = Container(a, b; id = :root, classes = [:pane])
    @test id(p) === :root
    @test has_class(p, :pane)
    @test children(p) == Widget[a, b]
    @test parent(a) === p
    @test parent(b) === p
    @test p[1] === a
    @test p[2] === b
end

@testitem "widgets: Container ids are unique by default" begin
    using ManyUI
    @test id(Container()) !== id(Container())
    @test id(Label("x")) !== id(Label("x"))
    @test id(Static("x")) !== id(Static("x"))
    @test id(Button("x", identity)) !== id(Button("x", identity))
end

@testitem "widgets: tree is queryable by id class and type" begin
    using ManyUI
    lab = Label("hi"; id = :greeting, classes = [:big])
    btn = Button("OK", identity; id = :ok)
    root = Container(Container(lab), btn; id = :root)

    @test query_one(root, "#greeting") === lab
    @test query_one(root, ".big") === lab
    @test query_one(root, "#ok") === btn
    @test query_one(root, "#greeting", Label) === lab
    @test query_one(root, "#ok", Button) === btn
    @test length(query(root, "Container")) == 2
    @test query(root, "Label") == Widget[lab]
    @test query_one(root, "#nope") === nothing
end

@testitem "widgets: Label measure wraps to available width" begin
    using ManyUI
    l = Label("hello world")
    @test measure(l, Size(11, 10)) == Size(11, 1)
    @test measure(l, Size(20, 10)) == Size(11, 1)
    @test measure(l, Size(5, 10)) == Size(5, 2)
    # No width at all: nothing can be laid out, and that is not a throw.
    @test measure(l, Size(0, 10)) == Size(0, 0)
    @test measure(Label(""), Size(10, 10)) == Size(0, 0)
    # Pure with respect to the tree: measuring marks nothing dirty.
    clean!(l)
    measure(l, Size(5, 10))
    @test !is_dirty(l)
end

@testitem "widgets: Label render! wraps into its view" begin
    using ManyUI
    buf = Buffer(5, 3)
    render!(Label("hello world"), buf)
    @test string(buf) == "hello\nworld\n     "
end

@testitem "widgets: Label render! stops at the bottom of its view" begin
    using ManyUI
    buf = Buffer(5, 1)
    render!(Label("hello world"), buf)
    @test string(buf) == "hello"
end

@testitem "widgets: Label wraps on grapheme boundaries" begin
    using ManyUI
    # A wide cluster that would straddle the right edge is moved to the
    # next line, never halved: S3 through the widget layer.
    l = Label("世界ab")
    @test measure(l, Size(3, 5)) == Size(3, 3)

    buf = Buffer(3, 3)
    render!(l, buf)
    @test buf[1, 1].content == "世"
    @test is_continuation(buf[2, 1])
    @test buf[3, 1] == CELL_BLANK
    @test buf[1, 2].content == "界"
    @test is_continuation(buf[2, 2])
    @test buf[3, 2].content == "a"
    @test buf[1, 3].content == "b"
end

@testitem "widgets: Label text is reactive" begin
    using ManyUI
    l = Label("one")
    @test l.text[] == "one"
    clean!(l)
    l.text[] = "one"
    @test !is_dirty(l)          # E1: an equal write is a no-op
    l.text[] = "two"
    @test l.text[] == "two"
    @test is_dirty(l, Dirty.LAYOUT)
    @test measure(l, Size(10, 1)) == Size(3, 1)
end

@testitem "widgets: Static measure is text_width by one" begin
    using ManyUI
    @test measure(Static("hello"), Size(2, 1)) == Size(5, 1)
    @test measure(Static("hello"), Size(100, 100)) == Size(5, 1)
    @test measure(Static("世界"), Size(1, 1)) == Size(4, 1)
    @test measure(Static(""), Size(10, 10)) == Size(0, 1)
    # Never wraps: the available width does not change the answer.
    s = Static("hello world")
    @test measure(s, Size(3, 9)) == measure(s, Size(300, 9))
end

@testitem "widgets: Static render! is one truncated line" begin
    using ManyUI
    buf = Buffer(5, 2)
    render!(Static("hello world"), buf)
    @test string(buf) == "hello\n     "
end

@testitem "widgets: Static render! refuses a straddling wide cluster" begin
    using ManyUI
    buf = Buffer(3, 1)
    render!(Static("世界"), buf)
    @test buf[1, 1].content == "世"
    @test is_continuation(buf[2, 1])
    @test buf[3, 1] == CELL_BLANK       # half a glyph is worse than a gap
end

@testitem "widgets: Static type_name is its own" begin
    using ManyUI
    @test type_name(Static("x")) === :Static
    @test type_name(Label("x")) === :Label
    @test type_name(Button("x", identity)) === :Button
    @test type_name(MinSizeOverlay()) === :MinSizeOverlay
end

@testitem "widgets: Button measure is the caption extent" begin
    using ManyUI
    @test measure(Button("OK", identity), Size(10, 10)) == Size(2, 1)
    @test measure(Button("世界", identity), Size(10, 10)) == Size(4, 1)
    @test measure(Button("", identity), Size(10, 10)) == Size(0, 1)
end

@testitem "widgets: Button render! centres the caption" begin
    using ManyUI
    b = Button("OK", identity)
    buf = Buffer(6, 3)
    render!(b, buf)
    @test buf[3, 2].content == "O"
    @test buf[4, 2].content == "K"
    @test buf[2, 2] == CELL_BLANK
    @test buf[5, 2] == CELL_BLANK
    @test buf[3, 1] == CELL_BLANK       # centred vertically too
    @test buf[3, 3] == CELL_BLANK
end

@testitem "widgets: Button render! truncates an oversized caption" begin
    using ManyUI
    buf = Buffer(3, 1)
    render!(Button("hello", identity), buf)
    @test string(buf) == "hel"
end

@testitem "widgets: Button is focusable" begin
    using ManyUI
    @test is_focusable(Button("OK", identity))
    @test !is_focusable(Label("x"))
    @test !is_focusable(Static("x"))
    @test !is_focusable(Container())

    root = Container(Label("x"), Button("a", identity),
                     Button("b", identity))
    layout!(root, Region(1, 1, 20, 10))
    tab = focusable_widgets(root)
    @test length(tab) == 2
    @test all(w -> w isa Button, tab)
end

@testitem "widgets: Button on_press fires on ENTER" begin
    using ManyUI
    fired = Ref(0)
    b = Button("OK", w -> (fired[] += 1; nothing))

    d = Dispatch(parse(KeyEvent, "enter"), b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 1
    @test is_consumed(d)

    # SPACE too, in either spelling the parser can produce.
    d = Dispatch(parse(KeyEvent, "space"), b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 2

    d = Dispatch(key(' '), b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 3

    # Not on another key, and never during the capture phase.
    d = Dispatch(parse(KeyEvent, "q"), b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 3
    @test !is_consumed(d)

    d = Dispatch(parse(KeyEvent, "enter"), b)
    @test d.phase === Phase.CAPTURE
    on_event!(b, d)
    @test fired[] == 3
    @test !is_consumed(d)

    # A modified ENTER belongs to an app-level binding, not the button.
    d = Dispatch(parse(KeyEvent, "ctrl+enter"), b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 3
    @test !is_consumed(d)
end

@testitem "widgets: Button on_press fires on LEFT click" begin
    using ManyUI
    fired = Ref(0)
    b = Button("OK", w -> (fired[] += 1; nothing))

    press = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 1, 1,
                       MOD_NONE)
    d = Dispatch(press, b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 1
    @test is_consumed(d)
    @test b.pressed[]

    rel = MouseEvent(MouseAction.RELEASE, MouseButton.LEFT, 1, 1,
                     MOD_NONE)
    d = Dispatch(rel, b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 1          # a release activates nothing
    @test !b.pressed[]

    right = MouseEvent(MouseAction.PRESS, MouseButton.RIGHT, 1, 1,
                       MOD_NONE)
    d = Dispatch(right, b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 1
    @test !is_consumed(d)

    move = MouseEvent(MouseAction.MOVE, MouseButton.NONE, 1, 1,
                      MOD_NONE)
    d = Dispatch(move, b)
    d.phase = Phase.AT_TARGET
    on_event!(b, d)
    @test fired[] == 1
    @test !is_consumed(d)
end

@testitem "widgets: Button press is routed by hit testing" begin
    using ManyUI
    fired = Ref(0)
    b = Button("OK", w -> (fired[] += 1; nothing))
    root = Container(Label("title"), b)
    layout!(root, Region(1, 1, 20, 4))

    r = region(b)
    @test !isempty(r)
    @test hit_test(root, r.x, r.y) === b

    e = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, r.x, r.y,
                   MOD_NONE)
    @test dispatch_event!(root, e)
    @test fired[] == 1

    # A click that misses the button hits something else and fires
    # nothing.
    miss = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 1,
                      bottom(Region(1, 1, 20, 4)), MOD_NONE)
    dispatch_event!(root, miss)
    @test fired[] == 1
end

@testitem "widgets: Button ENTER reaches the focused button" begin
    using ManyUI
    fired = Ref(0)
    b = Button("OK", w -> (fired[] += 1; nothing))
    root = Container(Label("title"), b)
    layout!(root, Region(1, 1, 20, 4))
    @test dispatch_event!(root, parse(KeyEvent, "enter"), b)
    @test fired[] == 1
end

@testitem "widgets: Button label is reactive" begin
    using ManyUI
    b = Button("OK", identity)
    @test b.label[] == "OK"
    @test !b.pressed[]
    clean!(b)
    b.label[] = "OK"
    @test !is_dirty(b)
    b.label[] = "Cancel"
    @test is_dirty(b, Dirty.LAYOUT)
    @test measure(b, Size(20, 1)) == Size(6, 1)
    # `pressed` cannot change the caption extent, so it is PAINT-only.
    clean!(b)
    b.pressed[] = true
    @test is_dirty(b, Dirty.PAINT)
    @test !is_dirty(b, Dirty.LAYOUT)
end

@testitem "widgets: Button field is concrete" begin
    using ManyUI
    f = w -> nothing
    b = Button("x", f)
    @test b isa Button{typeof(f)}
    @test isconcretetype(typeof(b))
    @test fieldtype(typeof(b), :on_press) === typeof(f)
    @test isconcretetype(fieldtype(typeof(b), :on_press))
    @test isconcretetype(fieldtype(typeof(b), :label))
    @test isconcretetype(fieldtype(typeof(b), :pressed))
    @test isconcretetype(fieldtype(Label, :text))
    @test isconcretetype(fieldtype(Static, :text))
end

@testitem "widgets: paint! composites the widget tree" begin
    using ManyUI
    root = Container(Static("ab"), Static("cd"); id = :root)
    layout!(root, Region(1, 1, 4, 3))
    buf = Buffer(4, 3)
    paint!(buf, root)
    @test string(buf) == "ab  \ncd  \n    "
end

@testitem "widgets: a widget cannot paint outside its box" begin
    using ManyUI
    root = Container(Static("hello world"); id = :root)
    root.node.inline_box = BoxPatch(; padding = Spacing(1))
    apply_stylesheet!(STYLESHEET_EMPTY, root)
    layout!(root, Region(1, 1, 6, 3))
    buf = Buffer(6, 3)
    paint!(buf, root)
    # Row 1 and row 3 are padding: the child owns row 2, columns 2:5.
    @test string(buf) == "      \n hell \n      "
end

@testitem "overlay: should_suspend predicate table" begin
    using ManyUI
    @test should_suspend(Size(12, 3), Size(20, 5)) === true
    @test should_suspend(Size(80, 24), Size(20, 5)) === false
    @test should_suspend(Size(20, 5), Size(20, 5)) === false
    @test should_suspend(Size(19, 5), Size(20, 5)) === true
    @test should_suspend(Size(20, 4), Size(20, 5)) === true
    @test should_suspend(Size(0, 0), Size(1, 1)) === true
    @test should_suspend(Size(1, 1), Size(0, 0)) === false
    @test OVERLAY_MIN_SIZE == Size(12, 1)
end

@testitem "overlay: MinSizeOverlay is an ordinary widget" begin
    using ManyUI
    o = MinSizeOverlay()
    @test o isa Widget
    @test id(o) === :_min_size_overlay
    @test o.message[] == "Increase Terminal Size"
    @test o.required[] == Size(0, 0)
    @test o.actual[] == Size(0, 0)

    o.required[] = Size(80, 24)
    o.actual[] = Size(40, 3)
    m = measure(o, Size(60, 10))
    @test m.height == 2
    @test m.width == length("Increase Terminal Size")

    buf = Buffer(40, 4)
    render!(o, buf)
    s = string(buf)
    @test occursin("Increase Terminal Size", s)
    @test occursin("Need 80x24 - have 40x3", s)

    o2 = MinSizeOverlay(; message = "Bigger please", id = :ov)
    @test id(o2) === :ov
    @test o2.message[] == "Bigger please"
end

@testitem "overlay: render_min_size_overlay! degrades in three steps" begin
    using ManyUI
    # 1. message + dimensions
    big = Buffer(40, 3)
    render_min_size_overlay!(big, Size(40, 3), Size(80, 24))
    s = string(big)
    @test occursin("Increase Terminal Size", s)
    @test occursin("Need 80x24 - have 40x3", s)

    # 2. message only -- one row is not enough for two lines
    med = Buffer(24, 1)
    render_min_size_overlay!(med, Size(24, 1), Size(80, 24))
    s = string(med)
    @test occursin("Increase Terminal Size", s)
    @test !occursin("Need", s)

    # 3. "Too small" -- the message no longer fits
    small = Buffer(10, 1)
    render_min_size_overlay!(small, Size(10, 1), Size(80, 24))
    @test occursin("Too small", string(small))

    # 4. nothing at all, and still not a throw
    tiny = Buffer(4, 1)
    render_min_size_overlay!(tiny, Size(4, 1), Size(80, 24))
    @test string(tiny) == string(Buffer(4, 1))

    empty = Buffer(0, 0)
    @test render_min_size_overlay!(empty, Size(0, 0), Size(80, 24)) ===
          nothing
end

@testitem "overlay: render_min_size_overlay! clears what it paints over" begin
    using ManyUI
    buf = Buffer(40, 3)
    fill!(buf, Cell("x"))
    render_min_size_overlay!(buf, Size(40, 3), Size(80, 24))
    @test !occursin("xxxx", string(buf))
    @test occursin("Increase Terminal Size", string(buf))
end

@testitem "overlay: render_min_size_overlay! calls no layout" begin
    using ManyUI
    # X2: the tree-free path exists precisely because layout is
    # meaningless below OVERLAY_MIN_SIZE. Assert it structurally.
    src = read(joinpath(dirname(pathof(ManyUI)), "widgets",
                        "overlay.jl"), String)
    for bad in (r"\blayout!\(", r"\brelayout!\(", r"\bcompute_layout\(",
                r"\bcascade\(", r"\bapply_layout!\(", r"\bpaint!\(")
        @test !occursin(bad, src)
    end

    names = Set{Symbol}()
    walkexpr(x) = nothing
    walkexpr(g::GlobalRef) = (push!(names, g.name); nothing)
    function walkexpr(e::Expr)
        for a in e.args
            walkexpr(a)
        end
        return nothing
    end
    for ci in code_lowered(ManyUI.render_min_size_overlay!,
                           (Buffer, Size, Size))
        for st in ci.code
            walkexpr(st)
        end
    end
    @test :measure ∉ names
    @test :layout! ∉ names
    @test :cascade ∉ names
    @test !isempty(names)       # the scan actually saw something
end
