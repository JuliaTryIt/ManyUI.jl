# Enumerations

```@meta
CurrentModule = DualUI
```

Every finite value set in DualUI is a module-scoped enum: a module
holding an `@enum T` with `SCREAMING_SNAKE_CASE` values. They
tab-complete (`ColorDepth.<TAB>`), discriminate by type
(`d isa ColorDepth.T`), and keep their value names out of the package
namespace.

```@docs
Align
Attr
BorderKind
CheckState
ColorDepth
ColorKind
Combinator
Dimension
Direction
Dirty
Display
Justify
Key
Modifier
MouseAction
MouseButton
Overflow
Phase
ScrollAxis
ScrollMode
SelectMode
SelectorKind
SortDir
```

## ANSI constants

```@docs
Ansi
```
