# Drop-down, forms and popups

```@meta
CurrentModule = DualUI
```

## Drop-down

```@autodocs
Modules = [DualUI]
Pages = ["widgets/dropdown.jl"]
```

## Form

```@autodocs
Modules = [DualUI]
Pages = ["widgets/form.jl"]
```

## Popups

A popup is a second root painted over the tree and hit-tested before it --
the layer a [`DropDown`](@ref)'s list rides on. The `App` owns the one open
popup; an owner opens it with `open_popup!` and is notified through
`on_popup_close!`.

```@autodocs
Modules = [DualUI]
Pages = ["widgets/popup.jl", "popup_ops.jl"]
```
