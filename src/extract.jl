# Title / snippet extraction with Poppler's pdfinfo and pdftotext.

pdfinfo_cmd(path) = `$(Poppler_jll.pdfinfo()) -enc UTF-8 $path`
pdftotext_cmd(path; first::Int=1, last::Int=2) =
    `$(Poppler_jll.pdftotext()) -f $first -l $last -enc UTF-8 -q $path -`

"""
    run_capture(cmd; timeout=60) -> String

Run `cmd`, return its stdout, kill it after `timeout` seconds. Throws on non-zero exit.
"""
function run_capture(cmd::Cmd; timeout::Real=60)
    killed = Ref(false)
    proc = open(pipeline(ignorestatus(cmd); stderr=devnull), "r")
    timer = Timer(timeout) do _
        if process_running(proc)
            killed[] = true
            kill(proc)
        end
    end
    local out::String
    try
        out = read(proc, String)
        wait(proc)
    finally
        close(timer)
    end
    if proc.exitcode != 0
        exe = basename(cmd.exec[1])
        killed[] && error("`$exe` timed out after $(timeout)s")
        error("`$exe` exited with code $(proc.exitcode)")
    end
    return out
end

function parse_pdfinfo(s::AbstractString)
    d = Dict{String,String}()
    for line in eachline(IOBuffer(s))
        m = match(r"^([A-Za-z][A-Za-z0-9 _\-]*):\s*(.*)$", line)
        m === nothing && continue
        d[String(m[1])] = String(strip(m[2]))
    end
    return d
end

# ---- title heuristics ------------------------------------------------------------

const JUNK_TITLE_PATTERNS = [
    r"^untitled"i,
    r"microsoft (word|powerpoint)"i,
    r"\.(docx?|tex|dvi|pdf|ps|indd|qxd|pptx?)\b"i,
    r"^(doi|https?://|www\.)"i,
    r"^slide 1"i,
    r"^(draft|paper|manuscript|final|revised|thesis|report|document)\d*$"i,
    r"^\d+([-_.]\d+)*$",
]

letter_fraction(s) = isempty(s) ? 0.0 : count(isletter, s) / length(s)

"""
    isjunk_title(title, stem) -> Bool

True when a PDF metadata title is not usable (empty, generic, a filename, mostly digits).
"""
function isjunk_title(title::AbstractString, stem::AbstractString)
    s = strip(title)
    isempty(s) && return true
    length(s) < 8 && return true
    length(s) > 250 && return true
    lowercase(s) == lowercase(strip(stem)) && return true
    any(p -> occursin(p, s), JUNK_TITLE_PATTERNS) && return true
    letter_fraction(s) < 0.5 && return true
    return false
end

const HEADER_LINE_PATTERNS = [
    r"\bdoi\b"i, r"https?://", r"www\.", r"^\d+$", r"©|copyright"i,
    r"^(vol\.?|volume|no\.?|issue)\b"i, r"downloaded (from|by)"i, r"available online"i,
    r"^arxiv"i, r"^page \d"i, r"^\d{1,2}(st|nd|rd|th)? .*(conference|symposium)"i,
    r"^(journal|proceedings) of .{0,60}$"i, r"\bissn\b"i, r"^see discussions"i,
    r"^\d{4}[-–]\d{2}"i, r"^[\d\s.,;:()\-–/]+$",
]

looks_like_header(line::AbstractString) =
    length(strip(line)) < 4 || any(p -> occursin(p, line), HEADER_LINE_PATTERNS)

# Lines that end a title block: author bylines (mostly upper-case letters, common in
# older journal scans) and presentation / reprint boilerplate.
const BYLINE_PATTERNS = [
    r"^this (paper|article|report) (was|is|has)"i, r"^(paper )?presented at"i,
    r"^reprinted (from|with)"i, r"^by\s+[A-Z]"i, r"^\(?received\b"i,
]

# A capitalized name token: "Edgar", "H.R.", "G.", "O'Neil", "Jr.", "III"
const NAME_TOKEN = r"^(?:[A-Z][A-Za-z'\-]*\.?|(?:[A-Z]\.)+|Jr\.?|Sr\.?|II|III|IV)$"

function looks_like_byline(line::AbstractString)
    any(p -> occursin(p, line), BYLINE_PATTERNS) && return true
    letters = filter(isletter, line)
    length(letters) < 4 && return false
    count(isuppercase, letters) / length(letters) >= 0.7 && return true
    # mixed-case byline: every word is a name token or a joiner, and at least one word
    # is an initial ("F.", "H.R."). Title lines such as "Composite Beams and Joists"
    # are all capitalized too, so an initial is required to avoid truncating titles.
    words = split(replace(line, "," => " "))
    2 <= length(words) <= 14 || return false
    all(w -> w in ("and", "&") || occursin(NAME_TOKEN, w), words) || return false
    return any(w -> occursin(r"^(?:[A-Z]\.)+$", w), words)
