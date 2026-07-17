# buffer.jl -- layer 3.
# May reference: types, geometry, unicode, style, boxmodel.
# E2 (the front/back grids the diff compares) and S3 (wide graphemes).

"""
One grid cell. `isbits` because `content` is an `InlineStrings.String31`
-- a `Matrix{Cell}` of pointers would mean `diff` chases 2*W*H pointers
per frame and the GC sees every cell.

Width discipline (S3):

  * `width == 2` -- a wide grapheme; the cell at `x + 1` is its
    continuation.
  * `width == 0` -- a continuation cell; `content == ""`. Never
    emitted.
  * `width == 1` -- an ordinary cell.
"""
struct Cell
    "The grapheme cluster displayed here."
    content::String31
    "Style the cluster is painted with."
    style::Style
    "Display cells occupied: 0 (continuation), 1 or 2."
    width::Int8
end

const CELL_BLANK = Cell(String31(" "), STYLE_NONE, Int8(1))
const CELL_CONT = Cell(String31(""), STYLE_NONE, Int8(0))

"""
Longest valid UTF-8 prefix of `s` holding at most 31 bytes -- the
capacity of a `String31`. Never splits a codepoint. Pure.
"""
function _fit31(s::AbstractString)::String
    str = String(s)
    ncodeunits(str) <= 31 && return str
    # `thisind(str, 32)` starts the codepoint covering byte 32, so the
    # codepoint before it ends at byte 31 or earlier.
    last = prevind(str, thisind(str, 32))
    return last == 0 ? "" : String(SubString(str, 1, last))
end

"""
Build a cell from a grapheme cluster; the width comes from
`grapheme_width`.

NORMATIVE overflow rule: `String31` holds at most 31 bytes, and real
emoji reach 27. A cluster exceeding 31 bytes is truncated to its
longest valid UTF-8 prefix of `<= 31` bytes, and the width computed
from the ORIGINAL cluster is retained. MUST NOT throw.
"""
Cell(g::AbstractString, s::Style = STYLE_NONE)::Cell =
    Cell(String31(_fit31(g)), s, Int8(grapheme_width(g)))

"""
True when `c` is the second half of a wide grapheme. Pure.
"""
is_continuation(c::Cell)::Bool = c.width == Int8(0)

"""
A dense cell grid.

`cells` has dims `(width, height)` and is indexed `[x, y]`, so a screen
row is stride-1 contiguous and `diff` scans rows linearly.

`<: AbstractMatrix{Cell}` earns `fill!`, `copyto!`, `==`, `similar`,
broadcasting and `show` for free.
"""
struct Buffer <: AbstractMatrix{Cell}
    "Backing grid, dims `(width, height)`, indexed `[x, y]`."
    cells::Matrix{Cell}
end

"""
A clipped, coordinate-translated window onto a `Buffer`.

`region` is in parent-ABSOLUTE coordinates; the view indexes in LOCAL
1-based coordinates and SILENTLY DROPS out-of-range writes (returning
`CELL_BLANK` on out-of-range reads).

This replaces threading a `clip::Region` keyword through every writer:
`render!` receives a view and structurally cannot paint outside its box.
"""
struct BufferView <: AbstractMatrix{Cell}
    "The buffer written through."
    parent::Buffer
    "Absolute window into `parent`."
    region::Region
end

