# color_tests.jl -- @testitem blocks for src/color.jl.
# Written BEFORE the implementation (TDD, CLAUDE.md).
# X1 (spec.md 2.5, bullet 1) is proven by
# "color: degrade truth table and idempotence".

@testitem "color: Color is isbits and 4 bytes" begin
    using ManyUI

    @test isbitstype(Color)
    @test sizeof(Color) == 4
    @test isbitstype(ColorKind.T)
    @test isbitstype(ColorDepth.T)

    # The kinds are the six tagged readings of the same 3 bytes.
    # TOKEN is the odd one out and deliberately so: it is not a colour
    # but the NAME of one, packed into the same isbits payload so a
    # theme can be swapped without rebuilding a single Style. It is
    # `theme.jl` that says what the payload means.
    @test Set(instances(ColorKind.T)) == Set((
        ColorKind.UNSET, ColorKind.DEFAULT, ColorKind.ANSI16,
        ColorKind.ANSI256, ColorKind.RGB, ColorKind.TOKEN))

    # ColorDepth is ORDERED, so `depth < ColorDepth.TRUECOLOR` is a
    # legal capability test.
    @test ColorDepth.MONOCHROME < ColorDepth.ANSI16
    @test ColorDepth.ANSI16 < ColorDepth.ANSI256
    @test ColorDepth.ANSI256 < ColorDepth.TRUECOLOR
    @test ColorDepth.TRUECOLOR isa ColorDepth.T

    # Color is a value: two equal constructions are `===`.
    @test rgb(1, 2, 3) === rgb(1, 2, 3)
    @test COLOR_UNSET === Color(ColorKind.UNSET, 0, 0, 0)
    @test COLOR_DEFAULT === Color(ColorKind.DEFAULT, 0, 0, 0)
    @test COLOR_UNSET !== COLOR_DEFAULT
end

@testitem "color: constructors validate and accessors read" begin
    using ManyUI

    c = rgb(255, 136, 0)
    @test c.kind === ColorKind.RGB
    @test (c.r, c.g, c.b) === (0xff, 0x88, 0x00)
    @test rgb(0xff8800) === c
    @test rgb(0x000000) === rgb(0, 0, 0)
    @test rgb(0xffffff) === rgb(255, 255, 255)

    @test_throws ArgumentError rgb(-1)
    @test_throws ArgumentError rgb(0x1000000)
    @test_throws ArgumentError rgb(256, 0, 0)
    @test_throws ArgumentError rgb(0, -1, 0)

    @test ansi16(0).kind === ColorKind.ANSI16
    @test ansi16(15).r === 0x0f
    @test_throws ArgumentError ansi16(16)
    @test_throws ArgumentError ansi16(-1)

    @test ansi256(0).kind === ColorKind.ANSI256
    @test ansi256(255).r === 0xff
    @test_throws ArgumentError ansi256(256)
    @test_throws ArgumentError ansi256(-1)

    @test is_unset(COLOR_UNSET)
    @test !is_set(COLOR_UNSET)
    @test is_set(COLOR_DEFAULT)
    @test is_set(rgb(0, 0, 0))
    @test is_set(ansi16(0))
    @test !is_unset(ansi256(0))

    @test color_index(ansi16(9)) === 0x09
    @test color_index(ansi256(200)) === 0xc8
    @test_throws ArgumentError color_index(rgb(1, 2, 3))
    @test_throws ArgumentError color_index(COLOR_UNSET)
    @test_throws ArgumentError color_index(COLOR_DEFAULT)

    @test color(:red) === ansi16(1)
    @test color(:bright_black) === ansi16(8)
    @test color(:bright_white) === ansi16(15)
    @test_throws KeyError color(:not_a_color)
end

