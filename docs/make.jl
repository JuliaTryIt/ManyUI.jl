using Documenter
using DualUI

DocMeta.setdocmeta!(DualUI, :DocTestSetup, :(using DualUI);
                    recursive = true)

makedocs(;
    modules = [DualUI],
    sitename = "DualUI.jl",
    authors = "Sébastien Celles",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://s-celles.github.io/DualUI.jl",
        edit_link = nothing,
        repolink = nothing,
    ),
    # The package is not in a git checkout yet, so there is no remote to
    # infer source links from. Drop them rather than guess a URL that
    # would 404.
    remotes = nothing,
    pages = [
        "Home" => "index.md",
        "Concepts" => "concepts.md",
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
            "api/scrolling.md",
            "api/text.md",
            "api/data.md",
            "api/list.md",
            "api/tables.md",
        ],
    ],
    checkdocs = :exports,
    warnonly = false,
)
