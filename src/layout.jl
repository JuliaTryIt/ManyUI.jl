# layout.jl -- layer 5. May reference: widget, boxmodel, geometry,
# unicode. U2 (box model), E1 (minimal relayout), E4 (full relayout).

"""
The pure layout pass's output: a node to its four resolved boxes.
"""
const LayoutMap = IdDict{Widget,LayoutBox}

"""
Intrinsic content size of `w` given the available space.

Override for leaf widgets -- a `Label` returns its wrapped text extent
via `text_width`. The default is the union of the children's OUTER
(margin-box) measures laid out along `display`/`direction`, with `gap`
between them; a widget with no laid-out child therefore measures
`Size(0, 0)`. Drives `Dimension.AUTO`.

`avail` is the CONTENT size of the parent, and it is what `PERCENT`
child lengths resolve against.

Pure with respect to the tree: no dirty marks, no field writes.
"""
function measure(w::Widget, avail::Size)::Size
    kids = children(w)
    isempty(kids) && return Size(0, 0)
    bs = box(w)
    horiz = _is_row(_main_direction(bs))
    main = 0
    cross = 0
    seen = 0
    for c in kids
        _laid_out(c) || continue
        seen += 1
        s = _measure_outer(c, avail)
        if horiz
            main += s.width
            cross = max(cross, s.height)
        else
            main += s.height
            cross = max(cross, s.width)
        end
    end
    seen == 0 && return Size(0, 0)
    main += bs.gap * (seen - 1)
    return horiz ? Size(main, cross) : Size(cross, main)
end

"""
THE heart of flex. Pure. Distributes `available` over the `base` sizes
using the grow/shrink factors.

When `sum(base) < available` the slack is shared out by `grow` weight.
When `sum(base) > available` the excess is taken back by CSS SCALED
shrink weight (`shrink[i] * base[i]`); an item whose share exceeds its
own size freezes at zero rather than going negative, and the residue is
re-offered to the items still able to shrink. When no item can absorb
the slack at all the `base` sizes are returned unchanged -- an
overflowing layout is clipped at paint time, never mangled here.

NORMATIVE: fractional leftovers resolve LARGEST-REMAINDER-FIRST, so
`sum(result) == available` EXACTLY whenever any item can absorb the
slack. Integer cells: no one-cell drift, ever. Ties in the remainder go
to the LOWER index.
"""
function flex_distribute(base::Vector{Int}, grow::Vector{Float32},
                         shrink::Vector{Float32},
                         available::Int)::Vector{Int}
    n = length(base)
    n == 0 && return Int[]
    (length(grow) == n && length(shrink) == n) ||
        throw(ArgumentError("flex_distribute: length mismatch"))
    total = sum(base)
    total == available && return copy(base)
    if total < available
        add = _apportion(grow, available - total)
        out = Vector{Int}(undef, n)
        for i in 1:n
            out[i] = base[i] + add[i]
        end
        return out
    end
    out = copy(base)
    frozen = falses(n)
    excess = total - available
    w = Vector{Float64}(undef, n)
    while excess > 0
        movable = false
        for i in 1:n
            w[i] = frozen[i] ? 0.0 :
                   max(0.0, Float64(shrink[i])) * max(0, base[i])
            w[i] > 0.0 && (movable = true)
        end
        movable || break
        cut = _apportion(w, excess)
        capped = false
        for i in 1:n
            if !frozen[i] && cut[i] > out[i]
                excess -= out[i]
                out[i] = 0
                frozen[i] = true
                capped = true
            end
        end
        capped && continue
        for i in 1:n
            out[i] -= cut[i]
        end
        excess = 0
    end
    return out
end

"""
Main-axis start offsets, 0-based within the container's content box,
for each item, given the item sizes, `gap` and total `available`. Pure.

The free space is `available - sum(sizes) - gap * (n - 1)`, CLAMPED AT
ZERO: when the items overflow, every mode degenerates to `START`
rather than placing an item at a negative offset. Free space is shared
out largest-remainder-first, so the trailing edge never drifts a cell.
"""
function justify_offsets(sizes::Vector{Int}, justify::Justify.T,
                         gap::Int, available::Int)::Vector{Int}
    n = length(sizes)
    n == 0 && return Int[]
    free = max(0, available - sum(sizes) - gap * (n - 1))
    lead = 0
    extra = zeros(Int, max(0, n - 1))
    if justify === Justify.CENTER
        lead = div(free, 2)
    elseif justify === Justify.END
        lead = free
    elseif justify === Justify.SPACE_BETWEEN
        n > 1 && (extra = _split_even(free, n - 1))
    elseif justify === Justify.SPACE_AROUND
        h = _split_even(free, 2 * n)
        lead = h[1]
        for i in 1:(n - 1)
            extra[i] = h[2 * i] + h[2 * i + 1]
        end
    elseif justify === Justify.SPACE_EVENLY
        s = _split_even(free, n + 1)
        lead = s[1]
        for i in 1:(n - 1)
            extra[i] = s[i + 1]
        end
    end
    out = Vector{Int}(undef, n)
    cur = lead
    for i in 1:n
        out[i] = cur
        cur += sizes[i] + gap
        i < n && (cur += extra[i])
    end
    return out