@testitem "color: to_rgb resolves the palettes and rejects UNSET" begin
    using ManyUI

    @test to_rgb(rgb(1, 2, 3)) === rgb(1, 2, 3)

    # The 16 system colors.
    @test to_rgb(ansi16(0)) === rgb(0, 0, 0)
    @test to_rgb(ansi16(7)) === rgb(192, 192, 192)
    @test to_rgb(ansi16(8)) === rgb(128, 128, 128)
    @test to_rgb(ansi16(9)) === rgb(255, 0, 0)
    @test to_rgb(ansi16(15)) === rgb(255, 255, 255)

    # The 6x6x6 cube: base 16, levels 0/95/135/175/215/255,
    # index == 16 + 36r + 6g + b.
    @test to_rgb(ansi256(16)) === rgb(0, 0, 0)
    @test to_rgb(ansi256(17)) === rgb(0, 0, 95)
    @test to_rgb(ansi256(21)) === rgb(0, 0, 255)
    @test to_rgb(ansi256(22)) === rgb(0, 95, 0)
    @test to_rgb(ansi256(52)) === rgb(95, 0, 0)
    @test to_rgb(ansi256(196)) === rgb(255, 0, 0)
    @test to_rgb(ansi256(231)) === rgb(255, 255, 255)

    # The 24-step grey ramp: 8 + 10i, i in 0:23.
    @test to_rgb(ansi256(232)) === rgb(8, 8, 8)
    @test to_rgb(ansi256(244)) === rgb(128, 128, 128)
    @test to_rgb(ansi256(255)) === rgb(238, 238, 238)

    # The first 16 entries of the 256 palette ARE the 16 system colors.
    for i in 0:15
        @test to_rgb(ansi256(i)) === to_rgb(ansi16(i))
    end

    # UNSET/DEFAULT have no RGB value at all.
    @test_throws ArgumentError to_rgb(COLOR_UNSET)
    @test_throws ArgumentError to_rgb(COLOR_DEFAULT)

    # to_rgb is idempotent.
    for c in (rgb(9, 9, 9), ansi16(3), ansi256(140))
        @test to_rgb(to_rgb(c)) === to_rgb(c)
    end
end

@testitem "color: luminance is sRGB-decoded and in 0..1" begin
    using ManyUI

    @test luminance(rgb(0x000000)) == 0.0
    @test luminance(rgb(0xffffff)) == 1.0
    for v in 0x00:0x0f:0xff
        @test 0.0 <= luminance(rgb(v, v, v)) <= 1.0
    end

    # Decoded, not raw: byte-midpoint grey is perceptually dark. A raw
    # (128/255 = 0.502) reading would put it above the 0.5 threshold.
    @test luminance(rgb(0x808080)) < 0.5
    @test luminance(rgb(0x808080)) ≈ 0.2159 atol = 1e-4

    # Rec. 709 weights: green dominates, blue barely registers.
    @test luminance(rgb(0, 255, 0)) > luminance(rgb(255, 0, 0))
    @test luminance(rgb(255, 0, 0)) > luminance(rgb(0, 0, 255))
    @test luminance(rgb(0, 255, 0)) ≈ 0.7152
    @test luminance(rgb(255, 0, 0)) ≈ 0.2126
    @test luminance(rgb(0, 0, 255)) ≈ 0.0722

    # Monotone along the grey axis.
    let prev = -1.0
        for v in 0x00:0xff
            l = luminance(rgb(v, v, v))
            @test l >= prev
            prev = l
        end
    end

    # Defined through to_rgb, so it works on indexed colors too.
    @test luminance(ansi16(15)) == 1.0
    @test luminance(ansi256(231)) == 1.0
    @test luminance(ansi256(16)) == 0.0
end

