# theme.jl -- layer 4.5. May reference: color.
#
# A SEMANTIC colour: `:warning` rather than `#ffc800`. The cascade can
# already say what colour a widget is; what it cannot say is what
# `warning` MEANS, because that answer belongs to the whole application
# and changes when the user picks a different palette.
#
# WHEN A TOKEN BECOMES A COLOUR IS THE WHOLE DESIGN. It is at EMISSION,
# in the one place `degrade` is called -- not at parse time, and not at
# cascade time. The consequences are the point:
#
#   * one parsed stylesheet serves every theme;
#   * `merge` carries a token through, so a `TextRun` naming `:warning`
#     is built once and is right under every theme rather than frozen
#     to whichever was current when it was built;
#   * swapping a theme is a REPAINT, not a re-cascade and not a
#     re-parse. Nothing in the tree has to change, because nothing in
#     the tree holds a resolved colour.
#
# The cost is one lookup per colour per emitted style change, which the
# frame diff already keeps small.

# --- the token table -------------------------------------------------

"Token names, indexed by id. `id = i` is `_TOKEN_NAMES[i]`."
const _TOKEN_NAMES = Symbol[]
"Name to id."
const _TOKEN_IDS = Dict{Symbol,UInt8}()
"""
The colour a token falls back to when the current theme does not name
it, indexed by id.
"""
const _TOKEN_FALLBACK = Color[]

"""
Declare a semantic colour called `name`, falling back to `fallback` in
a theme that does not name it, and return its id.

Idempotent: re-declaring an existing name returns the id it already
has and leaves its fallback alone. Ids are assigned in declaration
order and are meaningful only within a session -- they are an
implementation detail of packing a token into an isbits `Color`, never
something to serialise.

A fallback rather than an error at lookup time is deliberate: a partial
theme is a usable theme, and the failure mode of the alternative is one
unreadable widget discovered at runtime, far from the theme that caused
it.
"""
function register_token!(name::Symbol, fallback::Color)::UInt8
    haskey(_TOKEN_IDS, name) && return _TOKEN_IDS[name]
    length(_TOKEN_NAMES) < 255 ||
        throw(ArgumentError("no room for another token: the id is one " *
                            "byte of an isbits Color"))
    push!(_TOKEN_NAMES, name)
    push!(_TOKEN_FALLBACK, fallback)
    id = UInt8(length(_TOKEN_NAMES))
    _TOKEN_IDS[name] = id
    return id
end

"""
The `Color` naming the token `name`, to be looked up against a theme
when it is painted.

Throws on an unknown name: a typo in a token is a typo in a colour, and
silently painting the default instead is how a theme develops holes.
"""
function token(name::Symbol)::Color
    id = get(_TOKEN_IDS, name, UInt8(0))
    id == 0 && throw(ArgumentError(
        "unknown theme token: $(repr(name)). Known: " *
        join(sort(collect(keys(_TOKEN_IDS))), ", ")))
    return Color(ColorKind.TOKEN, id, 0x00, 0x00)
end

"""
The name a token `Color` carries. Throws for anything else.
"""
function token_name(c::Color)::Symbol
    is_token(c) || throw(ArgumentError("not a token: $c"))
    return _TOKEN_NAMES[Int(c.r)]
end

"""
Every declared token name, sorted.
"""
token_names()::Vector{Symbol} = sort(collect(keys(_TOKEN_IDS)))

# The vocabulary. Fallbacks are a legible dark palette, so a token
# resolves to something readable even with no theme registered at all.
const TOKEN_BG = register_token!(:bg, rgb(0x1e1e2e))
const TOKEN_TEXT = register_token!(:text, rgb(0xcdd6f4))
const TOKEN_TEXT_DIM = register_token!(:text_dim, rgb(0x7f849c))
const TOKEN_ACCENT = register_token!(:accent, rgb(0x89b4fa))
const TOKEN_BORDER = register_token!(:border, rgb(0x585b70))
const TOKEN_SUCCESS = register_token!(:success, rgb(0xa6e3a1))
const TOKEN_WARNING = register_token!(:warning, rgb(0xf9e2af))
const TOKEN_ERROR = register_token!(:error, rgb(0xf38ba8))
const TOKEN_SELECTION_BG = register_token!(:selection_bg, rgb(0x45475a))
const TOKEN_SELECTION_FG = register_token!(:selection_fg, rgb(0xcdd6f4))

