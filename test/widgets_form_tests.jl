# widgets_form_tests.jl -- @testitem blocks for ManyUI/src/widgets/form.jl.
#
# A Form is a Container that can be submitted and read. These tests pin
# exactly the three things it adds -- `submit!`, the `form_value`
# protocol, `form_values` -- and the two things it MUST NOT break: the
# tab order (it reaches every field, in order) and the TAB key (a Form
# never traps it).

@testitem "form: form_value reads text fields through the protocol" begin
    using ManyUI
    ti = TextInput("Alice")
    ta = TextArea("hi\nthere")
    @test form_value(ti) == "Alice"
    @test form_value(ta) == "hi\nthere"
    @test form_value(ti) isa String
    @test form_value(ta) isa String
end

@testitem "form: form_value on a valueless widget throws" begin
    using ManyUI
    # A `Label` has no value. The default MUST be a MethodError, never a
    # silent `nothing`, or a form SAVES A BLANK for a field the author
    # meant to read.
    lbl = Label("just text")
    @test_throws MethodError form_value(lbl)
end

@testitem "form: add_field! names, mounts and keeps order" begin
    using ManyUI
    f = Form()
    a = TextInput("a")
    b = TextInput("b")
    @test add_field!(f, :first, a) === f       # returns the form
    add_field!(f, :second, b)

    # The name map resolves; a missing name is `nothing`, not a throw.
    @test field(f, :first) === a
    @test field(f, :second) === b
    @test field(f, :missing) === nothing

    # `children(f)` is the tab order and it is the fields, in order.
    @test children(f) == [a, b]
end

@testitem "form: form_values reads a form of MIXED field types" begin
    using ManyUI
    f = Form()
    add_field!(f, :name, TextInput("Alice"))
    add_field!(f, :bio, TextArea("hi\nthere"))
    add_field!(f, :remember, Checkbox("Remember me";
                                      state = CheckState.CHECKED))
    add_field!(f, :size, RadioGroup(["Small", "Medium", "Large"]))
    choose!(field(f, :size), 2)

    vals = form_values(f)
    @test vals isa Dict{Symbol,Any}
    @test length(vals) == 4
    @test vals[:name] == "Alice"
    @test vals[:bio] == "hi\nthere"
    @test vals[:remember] === CheckState.CHECKED
    @test vals[:size] === 2

    # The heterogeneous types survive the boundary intact.
    @test vals[:name] isa String
    @test vals[:remember] isa CheckState.T
    @test vals[:size] isa Int
end

@testitem "form: an UNNAMED field stays out of form_values" begin
    using ManyUI
    f = Form()
    add_field!(f, :name, TextInput("Alice"))
    save = Button("Save", identity)
    mount!(f, save)                     # unnamed: no name to report

    vals = form_values(f)
    @test collect(keys(vals)) == [:name]
    @test !haskey(vals, :save)
    @test field(f, :save) === nothing

    # It is still a child, so TAB still reaches it.
    @test children(f) == [field(f, :name), save]
    @test focusable_widgets(f) == [field(f, :name), save]
end

@testitem "form: submit! validates THEN submits and reports true" begin
    using ManyUI
    order = String[]
    validated = Ref(false)
    f = Form(_ -> push!(order, "submit");
             on_validate = _ -> (push!(order, "validate");
                                 validated[] = true; true))

    @test submit!(f) === true
    @test order == ["validate", "submit"]   # validate runs FIRST
    @test validated[]
end

@testitem "form: a validation failure VETOES the submit" begin
    using ManyUI
    submitted = Ref(0)
    f = Form(_ -> (submitted[] += 1; nothing);
             on_validate = _ -> false)      # the veto

    @test submit!(f) === false
    @test submitted[] == 0                  # on_submit NEVER ran
end

@testitem "form: the on_validate closure sees the form and its values" begin
    using ManyUI
    saved = Ref{Any}(nothing)
    f = Form(g -> (saved[] = form_values(g); nothing);
             on_validate = g -> form_value(field(g, :name)) != "")
    add_field!(f, :name, TextInput("Bob"))

    @test submit!(f) === true
    @test saved[][:name] == "Bob"

    # Empty the field (a `TextInput` reads through its `text` reactive):
    # the same validator now vetoes and `on_submit` never runs.
    field(f, :name).text[] = ""
    saved[] = nothing
    @test submit!(f) === false
    @test saved[] === nothing
end

@testitem "form: focus traversal reaches every field IN ORDER" begin
    using ManyUI
    f = Form()
    n = TextInput("n")
    r = RadioGroup(["a", "b"])
    c = Checkbox("c")
    add_field!(f, :name, n)
    add_field!(f, :size, r)
    add_field!(f, :ok, c)

    # `focusable_widgets` is the ONLY tab order there is, and a Form adds
    # nothing to it: the fields come out in pre-order, which is add order.
    @test focusable_widgets(f) == [n, r, c]
