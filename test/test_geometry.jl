# test_geometry.jl -- @testitem blocks for src/geometry.jl (contract 2.2).
# Written BEFORE the implementation (house rule: TDD).

@testitem "geometry: Region isempty and area" begin
    using DualUI

    r = Region(1, 1, 10, 5)
    @test !isempty(r)
    @test area(r) == 50
    @test size_of(r) === Size(10, 5)
    @test origin(r) === Offset(1, 1)
    @test right(r) == 10
    @test bottom(r) == 5

    # 1-based inclusive: last cell is (x + w - 1, y + h - 1).
    r2 = Region(3, 4, 2, 3)
    @test right(r2) == 4
    @test bottom(r2) == 6
    @test area(r2) == 6

    @test isempty(EMPTY_REGION)
    @test area(EMPTY_REGION) == 0
    @test isempty(Region(1, 1, 0, 5))
    @test isempty(Region(1, 1, 5, 0))

    # area clamps per axis: a negative extent never yields a positive
    # or negative product.
    @test isempty(Region(1, 1, -3, 5))
    @test area(Region(1, 1, -3, 5)) == 0
    @test area(Region(1, 1, -3, -5)) == 0
    @test area(Region(1, 1, 5, -3)) == 0

    # Region(::Size) anchors at the origin.
    @test Region(Size(7, 3)) === Region(1, 1, 7, 3)
end

@testitem "geometry: intersect returns empty not nothing" begin
    using DualUI

    a = Region(1, 1, 10, 10)
    b = Region(5, 5, 10, 10)
    i = intersect(a, b)
    @test i isa Region              # type-stable: NEVER nothing
    @test i === Region(5, 5, 6, 6)
    @test intersect(a, b) === intersect(b, a)

    # Disjoint -> empty Region, still a Region.
    d = intersect(Region(1, 1, 2, 2), Region(50, 50, 2, 2))
    @test d isa Region
    @test isempty(d)
    @test d === EMPTY_REGION

    # Edge-adjacent but not overlapping.
    @test isempty(intersect(Region(1, 1, 5, 5), Region(6, 1, 5, 5)))
    # Sharing exactly one column.
    @test intersect(Region(1, 1, 5, 5), Region(5, 1, 5, 5)) ===
        Region(5, 1, 1, 5)

    # Containment: intersect with a superset is identity.
    @test intersect(b, Region(1, 1, 100, 100)) === b
    @test intersect(a, a) === a

    # An empty operand annihilates.
    @test isempty(intersect(a, EMPTY_REGION))
    @test isempty(intersect(EMPTY_REGION, a))

    # clamp_to is defined AS intersect.
    @test clamp_to(b, a) === intersect(b, a)
    @test clamp_to(Region(-5, -5, 3, 3), a) === intersect(
        Region(-5, -5, 3, 3), a)

    # Type stability of the hot clipping path.
    @test Base.return_types(intersect, (Region, Region))[1] === Region
end

@testitem "geometry: union is the bounding box" begin
    using DualUI

    a = Region(1, 1, 2, 2)
    b = Region(5, 5, 2, 2)
    u = union(a, b)
    @test u === Region(1, 1, 6, 6)
    @test union(a, b) === union(b, a)

    # The bounding box contains both operands.
    @test issubset(a, u)
    @test issubset(b, u)

    # Idempotent, and a superset absorbs.
    @test union(a, a) === a
    @test union(a, Region(1, 1, 100, 100)) === Region(1, 1, 100, 100)

    # An empty operand is the identity.
    @test union(a, EMPTY_REGION) === a
    @test union(EMPTY_REGION, a) === a
    @test isempty(union(EMPTY_REGION, EMPTY_REGION))

    # Disjoint on one axis only.
    @test union(Region(1, 1, 3, 10), Region(10, 1, 3, 10)) ===
        Region(1, 1, 12, 10)
end

@testitem "geometry: shrink clamps to zero never negative" begin
    using DualUI

    r = Region(1, 1, 10, 10)
    @test shrink(r, Spacing(1)) === Region(2, 2, 8, 8)
    @test shrink(r, NO_SPACING) === r

    # Asymmetric insets, CSS order (top, right, bottom, left).
    @test shrink(r, Spacing(1, 2, 3, 4)) === Region(5, 2, 4, 6)

    # Underflow MUST degrade to an empty region, never to a negative
    # extent that would crash a writer downstream.
    u = shrink(Region(1, 1, 4, 4), Spacing(10))
    @test u.width == 0
    @test u.height == 0
    @test isempty(u)
    @test area(u) == 0

    # Per-axis clamping: one axis may underflow while the other does not.
    p = shrink(Region(1, 1, 100, 2), Spacing(5))
    @test p.width == 90
    @test p.height == 0
    @test isempty(p)

    # Exact-fit underflow.
    @test isempty(shrink(Region(1, 1, 2, 2), Spacing(1)))

    # Extents are never negative for ANY spacing.
    for s in (Spacing(0), Spacing(1), Spacing(7), Spacing(3, 9),
              Spacing(2, 4, 6, 8))
        for w in (0, 1, 5, 12), h in (0, 1, 5, 12)
            q = shrink(Region(1, 1, w, h), s)
            @test q.width >= 0
            @test q.height >= 0
        end
    end
