# ansi_tests.jl -- tests for ManyUI/src/ansi.jl.
#
# This is a WIRE FORMAT. Assertions pin exact byte strings, not shapes:
# a terminal that receives one byte too many corrupts the screen, and a
# test that only checks `occursin` cannot see that.
#
# Accountable for EARS 2.2 (the ANSI half of the minimal-update rule)
# and EARS 2.3 (alternate screen + cursor control codes).

@testitem "ansi: control codes for alt screen and cursor" begin
    using ManyUI
    # EARS 2.3: the codes terminal.jl drives the host terminal with.
    @test Ansi.ESC == "\e"
    @test Ansi.CSI == "\e["
    @test Ansi.ALT_SCREEN_ENTER == "\e[?1049h"
    @test Ansi.ALT_SCREEN_EXIT == "\e[?1049l"
    @test Ansi.CURSOR_HIDE == "\e[?25l"
    @test Ansi.CURSOR_SHOW == "\e[?25h"
    @test Ansi.CURSOR_SAVE == "\e7"
    @test Ansi.CURSOR_RESTORE == "\e8"
    @test Ansi.CLEAR_SCREEN == "\e[2J"
    @test Ansi.CLEAR_LINE_RIGHT == "\e[0K"
    @test Ansi.SGR_RESET == "\e[0m"
    @test Ansi.SYNC_BEGIN == "\e[?2026h"
    @test Ansi.SYNC_END == "\e[?2026l"

    # Enter/exit are inverses on the wire: `h` sets, `l` resets.
    @test Ansi.ALT_SCREEN_ENTER[1:(end - 1)] ==
          Ansi.ALT_SCREEN_EXIT[1:(end - 1)]
    @test Ansi.CURSOR_HIDE[1:(end - 1)] == Ansi.CURSOR_SHOW[1:(end - 1)]
    @test Ansi.SYNC_BEGIN[1:(end - 1)] == Ansi.SYNC_END[1:(end - 1)]

    # Everything is bytes, not a Char soup.
    @test codeunits(Ansi.ALT_SCREEN_ENTER) ==
          UInt8[0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68]
end

@testitem "ansi: mouse and bracketed paste toggles" begin
    using ManyUI
    # EARS 2.3. Mouse ON enables 1000 (press/release), 1002 (drag),
    # 1003 (any motion) and 1006 (SGR extended coordinates).
    @test Ansi.MOUSE_ON == "\e[?1000h\e[?1002h\e[?1003h\e[?1006h"
    # OFF disables in the reverse order it enabled.
    @test Ansi.MOUSE_OFF == "\e[?1006l\e[?1003l\e[?1002l\e[?1000l"
    @test Ansi.PASTE_ON == "\e[?2004h"
    @test Ansi.PASTE_OFF == "\e[?2004l"
    @test Ansi.FOCUS_ON == "\e[?1004h"
    @test Ansi.FOCUS_OFF == "\e[?1004l"

    @test Ansi.PASTE_ON[1:(end - 1)] == Ansi.PASTE_OFF[1:(end - 1)]
    @test Ansi.FOCUS_ON[1:(end - 1)] == Ansi.FOCUS_OFF[1:(end - 1)]
    @test count("h", Ansi.MOUSE_ON) == 4
    @test count("l", Ansi.MOUSE_OFF) == 4
end

@testitem "ansi: cup is row-first and 1-based" begin
    using ManyUI
    # The API is (x, y); the wire is CSI row ; col H. Getting this
    # backwards is the single most common ANSI bug.
    @test Ansi.cup(1, 1) == "\e[1;1H"
    @test Ansi.cup(3, 7) == "\e[7;3H"
    @test Ansi.cup(10, 20) == "\e[20;10H"
    @test Ansi.cup(80, 24) == "\e[24;80H"
    # Not symmetric: swapping the arguments must change the bytes.
    @test Ansi.cup(3, 7) != Ansi.cup(7, 3)
    @test codeunits(Ansi.cup(1, 1)) ==
          UInt8[0x1b, 0x5b, 0x31, 0x3b, 0x31, 0x48]
end

