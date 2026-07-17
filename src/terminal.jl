# terminal.jl -- layer 6. May reference: driver, input, events, ansi,
# color, geometry. S1 (raw mode), S2 (alt screen), E4 (resize),
# X3 (restore survives any throw).

"""
The native TUI target: a TTY in raw mode, on the alternate screen.
"""
mutable struct TerminalDriver <: Driver
    "The terminal raw mode is toggled on."
    const term::REPL.Terminals.TTYTerminal
    "Byte source; an `IOBuffer` in tests, `stdin` in production."
    const in_stream::IO
    "Byte sink; an `IOBuffer` in tests, `stdout` in production."
    const out_stream::IO
    "The App's only input."
    const chan::Channel{Event}
    "Shared byte parser."
    const parser::InputParser
    "Staging buffer; `flush!` is the commit point."
    const outbuf::IOBuffer
    "What this terminal can do."
    caps::DriverCaps
    "Last observed renderable area."
    size::Size
    "True while raw mode is on."
    raw::Bool
    "True while the alternate screen is active."
    alt::Bool
    "True while mouse reporting is on."
    mouse_on::Bool
    "True between `start!` and `stop!`."
    started::Bool
    "True once `restore!` has run."
    restored::Bool
    "The byte reader task."
    reader::Union{Nothing,Task}
    "The resize poll task."
    resizer::Union{Nothing,Task}
    "Seconds between resize polls."
    resize_poll::Float64
end

"""
A terminal driver over `in_stream`/`out_stream`.

`caps === nothing` probes the environment via `detect_caps(ENV)`.
"""
function TerminalDriver(; in_stream::IO = stdin,
                          out_stream::IO = stdout,
                          caps::Union{Nothing,DriverCaps} = nothing,
                          buffer::Int = 256,
                          resize_poll::Real = 0.05)::TerminalDriver
    c = caps === nothing ? detect_caps(ENV) : caps
    term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", ""), in_stream,
                                      out_stream, stderr)
    return TerminalDriver(term, in_stream, out_stream,
                          Channel{Event}(buffer), InputParser(),
                          IOBuffer(), c, Size(80, 24),
                          false, false, false, false, false,
                          nothing, nothing, Float64(resize_poll))
end

"""
True when `env` advertises a UTF-8 locale through `LC_ALL` or `LANG`.
Pure. Internal.
"""
function _utf8_locale(env::AbstractDict)::Bool
    for k in ("LC_ALL", "LANG")
        v = uppercase(string(get(env, k, "")))
        (occursin("UTF-8", v) || occursin("UTF8", v)) && return true
    end
    return false
end

"""
A pure, table-testable environment probe.

`color_depth` comes from `detect_color_depth(env)`; `unicode` is true
unless `LANG`/`LC_ALL` lack UTF-8; `alt_screen`, `mouse`,
`bracketed_paste`, `focus_events` and `sync_output` are false when
`TERM == "dumb"` or `TERM` is unset, and true otherwise; `title` is
true.
"""
function detect_caps(env::AbstractDict = ENV)::DriverCaps
    term = string(get(env, "TERM", ""))
    capable = !(isempty(term) || term == "dumb")
    return DriverCaps(color_depth = detect_color_depth(env),
                      mouse = capable,
                      bracketed_paste = capable,
                      focus_events = capable,
                      alt_screen = capable,
                      title = true,
                      unicode = _utf8_locale(env),
                      sync_output = capable)
end

"""
S1. Toggle raw mode via `REPL.Terminals.raw!(d.term, on)`, which
saves and restores the original termios internally -- this driver
stores no termios blob and does no FFI. Returns success.

`d.raw` records the REQUESTED mode, not the OS outcome, so `restore!`
always undoes what `start!` asked for. The two differ only where the
toggle is meaningless anyway: over an `IOBuffer` there is no libuv
handle to set, the call fails, and there is correspondingly nothing to
undo. That is what lets the whole suite run without a tty.
"""
function set_raw!(d::TerminalDriver, on::Bool)::Bool
    ok = try
        REPL.Terminals.raw!(d.term, on) !== false
    catch
        false
    end
    d.raw = on
    return ok
