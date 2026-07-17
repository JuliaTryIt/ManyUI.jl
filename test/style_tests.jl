# style_tests.jl -- @testitem blocks for src/style.jl.
# Written BEFORE the implementation (TDD, CLAUDE.md).
# U4 (the cascade fold) is proven by "style: merge monoid laws";
# X1 (spec.md 2.5, bullet 1) by "style: degrade drops attrs at
# MONOCHROME".

@testitem "style: Style is isbits and 12 bytes" begin
    using DualUI

    @test isbitstype(Style)
    @test sizeof(Style) == 12          # Color(4) + Color(4) + 2 + 2
    @test isbitstype(Attr.T)
    @test AttrMask === UInt16
    @test sizeof(Attr.T) == 2

    # The attribute values are single, distinct bits: they ARE the bit
    # positions of an AttrMask.
    all_attrs = (Attr.BOLD, Attr.DIM, Attr.ITALIC, Attr.UNDERLINE,
                 Attr.BLINK, Attr.REVERSE, Attr.HIDDEN, Attr.STRIKE)
    @test Set(instances(Attr.T)) == Set(all_attrs)
    for a in all_attrs
        @test count_ones(UInt16(a)) == 1
    end
    @test length(Set(UInt16(a) for a in all_attrs)) == 8

    # Style is a value type: equal constructions are `===`.
    @test Style(bold = true) === Style(bold = true)
    @test STYLE_NONE === Style()
    @test STYLE_NONE === Style(COLOR_UNSET, COLOR_UNSET, 0x0000, 0x0000)
    @test STYLE_DEFAULT === Style(COLOR_DEFAULT, COLOR_DEFAULT,
                                  0x0000, 0xffff)
    @test STYLE_NONE !== STYLE_DEFAULT
end

@testitem "style: kwarg constructor is tri-state" begin
    using DualUI

    # nothing = unspecified, false = specified-off, true = specified-on.
    @test STYLE_NONE.mask === 0x0000
    @test STYLE_NONE.attrs === 0x0000
    @test !specified(STYLE_NONE, Attr.BOLD)
    @test !has(STYLE_NONE, Attr.BOLD)

    on = Style(bold = true)
    @test specified(on, Attr.BOLD)
    @test has(on, Attr.BOLD)
    @test on.attrs === UInt16(Attr.BOLD)
    @test on.mask === UInt16(Attr.BOLD)

    off = Style(bold = false)
    @test specified(off, Attr.BOLD)
    @test !has(off, Attr.BOLD)
    @test off.attrs === 0x0000
    @test off.mask === UInt16(Attr.BOLD)

    @test on !== off                # specified-on is not specified-off
    @test off !== STYLE_NONE        # specified-off is not unspecified

    # Colors default to UNSET, i.e. "inherit".
    @test is_unset(STYLE_NONE.fg)
    @test is_unset(STYLE_NONE.bg)
    s = Style(fg = rgb(255, 0, 0), bg = ansi16(4))
    @test s.fg === rgb(255, 0, 0)
    @test s.bg === ansi16(4)

    # Every attribute is reachable through the kwargs, and the values
    # are canonical: attrs is always a subset of mask.
    full = Style(bold = true, dim = false, italic = true,
                 underline = false, blink = true, reverse = false,
                 hidden = true, strike = false)
    @test full.mask === 0x00ff
    @test full.attrs === (UInt16(Attr.BOLD) | UInt16(Attr.ITALIC) |
                          UInt16(Attr.BLINK) | UInt16(Attr.HIDDEN))
    @test (full.attrs & ~full.mask) === 0x0000
    for a in (Attr.BOLD, Attr.ITALIC, Attr.BLINK, Attr.HIDDEN)
        @test has(full, a)
    end
    for a in (Attr.DIM, Attr.UNDERLINE, Attr.REVERSE, Attr.STRIKE)
        @test specified(full, a)
        @test !has(full, a)
    end
end