end

@testitem "geometry: grow inverts shrink on positive space" begin
    using DualUI

    r = Region(5, 5, 10, 10)
    for s in (Spacing(0), Spacing(1), Spacing(2, 3), Spacing(1, 2, 3, 4))
        # grow then shrink is the identity, always (grow never clamps).
        @test shrink(grow(r, s), s) === r
        # shrink then grow is the identity while space stays positive.
        @test grow(shrink(r, s), s) === r
    end

    @test grow(Region(5, 5, 4, 4), Spacing(1)) === Region(4, 4, 6, 6)
    @test grow(r, NO_SPACING) === r
    @test grow(Region(1, 1, 2, 2), Spacing(1, 2, 3, 4)) ===
        Region(-3, 0, 8, 6)

    # grow widens by exactly horizontal(s) / vertical(s).
    s = Spacing(1, 2, 3, 4)
    g = grow(r, s)
    @test g.width == r.width + horizontal(s)
    @test g.height == r.height + vertical(s)
end

@testitem "geometry: in is inclusive at both edges" begin
    using DualUI

    r = Region(2, 3, 4, 5)   # x: 2..5, y: 3..7
    @test Offset(2, 3) in r           # top-left corner
    @test Offset(5, 7) in r           # bottom-right corner
    @test Offset(5, 3) in r
    @test Offset(2, 7) in r
    @test Offset(3, 5) in r           # interior

    @test !(Offset(1, 3) in r)        # one left
    @test !(Offset(6, 3) in r)        # one right
    @test !(Offset(2, 2) in r)        # one above
    @test !(Offset(2, 8) in r)        # one below

    # Nothing is inside an empty region.
    @test !(Offset(1, 1) in EMPTY_REGION)
    @test !(Offset(0, 0) in EMPTY_REGION)
    @test !(Offset(3, 3) in Region(3, 3, 0, 0))

    # `in` agrees with the corners reported by right/bottom.
    @test Offset(right(r), bottom(r)) in r
    @test !(Offset(right(r) + 1, bottom(r)) in r)
    @test !(Offset(right(r), bottom(r) + 1) in r)

    # issubset is the region-level counterpart.
    @test issubset(Region(3, 4, 2, 2), r)
    @test issubset(r, r)
    @test !issubset(Region(1, 1, 10, 10), r)
    @test issubset(EMPTY_REGION, r)
    @test !issubset(r, EMPTY_REGION)
end

@testitem "geometry: split_row and split_col partition exactly" begin
    using DualUI

    r = Region(3, 4, 10, 6)

    top, bot = split_row(r, 2)
    @test top === Region(3, 4, 10, 2)
    @test bot === Region(3, 6, 10, 4)
    @test area(top) + area(bot) == area(r)
    @test union(top, bot) === r
    @test isempty(intersect(top, bot))

    lft, rgt = split_col(r, 4)
    @test lft === Region(3, 4, 4, 6)
    @test rgt === Region(7, 4, 6, 6)
    @test area(lft) + area(rgt) == area(r)
    @test union(lft, rgt) === r
    @test isempty(intersect(lft, rgt))

    # Degenerate splits still partition.
    t0, b0 = split_row(r, 0)
    @test isempty(t0)
    @test b0 === r
    tN, bN = split_row(r, r.height)
    @test tN === r
    @test isempty(bN)

    l0, r0 = split_col(r, 0)
    @test isempty(l0)
    @test r0 === r
    lN, rN = split_col(r, r.width)
    @test lN === r
    @test isempty(rN)

    # Out-of-range `at` clamps; extents never go negative.
    for at in -5:15
        a, b = split_row(r, at)
        @test a.height >= 0
        @test b.height >= 0
        @test area(a) + area(b) == area(r)
        c, d = split_col(r, at)
        @test c.width >= 0
        @test d.width >= 0
        @test area(c) + area(d) == area(r)
    end

    # Every cell of r belongs to exactly one piece of a split.
    a, b = split_row(r, 3)
    for x in r.x:right(r), y in r.y:bottom(r)
        o = Offset(x, y)
        @test (o in a) + (o in b) == 1
    end
end

