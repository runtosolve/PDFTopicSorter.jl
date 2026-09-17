# Intake of the PDF "data stream" into a vector of PDFSource records.

"""
    PDFSource

One input PDF. Created by [`collect_sources`](@ref) with only `code`, `path`, and
`name` filled; [`extract!`](@ref) fills `title`, `snippet`, `meta`, and `has_text`.
"""
mutable struct PDFSource
    code::String                 # compact tag, e.g. "P001"
    path::String                 # on-disk path (temp file when the input was in memory)
    name::String                 # display name: original filename or stream label
    title::String
    snippet::String
    meta::Dict{String,String}    # pdfinfo fields (Title, Author, Pages, ...)
    has_text::Bool               # false => no text layer (scanned) or unreadable
end

PDFSource(code, path, name) = PDFSource(code, path, name, "", "", Dict{String,String}(), false)

Base.show(io::IO, s::PDFSource) = print(io, "PDFSource(", s.code, ", \"", s.name, "\"",
    isempty(s.title) ? "" : ", title=\"" * s.title * "\"", ")")

ispdf(path::AbstractString) = occursin(r"\.pdf$"i, path)

"""
    find_pdfs(dir; recursive=true) -> Vector{String}

Sorted list of `*.pdf` files under `dir`.
"""
function find_pdfs(dir::AbstractString; recursive::Bool=true)
    out = String[]
    if recursive
        for (root, _, files) in walkdir(dir)
            for f in files
                ispdf(f) && push!(out, joinpath(root, f))
            end
        end
    else
        for f in readdir(dir; join=true)
            isfile(f) && ispdf(f) && push!(out, f)
        end
    end
    return sort!(out)
end

code_width(n::Integer) = max(3, ndigits(n))
make_code(prefix::AbstractString, i::Integer, width::Integer) = string(prefix, lpad(i, width, '0'))

# ---- staging: turn one stream item into (name, path) ----------------------------

_stage(item::AbstractString, tmp, i) = (basename(item), abspath(item))
_stage(item::PDFSource, tmp, i) = (item.name, item.path)

function _stage_bytes(name::AbstractString, bytes::AbstractVector{UInt8}, tmp)
    fname = ispdf(name) ? basename(name) : basename(name) * ".pdf"
    path = joinpath(tmp[], fname)
    # avoid collisions between identically named streams
    k = 1
    while isfile(path)
        k += 1
        path = joinpath(tmp[], string(splitext(fname)[1], "_", k, ".pdf"))
    end
    write(path, bytes)
    return (basename(name), path)
end

_stage(item::AbstractVector{UInt8}, tmp, i) = _stage_bytes("stream_$i.pdf", item, tmp)
_stage(item::IO, tmp, i) = _stage_bytes("stream_$i.pdf", read(item), tmp)
_stage(item::Pair{<:AbstractString}, tmp, i) = _stage_named(item.first, item.second, tmp, i)
_stage(item::Tuple{<:AbstractString,<:Any}, tmp, i) = _stage_named(item[1], item[2], tmp, i)

_stage_named(name, bytes::AbstractVector{UInt8}, tmp, i) = _stage_bytes(name, bytes, tmp)
_stage_named(name, io::IO, tmp, i) = _stage_bytes(name, read(io), tmp)
_stage_named(name, path::AbstractString, tmp, i) = (String(name), abspath(path))

"""
    collect_sources(input; code_prefix="P", recursive=true) -> Vector{PDFSource}

Turn the input stream into `PDFSource` records with codes assigned.

`input` may be a directory path (recursive search for `*.pdf`), a single PDF path,
a vector of paths, or any iterable / `Channel` whose items are paths, `IO`s,
`Vector{UInt8}`s, or `name => bytes` / `(name, bytes)` pairs. In-memory items are
written to a temporary directory so Poppler can read them.

File and directory inputs are sorted so codes are stable across runs; generic
iterables keep their arrival order.
"""
function collect_sources(input; code_prefix::AbstractString="P", recursive::Bool=true)
    staged = Tuple{String,String}[]
    lazy = LazyTmp(Ref{String}())   # temp dir for in-memory items, created on first use

    if input isa AbstractString
        if isdir(input)
            for p in find_pdfs(input; recursive)
                push!(staged, (basename(p), abspath(p)))
            end
        elseif isfile(input)
            push!(staged, (basename(input), abspath(input)))
        else
            throw(ArgumentError("no such file or directory: $input"))
        end
    elseif input isa AbstractVector{<:AbstractString}
        for p in sort(String.(input))
            if isdir(p)
                for q in find_pdfs(p; recursive)
                    push!(staged, (basename(q), abspath(q)))
                end
            else
                isfile(p) || throw(ArgumentError("no such file: $p"))
                push!(staged, (basename(p), abspath(p)))
            end
        end
    else
        for (i, item) in enumerate(input)
            push!(staged, _stage(item, lazy, i))
        end
    end

    n = length(staged)
    width = code_width(n)
    return [PDFSource(make_code(code_prefix, i, width), path, name) for (i, (name, path)) in enumerate(staged)]
end

# A Ref-like that creates the temp directory on first access.
struct LazyTmp
    ref::Ref{String}
end
function Base.getindex(t::LazyTmp)
    isassigned(t.ref) || (t.ref[] = mktempdir(; prefix="pdftopicsorter_"))
    return t.ref[]
end