@testitem "color: color_distance is a symmetric linear-space metric" begin
    using ManyUI

    @test color_distance(rgb(1, 2, 3), rgb(1, 2, 3)) == 0.0
    @test color_distance(ansi16(9), rgb(255, 0, 0)) == 0.0

    a = rgb(10, 200, 30)
    b = rgb(240, 5, 90)
    @test color_distance(a, b) === color_distance(b, a)
    @test color_distance(a, b) > 0.0

    # Weighted, not raw: an equal byte step in green is further than the
    # same step in blue.
    dg = color_distance(rgb(0, 0, 0), rgb(0, 64, 0))
    db = color_distance(rgb(0, 0, 0), rgb(0, 0, 64))
    @test dg > db

    # Linear, not raw-byte: this is the property that stops mid-greys
    # from snapping to blue.
    @test rgb_to_ansi16(rgb(0x808080)) === ansi16(8)
    @test rgb_to_ansi16(rgb(0x707070)) !== ansi16(4)
    @test rgb_to_ansi16(rgb(0x707070)) !== ansi16(12)
end

@testitem "color: nearest indexed known vectors" begin
    using ManyUI

    # The four vectors named in the contract. Each is exact, and each
    # proves the SYSTEM colors 0:15 are NOT candidates: black would
    # otherwise resolve to 0, white to 15, red to 9 and #808080 to 8.
    @test rgb_to_ansi256(rgb(0, 0, 0)) === ansi256(16)
    @test rgb_to_ansi256(rgb(255, 255, 255)) === ansi256(231)
    @test rgb_to_ansi256(rgb(255, 0, 0)) === ansi256(196)
    @test rgb_to_ansi256(rgb(0x808080)) === ansi256(244)

    # Exact on every cube boundary and every grey-ramp step: the 240
    # candidate entries are pairwise distinct, so each is its own
    # unique nearest neighbour. This is the "exact on the cube
    # boundaries" law, not a round-trip.
    for i in 16:255
        @test rgb_to_ansi256(to_rgb(ansi256(i))) === ansi256(i)
    end

    # ... and the candidates really are pairwise distinct.
    @test length(Set(to_rgb(ansi256(i)) for i in 16:255)) == 240

    # Cube corners, by construction.
    @test rgb_to_ansi256(rgb(0, 0, 255)) === ansi256(21)
    @test rgb_to_ansi256(rgb(0, 255, 0)) === ansi256(46)
    @test rgb_to_ansi256(rgb(255, 255, 0)) === ansi256(226)
    @test rgb_to_ansi256(rgb(0, 255, 255)) === ansi256(51)
    @test rgb_to_ansi256(rgb(255, 0, 255)) === ansi256(201)

    # Every 16-color entry is its own nearest 16-color entry.
    for i in 0:15
        @test ansi256_to_ansi16(ansi16(i)) === ansi16(i)
    end
    @test length(Set(to_rgb(ansi16(i)) for i in 0:15)) == 16

    # Saturated primaries land on the bright half of the 16 palette.
    @test ansi256_to_ansi16(ansi256(196)) === ansi16(9)
    @test ansi256_to_ansi16(ansi256(46)) === ansi16(10)
    @test ansi256_to_ansi16(ansi256(21)) === ansi16(12)
    @test ansi256_to_ansi16(ansi256(16)) === ansi16(0)
    @test ansi256_to_ansi16(ansi256(231)) === ansi16(15)

    # Output kinds are the target kind, never RGB.
    @test rgb_to_ansi256(rgb(1, 2, 3)).kind === ColorKind.ANSI256
    @test ansi256_to_ansi16(ansi256(1)).kind === ColorKind.ANSI16
    @test rgb_to_ansi16(rgb(1, 2, 3)).kind === ColorKind.ANSI16

    # Both reducers are idempotent on their own output.
    for i in 16:255
        c = to_rgb(ansi256(i))
        @test rgb_to_ansi256(to_rgb(rgb_to_ansi256(c))) ===
              rgb_to_ansi256(c)
    end
end