@testitem "ansi: sgr cuf and title builders" begin
    using ManyUI
    @test Ansi.sgr(0) == "\e[0m"
    @test Ansi.sgr(0) == Ansi.SGR_RESET
    @test Ansi.sgr(1) == "\e[1m"
    @test Ansi.sgr(38, 5, 196) == "\e[38;5;196m"
    @test Ansi.sgr(38, 2, 255, 136, 0) == "\e[38;2;255;136;0m"
    @test Ansi.sgr() == "\e[m"

    @test Ansi.cuf(1) == "\e[1C"
    @test Ansi.cuf(12) == "\e[12C"

    @test Ansi.title("hi") == "\e]0;hi\a"
    @test Ansi.title("") == "\e]0;\a"
end

@testitem "ansi: fg_seq and bg_seq wire forms" begin
    using ManyUI
    tc = ColorDepth.TRUECOLOR
    # UNSET says nothing at all -- it is the cascade's "inherit".
    @test Ansi.fg_seq(COLOR_UNSET, tc) == ""
    @test Ansi.bg_seq(COLOR_UNSET, tc) == ""
    # DEFAULT is SGR 39 / 49, not "no bytes".
    @test Ansi.fg_seq(COLOR_DEFAULT, tc) == "\e[39m"
    @test Ansi.bg_seq(COLOR_DEFAULT, tc) == "\e[49m"
    # ANSI16: 30..37 low, 90..97 bright; bg 40..47 / 100..107.
    @test Ansi.fg_seq(ansi16(0), ColorDepth.ANSI16) == "\e[30m"
    @test Ansi.fg_seq(ansi16(1), ColorDepth.ANSI16) == "\e[31m"
    @test Ansi.fg_seq(ansi16(7), ColorDepth.ANSI16) == "\e[37m"
    @test Ansi.fg_seq(ansi16(8), ColorDepth.ANSI16) == "\e[90m"
    @test Ansi.fg_seq(ansi16(9), ColorDepth.ANSI16) == "\e[91m"
    @test Ansi.fg_seq(ansi16(15), ColorDepth.ANSI16) == "\e[97m"
    @test Ansi.bg_seq(ansi16(0), ColorDepth.ANSI16) == "\e[40m"
    @test Ansi.bg_seq(ansi16(1), ColorDepth.ANSI16) == "\e[41m"
    @test Ansi.bg_seq(ansi16(9), ColorDepth.ANSI16) == "\e[101m"
    @test Ansi.bg_seq(ansi16(15), ColorDepth.ANSI16) == "\e[107m"
    # ANSI256 and RGB.
    @test Ansi.fg_seq(ansi256(196), ColorDepth.ANSI256) == "\e[38;5;196m"
    @test Ansi.bg_seq(ansi256(196), ColorDepth.ANSI256) == "\e[48;5;196m"
    @test Ansi.fg_seq(rgb(255, 136, 0), tc) == "\e[38;2;255;136;0m"
    @test Ansi.bg_seq(rgb(255, 136, 0), tc) == "\e[48;2;255;136;0m"
    @test Ansi.fg_seq(rgb(0, 0, 0), tc) == "\e[38;2;0;0;0m"
end

@testitem "ansi: fg_seq degrades before emitting" begin
    using ManyUI
    # X1. The sequence FORM follows the depth, not the authorial kind:
    # a TrueColor value must never reach a 256-color terminal as 38;2.
    orange = rgb(255, 136, 0)
    @test startswith(Ansi.fg_seq(orange, ColorDepth.TRUECOLOR), "\e[38;2;")
    @test startswith(Ansi.fg_seq(orange, ColorDepth.ANSI256), "\e[38;5;")
    @test !occursin("38;2;", Ansi.fg_seq(orange, ColorDepth.ANSI256))
    @test !occursin("38;", Ansi.fg_seq(orange, ColorDepth.ANSI16))
    @test !occursin("38;", Ansi.fg_seq(orange, ColorDepth.MONOCHROME))
    @test occursin(r"^\e\[(3[0-7]|9[0-7])m$",
                   Ansi.fg_seq(orange, ColorDepth.ANSI16))
    @test occursin(r"^\e\[(4[0-7]|10[0-7])m$",
                   Ansi.bg_seq(orange, ColorDepth.ANSI16))
    # DEFAULT and UNSET survive every depth unchanged.
    for d in (ColorDepth.MONOCHROME, ColorDepth.ANSI16,
              ColorDepth.ANSI256, ColorDepth.TRUECOLOR)
        @test Ansi.fg_seq(COLOR_DEFAULT, d) == "\e[39m"
        @test Ansi.bg_seq(COLOR_DEFAULT, d) == "\e[49m"
        @test Ansi.fg_seq(COLOR_UNSET, d) == ""
    end
