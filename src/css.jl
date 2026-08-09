# css.jl -- layer 5. May reference: widget, boxmodel, style, color,
# geometry. U4: declarative styling mapped to ids and classes.

"""
The four simple selector kinds.
"""
module SelectorKind
@enum T::UInt8 begin
    UNIVERSAL = 0  # *
    TYPE = 1       # Button
    CLASS = 2      # .primary
    ID = 3         # #ok
    PSEUDO = 4     # :focus, :focus-within -- STATE, not structure
end
end

"""
How two compounds relate.
"""
module Combinator
@enum T::UInt8 begin
    DESCENDANT = 0  # A B
    CHILD = 1       # A > B
end
end

"""
One selector atom.
"""
struct SimpleSelector
    "Universal, type, class or id."
    kind::SelectorKind.T
    "The name matched; ignored for `UNIVERSAL`."
    name::Symbol
end

"""
Simple selectors ANDed against ONE node: `Button.primary#ok`.
"""
struct CompoundSelector
    "Atoms that must all match the same node."
    parts::Vector{SimpleSelector}
end

"""
A full selector, read left to right; the LAST compound is the subject.

INVARIANT: `length(combinators) == length(compounds) - 1`.
"""
struct Selector
    "Compounds, in source order."
    compounds::Vector{CompoundSelector}
    "Relations between adjacent compounds."
    combinators::Vector{Combinator.T}
end

"""
The CSS specificity triple, ordered lexicographically.
"""
struct Specificity
    "Number of id selectors."
    ids::Int
    "Number of class selectors."
    classes::Int
    "Number of type selectors."
    types::Int
end

"""
One parsed rule.
"""
struct Rule
    "What the rule matches."
    selector::Selector
    "Style properties it sets."
    style::Style
    "Box properties it sets."
    box::BoxPatch
    "Source order; breaks specificity ties."
    order::Int
end

"""
An ordered collection of rules. Immutable enough to be shared by every
web session.
"""
struct Stylesheet
    "Rules, in source order."
    rules::Vector{Rule}
end

const STYLESHEET_EMPTY = Stylesheet(Rule[])

"""
A stylesheet failed to parse, with the source position.
"""
struct CssParseError <: Exception
    "What went wrong."
    msg::String
    "1-based line."
    line::Int
    "1-based column."
    col::Int
end

"""
Report the message with its line and column.
"""
Base.showerror(io::IO, e::CssParseError) =
    print(io, "CssParseError: ", e.msg, " (line ", e.line,
          ", column ", e.col, ")")

"""
Specificity of a full selector: the sum over its compounds. Pure.
"""
function specificity(s::Selector)::Specificity
    ids = 0
    cls = 0
    tys = 0
    for c in s.compounds
        sp = specificity(c)
        ids += sp.ids
        cls += sp.classes
        tys += sp.types
    end
    return Specificity(ids, cls, tys)
end

"""
Specificity of one compound. Pure.
"""
function specificity(c::CompoundSelector)::Specificity
    ids = 0
    cls = 0
    tys = 0
    for p in c.parts
        k = p.kind
        if k === SelectorKind.PSEUDO
            # A pseudo-class ranks with a class, exactly as in CSS, so
            # `Container:focus` beats `Container` and loses to `#pane`.
            cls += 1
        elseif k === SelectorKind.ID
            ids += 1
        elseif k === SelectorKind.CLASS
            cls += 1
        elseif k === SelectorKind.TYPE
            tys += 1
        end
    end
    return Specificity(ids, cls, tys)
end

"""
Lexicographic order on `(ids, classes, types)`. Pure.
"""
Base.isless(a::Specificity, b::Specificity)::Bool =
    (a.ids, a.classes, a.types) < (b.ids, b.classes, b.types)

"""
True when the atom matches `w`. Pure.
"""
function matches(s::SimpleSelector, w::Widget)::Bool
    k = s.kind
    k === SelectorKind.UNIVERSAL && return true
    n = node(w)
    k === SelectorKind.TYPE && return n.type_name === s.name
    k === SelectorKind.CLASS && return s.name in n.classes
    if k === SelectorKind.PSEUDO
        # STATE, read off the node rather than computed. `focus_within`
        # is a stored flag and not a walk of the subtree: the cascade
        # asks this of every node against every rule, and answering it
        # by walking descendants would make a focus change cost the
        # square of the tree. `focus!` maintains the two flags along
        # ONE chain instead -- see dispatch.jl.
        s.name === :focus && return n.focused
        s.name === Symbol("focus-within") && return n.focused ||
                                              n.focus_within
        return false
    end
    return n.id === s.name