@testitem "style: with and without are inverse on the mask" begin
    using DualUI

    @test with(STYLE_NONE, Attr.BOLD, true) === Style(bold = true)
    @test with(STYLE_NONE, Attr.BOLD, false) === Style(bold = false)
    @test with(STYLE_NONE, Attr.STRIKE, true) === Style(strike = true)

    s = Style(fg = rgb(1, 2, 3), bold = true, italic = true)
    # with() preserves the colors and the other attributes.
    t = with(s, Attr.BOLD, false)
    @test t.fg === s.fg
    @test t.bg === s.bg
    @test has(t, Attr.ITALIC)
    @test specified(t, Attr.BOLD)
    @test !has(t, Attr.BOLD)

    # without() clears BOTH the value and the mask -- that is what makes
    # it different from with(s, a, false).
    u = without(s, Attr.BOLD)
    @test !specified(u, Attr.BOLD)
    @test !has(u, Attr.BOLD)
    @test has(u, Attr.ITALIC)
    @test u.fg === s.fg
    @test with(s, Attr.BOLD, false) !== without(s, Attr.BOLD)

    # Idempotent, and without ∘ with == without.
    @test with(with(s, Attr.BOLD, true), Attr.BOLD, true) ===
          with(s, Attr.BOLD, true)
    @test without(without(s, Attr.BOLD), Attr.BOLD) ===
          without(s, Attr.BOLD)
    @test without(with(s, Attr.BOLD, true), Attr.BOLD) ===
          without(s, Attr.BOLD)
    @test without(STYLE_NONE, Attr.BOLD) === STYLE_NONE

    # `with` never disturbs a neighbouring bit.
    for a in instances(Attr.T), b in instances(Attr.T)
        a === b && continue
        x = with(with(STYLE_NONE, a, true), b, false)
        @test has(x, a)
        @test specified(x, b)
        @test !has(x, b)
    end
end

@testitem "style: merge monoid laws" begin
    using DualUI

    a = Style(fg = rgb(255, 0, 0), bold = true)
    b = Style(bg = rgb(0, 0, 255), italic = true)
    c = Style(fg = rgb(0, 255, 0), bold = false, underline = true)
    d = Style(fg = ansi16(3), bg = COLOR_DEFAULT, strike = true,
              italic = false)

    # Identity: STYLE_NONE on either side is a no-op.
    for s in (a, b, c, d, STYLE_NONE, STYLE_DEFAULT)
        @test merge(s, STYLE_NONE) === s
        @test merge(STYLE_NONE, s) === s
    end

    # Associativity -- this is what lets the cascade be a fold.
    for x in (a, b, c, d, STYLE_NONE, STYLE_DEFAULT),
        y in (a, b, c, d, STYLE_NONE, STYLE_DEFAULT),
        z in (a, b, c, d, STYLE_NONE, STYLE_DEFAULT)
        @test merge(merge(x, y), z) === merge(x, merge(y, z))
    end

    # Right-biased, per-property: `over` wins ONLY where it specifies.
    @test merge(a, c).fg === rgb(0, 255, 0)     # over sets fg
    @test merge(a, b).fg === rgb(255, 0, 0)     # over leaves fg alone
    @test merge(a, b).bg === rgb(0, 0, 255)     # over sets bg
    @test merge(b, a).bg === rgb(0, 0, 255)     # base keeps bg
    @test has(merge(a, b), Attr.BOLD)           # inherited
    @test has(merge(a, b), Attr.ITALIC)         # added
    @test merge(a, b).mask === (a.mask | b.mask)

    # NORMATIVE formula, verified bit for bit.
    for x in (a, b, c, d, STYLE_NONE, STYLE_DEFAULT),
        y in (a, b, c, d, STYLE_NONE, STYLE_DEFAULT)
        m = merge(x, y)
        @test m.fg === (is_set(y.fg) ? y.fg : x.fg)
        @test m.bg === (is_set(y.bg) ? y.bg : x.bg)
        @test m.mask === (x.mask | y.mask)
        @test m.attrs === ((x.attrs & ~y.mask) | (y.attrs & y.mask))
        @test (m.attrs & ~m.mask) === 0x0000    # stays canonical
    end

    # Not commutative -- and that is the point.
    @test merge(a, c) !== merge(c, a)

    # Folding a whole cascade chain right-biased.
    @test foldl(merge, (STYLE_NONE, a, b, c)) ===
          merge(merge(merge(STYLE_NONE, a), b), c)
end

@testitem "style: bold false overrides inherited bold" begin
    using DualUI

    # THE reason Style carries a mask: without it, `bold: false` in a
    # stylesheet could not switch off an inherited bold, exactly the
    # problem COLOR_UNSET solves for colors.
    inherited = Style(bold = true, italic = true)
    @test has(inherited, Attr.BOLD)

    child = Style(bold = false)
    m = merge(inherited, child)
    @test specified(m, Attr.BOLD)
    @test !has(m, Attr.BOLD)        # the override took
    @test has(m, Attr.ITALIC)       # untouched, still inherited

    # A child that says nothing about bold inherits it.
    quiet = Style(underline = true)
    m2 = merge(inherited, quiet)
    @test has(m2, Attr.BOLD)
    @test has(m2, Attr.ITALIC)
    @test has(m2, Attr.UNDERLINE)

    # `without` is silence, not an override.
    silent = without(child, Attr.BOLD)
    @test !specified(silent, Attr.BOLD)
    @test has(merge(inherited, silent), Attr.BOLD)

    # And the same tri-state for colors: UNSET inherits, DEFAULT
    # overrides with the terminal default.
    @test merge(Style(fg = rgb(255, 0, 0)), Style()).fg === rgb(255, 0, 0)
    @test merge(Style(fg = rgb(255, 0, 0)),
                Style(fg = COLOR_DEFAULT)).fg === COLOR_DEFAULT

    # Re-overriding back on works too.
    @test has(merge(m, Style(bold = true)), Attr.BOLD)
