using Test, JSON, Logging
using PDFTopicSorter
using PDFTopicSorter: find_pdfs, make_code, code_width, isjunk_title, title_from_text, parse_pdfinfo,
                 run_capture, pdftotext_cmd, lookup, codes, build_request, parse_taxonomy, validate,
                 run_tool_loop, response_text, usage_tuple, parse_api_error, all_codes, peek_pdf,
                 TAXONOMY_SCHEMA, DEFAULT_PROMPT, DEFAULT_MODEL

include("fixtures.jl")

const CANNED = joinpath(@__DIR__, "canned")
canned(name) = JSON.parse(read(joinpath(CANNED, name), String))

# Four fixture PDFs exercising each title path.
function fixture_dir()
    dir = mktempdir()
    make_pdf(joinpath(dir, "beams_holes.pdf");
        meta_title="Direct strength prediction of cold-formed steel beams with web holes",
        title_lines=["Direct strength prediction of cold-formed", "steel beams with web holes"],
        body_lines=["C. D. Moen and B. W. Schafer", "Abstract. This paper extends the Direct Strength Method."])
    make_pdf(joinpath(dir, "distortional.pdf");
        meta_title="Microsoft Word - paper_final_v3.docx",          # junk metadata
        title_lines=["Distortional buckling of thin-walled columns"],
        body_lines=["Journal of Structural Engineering", "Abstract. Distortional buckling is examined."])
    mkpath(joinpath(dir, "sub"))
    make_pdf(joinpath(dir, "sub", "local_buckling.pdf");
        title_lines=["Journal of Constructional Steel Research 66 (2010) 1-12", "Local buckling of lipped channels under bending"],
        body_lines=["Abstract. Local buckling capacities are derived."])
    make_pdf(joinpath(dir, "scanned_notes.pdf"))                     # no text layer
    return dir
end

@testset "PDFTopicSorter" begin

@testset "ingest" begin
    dir = fixture_dir()
    pdfs = find_pdfs(dir)
    @test length(pdfs) == 4
    @test issorted(pdfs)
    @test length(find_pdfs(dir; recursive=false)) == 3

    @test code_width(5) == 3
    @test code_width(1500) == 4
    @test make_code("P", 7, 3) == "P007"

    srcs = collect_sources(dir)
    @test [s.code for s in srcs] == ["P001", "P002", "P003", "P004"]
    @test srcs[1].name == "beams_holes.pdf"
    @test srcs[4].name == "local_buckling.pdf"          # sub/ sorts after top-level files

    # vector of paths, custom prefix
    srcs2 = collect_sources(reverse(pdfs); code_prefix="DOC")
    @test [s.code for s in srcs2] == ["DOC001", "DOC002", "DOC003", "DOC004"]
    @test srcs2[1].path == pdfs[1]                       # sorted for stability

    # in-memory stream: Channel of name => bytes pairs and a bare IO
    ch = Channel{Any}(4)
    put!(ch, "alpha.pdf" => read(pdfs[1]))
    put!(ch, ("beta", read(pdfs[2])))
    put!(ch, IOBuffer(read(pdfs[3])))
    close(ch)
    srcs3 = collect_sources(ch)
    @test [s.name for s in srcs3] == ["alpha.pdf", "beta", "stream_3.pdf"]
    @test all(isfile(s.path) for s in srcs3)
    @test read(srcs3[1].path) == read(pdfs[1])

    @test_throws ArgumentError collect_sources(joinpath(dir, "nope"))
end

