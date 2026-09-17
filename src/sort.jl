# Prompt, output schema, the sorting call, and validation of the returned taxonomy.

"""
    Group(name, codes, children)

A node of the taxonomy. Depth gives the level: theme → topic → subtopic. `codes`
are documents placed directly at this node.
"""
struct Group
    name::String
    codes::Vector{String}
    children::Vector{Group}
end
Group(name, codes) = Group(String(name), String.(codes), Group[])

"""
    Taxonomy(themes, unsorted)

The sorted result: top-level theme groups plus codes the model (or validation)
could not place.
"""
struct Taxonomy
    themes::Vector{Group}
    unsorted::Vector{String}
end

all_codes(g::Group) = vcat(g.codes, (all_codes(c) for c in g.children)...)
all_codes(t::Taxonomy) = vcat((all_codes(g) for g in t.themes)..., t.unsorted)

const DEFAULT_PROMPT = "Sort them according to themes, topics, and then sub topics, adding their code tags."

const SYSTEM_PROMPT = """
You are a research librarian organizing a collection of documents. The user gives you a
manifest with one line per document: a short code, then the title (and sometimes a snippet).

Sort every document into a hierarchy of research themes, topics within each theme, and
subtopics within each topic. Rules:
- Use only the codes that appear in the manifest, and place every code exactly once.
- Name groups specifically enough that a researcher recognizes the subject; avoid vague
  labels like "Miscellaneous" or "Other".
- Prefer a small number of themes. A topic may hold documents directly (empty `subtopics`)
  when splitting further is not warranted. Put codes directly under a theme only rarely.
- If a title is too ambiguous to place and a `peek_pdf` tool is available, you may call it
  to read the document's opening text. Use it sparingly.
- Put a code in `unsorted` only if you truly cannot place it.
Respond with the taxonomy in the required JSON format.
"""

const CODES_SCHEMA = Dict{String,Any}("type" => "array", "items" => Dict{String,Any}("type" => "string"))

const TAXONOMY_SCHEMA = Dict{String,Any}(
    "type" => "object", "additionalProperties" => false, "required" => ["themes", "unsorted"],
    "properties" => Dict{String,Any}(
        "themes" => Dict{String,Any}("type" => "array", "items" => Dict{String,Any}(
            "type" => "object", "additionalProperties" => false, "required" => ["name", "codes", "topics"],
            "properties" => Dict{String,Any}(
                "name" => Dict{String,Any}("type" => "string", "description" => "Research theme"),
                "codes" => merge(CODES_SCHEMA, Dict("description" => "Codes placed directly under the theme (rare)")),
                "topics" => Dict{String,Any}("type" => "array", "items" => Dict{String,Any}(
                    "type" => "object", "additionalProperties" => false, "required" => ["name", "codes", "subtopics"],
                    "properties" => Dict{String,Any}(
                        "name" => Dict{String,Any}("type" => "string", "description" => "Topic within the theme"),
                        "codes" => merge(CODES_SCHEMA, Dict("description" => "Codes placed directly under the topic")),
                        "subtopics" => Dict{String,Any}("type" => "array", "items" => Dict{String,Any}(
                            "type" => "object", "additionalProperties" => false, "required" => ["name", "codes"],
                            "properties" => Dict{String,Any}(
                                "name" => Dict{String,Any}("type" => "string", "description" => "Subtopic"),
                                "codes" => merge(CODES_SCHEMA, Dict("description" => "Codes in this subtopic")),
                            ))))))))),
        "unsorted" => merge(CODES_SCHEMA, Dict("description" => "Codes that could not be placed")),
    ))

const PEEK_TOOL = Dict{String,Any}(
    "name" => "peek_pdf",
    "description" => "Return the opening text (first pages) of one document when its title alone is too ambiguous to place. Use sparingly.",
    "strict" => true,
    "input_schema" => Dict{String,Any}(
        "type" => "object", "additionalProperties" => false, "required" => ["code"],
        "properties" => Dict{String,Any}("code" => Dict{String,Any}(
            "type" => "string", "description" => "The document code from the manifest, e.g. P012"))))