"""
A window onto a `Buffer` whose local ORIGIN and writable CLIP are
INDEPENDENT.

`frame` fixes the coordinate system and the reported size: local
`(1, 1)` is `(frame.x, frame.y)` and `size(v) === (frame.width,
frame.height)`. `clip` is the absolute set of cells a write may actually
reach. Out-of-range writes are SILENTLY DROPPED; out-of-range reads
return `CELL_BLANK`.

THE INVERSION `BufferView` cannot express: `BufferView` says "region is
both the origin and the clip, and they coincide". This type says "the
CLIP IS THE ONLY AUTHORITY; the frame is only a coordinate system".
That is what `paint.jl` always instructed ("Clipping wins if that ever
changes") made structural.

`BufferView` is deliberately left alone rather than grown a third
field: it is on the per-cell write path of every frame of every app,
and its `setindex!`/`getindex` are under exact-cell assertions. A new
type costs the unscrolled path nothing, because `_paint_node!` never
builds one -- an unclipped node's frame IS its clip and it still gets a
`BufferView`.

INVARIANT, established by the INNER CONSTRUCTOR and relied on by every
accessor: `clip ⊆ frame ∩ buffer_region(parent)`. A malformed view is
unrepresentable; there is no other constructor.
"""
struct ScrolledView <: AbstractMatrix{Cell}
    "The buffer written through."
    parent::Buffer
    "ABSOLUTE frame: fixes local (1, 1) and the reported size."
    frame::Region
    "ABSOLUTE writable window. Always a subset of `frame` and `parent`."
    clip::Region

    function ScrolledView(p::Buffer, frame::Region,
                          clip::Region)::ScrolledView
        return new(p, frame,
                   intersect(intersect(clip, frame), buffer_region(p)))
    end
end

"""
A buffer of `s`, filled with `CELL_BLANK`.
"""
Buffer(s::Size)::Buffer = Buffer(s.width, s.height)

"""
A `w` x `h` buffer, filled with `CELL_BLANK`.
"""
Buffer(w::Int, h::Int)::Buffer =
    Buffer(fill(CELL_BLANK, max(w, 0), max(h, 0)))

"""
`(width, height)`. Honours the `AbstractArray` contract by returning a
`Tuple`; `buffer_size` returns the domain type.
"""
Base.size(b::Buffer)::Tuple{Int,Int} = size(b.cells)

"""
`(region.width, region.height)`.
"""
Base.size(v::BufferView)::Tuple{Int,Int} =
    (v.region.width, v.region.height)

Base.IndexStyle(::Type{<:Buffer}) = IndexCartesian()
Base.IndexStyle(::Type{<:BufferView}) = IndexCartesian()

"""
Read one cell in absolute 1-based coordinates.
"""
Base.getindex(b::Buffer, x::Int, y::Int)::Cell = b.cells[x, y]

"""
Write one cell in absolute 1-based coordinates.
"""
Base.setindex!(b::Buffer, c::Cell, x::Int, y::Int)::Cell =
    (b.cells[x, y] = c)

"""
Read one cell in view-LOCAL 1-based coordinates. Out-of-range reads
return `CELL_BLANK`.
"""
function Base.getindex(v::BufferView, x::Int, y::Int)::Cell
    r = v.region
    (1 <= x <= r.width && 1 <= y <= r.height) || return CELL_BLANK
    px, py = r.x + x - 1, r.y + y - 1
    w, h = size(v.parent)
    (1 <= px <= w && 1 <= py <= h) || return CELL_BLANK
    return v.parent[px, py]
end

"""
Write one cell in view-LOCAL 1-based coordinates. Out-of-range writes
are SILENTLY DROPPED.
"""
function Base.setindex!(v::BufferView, c::Cell, x::Int, y::Int)::Cell
    r = v.region
    (1 <= x <= r.width && 1 <= y <= r.height) || return c
    px, py = r.x + x - 1, r.y + y - 1
    w, h = size(v.parent)
    (1 <= px <= w && 1 <= py <= h) || return c
    v.parent[px, py] = c
    return c
end

"""
Semantic size accessor: `Base.size` honours the `AbstractArray`
contract and returns a `Tuple`; THIS returns the domain type. Pure.
"""
function buffer_size(b::AbstractMatrix{Cell})::Size
    w, h = size(b)
    return Size(w, h)
end

"""
`Region(1, 1, width, height)` of `b`. Pure.
"""
function buffer_region(b::AbstractMatrix{Cell})::Region
    w, h = size(b)
    return Region(1, 1, w, h)
end

"""
A sub-view in ABSOLUTE coordinates.
"""
Base.view(b::Buffer, r::Region)::BufferView =
    BufferView(b, intersect(r, buffer_region(b)))