@testset "extract" begin
    dir = fixture_dir()
    srcs = collect_sources(dir)
    extract!(srcs; ntasks=2)
    by = Dict(s.name => s for s in srcs)

    good = by["beams_holes.pdf"]
    @test good.has_text
    @test good.title == "Direct strength prediction of cold-formed steel beams with web holes"
    @test good.meta["Title"] == good.title

    junk = by["distortional.pdf"]
    @test junk.has_text
    @test junk.title == "Distortional buckling of thin-walled columns"   # from page text

    header = by["local_buckling.pdf"]
    @test header.title == "Local buckling of lipped channels under bending"   # running header dropped

    scanned = by["scanned_notes.pdf"]
    @test !scanned.has_text
    @test scanned.title == "scanned_notes"

    # snippet extraction
    s = collect_sources([joinpath(dir, "beams_holes.pdf")])[1]
    describe_pdf!(s; snippet_chars=40)
    @test startswith(s.snippet, "C. D. Moen")
    @test length(s.snippet) <= 40

    # heuristics in isolation
    @test isjunk_title("", "x")
    @test isjunk_title("untitled", "x")
    @test isjunk_title("Microsoft Word - Document1", "x")
    @test isjunk_title("thesis.tex", "x")
    @test isjunk_title("my_paper", "my_paper")
    @test isjunk_title("2010-05-12", "x")
    @test !isjunk_title("Buckling of cold-formed steel members", "x")
    @test title_from_text("") == ""
    @test title_from_text("123\n\nhttps://doi.org/10.1\n\nA real title here\nsecond line\n\nAuthors") ==
          "A real title here second line"
    # bylines end the title block: all-caps, spaced caps, mixed-case names with initials or "and"
    @test title_from_text("Fundamentals of Beam Bracing\nJOSEPH A. YURA\nMore text") == "Fundamentals of Beam Bracing"
    @test title_from_text("The Effective Length of Columns\nJ O S E P H A. YURA") == "The Effective Length of Columns"
    @test title_from_text("Bolt Shear Design Considerations\nRaymond H.R. Tide") == "Bolt Shear Design Considerations"
    @test title_from_text("Equivalent Moment Factor Procedures\nEdgar Wong and Robert G. Driver") ==
          "Equivalent Moment Factor Procedures"
    @test title_from_text("Ponding of Concrete Deck Floors\nJOHN L. RUDDY\nThis paper was presented at the AISC conference.") ==
          "Ponding of Concrete Deck Floors"
    # an all-caps first line is still a title; a second title line with lowercase words is kept
    @test title_from_text("CLOSURE\nAISC LRFD Rules for Block Shear") == "AISC LRFD Rules for Block Shear"
    @test title_from_text("A Practical Method of Second Order Analysis\nPart 1—Pin Jointed Systems\nWM. J. LEMESSURIER") ==
          "A Practical Method of Second Order Analysis Part 1—Pin Jointed Systems"
    # generic labels are skipped, or trimmed when glued to the title
    @test title_from_text("Technical Note\n\nCritical Temperature of Steel Members\nAUTHOR NAME") ==
          "Critical Temperature of Steel Members"
    @test title_from_text("Spec/Manual Reference\n\nStrength of Joints that Combine Bolts and Welds") ==
          "Strength of Joints that Combine Bolts and Welds"
    @test title_from_text("Discussion Limit State Response of Composite Columns") ==
          "Limit State Response of Composite Columns"
    @test PDFTopicSorter.strip_label("Technical Note") == ""
    @test PDFTopicSorter.strip_label("Discussion: Web Crippling") == "Web Crippling"
    @test PDFTopicSorter.strip_label("Papers on Stability") == "Papers on Stability"
    @test PDFTopicSorter.strip_label("Introduction to Structural Stability") == "Introduction to Structural Stability"
    @test PDFTopicSorter.strip_label("Introduction") == ""
    @test PDFTopicSorter.looks_like_byline("Louis F. Geschwindner")
    @test PDFTopicSorter.looks_like_byline("Edgar Wong and Robert G. Driver")
    @test !PDFTopicSorter.looks_like_byline("Bolt Shear Design Considerations")
    @test !PDFTopicSorter.looks_like_byline("Flange Bending in Single Curvature")
    @test !PDFTopicSorter.looks_like_byline("Columns and Beams")
    @test !PDFTopicSorter.looks_like_byline("Composite Beams and Joists")
    @test title_from_text("Strength of Shear Studs in Steel Deck on\nComposite Beams and Joists\nW. SAMUEL EASTERLING") ==
          "Strength of Shear Studs in Steel Deck on Composite Beams and Joists"
    @test parse_pdfinfo("Title:          Hello\nPages:          12\nPage size:      612 x 792 pts\n") ==
          Dict("Title" => "Hello", "Pages" => "12", "Page size" => "612 x 792 pts")

    # unreadable file never throws
    bad = PDFSource("P001", joinpath(dir, "not_a_pdf.pdf"), "not_a_pdf.pdf")
    write(bad.path, "hello")
    with_logger(NullLogger()) do
        describe_pdf!(bad)
    end
    @test !bad.has_text
    @test bad.title == "not_a_pdf"
end

@testset "manifest" begin
    dir = fixture_dir()
    srcs = extract!(collect_sources(dir); ntasks=2)
    m = with_logger(NullLogger()) do
        compile_manifest(srcs)
    end
    lines = split(strip(m.text), '\n')
    @test lines[1] == "# 4 documents. Format: CODE | title"
    @test lines[2] == "P001 | Direct strength prediction of cold-formed steel beams with web holes"
    @test lines[3] == "P002 | Distortional buckling of thin-walled columns"
    @test lines[4] == "P003 | scanned_notes (no text layer)"
    @test lines[5] == "P004 | Local buckling of lipped channels under bending"
    @test codes(m) == ["P001", "P002", "P003", "P004"]
    @test lookup(m)["P002"].name == "distortional.pdf"
    @test length(m) == 4

    # pipes in titles are neutralized; snippets appended
    s = PDFSource("P001", "/x.pdf", "x.pdf", "A | B", "snip text", Dict{String,String}(), true)
    m2 = with_logger(NullLogger()) do
        compile_manifest([s]; include_snippet=true)
    end
    @test occursin("P001 | A / B | snip text", m2.text)