end

"""
Append the code units of `s` to the staging buffer. Internal.
"""
_emit_str!(d::TerminalDriver, s::AbstractString)::Int =
    emit!(d, codeunits(s))

"""
The renderable area as reported by `out_stream`.

`displaysize` returns `(rows, cols)` while `Size` is `(width, height)`:
the swap lives HERE and nowhere else. Internal.
"""
function _query_size(d::TerminalDriver)::Size
    (rows, cols) = displaysize(d.out_stream)
    return Size(Int(cols), Int(rows))
end

"""
Read available bytes and hand them to `pump_input!`. Runs until the
channel closes.

`eof` blocks on a TTY (libuv yields the task) and returns immediately on
an exhausted `IOBuffer`, so the same loop serves production and tests
without a poll or a `sleep`.
"""
function _reader_loop!(d::TerminalDriver)::Nothing
    try
        while isopen(d.chan) && !eof(d.in_stream)
            bytes = readavailable(d.in_stream)
            isempty(bytes) && break
            pump_input!(d.parser, d.chan, bytes)
        end
    catch
        # The stream closed under us, or the channel did. Either way the
        # driver is going away; there is no one left to tell.
    end
    return nothing
end

"""
E4. Poll `displaysize(out_stream)` every `resize_poll` seconds and call
`notify_resize!` on a change.

Julia 1.12 exposes no `SIGWINCH` hook that is async-signal-safe from a
Julia callback, so this polls. It is behaviourally identical from the
app's side, and `notify_resize!` remains the public seam -- a real
signal handler or a web client injects the SAME event through the SAME
door.
"""
function _resize_loop!(d::TerminalDriver)::Nothing
    try
        while isopen(d.chan)
            sz = _query_size(d)
            sz === d.size || notify_resize!(d, sz)
            sleep(d.resize_poll)
        end
    catch
        # `put!` on a closed channel, or a dead stream. Nothing to do.
    end
    return nothing
end

"""
E4. Adopt `sz` as the cached size, then post it through the one door
every resize source shares.
"""
function notify_resize!(d::TerminalDriver, sz::Size)::Nothing
    d.size = sz
    put!(d.chan, ResizeEvent(sz))
    return nothing
end

"""
S1 + S2 + E4. Acquire the terminal. Idempotent.

NORMATIVE order -- `stop!`/`restore!` do EXACTLY the reverse, and the
ordering is part of the contract: leaving the alternate screen before
showing the cursor leaves an invisible cursor on the user's shell.

  1. `set_raw!(d, true)`
  2. `Ansi.ALT_SCREEN_ENTER`, gated on `caps.alt_screen`
  3. `Ansi.CURSOR_HIDE`
  4. `Ansi.MOUSE_ON` / `PASTE_ON` / `FOCUS_ON`, each gated on caps
  5. `flush!(d)`
  6. `d.size` from `displaysize(out_stream)` -- which returns
     `(rows, cols)` while `Size` is `(width, height)`. SWAP. This is a
     known off-by-orientation trap.
  7. spawn `_reader_loop!` and `_resize_loop!`
  8. `atexit(() -> restore!(d))`
  9. `put!(chan, ResizeEvent(d.size))`, so the app never special-cases
     the first frame.
"""
function start!(d::TerminalDriver,
                size_hint::Union{Nothing,Size} = nothing)::Nothing
    d.started && return nothing
    # Set before the first side effect: if any step below throws, the
    # `restore!` in the caller's `catch` must still undo what ran.
    d.started = true
    d.restored = false
    set_raw!(d, true)
    if d.caps.alt_screen
        _emit_str!(d, Ansi.ALT_SCREEN_ENTER)
        d.alt = true
    end
    _emit_str!(d, Ansi.CURSOR_HIDE)
    if d.caps.mouse
        _emit_str!(d, Ansi.MOUSE_ON)
        d.mouse_on = true
    end
    d.caps.bracketed_paste && _emit_str!(d, Ansi.PASTE_ON)
    d.caps.focus_events && _emit_str!(d, Ansi.FOCUS_ON)
    flush!(d)
    d.size = size_hint === nothing ? _query_size(d) : size_hint
    d.reader = @async _reader_loop!(d)
    d.resizer = @async _resize_loop!(d)
    atexit(() -> restore!(d))
    put!(d.chan, ResizeEvent(d.size))
    return nothing
