# input_tests.jl -- the §2.11 grammar, chunk-boundary survival (W4) and
# the source-agnostic guarantee that makes req 2.4 zero new code.
#
# Every @testitem is self-contained: TestItemRunner isolates them.

@testitem "Input: parse_events grammar table" begin
    using ManyUI

    bytes_of(s::AbstractString) = Vector{UInt8}(codeunits(s))

    function one_event(s::AbstractString)
        (evs, n) = parse_events(bytes_of(s))
        @test n == ncodeunits(s)
        @test length(evs) == 1
        return isempty(evs) ? nothing : evs[1]
    end

    CTRL = Modifiers(UInt8(Modifier.CTRL))
    ALT = Modifiers(UInt8(Modifier.ALT))

    # 0x20..0x7e -- printable ASCII.
    @test one_event("a") == KeyEvent(Key.CHAR, 'a', MOD_NONE)
    @test one_event("Z") == KeyEvent(Key.CHAR, 'Z', MOD_NONE)
    @test one_event("~") == KeyEvent(Key.CHAR, '~', MOD_NONE)
    @test one_event("0") == KeyEvent(Key.CHAR, '0', MOD_NONE)

    # 0x01..0x1a except \t \n \r -- ctrl + letter.
    @test one_event("\x01") == KeyEvent(Key.CHAR, 'a', CTRL)
    @test one_event("\x03") == KeyEvent(Key.CHAR, 'c', CTRL)
    @test one_event("\x1a") == KeyEvent(Key.CHAR, 'z', CTRL)

    # Named single bytes.
    @test one_event("\r") == KeyEvent(Key.ENTER, '\0', MOD_NONE)
    @test one_event("\t") == KeyEvent(Key.TAB, '\0', MOD_NONE)
    @test one_event("\x7f") == KeyEvent(Key.BACKSPACE, '\0', MOD_NONE)
    @test one_event(" ") == KeyEvent(Key.SPACE, '\0', MOD_NONE)

    # Multi-byte UTF-8.
    @test one_event("é") == KeyEvent(Key.CHAR, 'é', MOD_NONE)
    @test one_event("世") == KeyEvent(Key.CHAR, '世', MOD_NONE)
    @test one_event("🚀") == KeyEvent(Key.CHAR, '🚀', MOD_NONE)

    # ESC [ A..D -- arrows.
    @test one_event("\e[A") == KeyEvent(Key.UP, '\0', MOD_NONE)
    @test one_event("\e[B") == KeyEvent(Key.DOWN, '\0', MOD_NONE)
    @test one_event("\e[C") == KeyEvent(Key.RIGHT, '\0', MOD_NONE)
    @test one_event("\e[D") == KeyEvent(Key.LEFT, '\0', MOD_NONE)

    # ESC O A..D -- the SS3 form of the same arrows.
    @test one_event("\eOA") == KeyEvent(Key.UP, '\0', MOD_NONE)
    @test one_event("\eOB") == KeyEvent(Key.DOWN, '\0', MOD_NONE)
    @test one_event("\eOC") == KeyEvent(Key.RIGHT, '\0', MOD_NONE)
    @test one_event("\eOD") == KeyEvent(Key.LEFT, '\0', MOD_NONE)

    # ESC [ 1 ; m A..D -- arrow + modifiers.
    @test one_event("\e[1;5C") == KeyEvent(Key.RIGHT, '\0', CTRL)

    # ESC O P..S -- F1..F4.
    @test one_event("\eOP") == KeyEvent(Key.F1, '\0', MOD_NONE)
    @test one_event("\eOS") == KeyEvent(Key.F4, '\0', MOD_NONE)

    # ESC [ n ~ -- navigation cluster.
    @test one_event("\e[1~") == KeyEvent(Key.HOME, '\0', MOD_NONE)
    @test one_event("\e[2~") == KeyEvent(Key.INSERT, '\0', MOD_NONE)
    @test one_event("\e[3~") == KeyEvent(Key.DELETE, '\0', MOD_NONE)
    @test one_event("\e[4~") == KeyEvent(Key.END, '\0', MOD_NONE)
    @test one_event("\e[5~") == KeyEvent(Key.PAGE_UP, '\0', MOD_NONE)
    @test one_event("\e[6~") == KeyEvent(Key.PAGE_DOWN, '\0', MOD_NONE)
    @test one_event("\e[7~") == KeyEvent(Key.HOME, '\0', MOD_NONE)
    @test one_event("\e[8~") == KeyEvent(Key.END, '\0', MOD_NONE)
    @test one_event("\e[H") == KeyEvent(Key.HOME, '\0', MOD_NONE)
    @test one_event("\e[F") == KeyEvent(Key.END, '\0', MOD_NONE)

    # ESC [ Z -- back tab.
    @test one_event("\e[Z") == KeyEvent(Key.BACK_TAB, '\0', MOD_NONE)

    # ESC [ < b ; x ; y M / m -- SGR 1006 mouse.
    @test one_event("\e[<0;10;5M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 10, 5,
                     MOD_NONE)
    @test one_event("\e[<0;10;5m") ==
          MouseEvent(MouseAction.RELEASE, MouseButton.LEFT, 10, 5,
                     MOD_NONE)

    # ESC [ I / ESC [ O -- focus in / out.
    @test one_event("\e[I") == FocusEvent(true)
    @test one_event("\e[O") == FocusEvent(false)

    # ESC <printable> -- alt + char.
    @test one_event("\ea") == KeyEvent(Key.CHAR, 'a', ALT)
    @test one_event("\e9") == KeyEvent(Key.CHAR, '9', ALT)

    # ESC [ 200~ ... ESC [ 201~ -- bracketed paste.
    (pv, pn) = parse_events(bytes_of("\e[200~hi\e[201~"))
    @test pn == 14
    @test length(pv) == 1
    @test pv[1] isa PasteEvent
    @test pv[1].text == "hi"

    # A lone trailing ESC is left unconsumed for flush_escape!.
    (ev, en) = parse_events(UInt8[0x1b])
    @test isempty(ev)
    @test en == 0

    # ResizeEvent is NEVER parsed from bytes.
    for s in ("\e[8;24;80t", "\e[A", "\e[<0;1;1M")
        (evs, _) = parse_events(bytes_of(s))
        @test !any(e -> e isa ResizeEvent, evs)
    end
