# richtext_tests.jl -- @testitem blocks for src/richtext.jl.
# Written BEFORE the implementation (TDD, CLAUDE.md).
#
# The load-bearing property is the WRAP INVARIANT, proven by
# "richtext: wrap agrees with the plain-string wrap": styling a string
# must not change where it breaks. Everything else is a consequence.

@testitem "richtext: TextRun defaults to the inherited style" begin
    using ManyUI

    r = TextRun("hi")
    @test r.text == "hi"
    @test r.style == STYLE_NONE

    st = Style(bold = true)
    @test TextRun("hi", st).style == st

    # Value equality, not identity: the field is a String, so `===`
    # would be false for two equal runs built separately.
    @test TextRun("hi") == TextRun("hi")
    @test hash(TextRun("hi")) == hash(TextRun("hi"))
    @test TextRun("hi") != TextRun("hi", st)
end

@testitem "richtext: the constructor normalises" begin
    using ManyUI

    bold = Style(bold = true)

    # Empty runs carry nothing and are dropped.
    @test RichText([TextRun(""), TextRun("a"), TextRun("")]).runs ==
          [TextRun("a")]

    # Adjacent runs with the SAME style coalesce: two ways of spelling
    # the same text must compare equal, or `==` is useless as an oracle
    # and every test below has to know how the text was built.
    @test RichText([TextRun("ab"), TextRun("cd")]) == RichText("abcd")
    @test RichText([TextRun("ab"), TextRun("cd")]).runs == [TextRun("abcd")]

    # Adjacent runs with DIFFERENT styles do not.
    rt = RichText([TextRun("a", bold), TextRun("b")])
    @test length(rt.runs) == 2

    # Coalescing is transitive across a dropped empty run.
    @test RichText([TextRun("a"), TextRun(""), TextRun("b")]).runs ==
          [TextRun("ab")]

    @test isempty(RichText())
    @test isempty(RichText(""))
    @test !isempty(RichText("a"))
    @test hash(RichText("abcd")) ==
          hash(RichText([TextRun("ab"), TextRun("cd")]))
end

@testitem "richtext: construction from strings and runs" begin
    using ManyUI

    warn = Style(fg = rgb(255, 200, 0), bold = true)

    @test RichText("plain") == RichText([TextRun("plain", STYLE_NONE)])
    @test RichText("hot", warn) == RichText([TextRun("hot", warn)])

    # Varargs of runs -- the tab-caption idiom: a styled key, then a
    # caption in the inherited style.
    rt = RichText(TextRun("1", warn), TextRun(" Server"))
    @test length(rt.runs) == 2
    @test plain(rt) == "1 Server"
    @test rt.runs[1].style == warn
    @test rt.runs[2].style == STYLE_NONE
end

@testitem "richtext: plain and String drop the styling" begin
    using ManyUI

    rt = RichText(TextRun("1", Style(bold = true)), TextRun(" Server"))
    @test plain(rt) == "1 Server"
    @test String(rt) == "1 Server"
    @test plain(RichText()) == ""
end

@testitem "richtext: text_width sums the runs on grapheme widths" begin
    using ManyUI

    bold = Style(bold = true)

    @test text_width(RichText()) == 0
    @test text_width(RichText("abc")) == 3
    @test text_width(RichText(TextRun("ab", bold), TextRun("c"))) == 3

    # A wide cluster counts 2 wherever it sits, and splitting the text
    # into runs must not change the total -- the width of a line is a
    # property of its text, not of how it was styled.
    wide = RichText(TextRun("好", bold), TextRun("a"))
    @test text_width(wide) == 3
    @test text_width(wide) == text_width(plain(wide))
end

@testitem "richtext: concatenation" begin
    using ManyUI

    bold = Style(bold = true)
    a = RichText("ab", bold)
    b = RichText("cd")

    @test plain(a * b) == "abcd"
    @test length((a * b).runs) == 2
    @test (a * "cd") == a * b
    @test ("ab" * b) == RichText("abcd")

    # Concatenation is associative and STYLE_NONE-empty is its identity.
    @test (a * b) * RichText("e") == a * (b * RichText("e"))
    @test a * RichText() == a
    @test RichText() * a == a
end

@testitem "richtext: truncate_width keeps a prefix" begin
    using ManyUI

    bold = Style(bold = true)
    rt = RichText(TextRun("abc", bold), TextRun("def"))

    @test truncate_width(rt, 0) == RichText()
    @test truncate_width(rt, -1) == RichText()
    @test truncate_width(rt, 100) == rt

    # A cut inside the first run drops the second entirely.
    @test truncate_width(rt, 2) == RichText("ab", bold)
    # A cut exactly on the run boundary keeps run 1 whole and no more.
    @test truncate_width(rt, 3) == RichText("abc", bold)
    # A cut inside the second run keeps the first whole.
    @test truncate_width(rt, 4) == RichText(TextRun("abc", bold), TextRun("d"))

    # The width of the result never exceeds the budget, and the plain
    # text agrees with truncating the plain text -- same rule, one
    # implementation of it.
    for w = 0:8
        @test text_width(truncate_width(rt, w)) <= w
        @test plain(truncate_width(rt, w)) == truncate_width(plain(rt), w)
    end
