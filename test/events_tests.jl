# events_tests.jl -- @testitem blocks for DualUI/src/events.jl.
# Written BEFORE the implementation (TDD). Each block is self-contained:
# TestItemRunner evaluates it in its own fresh module.
#
# Accountable for EARS 2.2 / E3 at the envelope level: `Dispatch{E}`,
# `Phase`, `consume!` and `on_event!` are what a capture/bubble walk is
# built out of. The walk itself (`propagate!`) lives in dispatch.jl.

@testitem "events: Modifiers bitset operations" begin
    using DualUI

    @test MOD_NONE === Modifiers(0x00)
    @test Modifiers() === MOD_NONE
    @test isempty(Modifiers())
    @test isbits(MOD_NONE)

    ctrl = Modifiers(Modifier.CTRL)
    @test Modifier.CTRL in ctrl
    @test !(Modifier.ALT in ctrl)
    @test !isempty(ctrl)

    both = Modifiers(Modifier.CTRL, Modifier.SHIFT)
    @test Modifier.CTRL in both
    @test Modifier.SHIFT in both
    @test !(Modifier.ALT in both)
    @test !(Modifier.SUPER in both)

    # `|` in both arities.
    @test (ctrl | Modifier.SHIFT) === both
    @test (Modifiers(Modifier.CTRL) | Modifiers(Modifier.SHIFT)) === both

    # A set union: idempotent, commutative, associative, identity
    # MOD_NONE.
    @test (both | Modifier.CTRL) === both
    @test (both | both) === both
    @test (MOD_NONE | both) === both
    @test (both | MOD_NONE) === both
    alt = Modifiers(Modifier.ALT)
    @test ((ctrl | alt) | Modifiers(Modifier.SHIFT)) ===
          (ctrl | (alt | Modifiers(Modifier.SHIFT)))

    # Duplicate arguments collapse; argument order does not matter.
    @test Modifiers(Modifier.CTRL, Modifier.CTRL) === ctrl
    @test Modifiers(Modifier.SHIFT, Modifier.CTRL) === both

    # Every modifier is a distinct power of two, so the bitset is exact.
    all4 = Modifiers(Modifier.SHIFT, Modifier.ALT,
                     Modifier.CTRL, Modifier.SUPER)
    @test all(m -> m in all4, instances(Modifier.T))
    @test all4.bits === 0x0f
    @test !isempty(all4)
end

@testitem "events: enum modules are module-scoped and ordered" begin
    using DualUI

    # Finite value sets are module-scoped enums named `T`.
    @test Key.CHAR isa Key.T
    @test Modifier.SHIFT isa Modifier.T
    @test MouseButton.NONE isa MouseButton.T
    @test MouseAction.PRESS isa MouseAction.T
    @test Phase.CAPTURE isa Phase.T

    # Zero-valued members are pinned, so the wire and the enum agree.
    @test UInt16(Key.CHAR) === 0x0000
    @test UInt8(MouseButton.NONE) === 0x00
    @test UInt8(MouseAction.PRESS) === 0x00
    @test UInt8(Phase.CAPTURE) === 0x00

    # Modifier values are bitmask powers of two (house rule).
    @test UInt8(Modifier.SHIFT) === 0x01
    @test UInt8(Modifier.ALT) === 0x02
    @test UInt8(Modifier.CTRL) === 0x04
    @test UInt8(Modifier.SUPER) === 0x08
    @test all(m -> count_ones(UInt8(m)) == 1, instances(Modifier.T))

    # Phase is ordered: it names a chronology, not a set.
    @test Phase.CAPTURE < Phase.AT_TARGET < Phase.BUBBLE
    @test collect(instances(Phase.T)) ==
          [Phase.CAPTURE, Phase.AT_TARGET, Phase.BUBBLE]

    # The whole key vocabulary the spec calls for is present.
    @test length(instances(Key.T)) == 30
    @test Key.UNKNOWN isa Key.T
    @test length(instances(MouseButton.T)) == 8
    @test length(instances(MouseAction.T)) == 4