end

@testitem "Input: modified keys via CSI parameters" begin
    using ManyUI

    p1(s) = first(parse_events(Vector{UInt8}(codeunits(s))))[1]

    SHIFT = Modifiers(UInt8(Modifier.SHIFT))
    ALT = Modifiers(UInt8(Modifier.ALT))
    CTRL = Modifiers(UInt8(Modifier.CTRL))
    ALT_CTRL = Modifiers(UInt8(Modifier.ALT) | UInt8(Modifier.CTRL))
    SUPER = Modifiers(UInt8(Modifier.SUPER))

    # m - 1 is the xterm modifier bitfield.
    @test p1("\e[1;2A") == KeyEvent(Key.UP, '\0', SHIFT)
    @test p1("\e[1;3D") == KeyEvent(Key.LEFT, '\0', ALT)
    @test p1("\e[1;5C") == KeyEvent(Key.RIGHT, '\0', CTRL)
    @test p1("\e[1;7B") == KeyEvent(Key.DOWN, '\0', ALT_CTRL)
    @test p1("\e[1;9A") == KeyEvent(Key.UP, '\0', SUPER)
    @test p1("\e[3;5~") == KeyEvent(Key.DELETE, '\0', CTRL)
    @test p1("\e[1;5P") == KeyEvent(Key.F1, '\0', CTRL)
    @test p1("\e[1;1C") == KeyEvent(Key.RIGHT, '\0', MOD_NONE)

    # ESC + a control byte carries ALT too.
    @test p1("\ea") == KeyEvent(Key.CHAR, 'a', ALT)
    @test p1("\e\r") == KeyEvent(Key.ENTER, '\0', ALT)
    @test p1("\e\t") == KeyEvent(Key.TAB, '\0', ALT)
    @test p1("\e\x7f") == KeyEvent(Key.BACKSPACE, '\0', ALT)
    @test p1("\eé") == KeyEvent(Key.CHAR, 'é', ALT)
end

