# The single compact document the agent sorts.

"""
    Manifest

The compiled `CODE | title` document plus the sources it was built from.
"""
struct Manifest
    sources::Vector{PDFSource}
    text::String
end

Base.length(m::Manifest) = length(m.sources)
codes(m::Manifest) = [s.code for s in m.sources]
lookup(m::Manifest) = Dict(s.code => s for s in m.sources)

# Keep the pipe delimiter unique to the manifest format.
clean_field(s::AbstractString) = replace(flatten_ws(s), "|" => "/")

function manifest_line(s::PDFSource; include_snippet::Bool=false)
    t = s.title
    s.has_text || (t *= " (no text layer)")
    line = string(s.code, " | ", clean_field(t))
    if include_snippet && !isempty(s.snippet)
        line *= " | " * clean_field(s.snippet)
    end
    return line
end

estimate_tokens(s::AbstractString) = cld(length(s), 4)

"""
    compile_manifest(sources; include_snippet=false) -> Manifest

One line per PDF: `CODE | title [| snippet]`, preceded by a one-line header.
"""
function compile_manifest(sources::AbstractVector{PDFSource}; include_snippet::Bool=false)
    io = IOBuffer()
    print(io, "# ", length(sources), " documents. Format: CODE | title")
    include_snippet && print(io, " | snippet")
    println(io)
    for s in sources
        println(io, manifest_line(s; include_snippet))
    end
    text = String(take!(io))
    @info "Manifest compiled" documents = length(sources) approx_tokens = estimate_tokens(text)
    return Manifest(collect(sources), text)
end
