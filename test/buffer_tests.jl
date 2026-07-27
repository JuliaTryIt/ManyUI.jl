# buffer_tests.jl -- tests for src/buffer.jl (E2 grids, S3 wide chars).

@testitem "buffer: Cell is isbits" begin
    using ManyUI

    @test isbitstype(Cell)
    @test isbits(CELL_BLANK)
    @test isbits(CELL_CONT)
    @test String(CELL_BLANK.content) == " "
    @test CELL_BLANK.width == 1
    @test String(CELL_CONT.content) == ""
    @test CELL_CONT.width == 0
    @test is_continuation(CELL_CONT)
    @test !is_continuation(CELL_BLANK)
    @test Cell("a").style === STYLE_NONE
    @test Cell("a").width == 1
    @test isbits(Buffer(1, 1)[1, 1])
end

@testitem "buffer: Cell truncates clusters over 31 bytes" begin
    using ManyUI

    long = "\U1F468‍\U1F469‍\U1F467‍\U1F466‍\U1F466"
    @test ncodeunits(long) > 31          # premise of the rule
    c = Cell(long)                       # MUST NOT throw
    @test ncodeunits(c.content) <= 31
    @test isvalid(String(c.content))
    @test startswith(long, String(c.content))
    # Width comes from the ORIGINAL cluster, not the truncated prefix.
    @test c.width == Int8(grapheme_width(long))

    short = "\U1F468‍\U1F469‍\U1F467‍\U1F466"
    @test ncodeunits(short) == 25        # String15 would throw here
    @test String(Cell(short).content) == short
end

@testitem "buffer: Base.size returns a Tuple not a Size" begin
    using ManyUI

    b = Buffer(Size(4, 3))
    @test size(b) === (4, 3)
    @test !(size(b) isa Size)
    @test size(b) isa Tuple{Int,Int}
    @test buffer_size(b) === Size(4, 3)
    @test buffer_region(b) === Region(1, 1, 4, 3)
    @test Buffer(4, 3) == b
    @test b isa AbstractMatrix{Cell}
    @test all(c === CELL_BLANK for c in b)

    v = view(b, Region(2, 1, 2, 2))
    @test size(v) === (2, 2)
    @test !(size(v) isa Size)
    @test buffer_size(v) === Size(2, 2)
    @test buffer_region(v) === Region(1, 1, 2, 2)
end

@testitem "buffer: wide grapheme writes head plus continuation" begin
    using ManyUI

    b = Buffer(6, 1)
    @test set_cell!(b, 2, 1, "世", STYLE_NONE) == 2
    @test String(b[2, 1].content) == "世"
    @test b[2, 1].width == 2
    @test b[3, 1] === CELL_CONT
    @test is_continuation(b[3, 1])
    @test b[1, 1] === CELL_BLANK
    @test b[4, 1] === CELL_BLANK

    # An ordinary grapheme advances exactly one cell.
    @test set_cell!(b, 5, 1, "a", STYLE_NONE) == 1
    @test !is_continuation(b[5, 1])
    @test b[6, 1] === CELL_BLANK
end

@testitem "buffer: straddling wide grapheme is refused not halved" begin
    using ManyUI

    b = Buffer(3, 1)
    @test set_cell!(b, 3, 1, "世", STYLE_NONE) == 0
    @test b[3, 1] === CELL_BLANK          # no-op, not half a glyph
    @test b[2, 1] === CELL_BLANK

    # write_text! stops at the right edge rather than halving.
    b2 = Buffer(2, 1)
    @test write_text!(b2, 1, 1, "a世") == 1
    @test String(b2[1, 1].content) == "a"
    @test b2[2, 1] === CELL_BLANK
    @test string(b2) == "a "
end

@testitem "buffer: overwriting a head clears its continuation" begin
    using ManyUI

    b = Buffer(4, 1)
    set_cell!(b, 1, 1, "世", STYLE_NONE)
    @test set_cell!(b, 1, 1, "a", STYLE_NONE) == 1
    @test String(b[1, 1].content) == "a"
    @test b[1, 1].width == 1
    @test b[2, 1] === CELL_BLANK          # orphan continuation blanked
    @test !is_continuation(b[2, 1])
    @test string(b) == "a   "
end

@testitem "buffer: overwriting a continuation clears its head" begin
    using ManyUI

    b = Buffer(4, 1)
    set_cell!(b, 1, 1, "世", STYLE_NONE)
    @test set_cell!(b, 2, 1, "a", STYLE_NONE) == 1
    @test b[1, 1] === CELL_BLANK          # orphan head blanked
    @test String(b[2, 1].content) == "a"
    @test string(b) == " a  "

    # A wide write straddling two wide glyphs blanks both outer halves.
    w = Buffer(5, 1)
    set_cell!(w, 1, 1, "世", STYLE_NONE)
    set_cell!(w, 3, 1, "界", STYLE_NONE)
    @test set_cell!(w, 2, 1, "漢", STYLE_NONE) == 2
    @test w[1, 1] === CELL_BLANK
    @test String(w[2, 1].content) == "漢"
    @test w[3, 1] === CELL_CONT
    @test w[4, 1] === CELL_BLANK
    @test string(w) == " 漢  "
