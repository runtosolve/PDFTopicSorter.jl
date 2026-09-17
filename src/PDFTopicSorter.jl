"""
    PDFTopicSorter

Sort a collection of PDFs into research themes, topics, and subtopics with one
token-efficient Claude call.

Pipeline: ingest PDFs (directory, paths, or an in-memory stream) → extract a title
per file with Poppler → assign compact codes (`P001`, `P002`, …) → compile one
manifest document (`CODE | title` per line) → ask Claude to sort the manifest into
a theme > topic > subtopic taxonomy tagged with codes → render markdown and a
machine-readable index.

Entry point: [`sort_pdfs`](@ref).
"""
module PDFTopicSorter

using Dates, Logging
using HTTP, JSON
using Poppler_jll

export PDFSource, Manifest, Group, Taxonomy, SortResult, Client, AnthropicError
export collect_sources, extract!, describe_pdf!, compile_manifest
export sort_pdfs, sort_manifest, render_markdown, build_index, write_index, write_run

include("ingest.jl")
include("extract.jl")
include("manifest.jl")
include("anthropic.jl")
include("sort.jl")
include("output.jl")

end # module
