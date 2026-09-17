# PDFTopicSorter

Sort a collection of research PDFs into **themes → topics → subtopics** with one
token-efficient Claude call.

Instead of classifying PDFs one at a time, PDFTopicSorter extracts a title per file,
assigns each a compact code (`P001`, `P002`, …), compiles everything into a single
manifest document, and asks Claude Opus 5 to sort that document directly. The
result is a markdown outline where every group lists its members by code, plus a
machine-readable index (code → path → tags). Files on disk are not moved.

## Install

```julia
using Pkg
Pkg.develop(path="~/.julia/dev/PDFTopicSorter")   # or Pkg.add(url=...) once published
```

Poppler is bundled through `Poppler_jll`; no system install is needed.
Set your API key: `export ANTHROPIC_API_KEY=sk-ant-...`

## Use

```julia
using PDFTopicSorter

r = sort_pdfs("~/papers"; out="~/papers_sorted",
              prompt="Sort them according to topics and then sub topics, adding their code tags.")

print(r.markdown)      # the sorted outline
r.index                # rows of (code, path, title, theme, topic, subtopic)
r.usage                # token usage of the call
```

`out` receives `sorted.md`, `index.json`, `index.csv`, `manifest.txt` (exactly what
the model saw), `response.json`, and `usage.json`.

### Input as a data stream

`sort_pdfs` / `collect_sources` accept a directory, a single file, a vector of paths,
or any iterable / `Channel` yielding paths, `IO`s, `Vector{UInt8}`s, or
`name => bytes` pairs:

```julia
ch = Channel{Any}(32)
@async begin
    for (name, bytes) in my_stream
        put!(ch, name => bytes)
    end
    close(ch)
end
r = sort_pdfs(ch)
```

### Options

| keyword | default | meaning |
|---|---|---|
| `prompt` | "Sort them according to themes, topics, and then sub topics, adding their code tags." | your sorting instruction |
| `model` | `"claude-opus-5"` | any Messages API model id |
| `effort` | `"high"` | `output_config.effort`; `"medium"`/`"low"` for cheaper runs |
| `max_tokens` | `16000` | raise for very large corpora |
| `allow_peek` | `true` | let the model call `peek_pdf(code)` to read an ambiguous document's opening text |
| `max_peeks` | `20` | budget for those tool calls |
| `snippet_chars` | `0` | append the first N chars of each PDF to its manifest line (costs tokens, helps with vague titles) |
| `code_prefix` | `"P"` | code prefix |
| `out` | `nothing` | directory for run artifacts |
| `api_key` / `client` | env | connection settings |

### Lower-level pieces

```julia
sources = collect_sources("~/papers")          # Vector{PDFSource} with codes
extract!(sources; snippet_chars=200)           # titles via Poppler
m = compile_manifest(sources)                  # the single document
println(m.text)                                # inspect before spending tokens
tax, resp = sort_manifest(m; prompt="...")     # Taxonomy + raw API response
md = render_markdown(tax, m); rows = build_index(tax, m)
```

## How titles are found

1. PDF metadata `Title`, unless it looks like junk (empty, `Microsoft Word - …`, a
   filename, mostly digits, …).
2. Otherwise the first block of page-1 text, after dropping running headers, DOIs,
   and page numbers. The block ends at the first author byline (all-caps names, or
   mixed-case names with initials) or "This paper was presented…" boilerplate, and
   generic section labels ("Technical Note", "Discussion", "Spec/Manual Reference")
   are skipped or trimmed.
3. Otherwise the filename stem. PDFs without a text layer are flagged
   `(no text layer)` in the manifest.

## Validation

Every code must appear exactly once. Codes the model invents are dropped, duplicate
placements keep the first, and codes it omitted are appended to an **Unsorted**
section, each with a warning.

## Tests

```julia
Pkg.test("PDFTopicSorter")
```

Tests run offline: fixture PDFs are generated on the fly and API responses are canned.

## Not yet

OCR for scanned PDFs, chunk-and-merge for corpora beyond a few thousand files,
copying files into a folder tree, writing tags into PDF metadata.