# --- themes ----------------------------------------------------------

"""
A named palette: what each token means.

Partial by design -- a token the theme does not name falls back to the
one declared with `register_token!`, so a theme that cares about three
colours is three entries long and still total.
"""
struct Theme
    "How the theme is asked for."
    name::Symbol
    "Token to colour. Need not be total."
    colors::Dict{Symbol,Color}
end

Theme(name::Symbol; kwargs...)::Theme =
    Theme(name, Dict{Symbol,Color}(k => v for (k, v) in kwargs))

"""
What `name` means under `th`: the theme's own entry, or the token's
declared fallback. Never a token -- the result is always a colour.
"""
function theme_color(th::Theme, name::Symbol)::Color
    c = get(th.colors, name, COLOR_UNSET)
    is_unset(c) || return c
    id = get(_TOKEN_IDS, name, UInt8(0))
    id == 0 && throw(ArgumentError("unknown theme token: $(repr(name))"))
    return _TOKEN_FALLBACK[Int(id)]
end

const _THEMES = Dict{Symbol,Theme}()

"""
Make `th` askable for by name. Replaces a theme of the same name.
"""
function register_theme!(th::Theme)::Theme
    _THEMES[th.name] = th
    return th
end

"""
Every registered theme name, sorted.
"""
themes()::Vector{Symbol} = sort(collect(keys(_THEMES)))

register_theme!(Theme(:dark, Dict(
    :bg => rgb(0x1e1e2e), :text => rgb(0xcdd6f4),
    :text_dim => rgb(0x7f849c), :accent => rgb(0x89b4fa),
    :border => rgb(0x585b70), :success => rgb(0xa6e3a1),
    :warning => rgb(0xf9e2af), :error => rgb(0xf38ba8),
    :selection_bg => rgb(0x45475a), :selection_fg => rgb(0xcdd6f4))))

register_theme!(Theme(:light, Dict(
    :bg => rgb(0xeff1f5), :text => rgb(0x4c4f69),
    :text_dim => rgb(0x8c8fa1), :accent => rgb(0x1e66f5),
    :border => rgb(0xbcc0cc), :success => rgb(0x40a02b),
    :warning => rgb(0xdf8e1d), :error => rgb(0xd20f39),
    :selection_bg => rgb(0xccd0da), :selection_fg => rgb(0x4c4f69))))

const _CURRENT_THEME = Ref{Theme}(_THEMES[:dark])

"""
The theme in force, or the registered theme called `name`.
"""
theme()::Theme = _CURRENT_THEME[]

function theme(name::Symbol)::Theme
    haskey(_THEMES, name) ||
        throw(ArgumentError("unknown theme: $(repr(name)). Known: " *
                            join(themes(), ", ")))
    return _THEMES[name]
end

"""
Put `th` in force and return it.

NOTHING IN THE TREE CHANGES, because nothing in the tree holds a
resolved colour: tokens are looked up at emission. A caller therefore
needs a full REPAINT and not a re-cascade -- and not a re-parse of the
stylesheet either. On the terminal backend that is `refresh!`; the
frame diff will not find the change on its own, since the cells it
compares are the same cells.
"""
function set_theme!(th::Theme)::Theme
    _CURRENT_THEME[] = th
    return th
end

set_theme!(name::Symbol)::Theme = set_theme!(theme(name))

# --- resolution ------------------------------------------------------

"""
`c` as a concrete colour under `th`: the token looked up, or `c`
itself.

Idempotent, total, and identity-preserving for everything that is not a
token -- `resolve_token(c) === c` for an ordinary colour, so the common
case allocates nothing and compares by identity.
"""
function resolve_token(c::Color, th::Theme = theme())::Color
    is_token(c) || return c
    return theme_color(th, _TOKEN_NAMES[Int(c.r)])
end

"""
`s` with both colour planes resolved under `th`. Attributes are
untouched: a theme names colours, not weights.

Returns `s` ITSELF when neither plane is a token, which is the
overwhelming majority of styles on the emission path.
"""
function resolve_token(s::Style, th::Theme = theme())::Style
    (is_token(s.fg) || is_token(s.bg)) || return s
    return Style(resolve_token(s.fg, th), resolve_token(s.bg, th),
                 s.attrs, s.mask)
end