end

@testitem "events: event structs form the Event hierarchy" begin
    using DualUI

    @test KeyEvent <: Event
    @test MouseEvent <: Event
    @test ResizeEvent <: Event
    @test PasteEvent <: Event
    @test FocusEvent <: Event
    @test TickEvent <: Event
    @test RefreshEvent <: Event
    @test QuitEvent <: Event

    # Everything on the hot path stays isbits; only PasteEvent, which
    # carries an arbitrary-length String, cannot.
    @test isbitstype(KeyEvent)
    @test isbitstype(MouseEvent)
    @test isbitstype(ResizeEvent)
    @test isbitstype(FocusEvent)
    @test isbitstype(TickEvent)
    @test isbitstype(RefreshEvent)
    @test isbitstype(QuitEvent)
    @test !isbitstype(PasteEvent)

    # Fields carry what the contract says they carry.
    @test ResizeEvent(Size(80, 24)).size === Size(80, 24)
    @test PasteEvent("a\nb").text == "a\nb"
    @test FocusEvent(true).gained
    @test !FocusEvent(false).gained
    @test TickEvent(1.5).time === 1.5
    m = MouseEvent(MouseAction.DRAG, MouseButton.RIGHT, 7, 9,
                   Modifiers(Modifier.ALT))
    @test m.action === MouseAction.DRAG
    @test m.button === MouseButton.RIGHT
    @test m.x === 7
    @test m.y === 9
    @test Modifier.ALT in m.mods

    # Immutable values, so equality is structural and replay is safe.
    @test ResizeEvent(Size(80, 24)) === ResizeEvent(Size(80, 24))
    @test ResizeEvent(Size(80, 24)) != ResizeEvent(Size(80, 25))
    @test FocusEvent(true) != FocusEvent(false)
    @test RefreshEvent() === RefreshEvent()
    @test QuitEvent() === QuitEvent()
    @test KeyEvent(Key.CHAR, 'q', MOD_NONE) ===
          KeyEvent(Key.CHAR, 'q', MOD_NONE)
end

@testitem "events: key builds a KeyEvent from a Char or a Key.T" begin
    using DualUI

    @test key('q') === KeyEvent(Key.CHAR, 'q', MOD_NONE)
    @test key('c'; ctrl = true) ===
          KeyEvent(Key.CHAR, 'c', Modifiers(Modifier.CTRL))
    @test key(Key.ENTER) === KeyEvent(Key.ENTER, '\0', MOD_NONE)
    @test key(Key.ENTER; alt = true) ===
          KeyEvent(Key.ENTER, '\0', Modifiers(Modifier.ALT))
    @test key(Key.LEFT; ctrl = true, shift = true) ===
          KeyEvent(Key.LEFT, '\0',
                   Modifiers(Modifier.CTRL, Modifier.SHIFT))

    # `char` is meaningful ONLY when `code === Key.CHAR`.
    @test key('x').code === Key.CHAR
    @test key(Key.F5).char === '\0'
    @test key(Key.ESCAPE).char === '\0'
    @test all(k -> key(k).char === '\0',
              filter(!=(Key.CHAR), collect(instances(Key.T))))

    # Non-ASCII characters survive verbatim.
    @test key('é').char === 'é'
    @test key('世').char === '世'

    # All three modifier flags at once.
    @test key('a'; ctrl = true, alt = true, shift = true).mods ===
          Modifiers(Modifier.CTRL, Modifier.ALT, Modifier.SHIFT)
    @test key('a').mods === MOD_NONE
end

