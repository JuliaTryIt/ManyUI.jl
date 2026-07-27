# Backends

A [`Driver`](@ref) makes targets swappable. A [`Backend`](@ref) makes them
swappable *without editing the call*.

## One verb

[`launch`](@ref) runs an app on any target:

```julia
using ManyUI

ui() = Container(Label("hello"))

launch(ui)                                   # this terminal
launch(ui; backend = HeadlessBackend())      # nothing attached
```

With `ManyUIWeb` loaded, the same app runs in a browser and the *only*
thing that changes is the backend argument:

```julia
using ManyUI, ManyUIWeb

launch(ui; backend = WebBackend(port = 8000))
```

Nothing else moves. `config` and `stylesheet` describe the **app**, so they
are spelled the same way whatever the target; a port or a tty describes the
**target**, so it lives on the backend.

## Why a factory

`launch` takes `() -> Widget` — a function that builds a tree — not a tree:

```julia
launch(ui)          # yes
launch(ui())        # no
```

A terminal needs one app. A browser needs **one app per connected client**,
each with its own tree, and it cannot know how many until they arrive. Only
a factory serves both, which is why it is the universal unit rather than a
convenience. It is also what keeps sessions isolated: two browsers share no
mutable state because each got its own `factory()` call.

## Blocking, and the handle

By default `launch` blocks until the app quits and returns an exit code,
like [`run!`](@ref):

```julia
code = launch(ui)     # returns when the user quits
```

Pass `wait = false` to keep going and get a handle back:

```julia
h = launch(ui; wait = false)
isopen(h)     # still going?
close(h)      # ask it to stop
wait(h)       # block until it has
```

The handle's *type* is the backend's business — an [`App`](@ref) for a
terminal, a `WebServer` for the web — but every handle answers those same
three verbs, so code that starts and stops an app need not know which
backend it got. A handle is **live when you get it**: `launch` does not
return until the loop is actually up, so `isopen(h)` is true on the next
line and a `close` cannot race the loop into existence.

## Writing a backend

Two things, and nothing else:

```julia
struct MyBackend <: ManyUI.Backend end
ManyUI.make_driver(::MyBackend) = MyDriver()
```

That is the whole contract for a target with one driver. There is no
fallback for [`make_driver`](@ref) on purpose: a backend that forgets it
gets a `MethodError` naming the type, rather than a silent default driver
writing to somebody's terminal.

A backend whose target **multiplexes** — one app per client, as the web
does — has no single driver to make, so it defines its own `launch` method
instead and never implements `make_driver`. `ManyUIWeb.WebBackend` is the
worked example, and it lives in another package entirely: a backend joins
by dispatch, with no cooperation from ManyUI beyond the abstract type.

## The old entry points still work

`launch` is a convenience over the seam, not a replacement for it. This
still means exactly what it always did, and is what you want when you have
a driver in hand rather than a description of one:

```julia
run!(App(ui(), TerminalDriver()))
```

## Reference

```@docs
Backend
TerminalBackend
HeadlessBackend
make_driver
launch
```