@testitem "color: rgb_to_ansi16 equals the staged composition" begin
    using ManyUI

    # NORMATIVE: rgb_to_ansi16 is DEFINED as the composition, so
    # TrueColor->16 and TrueColor->256->16 cannot disagree.
    samples = Color[]
    for r in 0x00:0x1f:0xff, g in 0x00:0x1f:0xff, b in 0x00:0x1f:0xff
        push!(samples, rgb(r, g, b))
    end
    append!(samples, [rgb(0x808080), rgb(0x1e90ff), rgb(0xff8800),
                      rgb(0x123456), rgb(0xfedcba), rgb(0x0a0a0a)])
    append!(samples, [to_rgb(ansi256(i)) for i in 16:255])

    for c in samples
        @test rgb_to_ansi16(c) === ansi256_to_ansi16(rgb_to_ansi256(c))
    end
    @test length(samples) > 500
end

@testitem "color: color_distance ties go to lower index" begin
    using ManyUI

    # THE tie in this palette, and it is exact rather than a rounding
    # accident. Bytes 0, 4 and 8 all sit in the LINEAR branch of the
    # sRGB decode (f <= 0.04045, a plain division), and 4/255 and 8/255
    # differ by exactly a factor of two, so lin(8) == 2*lin(4) to the
    # bit. rgb(4,4,4) therefore lands exactly halfway between cube
    # entry 16 (0,0,0) and grey-ramp entry 232 (8,8,8): the two
    # candidates are EQUIDISTANT and only the tie-break decides.
    @test luminance(rgb(8, 8, 8)) == 2 * luminance(rgb(4, 4, 4))
    @test color_distance(rgb(4, 4, 4), ansi256(16)) ==
          color_distance(rgb(4, 4, 4), ansi256(232))
    @test rgb_to_ansi256(rgb(4, 4, 4)) === ansi256(16)   # LOWER wins
    @test rgb_to_ansi256(rgb(4, 4, 4)) !== ansi256(232)

    # A tie is only observable through a nearest-index search, so drive
    # it through one: scan the whole 256 palette with the PUBLIC metric,
    # collect every entry that ties the minimum, and require the search
    # to have returned the lowest of them.
    let checked = 0
        for c in (rgb(4, 4, 4), rgb(0x808080), rgb(0x1e90ff),
                  rgb(0x333333), rgb(0x5f8700), rgb(0x0b0b0b),
                  rgb(0x7f7f7f), rgb(0x80, 0x00, 0x00),
                  rgb(0x00, 0x87, 0x5f))
            ds = [color_distance(c, ansi256(i)) for i in 16:255]
            m = minimum(ds)
            tied = [i + 15 for i in eachindex(ds) if ds[i] == m]
            @test rgb_to_ansi256(c) === ansi256(minimum(tied))
            checked += 1
        end
        @test checked == 9
        # ... and the sweep above really did exercise a tie, so this
        # test cannot silently rot into a no-op.
        @test count(==(minimum(color_distance(rgb(4, 4, 4), ansi256(i))
                               for i in 16:255)),
                    [color_distance(rgb(4, 4, 4), ansi256(i))
                     for i in 16:255]) == 2
    end

    # Same rule for the 16-color search.
    for c in (rgb(0x808080), rgb(0x1e90ff), rgb(0xc0c0c0))
        ds = [color_distance(c, ansi16(i)) for i in 0:15]
        m = minimum(ds)
        tied = [i - 1 for i in eachindex(ds) if ds[i] == m]
        @test ansi256_to_ansi16(c) === ansi16(minimum(tied))
    end

    # Ties are broken low, so a degenerate zero-distance search returns
    # the first exact hit rather than an arbitrary one.
    @test rgb_to_ansi256(rgb(0, 0, 0)) === ansi256(16)
end

