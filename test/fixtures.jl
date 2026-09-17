# Minimal hand-written PDF generator so tests need no extra dependencies.
# Produces a single-page PDF with optional metadata Title and text lines that
# Poppler's pdftotext can read back.

pdf_escape(s) = replace(s, "\\" => "\\\\", "(" => "\\(", ")" => "\\)")

"""
    make_pdf(path; title_lines=String[], body_lines=String[], meta_title=nothing, author=nothing)

Write a one-page PDF. `title_lines` are drawn large near the top; `body_lines` are
drawn smaller after a vertical gap so pdftotext separates them with a blank line.
An empty `title_lines`/`body_lines` pair yields a page with no text layer.
"""
function make_pdf(path::AbstractString; title_lines=String[], body_lines=String[],
                  meta_title=nothing, author=nothing)
    content = IOBuffer()
    y = 720
    for l in title_lines
        print(content, "BT /F1 18 Tf 72 $y Td (", pdf_escape(l), ") Tj ET\n")
        y -= 24
    end
    y -= 60                       # gap => blank line in pdftotext output
    for l in body_lines
        print(content, "BT /F1 11 Tf 72 $y Td (", pdf_escape(l), ") Tj ET\n")
        y -= 14
    end
    stream = String(take!(content))

    info = IOBuffer()
    print(info, "<<")
    meta_title === nothing || print(info, " /Title (", pdf_escape(meta_title), ")")
    author === nothing || print(info, " /Author (", pdf_escape(author), ")")
    print(info, " /Producer (PDFTopicSorter tests) >>")

    objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Length $(sizeof(stream)) >>\nstream\n" * stream * "endstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        String(take!(info)),
    ]

    io = IOBuffer()
    write(io, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = Int[]
    for (i, obj) in enumerate(objects)
        push!(offsets, position(io))
        write(io, "$i 0 obj\n", obj, "\nendobj\n")
    end
    xref = position(io)
    write(io, "xref\n0 $(length(objects) + 1)\n")
    write(io, "0000000000 65535 f \n")
    for off in offsets
        write(io, lpad(off, 10, '0'), " 00000 n \n")
    end
    write(io, "trailer\n<< /Size $(length(objects) + 1) /Root 1 0 R /Info 6 0 R >>\nstartxref\n$xref\n%%EOF\n")
    write(path, take!(io))
    return path
end
