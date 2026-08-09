# widgets/dialog.jl -- layer 7.
# May reference: container, label, button, richtext.
#
# NOT A NEW WIDGET TYPE. A dialog is a captioned `Container` holding a
# message and a row of `Button`s -- every part of it already exists, and
# a `Dialog <: Widget` would add a type whose only content is how those
# three are arranged. What did not exist is the ARRANGEMENT and the size
# it needs, so that is what this file is: two functions.
#
# The modality is not here either. `Popup(...; modal = true)` supplies
# it, and it belongs there because it is a property of the LAYER, not of
# what is on it.

"Cells of padding inside a dialog's frame."
const DIALOG_PAD = 1
"Cells between two buttons in the row."
const DIALOG_BUTTON_GAP = 2
"Narrowest dialog worth opening."
const DIALOG_MIN_WIDTH = 20

"""
A dialog: a captioned frame around `message` and a row of buttons.

`buttons` is a vector of `caption => callback` pairs, laid out left to
right. The callback is the `Button`'s own `on_click`, so a dialog that
must close itself calls `close_popup!` from inside it -- this function
does not know about an App and cannot do it for you.

Returns an ordinary `Container`, so it composes, restyles and is
queried like anything else. Pair it with [`dialog_size`](@ref) and open
it with `Popup(...; modal = true, placement = PopupPlacement.CENTER)`.
"""
function Dialog(message::TextLike;
                title::TextLike = RICHTEXT_EMPTY,
                buttons::AbstractVector{<:Pair} = Pair{String,Function}[],
                id::Symbol = gensym(:dialog),
                classes = Symbol[])::Container
    row = Container([Button(String(c), f) for (c, f) in buttons]...;
                    id = Symbol(id, :_buttons), classes = [:dialog_buttons])
    _sp_box!(row, BoxPatch(; display = Display.FLEX,
                           direction = Direction.ROW,
                           justify = Justify.CENTER,
                           gap = DIALOG_BUTTON_GAP,
                           height = cells(1), grow = 0.0f0,
                           shrink = 0.0f0))

    body = Label(message; id = Symbol(id, :_message))
    _sp_box!(body, BoxPatch(; grow = 1.0f0))

    d = Container(body, row; id = id, classes = classes, title = title,
                  title_align = Align.CENTER)
    _sp_box!(d, BoxPatch(; display = Display.FLEX,
                         direction = Direction.COLUMN,
                         padding = Spacing(DIALOG_PAD, DIALOG_PAD,
                                           DIALOG_PAD, DIALOG_PAD),
                         border = Border(BorderKind.ROUND, STYLE_NONE)))
    return d
end

"""
The size a `Dialog` wants for `message`, `title` and `buttons`, bounded
by `max`.

A dialog is opened on the POPUP layer, and the layer takes the owner's
declared size rather than measuring the content -- so something has to
compute it, and guessing wrong shows as a clipped question. Wraps the
message to the width it settles on, so the height is the height the
message will actually occupy rather than one line per sentence.
"""
function dialog_size(message::TextLike;
                     title::TextLike = RICHTEXT_EMPTY,
                     buttons::AbstractVector{<:Pair} = Pair{String,Function}[],
                     max::Size = Size(60, 20))::Size
    msg = convert(RichText, message)
    # Widest of: the message on one line, the caption, the button row.
    btn_w = isempty(buttons) ? 0 :
            sum(text_width(String(first(b))) + 2 for b in buttons) +
            DIALOG_BUTTON_GAP * (length(buttons) - 1)
    want = Base.max(text_width(msg), text_width(convert(RichText, title)) + 2,
                    btn_w)
    # Frame plus padding on both sides.
    chrome = 2 + 2 * DIALOG_PAD
    w = clamp(want + chrome, DIALOG_MIN_WIDTH, max.width)
    inner = Base.max(1, w - chrome)
    lines = Base.max(1, length(wrap_width(msg, inner)))
    # Message, a blank row, the button row, plus the frame and padding.
    h = lines + (isempty(buttons) ? 0 : 2) + chrome
    return Size(w, clamp(h, 3, max.height))
end