"""
A sub-view in coordinates LOCAL to `v`.

Nested views stay two-level: this intersects and re-anchors to
`v.parent`, so there is never a chain to walk.
"""
function Base.view(v::BufferView, r::Region)::BufferView
    abs_r = Region(v.region.x + r.x - 1, v.region.y + r.y - 1,
                   r.width, r.height)
    return BufferView(v.parent, intersect(abs_r, v.region))
end

"""
`(frame.width, frame.height)` -- the FRAME's extent, NOT the clip's.

This is the whole point: `size(buf)` inside `render!` is the widget's
real content box, INVARIANT under scroll, so a scrolled `Label` does not
rewrap and a scrolled `Button` does not re-centre.
"""
Base.size(v::ScrolledView)::Tuple{Int,Int} =
    (v.frame.width, v.frame.height)

Base.IndexStyle(::Type{<:ScrolledView}) = IndexCartesian()

"""
Read one cell in view-LOCAL 1-based coordinates. Reads outside the CLIP
return `CELL_BLANK`, which is what keeps `_break_wide!` honest across a
clip edge.
"""
function Base.getindex(v::ScrolledView, x::Int, y::Int)::Cell
    f = v.frame
    px, py = f.x + x - 1, f.y + y - 1
    k = v.clip
    (k.x <= px <= right(k) && k.y <= py <= bottom(k)) ||
        return CELL_BLANK
    return v.parent[px, py]
end

"""
Write one cell in view-LOCAL 1-based coordinates. Writes outside the
CLIP are SILENTLY DROPPED.

The test is against the CLIP alone, never against the frame or the
parent: the inner constructor already proved `clip ⊆ frame ∩ parent`, so
one rectangle test is total. A local index BELOW the clip is a row or
column scrolled off the top or left -- dropping it IS the scroll.
"""
function Base.setindex!(v::ScrolledView, c::Cell, x::Int,
                        y::Int)::Cell
    f = v.frame
    px, py = f.x + x - 1, f.y + y - 1
    k = v.clip
    (k.x <= px <= right(k) && k.y <= py <= bottom(k)) || return c
    v.parent[px, py] = c
    return c
end

"""
A sub-view in coordinates LOCAL to `v`. Inherits BOTH the shifted origin
and the clip; stays two-level by re-anchoring to `v.parent`.
"""
function Base.view(v::ScrolledView, r::Region)::ScrolledView
    f = Region(v.frame.x + r.x - 1, v.frame.y + r.y - 1,
               r.width, r.height)
    return ScrolledView(v.parent, f, intersect(f, v.clip))
end

"""
The cells of `b` a write can actually reach, in `b`'s OWN LOCAL
coordinates.

`buffer_region(b)` for a `Buffer` and for every `BufferView` -- both are
TIGHT, their frame IS their clip -- so every writer below behaves
IDENTICALLY on every grid that existed before scrolling. That identity
is not a coincidence to be tested; it is why `fill_region!`, `blit!` and
`set_cell!` can be changed at all. Pure.
"""
writable_region(b::AbstractMatrix{Cell})::Region = buffer_region(b)

"""
The clip of `v`, in `v`'s local coordinates. Pure.
"""
writable_region(v::ScrolledView)::Region =
    Region(v.clip.x - v.frame.x + 1, v.clip.y - v.frame.y + 1,
           v.clip.width, v.clip.height)

"""
True when BOTH cells of a width-2 cluster at local `x` land inside the
grid's writable window.

`set_cell!` has already checked `x` against the FRAME; this checks the
CLIP, which a scroll offset moves independently. For a `Buffer` or a
`BufferView` it reduces to `x >= 1 && x + 1 <= width` -- checks
`set_cell!` has already made -- so it can never change their behaviour.

Evaluated ONLY when `wide`, and `wide` is already in a register from the
line above: a width-1 write pays nothing. Pure. Internal.
"""
function _pair_fits(b::AbstractMatrix{Cell}, x::Int)::Bool
    wr = writable_region(b)
    return x >= wr.x && x + 1 <= right(wr)