end

@testitem "form: a hidden field drops OUT of the tab order" begin
    using ManyUI
    # Browser-lesson 3, inverted: the way to take a field out of TAB is
    # `set_visible!`/`focusable = false`, not a Form feature. A hidden
    # field's node leaves `focusable_widgets` because it uses
    # `walk_visible`.
    f = Form()
    a = TextInput("a")
    b = TextInput("b")
    c = TextInput("c")
    add_field!(f, :a, a)
    add_field!(f, :b, b)
    add_field!(f, :c, c)
    @test focusable_widgets(f) == [a, b, c]

    set_visible!(b, false)
    @test focusable_widgets(f) == [a, c]

    # And a field made non-focusable is skipped while still visible.
    node(c).focusable = false
    @test focusable_widgets(f) == [a]
end

@testitem "form: does NOT trap the TAB key -- focus advances through it" begin
    using ManyUI
    # A Form defines no `on_event!`, so TAB is never consumed inside it.
    # End to end: a TAB delivered to a focused field leaves it unconsumed,
    # reaches `app.bindings`, and `:focus_next` advances to the next
    # field. A Form that trapped TAB would fail this.
    f = Form()
    a = TextInput("a")
    b = TextInput("b")
    add_field!(f, :a, a)
    add_field!(f, :b, b)

    dr = HeadlessDriver(Size(20, 5))
    ap = App(f, dr)
    bind!(ap, "tab", :focus_next)
    bind!(ap, "shift+tab", :focus_prev)

    focus!(ap, a)
    @test focused(ap) === a
    ManyUI.handle!(ap, parse(KeyEvent, "tab"))
    @test focused(ap) === b                 # TAB reached :focus_next
    ManyUI.handle!(ap, parse(KeyEvent, "tab"))
    @test focused(ap) === a                 # wraps -- still not trapped
    ManyUI.handle!(ap, parse(KeyEvent, "shift+tab"))
    @test focused(ap) === b                 # BACK_TAB works too
end

@testitem "form: TAB delivered to a field inside a form is NOT consumed" begin
    using ManyUI
    # The mechanism behind the App-level test: no widget on the path from
    # the Form down to the focused field consumes TAB.
    f = Form()
    a = TextInput("hi")
    add_field!(f, :a, a)

    d = Dispatch(parse(KeyEvent, "tab"), a)
    d.phase = Phase.AT_TARGET
    on_event!(a, d)
    @test !is_consumed(d)

    # The Form itself defines no key handler -- it falls through to the
    # no-op `on_event!(::Widget, ::Dispatch)` default and consumes nothing
    # in any phase, so TAB (and every other key) passes straight through.
    for ph in (Phase.CAPTURE, Phase.AT_TARGET, Phase.BUBBLE)
        df = Dispatch(parse(KeyEvent, "tab"), f)
        df.phase = ph
        @test on_event!(f, df) === nothing
        @test !is_consumed(df)
    end
end

@testitem "form: it lays its fields out and PAINTS them -- assert cells" begin
    using ManyUI
    # Browser-lesson 4: building a Form and asserting no throw proves
    # nothing. Paint into a headless Buffer and assert the CELLS the
    # fields actually put on screen.
    f = Form()
    add_field!(f, :name, TextInput("hello"))
    add_field!(f, :ok, Checkbox("Save"))
    apply_stylesheet!(STYLESHEET_EMPTY, f)
    layout!(f, Region(1, 1, 20, 2))

    buf = Buffer(20, 2)
    clear!(buf)
    paint!(buf, f)

    # Row 1: the TextInput's content.
    @test buf[1, 1].content == "h"
    @test buf[2, 1].content == "e"
    @test buf[3, 1].content == "l"
    # Row 2: the Checkbox's caption is present somewhere on its row.
    row2 = join(buf[x, 2].content for x in 1:20)
    @test occursin("Save", row2)
end

@testitem "form: reading a field's value after a real key press" begin
    using ManyUI
    # The value protocol end to end: type into a field, read it back
    # through `form_values`. `key(Key.SPACE)` toggles a Checkbox field,
    # so its value flips -- both space forms, per browser-lesson 1.
    f = Form()
    add_field!(f, :name, TextInput(""))
    cb = Checkbox("ok")
    add_field!(f, :ok, cb)

    # Type "hi" into the text field.
    for e in (key('h'), key('i'))
        d = Dispatch(e, field(f, :name))
        d.phase = Phase.AT_TARGET
        on_event!(field(f, :name), d)
    end
    @test form_values(f)[:name] == "hi"

    # Press the REAL space bar (Key.SPACE, not Key.CHAR(' ')) on the box.
    d = Dispatch(key(Key.SPACE), cb)
    d.phase = Phase.AT_TARGET
    on_event!(cb, d)
    @test form_values(f)[:ok] === CheckState.CHECKED
    @test is_consumed(d)
end
