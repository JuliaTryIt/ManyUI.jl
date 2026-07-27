default:
	@just --list

test:
	julia --project=@. -e 'using Pkg; Pkg.test()'

instantiate:
	julia --project=@. -e 'using Pkg; Pkg.instantiate()'

dev:
	julia --project=@.
