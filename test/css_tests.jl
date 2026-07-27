# css_tests.jl -- tests for ManyUI/src/css.jl (U4, req 2.1).
#
# Every @testitem is self-contained: it names its own stub widget type
# so the cascade is exercised with no App and no tree walk.

@testitem "css: specificity is lexicographic" begin
    using ManyUI

    S = Specificity

    # types < classes < ids, whatever the counts below.
    @test S(0, 0, 1) < S(0, 1, 0)
    @test S(0, 1, 0) < S(1, 0, 0)
    @test S(0, 0, 9) < S(0, 1, 0)
    @test S(0, 9, 9) < S(1, 0, 0)
    @test !(S(1, 0, 0) < S(0, 9, 9))
    @test !(S(1, 2, 3) < S(1, 2, 3))
    @test S(1, 2, 3) < S(1, 2, 4)
    @test S(1, 2, 3) < S(1, 3, 0)

    # Counting, per compound and per selector.
    @test specificity(parse(Selector, "*")) == S(0, 0, 0)
    @test specificity(parse(Selector, "Label")) == S(0, 0, 1)
    @test specificity(parse(Selector, ".a")) == S(0, 1, 0)
    @test specificity(parse(Selector, ".a.b")) == S(0, 2, 0)
    @test specificity(parse(Selector, "#x")) == S(1, 0, 0)
    @test specificity(parse(Selector, "Button.primary#ok")) ==
          S(1, 1, 1)
    @test specificity(parse(Selector, "Container > Button.p#ok")) ==
          S(1, 1, 2)
    @test specificity(parse(Selector, ".panel Label")) == S(0, 1, 1)

    c = parse(Selector, "Button.primary#ok").compounds[1]
    @test c isa CompoundSelector
    @test specificity(c) == S(1, 1, 1)
    @test length(c.parts) == 3
end

@testitem "css: cascade id beats class beats type" begin
    using ManyUI

    struct W1 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    mkw(; wid::Symbol = :_w, cls = Symbol[], ty::Symbol = :Widget) =
        W1(ManyUI.WidgetNode(wid, Set{Symbol}(cls), ty, nothing,
                             ManyUI.Widget[], STYLE_NONE,
                             BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                             LAYOUT_BOX_EMPTY, ManyUI.DirtyMask(0),
                             true, false, nothing))

    w = mkw(wid = :ok, cls = [:primary], ty = :Button)

    # All three match; the id rule wins even though it is FIRST in
    # source order, so this is specificity and not source order.
    ss = parse_css("""
        #ok      { color: blue; }
        .primary { color: green; }
        Button   { color: red; }
        """)
    @test [r.order for r in matching_rules(ss, w)] == [3, 2, 1]
    (st, _) = cascade(ss, w)
    @test st.fg == parse(Color, "blue")

    # Without the id rule, the class rule wins over the type rule.
    ss2 = parse_css(".primary { color: green; }\nButton { color: red; }")
    (st2, _) = cascade(ss2, w)
    @test st2.fg == parse(Color, "green")

    # Without the class rule, the type rule wins.
    ss3 = parse_css("Button { color: red; }")
    (st3, _) = cascade(ss3, w)
    @test st3.fg == parse(Color, "red")

    # The universal selector is weaker than a type selector.
    ss4 = parse_css("* { color: red; }\nButton { color: green; }")
    (st4, _) = cascade(ss4, w)
    @test st4.fg == parse(Color, "green")

    # An unmatched selector contributes NOTHING.
    ss5 = parse_css("Label { color: red; }\n#nope { color: green; }\n" *
                    ".other { color: blue; }")
    @test isempty(matching_rules(ss5, w))
    (st5, _) = cascade(ss5, w)
    @test is_unset(st5.fg)
    @test st5 === STYLE_NONE

    # Box properties cascade by the same ordering.
    ss6 = parse_css("#ok { gap: 3; }\nButton { gap: 1; }")
    (_, bx6) = cascade(ss6, w)
    @test bx6.gap == 3
end

