# widgets/markdownpane.jl -- layer 7.
# May reference: widget, reactive, richtext, theme, scroll, unicode.
#
# Markdown is PARSED BY THE STDLIB and only rendered here. The AST is
# `Markdown.MD`; what this file adds is the projection from that AST to
# a `Vector{RichText}` -- which is the whole reason `RichText` had to
# exist first. A heading is not a widget, a bold run is not a widget,
# and a document is not a subtree: it is LINES, held as data, one node.
#
# The line cache is keyed on the WIDTH it was built at. Everything here
# depends on the wrap width, so a pane laid out narrower must rebuild;
# rebuilding on every frame instead would reflow a whole document per
# frame, and not rebuilding at all would show the previous width's
# breaks in the new box.

"Style of a heading. Themed, so a document tracks the palette."
const MD_HEADING = Style(; fg = token(:accent), bold = true)
"Style of inline and block code."
const MD_CODE = Style(; fg = token(:warning))
"Style of a block quote, marker included."
const MD_QUOTE = Style(; fg = token(:text_dim), italic = true)
"Style of a link's text. The URL is not shown; see `md_lines`."
const MD_LINK = Style(; fg = token(:accent), underline = true)
"Style of a list bullet or number."
const MD_MARKER = Style(; fg = token(:text_dim))
"Drawn for a horizontal rule, repeated to the pane width."
const MD_RULE = "─"
"Marker before a block-quote line."
const MD_QUOTE_MARK = "│ "
"Bullet for an unordered list item."
const MD_BULLET = "• "
"Cells a nested list is indented by."
const MD_INDENT = 2

"""
A scrollable rendered Markdown document.

Holds the SOURCE, the parsed AST and the lines it was last rendered to.
The lines are `RichText`, so a heading, a bold run and a code span cost
runs rather than nodes: a 500-line document is one widget.
"""
mutable struct MarkdownPane <: Widget
    "Per-widget state."
    node::WidgetNode
    "The Markdown source."
    source::String
    "The parsed document. Reparsed only when `source` is replaced."
    ast::Any
    "Rendered lines, valid for `wrapped_at`."
    lines::Vector{RichText}
    "The width `lines` was built at; `-1` when there are none."
    wrapped_at::Int
    "Bumped when the source changes. THE reactive cell. `Dirty.PAINT`."
    version::Reactive{Int}
end

"""
A pane over the Markdown in `source`.
"""
function MarkdownPane(source::AbstractString = "";
                      id::Symbol = gensym(:markdownpane),
                      classes = Symbol[])::MarkdownPane
    w = MarkdownPane(WidgetNode(; id = id, classes = classes,
                                type_name = :MarkdownPane),
                     String(source), Markdown.parse(String(source)),
                     RichText[], -1, Reactive(0; kind = Dirty.PAINT))
    attach_reactives!(w)
    return w
end

"""
Replace the source and reparse. Drops the line cache.
"""
function set_source!(w::MarkdownPane, source::AbstractString)::Nothing
    s = String(source)
    s == w.source && return nothing
    w.source = s
    w.ast = Markdown.parse(s)
    w.wrapped_at = -1
    empty!(w.lines)
    w.version[] += 1
    return nothing
end

# --- inline ----------------------------------------------------------

"""
Append the inline node `x` to `runs`, under `base`. Internal.

Unknown nodes fall through to their `string` form rather than being
dropped: an unrendered footnote is a visible oddity, a missing one is a
silent hole in the text.
"""
function _md_inline!(runs::Vector{TextRun}, x, base::Style)::Nothing
    if x isa AbstractString
        push!(runs, TextRun(String(x), base))
    elseif x isa Markdown.Bold
        _md_inlines!(runs, x.text, merge(base, Style(; bold = true)))
    elseif x isa Markdown.Italic
        _md_inlines!(runs, x.text, merge(base, Style(; italic = true)))
    elseif x isa Markdown.Code
        push!(runs, TextRun(x.code, merge(base, MD_CODE)))
    elseif x isa Markdown.Link
        _md_inlines!(runs, x.text, merge(base, MD_LINK))
    elseif x isa Markdown.LineBreak
        push!(runs, TextRun(" ", base))
    else
        push!(runs, TextRun(strip(sprint(show, MIME("text/plain"), x)),
                            base))
    end
    return nothing
end

"""
Append every inline node of `xs`. `xs` may be one node. Internal.
"""
function _md_inlines!(runs::Vector{TextRun}, xs, base::Style)::Nothing
    if xs isa AbstractVector
        for x in xs
            _md_inline!(runs, x, base)
        end
    else
        _md_inline!(runs, xs, base)
    end
    return nothing
end