@testitem "color: degrade truth table and idempotence" begin
    using ManyUI

    D = ColorDepth
    depths = (D.MONOCHROME, D.ANSI16, D.ANSI256, D.TRUECOLOR)
    samples = (COLOR_UNSET, COLOR_DEFAULT,
               ansi16(0), ansi16(7), ansi16(9), ansi16(11), ansi16(15),
               ansi256(16), ansi256(21), ansi256(196), ansi256(231),
               ansi256(244), ansi256(3),
               rgb(0, 0, 0), rgb(255, 255, 255), rgb(255, 0, 0),
               rgb(0x808080), rgb(0x1e90ff), rgb(0xff8800))

    # TOTAL: never throws, always a Color, for every (kind, depth).
    # IDEMPOTENT: degrade(degrade(c, d), d) === degrade(c, d).
    for c in samples, d in depths
        x = degrade(c, d)
        @test x isa Color
        @test degrade(x, d) === x
    end

    # PURE: same inputs, same output, no hidden state.
    for c in samples, d in depths
        @test degrade(c, d) === degrade(c, d)
    end

    # --- TRUECOLOR column: identity for every kind ---
    for c in samples
        @test degrade(c, D.TRUECOLOR) === c
    end

    # --- ANSI256 column ---
    @test degrade(rgb(0x808080), D.ANSI256) === ansi256(244)
    @test degrade(rgb(0, 0, 0), D.ANSI256) === ansi256(16)
    @test degrade(rgb(255, 255, 255), D.ANSI256) === ansi256(231)
    @test degrade(ansi256(244), D.ANSI256) === ansi256(244)   # identity
    @test degrade(ansi16(9), D.ANSI256) === ansi16(9)         # identity
    @test degrade(COLOR_DEFAULT, D.ANSI256) === COLOR_DEFAULT
    @test degrade(COLOR_UNSET, D.ANSI256) === COLOR_UNSET

    # --- ANSI16 column ---
    @test degrade(rgb(255, 0, 0), D.ANSI16) === ansi16(9)
    @test degrade(rgb(0, 0, 0), D.ANSI16) === ansi16(0)
    @test degrade(rgb(255, 255, 255), D.ANSI16) === ansi16(15)
    @test degrade(ansi256(196), D.ANSI16) === ansi16(9)
    @test degrade(ansi256(231), D.ANSI16) === ansi16(15)
    @test degrade(ansi16(3), D.ANSI16) === ansi16(3)          # identity
    @test degrade(COLOR_DEFAULT, D.ANSI16) === COLOR_DEFAULT
    @test degrade(COLOR_UNSET, D.ANSI16) === COLOR_UNSET
    # RGB->16 must agree with RGB->256->16 through `degrade` too.
    for c in (rgb(0x1e90ff), rgb(0xff8800), rgb(0x123456))
        @test degrade(c, D.ANSI16) ===
              degrade(degrade(c, D.ANSI256), D.ANSI16)
    end

    # --- MONOCHROME column ---
    # RGB / ANSI256 rows: luminance >= 0.5 -> white else black.
    @test degrade(rgb(255, 255, 255), D.MONOCHROME) === ansi16(15)
    @test degrade(rgb(0, 0, 0), D.MONOCHROME) === ansi16(0)
    @test degrade(rgb(0x808080), D.MONOCHROME) === ansi16(0)
    @test degrade(rgb(255, 0, 0), D.MONOCHROME) === ansi16(0)
    @test degrade(rgb(0, 255, 0), D.MONOCHROME) === ansi16(15)
    @test degrade(ansi256(231), D.MONOCHROME) === ansi16(15)
    @test degrade(ansi256(16), D.MONOCHROME) === ansi16(0)
    @test degrade(ansi256(244), D.MONOCHROME) === ansi16(0)
    # ANSI16 row: index-based, NOT luminance. 7 and 15 are the only
    # entries that survive as white -- note ansi16(11) (yellow) is a
    # high-luminance colour that the index rule still sends to black.
    @test degrade(ansi16(7), D.MONOCHROME) === ansi16(15)
    @test degrade(ansi16(15), D.MONOCHROME) === ansi16(15)
    @test degrade(ansi16(0), D.MONOCHROME) === ansi16(0)
    @test degrade(ansi16(9), D.MONOCHROME) === ansi16(0)
    @test luminance(ansi16(11)) > 0.5
    @test degrade(ansi16(11), D.MONOCHROME) === ansi16(0)
    for i in 0:15
        want = (i == 7 || i == 15) ? ansi16(15) : ansi16(0)
        @test degrade(ansi16(i), D.MONOCHROME) === want
    end
    # DEFAULT/UNSET rows: identity at every depth, MONOCHROME included.
    @test degrade(COLOR_DEFAULT, D.MONOCHROME) === COLOR_DEFAULT
    @test degrade(COLOR_UNSET, D.MONOCHROME) === COLOR_UNSET