@testitem "css: source order breaks specificity ties" begin
    using ManyUI

    struct W2 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    mkw(; wid::Symbol = :_w, cls = Symbol[], ty::Symbol = :Widget) =
        W2(ManyUI.WidgetNode(wid, Set{Symbol}(cls), ty, nothing,
                             ManyUI.Widget[], STYLE_NONE,
                             BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                             LAYOUT_BOX_EMPTY, ManyUI.DirtyMask(0),
                             true, false, nothing))

    w = mkw(cls = [:a, :b])

    ss = parse_css(".a { color: red; }\n.b { color: green; }")
    rs = matching_rules(ss, w)
    @test length(rs) == 2
    @test [r.order for r in rs] == [1, 2]     # ASCENDING: apply in order
    @test specificity(rs[1].selector) == specificity(rs[2].selector)
    (st, _) = cascade(ss, w)
    @test st.fg == parse(Color, "green")      # the LATER rule wins

    # Flip the source order and the winner flips with it.
    ss2 = parse_css(".b { color: green; }\n.a { color: red; }")
    (st2, _) = cascade(ss2, w)
    @test st2.fg == parse(Color, "red")

    # merge shifts b's order so its rules stay later.
    m = merge(parse_css(".a { color: red; }"),
              parse_css(".b { color: green; }"))
    @test [r.order for r in m.rules] == [1, 2]
    (stm, _) = cascade(m, w)
    @test stm.fg == parse(Color, "green")
end

@testitem "css: inline style always wins" begin
    using ManyUI

    struct W3 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    mkw(; wid::Symbol = :_w, cls = Symbol[], ty::Symbol = :Widget) =
        W3(ManyUI.WidgetNode(wid, Set{Symbol}(cls), ty, nothing,
                             ManyUI.Widget[], STYLE_NONE,
                             BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                             LAYOUT_BOX_EMPTY, ManyUI.DirtyMask(0),
                             true, false, nothing))

    w = mkw(wid = :ok, ty = :Button)
    ss = parse_css("#ok { color: red; gap: 2; }")

    (st0, bx0) = cascade(ss, w)
    @test st0.fg == parse(Color, "red")
    @test bx0.gap == 2

    n = ManyUI.node(w)
    n.inline_style = Style(fg = parse(Color, "green"))
    n.inline_box = BoxPatch(gap = 7)

    (st, bx) = cascade(ss, w)
    @test st.fg == parse(Color, "green")   # beats the id rule
    @test bx.gap == 7

    # Inline leaves unspecified properties to the sheet.
    ss2 = parse_css("#ok { color: red; background: blue; }")
    (st2, _) = cascade(ss2, w)
    @test st2.fg == parse(Color, "green")
    @test st2.bg == parse(Color, "blue")
end

@testitem "css: cascade is pure" begin
    using ManyUI

    struct W4 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    mkw(; wid::Symbol = :_w, cls = Symbol[], ty::Symbol = :Widget) =
        W4(ManyUI.WidgetNode(wid, Set{Symbol}(cls), ty, nothing,
                             ManyUI.Widget[], STYLE_NONE,
                             BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                             LAYOUT_BOX_EMPTY, ManyUI.DirtyMask(0),
                             true, false, nothing))

    w = mkw(wid = :ok, cls = [:primary], ty = :Button)
    ss = parse_css("#ok { color: red; width: 30%; }")
    n = ManyUI.node(w)

    cs, bx, dirty = n.computed_style, n.box, n.dirty
    r1 = cascade(ss, w)
    r2 = cascade(ss, w)

    # Mutates NOTHING on the node.
    @test n.computed_style === cs
    @test n.box === bx
    @test n.dirty == dirty
    @test isempty(ManyUI.node(w).children)

    # Same inputs, same outputs.
    @test r1 == r2

    # parent_style is an input, not hidden state: fg inherits, bg
    # does not.
    ps = Style(fg = parse(Color, "green"), bg = parse(Color, "blue"))
    (st, _) = cascade(STYLESHEET_EMPTY, mkw(), ps)
    @test st.fg == parse(Color, "green")
    @test is_unset(st.bg)
end

