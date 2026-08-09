# theme_tests.jl -- @testitem blocks for src/theme.jl.
# Written BEFORE the implementation (TDD, CLAUDE.md).
#
# The load-bearing decision here is WHEN a token becomes a colour. It is
# at EMISSION, not at cascade: a token survives the cascade, survives
# `merge`, survives sitting in a `TextRun`, and is looked up once when a
# colour meets a device. That is what makes a theme swap a repaint
# rather than a re-cascade, and it is what "richtext: a run style
# resolves against the widget style" needs in order to stay true when
# the run names a token.

@testitem "theme: a token is a Color of its own kind" begin
    using ManyUI

    t = token(:accent)
    @test t isa Color
    @test t.kind === ColorKind.TOKEN
    @test is_token(t)
    @test !is_token(rgb(1, 2, 3))
    @test !is_token(COLOR_UNSET)

    # A token IS set: it names a colour, it just has not been looked up.
    # `is_set` deciding otherwise would make `merge` drop it.
    @test is_set(t)
    @test !is_unset(t)

    # Same name, same token -- ids are stable within a session, so a
    # token can be compared and stored in an isbits Style.
    @test token(:accent) === token(:accent)
    @test token(:accent) !== token(:warning)
    @test isbitstype(Color)
    @test sizeof(Color) == 4
end

@testitem "theme: an unknown token name is an error, not a silent miss" begin
    using ManyUI

    @test_throws ArgumentError token(:no_such_token)
end

@testitem "theme: the built-in tokens exist in both built-in themes" begin
    using ManyUI

    wanted = (:bg, :text, :text_dim, :accent, :border,
              :success, :warning, :error, :selection_bg, :selection_fg)
    for name in wanted
        @test token(name) isa Color
    end

    @test :dark in themes()
    @test :light in themes()
    for nm in (:dark, :light)
        th = theme(nm)
        for name in wanted
            # Total over the built-in tokens: a theme with a hole would
            # show up as one unreadable widget at runtime, far from here.
            @test theme_color(th, name) isa Color
            @test !is_token(theme_color(th, name))
        end
    end

    # The two themes disagree about the background, or one of them is
    # not a theme.
    @test theme_color(theme(:dark), :bg) != theme_color(theme(:light), :bg)
end

@testitem "theme: resolve_token replaces a token and nothing else" begin
    using ManyUI

    th = theme(:dark)
    @test resolve_token(token(:accent), th) == theme_color(th, :accent)

    # Everything that is not a token passes through untouched.
    for c in (rgb(1, 2, 3), ansi16(4), ansi256(200), COLOR_UNSET,
              COLOR_DEFAULT)
        @test resolve_token(c, th) === c
    end

    # Resolution is idempotent: a resolved colour is an ordinary colour.
    once = resolve_token(token(:accent), th)
    @test resolve_token(once, th) === once
end

@testitem "theme: resolve_token on a Style does both planes" begin
    using ManyUI

    th = theme(:dark)
    s = Style(fg = token(:accent), bg = token(:bg), bold = true)
    r = resolve_token(s, th)

    @test r.fg == theme_color(th, :accent)
    @test r.bg == theme_color(th, :bg)
    # The attributes are untouched: a theme names colours, not weights.
    @test has(r, Attr.BOLD)
    @test r.attrs == s.attrs
    @test r.mask == s.mask

    # A style with no token at all is returned as-is.
    plain_style = Style(fg = rgb(1, 2, 3), italic = true)
    @test resolve_token(plain_style, th) === plain_style
end

@testitem "theme: a token survives merge, which is the whole point" begin
    using ManyUI

    # `merge` is the cascade's monoid AND the fold a RichText run uses.
    # If it collapsed a token to a colour, a run naming `:warning` would
    # be frozen to whichever theme was current when it was BUILT.
    base = Style(fg = rgb(200, 200, 200), bg = rgb(0, 0, 0))
    over = Style(fg = token(:warning), bold = true)
    got = merge(base, over)

    @test is_token(got.fg)
    @test got.fg === token(:warning)
    @test got.bg == rgb(0, 0, 0)
    @test has(got, Attr.BOLD)

    # And it resolves differently under two themes -- built once, right
    # in both.
    @test resolve_token(got, theme(:dark)).fg ==
          theme_color(theme(:dark), :warning)
    @test resolve_token(got, theme(:light)).fg ==
          theme_color(theme(:light), :warning)
end

@testitem "theme: set_theme! swaps what tokens mean" begin
    using ManyUI

    before = theme()
    try
        set_theme!(:dark)
        @test theme().name === :dark
        dark_bg = resolve_token(token(:bg))

        set_theme!(:light)
        @test theme().name === :light
        @test resolve_token(token(:bg)) != dark_bg

        # By value as well as by name.
        set_theme!(theme(:dark))
        @test theme().name === :dark
    finally
        set_theme!(before)
    end

    @test_throws ArgumentError set_theme!(:no_such_theme)
end

@testitem "theme: a custom theme registers and resolves" begin
    using ManyUI

    before = theme()
    try
        mine = Theme(:test_custom, Dict(:accent => rgb(1, 2, 3)))
        register_theme!(mine)
        @test :test_custom in themes()

        set_theme!(:test_custom)
        @test resolve_token(token(:accent)) == rgb(1, 2, 3)
        # A token the theme does not name falls back to the one
        # declared when the token was registered, so a partial theme is
        # usable rather than a source of invisible text.
        @test !is_token(resolve_token(token(:warning)))
    finally
        set_theme!(before)
    end
end

@testitem "theme: a token is unusable as a concrete colour" begin
    using ManyUI

    # Loud, not silent: a token that reached a device without being
    # resolved is a bug, and `to_rgb` is where it shows.
    @test_throws ArgumentError to_rgb(token(:accent))

    # `degrade` refuses to rewrite it for the same reason it refuses
    # UNSET and DEFAULT: it is not a colour yet.
    for d in (ColorDepth.MONOCHROME, ColorDepth.ANSI16,
              ColorDepth.ANSI256, ColorDepth.TRUECOLOR)
        @test degrade(token(:accent), d) === token(:accent)
    end
end

@testitem "theme: CSS names a token with var(--name)" begin
    using ManyUI

    ss = parse_css("Label { color: var(--accent); background: var(--bg); }")
    st = ss.rules[1].style
    @test st.fg === token(:accent)
    @test st.bg === token(:bg)

    # The cascade carries the token through rather than resolving it,
    # so one parsed stylesheet serves every theme.
    l = Label("x")
    apply_stylesheet!(ss, l)
    @test computed_style(l).fg === token(:accent)

    # A bad token name is a parse error with a position, like every
    # other bad value.
    @test_throws CssParseError parse_css("Label { color: var(--nope); }")
end
