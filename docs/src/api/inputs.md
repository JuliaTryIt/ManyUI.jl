# Drop-down, forms and popups

```@meta
CurrentModule = ManyUI
```

## Drop-down

```@autodocs
Modules = [ManyUI]
Pages = ["widgets/dropdown.jl"]
```

## Form

```@autodocs
Modules = [ManyUI]
Pages = ["widgets/form.jl"]
```

## Popups

A popup is a second root painted over the tree and hit-tested before it --
the layer a [`DropDown`](@ref)'s list rides on. The `App` owns the one open
popup; an owner opens it with `open_popup!` and is notified through
`on_popup_close!`.

```@autodocs
Modules = [ManyUI]
Pages = ["widgets/popup.jl", "popup_ops.jl"]
```