end

@testitem "style: inheritable keeps fg drops bg" begin
    using DualUI

    s = Style(fg = rgb(255, 0, 0), bg = rgb(0, 0, 255), bold = true,
              italic = false, strike = true)
    i = inheritable(s)

    @test i.fg === rgb(255, 0, 0)
    @test is_unset(i.bg)                # background does NOT inherit
    @test i.attrs === s.attrs           # every text attribute does
    @test i.mask === s.mask
    @test has(i, Attr.BOLD)
    @test has(i, Attr.STRIKE)
    @test specified(i, Attr.ITALIC)
    @test !has(i, Attr.ITALIC)

    @test inheritable(inheritable(s)) === i        # idempotent
    @test inheritable(STYLE_NONE) === STYLE_NONE

    # A background never leaks down a chain of inherits, however deep.
    @test is_unset(inheritable(inheritable(STYLE_DEFAULT)).bg)
    @test inheritable(STYLE_DEFAULT).fg === COLOR_DEFAULT

    # Merging an inheritable parent under a child leaves the child's own
    # background alone.
    child = Style(bg = ansi16(2))
    @test merge(inheritable(s), child).bg === ansi16(2)
    @test merge(inheritable(s), child).fg === rgb(255, 0, 0)
    # ... and a child with no background of its own gets none.
    @test is_unset(merge(inheritable(s), STYLE_NONE).bg)
end

@testitem "style: resolve replaces unset colors with default" begin
    using DualUI

    r = resolve(STYLE_NONE)
    @test r.fg === COLOR_DEFAULT
    @test r.bg === COLOR_DEFAULT
    @test resolve(r) === r                       # idempotent

    s = Style(fg = rgb(1, 2, 3), bold = true, italic = false)
    @test resolve(s).fg === rgb(1, 2, 3)         # a set fg is kept
    @test resolve(s).bg === COLOR_DEFAULT        # an unset bg resolves
    @test resolve(s).attrs === s.attrs           # colors only
    @test resolve(s).mask === s.mask
    @test resolve(Style(bg = ansi16(4))).bg === ansi16(4)
    @test resolve(STYLE_DEFAULT) === STYLE_DEFAULT

    # After resolve there is no UNSET colour left anywhere.
    for x in (STYLE_NONE, s, STYLE_DEFAULT, Style(fg = ansi256(9)))
        @test is_set(resolve(x).fg)
        @test is_set(resolve(x).bg)
    end
end