end

@testitem "color: MONOCHROME uses luminance not DEFAULT" begin
    using ManyUI

    # C's proposal (RGB -> COLOR_DEFAULT) is REJECTED: it collapses fg
    # and bg to the same value and loses the distinction entirely.
    for c in (rgb(255, 255, 255), rgb(0, 0, 0), rgb(0x808080),
              rgb(255, 0, 0), ansi256(244), ansi256(231))
        d = degrade(c, ColorDepth.MONOCHROME)
        @test d !== COLOR_DEFAULT
        @test d.kind === ColorKind.ANSI16
        @test color_index(d) in (0x00, 0x0f)
    end

    # A light fg on a dark bg stays legible after degradation.
    fg = degrade(rgb(0xf0f0f0), ColorDepth.MONOCHROME)
    bg = degrade(rgb(0x101010), ColorDepth.MONOCHROME)
    @test fg === ansi16(15)
    @test bg === ansi16(0)
    @test fg !== bg

    # The split is exactly the luminance >= 0.5 threshold, walked along
    # the grey axis: one flip, and it is where luminance crosses 0.5.
    let flips = 0
        for v in 0x01:0xff
            lo = degrade(rgb(v - 0x01, v - 0x01, v - 0x01),
                         ColorDepth.MONOCHROME)
            hi = degrade(rgb(v, v, v), ColorDepth.MONOCHROME)
            if lo !== hi
                flips += 1
                @test luminance(rgb(v - 0x01, v - 0x01, v - 0x01)) < 0.5
                @test luminance(rgb(v, v, v)) >= 0.5
            end
        end
        @test flips == 1
    end
end

@testitem "color: parse accepts every documented form" begin
    using ManyUI

    @test parse(Color, "#f80") === rgb(0xff, 0x88, 0x00)
    @test parse(Color, "#ff8800") === rgb(0xff8800)
    @test parse(Color, "#000") === rgb(0, 0, 0)
    @test parse(Color, "#ffffff") === rgb(255, 255, 255)
    @test parse(Color, "rgb(255,136,0)") === rgb(255, 136, 0)
    @test parse(Color, "rgb(255, 136, 0)") === rgb(255, 136, 0)
    @test parse(Color, "rgb( 0 , 0 , 0 )") === rgb(0, 0, 0)
    @test parse(Color, "red") === color(:red)
    @test parse(Color, "bright_black") === color(:bright_black)
    @test parse(Color, "bright_white") === ansi16(15)
    @test parse(Color, "ansi(9)") === ansi16(9)
    @test parse(Color, "ansi(0)") === ansi16(0)
    @test parse(Color, "color(200)") === ansi256(200)
    @test parse(Color, "color(0)") === ansi256(0)
    @test parse(Color, "default") === COLOR_DEFAULT
    @test parse(Color, "transparent") === COLOR_UNSET
    @test is_unset(parse(Color, "transparent"))

    # Whitespace-trimmed and case-insensitive.
    @test parse(Color, "  #F80  ") === rgb(0xff8800)
    @test parse(Color, "RED") === color(:red)
    @test parse(Color, " RGB(255,136,0) ") === rgb(255, 136, 0)
    @test parse(Color, "ANSI(9)") === ansi16(9)

    # tryparse returns nothing where parse throws.
    for bad in ("", "   ", "not-a-color", "#12345", "#gggggg", "#",
                "ansi(16)", "ansi(-1)", "ansi()", "ansi(x)",
                "color(256)", "color(-1)",
                "rgb(255,136)", "rgb(255,136,0,0)", "rgb(256,0,0)",
                "rgb(-1,0,0)", "rgb(a,b,c)", "rgb 255 136 0")
        @test tryparse(Color, bad) === nothing
        @test_throws ArgumentError parse(Color, bad)
    end

    # parse == tryparse wherever tryparse succeeds.
    for good in ("#f80", "#ff8800", "rgb(1,2,3)", "red", "ansi(9)",
                 "color(200)", "default", "transparent")
        @test parse(Color, good) === tryparse(Color, good)
    end

    # The documented forms round-trip against the constructors.
    @test tryparse(Color, "#ff8800") === tryparse(Color, "rgb(255,136,0)")