"""
    peek_pdf(m::Manifest, input; chars=1500) -> String

Tool implementation: opening text of the document with code `input["code"]`.
"""
function peek_pdf(m::Manifest, input::AbstractDict; chars::Int=1500, timeout::Real=60)
    code = String(get(input, "code", ""))
    src = get(lookup(m), code, nothing)
    src === nothing && return "Unknown code: $code"
    text = try
        run_capture(pdftotext_cmd(src.path; last=2); timeout)
    catch e
        return "Could not read $code ($(src.name)): $(sprint(showerror, e))"
    end
    flat = flatten_ws(text)
    isempty(flat) && return "$code has no text layer (scanned document). Filename: $(src.name)"
    return string(code, " (", src.name, "): ", first(flat, chars))
end

"""
    build_request(m::Manifest; prompt, model, effort, max_tokens, allow_peek) -> Dict

The Messages API request body. The manifest goes first, with a cache breakpoint, so
re-sorting the same corpus with a different prompt can reuse the cached prefix.
"""
function build_request(m::Manifest; prompt::AbstractString=DEFAULT_PROMPT, model::AbstractString=DEFAULT_MODEL,
                       effort::Union{Nothing,AbstractString}="high", max_tokens::Int=16_000, allow_peek::Bool=true)
    user_content = Any[
        Dict{String,Any}("type" => "text", "text" => "<manifest>\n" * m.text * "</manifest>",
                         "cache_control" => Dict("type" => "ephemeral")),
        Dict{String,Any}("type" => "text", "text" => String(prompt)),
    ]
    output_config = Dict{String,Any}("format" => Dict{String,Any}("type" => "json_schema", "schema" => TAXONOMY_SCHEMA))
    effort === nothing || (output_config["effort"] = String(effort))
    body = Dict{String,Any}(
        "model" => String(model),
        "max_tokens" => max_tokens,
        "system" => SYSTEM_PROMPT,
        "messages" => Any[Dict{String,Any}("role" => "user", "content" => user_content)],
        "output_config" => output_config,
    )
    allow_peek && (body["tools"] = Any[PEEK_TOOL])
    return body
end

function parse_taxonomy(j::AbstractDict)
    themes = Group[]
    for t in get(j, "themes", Any[])
        topics = Group[]
        for tp in get(t, "topics", Any[])
            subs = Group[Group(s["name"], get(s, "codes", Any[])) for s in get(tp, "subtopics", Any[])]
            push!(topics, Group(String(tp["name"]), String.(get(tp, "codes", Any[])), subs))
        end
        push!(themes, Group(String(t["name"]), String.(get(t, "codes", Any[])), topics))
    end
    return Taxonomy(themes, String.(get(j, "unsorted", Any[])))
end

"""
    validate(tax::Taxonomy, valid_codes) -> (Taxonomy, report)

Drop codes not in the manifest, keep only the first placement of duplicated codes,
append codes missing from the tree to `unsorted`, and prune groups left empty.
`report` is a NamedTuple `(dropped, duplicates, missing)`.
"""
function validate(tax::Taxonomy, valid::AbstractVector{<:AbstractString})
    validset = Set(String.(valid))
    seen = Set{String}()
    dropped = String[]; dups = String[]

    function fix(codes)
        out = String[]
        for c in codes
            if !(c in validset)
                push!(dropped, c)
            elseif c in seen
                push!(dups, c)
            else
                push!(seen, c); push!(out, c)
            end
        end
        return out
    end
    function fixg(g::Group)
        cs = fix(g.codes)                            # this node's codes first
        kids = Group[fixg(c) for c in g.children]
        filter!(k -> !(isempty(k.codes) && isempty(k.children)), kids)
        return Group(g.name, cs, kids)
    end

    themes = Group[fixg(t) for t in tax.themes]
    filter!(t -> !(isempty(t.codes) && isempty(t.children)), themes)
    unsorted = fix(tax.unsorted)
    missing_codes = [c for c in valid if !(c in seen)]
    append!(unsorted, missing_codes)

    isempty(dropped) || @warn "Dropped codes not present in the manifest" dropped
    isempty(dups) || @warn "Codes placed more than once; kept the first placement" duplicates = dups
    isempty(missing_codes) || @warn "Codes missing from the taxonomy; appended to Unsorted" missing = missing_codes
    return Taxonomy(themes, unsorted), (dropped=dropped, duplicates=dups, missing=missing_codes)
end

