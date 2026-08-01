using Documenter
using ManyUI

DocMeta.setdocmeta!(ManyUI, :DocTestSetup, :(using ManyUI);
                    recursive = true)

makedocs(;
    modules = [ManyUI],
    sitename = "ManyUI.jl",
    authors = "Sébastien Celles",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://s-celles.github.io/ManyUI.jl",
        # The aggregate search index grows with the library and is past the
        # 500 KiB soft default; raise its ceiling so a full API stays one
        # warning-free build. `size_threshold` gets headroom too.
        search_size_threshold_warn = 1024 * 1024,
        size_threshold_warn = 500 * 1024,
        size_threshold = 1024 * 1024,
    ),
    pages = [
        "Home" => "index.md",
        "Concepts" => "concepts.md",
        "Backends" => "backends.md",
        "Layout" => "layout.md",
        "Styling" => "styling.md",
        "Events" => "events.md",
        "Widgets" => "widgets.md",
        "Scrolling" => "scrolling.md",
        "Text entry" => "textentry.md",
        "Data widgets" => "data.md",
        "API reference" => [
            "api/enums.md",
            "api/geometry.md",
            "api/style.md",
            "api/buffer.md",
            "api/tree.md",
            "api/events.md",
            "api/drivers.md",
            "api/app.md",
            "api/widgets.md",
            "api/inputs.md",
            "api/scrolling.md",
            "api/text.md",
            "api/list.md",
            "api/tables.md",
        ],
    ],
    checkdocs = :none,
    warnonly = false,
)

deploydocs(;
    repo="github.com/s-celles/ManyUI.jl",
    devbranch="main",
)