@testitem "css: child combinator does not match a grandchild" begin
    using ManyUI

    struct W5 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    mkw(; wid::Symbol = :_w, cls = Symbol[], ty::Symbol = :Widget) =
        W5(ManyUI.WidgetNode(wid, Set{Symbol}(cls), ty, nothing,
                             ManyUI.Widget[], STYLE_NONE,
                             BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                             LAYOUT_BOX_EMPTY, ManyUI.DirtyMask(0),
                             true, false, nothing))
    function link!(p, c)
        push!(ManyUI.node(p).children, c)
        ManyUI.node(c).parent = p
        return c
    end

    root = mkw(ty = :Container)
    mid = mkw(ty = :Panel)
    leaf = mkw(ty = :Label, cls = [:item])
    link!(root, mid)
    link!(mid, leaf)

    sel = parse(Selector, "Container > .item")
    @test length(sel.compounds) == 2
    @test sel.combinators == [Combinator.CHILD]
    @test !matches(sel, leaf)          # leaf's parent is a Panel
    @test matches(parse(Selector, "Panel > .item"), leaf)
    @test matches(parse(Selector, "Container > Panel > .item"), leaf)
    @test matches(parse(Selector, "Container > Panel"), mid)
    @test !matches(parse(Selector, "Container > Container"), mid)

    # A child rule that does not match contributes nothing.
    ss = parse_css("Container > .item { color: red; }")
    @test isempty(matching_rules(ss, leaf))
    (st, _) = cascade(ss, leaf)
    @test is_unset(st.fg)

    # The root has no parent: a combinator selector cannot match it.
    @test !matches(parse(Selector, "Container > Container"), root)
    @test matches(parse(Selector, "Container"), root)
end

@testitem "css: descendant combinator matches a grandchild" begin
    using ManyUI

    struct W6 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    mkw(; wid::Symbol = :_w, cls = Symbol[], ty::Symbol = :Widget) =
        W6(ManyUI.WidgetNode(wid, Set{Symbol}(cls), ty, nothing,
                             ManyUI.Widget[], STYLE_NONE,
                             BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                             LAYOUT_BOX_EMPTY, ManyUI.DirtyMask(0),
                             true, false, nothing))
    function link!(p, c)
        push!(ManyUI.node(p).children, c)
        ManyUI.node(c).parent = p
        return c
    end

    root = mkw(ty = :Container, cls = [:panel])
    mid = mkw(ty = :Panel)
    leaf = mkw(ty = :Label, cls = [:item])
    link!(root, mid)
    link!(mid, leaf)

    sel = parse(Selector, ".panel Label")
    @test sel.combinators == [Combinator.DESCENDANT]
    @test matches(sel, leaf)                       # skips over Panel
    @test matches(parse(Selector, "Container Label"), leaf)
    @test matches(parse(Selector, "Container Panel Label"), leaf)
    @test matches(parse(Selector, "Panel Label"), leaf)
    @test !matches(parse(Selector, "Label Label"), leaf)
    @test !matches(parse(Selector, "Missing Label"), leaf)

    # Backtracking: the FIRST ancestor tried need not be the match.
    @test matches(parse(Selector, "Container .item"), leaf)

    ss = parse_css(".panel Label { color: red; }")
    (st, _) = cascade(ss, leaf)
    @test st.fg == parse(Color, "red")
    (stm, _) = cascade(ss, mid)
    @test is_unset(stm.fg)
end

@testitem "css: margin shorthand 1 2 and 4 values" begin
    using ManyUI

    one = parse_css("#a { margin: 1; }").rules[1].box
    @test one.margin == Spacing(1, 1, 1, 1)

    two = parse_css("#a { padding: 0 2; }").rules[1].box
    @test two.padding == Spacing(0, 2, 0, 2)   # vertical, horizontal

    four = parse_css("#a { margin: 1 2 3 4; }").rules[1].box
    @test four.margin == Spacing(1, 2, 3, 4)   # top right bottom left

    both = parse_css("#a { margin: 2; padding: 1 3 5 7; }").rules[1].box
    @test both.margin == Spacing(2, 2, 2, 2)
    @test both.padding == Spacing(1, 3, 5, 7)

    # 3 values is not in the accepted set, and neither is garbage.
    @test_throws CssParseError parse_css("#a { margin: 1 2 3; }")
    @test_throws CssParseError parse_css("#a { margin: 1 2 3 4 5; }")
    @test_throws CssParseError parse_css("#a { padding: wide; }")
end