end

@testitem "buffer: writes outside bounds are clipped not thrown" begin
    using ManyUI

    b = Buffer(3, 2)
    @test set_cell!(b, 0, 1, "a", STYLE_NONE) == 0
    @test set_cell!(b, 4, 1, "a", STYLE_NONE) == 0
    @test set_cell!(b, 1, 0, "a", STYLE_NONE) == 0
    @test set_cell!(b, 1, 3, "a", STYLE_NONE) == 0
    @test set_cell!(b, -9, -9, CELL_BLANK) == 0
    @test write_text!(b, 1, 9, "hi") == 0
    @test write_text!(b, 3, 1, "hello") == 1   # stops at right edge
    @test String(b[3, 1].content) == "h"

    # Region writers clip rather than throw.
    @test fill_region!(b, Region(-5, -5, 100, 100)) === nothing
    @test fill_region!(b, Region(9, 9, 2, 2)) === nothing
    @test style_region!(b, Region(-1, -1, 99, 99), STYLE_NONE) === nothing
    @test blit!(b, Buffer(50, 50), Offset(1, 1)) === nothing
    @test blit!(b, Buffer(2, 2), Offset(99, 99)) === nothing
    @test size(b) === (3, 2)
end

@testitem "buffer: BufferView translates and clips" begin
    using ManyUI

    b = Buffer(10, 5)
    v = view(b, Region(3, 2, 4, 3))
    @test v isa BufferView
    @test v.parent === b
    @test size(v) === (4, 3)

    v[1, 1] = Cell("x")
    @test String(b[3, 2].content) == "x"    # local (1,1) -> absolute (3,2)

    @test write_text!(v, 1, 2, "ab") == 2
    @test String(b[3, 3].content) == "a"
    @test String(b[4, 3].content) == "b"

    # Out-of-range writes are silently dropped; reads give CELL_BLANK.
    v[5, 1] = Cell("z")
    @test b[7, 2] === CELL_BLANK
    v[1, 9] = Cell("z")
    @test v[9, 9] === CELL_BLANK
    @test v[0, 0] === CELL_BLANK

    # A writer structurally cannot paint outside the view's box.
    @test write_text!(v, 1, 1, "abcdef") == 4
    @test String(b[6, 2].content) == "d"
    @test b[7, 2] === CELL_BLANK

    # A view is clipped to its parent at construction.
    v2 = view(b, Region(9, 4, 5, 5))
    @test size(v2) === (2, 2)
    v2[2, 2] = Cell("e")
    @test String(b[10, 5].content) == "e"
end

@testitem "buffer: nested view stays two-level" begin
    using ManyUI

    b = Buffer(10, 5)
    v = view(b, Region(3, 2, 6, 3))
    v2 = view(v, Region(2, 2, 3, 2))
    @test v2 isa BufferView
    @test v2.parent === b                 # re-anchored, not chained
    @test !(v2.parent isa BufferView)
    @test size(v2) === (3, 2)

    v2[1, 1] = Cell("q")
    @test String(b[4, 3].content) == "q"

    # A nested view cannot escape its parent view's box.
    v3 = view(v, Region(5, 1, 9, 9))
    @test size(v3) === (2, 3)
    @test write_text!(v3, 1, 1, "abcdef") == 2
    @test String(b[7, 2].content) == "a"
    @test String(b[8, 2].content) == "b"
    @test b[9, 2] === CELL_BLANK
end

@testitem "buffer: string dump skips continuations" begin
    using ManyUI

    b = Buffer(4, 2)
    write_text!(b, 1, 1, "世")
    write_text!(b, 1, 2, "ab")
    @test string(b) == "世  \nab  "

    io = IOBuffer()
    @test show(io, MIME"text/plain"(), b) === nothing
    out = String(take!(io))
    @test occursin("世", out)
    @test occursin("ab", out)
end

@testitem "buffer: write_text! advances by text width" begin
    using ManyUI

    b = Buffer(10, 1)
    @test write_text!(b, 1, 1, "ab世") == 4
    @test String(b[1, 1].content) == "a"
    @test String(b[2, 1].content) == "b"
    @test String(b[3, 1].content) == "世"
    @test is_continuation(b[4, 1])
    @test string(b) == "ab世" * " "^6
    @test write_text!(b, 1, 1, "") == 0

    # The style given is carried onto every cell written.
    st = Style(COLOR_UNSET, COLOR_UNSET, UInt16(Attr.BOLD),
               UInt16(Attr.BOLD))
    c = Buffer(4, 1)
    @test write_text!(c, 1, 1, "hi", st) == 2
    @test c[1, 1].style === st
    @test c[2, 1].style === st
    @test c[3, 1].style === STYLE_NONE
