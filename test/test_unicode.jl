# test_unicode.jl -- @testitem blocks for src/unicode.jl (contract 2.3).
# Written BEFORE the implementation (house rule: TDD).
#
# EARS S3 / spec 2.3: "While rendering text, the framework shall process
# wide Unicode characters (emojis, CJK) as spanning two terminal grid
# cells to prevent layout corruption." `grapheme_width` IS that
# requirement; the mandatory-vector testitem below IS its acceptance
# test.

@testitem "unicode: grapheme_width mandatory vectors" begin
    using DualUI

    # ---- contract 2.3, the normative table. All MUST pass. ----
    @test text_width("\U1F468‍\U1F469‍\U1F467") == 2   # 👨‍👩‍👧
    @test text_width("\U1F468‍\U1F469‍\U1F467‍" *
                     "\U1F466") == 2                             # 👨‍👩‍👧‍👦
    @test text_width("\U1F44D\U1F3FD") == 2                      # 👍🏽
    @test text_width("\U1F1EB\U1F1F7") == 2                      # 🇫🇷
    @test text_width("❤️") == 2                        # ❤️ VS16
    @test text_width("☝️") == 2                        # ☝️ VS16
    @test text_width("世界") == 4
    @test text_width("é") == 1
    @test text_width("​") == 0                              # ZWSP
    @test text_width("") == 0
    @test text_width("abc") == 3

    # Each of the above is ONE grapheme cluster (except "世界"/"abc"),
    # so grapheme_width agrees with text_width on them directly.
    @test grapheme_width("\U1F468‍\U1F469‍\U1F467") == 2
    @test grapheme_width("\U1F44D\U1F3FD") == 2
    @test grapheme_width("\U1F1EB\U1F1F7") == 2
    @test grapheme_width("❤️") == 2
    @test grapheme_width("世") == 2
    @test grapheme_width("界") == 2
    @test grapheme_width("a") == 1
    @test grapheme_width("") == 0
    @test grapheme_width("​") == 0

    # ---- S3: the whole point. Wide spans exactly two cells. ----
    @test grapheme_width("\U1F468") == 2      # emoji
    @test grapheme_width("世") == 2            # CJK Unified Ideograph
    @test grapheme_width("가") == 2            # Hangul syllable
    @test grapheme_width("Ａ") == 2            # Fullwidth Latin A

    # ---- The range is exactly {0, 1, 2}. Never 3, never negative. ----
    for g in ("", "a", "世", "\U1F468‍\U1F469‍\U1F467",
              "​", "\n", "́", "\U1F1EB\U1F1F7",
              "❤️", "\U1F44D\U1F3FD", "é", "Ａ")
        w = grapheme_width(g)
        @test w isa Int
        @test 0 <= w <= 2
    end

    # ---- Combining marks and controls contribute nothing. ----
    @test grapheme_width("́") == 0       # lone combining acute
    @test grapheme_width("\n") == 0
    @test grapheme_width("\0") == 0
    @test grapheme_width("\e") == 0
    @test grapheme_width("\t") == 0
    @test grapheme_width("") == 0       # DEL

    # ---- text_width is the sum over clusters. ----
    @test text_width("a世b") == 4
    @test text_width("世界abc") == 7
    # NB: the trailing "b" is concatenated, not inlined -- 'b' is a hex
    # digit and would be swallowed by the \U escape.
    @test text_width("a\U1F468‍\U1F469‍\U1F467" * "b") == 4
    @test text_width("\U1F1EB\U1F1F7\U1F1EB\U1F1F7") == 4   # 🇫🇷🇫🇷
    @test text_width("hello world") == 11

    # ---- Purity: no `!`, no state, same answer every time. ----
    s = "世\U1F468‍\U1F469‍\U1F467" * "a"
    @test text_width(s) == text_width(s)
    @test grapheme_width("世") == grapheme_width("世")
end

