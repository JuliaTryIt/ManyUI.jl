# precompile.jl -- layer 9.
#
# Locked invariant 1 fixes `[deps]` at DocStringExtensions,
# InlineStrings, REPL and Unicode, so PrecompileTools is NOT available
# here: use plain `precompile(f, argtypes)` directives rather than
# `@setup_workload` / `@compile_workload`.
#
# The workload to cover, once the pipeline exists, is one full frame on
# a `HeadlessDriver`: cascade, layout, paint, diff, encode, emit.

"""
Force compilation of the hot render path at precompile time.

Called once at the bottom of the module. Every directive is
best-effort: a `precompile` call that fails to resolve returns false
and is ignored.
"""
function _precompile!()
    nothing
end

_precompile!()