@testitem "geometry: Spacing shorthand constructors" begin
    using DualUI

    # One-value shorthand: all four edges.
    @test Spacing(2) === Spacing(2, 2, 2, 2)
    @test Spacing(0) === NO_SPACING

    # Two-value shorthand: (vertical, horizontal), CSS order.
    @test Spacing(1, 3) === Spacing(1, 3, 1, 3)
    s = Spacing(1, 3)
    @test s.top == 1
    @test s.bottom == 1
    @test s.left == 3
    @test s.right == 3

    # Four-value form is CSS order: top, right, bottom, left.
    f = Spacing(1, 2, 3, 4)
    @test f.top == 1
    @test f.right == 2
    @test f.bottom == 3
    @test f.left == 4

    @test horizontal(f) == 6      # left + right
    @test vertical(f) == 4        # top + bottom
    @test horizontal(NO_SPACING) == 0
    @test vertical(NO_SPACING) == 0

    # Fieldwise addition.
    @test Spacing(1, 2, 3, 4) + Spacing(10, 20, 30, 40) ===
        Spacing(11, 22, 33, 44)
    @test f + NO_SPACING === f
    @test NO_SPACING + f === f
    @test (f + f) === Spacing(2, 4, 6, 8)
    @test horizontal(f + f) == 2 * horizontal(f)
end

@testitem "geometry: all types are isbits" begin
    using DualUI

    @test isbitstype(Size)
    @test isbitstype(Offset)
    @test isbitstype(Region)
    @test isbitstype(Spacing)

    @test isbits(Size(1, 2))
    @test isbits(Offset(1, 2))
    @test isbits(Region(1, 2, 3, 4))
    @test isbits(Spacing(1, 2, 3, 4))

    # Concrete fields only (house rule).
    for T in (Size, Offset, Region, Spacing)
        for i in 1:fieldcount(T)
            @test fieldtype(T, i) === Int
            @test isconcretetype(fieldtype(T, i))
        end
    end

    # Value semantics: === is structural, so tests can compare directly.
    @test Region(1, 2, 3, 4) === Region(1, 2, 3, 4)
    @test Size(1, 2) === Size(1, 2)
end

@testitem "geometry: constants and translation" begin
    using DualUI

    @test ORIGIN === Offset(0, 0)
    @test NO_SPACING === Spacing(0, 0, 0, 0)
    @test EMPTY_REGION === Region(1, 1, 0, 0)
    @test isempty(EMPTY_REGION)

    r = Region(3, 4, 5, 6)
    @test translate(r, Offset(2, 3)) === Region(5, 7, 5, 6)
    @test translate(r, ORIGIN) === r
    @test translate(r, Offset(-2, -3)) === Region(1, 1, 5, 6)

    # translate preserves extent and is additive.
    t = translate(r, Offset(2, 3))
    @test size_of(t) === size_of(r)
    @test area(t) == area(r)
    @test translate(translate(r, Offset(1, 1)), Offset(2, 2)) ===
        translate(r, Offset(3, 3))

    # translate moves the origin by exactly the offset.
    @test origin(translate(r, Offset(7, 8))) ===
        origin(r) + Offset(7, 8)
end

@testitem "geometry: Offset and Size algebra" begin
    using DualUI

    @test Offset(1, 2) + Offset(3, 4) === Offset(4, 6)
    @test Offset(5, 7) - Offset(1, 2) === Offset(4, 5)
    @test Offset(1, 2) + ORIGIN === Offset(1, 2)
    @test Offset(1, 2) - Offset(1, 2) === ORIGIN
    @test Offset(1, 2) - Offset(3, 5) === Offset(-2, -3)

    @test Size(2, 3) + Size(4, 5) === Size(6, 8)
    @test Size(2, 3) + Size(0, 0) === Size(2, 3)

    # Offset addition is commutative and associative.
    a, b, c = Offset(1, 2), Offset(3, 4), Offset(5, 6)
    @test a + b === b + a
    @test (a + b) + c === a + (b + c)
end

@testitem "geometry: clamp_size clamps per axis" begin
    using DualUI

    lo = Size(2, 3)
    hi = Size(10, 12)

    @test clamp_size(Size(5, 5), lo, hi) === Size(5, 5)
    @test clamp_size(Size(1, 1), lo, hi) === Size(2, 3)
    @test clamp_size(Size(99, 99), lo, hi) === Size(10, 12)

    # Per-axis, not whole-struct: each axis clamps independently.
    @test clamp_size(Size(1, 99), lo, hi) === Size(2, 12)
    @test clamp_size(Size(99, 1), lo, hi) === Size(10, 3)

    # Boundaries are inclusive.
    @test clamp_size(lo, lo, hi) === lo
    @test clamp_size(hi, lo, hi) === hi

    # Idempotent.
    s = clamp_size(Size(99, 0), lo, hi)
    @test clamp_size(s, lo, hi) === s
end