end

"""
True when every atom matches `w`. Pure.
"""
function matches(c::CompoundSelector, w::Widget)::Bool
    for p in c.parts
        matches(p, w) || return false
    end
    return true
end

"""
True when `w` is the subject of `s`. Matched right-to-left, walking
ancestors. Pure.
"""
function matches(s::Selector, w::Widget)::Bool
    isempty(s.compounds) && return false
    return _match_from(s, length(s.compounds), w)
end

"""
Match compound `i` of `s` against `w`, then everything to its left
against `w`'s ancestors. A `DESCENDANT` combinator backtracks over
every ancestor; a `CHILD` combinator considers only the parent. Pure.
"""
function _match_from(s::Selector, i::Int, w::Widget)::Bool
    matches(s.compounds[i], w) || return false
    i == 1 && return true
    p = node(w).parent
    if s.combinators[i-1] === Combinator.CHILD
        p === nothing && return false
        return _match_from(s, i - 1, p)
    end
    while p !== nothing
        _match_from(s, i - 1, p) && return true
        p = node(p).parent
    end
    return false
end

"""
An empty stylesheet.
"""
Stylesheet()::Stylesheet = Stylesheet(Rule[])

"""
Append a rule. Returns `ss`.
"""
Base.push!(ss::Stylesheet, r::Rule)::Stylesheet = (push!(ss.rules, r); ss)

"""
Append several rules. Returns `ss`.
"""
Base.append!(ss::Stylesheet, rs)::Stylesheet = (append!(ss.rules, rs); ss)

"""
Concatenate two stylesheets: `b`'s rules come later, with their `order`
shifted past `a`'s. Pure.
"""
function Base.merge(a::Stylesheet, b::Stylesheet)::Stylesheet
    off = 0
    for r in a.rules
        off = max(off, r.order)
    end
    na = length(a.rules)
    rules = Vector{Rule}(undef, na + length(b.rules))
    copyto!(rules, 1, a.rules, 1, na)
    for (k, r) in pairs(b.rules)
        rules[na+k] = Rule(r.selector, r.style, r.box, r.order + off)
    end
    return Stylesheet(rules)
end

"""
True when the sheet has no rules. Pure.
"""
Base.isempty(ss::Stylesheet)::Bool = isempty(ss.rules)

"""
The cascade sort key of a rule: `(specificity, order)`. Pure.
"""
_rule_key(r::Rule)::Tuple{Specificity,Int} =
    (specificity(r.selector), r.order)

"""
Rules matching `w`, sorted ASCENDING by `(specificity, order)` -- apply
them in the returned order. Pure.
"""
function matching_rules(ss::Stylesheet, w::Widget)::Vector{Rule}
    out = Rule[]
    for r in ss.rules
        matches(r.selector, w) && push!(out, r)
    end
    sort!(out; by = _rule_key)
    return out
end

"""
U4. PURE: resolve `w`'s computed style and box. Testable with a stub
widget -- no App, no tree walk.

NORMATIVE per-node cascade order:

  1. `style = inheritable(parent_style)`; `box = BOX_DEFAULT`
  2. fold `matching_rules(ss, w)` ascending by `(specificity, order)`:
     `style = merge(style, rule.style)`; `box = apply(box, rule.box)`
  3. `style = merge(style, node(w).inline_style)` and
     `box = apply(box, node(w).inline_box)` -- inline ALWAYS wins.
"""
function cascade(ss::Stylesheet, w::Widget,
                 parent_style::Style = STYLE_NONE)::Tuple{Style,BoxStyle}
    style = inheritable(parent_style)
    bx = BOX_DEFAULT
    for r in matching_rules(ss, w)
        style = merge(style, r.style)
        bx = apply(bx, r.box)
    end
    n = node(w)
    style = merge(style, n.inline_style)
    bx = apply(bx, n.inline_box)
    return (style, bx)
end

"""
Cascade `w` against `ss` under `parent_style`, write the result into
its node, clear `Dirty.STYLE`, dirty it only if something actually
changed, then recurse into its children so inheritance flows down.
"""
function _cascade_into!(ss::Stylesheet, w::Widget,
                        parent_style::Style)::Nothing
    n = node(w)
    (st, bx) = cascade(ss, w, parent_style)
    box_changed = bx !== n.box
    style_changed = st !== n.computed_style
    n.computed_style = st
    n.box = bx
    n.dirty = clear_dirty(n.dirty, Dirty.STYLE)
    if box_changed
        mark!(w, Dirty.LAYOUT)
    elseif style_changed
        mark!(w, Dirty.PAINT)
    end
    for c in n.children
        _cascade_into!(ss, c, st)
    end
    return nothing