@testitem "events: is_scroll is true for the wheel buttons only" begin
    using DualUI

    mk(b) = MouseEvent(MouseAction.PRESS, b, 1, 1, MOD_NONE)
    @test is_scroll(mk(MouseButton.WHEEL_UP))
    @test is_scroll(mk(MouseButton.WHEEL_DOWN))
    @test is_scroll(mk(MouseButton.WHEEL_LEFT))
    @test is_scroll(mk(MouseButton.WHEEL_RIGHT))
    @test !is_scroll(mk(MouseButton.NONE))
    @test !is_scroll(mk(MouseButton.LEFT))
    @test !is_scroll(mk(MouseButton.MIDDLE))
    @test !is_scroll(mk(MouseButton.RIGHT))

    # Scroll-ness is a property of the button, never of the action.
    for a in instances(MouseAction.T)
        @test is_scroll(MouseEvent(a, MouseButton.WHEEL_UP, 3, 4,
                                   MOD_NONE))
        @test !is_scroll(MouseEvent(a, MouseButton.LEFT, 3, 4,
                                    MOD_NONE))
    end
end

@testitem "events: parse KeyEvent accepts documented forms" begin
    using DualUI

    # Every form named in the contract, verbatim.
    @test parse(KeyEvent, "q") === key('q')
    @test parse(KeyEvent, "ctrl+c") === key('c'; ctrl = true)
    @test parse(KeyEvent, "shift+tab") === key(Key.TAB; shift = true)
    @test parse(KeyEvent, "f1") === key(Key.F1)
    @test parse(KeyEvent, "alt+enter") === key(Key.ENTER; alt = true)
    @test parse(KeyEvent, "ctrl+shift+left") ===
          key(Key.LEFT; ctrl = true, shift = true)
    @test parse(KeyEvent, "escape") === key(Key.ESCAPE)
    @test parse(KeyEvent, "space") === key(Key.SPACE)

    # Names are case-insensitive, modifier and key alike.
    @test parse(KeyEvent, "CTRL+Shift+LEFT") ===
          parse(KeyEvent, "ctrl+shift+left")
    @test parse(KeyEvent, "F12") === key(Key.F12)
    @test parse(KeyEvent, "Escape") === key(Key.ESCAPE)
    @test parse(KeyEvent, "AlT+eNtEr") === key(Key.ENTER; alt = true)

    # Modifier order does not matter: it is a set.
    @test parse(KeyEvent, "shift+ctrl+left") ===
          parse(KeyEvent, "ctrl+shift+left")
    @test parse(KeyEvent, "super+alt+ctrl+shift+home") ===
          KeyEvent(Key.HOME, '\0',
                   Modifiers(Modifier.SUPER, Modifier.ALT,
                             Modifier.CTRL, Modifier.SHIFT))

    # A one-character key is literal, case included -- only NAMES fold.
    @test parse(KeyEvent, "Q") === key('Q')
    @test parse(KeyEvent, "q") !== parse(KeyEvent, "Q")
    @test parse(KeyEvent, "é") === key('é')

    # '+' is both the separator and a perfectly good key.
    @test parse(KeyEvent, "+") === key('+')
    @test parse(KeyEvent, "ctrl++") === key('+'; ctrl = true)

    # Every named key round-trips through its own lowercased name.
    for k in instances(Key.T)
        (k === Key.CHAR || k === Key.UNKNOWN) && continue
        @test parse(KeyEvent, lowercase(string(k))) === key(k)
    end
end

@testitem "events: parse KeyEvent throws where tryparse says no" begin
    using DualUI

    bad = ("", "+ctrl", "ctrl+", "nope+q", "ctrl+nope", "qq", "f13",
           "ctrl shift left", "ctrl+ +c", "ctrl++c", "++", "ctrl", "f0")
    for s in bad
        @test tryparse(KeyEvent, s) === nothing
        @test_throws ArgumentError parse(KeyEvent, s)
    end

    # tryparse and parse agree on every good form.
    good = ("q", "ctrl+c", "shift+tab", "f1", "alt+enter",
            "ctrl+shift+left", "escape", "space", "+", "ctrl++")
    for s in good
        @test tryparse(KeyEvent, s) === parse(KeyEvent, s)
        @test tryparse(KeyEvent, s) isa KeyEvent
    end