@testitem "Input: function keys F1 through F12" begin
    using ManyUI

    p1(s) = first(parse_events(Vector{UInt8}(codeunits(s))))[1]

    @test p1("\eOP") == KeyEvent(Key.F1, '\0', MOD_NONE)
    @test p1("\eOQ") == KeyEvent(Key.F2, '\0', MOD_NONE)
    @test p1("\eOR") == KeyEvent(Key.F3, '\0', MOD_NONE)
    @test p1("\eOS") == KeyEvent(Key.F4, '\0', MOD_NONE)

    for (n, k) in ((11, Key.F1), (12, Key.F2), (13, Key.F3),
                   (14, Key.F4), (15, Key.F5), (17, Key.F6),
                   (18, Key.F7), (19, Key.F8), (20, Key.F9),
                   (21, Key.F10), (23, Key.F11), (24, Key.F12))
        @test p1("\e[$(n)~") == KeyEvent(k, '\0', MOD_NONE)
    end
end

@testitem "Input: SGR mouse reports" begin
    using ManyUI

    p1(s) = first(parse_events(Vector{UInt8}(codeunits(s))))[1]
    CTRL = Modifiers(UInt8(Modifier.CTRL))
    SHIFT = Modifiers(UInt8(Modifier.SHIFT))

    @test p1("\e[<0;10;5M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 10, 5,
                     MOD_NONE)
    @test p1("\e[<1;10;5M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.MIDDLE, 10, 5,
                     MOD_NONE)
    @test p1("\e[<2;1;1M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.RIGHT, 1, 1,
                     MOD_NONE)
    # bit 5 (32) is motion: with a button held that is a drag.
    @test p1("\e[<32;4;9M") ==
          MouseEvent(MouseAction.DRAG, MouseButton.LEFT, 4, 9, MOD_NONE)
    # motion with no button held is a bare move.
    @test p1("\e[<35;4;9M") ==
          MouseEvent(MouseAction.MOVE, MouseButton.NONE, 4, 9, MOD_NONE)
    # bit 6 (64) is the wheel.
    @test p1("\e[<64;2;3M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_UP, 2, 3,
                     MOD_NONE)
    @test p1("\e[<65;2;3M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_DOWN, 2, 3,
                     MOD_NONE)
    @test p1("\e[<66;2;3M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_LEFT, 2, 3,
                     MOD_NONE)
    @test p1("\e[<67;2;3M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.WHEEL_RIGHT, 2, 3,
                     MOD_NONE)
    # Modifier bits ride along.
    @test p1("\e[<16;7;8M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 7, 8, CTRL)
    @test p1("\e[<4;7;8M") ==
          MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 7, 8, SHIFT)
    # Coordinates are 1-based and absolute, per §0.1.
    e = p1("\e[<0;1;1M")
    @test e.x == 1 && e.y == 1
end

@testitem "Input: legacy X10 mouse reports" begin
    using ManyUI

    bs = UInt8[0x1b, UInt8('['), UInt8('M'), 0x20, 0x21, 0x22]
    (evs, n) = parse_events(bs)
    @test n == 6
    @test evs == Event[MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                                  1, 2, MOD_NONE)]

    # Button bits == 3 means release.
    bs2 = UInt8[0x1b, UInt8('['), UInt8('M'), 0x23, 0x25, 0x26]
    (evs2, n2) = parse_events(bs2)
    @test n2 == 6
    @test evs2 == Event[MouseEvent(MouseAction.RELEASE,
                                   MouseButton.NONE, 5, 6, MOD_NONE)]

    # Truncated report -- unconsumed, not misparsed.
    for k in 3:5
        (evs3, n3) = parse_events(bs[1:k])
        @test isempty(evs3)
        @test n3 == 0
    end
end

@testitem "Input: incomplete CSI is left unconsumed" begin
    using ManyUI

    for s in ("\e", "\e[", "\e[1", "\e[1;", "\e[1;5", "\e[<", "\e[<0;1",
              "\eO")
        (evs, n) = parse_events(Vector{UInt8}(codeunits(s)))
        @test isempty(evs)
        @test n == 0
    end

    # Everything before the incomplete tail is still delivered.
    (evs, n) = parse_events(Vector{UInt8}(codeunits("ab\e[1;5")))
    @test evs == Event[KeyEvent(Key.CHAR, 'a', MOD_NONE),
                       KeyEvent(Key.CHAR, 'b', MOD_NONE)]
    @test n == 2
end