end

"""
U4. The impure shell. Walks TOP-DOWN -- parents before children, so
inheritance flows -- writes the results into each node and clears
`Dirty.STYLE`.

Marks `Dirty.LAYOUT` where `box` actually CHANGED, and `Dirty.PAINT`
where only `computed_style` changed. Compare-before-dirty is required:
an unchanged cascade must cost zero frames.
"""
function apply_stylesheet!(ss::Stylesheet, root::Widget)::Nothing
    _cascade_into!(ss, root, STYLE_NONE)
    return nothing
end

"""
Recascade the STYLE-dirty part of `w`'s subtree, descending `SUBTREE`
breadcrumbs. The breadcrumbs are left in place: `relayout!` reads the
same trail later in the same frame.
"""
function _recascade_node!(ss::Stylesheet, w::Widget,
                          parent_style::Style)::Nothing
    n = node(w)
    if has_dirty(n.dirty, Dirty.STYLE)
        _cascade_into!(ss, w, parent_style)
        return nothing
    end
    if has_dirty(n.dirty, Dirty.SUBTREE)
        ps = n.computed_style
        for c in n.children
            _recascade_node!(ss, c, ps)
        end
    end
    return nothing
end

"""
U4 + E1. Incremental: only STYLE-dirty subtrees, found via `SUBTREE`
breadcrumbs. A no-op when the tree is style-clean.
"""
function recascade!(ss::Stylesheet, root::Widget)::Nothing
    _recascade_node!(ss, root, STYLE_NONE)
    return nothing
end

# ---------------------------------------------------------------------
# Property table
# ---------------------------------------------------------------------

"""
Strip every space out of `v`, so `rgb(0, 90, 180)` reaches
`parse(Color, _)` in the form it accepts. Pure.
"""
_squeeze(v::AbstractString)::String = replace(v, r"\s+" => "")

"""
Parse a color value. Pure.
"""
function _color(v::AbstractString)::Color
    s = _squeeze(v)
    # `var(--name)` names a THEME TOKEN, and is kept as one: resolving
    # it here would freeze the stylesheet to the theme in force when it
    # was parsed, and one parsed sheet has to serve every theme.
    if startswith(s, "var(--") && endswith(s, ")")
        name = Symbol(s[7:(end - 1)])
        try
            return token(name)
        catch e
            e isa ArgumentError || rethrow()
            throw(CssParseError("unknown theme token: $name", 0, 0))
        end
    end
    return parse(Color, s)
end

"""
Parse a CSS keyword into the module-scoped enum `E`: lowercase and
dashes map to the SCREAMING_SNAKE_CASE value name. Pure.
"""
function _enum(::Type{E}, v::AbstractString,
               prop::AbstractString)::E where {E}
    want = uppercase(replace(strip(v), '-' => '_'))
    for e in instances(E)
        string(e) == want && return e
    end
    throw(CssParseError("bad value for '$prop': $(strip(v))", 0, 0))
end

"""
Parse an integer value. Pure.
"""
function _int(v::AbstractString, prop::AbstractString)::Int
    n = tryparse(Int, strip(v))
    n === nothing &&
        throw(CssParseError("bad value for '$prop': $(strip(v))", 0, 0))
    return n
end

"""
Parse a `Float32` value. Pure.
"""
function _f32(v::AbstractString, prop::AbstractString)::Float32
    n = tryparse(Float32, strip(v))
    n === nothing &&
        throw(CssParseError("bad value for '$prop': $(strip(v))", 0, 0))
    return n
end

"""
Parse a `margin`/`padding` shorthand of 1, 2 or 4 cell counts, in CSS
order (top right bottom left). Pure.
"""
function _spacing(v::AbstractString, prop::AbstractString)::Spacing
    ps = split(strip(v))
    n = length(ps)
    if n == 1
        return Spacing(_int(ps[1], prop))
    elseif n == 2
        return Spacing(_int(ps[1], prop), _int(ps[2], prop))
    elseif n == 4
        return Spacing(_int(ps[1], prop), _int(ps[2], prop),
                       _int(ps[3], prop), _int(ps[4], prop))
    end
    throw(CssParseError("'$prop' takes 1, 2 or 4 values, got $n", 0, 0))