end

@testitem "events: Dispatch starts at the target in the capture phase" begin
    using DualUI

    struct DNode <: DualUI.Widget
        name::Symbol
    end

    t = DNode(:target)
    e = key('a')
    d = Dispatch(e, t)

    # The envelope's initial state IS the precondition of a capture walk.
    @test d isa Dispatch{KeyEvent}
    @test d.event === e
    @test d.target === t
    @test d.current === t
    @test d.phase === Phase.CAPTURE
    @test !is_consumed(d)
    @test !d.consumed

    # `event` is the type-stable accessor: parametric on E, no boxing.
    @test event(d) === e
    @test (@inferred event(d)) === e
    @test Base.return_types(event, (Dispatch{KeyEvent},)) == [KeyEvent]

    # Every event type gets its own concrete envelope type.
    mouse = MouseEvent(MouseAction.PRESS, MouseButton.LEFT, 1, 1,
                       MOD_NONE)
    @test Dispatch(mouse, t) isa Dispatch{MouseEvent}
    @test Dispatch(ResizeEvent(Size(4, 4)), t) isa Dispatch{ResizeEvent}
    @test Dispatch(PasteEvent("x"), t) isa Dispatch{PasteEvent}
    @test Dispatch(FocusEvent(true), t) isa Dispatch{FocusEvent}
    @test Dispatch(TickEvent(0.0), t) isa Dispatch{TickEvent}
    @test Dispatch(RefreshEvent(), t) isa Dispatch{RefreshEvent}
    @test Dispatch(QuitEvent(), t) isa Dispatch{QuitEvent}
    @test Dispatch(mouse, t) isa Dispatch
    @test Dispatch(mouse, t) isa Dispatch{<:Event}

    # `event` and `target` are const: an envelope may be walked, never
    # rewritten.
    @test_throws ErrorException setfield!(d, :event, key('b'))
    @test_throws ErrorException setfield!(d, :target, DNode(:other))
    # `current`, `phase` and `consumed` are the walk's own scratch space.
    d.current = DNode(:other)
    d.phase = Phase.BUBBLE
    @test d.current.name === :other
    @test d.phase === Phase.BUBBLE
    @test d.target === t
end

@testitem "events: Dispatch consume! is one-way" begin
    using DualUI

    struct CNode <: DualUI.Widget end

    d = Dispatch(key('x'), CNode())
    @test !is_consumed(d)
    @test consume!(d) === nothing
    @test is_consumed(d)
    @test d.consumed

    # Idempotent, and there is no un-consume anywhere in the API.
    consume!(d)
    @test is_consumed(d)
    @test !isdefined(DualUI, :unconsume!)
    @test !isdefined(DualUI, :release!)

    # Consumption lives on the ENVELOPE, not on the event, so the same
    # immutable event replays on a fresh envelope uncontaminated.
    e = key('x')
    d1 = Dispatch(e, CNode())
    consume!(d1)
    d2 = Dispatch(e, CNode())
    @test is_consumed(d1)
    @test !is_consumed(d2)
    @test event(d1) === event(d2) === e
end