end

@testitem "color: detect_color_depth rule table" begin
    using ManyUI

    D = ColorDepth
    E(ps...) = Dict{String,String}(ps...)

    # Rule 1: NO_COLOR set, ANY value (empty string included), wins over
    # everything else.
    @test detect_color_depth(E("NO_COLOR" => "")) === D.MONOCHROME
    @test detect_color_depth(E("NO_COLOR" => "1")) === D.MONOCHROME
    @test detect_color_depth(E("NO_COLOR" => "0")) === D.MONOCHROME
    @test detect_color_depth(E("NO_COLOR" => "1",
                               "COLORTERM" => "truecolor",
                               "TERM" => "xterm-256color")) ===
          D.MONOCHROME

    # Rule 2: COLORTERM in {truecolor, 24bit}.
    @test detect_color_depth(E("COLORTERM" => "truecolor")) === D.TRUECOLOR
    @test detect_color_depth(E("COLORTERM" => "24bit")) === D.TRUECOLOR
    @test detect_color_depth(E("COLORTERM" => "truecolor",
                               "TERM" => "dumb")) === D.TRUECOLOR
    @test detect_color_depth(E("COLORTERM" => "truecolor",
                               "TERM" => "xterm-256color")) === D.TRUECOLOR
    # ... and only those two values.
    @test detect_color_depth(E("COLORTERM" => "yes",
                               "TERM" => "xterm")) === D.ANSI16

    # Rule 3: TERM CONTAINS "256color" (substring, not equality).
    @test detect_color_depth(E("TERM" => "xterm-256color")) === D.ANSI256
    @test detect_color_depth(E("TERM" => "screen-256color")) === D.ANSI256
    @test detect_color_depth(E("TERM" => "tmux-256color")) === D.ANSI256

    # Rule 4: TERM == "dumb", or TERM absent.
    @test detect_color_depth(E("TERM" => "dumb")) === D.MONOCHROME
    @test detect_color_depth(E()) === D.MONOCHROME
    @test detect_color_depth(E("COLORTERM" => "")) === D.MONOCHROME

    # Rule 5: otherwise.
    @test detect_color_depth(E("TERM" => "xterm")) === D.ANSI16
    @test detect_color_depth(E("TERM" => "vt100")) === D.ANSI16
    @test detect_color_depth(E("TERM" => "screen")) === D.ANSI16
    @test detect_color_depth(E("TERM" => "linux")) === D.ANSI16

    # Pure: no globals read, no side effects, same answer twice.
    env = E("TERM" => "xterm-256color")
    @test detect_color_depth(env) === detect_color_depth(env)
    @test length(env) == 1

    # Defaults to ENV and stays type-stable on it.
    @test detect_color_depth() isa ColorDepth.T
    @test detect_color_depth(ENV) isa ColorDepth.T
end

@testitem "color: degrade is allocation-free on the hot path" begin
    using ManyUI

    # `degrade` runs once per Style per span inside AnsiEncoder; it must
    # not put the GC on the render path.
    f(c, d) = degrade(c, d)
    for c in (rgb(0x1e90ff), ansi256(200), ansi16(3), COLOR_DEFAULT),
        d in (ColorDepth.MONOCHROME, ColorDepth.ANSI16,
              ColorDepth.ANSI256, ColorDepth.TRUECOLOR)
        f(c, d)                       # warm up
        @test (@allocated f(c, d)) == 0
    end
end
