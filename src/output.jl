# Rendering: markdown outline, code → tags index, run artifacts.

function _items(io::IO, codes::AbstractVector{String}, by::AbstractDict)
    isempty(codes) && return
    for c in codes
        s = get(by, c, nothing)
        if s === nothing
            println(io, "- [", c, "]")
        else
            println(io, "- [", c, "] ", s.title, "  (", s.name, ")")
        end
    end
    println(io)
end

"""
    render_markdown(tax::Taxonomy, m::Manifest) -> String

`# Theme`, `## Topic`, `### Subtopic` headings with `- [CODE] Title  (filename)` items,
plus an `## Unsorted` section when needed.
"""
function render_markdown(tax::Taxonomy, m::Manifest)
    by = lookup(m)
    io = IOBuffer()
    println(io, "<!-- ", length(m), " documents sorted by PDFTopicSorter on ", Dates.format(now(), "yyyy-mm-dd"), " -->\n")
    for t in tax.themes
        println(io, "# ", t.name, "\n")
        _items(io, t.codes, by)
        for tp in t.children
            println(io, "## ", tp.name, "\n")
            _items(io, tp.codes, by)
            for s in tp.children
                println(io, "### ", s.name, "\n")
                _items(io, s.codes, by)
            end
        end
    end
    if !isempty(tax.unsorted)
        println(io, "## Unsorted\n")
        _items(io, tax.unsorted, by)
    end
    return String(take!(io))
end

const IndexRow = NamedTuple{(:code, :path, :title, :theme, :topic, :subtopic),NTuple{6,String}}

"""
    build_index(tax::Taxonomy, m::Manifest) -> Vector{IndexRow}

One row per document: `(code, path, title, theme, topic, subtopic)`, in taxonomy order.
Unplaced documents get theme `"Unsorted"`.
"""
function build_index(tax::Taxonomy, m::Manifest)
    by = lookup(m)
    rows = IndexRow[]
    row(c, theme, topic, sub) = begin
        s = get(by, c, nothing)
        push!(rows, (code=c, path=s === nothing ? "" : s.path, title=s === nothing ? "" : s.title,
                     theme=theme, topic=topic, subtopic=sub))
    end
    for t in tax.themes
        foreach(c -> row(c, t.name, "", ""), t.codes)
        for tp in t.children
            foreach(c -> row(c, t.name, tp.name, ""), tp.codes)
            for s in tp.children
                foreach(c -> row(c, t.name, tp.name, s.name), s.codes)
            end
        end
    end
    foreach(c -> row(c, "Unsorted", "", ""), tax.unsorted)
    return rows
end

tags(rows::AbstractVector{IndexRow}, code::AbstractString) = filter(r -> r.code == code, rows)

csv_field(s::AbstractString) = occursin(r"[\",\n\r]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s

"""
    write_index(rows, path)

Write the index as JSON (`.json`) or CSV (any other extension).
"""
function write_index(rows::AbstractVector{IndexRow}, path::AbstractString)
    if lowercase(splitext(path)[2]) == ".json"
        write(path, JSON.json(rows))
    else
        open(path, "w") do io
            println(io, "code,path,title,theme,topic,subtopic")
            for r in rows
                println(io, join(csv_field.((r.code, r.path, r.title, r.theme, r.topic, r.subtopic)), ","))
            end
        end
    end
    return path
end

"""
    write_run(dir, m, tax, markdown, rows, resp) -> dir

Persist a full run for reproducibility: `sorted.md`, `index.json`, `index.csv`,
`manifest.txt`, `response.json`, `usage.json`.
"""
function write_run(dir::AbstractString, m::Manifest, tax::Taxonomy, markdown::AbstractString,
                   rows::AbstractVector{IndexRow}, resp::AbstractDict)
    mkpath(dir)
    write(joinpath(dir, "sorted.md"), markdown)
    write_index(rows, joinpath(dir, "index.json"))
    write_index(rows, joinpath(dir, "index.csv"))
    write(joinpath(dir, "manifest.txt"), m.text)
    write(joinpath(dir, "response.json"), JSON.json(resp))
    write(joinpath(dir, "usage.json"), JSON.json(usage_tuple(resp)))
    @info "Run written" dir
    return String(dir)
end