end

"""
Fill every cell with `c`.

Narrowed to the two grid types on purpose: the contract's
`fill!(::AbstractMatrix{Cell}, ::Cell)` is AMBIGUOUS with Base's
`fill!(::Array{T}, ::Any)` for a `Matrix{Cell}` -- neither is more
specific -- so it cannot dispatch at all. Base already fills a
`Matrix{Cell}` correctly, so every `AbstractMatrix{Cell}` the caller
can hold is still covered.
"""
function Base.fill!(b::Union{Buffer,BufferView,ScrolledView}, c::Cell)
    w, h = size(b)
    for y in 1:h, x in 1:w
        b[x, y] = c
    end
    return b
end

"""
An independent copy of `b`.
"""
Base.copy(b::Buffer)::Buffer = Buffer(copy(b.cells))

"""
Fill every cell with `CELL_BLANK`.
"""
clear!(b::AbstractMatrix{Cell})::Nothing =
    (fill!(b, CELL_BLANK); nothing)

"""
A NEW buffer of size `s`. Content is undefined, which is why the caller
forces a full repaint.
"""
resize_buffer(b::Buffer, s::Size)::Buffer = Buffer(s)

"""
S3. Break the wide grapheme straddling `(x, y)`, blanking the half a
write landing there would orphan.

Overwriting a width-2 HEAD orphans its `CELL_CONT` at `x + 1`;
overwriting a `CELL_CONT` orphans its head at `x - 1`. Either way the
survivor is blanked, because half a glyph corrupts every column to its
right. In-bounds cells only; never throws.
"""
function _break_wide!(b::AbstractMatrix{Cell}, x::Int, y::Int)::Nothing
    w, h = size(b)
    (1 <= x <= w && 1 <= y <= h) || return nothing
    cur = b[x, y]
    if cur.width == Int8(2)
        if x + 1 <= w && is_continuation(b[x+1, y])
            b[x+1, y] = CELL_BLANK
        end
    elseif is_continuation(cur)
        if x - 1 >= 1 && b[x-1, y].width == Int8(2)
            b[x-1, y] = CELL_BLANK
        end
    end
    return nothing
end

"""
S3. Write one grapheme cluster; returns the cells advanced (0, 1 or 2).

A width-2 cluster writes the cell plus `CELL_CONT` at `x + 1`, and is
REFUSED (no-op, returns 0) if it would straddle the right edge -- half
a glyph is worse than a gap.

CONTINUATION INVARIANT, enforced here and tested everywhere:
overwriting a width-2 cell's HEAD clears its `CELL_CONT` to
`CELL_BLANK`; overwriting a `CELL_CONT` clears its head to
`CELL_BLANK`. Without this, S3 corrupts the grid on partial redraw.

Bounds-clipped: never throws on overflow.
"""
set_cell!(b::AbstractMatrix{Cell}, x::Int, y::Int,
          g::AbstractString, s::Style)::Int =
    set_cell!(b, x, y, Cell(g, s))

"""
S3. Write one prebuilt cell; returns the cells advanced (0, 1 or 2).
Same continuation invariant and clipping as the grapheme form.

The CLIP guard sits here rather than in `setindex!` for two reasons.
Scrolling is the first thing in this package that can cut a wide
grapheme's HEAD off, and the pre-existing `x + 1 > w` guard protects the
RIGHT edge only, and only because `size` USED TO BE the clip; and a
guard inside `setindex!` would run on every cell, while this one runs
once per grapheme and only when `wide`.
"""
function set_cell!(b::AbstractMatrix{Cell}, x::Int, y::Int,
                   c::Cell)::Int
    w, h = size(b)
    (1 <= x <= w && 1 <= y <= h) || return 0
    wide = c.width == Int8(2)
    wide && x + 1 > w && return 0           # refused, not halved
    wide && !_pair_fits(b, x) && return 0   # refused at the CLIP edge
    _break_wide!(b, x, y)
    wide && _break_wide!(b, x + 1, y)
    b[x, y] = c
    wide && (b[x+1, y] = CELL_CONT)
    return Int(c.width)