@testitem "css: parse_css throws CssParseError with line and col" begin
    using ManyUI

    grab(src) = try
        parse_css(src)
        nothing
    catch e
        e
    end

    # Line 2, column 13: the '@' where a ':' was required.
    e = grab("Button { }\n#ok { width @ 3; }")
    @test e isa CssParseError
    @test e.line == 2
    @test e.col == 13
    @test occursin("width", e.msg)
    s = sprint(showerror, e)
    @test occursin("2", s)
    @test occursin("13", s)

    # A missing '{' is reported where the '{' should have been.
    e2 = grab("#ok }")
    @test e2 isa CssParseError
    @test e2.line == 1
    @test e2.col == 5

    # An unterminated block reaches EOF.
    e3 = grab("#ok { ")
    @test e3 isa CssParseError
    @test e3.line == 1

    # An unknown property is a CssParseError, never a bare
    # ArgumentError.
    e4 = grab("#a { bogus: 1; }")
    @test e4 isa CssParseError
    @test occursin("bogus", e4.msg)

    # Comments and blank lines do not shift the reported position.
    e5 = grab("/* a\n   comment */\n#ok }")
    @test e5 isa CssParseError
    @test e5.line == 3
    @test e5.col == 5

    # A well-formed sheet parses; a rule per selector in the list.
    ok = parse_css("""
        /* leading comment */
        Screen { gap: 1; }
        A, B { gap: 2; }
        """)
    @test length(ok.rules) == 3
    @test [r.order for r in ok.rules] == [1, 2, 3]
end

@testitem "css: apply_stylesheet! dirties only on real change" begin
    using ManyUI

    struct W7 <: ManyUI.Widget
        node::ManyUI.WidgetNode
    end
    mkw(; wid::Symbol = :_w, cls = Symbol[], ty::Symbol = :Widget) =
        W7(ManyUI.WidgetNode(wid, Set{Symbol}(cls), ty, nothing,
                             ManyUI.Widget[], STYLE_NONE,
                             BOX_PATCH_NONE, STYLE_NONE, BOX_DEFAULT,
                             LAYOUT_BOX_EMPTY, ManyUI.DirtyMask(0),
                             true, false, nothing))
    function link!(p, c)
        push!(ManyUI.node(p).children, c)
        ManyUI.node(c).parent = p
        return c
    end

    root = mkw(wid = :a, ty = :Screen)
    kid = mkw(ty = :Label)
    link!(root, kid)

    # A style-only change dirties PAINT, not LAYOUT.
    ss = parse_css("#a { color: red; }")
    apply_stylesheet!(ss, root)
    @test ManyUI.node(root).computed_style.fg == parse(Color, "red")
    @test is_dirty(root, Dirty.PAINT)
    @test !is_dirty(root, Dirty.LAYOUT)
    @test !is_dirty(root, Dirty.STYLE)          # STYLE is cleared

    # fg inherits down; the child was cascaded too.
    @test ManyUI.node(kid).computed_style.fg == parse(Color, "red")

    # Re-running an UNCHANGED cascade must cost zero frames.
    clean!(root)
    clean!(kid)
    apply_stylesheet!(ss, root)
    @test !is_dirty(root)
    @test !is_dirty(kid)

    # A box change dirties LAYOUT.
    clean!(root)
    clean!(kid)
    apply_stylesheet!(parse_css("#a { color: red; width: 10; }"), root)
    @test is_dirty(root, Dirty.LAYOUT)
    @test ManyUI.node(root).box.width == parse(Length, "10")

    # recascade! is a no-op on a style-clean tree.
    clean!(root)
    clean!(kid)
    ss2 = parse_css("#a { color: green; }")
    recascade!(ss2, root)
    @test !is_dirty(root)
    @test ManyUI.node(root).computed_style.fg == parse(Color, "red")

    # ... and re-cascades once STYLE is marked.
    mark!(root, Dirty.STYLE)
    recascade!(ss2, root)
    @test ManyUI.node(root).computed_style.fg == parse(Color, "green")
    @test !is_dirty(root, Dirty.STYLE)
end

@testitem "css: css_str parses at macro expansion" begin
    using ManyUI

    ss = css"#ok { }"
    @test ss isa Stylesheet
    @test length(ss.rules) == 1
    @test specificity(ss.rules[1].selector) == Specificity(1, 0, 0)

    # The expansion is the VALUE, not a call to the parser.
    ex = macroexpand(@__MODULE__, :(css"#ok { }"))
    @test ex isa Stylesheet
    @test length(ex.rules) == 1

    # A bad stylesheet fails at expansion time.
    @test_throws Exception macroexpand(@__MODULE__, :(css"#ok }"))
    @test_throws Exception macroexpand(@__MODULE__, :(css"#a { x: 1; }"))