end

# Section labels that open an article but are not its title. A block that is only a
# label is skipped; a strong label glued to the front of a title is trimmed off.
const LABEL_ONLY = r"^(?:technical note|discussion|closure|reply|errata|erratum|editorial|research report|case study|spec/manual reference|original article|review article|short communication|engineering journal|abstract|introduction|contents|preface|foreword|paper|article)s?[\s:.\-–—]*$"i
const LABEL_PREFIX = r"^(?:technical note|discussion|closure|reply|errata|erratum|editorial|research report|short communication|original article|review article)s?\b[\s:.\-–—]*"i

"""
    strip_label(title) -> String

Return `""` when `title` is only a generic section label ("Technical Note"), otherwise
`title` with a leading strong label ("Discussion", "Closure", ...) removed.
"""
function strip_label(title::AbstractString)
    occursin(LABEL_ONLY, title) && return ""
    return String(strip(replace(title, LABEL_PREFIX => ""; count=1)))
end

"""
    title_from_text(text) -> String

Guess a title from page-1 text: the first block of consecutive non-blank lines, after
dropping lines that look like running headers, DOIs, or page numbers.
"""
function title_from_text(text::AbstractString; max_lines::Int=4, max_chars::Int=200)
    blocks = Vector{Vector{String}}()
    cur = String[]
    for raw in eachline(IOBuffer(text))
        s = strip(replace(raw, '\f' => ' '))
        if isempty(s)
            isempty(cur) || (push!(blocks, cur); cur = String[])
        else
            push!(cur, s)
        end
    end
    isempty(cur) || push!(blocks, cur)

    for b in blocks
        kept = filter(l -> !looks_like_header(l), b)
        isempty(kept) && continue
        # keep leading title lines; stop at the first byline (but let an all-caps
        # first line through so titles set in capitals survive)
        title_lines = String[]
        for (i, l) in enumerate(kept)
            i > 1 && looks_like_byline(l) && break
            push!(title_lines, l)
            length(title_lines) >= max_lines && break
        end
        cand = replace(join(title_lines, " "), r"\s+" => " ")
        cand = strip_label(cand)                 # skip / trim "Technical Note", "Discussion", ...
        length(cand) < 8 && continue
        letter_fraction(cand) < 0.5 && continue
        return String(first(cand, max_chars))
    end
    return ""
end

flatten_ws(s) = String(strip(replace(s, r"\s+" => " ")))

"""
    describe_pdf!(src::PDFSource; snippet_chars=0, timeout=60, pages=2) -> PDFSource

Fill `meta`, `title`, `snippet`, and `has_text` for one source. Never throws:
failures are logged and the title falls back to the filename stem.
"""
function describe_pdf!(src::PDFSource; snippet_chars::Int=0, timeout::Real=60, pages::Int=2)
    stem = splitext(src.name)[1]

    try
        src.meta = parse_pdfinfo(run_capture(pdfinfo_cmd(src.path); timeout))
    catch e
        @warn "pdfinfo failed" file = src.name error = sprint(showerror, e)
    end

    text = ""
    try
        text = run_capture(pdftotext_cmd(src.path; last=pages); timeout)
    catch e
        @warn "pdftotext failed" file = src.name error = sprint(showerror, e)
    end
    src.has_text = !isempty(flatten_ws(text))

    meta_title = get(src.meta, "Title", "")
    title = isjunk_title(meta_title, stem) ? title_from_text(text) : flatten_ws(meta_title)
    isempty(title) && (title = stem)
    src.title = title

    if snippet_chars > 0 && src.has_text
        flat = flatten_ws(text)
        flat = String(strip(chopprefix(flat, title)))
        src.snippet = String(first(flat, snippet_chars))
    end
    return src
end

"""
    extract!(sources; ntasks=..., snippet_chars=0, timeout=60, pages=2) -> sources

Run [`describe_pdf!`](@ref) over all sources concurrently (subprocess-bound work).
"""
function extract!(sources::AbstractVector{PDFSource}; ntasks::Int=max(1, Sys.CPU_THREADS ÷ 2), kwargs...)
    asyncmap(s -> describe_pdf!(s; kwargs...), sources; ntasks)
    return sources
end