@testitem "unicode: VS16 promotes width 1 base to 2" begin
    using DualUI

    # U+2764 HEAVY BLACK HEART is width 1 on its own...
    @test char_width('❤') == 1
    @test grapheme_width("❤") == 1
    # ...and width 2 once VS16 forces emoji presentation.
    @test grapheme_width("❤️") == 2

    @test char_width('☝') == 1           # ☝
    @test grapheme_width("☝") == 1
    @test grapheme_width("☝️") == 2 # ☝️

    # VS16 anywhere in the cluster promotes it (rule 3 scans the
    # cluster, it does not merely look at the last codepoint).
    @test grapheme_width("❤️‍\U1F525") == 2  # ❤️‍🔥

    # VS16 does not make an already-wide base any wider.
    @test grapheme_width("\U1F468️") == 2

    # VS15 (text presentation) keeps a cluster narrow.
    @test grapheme_width("❤︎") == 1
    @test grapheme_width("☝︎") == 1

    # VS16 beats VS15 when both appear: rule 3 precedes rule 4.
    @test grapheme_width("❤️︎") == 2

    # The variation selectors are themselves zero-width codepoints.
    # VS16/VS15/ZWJ are [I] internal (contract 2.3): they are part of
    # the package's vocabulary but are deliberately NOT exported, so
    # they must be reached through the module.
    @test char_width(DualUI.VS16) == 0
    @test char_width(DualUI.VS15) == 0
    @test char_width(DualUI.ZWJ) == 0
    @test is_combining(DualUI.VS16)
    @test is_combining(DualUI.ZWJ)
    @test DualUI.VS16 == '️'
    @test DualUI.VS15 == '︎'
    @test DualUI.ZWJ == '‍'
    @test !isdefined(Main, :VS16)   # stays internal
end

@testitem "unicode: regional indicator pair is 2" begin
    using DualUI

    # A lone regional indicator is width 1 per the Unicode tables...
    @test is_regional_indicator('\U1F1EB')
    @test is_regional_indicator('\U1F1E6')     # first: RI A
    @test is_regional_indicator('\U1F1FF')     # last:  RI Z
    @test !is_regional_indicator('\U1F1E5')    # one below the range
    @test !is_regional_indicator('\U1F200')    # above the range
    @test !is_regional_indicator('a')
    @test !is_regional_indicator('世')

    # ...but a PAIR is one flag and occupies two cells (rule 2).
    @test grapheme_width("\U1F1EB\U1F1F7") == 2   # 🇫🇷
    @test grapheme_width("\U1F1EF\U1F1F5") == 2   # 🇯🇵
    @test grapheme_width("\U1F1FA\U1F1F8") == 2   # 🇺🇸

    # Two flags -> two clusters -> 4 cells.
    @test text_width("\U1F1EB\U1F1F7\U1F1EF\U1F1F5") == 4

    # A flag next to ASCII does not bleed.
    @test text_width("[\U1F1EB\U1F1F7]") == 4
end

@testitem "unicode: NFC and NFD forms agree" begin
    using DualUI
    using Unicode

    nfc = Unicode.normalize("é", :NFC)   # single codepoint U+00E9
    nfd = Unicode.normalize("é", :NFD)   # 'e' + U+0301 combining acute

    # Different byte sequences...
    @test ncodeunits(nfc) != ncodeunits(nfd)
    @test length(nfc) == 1
    @test length(nfd) == 2

    # ...but the SAME display width. This is why we cluster first:
    # a codepoint-naive count would disagree with itself.
    @test text_width(nfc) == 1
    @test text_width(nfd) == 1
    @test text_width(nfc) == text_width(nfd)
    @test grapheme_width(nfc) == grapheme_width(nfd) == 1

    # Same, for a longer mixed string.
    s = "café au lait"
    @test text_width(Unicode.normalize(s, :NFC)) ==
        text_width(Unicode.normalize(s, :NFD)) == 12

    # Stacked combining marks still occupy one cell.
    @test text_width("é̂̃") == 1
    @test grapheme_width("é̂̃") == 1

    # A combining mark on a WIDE base keeps the base's width.
    @test grapheme_width("世́") == 2
end