@testitem "events: Dispatch drives a capture then bubble walk" begin
    using DualUI

    # EARS 2.2 / E3 at the envelope level, on a plain node chain: no
    # terminal, no driver, no layout, no App. `propagate!` itself is
    # dispatch.jl's; what is proved here is that `Dispatch`, `Phase`,
    # `on_event!` and `consume!` are together SUFFICIENT to express a
    # root->target capture pass and a target->root bubble pass that stop
    # the instant the event is consumed. The walk below mirrors the
    # contract's `propagate!` algorithm step for step.

    mutable struct Probe <: DualUI.Widget
        name::Symbol
        consume_on::Union{Nothing,Phase.T}
    end
    Probe(name::Symbol) = Probe(name, nothing)

    const LOG = Tuple{Symbol,Phase.T}[]

    function DualUI.on_event!(w::Probe, d::Dispatch{KeyEvent})
        push!(LOG, (w.name, d.phase))
        w.consume_on === d.phase && consume!(d)
        return nothing
    end

    function walk!(path::Vector{Probe}, e::Event)
        d = Dispatch(e, path[end])
        for i in 1:(length(path) - 1)          # CAPTURE, root -> target
            is_consumed(d) && return d
            d.current = path[i]
            d.phase = Phase.CAPTURE
            on_event!(path[i], d)
        end
        if !is_consumed(d)                     # AT_TARGET
            d.current = path[end]
            d.phase = Phase.AT_TARGET
            on_event!(path[end], d)
        end
        for i in (length(path) - 1):-1:1       # BUBBLE, target -> root
            is_consumed(d) && return d
            d.current = path[i]
            d.phase = Phase.BUBBLE
            on_event!(path[i], d)
        end
        return d
    end

    root, mid, leaf = Probe(:root), Probe(:mid), Probe(:leaf)
    path = [root, mid, leaf]
    # `reset!` is a DualUI export, so the local helper is renamed.
    rearm!() = (foreach(p -> p.consume_on = nothing, path);
                empty!(LOG))

    # 1. Nobody consumes: capture root->target, then bubble target->root.
    rearm!()
    d = walk!(path, key('a'))
    @test !is_consumed(d)
    @test LOG == [(:root, Phase.CAPTURE), (:mid, Phase.CAPTURE),
                  (:leaf, Phase.AT_TARGET),
                  (:mid, Phase.BUBBLE), (:root, Phase.BUBBLE)]
    # Capture order is root-first, bubble order is its exact reverse.
    caps = [n for (n, p) in LOG if p === Phase.CAPTURE]
    bubs = [n for (n, p) in LOG if p === Phase.BUBBLE]
    @test caps == [:root, :mid]
    @test bubs == reverse(caps)
    # The target is visited exactly once, and AT_TARGET tells that visit
    # apart from the two it would otherwise be confused with.
    @test count(l -> l[1] === :leaf, LOG) == 1
    @test LOG[3] === (:leaf, Phase.AT_TARGET)
    @test d.current === root

    # 2. Consuming mid-CAPTURE: the target and the WHOLE bubble phase
    #    never see the event.
    rearm!()
    mid.consume_on = Phase.CAPTURE
    d = walk!(path, key('a'))
    @test is_consumed(d)
    @test LOG == [(:root, Phase.CAPTURE), (:mid, Phase.CAPTURE)]
    @test !any(l -> l[1] === :leaf, LOG)
    @test !any(l -> l[2] === Phase.AT_TARGET, LOG)
    @test !any(l -> l[2] === Phase.BUBBLE, LOG)

    # 3. Consuming at the root, on the very first visit: nothing else in
    #    the tree is ever touched.
    rearm!()
    root.consume_on = Phase.CAPTURE
    d = walk!(path, key('a'))
    @test is_consumed(d)
    @test LOG == [(:root, Phase.CAPTURE)]

    # 4. Consuming AT_TARGET: capture ran in full, bubble not at all.
    rearm!()
    leaf.consume_on = Phase.AT_TARGET
    d = walk!(path, key('a'))
    @test is_consumed(d)
    @test LOG == [(:root, Phase.CAPTURE), (:mid, Phase.CAPTURE),
                  (:leaf, Phase.AT_TARGET)]

    # 5. Consuming mid-BUBBLE stops the remainder of the bubble.
    rearm!()
    mid.consume_on = Phase.BUBBLE
    d = walk!(path, key('a'))
    @test is_consumed(d)
    @test LOG == [(:root, Phase.CAPTURE), (:mid, Phase.CAPTURE),
                  (:leaf, Phase.AT_TARGET), (:mid, Phase.BUBBLE)]
    @test !any(l -> l === (:root, Phase.BUBBLE), LOG)

    # 6. A single-node path degenerates to one AT_TARGET visit.
    rearm!()
    solo = Probe(:solo)
    d = walk!([solo], key('a'))
    @test !is_consumed(d)
    @test LOG == [(:solo, Phase.AT_TARGET)]

    # 7. The event itself is untouched by any of it, so the identical
    #    event replays on a second tree with no contamination.
    rearm!()
    e = key('a')
    root.consume_on = Phase.CAPTURE
    @test is_consumed(walk!(path, e))
    rearm!()
    @test !is_consumed(walk!(path, e))
    @test length(LOG) == 5