end

@testset "request + schema" begin
    m = Manifest([PDFSource("P001", "/a.pdf", "a.pdf", "T", "", Dict{String,String}(), true)], "# 1\nP001 | T\n")
    body = build_request(m; prompt="Sort them.")
    @test body["model"] == DEFAULT_MODEL == "claude-opus-5"
    @test body["max_tokens"] == 16_000
    @test body["output_config"]["effort"] == "high"
    @test body["output_config"]["format"]["type"] == "json_schema"
    @test body["output_config"]["format"]["schema"] === TAXONOMY_SCHEMA
    @test length(body["tools"]) == 1 && body["tools"][1]["strict"] === true
    @test !haskey(body, "thinking")                       # adaptive by default on Opus 5
    content = body["messages"][1]["content"]
    @test startswith(content[1]["text"], "<manifest>")
    @test content[1]["cache_control"] == Dict("type" => "ephemeral")
    @test content[2]["text"] == "Sort them."
    @test !haskey(build_request(m; allow_peek=false), "tools")
    @test !haskey(build_request(m; effort=nothing)["output_config"], "effort")

    # the schema must be non-recursive with additionalProperties=false on every object
    function check_schema(s)
        if get(s, "type", "") == "object"
            @test s["additionalProperties"] === false
            @test haskey(s, "required")
            foreach(check_schema, values(s["properties"]))
        elseif get(s, "type", "") == "array"
            check_schema(s["items"])
        end
    end
    check_schema(TAXONOMY_SCHEMA)
    @test JSON.json(body) isa String                      # serializable
end

@testset "taxonomy parse + validate" begin
    tax = parse_taxonomy(JSON.parse(response_text(canned("simple.json"))))
    @test length(tax.themes) == 2
    @test tax.themes[1].name == "Cold-Formed Steel Structures"
    @test tax.themes[1].children[1].children[1].codes == ["P001"]
    @test sort(all_codes(tax)) == ["P001", "P002", "P003", "P004"]

    messy = parse_taxonomy(JSON.parse(response_text(canned("messy.json"))))
    fixed, report = with_logger(NullLogger()) do
        validate(messy, ["P001", "P002", "P003"])
    end
    @test report.dropped == ["P999", "P999"]
    @test report.duplicates == ["P001", "P002"]
    @test report.missing == ["P003"]
    @test fixed.unsorted == ["P003"]
    @test fixed.themes[1].codes == ["P001"]               # first placement wins
    @test isempty(fixed.themes[1].children)               # Topic A1 pruned once empty
    @test fixed.themes[2].children[1].codes == ["P002"]
    @test sort(all_codes(fixed)) == ["P001", "P002", "P003"]
end

@testset "tool loop" begin
    dir = fixture_dir()
    srcs = extract!(collect_sources(dir); ntasks=2)
    m = with_logger(NullLogger()) do
        compile_manifest(srcs)
    end
    responses = Any[canned("tool_use.json"), canned("simple.json")]
    bodies = Any[]
    fake_call = body -> (push!(bodies, deepcopy(body)); popfirst!(responses))

    tax, resp = with_logger(NullLogger()) do
        sort_manifest(m; call=fake_call)
    end
    @test isempty(responses)
    @test length(bodies) == 2
    msgs = bodies[2]["messages"]
    @test length(msgs) == 3
    @test msgs[2]["role"] == "assistant"
    @test msgs[2]["content"][1]["type"] == "thinking"     # passed back verbatim
    @test msgs[3]["role"] == "user"
    tr = msgs[3]["content"][1]
    @test tr["type"] == "tool_result" && tr["tool_use_id"] == "toolu_test_1" && tr["is_error"] == false
    @test startswith(tr["content"], "P002 (distortional.pdf): Distortional buckling")
    @test length(bodies[1]["messages"]) == 1               # original body not mutated
    @test resp["stop_reason"] == "end_turn"
    @test sort(all_codes(tax)) == codes(m)

    # unknown code, unknown tool, budget exhaustion
    @test startswith(peek_pdf(m, Dict("code" => "P042")), "Unknown code")
    @test occursin("no text layer", peek_pdf(m, Dict("code" => "P003")))
    seq = Any[canned("tool_use.json"), canned("tool_use.json"), canned("simple.json")]
    sent = Any[]
    final = run_tool_loop(b -> (push!(sent, deepcopy(b)); popfirst!(seq)),
                          build_request(m), Dict{String,Function}(); max_tool_calls=1)
    @test final["stop_reason"] == "end_turn"
    r1 = sent[2]["messages"][end]["content"][1]
    r2 = sent[3]["messages"][end]["content"][1]
    @test r1["is_error"] && startswith(r1["content"], "Unknown tool")
    @test r2["is_error"] && startswith(r2["content"], "Tool budget exhausted")

    # stop-reason handling
    refusal = merge(canned("simple.json"), Dict("stop_reason" => "refusal", "stop_details" => Dict("category" => "x")))
    @test_throws ErrorException with_logger(NullLogger()) do
        sort_manifest(m; call=_ -> refusal)
    end
    truncated = merge(canned("simple.json"), Dict("stop_reason" => "max_tokens"))
    @test_throws ErrorException with_logger(NullLogger()) do
        sort_manifest(m; call=_ -> truncated)
    end
    @test_throws ArgumentError sort_manifest(Manifest(PDFSource[], ""); call=_ -> nothing)