"""
The inline content of `xs` as one `RichText` under `base`.
"""
function md_inline(xs, base::Style = STYLE_NONE)::RichText
    runs = TextRun[]
    _md_inlines!(runs, xs, base)
    return RichText(runs)
end

# --- blocks ----------------------------------------------------------

"""
Wrap `rt` to `width` and push the lines onto `out`, each prefixed by
`prefix`. Internal.

TWO prefixes, and that is the point. A block quote wants the same
marker on every line; a list item wants its bullet ONCE and blank
indent under it, or a wrapped item reads as two items. One prefix
cannot be both, which is exactly the bug a single one produces.
"""
function _md_wrap!(out::Vector{RichText}, rt::RichText, width::Int,
                   head::RichText = RICHTEXT_EMPTY,
                   rest::RichText = head)::Nothing
    inner = max(1, width - text_width(head))
    ls = wrap_width(rt, inner)
    isempty(ls) && (push!(out, head); return nothing)
    for (i, l) in enumerate(ls)
        pre = i == 1 ? head : rest
        push!(out, isempty(pre) ? l : pre * l)
    end
    return nothing
end

"""
Render the block `b` at `width`, appending to `out`. Internal.
"""
function _md_block!(out::Vector{RichText}, b, width::Int,
                    head::RichText, rest::RichText = head)::Nothing
    if b isa Markdown.Header
        _md_wrap!(out, md_inline(b.text, MD_HEADING), width, head, rest)
    elseif b isa Markdown.Paragraph
        _md_wrap!(out, md_inline(b.content), width, head, rest)
    elseif b isa Markdown.Code
        # A code block is NEVER wrapped: a broken line of code is a
        # different line of code. It is truncated by the painter
        # instead, and the pane scrolls sideways.
        for (i, l) in enumerate(split(b.code, '\n'))
            push!(out, (i == 1 ? head : rest) *
                       RichText(String(l), MD_CODE))
        end
    elseif b isa Markdown.BlockQuote
        # A quote repeats its marker on every line, so head === rest.
        q = rest * RichText(MD_QUOTE_MARK, MD_QUOTE)
        q1 = head * RichText(MD_QUOTE_MARK, MD_QUOTE)
        for (i, sub) in enumerate(b.content)
            i == 1 || push!(out, q)
            _md_block!(out, sub, width, i == 1 ? q1 : q, q)
        end
    elseif b isa Markdown.List
        for (i, item) in enumerate(b.items)
            mark = b.ordered < 0 ? MD_BULLET : "$(b.ordered + i - 1). "
            # The bullet ONCE, blank indent under it: a wrapped item
            # that repeated its bullet would read as two items.
            h = (i == 1 ? head : rest) * RichText(mark, MD_MARKER)
            cont = rest * RichText(" "^text_width(mark))
            for (j, sub) in enumerate(item)
                _md_block!(out, sub, width, j == 1 ? h : cont, cont)
            end
        end
    elseif b isa Markdown.HorizontalRule
        n = max(1, width - text_width(head))
        push!(out, head * RichText(MD_RULE^n, MD_MARKER))
    else
        _md_wrap!(out, md_inline(b), width, head, rest)
    end
    return nothing
end

"""
The document rendered to lines at `width`, cached.

Rebuilt only when `width` differs from the width the cache was built
at. Everything about a rendered document depends on the wrap width, so
a cache that ignored it would show the previous box's breaks in the new
one, and rebuilding unconditionally would reflow the whole document
once a frame.
"""
function md_lines(w::MarkdownPane, width::Int)::Vector{RichText}
    width = max(1, width)
    w.wrapped_at == width && return w.lines
    out = RichText[]
    blocks = w.ast.content
    for (i, b) in enumerate(blocks)
        i == 1 || push!(out, RICHTEXT_EMPTY)   # one blank row between
        _md_block!(out, b, width, RICHTEXT_EMPTY)
    end
    w.lines = out
    w.wrapped_at = width
    return out
end

"""
`avail`. A pane takes the space it is OFFERED and scrolls, because an
auto-height document would be as tall as itself and would never scroll.
This is also what licenses `version`'s PAINT reactivity.
"""
measure(w::MarkdownPane, avail::Size)::Size = avail

"""
The size of the rendered document at the width it was last rendered
to, so a `Scrollbar` reports on it with no new code.

`Size(0, 0)` before the first paint: nothing has decided a width yet,
and guessing one here would produce an extent that the first paint then
contradicts.
"""
function content_extent(w::MarkdownPane)::Size
    w.wrapped_at < 0 && return Size(0, 0)
    widest = 0
    for l in w.lines
        widest = max(widest, text_width(l))
    end
    return Size(widest, length(w.lines))
end