end

"""
Stop the tasks, close the channel, then `restore!`. Idempotent.

Closing the channel is what stops both loops: each checks
`isopen(d.chan)` and each `put!`s into it.
"""
function stop!(d::TerminalDriver)::Nothing
    isopen(d.chan) && close(d.chan)
    restore!(d)
    d.reader = nothing
    d.resizer = nothing
    return nothing
end

"""
Turn focus reporting off. Internal.
"""
_disable_focus(d::TerminalDriver)::Nothing =
    (d.caps.focus_events && _emit_str!(d, Ansi.FOCUS_OFF); nothing)

"""
Turn bracketed paste off. Internal.
"""
_disable_paste(d::TerminalDriver)::Nothing =
    (d.caps.bracketed_paste && _emit_str!(d, Ansi.PASTE_OFF); nothing)

"""
Turn mouse reporting off. Internal.
"""
function _disable_mouse(d::TerminalDriver)::Nothing
    d.mouse_on || return nothing
    _emit_str!(d, Ansi.MOUSE_OFF)
    d.mouse_on = false
    return nothing
end

"""
Make the cursor visible again. Unconditional: `start!` hid it
unconditionally. Internal.
"""
_show_cursor(d::TerminalDriver)::Nothing =
    (_emit_str!(d, Ansi.CURSOR_SHOW); nothing)

"""
Leave the alternate screen, handing the user back their scrollback.
Internal.
"""
function _leave_alt(d::TerminalDriver)::Nothing
    d.alt || return nothing
    _emit_str!(d, Ansi.ALT_SCREEN_EXIT)
    d.alt = false
    return nothing
end

"""
S1. Leave raw mode. Internal.
"""
_unraw(d::TerminalDriver)::Nothing = (set_raw!(d, false); nothing)

"""
Push the staging buffer out. Internal.
"""
_flush_out(d::TerminalDriver)::Nothing = flush!(d)

"""
X3. Return the terminal to its pre-`start!` state.

Idempotent, and it MUST NOT throw: it runs inside a `catch`, inside a
`finally`, and from `atexit`. Every step runs even if an earlier one
throws, in this order:

    focus off, paste off, mouse off, show cursor, leave alt screen,
    unraw, flush
"""
function restore!(d::TerminalDriver)::Nothing
    d.started || return nothing
    d.restored && return nothing
    for f in (_disable_focus, _disable_paste, _disable_mouse,
              _show_cursor, _leave_alt, _unraw, _flush_out)
        try
            f(d)
        catch
            # X3: every step MUST run even if an earlier one throws.
            # Swallow; never mask the original error.
        end
    end
    d.restored = true
    return nothing
end

"""
Append `b` to the staging buffer; returns the bytes accepted.
"""
emit!(d::TerminalDriver, b::AbstractVector{UInt8})::Int =
    Int(write(d.outbuf, b))

"""
Write the staging buffer to `out_stream` and flush it.
"""
function flush!(d::TerminalDriver)::Nothing
    bytes = take!(d.outbuf)
    isempty(bytes) || write(d.out_stream, bytes)
    Base.flush(d.out_stream)
    return nothing
end

"""
The last observed renderable area.
"""
display_size(d::TerminalDriver)::Size = d.size

"""
What this terminal can do.
"""
capabilities(d::TerminalDriver)::DriverCaps = d.caps

"""
The event channel.
"""
events(d::TerminalDriver)::Channel{Event} = d.chan

"""
True while the driver can still deliver events.
"""
Base.isopen(d::TerminalDriver)::Bool = isopen(d.chan)

"""
Set the window title via OSC 0, gated on `caps.title`.
"""
function set_title!(d::TerminalDriver, s::AbstractString)::Nothing
    d.caps.title || return nothing
    _emit_str!(d, Ansi.title(s))
    return nothing
end
