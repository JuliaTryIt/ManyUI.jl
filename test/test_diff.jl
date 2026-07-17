# test_diff.jl -- E2 (minimal change set) and S3 (wide graphemes).
#
# Test item names are the ones contract section 4 mandates; the
# traceability matrix resolves E2 to "diff: round-trip apply! law".

@testitem "diff: identical buffers produce an empty patch" begin
    using DualUI

    a = Buffer(20, 5)
    write_text!(a, 3, 2, "hello")
    write_text!(a, 1, 4, "世界")
    b = copy(a)

    p = diff(a, b)
    @test isempty(p)
    @test length(p) == 0
    @test n_cells(p) == 0
    @test !p.full
    @test p.size == Size(20, 5)

    # A buffer always matches itself, including a wide glyph.
    @test isempty(diff(a, a))
    # Degenerate grids do not throw.
    @test isempty(diff(Buffer(0, 0), Buffer(0, 0)))
end

@testitem "diff: round-trip apply! law" begin
    using DualUI

    # E2, the strongest available test: whatever `diff` emits must be
    # exactly enough to turn `a` into `b`. If the diff drops a cell the
    # law fails; if it is merely non-minimal the law still holds, which
    # is why the minimality tests below are separate.
    law(a, b) = apply!(copy(a), diff(a, b)) == b

    a = Buffer(12, 4)
    b = copy(a)
    write_text!(b, 2, 2, "hi")
    @test law(a, b)
    @test law(b, a)

    # Wide graphemes, styles, and mixed content.
    c = Buffer(12, 4)
    write_text!(c, 1, 1, "世界", Style(fg = rgb(255, 0, 0), bold = true))
    write_text!(c, 4, 3, "ab")
    @test law(a, c)
    @test law(c, a)
    @test law(b, c)

    # A deterministic pseudo-random sweep. A hand-rolled LCG keeps the
    # test self-contained and reproducible without a Random dependency.
    seed = Ref(UInt32(2463534242))
    function nxt()
        s = seed[]
        s = xor(s, s << 13)
        s = xor(s, s >> 17)
        s = xor(s, s << 5)
        seed[] = s
        return s
    end
    pool = ["a", "b", " ", "世", "👍🏽", "é"]
    for trial in 1:40
        w, h = 9, 4
        x, y = Buffer(w, h), Buffer(w, h)
        for buf in (x, y), row in 1:h
            col = 1
            while col <= w
                g = pool[(nxt() % length(pool)) + 1]
                st = iseven(nxt() % 2) ? STYLE_NONE :
                     Style(fg = rgb(nxt() % 256, 0, 0))
                adv = set_cell!(buf, col, row, g, st)
                col += max(1, adv)
            end
        end
        @test law(x, y)
        @test law(y, x)
    end
end

@testitem "diff: gap coalesces near runs" begin
    using DualUI

    a = Buffer(20, 1)
    b = copy(a)
    # Two changed cells with exactly two unchanged cells between them.
    set_cell!(b, 1, 1, "x", STYLE_NONE)
    set_cell!(b, 4, 1, "y", STYLE_NONE)

    # Default gap = 4: a 2-cell hole is cheaper to bridge than to jump.
    p = diff(a, b)
    @test length(p) == 1
    @test p.spans[1].x == 1
    @test length(p.spans[1].cells) == 4

    # gap = 0 never bridges: two runs stay two spans.
    p0 = diff(a, b; gap = 0)
    @test length(p0) == 2
    @test p0.spans[1] == Span(1, 1, [b[1, 1]])
    @test p0.spans[2] == Span(4, 1, [b[4, 1]])

    # The boundary is inclusive: a hole of exactly `gap` merges, one
    # cell wider does not.
    @test length(diff(a, b; gap = 2)) == 1
    @test length(diff(a, b; gap = 1)) == 2

    # A trailing unchanged stretch is never bridged: the span stops at
    # the last changed cell rather than running to the row's end.
    @test p.spans[end].x + length(p.spans[end].cells) - 1 == 4

    # Bridging only ever adds cells, never drops them: the law holds at
    # every gap, and every patch still repaints at least what changed.
    nchanged = count(i -> a[i] != b[i], eachindex(a))
    for g in 0:6
        @test apply!(copy(a), diff(a, b; gap = g)) == b
        @test n_cells(diff(a, b; gap = g)) >= nchanged
    end
    @test_throws ArgumentError diff(a, b; gap = -1)