end

@testitem "buffer: fill_region! clips and blanks split wide glyphs" begin
    using ManyUI

    b = Buffer(6, 2)
    write_text!(b, 1, 1, "世界")     # 1=世 2=cont 3=界 4=cont
    fill_region!(b, Region(2, 1, 2, 1))
    @test b[1, 1] === CELL_BLANK     # head of 世 lost its continuation
    @test b[2, 1] === CELL_BLANK
    @test b[3, 1] === CELL_BLANK
    @test b[4, 1] === CELL_BLANK     # continuation of 界 lost its head
    @test string(b) == "      \n      "

    # Filling with a styled cell touches only the clipped region.
    st = Style(COLOR_UNSET, COLOR_UNSET, UInt16(Attr.BOLD),
               UInt16(Attr.BOLD))
    fill_region!(b, Region(5, 2, 99, 99), Cell("#", st))
    @test String(b[5, 2].content) == "#"
    @test b[6, 2].style === st
    @test b[4, 2] === CELL_BLANK
    @test size(b) === (6, 2)

    # Fill through a view stays inside the view.
    v = view(b, Region(2, 1, 2, 1))
    fill_region!(v, Region(1, 1, 99, 99), Cell("."))
    @test String(b[2, 1].content) == "."
    @test String(b[3, 1].content) == "."
    @test b[1, 1] === CELL_BLANK
    @test b[4, 1] === CELL_BLANK
end

@testitem "buffer: style_region! merges and keeps content" begin
    using ManyUI

    b = Buffer(4, 1)
    write_text!(b, 1, 1, "a世")
    st = Style(COLOR_UNSET, COLOR_UNSET, UInt16(Attr.BOLD),
               UInt16(Attr.BOLD))
    style_region!(b, Region(1, 1, 2, 1), st)
    @test String(b[1, 1].content) == "a"
    @test b[1, 1].width == 1
    @test b[1, 1].style === merge(STYLE_NONE, st)
    @test String(b[2, 1].content) == "世"
    @test b[2, 1].width == 2         # widths are preserved
    @test b[3, 1].style === STYLE_NONE
    @test is_continuation(b[3, 1])   # continuation survives untouched
    @test string(b) == "a世 "
end

@testitem "buffer: blit! copies clipped at an offset" begin
    using ManyUI

    src = Buffer(3, 2)
    write_text!(src, 1, 1, "abc")
    write_text!(src, 1, 2, "def")

    dst = Buffer(6, 3)
    @test blit!(dst, src, Offset(2, 2)) === nothing
    @test String(dst[2, 2].content) == "a"
    @test String(dst[4, 2].content) == "c"
    @test String(dst[2, 3].content) == "d"
    @test String(dst[4, 3].content) == "f"
    @test dst[1, 1] === CELL_BLANK
    @test dst[1, 2] === CELL_BLANK
    @test dst[5, 3] === CELL_BLANK

    # Overflow is dropped, never thrown.
    @test blit!(dst, src, Offset(5, 3)) === nothing
    @test String(dst[5, 3].content) == "a"
    @test String(dst[6, 3].content) == "b"
    @test size(dst) === (6, 3)

    # A wide glyph whose continuation is clipped away is not halved.
    s2 = Buffer(2, 1)
    write_text!(s2, 1, 1, "世")
    d2 = Buffer(2, 1)
    blit!(d2, s2, Offset(2, 1))
    @test d2[2, 1] === CELL_BLANK
    @test string(d2) == "  "

    # A continuation whose head is clipped away is not orphaned.
    d3 = Buffer(4, 1)
    blit!(d3, s2, Offset(0, 1))
    @test d3[1, 1] === CELL_BLANK
    @test string(d3) == "    "
end

@testitem "buffer: clear! fill! copy and resize_buffer" begin
    using ManyUI

    b = Buffer(3, 2)
    write_text!(b, 1, 1, "ab")
    @test clear!(b) === nothing
    @test all(c === CELL_BLANK for c in b)
    @test string(b) == "   \n   "

    fill!(b, Cell("#"))
    @test string(b) == "###\n###"

    write_text!(b, 1, 1, "ab")
    c = copy(b)
    @test c == b
    @test c isa Buffer
    @test c.cells !== b.cells
    write_text!(c, 1, 1, "zz")
    @test String(b[1, 1].content) == "a"
    @test c != b

    r = resize_buffer(b, Size(5, 1))
    @test r isa Buffer
    @test size(r) === (5, 1)
    @test r !== b
    @test size(b) === (3, 2)          # the source is untouched
end