end

@testitem "ansi: AnsiEncoder starts unsynced" begin
    using ManyUI
    e = AnsiEncoder(ColorDepth.ANSI256)
    @test e.depth === ColorDepth.ANSI256
    @test e.style === STYLE_NONE
    @test e.cursor === ORIGIN
    @test e.synced == false
    @test e.sync_frames == true

    e2 = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    @test e2.sync_frames == false
    @test e2.depth === ColorDepth.TRUECOLOR
end

@testitem "ansi: sgr! from s to s writes zero bytes" begin
    using ManyUI
    # THE law. Without it the encoder re-emits an SGR per cell and E2's
    # "minimal set" is a lie.
    red = Color(ColorKind.RGB, 0xff, 0x00, 0x00)
    styles = (STYLE_NONE,
              STYLE_DEFAULT,
              Style(red, COLOR_DEFAULT, UInt16(Attr.BOLD),
                    UInt16(Attr.BOLD)),
              Style(COLOR_DEFAULT, red, 0x00ff, 0x00ff))
    for s in styles, d in (ColorDepth.MONOCHROME, ColorDepth.ANSI16,
                           ColorDepth.ANSI256, ColorDepth.TRUECOLOR)
        io = IOBuffer()
        @test sgr!(io, s, s, d) === nothing
        @test isempty(take!(io))
    end
end

@testitem "ansi: sgr! resets before turning an attribute off" begin
    using ManyUI
    d = ColorDepth.TRUECOLOR
    bold = Style(COLOR_DEFAULT, COLOR_DEFAULT, UInt16(Attr.BOLD),
                 UInt16(Attr.BOLD))
    plain = Style(COLOR_DEFAULT, COLOR_DEFAULT, 0x0000,
                  UInt16(Attr.BOLD))

    # Turning BOLD off costs a full reset: code 22 is ambiguous between
    # bold and dim, so per-attribute off codes are never used.
    io = IOBuffer()
    sgr!(io, bold, plain, d)
    @test String(take!(io)) == Ansi.SGR_RESET

    # Turning an attribute ON needs no reset.
    io = IOBuffer()
    sgr!(io, plain, bold, d)
    out = String(take!(io))
    @test out == "\e[1m"
    @test !occursin(Ansi.SGR_RESET, out)
    @test !occursin("\e[22m", out)

    # A reset wipes the colors too, so they must be re-emitted after it.
    red = Color(ColorKind.ANSI16, 0x01, 0x00, 0x00)
    on = Style(red, COLOR_DEFAULT, UInt16(Attr.BOLD), UInt16(Attr.BOLD))
    off = Style(red, COLOR_DEFAULT, 0x0000, UInt16(Attr.BOLD))
    io = IOBuffer()
    sgr!(io, on, off, ColorDepth.ANSI16)
    @test String(take!(io)) == "\e[0m\e[31m"
end

@testitem "ansi: sgr! emits attribute codes in ascending order" begin
    using ManyUI
    all_on = Style(COLOR_DEFAULT, COLOR_DEFAULT, 0x00ff, 0x00ff)
    io = IOBuffer()
    sgr!(io, STYLE_DEFAULT, all_on, ColorDepth.TRUECOLOR)
    # 1 bold, 2 dim, 3 italic, 4 underline, 5 blink, 7 reverse,
    # 8 hidden, 9 strike. 6 is not assigned.
    @test String(take!(io)) == "\e[1m\e[2m\e[3m\e[4m\e[5m\e[7m\e[8m\e[9m"

    # Only the delta is emitted, never the whole style.
    bold = Style(COLOR_DEFAULT, COLOR_DEFAULT, UInt16(Attr.BOLD),
                 UInt16(Attr.BOLD))
    bold_it = Style(COLOR_DEFAULT, COLOR_DEFAULT,
                    UInt16(Attr.BOLD) | UInt16(Attr.ITALIC),
                    UInt16(Attr.BOLD) | UInt16(Attr.ITALIC))
    io = IOBuffer()
    sgr!(io, bold, bold_it, ColorDepth.TRUECOLOR)
    @test String(take!(io)) == "\e[3m"