end

@testitem "richtext: truncate_width drops a straddling wide cluster whole" begin
    using ManyUI

    bold = Style(bold = true)
    # "好" is width 2. With a budget of 1 it cannot be halved.
    rt = RichText(TextRun("好", bold), TextRun("a"))

    @test truncate_width(rt, 1) == RichText()
    @test truncate_width(rt, 2) == RichText("好", bold)
    @test truncate_width(rt, 3) == rt

    # STOPPING, not skipping: the budget of 1 left by "好" is NOT then
    # spent on the narrow "a" that follows. Truncation yields a prefix,
    # and "a" is not a prefix of "好a". This mirrors the string rule in
    # unicode.jl, which breaks out of its scan rather than continuing.
    @test plain(truncate_width(rt, 1)) == truncate_width(plain(rt), 1)
end

@testitem "richtext: wrap agrees with the plain-string wrap" begin
    using ManyUI

    bold = Style(bold = true)
    warn = Style(fg = rgb(255, 0, 0))

    cases = [
        RichText("the quick brown fox jumps over the lazy dog"),
        RichText(TextRun("the quick ", bold), TextRun("brown fox jumps")),
        RichText(TextRun("alpha", bold), TextRun(" beta ", warn),
                 TextRun("gamma delta")),
        RichText(TextRun("supercalifragilistic", bold), TextRun(" ok")),
        RichText(TextRun("line one\nline two", warn)),
        RichText(TextRun("好好好 好好好", bold), TextRun(" tail")),
    ]

    # THE invariant: adding style to a string must not move a single
    # break. Anything else and a Label would reflow when it is coloured.
    for rt in cases, w = 1:24
        @test plain.(wrap_width(rt, w)) == wrap_width(plain(rt), w)
    end
end

@testitem "richtext: wrap carries the styling onto each line" begin
    using ManyUI

    bold = Style(bold = true)
    rt = RichText(TextRun("aaa", bold), TextRun(" bbb"))

    lines = wrap_width(rt, 3)
    @test length(lines) == 2
    @test lines[1] == RichText("aaa", bold)
    @test lines[2] == RichText("bbb")

    # No line may exceed the budget it was wrapped to.
    for w = 1:12, l in wrap_width(rt, w)
        @test text_width(l) <= max(w, text_width(l))
    end

    @test wrap_width(RichText(), 10) == RichText[]
    @test wrap_width(RichText("abc"), 0) == RichText[]
end

@testitem "richtext: wrap splits a word that spans two runs" begin
    using ManyUI

    bold = Style(bold = true)
    # A single word whose first half is bold: the break falls INSIDE
    # the styled run, so the style has to survive the split.
    rt = RichText(TextRun("abcd", bold), TextRun("efgh"))

    lines = wrap_width(rt, 3)
    @test plain.(lines) == ["abc", "def", "gh"]
    @test lines[1] == RichText("abc", bold)
    # The middle line straddles the run boundary and keeps both styles.
    @test lines[2] == RichText(TextRun("d", bold), TextRun("ef"))
    @test lines[3] == RichText("gh")
end

@testitem "richtext: the joining space takes the style it replaced" begin
    using ManyUI

    warn = Style(fg = rgb(255, 0, 0))
    # Wrapping collapses a run of whitespace to one space. That space
    # is still a cell with a background, so it must inherit the style
    # of the whitespace it stands for rather than silently reset.
    rt = RichText(TextRun("aa", Style(bold = true)),
                  TextRun("   ", warn), TextRun("bb"))

    lines = wrap_width(rt, 10)
    @test length(lines) == 1
    @test plain(lines[1]) == "aa bb"
    @test lines[1].runs[2] == TextRun(" ", warn)
end

@testitem "richtext: a run style resolves against the widget style" begin
    using ManyUI

    # Painting folds each run over the widget's computed style with the
    # cascade's own monoid, so an unstyled run is EXACTLY the widget
    # style and a styled one overrides only what it names.
    base = Style(fg = rgb(200, 200, 200), bg = rgb(0, 0, 0), italic = true)

    @test merge(base, STYLE_NONE) == base

    over = Style(fg = rgb(255, 0, 0), bold = true)
    got = merge(base, over)
    @test got.fg == rgb(255, 0, 0)
    @test got.bg == rgb(0, 0, 0)          # not named by the run: kept
    @test has(got, Attr.BOLD)             # named by the run: applied
    @test has(got, Attr.ITALIC)           # not named: inherited
end