end

@testitem "events: on_event! default fallback is a no-op" begin
    using DualUI

    struct Silent <: DualUI.Widget end

    # E3: a widget that handles nothing is a widget that defines
    # nothing. Every event type falls through the same fallback
    # untouched -- an unhandled event must keep propagating.
    for e in (key('a'),
              MouseEvent(MouseAction.MOVE, MouseButton.NONE, 1, 1,
                         MOD_NONE),
              ResizeEvent(Size(2, 2)), PasteEvent("x"),
              FocusEvent(true), TickEvent(0.0), RefreshEvent(),
              QuitEvent())
        d = Dispatch(e, Silent())
        @test on_event!(Silent(), d) === nothing
        @test !is_consumed(d)
        @test d.phase === Phase.CAPTURE
        @test event(d) === e
    end
end

@testitem "events: local_offset is widget-local 1-based" begin
    using DualUI

    struct Boxed <: DualUI.Widget
        r::Region
    end
    DualUI.region(w::Boxed) = w.r

    w = Boxed(Region(10, 5, 20, 8))     # x in 10:29, y in 5:12
    mouse(x, y) = MouseEvent(MouseAction.PRESS, MouseButton.LEFT,
                             x, y, MOD_NONE)

    # The region's origin maps to (1, 1), not (0, 0): 1-based, locked.
    @test local_offset(Dispatch(mouse(10, 5), w)) === Offset(1, 1)
    # The far corner maps to exactly (width, height).
    @test local_offset(Dispatch(mouse(29, 12), w)) === Offset(20, 8)
    @test local_offset(Dispatch(mouse(15, 7), w)) === Offset(6, 3)
    @test local_offset(Dispatch(mouse(10, 12), w)) === Offset(1, 8)
    @test local_offset(Dispatch(mouse(29, 5), w)) === Offset(20, 1)
    @test local_offset(Dispatch(mouse(10, 5), w)) isa Offset

    # A widget at the screen origin is the identity.
    at_origin = Boxed(Region(1, 1, 40, 20))
    @test local_offset(Dispatch(mouse(15, 7), at_origin)) ===
          Offset(15, 7)

    # It is relative to `current`, NOT to `target`: a capture-phase
    # handler on an ancestor gets coordinates in ITS box, which is the
    # whole reason the call site must never hand-roll the subtraction.
    d = Dispatch(mouse(15, 7), w)
    @test local_offset(d) === Offset(6, 3)
    d.current = at_origin
    @test local_offset(d) === Offset(15, 7)
    @test d.target === w

    # Points outside the box are NOT clamped; the caller decides.
    @test local_offset(Dispatch(mouse(9, 4), w)) === Offset(0, 0)
    @test local_offset(Dispatch(mouse(30, 13), w)) === Offset(21, 9)

    # Defined for Dispatch{MouseEvent} only -- there is no sensible
    # position for a keystroke.
    @test_throws MethodError local_offset(Dispatch(key('a'), w))
    @test_throws MethodError local_offset(Dispatch(TickEvent(0.0), w))
end