end

@testitem "css: declarations cover paint and box properties" begin
    using ManyUI

    r = parse_css("""
        Button {
            color: #ff8800;
            background: rgb(0, 90, 180);
            text-style: bold italic no-dim;
            layout: column;
            justify: space-between;
            align: center;
            width: 30%;
            height: auto;
            min-width: 4;
            min-height: 2;
            max-width: 80;
            max-height: 40;
            margin: 1 2;
            padding: 0 2;
            border: round #444;
            gap: 1;
            overflow: scroll;
            grow: 1;
            shrink: 0;
        }
        """).rules[1]

    # Paint properties.
    @test r.style.fg == rgb(0xff8800)
    @test r.style.bg == rgb(0, 90, 180)
    @test has(r.style, Attr.BOLD)
    @test has(r.style, Attr.ITALIC)
    @test specified(r.style, Attr.DIM)
    @test !has(r.style, Attr.DIM)               # no-dim: off, specified

    # Box properties.
    b = r.box
    @test b.display == Display.FLEX             # `layout` is an alias
    @test b.direction == Direction.COLUMN
    @test b.justify == Justify.SPACE_BETWEEN
    @test b.align == Align.CENTER
    @test b.width == pct(30)
    @test b.height == AUTO
    @test b.min_width == cells(4)
    @test b.min_height == cells(2)
    @test b.max_width == cells(80)
    @test b.max_height == cells(40)
    @test b.margin == Spacing(1, 2, 1, 2)
    @test b.padding == Spacing(0, 2, 0, 2)
    @test b.border == Border(BorderKind.ROUND,
                             Style(fg = parse(Color, "#444")))
    @test b.gap == 1
    @test b.overflow_x == Overflow.SCROLL
    @test b.overflow_y == Overflow.SCROLL
    @test b.grow == 1f0
    @test b.shrink == 0f0

    # display / direction / overflow-x / overflow-y on their own.
    b2 = parse_css("""
        A { display: block; direction: row-reverse;
            overflow-x: visible; overflow-y: hidden;
            border: none; }
        """).rules[1].box
    @test b2.display == Display.BLOCK
    @test b2.direction == Direction.ROW_REVERSE
    @test b2.overflow_x == Overflow.VISIBLE
    @test b2.overflow_y == Overflow.HIDDEN
    @test b2.border == BORDER_NONE

    # Values are folded onto BOX_DEFAULT / STYLE_NONE by the cascade.
    @test isempty(parse_css("A { color: red; }").rules[1].box)
    @test parse_css("A { gap: 1; }").rules[1].style === STYLE_NONE

    # parse_property is the extension point.
    (s, p) = ManyUI.parse_property(Val(:color), "red")
    @test s.fg == parse(Color, "red")
    @test isempty(p)
    @test_throws CssParseError ManyUI.parse_property(Val(:nope), "x")
end

@testitem "css: stylesheet collection API" begin
    using ManyUI

    ss = Stylesheet()
    @test isempty(ss)
    @test isempty(STYLESHEET_EMPTY)
    @test !isempty(parse_css("A { gap: 1; }"))

    sel = parse(Selector, ".a")
    r = Rule(sel, STYLE_NONE, BOX_PATCH_NONE, 1)
    @test push!(ss, r) === ss
    @test length(ss.rules) == 1
    @test !isempty(ss)
    @test append!(ss, [Rule(sel, STYLE_NONE, BOX_PATCH_NONE, 2)]) === ss
    @test length(ss.rules) == 2

    a = parse_css("A { gap: 1; }\nB { gap: 2; }")
    b = parse_css("C { gap: 3; }")
    m = merge(a, b)
    @test length(m.rules) == 3
    @test [x.order for x in m.rules] == [1, 2, 3]
    @test length(a.rules) == 2          # merge does not mutate `a`
    @test length(b.rules) == 1
    @test [x.order for x in b.rules] == [1]

    @test isempty(merge(STYLESHEET_EMPTY, STYLESHEET_EMPTY))
    @test length(merge(STYLESHEET_EMPTY, b).rules) == 1

    # parse(Stylesheet, s) is parse_css.
    @test length(parse(Stylesheet, "A { gap: 1; }").rules) == 1
    @test_throws CssParseError parse(Selector, "A { }")
end
