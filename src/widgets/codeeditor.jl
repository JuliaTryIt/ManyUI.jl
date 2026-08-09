# widgets/codeeditor.jl -- layer 7.
# May reference: richtext, theme, textarea.
#
# NOT A NEW WIDGET TYPE. A code editor is a `TextArea` whose lines are
# painted through a highlighter -- the same call `Gauge` did not deserve
# a type for. What is new is the HIGHLIGHTER seam and one implementation
# of it.
#
# Highlighting is done on the WHOLE document and not line by line,
# because a line is not a lexical unit: a triple-quoted string or an
# unterminated comment means line 40 is only classifiable given lines
# 1 to 39. The result is cached against `TextArea.version`, which every
# edit already bumps, so a keystroke costs one relex of the document
# and a frame costs none.

"""
Map from a `JuliaSyntaxHighlighting` face to a style.

Themed, so code tracks the palette. Faces not named here fall back to
the widget's own style, which is why an unknown face is invisible
rather than wrong.
"""
const CODE_FACES = Dict{Symbol,Style}(
    :julia_keyword => Style(; fg = token(:accent), bold = true),
    :julia_macro => Style(; fg = token(:accent)),
    :julia_string => Style(; fg = token(:success)),
    :julia_string_delim => Style(; fg = token(:success)),
    :julia_char => Style(; fg = token(:success)),
    :julia_char_delim => Style(; fg = token(:success)),
    :julia_regex => Style(; fg = token(:success)),
    :julia_comment => Style(; fg = token(:text_dim), italic = true),
    :julia_number => Style(; fg = token(:warning)),
    :julia_funcall => Style(; fg = token(:warning)),
    :julia_operator => Style(; fg = token(:text_dim)),
    :julia_type => Style(; fg = token(:warning)),
    :julia_symbol => Style(; fg = token(:success)),
    :julia_error => Style(; fg = token(:error), underline = true),
)

"""
The style a highlighter face maps to, or `STYLE_NONE`.
"""
code_face_style(face::Symbol)::Style = get(CODE_FACES, face, STYLE_NONE)

"""
Highlight Julia `source` into one `RichText` per line.

Uses the `JuliaSyntaxHighlighting` stdlib, so the lexer is the one
Julia itself ships and this file owns no tokeniser. Its annotations are
BYTE regions over the whole source; they are turned into per-line runs
here, splitting a region that spans a newline rather than dropping it.

Total: a source that does not lex is returned unhighlighted rather than
throwing. An editor that refuses to draw the moment the text is
mid-edit would be unusable, and text under the cursor is invalid most
of the time it is being typed.
"""
function highlight_julia(source::AbstractString)::Vector{RichText}
    lines = split(String(source), '\n')
    faces = fill(STYLE_NONE, ncodeunits(source) + 1)
    try
        hl = JuliaSyntaxHighlighting.highlight(String(source))
        for ann in Base.annotations(hl)
            ann.label === :face || continue
            st = code_face_style(ann.value)
            st === STYLE_NONE && continue
            for i in ann.region
                checkbounds(Bool, faces, i) && (faces[i] = st)
            end
        end
    catch
        # Unlexable mid-edit text: draw it plain, never refuse to draw.
    end

    out = Vector{RichText}(undef, length(lines))
    pos = 1                       # byte index of the current line start
    for (li, line) in enumerate(lines)
        runs = TextRun[]
        s = String(line)
        i = 1
        while i <= ncodeunits(s)
            st = faces[pos + i - 1]
            j = i
            while j < ncodeunits(s) && faces[pos + j] === st
                j += 1
            end
            # `thisind`/`nextind`: a run boundary must fall on a
            # character boundary, or the substring throws.
            lo = thisind(s, i)
            hi = thisind(s, j)
            push!(runs, TextRun(s[lo:hi], st))
            i = nextind(s, hi)
        end
        out[li] = RichText(runs)
        pos += ncodeunits(s) + 1  # the newline
    end
    return out
end

"""
A `TextArea` that paints its lines through `highlight`.

`language` selects a built-in highlighter; `:julia` is the only one,
and `:none` gives a plain `TextArea`. Pass `highlight` directly for
your own -- it takes the whole source and returns one `RichText` per
line, WHOLE-DOCUMENT because a line is not a lexical unit.
"""
function CodeEditor(text::AbstractString = "", on_change = _ta_noop;
                    language::Symbol = :julia,
                    highlight = nothing,
                    disabled::Bool = false,
                    id::Symbol = gensym(:codeeditor),
                    classes = Symbol[])
    hl = highlight !== nothing ? highlight :
         language === :julia ? highlight_julia :
         language === :none ? nothing :
         throw(ArgumentError("unknown language: $(repr(language)). " *
                             "Known: :julia, :none"))
    w = TextArea(text, on_change; disabled = disabled, id = id,
                 classes = classes)
    w.highlight = hl
    return w
end

"""
`w`'s lines as `RichText`, highlighted and cached.

Keyed on `version`, which every edit already bumps, so a keystroke
costs one relex of the document and a frame costs none. Returns an
empty vector when there is no highlighter -- the caller then paints the
plain lines, which is the same code path a `TextArea` always took.
"""
function code_lines(w::TextArea)::Vector{RichText}
    w.highlight === nothing && return RichText[]
    v = w.version[]
    w.hl_version == v && return w.hl_lines
    w.hl_lines = w.highlight(join(w.lines, '\n'))
    w.hl_version = v
    return w.hl_lines
end