end

"""
Cross-axis `(offset, size)` for one item. `Align.STRETCH` returns
`(0, available)`. An item larger than `available` is given offset zero
under every mode rather than a negative offset. Pure.
"""
function cross_align(size::Int, align::Align.T,
                     available::Int)::Tuple{Int,Int}
    align === Align.STRETCH && return (0, available)
    free = max(0, available - size)
    align === Align.CENTER && return (div(free, 2), size)
    align === Align.END && return (free, size)
    return (0, size)
end

"""
U2 + E4. PURE: tree plus viewport to boxes. Mutates NOTHING, and does
not touch `WidgetNode.layout`. This is what makes the layout engine
testable without an App, a Buffer, or a terminal.

`viewport` is `root`'s MARGIN box, so `root`'s own `width`/`height` are
not consulted: the root fills what it is given. Every other node's
margin box is derived from its parent's CONTENT box, and
`layout_box(bs, margin_box)` derives all four regions -- no file may
re-derive them.

Two passes per container:

  1. MEASURE (bottom-up): resolve CELLS/PERCENT against the parent
     content box; AUTO calls `measure(child, avail)`. Every `Length`
     sizes the CONTENT box, and `box_overhead` is added on top of it to
     reach the margin box that the flex kernel distributes over.
  2. DISTRIBUTE (top-down): FRACTION items claim free space pro-rata by
     `fr` weight AFTER 1 and BEFORE grow; `flex_distribute` applies
     grow/shrink to the residual, clamped by `min_*`/`max_*`;
     `justify_offsets` places along the main axis; `cross_align`
     places and stretches along the cross axis.

`Display.BLOCK` is FLEX with direction COLUMN, align STRETCH and the
children's `grow` forced to zero -- ONE code path, no special case.
`Display.NONE` and invisible subtrees are ABSENT from the returned map
and claim no main-axis space.

Overflow is NOT clipped here: the map reports true geometry under every
`Overflow` policy, and `paint.jl` clips through a `BufferView`.
"""
function compute_layout(root::Widget, viewport::Region)::LayoutMap
    lm = LayoutMap()
    _laid_out(root) && _place!(lm, root, viewport)
    return lm
end

"""
The impure shell: write `lm` into each `WidgetNode.layout`, clear
`Dirty.LAYOUT` and `Dirty.SUBTREE` on every written node, and set
`Dirty.PAINT` on any node whose `LayoutBox` actually CHANGED.

Nodes absent from `lm` are left untouched, breadcrumbs included: an
ancestor's `SUBTREE` may still be carrying a `PAINT`-dirty descendant.
"""
function apply_layout!(lm::LayoutMap)::Nothing
    for (w, lb) in lm
        n = node(w)
        moved = n.layout !== lb
        n.layout = lb
        m = clear_dirty(clear_dirty(n.dirty, Dirty.LAYOUT),
                        Dirty.SUBTREE)
        moved && (m = set_dirty(m, Dirty.PAINT))
        n.dirty = m
    end
    return nothing
end

"""
U2 + E4. An unconditional FULL pass over the whole tree; assigns
`layout` on every visible node.

This is what a `ResizeEvent` calls -- "instantly recalculate the
bounding boxes of the ENTIRE layout tree". Never consults dirty flags.
"""
function layout!(root::Widget, viewport::Region)::Nothing
    apply_layout!(compute_layout(root, viewport))
    return nothing
end

"""
E1 + U2. INCREMENTAL: recomputes from `dirty_root(root)` down ONLY.

  * `dirty_root(root) === nothing` -- no-op, returns immediately.
  * `dirty_root(root) === root` -- falls back to `layout!`.
  * otherwise -- `compute_layout` on the dirty subtree, anchored at the
    subtree root's EXISTING `margin_box`, then `apply_layout!`.

Two functions, not one with a `force::Bool` keyword: E4 mandates a full
recompute on resize, E1 mandates a minimal one on state change. Two
requirements, two functions, two test suites.
"""
function relayout!(root::Widget, viewport::Region)::Nothing
    dr = dirty_root(root)
    dr === nothing && return nothing
    dr === root && return layout!(root, viewport)
    apply_layout!(compute_layout(dr, node(dr).layout.margin_box))
    return nothing