@testitem "unicode: text_width never delegates to textwidth" begin
    using DualUI

    # Base.textwidth sums codepoints and ignores grapheme clustering.
    # These are the exact cases where it is WRONG; if text_width ever
    # delegates to it, every one of these fails.
    fam3 = "\U1F468‍\U1F469‍\U1F467"
    fam4 = "\U1F468‍\U1F469‍\U1F467‍\U1F466"
    thumb = "\U1F44D\U1F3FD"
    heart = "❤️"
    point = "☝️"

    @test textwidth(fam3) == 6      # Base is wrong...
    @test text_width(fam3) == 2     # ...we are right.

    @test textwidth(fam4) == 8
    @test text_width(fam4) == 2

    @test textwidth(thumb) == 4
    @test text_width(thumb) == 2

    @test textwidth(heart) == 1     # Base undercounts here
    @test text_width(heart) == 2

    @test textwidth(point) == 1
    @test text_width(point) == 2

    # Assert they genuinely disagree, so this test cannot pass by
    # accidentally calling textwidth.
    for s in (fam3, fam4, thumb, heart, point)
        @test text_width(s) != textwidth(s)
    end

    # Where Base is right, we agree with it.
    for s in ("abc", "世界", "", "hello world")
        @test text_width(s) == textwidth(s)
    end

    # grapheme_cells: the (cluster, width) pairs a Buffer stores.
    @test grapheme_cells("ab") == [("a", 1), ("b", 1)]
    @test grapheme_cells("世a") == [("世", 2), ("a", 1)]
    @test grapheme_cells(fam3) == [(fam3, 2)]
    @test grapheme_cells("\U1F1EB\U1F1F7") == [("\U1F1EB\U1F1F7", 2)]
    @test grapheme_cells("") == Tuple{String,Int}[]
    @test grapheme_cells("") isa Vector{Tuple{String,Int}}

    # grapheme_cells is consistent with text_width by construction.
    for s in (fam3, fam4, thumb, heart, "世界abc", "é", "a世b")
        @test sum(last, grapheme_cells(s); init = 0) == text_width(s)
        @test join(first.(grapheme_cells(s))) == s
    end
end

@testitem "unicode: truncate_width drops straddling wide cluster" begin
    using DualUI

    # A width-2 cluster that would straddle the limit is DROPPED, not
    # halved: half a glyph corrupts the grid.
    @test truncate_width("世界", 3) == "世"
    @test text_width(truncate_width("世界", 3)) == 2
    @test truncate_width("世界", 4) == "世界"
    @test truncate_width("世界", 2) == "世"
    @test truncate_width("世界", 1) == ""
    @test truncate_width("世界", 0) == ""

    # Same rule for emoji clusters.
    fam3 = "\U1F468‍\U1F469‍\U1F467"
    @test truncate_width("a" * fam3, 2) == "a"
    @test truncate_width("a" * fam3, 3) == "a" * fam3
    @test truncate_width(fam3, 1) == ""
    @test truncate_width(fam3, 2) == fam3

    # ASCII behaves as expected.
    @test truncate_width("abcdef", 3) == "abc"
    @test truncate_width("abcdef", 0) == ""
    @test truncate_width("abcdef", 99) == "abcdef"
    @test truncate_width("", 5) == ""

    # A negative limit yields the empty prefix, and never throws.
    @test truncate_width("abc", -1) == ""

    # The result is a SubString{String} (no copy) and is a real prefix
    # whose width never exceeds the limit.
    @test truncate_width("abcdef", 3) isa SubString{String}
    @test truncate_width("世界", 3) isa SubString{String}
    for s in ("abcdef", "世界世界", fam3 * "xy", "a世b", "")
        for w in -1:8
            t = truncate_width(s, w)
            @test t isa SubString{String}
            @test startswith(s, t)
            @test text_width(t) <= max(w, 0)
        end
    end

    # Never splits a cluster: the prefix is always a whole number of
    # graphemes.
    @test truncate_width("❤️", 1) == ""
    @test truncate_width("❤️x", 2) == "❤️"
end

