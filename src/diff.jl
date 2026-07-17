# diff.jl -- layer 3. May reference: buffer, geometry, style.
# E2: the minimal change set between two frames.

"""
A horizontal run of cells to repaint, starting at the 1-based cell
`(x, y)`.
"""
struct Span
    "Start column, 1-based."
    x::Int
    "Row, 1-based."
    y::Int
    "Cells to write, left to right from `(x, y)`."
    cells::Vector{Cell}
end

"""
The minimal change set between two frames.
"""
struct Patch
    "Runs to repaint, in row-major order."
    spans::Vector{Span}
    "Size of the frame the spans index into."
    size::Size
    "When true the encoder must clear the screen and reset SGR first."
    full::Bool
end

"""
True when the patch repaints nothing. Pure.

Note this asks only whether any cells are repainted -- a `full` patch
with no spans is still `isempty`, because `full` is an instruction to
the encoder (clear + SGR reset), not a change set.
"""
Base.isempty(p::Patch)::Bool = isempty(p.spans)

"""
Number of spans. Pure.
"""
Base.length(p::Patch)::Int = length(p.spans)

"""
Total cells across all spans. Pure.
"""
n_cells(p::Patch)::Int = sum(s -> length(s.cells), p.spans; init = 0)

"""
Structural equality. Pure.
"""
Base.:(==)(a::Span, b::Span)::Bool =
    a.x == b.x && a.y == b.y && a.cells == b.cells

"""
Structural equality. Pure.
"""
Base.:(==)(a::Patch, b::Patch)::Bool =
    a.full == b.full && a.size == b.size && a.spans == b.spans

"""
E2. The minimal diff. PURE: mutates NEITHER argument.

Rows are scanned stride-1. Runs of changed cells coalesce into `Span`s;
two runs separated by `<= gap` unchanged cells MERGE, because a CUP
costs about six bytes and a re-emitted cell costs about one. The
default of 4 is the measured break-even.

S3: a changed cell that is a `CELL_CONT` pulls its width-2 head into
the span (walk left to the head first), and a changed width-2 head
pulls its `CELL_CONT` in. A `Span` therefore NEVER begins or ends
mid-grapheme, so the escape stream can never place the cursor inside a
wide glyph.

`size(old) != size(new)` yields `Patch(spans covering all of new,
size(new), true)`.

MUST NOT touch a `Driver`, an `App`, a `Widget`, or any global.
"""
function diff(old::Buffer, new::Buffer; gap::Int = 4)::Patch
    gap >= 0 || throw(ArgumentError("diff: gap must be >= 0, got $gap"))
    size(old) == size(new) && return _diff_same_size(old, new, gap)
    # A reflowed grid shares no coordinates with the old one; there is
    # nothing to compare against, so every cell is news to the terminal.
    return full_patch(new)
end

# Split out so the size-mismatch branch above stays a one-liner and this
# body can assume `size(old) == size(new)`.
function _diff_same_size(old::Buffer, new::Buffer, gap::Int)::Patch
    w, h = size(new)
    spans = Span[]
    (w == 0 || h == 0) && return Patch(spans, buffer_size(new), false)
    changed = falses(w)
    for y in 1:h
        fill!(changed, false)
        dirty = false
        @inbounds for x in 1:w
            if old[x, y] != new[x, y]
                changed[x] = true
                dirty = true
            end
        end
        dirty || continue
        _widen_graphemes!(changed, new, y, w)
        _emit_row_spans!(spans, changed, new, y, w, gap)
    end
    return Patch(spans, buffer_size(new), false)
end

# S3. Grow the changed set so no run can begin on a continuation or end
# on a width-2 head: a changed CELL_CONT pulls in the head to its left,
# a changed head pulls in its CELL_CONT. One forward pass suffices --
# a wide grapheme is exactly two cells, so nothing cascades further.
function _widen_graphemes!(changed::BitVector, new::Buffer, y::Int,
                           w::Int)::Nothing
    @inbounds for x in 1:w
        changed[x] || continue
        c = new[x, y]
        if c.width == Int8(0)
            x > 1 && (changed[x - 1] = true)
        elseif c.width == Int8(2)
            x < w && (changed[x + 1] = true)
        end
    end
    return nothing
end

# Coalesce the changed cells of row `y` into spans. Two runs separated
# by at most `gap` unchanged cells merge: a CUP costs ~6 bytes and a
# re-emitted cell ~1, so bridging a short gap is cheaper than jumping.
function _emit_row_spans!(spans::Vector{Span}, changed::BitVector,
                          new::Buffer, y::Int, w::Int, gap::Int)::Nothing
    x = 1
    @inbounds while x <= w
        if !changed[x]
            x += 1
            continue
        end
        s = x
        e = x
        j = x + 1
        while j <= w
            if changed[j]
                e = j
                j += 1
                continue
            end
            k = j
            while k <= w && !changed[k]
                k += 1
            end
            # `k` is the next changed cell, or w+1 if the row ends here.
            # A trailing unchanged stretch is never bridged.
            if k <= w && (k - j) <= gap
                e = k
                j = k + 1
            else
                break
            end
        end
        push!(spans, Span(s, y, Cell[new[i, y] for i in s:e]))
        x = e + 1
    end
    return nothing
end

"""
Every row of `b` as one span, with `full = true`. Pure.
"""
function full_patch(b::Buffer)::Patch
    w, h = size(b)
    spans = Span[]
    (w == 0 || h == 0) && return Patch(spans, buffer_size(b), true)
    sizehint!(spans, h)
    for y in 1:h
        push!(spans, Span(1, y, Cell[b[x, y] for x in 1:w]))
    end
    return Patch(spans, buffer_size(b), true)
end

"""
Apply `p` to `b` IN PLACE, returning `b`.

Exists so the round-trip law is expressible -- the strongest available
test of `diff`:

    apply!(copy(a), diff(a, b)) == b

Ships in `src` (not `test`) so DualUIWeb can use it too.
"""
function apply!(b::Buffer, p::Patch)::Buffer
    w, h = size(b)
    for s in p.spans
        (1 <= s.y <= h) || continue
        @inbounds for (i, c) in enumerate(s.cells)
            x = s.x + i - 1
            (1 <= x <= w) || continue
            # A RAW write, deliberately not `set_cell!`: the span is
            # already grapheme-aligned by `diff`, and set_cell!'s
            # continuation repair would clobber the neighbouring cell
            # the very next span is about to restore -- which would
            # break the round-trip law this function exists to express.
            b[x, s.y] = c
        end
    end
    return b
end