end

"""
Parse `border: <kind>` or `border: <kind> <color>`. Pure.
"""
function _border(v::AbstractString)::Border
    t = strip(v)
    sp = findfirst(isspace, t)
    sp === nothing &&
        return Border(_enum(BorderKind.T, t, "border"), STYLE_NONE)
    k = _enum(BorderKind.T, t[1:prevind(t, sp)], "border")
    rest = _squeeze(t[nextind(t, sp):end])
    isempty(rest) && return Border(k, STYLE_NONE)
    # `_color` and not `parse(Color, ...)`: the border shorthand must
    # accept `var(--accent)` like every other place a colour is named.
    # It did not, which a rebuilt screen found and a unit test had not.
    return Border(k, Style(fg = _color(rest)))
end

"""
The extensible property table -- adding a property is adding a method.
Used ONLY by the parser, never in a render loop. Pure.
"""
function parse_property(::Val{P},
                        value::AbstractString)::Tuple{Style,BoxPatch} where {P}
    throw(CssParseError("unknown property: $(P)", 0, 0))
end

parse_property(::Val{:color},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (Style(fg = _color(v)), BOX_PATCH_NONE)

parse_property(::Val{:background},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (Style(bg = _color(v)), BOX_PATCH_NONE)

function parse_property(::Val{Symbol("text-style")},
                        v::AbstractString)::Tuple{Style,BoxPatch}
    (attrs, mask) = parse_attrs(v)
    return (Style(COLOR_UNSET, COLOR_UNSET, attrs, mask),
            BOX_PATCH_NONE)
end

parse_property(::Val{:display},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(display = _enum(Display.T, v, "display")))

parse_property(::Val{:layout},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE,
     BoxPatch(display = Display.FLEX,
              direction = _enum(Direction.T, v, "layout")))

parse_property(::Val{:direction},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE,
     BoxPatch(direction = _enum(Direction.T, v, "direction")))

parse_property(::Val{:justify},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(justify = _enum(Justify.T, v, "justify")))

parse_property(::Val{:align},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(align = _enum(Align.T, v, "align")))

parse_property(::Val{:width},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(width = parse(Length, strip(v))))

parse_property(::Val{:height},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(height = parse(Length, strip(v))))

parse_property(::Val{Symbol("min-width")},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(min_width = parse(Length, strip(v))))

parse_property(::Val{Symbol("min-height")},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(min_height = parse(Length, strip(v))))

parse_property(::Val{Symbol("max-width")},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(max_width = parse(Length, strip(v))))

parse_property(::Val{Symbol("max-height")},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(max_height = parse(Length, strip(v))))

parse_property(::Val{:margin},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(margin = _spacing(v, "margin")))

parse_property(::Val{:padding},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(padding = _spacing(v, "padding")))

parse_property(::Val{:border},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(border = _border(v)))

parse_property(::Val{:gap},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(gap = _int(v, "gap")))

function parse_property(::Val{:overflow},
                        v::AbstractString)::Tuple{Style,BoxPatch}
    o = _enum(Overflow.T, v, "overflow")
    return (STYLE_NONE, BoxPatch(overflow_x = o, overflow_y = o))
end

parse_property(::Val{Symbol("overflow-x")},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE,
     BoxPatch(overflow_x = _enum(Overflow.T, v, "overflow-x")))

parse_property(::Val{Symbol("overflow-y")},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE,
     BoxPatch(overflow_y = _enum(Overflow.T, v, "overflow-y")))

parse_property(::Val{:grow},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(grow = _f32(v, "grow")))

parse_property(::Val{:shrink},
               v::AbstractString)::Tuple{Style,BoxPatch} =
    (STYLE_NONE, BoxPatch(shrink = _f32(v, "shrink")))

# ---------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------

"""
A position-tracking cursor over stylesheet source. Internal to the
parser; it is the only thing that knows about lines and columns.
"""
mutable struct _CssCursor
    "The source being scanned."
    const src::String
    "Byte index of the next character."
    i::Int
    "1-based line of `i`."
    line::Int
    "1-based column of `i`."
    col::Int
end

"""
A cursor at the start of `src`.
"""
_cursor(src::AbstractString)::_CssCursor = _CssCursor(String(src), 1, 1, 1)

"""
True once every character has been consumed.
"""
_eof(c::_CssCursor)::Bool = c.i > ncodeunits(c.src)

"""
Fail at the cursor's current position.
"""
_err(c::_CssCursor, msg::AbstractString) =
    throw(CssParseError(String(msg), c.line, c.col))

"""
The next character, or `'\\0'` at end of input.
"""
_peek(c::_CssCursor)::Char = _eof(c) ? '\0' : c.src[c.i]

"""
The character after the next one, or `'\\0'`.
"""
function _peek2(c::_CssCursor)::Char
    _eof(c) && return '\0'
    j = nextind(c.src, c.i)
    j > ncodeunits(c.src) && return '\0'
    return c.src[j]
end

"""
Consume and return the next character, tracking line and column.
"""
function _advance!(c::_CssCursor)::Char
    _eof(c) && return '\0'
    ch = c.src[c.i]
    c.i = nextind(c.src, c.i)
    if ch == '\n'
        c.line += 1
        c.col = 1
    else
        c.col += 1
    end
    return ch
end

"""
Consume a `/* ... */` comment. The cursor must sit on its `/`.
"""
function _skip_comment!(c::_CssCursor)::Nothing
    line = c.line
    col = c.col
    _advance!(c)
    _advance!(c)
    while true
        _eof(c) && throw(CssParseError("unterminated comment", line, col))
        if _peek(c) == '*' && _peek2(c) == '/'
            _advance!(c)
            _advance!(c)
            return nothing
        end
        _advance!(c)
    end
end

"""
Consume whitespace and comments. Returns true when anything was
consumed -- which is what makes `A B` a descendant combinator and `AB`
one identifier.
"""
function _skip_ws!(c::_CssCursor)::Bool
    skipped = false
    while !_eof(c)
        ch = _peek(c)
        if isspace(ch)
            _advance!(c)
            skipped = true
        elseif ch == '/' && _peek2(c) == '*'
            _skip_comment!(c)
            skipped = true
        else
            break
        end
    end
    return skipped
end

"""
True when `ch` may open an identifier.
"""
_is_ident_start(ch::Char)::Bool = isletter(ch) || ch == '_' || ch == '-'

"""
True when `ch` may continue an identifier.
"""
_is_ident_char(ch::Char)::Bool =
    isletter(ch) || isdigit(ch) || ch == '_' || ch == '-'

"""
True when `ch` may open a simple selector.
"""
_is_simple_start(ch::Char)::Bool =
    ch == '*' || ch == '.' || ch == '#' || ch == ':' ||
    _is_ident_start(ch)

"""
Consume one identifier.
"""
function _read_ident!(c::_CssCursor)::String
    _is_ident_start(_peek(c)) || _err(c, "expected an identifier")
    io = IOBuffer()
    while !_eof(c) && _is_ident_char(_peek(c))
        write(io, _advance!(c))
    end
    return String(take!(io))
end

"""
Consume a declaration value: everything up to the next `;` or `}`.
"""
function _read_value!(c::_CssCursor)::String
    io = IOBuffer()
    while !_eof(c)
        ch = _peek(c)
        (ch == ';' || ch == '}') && break
        write(io, _advance!(c))
    end
    return String(strip(String(take!(io))))
end

"""
Consume one compound selector: the atoms ANDed against a single node.
"""
function _parse_compound!(c::_CssCursor)::CompoundSelector
    parts = SimpleSelector[]
    while !_eof(c)
        ch = _peek(c)
        if ch == '*'
            _advance!(c)
            push!(parts,
                  SimpleSelector(SelectorKind.UNIVERSAL, Symbol("*")))
        elseif ch == '.'
            _advance!(c)
            push!(parts,
                  SimpleSelector(SelectorKind.CLASS,
                                 Symbol(_read_ident!(c))))
        elseif ch == '#'
            _advance!(c)
            push!(parts,
                  SimpleSelector(SelectorKind.ID,
                                 Symbol(_read_ident!(c))))
        elseif ch == ':'
            _advance!(c)
            name = _read_ident!(c)
            name in ("focus", "focus-within") ||
                _err(c, "unknown pseudo-class: :$name")
            push!(parts,
                  SimpleSelector(SelectorKind.PSEUDO, Symbol(name)))
        elseif _is_ident_start(ch)
            push!(parts,
                  SimpleSelector(SelectorKind.TYPE,
                                 Symbol(_read_ident!(c))))
        else
            break
        end
    end
    isempty(parts) && _err(c, "expected a selector")
    return CompoundSelector(parts)
end

"""
Consume one selector: compounds joined by `>` or by whitespace.
"""
function _parse_selector!(c::_CssCursor)::Selector
    compounds = CompoundSelector[]
    combinators = Combinator.T[]
    push!(compounds, _parse_compound!(c))
    while true
        ws = _skip_ws!(c)
        ch = _peek(c)
        if ch == '>'
            _advance!(c)
            _skip_ws!(c)
            push!(combinators, Combinator.CHILD)
            push!(compounds, _parse_compound!(c))
        elseif ws && _is_simple_start(ch)
            push!(combinators, Combinator.DESCENDANT)
            push!(compounds, _parse_compound!(c))
        else
            break
        end
    end
    return Selector(compounds, combinators)
end

"""
True for the exceptions a value parser raises on BAD INPUT, as opposed
to the ones a bug raises. `parse(Color, _)`, `parse(Length, _)` and
`parse_attrs` signal with `ArgumentError`; an out-of-range channel or
cell count surfaces as `InexactError`/`OverflowError`. Anything else --
`MethodError`, `UndefVarError` -- is a defect in a `parse_property`
method and MUST NOT be reported to the author as "bad value". Pure.
"""
_is_value_error(e)::Bool =
    e isa ArgumentError || e isa InexactError || e isa OverflowError

"""
Dispatch one declaration through `parse_property`, re-throwing what it
rejects as a `CssParseError` carrying the declaration's own line and
column.
"""
function _property(prop::AbstractString, value::AbstractString,
                   line::Int, col::Int)::Tuple{Style,BoxPatch}
    try
        return parse_property(Val(Symbol(prop)), value)
    catch e
        e isa CssParseError && throw(CssParseError(e.msg, line, col))
        _is_value_error(e) || rethrow()
        throw(CssParseError("bad value for '$prop': $value", line, col))
    end
end

"""
Consume a `{ ... }` declaration block, folding it into one `Style` and
one `BoxPatch`. Later declarations win over earlier ones.
"""
function _parse_declarations!(c::_CssCursor)::Tuple{Style,BoxPatch}
    style = STYLE_NONE
    bx = BOX_PATCH_NONE
    _skip_ws!(c)
    while true
        _eof(c) && _err(c, "unterminated declaration block")
        if _peek(c) == '}'
            _advance!(c)
            break
        end
        line = c.line
        col = c.col
        _is_ident_start(_peek(c)) || _err(c, "expected a property name")
        prop = _read_ident!(c)
        _skip_ws!(c)
        _peek(c) == ':' || _err(c, "expected ':' after '$prop'")
        _advance!(c)
        _skip_ws!(c)
        value = _read_value!(c)
        isempty(value) &&
            throw(CssParseError("property '$prop' has no value",
                                line, col))
        (s, b) = _property(prop, value, line, col)
        style = merge(style, s)
        bx = merge(bx, b)
        _skip_ws!(c)
        if _peek(c) == ';'
            _advance!(c)
            _skip_ws!(c)
        end
    end
    return (style, bx)
end

"""
Parse a stylesheet.

Throws `CssParseError`, carrying line and column, on bad input. Never
throws a bare `ArgumentError`. Pure.
"""
function parse_css(src::AbstractString)::Stylesheet
    c = _cursor(src)
    rules = Rule[]
    order = 0
    _skip_ws!(c)
    while !_eof(c)
        sels = Selector[]
        push!(sels, _parse_selector!(c))
        _skip_ws!(c)
        while _peek(c) == ','
            _advance!(c)
            _skip_ws!(c)
            push!(sels, _parse_selector!(c))
            _skip_ws!(c)
        end
        _peek(c) == '{' || _err(c, "expected '{'")
        _advance!(c)
        (style, bx) = _parse_declarations!(c)
        for s in sels
            order += 1
            push!(rules, Rule(s, style, bx, order))
        end
        _skip_ws!(c)
    end
    return Stylesheet(rules)
end

"""
Parse a stylesheet. Pure.
"""
Base.parse(::Type{Stylesheet}, s::AbstractString)::Stylesheet = parse_css(s)

"""
Parse a single selector. Pure.
"""
function Base.parse(::Type{Selector}, s::AbstractString)::Selector
    c = _cursor(s)
    _skip_ws!(c)
    sel = _parse_selector!(c)
    _skip_ws!(c)
    _eof(c) || _err(c, "trailing characters after the selector")
    return sel
end

"""
Parse a stylesheet at MACRO-EXPANSION time, so a bad stylesheet is a
compile error:

    css"Button { color: red; }"
"""
macro css_str(s)
    return parse_css(s)
end