end

@testset "output" begin
    dir = fixture_dir()
    srcs = extract!(collect_sources(dir); ntasks=2)
    m = with_logger(NullLogger()) do
        compile_manifest(srcs)
    end
    tax = parse_taxonomy(JSON.parse(response_text(canned("simple.json"))))
    tax, _ = validate(tax, codes(m))

    md = render_markdown(tax, m)
    @test occursin("# Cold-Formed Steel Structures\n", md)
    @test occursin("## Member Buckling\n", md)
    @test occursin("### Beams with Holes\n\n- [P001] Direct strength prediction of cold-formed steel beams with web holes  (beams_holes.pdf)", md)
    @test occursin("- [P003] scanned_notes  (scanned_notes.pdf)", md)
    @test !occursin("Unsorted", md)
    @test occursin("## Unsorted", render_markdown(Taxonomy(Group[], ["P001"]), m))

    rows = build_index(tax, m)
    @test length(rows) == 4
    @test rows[1] == (code="P003", path=lookup(m)["P003"].path, title="scanned_notes",
                      theme="Cold-Formed Steel Structures", topic="Member Buckling", subtopic="")
    @test rows[2].code == "P001" && rows[2].subtopic == "Beams with Holes"
    @test rows[4] == (code="P004", path=lookup(m)["P004"].path, title="Local buckling of lipped channels under bending",
                      theme="Numerical Methods", topic="Finite Strip Method", subtopic="")

    out = mktempdir()
    write_index(rows, joinpath(out, "i.json"))
    back = JSON.parse(read(joinpath(out, "i.json"), String))
    @test length(back) == 4 && back[2]["code"] == "P001" && back[2]["subtopic"] == "Beams with Holes"
    write_index(rows, joinpath(out, "i.csv"))
    csv = readlines(joinpath(out, "i.csv"))
    @test csv[1] == "code,path,title,theme,topic,subtopic"
    @test length(csv) == 5
    @test occursin("\"", PDFTopicSorter.csv_field("a,b")) && PDFTopicSorter.csv_field("plain") == "plain"

    resp = canned("simple.json")
    run_dir = with_logger(NullLogger()) do
        write_run(joinpath(out, "run"), m, tax, md, rows, resp)
    end
    @test all(isfile(joinpath(run_dir, f)) for f in
              ("sorted.md", "index.json", "index.csv", "manifest.txt", "response.json", "usage.json"))
    @test read(joinpath(run_dir, "manifest.txt"), String) == m.text
    u = usage_tuple(resp)
    @test u.input_tokens == 412 && u.output_tokens == 133 && u.model == "claude-opus-5"
end

@testset "end to end (offline)" begin
    dir = fixture_dir()
    r = with_logger(NullLogger()) do
        sort_pdfs(dir; out=joinpath(dir, "out"), call=_ -> canned("simple.json"))
    end
    @test r isa SortResult
    @test length(r.manifest) == 4
    @test length(r.taxonomy.themes) == 2
    @test isempty(r.taxonomy.unsorted)
    @test isfile(joinpath(r.run_dir, "sorted.md"))
    @test r.usage.input_tokens == 412
    @test occursin("4 documents, 2 themes", sprint(show, r))
    @test_throws ArgumentError sort_pdfs(mktempdir(); call=_ -> nothing)
end

@testset "client" begin
    withenv("ANTHROPIC_API_KEY" => nothing) do
        @test_throws ArgumentError Client()
    end
    c = Client(; api_key="sk-test-1234")
    @test c.base_url == PDFTopicSorter.API_URL && c.timeout == 600 && c.max_retries == 5
    @test occursin("…1234", sprint(show, c))
    e = parse_api_error(400, """{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}""")
    @test e.status == 400 && e.type == "invalid_request_error" && e.message == "bad"
    @test occursin("invalid_request_error", sprint(showerror, e))
    @test parse_api_error(502, "<html>gateway</html>").type == "unknown"
end

end # PDFTopicSorter testset