@testitem "style: degrade drops attrs at MONOCHROME" begin
    using DualUI

    D = ColorDepth
    s = Style(fg = rgb(0xffffff), bg = rgb(0x000000), bold = true,
              dim = true, italic = true, underline = true, blink = true,
              reverse = true, hidden = true, strike = true)

    d = degrade(s, D.MONOCHROME)
    @test d.fg === ansi16(15)
    @test d.bg === ansi16(0)
    # Kept: the three a monochrome terminal can actually render.
    @test has(d, Attr.BOLD)
    @test has(d, Attr.UNDERLINE)
    @test has(d, Attr.REVERSE)
    # Dropped from the mask, so a downstream merge does not resurrect
    # them either.
    for a in (Attr.DIM, Attr.ITALIC, Attr.BLINK, Attr.HIDDEN,
              Attr.STRIKE)
        @test !specified(d, a)
        @test !has(d, a)
    end
    @test degrade(d, D.MONOCHROME) === d          # idempotent

    # A specified-OFF droppable attribute is dropped as well.
    off = Style(italic = false, bold = false)
    od = degrade(off, D.MONOCHROME)
    @test !specified(od, Attr.ITALIC)
    @test specified(od, Attr.BOLD)
    @test !has(od, Attr.BOLD)

    # Every other depth keeps every attribute untouched.
    for depth in (D.ANSI16, D.ANSI256, D.TRUECOLOR)
        x = degrade(s, depth)
        @test x.attrs === s.attrs
        @test x.mask === s.mask
        @test degrade(x, depth) === x             # idempotent
    end

    # TRUECOLOR is the identity on the whole Style.
    @test degrade(s, D.TRUECOLOR) === s
    @test degrade(STYLE_NONE, D.TRUECOLOR) === STYLE_NONE
    @test degrade(STYLE_DEFAULT, D.TRUECOLOR) === STYLE_DEFAULT

    # Colors go through the Color truth table, both channels.
    @test degrade(Style(fg = rgb(255, 0, 0)), D.ANSI16).fg === ansi16(9)
    @test degrade(Style(bg = rgb(255, 0, 0)), D.ANSI16).bg === ansi16(9)
    @test degrade(Style(fg = rgb(0x808080)), D.ANSI256).fg ===
          ansi256(244)
    @test degrade(Style(fg = rgb(0x808080)), D.MONOCHROME).fg ===
          ansi16(0)

    # UNSET stays UNSET at every depth: degradation must not turn
    # "inherit" into a concrete colour behind the cascade's back.
    for depth in (D.MONOCHROME, D.ANSI16, D.ANSI256, D.TRUECOLOR)
        x = degrade(STYLE_NONE, depth)
        @test is_unset(x.fg)
        @test is_unset(x.bg)
        @test x === STYLE_NONE
        y = degrade(STYLE_DEFAULT, depth)
        @test y.fg === COLOR_DEFAULT
        @test y.bg === COLOR_DEFAULT
    end

    # Total and idempotent over the whole grid.
    styles = (STYLE_NONE, STYLE_DEFAULT, s, off,
              Style(fg = ansi256(200), bg = ansi16(4), blink = true),
              Style(fg = COLOR_DEFAULT, dim = true))
    for x in styles,
        depth in (D.MONOCHROME, D.ANSI16, D.ANSI256, D.TRUECOLOR)
        y = degrade(x, depth)
        @test y isa Style
        @test degrade(y, depth) === y
        @test (y.attrs & ~y.mask) === 0x0000      # stays canonical
    end
end

@testitem "style: parse_attrs handles no- prefix" begin
    using DualUI

    B = UInt16(Attr.BOLD)
    I = UInt16(Attr.ITALIC)

    @test parse_attrs("bold") === (B, B)
    @test parse_attrs("bold italic") === (B | I, B | I)
    @test parse_attrs("no-bold") === (0x0000, B)
    @test parse_attrs("bold no-italic") === (B, B | I)
    @test parse_attrs("no-bold no-italic") === (0x0000, B | I)
    @test parse_attrs("") === (0x0000, 0x0000)
    @test parse_attrs("   ") === (0x0000, 0x0000)
    @test parse_attrs(" bold   italic ") === (B | I, B | I)
    @test parse_attrs("bold\titalic") === (B | I, B | I)

    # Case-insensitive.
    @test parse_attrs("BOLD") === (B, B)
    @test parse_attrs("No-Bold") === (0x0000, B)

    # Later tokens win, and the mask stays set either way.
    @test parse_attrs("bold bold") === (B, B)
    @test parse_attrs("bold no-bold") === (0x0000, B)
    @test parse_attrs("no-bold bold") === (B, B)

    # Every attribute name is accepted, on and off.
    names = ("bold", "dim", "italic", "underline", "blink", "reverse",
             "hidden", "strike")
    all_attrs = (Attr.BOLD, Attr.DIM, Attr.ITALIC, Attr.UNDERLINE,
                 Attr.BLINK, Attr.REVERSE, Attr.HIDDEN, Attr.STRIKE)
    for (n, a) in zip(names, all_attrs)
        @test parse_attrs(n) === (UInt16(a), UInt16(a))
        @test parse_attrs("no-" * n) === (0x0000, UInt16(a))
    end
    @test parse_attrs(join(names, " ")) === (0x00ff, 0x00ff)

    # Garbage throws.
    @test_throws ArgumentError parse_attrs("wobbly")
    @test_throws ArgumentError parse_attrs("bold wobbly")
    @test_throws ArgumentError parse_attrs("no-wobbly")
    @test_throws ArgumentError parse_attrs("no-")
    @test_throws ArgumentError parse_attrs("bold-italic")

    # The pair drops straight into the Style tri-state.
    a, m = parse_attrs("bold no-italic")
    st = Style(rgb(0, 0, 0), COLOR_UNSET, a, m)
    @test has(st, Attr.BOLD)
    @test specified(st, Attr.ITALIC)
    @test !has(st, Attr.ITALIC)
    @test !specified(st, Attr.STRIKE)
    @test (a & ~m) === 0x0000                # canonical: attrs ⊆ mask

    # Return type is exactly the contract's.
    @test parse_attrs("bold") isa Tuple{AttrMask,AttrMask}
end
