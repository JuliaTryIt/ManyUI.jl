@testitem "popup: CENTER placement is independent of its owner" begin
    using ManyUI

    viewport = Size(80, 24)
    size = Size(34, 12)

    @test popup_region(Region(2, 3, 10, 1), size,
        PopupPlacement.CENTER, viewport) == Region(24, 7, 34, 12)
    @test popup_region(Region(70, 22, 8, 1), size,
        PopupPlacement.CENTER, viewport) == Region(24, 7, 34, 12)

    # Oversized centered dialogs are clipped to the viewport.
    @test popup_region(Region(1, 1, 1, 1), Size(120, 40),
        PopupPlacement.CENTER, viewport) == Region(1, 1, 80, 24)
end