end

# --- internals --------------------------------------------------------

"""
True when `w` takes part in layout at all. Pure.
"""
_laid_out(w::Widget)::Bool =
    is_visible(w) && box(w).display !== Display.NONE

"""
The direction a container actually arranges its children along:
`Display.BLOCK` is COLUMN whatever `direction` says. Pure.
"""
_main_direction(bs::BoxStyle)::Direction.T =
    bs.display === Display.BLOCK ? Direction.COLUMN : bs.direction

"""
True when the main axis of `d` is horizontal. Pure.
"""
_is_row(d::Direction.T)::Bool =
    d === Direction.ROW || d === Direction.ROW_REVERSE

"""
True when `d` runs the main axis backwards. Pure.
"""
_is_reverse(d::Direction.T)::Bool =
    d === Direction.ROW_REVERSE || d === Direction.COLUMN_REVERSE

"""
The `Length` sizing the main axis of `bs`. Pure.
"""
_main_length(bs::BoxStyle, horiz::Bool)::Length =
    horiz ? bs.width : bs.height

"""
The `Length` sizing the cross axis of `bs`. Pure.
"""
_cross_length(bs::BoxStyle, horiz::Bool)::Length =
    horiz ? bs.height : bs.width

"""
Main-axis extent of `s`. Pure.
"""
_main_of(s::Size, horiz::Bool)::Int = horiz ? s.width : s.height

"""
Cross-axis extent of `s`. Pure.
"""
_cross_of(s::Size, horiz::Bool)::Int = horiz ? s.height : s.width

"""
Main-axis component of a `Spacing`. Pure.
"""
_main_inset(sp::Spacing, horiz::Bool)::Int =
    horiz ? horizontal(sp) : vertical(sp)

"""
Cross-axis component of a `Spacing`. Pure.
"""
_cross_inset(sp::Spacing, horiz::Bool)::Int =
    horiz ? vertical(sp) : horizontal(sp)

"""
Resolve one axis of `w` to a CONTENT extent against the parent content
box `avail`. FRACTION contributes nothing here -- it claims free space
later. Pure.
"""
function _content_extent(w::Widget, len::Length, horiz::Bool,
                         main::Bool, avail::Size)::Int
    ref = main ? _main_of(avail, horiz) : _cross_of(avail, horiz)
    is_definite(len) && return max(0, definite_size(len, ref))
    len.kind === Dimension.FRACTION && return 0
    m = measure(w, avail)
    return max(0, main ? _main_of(m, horiz) : _cross_of(m, horiz))
end

"""
The margin-box size `w` wants, given the parent content box `avail`.
Used by the default `measure`. Pure.
"""
function _measure_outer(w::Widget, avail::Size)::Size
    bs = box(w)
    cw = _content_extent(w, bs.width, true, true, avail)
    ch = _content_extent(w, bs.height, true, false, avail)
    return outer_size(bs, Size(cw, ch))
end

"""
Resolve a `min_*`/`max_*` bound to an OUTER extent. An AUTO bound means
"unbounded": `0` for a lower bound, `typemax(Int)` for an upper one.
Pure.
"""
function _bound_outer(len::Length, over::Int, ref::Int,
                      lower::Bool)::Int
    is_definite(len) || return lower ? 0 : typemax(Int)
    return over + max(0, definite_size(len, ref))
end

"""
Record the four boxes of `w` in `lm`, then arrange its children. Pure
with respect to the tree: `lm` is the only thing written.
"""
function _place!(lm::LayoutMap, w::Widget, margin_box::Region)::Nothing
    bs = box(w)
    lb = layout_box(bs, margin_box)
    lm[w] = lb
    _arrange!(lm, w, bs, lb.content)
    return nothing
end