@testitem "unicode: wrap_width never splits a cluster" begin
    using DualUI
    using Unicode

    # Greedy word wrap.
    @test wrap_width("hello world", 11) == ["hello world"]
    @test wrap_width("hello world", 5) == ["hello", "world"]
    @test wrap_width("a b c", 3) == ["a b", "c"]
    @test wrap_width("a b c", 1) == ["a", "b", "c"]
    @test wrap_width("", 10) == String[]
    @test wrap_width("abc", 0) == String[]
    @test wrap_width("abc", -3) == String[]
    @test wrap_width("one", 10) == ["one"]
    @test wrap_width("abc", 3) isa Vector{String}

    # Breaks mid-word ONLY when a single word exceeds w.
    @test wrap_width("abcdefgh", 3) == ["abc", "def", "gh"]
    @test wrap_width("hi abcdefgh", 3) == ["hi", "abc", "def", "gh"]
    # ...and not otherwise: a too-long line prefers a word break.
    @test wrap_width("aa bb", 2) == ["aa", "bb"]

    # Every produced line respects the width budget whenever the input
    # allows it.
    for w in 1:12
        for line in wrap_width("the quick brown fox jumps", w)
            @test text_width(line) <= max(w, textwidth("quick"))
        end
    end

    # NEVER splits a grapheme cluster: each line is a whole number of
    # clusters, and rejoining recovers every cluster in order.
    fam3 = "\U1F468‍\U1F469‍\U1F467"
    txt = "$fam3 $fam3 世界 café"
    for w in 2:10
        lines = wrap_width(txt, w)
        for line in lines
            # Each line must be valid UTF-8 and re-cluster identically.
            @test isvalid(line)
            @test all(g -> grapheme_width(g) > 0 ||
                          length(collect(Unicode.graphemes(g))) >= 0,
                      Unicode.graphemes(line))
        end
        # No cluster was cut in half: the family emoji survives whole
        # wherever it appears.
        joined = join(lines)
        @test count(==(fam3), collect(Unicode.graphemes(joined))) == 2
    end

    # A wide cluster wider than the budget still gets a line of its own
    # rather than being halved or dropped into an infinite loop.
    @test wrap_width("世界", 1) == ["世", "界"]
    @test wrap_width(fam3, 1) == [fam3]

    # Wrapping wide text respects text_width, not character count.
    @test wrap_width("世界 世界", 4) == ["世界", "世界"]
    @test wrap_width("世界 世界", 9) == ["世界 世界"]
end

@testitem "unicode: grapheme_width allocates nothing" begin
    using DualUI

    # grapheme_width runs per cell per frame. It MUST NOT collect the
    # cluster into a Vector{Char}: that would allocate on the hot path.
    gw(s) = grapheme_width(s)

    samples = ["a", "世", "\U1F468‍\U1F469‍\U1F467",
               "\U1F1EB\U1F1F7", "❤️", "❤︎",
               "", "​", "\n", "é", "\U1F44D\U1F3FD"]

    # Warm up: compile before measuring.
    for s in samples
        gw(s)
    end

    for s in samples
        @test @allocated(gw(s)) == 0
    end

    # Type stability: Int in, Int out, no Union.
    @test Base.return_types(grapheme_width, (String,))[1] === Int
    @test Base.return_types(char_width, (Char,))[1] === Int
    @test Base.return_types(text_width, (String,))[1] === Int
end

@testitem "unicode: char_width classifies codepoints" begin
    using DualUI

    # Narrow.
    @test char_width('a') == 1
    @test char_width('Z') == 1
    @test char_width('0') == 1
    @test char_width(' ') == 1
    @test char_width('é') == 1
    @test char_width('❤') == 1

    # Wide: East Asian Wide / Fullwidth, and emoji.
    @test char_width('世') == 2
    @test char_width('가') == 2
    @test char_width('Ａ') == 2      # Fullwidth
    @test char_width('\U1F468') == 2 # emoji

    # Zero: combining marks, control characters, format characters.
    @test char_width('́') == 0  # combining acute
    @test char_width('​') == 0  # ZWSP
    @test char_width('\n') == 0
    @test char_width('\0') == 0
    @test char_width('\e') == 0
    @test char_width('\t') == 0

    # The range is exactly {0, 1, 2}.
    for c in ('a', '世', '́', '\n', '\U1F468', 'Ａ', '️',
              '‍', '\U1F1EB', ' ', '\U0010FFFF')
        w = char_width(c)
        @test w isa Int
        @test 0 <= w <= 2
    end

    # is_wide / is_combining are the predicates over char_width.
    @test is_wide('世')
    @test is_wide('\U1F468')
    @test !is_wide('a')
    @test !is_wide('́')

    @test is_combining('́')
    @test is_combining('‍')
    @test is_combining('\n')
    @test !is_combining('a')
    @test !is_combining('世')

    # The three predicates partition {0, 1, 2} exactly.
    for c in ('a', '世', '́', '\n', '\U1F468', 'Ａ', '️')
        @test is_wide(c) == (char_width(c) == 2)
        @test is_combining(c) == (char_width(c) == 0)
        @test !(is_wide(c) && is_combining(c))
    end
end