end

"""
S3. Segment `s` into graphemes and write them left to right, stopping
at the right edge. Returns the total width advanced. Bounds-clipped.
"""
function write_text!(b::AbstractMatrix{Cell}, x::Int, y::Int,
                     s::AbstractString, st::Style = STYLE_NONE)::Int
    w, h = size(b)
    (1 <= y <= h) || return 0
    cx = x
    total = 0
    for g in graphemes(s)
        cx > w && break
        gw = grapheme_width(g)
        gw == 2 && cx + 1 > w && break   # would straddle the edge
        cx >= 1 && set_cell!(b, cx, y, Cell(g, st))
        cx += gw
        total += gw
    end
    return total
end

"""
Fill `r` with `c`, clipped to `b`'s WRITABLE window.

`writable_region`, not `buffer_region`: the two are identical for a
`Buffer` and for every `BufferView`, and differ only for a
`ScrolledView`, whose edge columns are the ones the CLIP cuts rather
than the ones the frame ends at.
"""
function fill_region!(b::AbstractMatrix{Cell}, r::Region,
                      c::Cell = CELL_BLANK)::Nothing
    rr = intersect(r, writable_region(b))
    isempty(rr) && return nothing
    x0, x1 = rr.x, right(rr)
    for y in rr.y:bottom(rr)
        # Only the two edge columns can straddle the boundary: every
        # wide glyph strictly inside `rr` is overwritten whole.
        _break_wide!(b, x0, y)
        _break_wide!(b, x1, y)
        for x in x0:x1
            b[x, y] = c
        end
    end
    return nothing
end

"""
Merge `s` onto the style of each existing cell in `r`, keeping the
content. Clipped to `b`.
"""
function style_region!(b::AbstractMatrix{Cell}, r::Region,
                       s::Style)::Nothing
    rr = intersect(r, buffer_region(b))
    isempty(rr) && return nothing
    for y in rr.y:bottom(rr), x in rr.x:right(rr)
        cur = b[x, y]
        b[x, y] = Cell(cur.content, merge(cur.style, s), cur.width)
    end
    return nothing
end

"""
Copy `src` into `dst` with its top-left at `at`, a 1-based ABSOLUTE
position. Clipped to `dst`'s WRITABLE window; a wide glyph whose other
half falls outside the clip is blanked rather than halved.
"""
function blit!(dst::AbstractMatrix{Cell}, src::Buffer,
               at::Offset)::Nothing
    sw, sh = size(src)
    dr = intersect(Region(at.x, at.y, sw, sh), writable_region(dst))
    isempty(dr) && return nothing
    x0, x1 = dr.x, right(dr)
    for y in dr.y:bottom(dr)
        _break_wide!(dst, x0, y)
        _break_wide!(dst, x1, y)
        sy = y - at.y + 1
        for x in x0:x1
            c = src[x - at.x + 1, sy]
            if c.width == Int8(2) && x == x1
                c = CELL_BLANK           # continuation clipped away
            elseif is_continuation(c) && x == x0
                c = CELL_BLANK           # head clipped away
            end
            dst[x, y] = c
        end
    end
    return nothing
end

"""
Plain-text dump: one line per row, continuations skipped, no ANSI.
Makes every widget test a one-line string comparison. Pure.
"""
function Base.string(b::Buffer)::String
    w, h = size(b)
    io = IOBuffer()
    for y in 1:h
        for x in 1:w
            c = b.cells[x, y]
            is_continuation(c) && continue
            print(io, String(c.content))
        end
        y < h && print(io, '\n')
    end
    return String(take!(io))
end

"""
Print `b` as an ASCII picture, so a failing assertion prints a screen
rather than a struct dump.
"""
function Base.show(io::IO, ::MIME"text/plain", b::Buffer)::Nothing
    w, h = size(b)
    println(io, "Buffer ", w, "x", h, ":")
    println(io, string(b))
    return nothing
end