"""
Size and place every laid-out child of `w` inside `content`, then
recurse. Pure with respect to the tree. Pure.
"""
function _arrange!(lm::LayoutMap, w::Widget, bs::BoxStyle,
                   content::Region)::Nothing
    kids = Widget[c for c in children(w) if _laid_out(c)]
    n = length(kids)
    n == 0 && return nothing
    dir = _main_direction(bs)
    block = bs.display === Display.BLOCK
    horiz = _is_row(dir)
    just = block ? Justify.START : bs.justify
    al = block ? Align.STRETCH : bs.align
    avail = size_of(content)
    main_avail = _main_of(avail, horiz)
    cross_avail = _cross_of(avail, horiz)
    inner_main = max(0, main_avail - bs.gap * (n - 1))

    boxes = BoxStyle[box(c) for c in kids]
    over = Spacing[box_overhead(b) for b in boxes]
    base = Vector{Int}(undef, n)
    frs = Vector{Float32}(undef, n)
    lo = Vector{Int}(undef, n)
    hi = Vector{Int}(undef, n)
    grows = Vector{Float32}(undef, n)
    shrinks = Vector{Float32}(undef, n)
    for i in 1:n
        cb = boxes[i]
        mo = _main_inset(over[i], horiz)
        len = _main_length(cb, horiz)
        frs[i] = len.kind === Dimension.FRACTION ?
                 max(0f0, len.value) : 0f0
        base[i] = mo + _content_extent(kids[i], len, horiz, true, avail)
        lo[i] = _bound_outer(horiz ? cb.min_width : cb.min_height,
                             mo, main_avail, true)
        hi[i] = _bound_outer(horiz ? cb.max_width : cb.max_height,
                             mo, main_avail, false)
        grows[i] = block ? 0f0 : max(0f0, cb.grow)
        shrinks[i] = max(0f0, cb.shrink)
    end

    # 3. FRACTION items claim the free space: after CELLS/PERCENT/AUTO,
    #    before grow. Their overhead is already in `base`, so the share
    #    lands on their content box.
    if sum(frs) > 0f0
        share = _apportion(frs, max(0, inner_main - sum(base)))
        for i in 1:n
            base[i] += share[i]
        end
    end
    for i in 1:n
        base[i] = clamp(base[i], lo[i], hi[i])
    end

    # 4. grow/shrink over the residual, then re-clamp. A size pinned by
    #    min/max hands its residue to `justify_offsets` rather than to a
    #    second distribution round.
    sizes = flex_distribute(base, grows, shrinks, inner_main)
    for i in 1:n
        sizes[i] = max(0, clamp(sizes[i], lo[i], hi[i]))
    end

    # 5. place along main, then along cross.
    offs = justify_offsets(sizes, just, bs.gap, main_avail)
    if _is_reverse(dir)
        for i in 1:n
            offs[i] = main_avail - offs[i] - sizes[i]
        end
    end
    for i in 1:n
        cb = boxes[i]
        co = _cross_inset(over[i], horiz)
        clen = _cross_length(cb, horiz)
        clo = _bound_outer(horiz ? cb.min_height : cb.min_width,
                           co, cross_avail, true)
        chi = _bound_outer(horiz ? cb.max_height : cb.max_width,
                           co, cross_avail, false)
        local coff::Int, csz::Int
        if !is_definite(clen) && al === Align.STRETCH
            coff, csz = cross_align(0, Align.STRETCH, cross_avail)
            pinned = clamp(csz, clo, chi)
            if pinned != csz
                coff, csz = cross_align(pinned, Align.START,
                                        cross_avail)
            end
        else
            want = co + _content_extent(kids[i], clen, horiz, false,
                                        avail)
            eff = al === Align.STRETCH ? Align.START : al
            coff, csz = cross_align(clamp(want, clo, chi), eff,
                                    cross_avail)
        end
        csz = max(0, csz)
        mb = horiz ?
             Region(content.x + offs[i], content.y + coff,
                    sizes[i], csz) :
             Region(content.x + coff, content.y + offs[i],
                    csz, sizes[i])
        _place!(lm, kids[i], mb)
    end
    return nothing
end

"""
Share `total` cells out over `weights`, largest-remainder-first with
ties going to the LOWER index, so `sum(result) == total` exactly
whenever `sum(weights) > 0`. Pure.
"""
function _apportion(weights::AbstractVector{<:Real},
                    total::Int)::Vector{Int}
    n = length(weights)
    out = zeros(Int, n)
    (n == 0 || total <= 0) && return out
    wsum = 0.0
    for x in weights
        wsum += max(0.0, Float64(x))
    end
    wsum <= 0.0 && return out
    rest = Vector{Float64}(undef, n)
    acc = 0
    for i in 1:n
        exact = total * max(0.0, Float64(weights[i])) / wsum
        whole = floor(exact)
        out[i] = Int(whole)
        rest[i] = exact - whole
        acc += out[i]
    end
    left = total - acc
    if left > 0
        order = collect(1:n)
        sort!(order; by = i -> (-rest[i], i))
        for k in 1:min(left, n)
            out[order[k]] += 1
        end
    end
    return out
end

"""
Split `total` cells into `k` as-equal-as-possible parts, the remainder
going to the lowest indices. Pure.
"""
_split_even(total::Int, k::Int)::Vector{Int} =
    _apportion(ones(Float32, max(0, k)), total)
