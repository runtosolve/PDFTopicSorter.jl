# Minimal Anthropic Messages API client: one POST, retries, tool loop.

const API_URL = "https://api.anthropic.com/v1/messages"
const API_VERSION = "2023-06-01"
const DEFAULT_MODEL = "claude-opus-5"

"""
    AnthropicError(status, type, message)

Raised for non-retryable API errors (4xx) and for retryable ones once retries are exhausted.
"""
struct AnthropicError <: Exception
    status::Int
    type::String
    message::String
end
Base.showerror(io::IO, e::AnthropicError) =
    print(io, "AnthropicError (HTTP ", e.status, ", ", e.type, "): ", e.message)

function resolve_api_key(explicit)
    explicit === nothing || return String(explicit)
    k = get(ENV, "ANTHROPIC_API_KEY", "")
    isempty(k) && throw(ArgumentError(
        "No Anthropic API key. Pass `api_key=` or set ENV[\"ANTHROPIC_API_KEY\"]."))
    return k
end

"""
    Client(; api_key=nothing, base_url=API_URL, timeout=600, max_retries=5)

Connection settings for the Messages API. The key comes from `api_key` or
`ENV["ANTHROPIC_API_KEY"]`.
"""
struct Client
    api_key::String
    base_url::String
    timeout::Int
    max_retries::Int
end
Client(; api_key=nothing, base_url::AbstractString=API_URL, timeout::Integer=600, max_retries::Integer=5) =
    Client(resolve_api_key(api_key), String(base_url), Int(timeout), Int(max_retries))

Base.show(io::IO, c::Client) = print(io, "Client(", c.base_url, ", key=…", last(c.api_key, 4), ")")

function parse_api_error(status::Int, body::AbstractString)
    try
        j = JSON.parse(body)
        err = j["error"]
        return AnthropicError(status, String(get(err, "type", "unknown")), String(get(err, "message", body)))
    catch
        return AnthropicError(status, "unknown", String(body))
    end
end

function retry_delay(resp, attempt::Int)
    ra = HTTP.header(resp, "retry-after", "")
    if !isempty(ra)
        v = tryparse(Float64, ra)
        v === nothing || return min(v, 120.0)
    end
    return min(2.0^attempt + rand(), 60.0)
end

"""
    messages(client, body::AbstractDict) -> Dict

POST one Messages API request. Retries 429/529/5xx and connection errors with backoff.
"""
function messages(client::Client, body::AbstractDict)
    headers = [
        "content-type" => "application/json",
        "x-api-key" => client.api_key,
        "anthropic-version" => API_VERSION,
    ]
    payload = JSON.json(body)
    attempt = 0
    while true
        attempt += 1
        resp = try
            HTTP.post(client.base_url, headers, payload;
                readtimeout=client.timeout, connect_timeout=30,
                status_exception=false, retry=false)
        catch e
            e isa InterruptException && rethrow()
            attempt > client.max_retries && rethrow()
            delay = min(2.0^attempt + rand(), 60.0)
            @warn "Anthropic request failed; retrying" attempt delay error = sprint(showerror, e)
            sleep(delay)
            continue
        end
        st = resp.status
        text = String(resp.body)
        if st == 200
            return JSON.parse(text)
        elseif st == 429 || st == 529 || st >= 500
            attempt > client.max_retries && throw(parse_api_error(st, text))
            delay = retry_delay(resp, attempt)
            @warn "Anthropic API returned $st; retrying" attempt delay
            sleep(delay)
        else
            throw(parse_api_error(st, text))
        end
    end
end

"""
    response_text(resp) -> String

Concatenate the `text` content blocks of a Messages API response.
"""
function response_text(resp::AbstractDict)
    io = IOBuffer()
    for block in get(resp, "content", Any[])
        get(block, "type", "") == "text" && print(io, block["text"])
    end
    return String(take!(io))
end

function usage_tuple(resp::AbstractDict)
    u = get(resp, "usage", Dict{String,Any}())
    g(k) = something(get(u, k, 0), 0)
    return (input_tokens=g("input_tokens"), output_tokens=g("output_tokens"),
            cache_read_input_tokens=g("cache_read_input_tokens"),
            cache_creation_input_tokens=g("cache_creation_input_tokens"),
            model=String(get(resp, "model", "")))
end

"""
    run_tool_loop(call, body, tools; max_tool_calls=20) -> final response

Drive the tool-use loop. `call(body) -> response` performs one request (normally a
closure over [`messages`](@ref); tests inject canned responses). `tools` maps a tool
name to `f(input::AbstractDict) -> String`.

Each turn's assistant `content` is appended verbatim (thinking blocks included) and
all `tool_result` blocks go back in a single user message. Once `max_tool_calls` is
exceeded, further calls receive an error result asking the model to finish.
"""
function run_tool_loop(call::Function, body::AbstractDict, tools::AbstractDict; max_tool_calls::Int=20)
    body = deepcopy(body)
    msgs = body["messages"]
    ncalls = 0
    while true
        resp = call(body)
        get(resp, "stop_reason", "") == "tool_use" || return resp
        content = resp["content"]
        push!(msgs, Dict{String,Any}("role" => "assistant", "content" => content))
        results = Any[]
        for block in content
            get(block, "type", "") == "tool_use" || continue
            ncalls += 1
            name = String(block["name"])
            input = get(block, "input", Dict{String,Any}())
            result, iserr = if ncalls > max_tool_calls
                ("Tool budget exhausted. Finish the sorting with the information you already have.", true)
            elseif haskey(tools, name)
                try
                    (string(tools[name](input)), false)
                catch e
                    (string("Tool error: ", sprint(showerror, e)), true)
                end
            else
                ("Unknown tool: $name", true)
            end
            push!(results, Dict{String,Any}("type" => "tool_result", "tool_use_id" => block["id"],
                                            "content" => result, "is_error" => iserr))
        end
        isempty(results) && return resp   # defensive: tool_use stop with no tool blocks
        push!(msgs, Dict{String,Any}("role" => "user", "content" => results))
    end
end