"""
    sort_manifest(m::Manifest; kwargs...) -> (Taxonomy, response::Dict)

Ask the model to sort the manifest. Keywords:

- `prompt`: the user's sorting instruction (default `DEFAULT_PROMPT`).
- `model`, `effort`, `max_tokens`: request settings (defaults `claude-opus-5`, `"high"`, 16000).
- `allow_peek`, `max_peeks`, `peek_chars`: the `peek_pdf` tool and its budget.
- `client` / `api_key`: connection settings; or `call(body) -> response` to bypass HTTP.
"""
function sort_manifest(m::Manifest; prompt::AbstractString=DEFAULT_PROMPT, model::AbstractString=DEFAULT_MODEL,
                       effort::Union{Nothing,AbstractString}="high", max_tokens::Int=16_000,
                       allow_peek::Bool=true, max_peeks::Int=20, peek_chars::Int=1500,
                       client::Union{Nothing,Client}=nothing, api_key=nothing, call::Union{Nothing,Function}=nothing)
    isempty(m.sources) && throw(ArgumentError("manifest is empty"))
    if call === nothing
        c = client === nothing ? Client(; api_key) : client
        call = body -> messages(c, body)
    end
    body = build_request(m; prompt, model, effort, max_tokens, allow_peek)
    tools = allow_peek ? Dict{String,Function}("peek_pdf" => input -> peek_pdf(m, input; chars=peek_chars)) :
                         Dict{String,Function}()

    @info "Sorting manifest" documents = length(m) model approx_input_tokens = estimate_tokens(m.text)
    resp = run_tool_loop(call, body, tools; max_tool_calls=max_peeks)

    stop = get(resp, "stop_reason", "")
    stop == "refusal" && error("The model refused the request: $(get(resp, "stop_details", nothing))")
    stop == "max_tokens" && error("Response truncated at max_tokens=$max_tokens; raise `max_tokens`.")

    text = response_text(resp)
    isempty(strip(text)) && error("Empty response from the model (stop_reason=$stop)")
    tax = parse_taxonomy(JSON.parse(text))
    tax, _ = validate(tax, codes(m))
    return tax, resp
end

"""
    SortResult

Everything produced by [`sort_pdfs`](@ref).
"""
struct SortResult
    manifest::Manifest
    taxonomy::Taxonomy
    markdown::String
    index::Vector{NamedTuple{(:code, :path, :title, :theme, :topic, :subtopic),NTuple{6,String}}}
    usage::NamedTuple
    raw_response::String
    run_dir::Union{Nothing,String}
end

function Base.show(io::IO, r::SortResult)
    print(io, "SortResult(", length(r.manifest), " documents, ", length(r.taxonomy.themes), " themes",
          isempty(r.taxonomy.unsorted) ? "" : ", $(length(r.taxonomy.unsorted)) unsorted",
          "; ", r.usage.input_tokens, " in / ", r.usage.output_tokens, " out tokens)")
end

"""
    sort_pdfs(input; out=nothing, snippet_chars=0, code_prefix="P", recursive=true,
              ntasks=..., timeout=60, kwargs...) -> SortResult

End-to-end: ingest `input` (see [`collect_sources`](@ref)), extract titles, compile the
manifest, sort it with the model, render markdown and an index. When `out` is a
directory, write `sorted.md`, `index.json`, `index.csv`, `manifest.txt`, `response.json`,
and `usage.json` there. Remaining keywords go to [`sort_manifest`](@ref).
"""
function sort_pdfs(input; out::Union{Nothing,AbstractString}=nothing, snippet_chars::Int=0,
                   code_prefix::AbstractString="P", recursive::Bool=true,
                   ntasks::Int=max(1, Sys.CPU_THREADS ÷ 2), timeout::Real=60, kwargs...)
    sources = collect_sources(input; code_prefix, recursive)
    isempty(sources) && throw(ArgumentError("no PDFs found in the input"))
    extract!(sources; ntasks, snippet_chars, timeout)
    m = compile_manifest(sources; include_snippet=snippet_chars > 0)
    tax, resp = sort_manifest(m; kwargs...)
    md = render_markdown(tax, m)
    idx = build_index(tax, m)
    usage = usage_tuple(resp)
    run_dir = out === nothing ? nothing : write_run(out, m, tax, md, idx, resp)
    return SortResult(m, tax, md, idx, usage, JSON.json(resp), run_dir)
end