end

@testitem "ansi: sgr! orders attrs then fg then bg" begin
    using ManyUI
    red = Color(ColorKind.ANSI16, 0x01, 0x00, 0x00)
    blue = Color(ColorKind.ANSI16, 0x04, 0x00, 0x00)
    to = Style(red, blue, UInt16(Attr.BOLD), UInt16(Attr.BOLD))
    io = IOBuffer()
    sgr!(io, STYLE_DEFAULT, to, ColorDepth.ANSI16)
    @test String(take!(io)) == "\e[1m\e[31m\e[44m"
end

@testitem "ansi: encode! emits cup only for non-contiguous spans" begin
    using ManyUI
    # EARS 2.2 / E2: a cursor move is bytes on the wire. Emit one only
    # when the next run does not start where the last one ended.
    S31 = typeof(CELL_BLANK.content)
    a = Cell(S31("a"), STYLE_NONE, Int8(1))
    b = Cell(S31("b"), STYLE_NONE, Int8(1))
    c = Cell(S31("c"), STYLE_NONE, Int8(1))
    sz = Size(10, 3)

    # Contiguous: span 2 starts exactly where span 1 left the cursor.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    p = Patch([Span(1, 1, [a, b]), Span(3, 1, [c])], sz, false)
    @test String(encode(e, p)) == "\e[1;1Habc"

    # A gap on the same row costs one CUP.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    p = Patch([Span(1, 1, [a, b]), Span(5, 1, [c])], sz, false)
    @test String(encode(e, p)) == "\e[1;1Hab\e[1;5Hc"

    # A new row always costs one CUP.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    p = Patch([Span(1, 1, [a]), Span(1, 2, [b])], sz, false)
    @test String(encode(e, p)) == "\e[1;1Ha\e[2;1Hb"

    # Contiguity is tracked ACROSS frames too.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    @test String(encode(e, Patch([Span(1, 1, [a])], sz, false))) ==
          "\e[1;1Ha"
    @test e.synced == true
    @test e.cursor === Offset(2, 1)
    @test String(encode(e, Patch([Span(2, 1, [b])], sz, false))) == "b"
end

@testitem "ansi: encode! skips continuation cells" begin
    using ManyUI
    # S3. The terminal advanced two columns for the wide glyph itself.
    # Emitting the CELL_CONT as a space is the classic corruption bug.
    S31 = typeof(CELL_BLANK.content)
    head = Cell(S31("世"), STYLE_NONE, Int8(2))
    tail = Cell(S31("x"), STYLE_NONE, Int8(1))
    sz = Size(10, 1)

    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    p = Patch([Span(1, 1, [head, CELL_CONT, tail])], sz, false)
    out = String(encode(e, p))
    # No space, no second CUP: the glyph already moved the cursor to 3.
    @test out == "\e[1;1H世x"
    @test !occursin(" ", out)
    @test e.cursor === Offset(4, 1)

    # The head's width, not the cell count, is what advances the cursor.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    p = Patch([Span(1, 1, [head, CELL_CONT]), Span(3, 1, [tail])],
              sz, false)
    @test String(encode(e, p)) == "\e[1;1H世x"

    # A lone continuation emits nothing at all.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    p = Patch([Span(2, 1, [CELL_CONT])], sz, false)
    @test isempty(encode(e, p))
end