@testitem "Input: CSI split across two feeds parses once" begin
    using ManyUI

    # W4 / req 2.4: a sequence cut by a frame boundary must not be lost
    # and must not be double-counted.
    p = InputParser()
    @test isempty(feed!(p, UInt8[0x1b, UInt8('['), UInt8('1')], 0.0))
    @test pending(p) == 3
    @test !isempty(p)
    evs = feed!(p, UInt8[UInt8(';'), UInt8('5'), UInt8('C')], 0.0)
    @test evs == Event[KeyEvent(Key.RIGHT, '\0',
                                Modifiers(UInt8(Modifier.CTRL)))]
    @test pending(p) == 0
    @test isempty(p)

    # Feeding the same bytes whole gives exactly the same one event.
    q = InputParser()
    @test feed!(q, "\e[1;5C", 0.0) == evs
end

@testitem "Input: partial UTF-8 is left unconsumed" begin
    using ManyUI

    bs = Vector{UInt8}(codeunits("🚀"))
    @test length(bs) == 4
    for k in 1:3
        (evs, n) = parse_events(bs[1:k])
        @test isempty(evs)
        @test n == 0
    end
    (evs, n) = parse_events(bs)
    @test n == 4
    @test evs == Event[KeyEvent(Key.CHAR, '🚀', MOD_NONE)]

    # The codepoint survives a feed boundary in its middle.
    p = InputParser()
    @test isempty(feed!(p, bs[1:2], 0.0))
    @test pending(p) == 2
    got = feed!(p, bs[3:4], 0.0)
    @test got == Event[KeyEvent(Key.CHAR, '🚀', MOD_NONE)]
    @test isempty(p)

    # Invalid UTF-8 is dropped byte-wise and never throws.
    (evs2, n2) = parse_events(UInt8[0xff, UInt8('a')])
    @test evs2 == Event[KeyEvent(Key.CHAR, 'a', MOD_NONE)]
    @test n2 == 2
    # Overlong encodings are rejected, not decoded.
    (evs3, n3) = parse_events(UInt8[0xc0, 0x80])
    @test isempty(evs3)
    @test n3 == 2
end

@testitem "Input: byte-at-a-time matches whole feeding" begin
    using ManyUI

    function collect_drip(bs::Vector{UInt8})
        p = InputParser()
        out = Event[]
        for b in bs
            append!(out, feed!(p, UInt8[b], 0.0))
        end
        return out
    end

    same(a::PasteEvent, b::PasteEvent) = a.text == b.text
    same(a::Event, b::Event) = a == b

    for s in ("\e[1;5C", "🚀", "\e[<0;12;7M", "a\e[200~hi\e[201~b",
              "hé世🚀\e[A\eOP\e[3~\e[Z", "\e[M !\"")
        bs = Vector{UInt8}(codeunits(s))
        whole = feed!(InputParser(), bs, 0.0)
        drip = collect_drip(bs)
        @test length(drip) == length(whole)
        for (a, b) in zip(drip, whole)
            @test typeof(a) === typeof(b)
            @test same(a, b)
        end
    end
end

@testitem "Input: source agnostic byte stream (req 2.4)" begin
    using ManyUI

    # The parser never touches a byte source: the same bytes cut at ANY
    # boundary -- a raw keyboard read or a web frame split -- must yield
    # exactly the same events. This is why ManyUIWeb needs no parser.
    s = "hi\e[1;5C\e[<0;3;4M🚀\eOQ"
    bs = Vector{UInt8}(codeunits(s))
    whole = feed!(InputParser(), bs, 0.0)
    @test length(whole) == 6
    for cut in 0:length(bs)
        p = InputParser()
        got = feed!(p, bs[1:cut], 0.0)
        append!(got, feed!(p, bs[(cut + 1):end], 0.0))
        @test got == whole
        @test isempty(p)
    end
end