end

@testitem "diff: size mismatch produces a full patch" begin
    using DualUI

    a = Buffer(10, 3)
    write_text!(a, 1, 1, "old")
    b = Buffer(6, 2)
    write_text!(b, 1, 1, "new")

    p = diff(a, b)
    @test p.full
    @test p.size == Size(6, 2)
    # Spans cover all of `new`: one per row, full width.
    @test length(p) == 2
    @test all(s -> s.x == 1 && length(s.cells) == 6, p.spans)
    @test n_cells(p) == 12
    # It reconstructs `b` from a blank grid of the NEW size -- the only
    # thing the terminal can be assumed to hold after a reflow.
    @test apply!(Buffer(6, 2), p) == b

    # Same-size buffers never take this branch.
    @test !diff(a, copy(a)).full
    # A mismatch on either axis alone still forces full.
    @test diff(a, Buffer(10, 2)).full
    @test diff(a, Buffer(9, 3)).full

    # full_patch itself: every row, one span, full = true.
    fp = full_patch(a)
    @test fp.full
    @test fp.size == Size(10, 3)
    @test length(fp) == 3
    @test n_cells(fp) == 30
    @test apply!(Buffer(10, 3), fp) == a
end

@testitem "diff: span never starts on a continuation" begin
    using DualUI

    # S3. A width-2 glyph occupies a head plus a CELL_CONT. If a span
    # could begin on the CONT, the encoder would place the cursor
    # inside the glyph and the terminal would print half of it.
    is_head(c) = c.width == Int8(2)
    is_cont(c) = c.width == Int8(0)
    function assert_aligned(p, new)
        for s in p.spans
            @test !is_cont(new[s.x, s.y])
            @test !is_head(new[s.x + length(s.cells) - 1, s.y])
        end
    end

    # A head whose only change is its STYLE still pulls in its CONT, so
    # the span cannot end mid-grapheme.
    a = Buffer(8, 1)
    write_text!(a, 3, 1, "世", STYLE_NONE)
    b = copy(a)
    set_cell!(b, 3, 1, "世", Style(fg = rgb(0, 255, 0)))
    p = diff(a, b)
    @test p.spans[1].x == 3
    @test length(p.spans[1].cells) == 2
    assert_aligned(p, b)

    # A changed CONT walks LEFT to its head: here only cell 4 differs,
    # yet the span must start at 3. The stale cell is written raw, the
    # way a partial redraw would leave it.
    stale = Buffer(8, 1)
    write_text!(stale, 3, 1, "世")
    fresh = copy(stale)
    stale[4, 1] = Cell("x", STYLE_NONE)
    @test stale[3, 1] == fresh[3, 1]      # heads agree
    @test stale[4, 1] != fresh[4, 1]      # only the CONT differs
    q = diff(stale, fresh)
    @test q.spans[1].x == 3
    assert_aligned(q, fresh)

    # Wide glyphs at both edges of the row, and back to back.
    e = Buffer(6, 1)
    f = copy(e)
    write_text!(f, 1, 1, "世界界")
    r = diff(e, f)
    assert_aligned(r, f)
    @test apply!(copy(e), r) == f

    # The invariant holds for a full patch too.
    assert_aligned(full_patch(f), f)
end

@testitem "diff: is pure and mutates neither argument" begin
    using DualUI

    a = Buffer(10, 3)
    write_text!(a, 1, 1, "before")
    b = Buffer(10, 3)
    write_text!(b, 1, 1, "after")
    write_text!(b, 2, 3, "世")

    a0, b0 = copy(a), copy(b)
    p = diff(a, b)
    @test a == a0
    @test b == b0

    # Running it again yields an equal patch: no hidden state.
    @test diff(a, b) == p
    @test a == a0 && b == b0

    # The spans own their cells -- mutating a span cannot reach back
    # into the buffer it was read from.
    p.spans[1].cells[1] = Cell("Z", STYLE_NONE)
    @test b == b0

    # The size-mismatch branch is pure as well.
    c = Buffer(4, 1)
    c0 = copy(c)
    full_patch(c)
    diff(a, c)
    @test c == c0 && a == a0

    # apply! is the ONLY mutating function here, and it returns its
    # own first argument rather than a copy.
    dst = Buffer(10, 3)
    @test apply!(dst, p) === dst
end