@testitem "ansi: encode! emits sgr only when the style changes" begin
    using ManyUI
    S31 = typeof(CELL_BLANK.content)
    bold = Style(COLOR_DEFAULT, COLOR_DEFAULT, UInt16(Attr.BOLD),
                 UInt16(Attr.BOLD))
    b1 = Cell(S31("a"), bold, Int8(1))
    b2 = Cell(S31("b"), bold, Int8(1))
    b3 = Cell(S31("c"), bold, Int8(1))
    p = Patch([Span(1, 1, [b1, b2, b3])], Size(10, 1), false)
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    out = String(encode(e, p))
    # One SGR run for three cells, not three.
    @test out == "\e[1;1H\e[1m\e[39m\e[49mabc"
    @test count("\e[1m", out) == 1
    @test e.style === bold
end

@testitem "ansi: encoder tracks style across frames" begin
    using ManyUI
    S31 = typeof(CELL_BLANK.content)
    bold = Style(COLOR_DEFAULT, COLOR_DEFAULT, UInt16(Attr.BOLD),
                 UInt16(Attr.BOLD))
    sz = Size(10, 2)
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)

    p1 = Patch([Span(1, 1, [Cell(S31("a"), bold, Int8(1))])], sz, false)
    @test String(encode(e, p1)) == "\e[1;1H\e[1m\e[39m\e[49ma"

    # Frame 2, same style elsewhere: the SGR is NOT re-emitted.
    p2 = Patch([Span(5, 1, [Cell(S31("b"), bold, Int8(1))])], sz, false)
    out2 = String(encode(e, p2))
    @test out2 == "\e[1;5Hb"
    @test !occursin("\e[1m", out2)
    @test !occursin("\e[", replace(out2, "\e[1;5H" => ""))
end

@testitem "ansi: reset! forces a full re-emit" begin
    using ManyUI
    S31 = typeof(CELL_BLANK.content)
    bold = Style(COLOR_DEFAULT, COLOR_DEFAULT, UInt16(Attr.BOLD),
                 UInt16(Attr.BOLD))
    sz = Size(10, 1)
    p = Patch([Span(1, 1, [Cell(S31("a"), bold, Int8(1))])], sz, false)

    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    first = String(encode(e, p))
    # Without a reset the identical patch is nearly free.
    @test String(encode(e, p)) == "\e[1;1Ha"

    # A reconnected xterm.js is at default SGR while the encoder still
    # believes it last emitted bold: reset! is what re-syncs the belief.
    @test reset!(e) === nothing
    @test e.synced == false
    @test e.style === STYLE_NONE
    @test e.cursor === ORIGIN
    @test String(encode(e, p)) == first
end

@testitem "ansi: full patch clears and resets first" begin
    using ManyUI
    S31 = typeof(CELL_BLANK.content)
    a = Cell(S31("a"), STYLE_NONE, Int8(1))
    sz = Size(10, 1)

    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    out = String(encode(e, Patch([Span(1, 1, [a])], sz, true)))
    @test startswith(out, Ansi.CLEAR_SCREEN * Ansi.SGR_RESET)
    @test out == "\e[2J\e[0m\e[1;1Ha"

    # `full` invalidates tracking even mid-stream: the CUP comes back
    # although the cursor was already believed to be in place.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    encode(e, Patch([Span(1, 1, [a])], sz, false))
    @test e.synced == true
    out = String(encode(e, Patch([Span(1, 1, [a])], sz, true)))
    @test out == "\e[2J\e[0m\e[1;1Ha"

    # An empty full patch still clears -- `full` is the instruction.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    @test String(encode(e, Patch(Span[], sz, true))) == "\e[2J\e[0m"
end

@testitem "ansi: sync_frames wraps in 2026h/2026l" begin
    using ManyUI
    S31 = typeof(CELL_BLANK.content)
    a = Cell(S31("a"), STYLE_NONE, Int8(1))
    p = Patch([Span(1, 1, [a])], Size(10, 1), false)

    e = AnsiEncoder(ColorDepth.TRUECOLOR)
    out = String(encode(e, p))
    @test startswith(out, Ansi.SYNC_BEGIN)
    @test endswith(out, Ansi.SYNC_END)
    @test out == "\e[?2026h\e[1;1Ha\e[?2026l"

    # The clear of a full patch is INSIDE the atomic frame.
    e = AnsiEncoder(ColorDepth.TRUECOLOR)
    out = String(encode(e, Patch([Span(1, 1, [a])], Size(10, 1), true)))
    @test out == "\e[?2026h\e[2J\e[0m\e[1;1Ha\e[?2026l"

    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    @test String(encode(e, p)) == "\e[1;1Ha"