@testitem "Input: bracketed paste accumulates then emits" begin
    using ManyUI

    p = InputParser()
    @test isempty(feed!(p, "\e[200~hello", 0.0))
    @test p.in_paste
    @test String(copy(p.paste)) == "hello"
    @test isempty(feed!(p, " world", 0.0))
    @test p.in_paste
    @test String(copy(p.paste)) == "hello world"

    evs = feed!(p, "\e[201~", 0.0)
    @test length(evs) == 1
    @test evs[1] isa PasteEvent
    @test evs[1].text == "hello world"
    @test !p.in_paste
    @test isempty(p)

    # The body is verbatim: an ESC inside a paste is text, not a key.
    q = InputParser()
    evs2 = feed!(q, "\e[200~a\e[Ab\e[201~", 0.0)
    @test length(evs2) == 1
    @test evs2[1] isa PasteEvent
    @test evs2[1].text == "a\e[Ab"

    # An empty paste still emits.
    r = InputParser()
    evs3 = feed!(r, "\e[200~\e[201~", 0.0)
    @test length(evs3) == 1
    @test evs3[1].text == ""

    # Keys around the paste survive.
    t = InputParser()
    evs4 = feed!(t, "x\e[200~p\e[201~y", 0.0)
    @test length(evs4) == 3
    @test evs4[1] == KeyEvent(Key.CHAR, 'x', MOD_NONE)
    @test evs4[2].text == "p"
    @test evs4[3] == KeyEvent(Key.CHAR, 'y', MOD_NONE)
end

@testitem "Input: lone ESC resolves via injected clock" begin
    using ManyUI

    # No sleep anywhere: the clock is a parameter.
    p = InputParser(esc_timeout = 0.05)
    @test isempty(feed!(p, UInt8[0x1b], 0.0))
    @test pending(p) == 1
    @test !isempty(p)
    @test isempty(flush_escape!(p, 0.0))
    @test isempty(flush_escape!(p, 0.049))
    evs = flush_escape!(p, 0.05)
    @test evs == Event[KeyEvent(Key.ESCAPE, '\0', MOD_NONE)]
    @test isempty(p)
    # Idempotent: it fires once, not forever.
    @test isempty(flush_escape!(p, 10.0))

    # An ESC that turns out to introduce a sequence never fires.
    q = InputParser(esc_timeout = 0.05)
    @test isempty(feed!(q, UInt8[0x1b], 0.0))
    @test feed!(q, UInt8[UInt8('['), UInt8('A')], 0.01) ==
          Event[KeyEvent(Key.UP, '\0', MOD_NONE)]
    @test isempty(flush_escape!(q, 100.0))

    # A partial CSI is not a pending lone ESC.
    r = InputParser()
    feed!(r, "\e[", 0.0)
    @test isempty(flush_escape!(r, 100.0))
    @test pending(r) == 2

    # The stamp is taken once and not refreshed by a no-op feed.
    u = InputParser(esc_timeout = 0.05)
    feed!(u, UInt8[0x1b], 0.0)
    feed!(u, UInt8[], 0.04)
    @test flush_escape!(u, 0.06) ==
          Event[KeyEvent(Key.ESCAPE, '\0', MOD_NONE)]
end

@testitem "Input: unknown CSI is consumed and dropped" begin
    using ManyUI

    for s in ("\e[99y", "\e[?1;2c", "\e[>0;95;0c", "\e[=1u", "\e[R")
        (evs, n) = parse_events(Vector{UInt8}(codeunits(s)))
        @test isempty(evs)
        @test n == ncodeunits(s)
    end

    # Consumed, so the next real key still lands.
    (evs, n) = parse_events(Vector{UInt8}(codeunits("\e[99ya")))
    @test evs == Event[KeyEvent(Key.CHAR, 'a', MOD_NONE)]
    @test n == 6

    # A CSI aborted by a control byte resynchronises on that byte.
    (evs2, n2) = parse_events(UInt8[0x1b, UInt8('['), 0x03])
    @test evs2 == Event[KeyEvent(Key.CHAR, 'c',
                                 Modifiers(UInt8(Modifier.CTRL)))]
    @test n2 == 3
end

@testitem "Input: empty! drops half-parsed state" begin
    using ManyUI

    p = InputParser()
    feed!(p, "\e[1;", 0.0)
    @test pending(p) == 4
    @test !isempty(p)
    @test empty!(p) === p
    @test isempty(p)
    @test pending(p) == 0
    @test !p.in_paste
    @test isnan(p.esc_at)

    # The first keystroke after a reattach is clean, not a stray '5C'.
    @test feed!(p, "a", 0.0) == Event[KeyEvent(Key.CHAR, 'a', MOD_NONE)]

    # An open paste is dropped too.
    q = InputParser()
    feed!(q, "\e[200~partial", 0.0)
    @test q.in_paste
    empty!(q)
    @test isempty(q)
    @test !q.in_paste
    @test isempty(q.paste)

    # A pending ESC is dropped too.
    r = InputParser()
    feed!(r, UInt8[0x1b], 0.0)
    empty!(r)
    @test isempty(flush_escape!(r, 100.0))
