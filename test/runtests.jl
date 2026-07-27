using TestItemRunner

@testitem "Aqua.jl" begin
    import Aqua
    import ManyUI
    Aqua.test_all(ManyUI)
end

@run_package_tests