end

@testitem "ansi: encode! degrades colors at the depth" begin
    using ManyUI
    # X1, observed through the encoder: the SAME patch yields a
    # different wire form per depth, and the Patch is never mutated.
    S31 = typeof(CELL_BLANK.content)
    orange = rgb(255, 136, 0)
    st = Style(orange, COLOR_UNSET, 0x0000, 0x0000)
    cell = Cell(S31("a"), st, Int8(1))
    p = Patch([Span(1, 1, [cell])], Size(10, 1), false)

    enc(d) = String(encode(AnsiEncoder(d; sync_frames = false), p))

    @test enc(ColorDepth.TRUECOLOR) == "\e[1;1H\e[38;2;255;136;0ma"

    out = enc(ColorDepth.ANSI256)
    @test occursin("\e[38;5;", out)
    @test !occursin("38;2;", out)

    out = enc(ColorDepth.ANSI16)
    @test !occursin("38;5;", out)
    @test !occursin("38;2;", out)
    @test occursin(r"\e\[(3[0-7]|9[0-7])m", out)

    out = enc(ColorDepth.MONOCHROME)
    @test !occursin("38;5;", out)
    @test !occursin("38;2;", out)

    # The buffer keeps authorial intent: degradation happened HERE only.
    @test p.spans[1].cells[1].style.fg === orange
    @test cell.style.fg === orange
end

@testitem "ansi: encode! collapses styles that share a degraded form" begin
    using ManyUI
    # Two distinct authorial colors that both degrade to white must not
    # produce two SGR sequences at MONOCHROME.
    S31 = typeof(CELL_BLANK.content)
    s1 = Style(rgb(250, 250, 250), COLOR_DEFAULT, 0x0000, 0x0000)
    s2 = Style(rgb(240, 245, 255), COLOR_DEFAULT, 0x0000, 0x0000)
    p = Patch([Span(1, 1, [Cell(S31("a"), s1, Int8(1)),
                           Cell(S31("b"), s2, Int8(1))])],
              Size(10, 1), false)
    e = AnsiEncoder(ColorDepth.MONOCHROME; sync_frames = false)
    out = String(encode(e, p))
    @test endswith(out, "ab")
    @test count("\e[", out) == 3   # one CUP, one fg, one bg
end

@testitem "ansi: empty patch encodes to zero bytes" begin
    using ManyUI
    # E2 at its limit: nothing changed, so nothing goes on the wire --
    # not even a sync wrapper.
    e = AnsiEncoder(ColorDepth.TRUECOLOR)
    @test isempty(encode(e, Patch(Span[], Size(10, 5), false)))
    @test e.synced == false

    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    @test isempty(encode(e, Patch(Span[], Size(10, 5), false)))

    # A span of nothing but continuations is equally free.
    e = AnsiEncoder(ColorDepth.TRUECOLOR; sync_frames = false)
    @test isempty(encode(e, Patch([Span(1, 1, Cell[])], Size(10, 5),
                                  false)))
end

@testitem "ansi: encode agrees with encode! byte for byte" begin
    using ManyUI
    S31 = typeof(CELL_BLANK.content)
    bold = Style(COLOR_DEFAULT, COLOR_DEFAULT, UInt16(Attr.BOLD),
                 UInt16(Attr.BOLD))
    p = Patch([Span(1, 1, [Cell(S31("a"), bold, Int8(1))]),
               Span(4, 2, [Cell(S31("b"), STYLE_DEFAULT, Int8(1))])],
              Size(10, 3), false)

    io = IOBuffer()
    e1 = AnsiEncoder(ColorDepth.ANSI256)
    @test encode!(io, e1, p) === nothing
    bytes = take!(io)

    e2 = AnsiEncoder(ColorDepth.ANSI256)
    @test encode(e2, p) == bytes
    @test encode(e2, p) isa Vector{UInt8}

    # The two encoders walked identical state machines.
    @test e1.cursor === e2.cursor
    @test e1.style === e2.style
    @test e1.synced == e2.synced
end