end

@testitem "Input: pump_input! puts events on a channel" begin
    using ManyUI

    p = InputParser()
    ch = Channel{Event}(16)

    @test pump_input!(p, ch, Vector{UInt8}(codeunits("ab")), 0.0) == 2
    @test take!(ch) == KeyEvent(Key.CHAR, 'a', MOD_NONE)
    @test take!(ch) == KeyEvent(Key.CHAR, 'b', MOD_NONE)

    # THE shared loop: a CSI split across two pumps yields one event.
    @test pump_input!(p, ch, UInt8[0x1b, UInt8('[')], 0.0) == 0
    @test pump_input!(p, ch, UInt8[UInt8('A')], 0.0) == 1
    @test take!(ch) == KeyEvent(Key.UP, '\0', MOD_NONE)

    # Nothing to put is not an error.
    @test pump_input!(p, ch, UInt8[], 0.0) == 0

    # A closed channel returns 0 and does not throw.
    close(ch)
    @test pump_input!(p, ch, Vector{UInt8}(codeunits("z")), 0.0) == 0
end

@testitem "Input: parse_events never throws" begin
    using ManyUI

    junk = Vector{UInt8}[
        UInt8[],
        UInt8[0x1b],
        UInt8[0x1b, UInt8('[')],
        UInt8[0x1b, UInt8('O')],
        UInt8[0x1b, 0x1b, 0x1b],
        UInt8[0x1b, 0xff],
        UInt8[0xff, 0xfe, 0xfd],
        UInt8[0xc0, 0x80],
        UInt8[0xf4, 0x90, 0x80, 0x80],
        UInt8[0x1b, UInt8('['), 0x07],
        UInt8[0x1b, UInt8('['), UInt8('<'), UInt8('9')],
        UInt8[0x1b, UInt8('['), UInt8('M')],
        UInt8[0x1b, UInt8('['), UInt8('2'), UInt8('0'), UInt8('0'),
              UInt8('~')],
        UInt8[0x00, 0x01, 0x1f, 0x7f],
    ]
    for b in junk
        (evs, n) = parse_events(b)
        @test evs isa Vector{Event}
        @test 0 <= n <= length(b)
    end

    # Deterministic fuzz: never throws and never over-consumes.
    for seed in 0:255
        b = UInt8[UInt8((seed * 7 + 13 * k) % 256) for k in 1:24]
        (evs, n) = parse_events(b)
        @test evs isa Vector{Event}
        @test 0 <= n <= length(b)
    end
end

@testitem "Input: InputParser is a thin shell over parse_events" begin
    using ManyUI

    p = InputParser()
    @test isempty(p)
    @test pending(p) == 0
    @test p.esc_timeout == 0.05
    @test isnan(p.esc_at)
    @test !p.in_paste

    @test InputParser(esc_timeout = 0.2).esc_timeout == 0.2

    # feed! on a String and on bytes agree.
    a = feed!(InputParser(), "\e[1;5C", 0.0)
    b = feed!(InputParser(), Vector{UInt8}(codeunits("\e[1;5C")), 0.0)
    @test a == b

    # Feeding nothing produces nothing and changes nothing.
    q = InputParser()
    @test isempty(feed!(q, UInt8[], 0.0))
    @test isempty(q)
end

@testitem "Input: file contains no IO type" begin
    using ManyUI

    src = read(joinpath(pkgdir(ManyUI), "src", "input.jl"), String)
    @test !occursin(r"\bIO\b", src)
    @test !occursin(r"\bIOBuffer\b", src)
    @test !occursin("stdin", src)
    @test !occursin("stdout", src)
    @test !occursin("stderr", src)
    @test !occursin(r"\bTTY\b", src)
    # No byte-source verbs are ever called here: bytes are pushed IN.
    @test !occursin(r"\bread\(", src)
    @test !occursin(r"\bwrite\(", src)
    @test !occursin(r"\breadbytes!\(", src)
    @test !occursin(r"\bopen\(", src)
end
