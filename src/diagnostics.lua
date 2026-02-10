-- Collects and formats compiler diagnostics across phases
local Diagnostics = {}

-- Builds a minimal span when only token coordinates are known
local function new_span(file, line, col, end_line, end_col)
    return {
        file = file or "<input>",
        line = line or 1,
        col = col or 1,
        end_line = end_line or line or 1,
        end_col = end_col or col or 1,
    }
end

-- Sorts spans in source order for stable output
local function compare(a, b)
    if a.file ~= b.file then
        return a.file < b.file
    end
    if a.line ~= b.line then
        return a.line < b.line
    end
    if a.col ~= b.col then
        return a.col < b.col
    end
    if a.end_line ~= b.end_line then
        return a.end_line < b.end_line
    end
    return a.end_col < b.end_col
end

-- Creates a diagnostics container
function Diagnostics.new()
    return { list = {} }
end

-- Records an error diagnostic
function Diagnostics.error(diag, span, message, hints)
    diag.list[#diag.list + 1] = { severity = "error", span = span, message = message, hints = hints }
end

-- Records a warning diagnostic
function Diagnostics.warn(diag, span, message, hints)
    diag.list[#diag.list + 1] = { severity = "warning", span = span, message = message, hints = hints }
end

-- Records a note diagnostic
function Diagnostics.note(diag, span, message, hints)
    diag.list[#diag.list + 1] = { severity = "note", span = span, message = message, hints = hints }
end

-- Appends diagnostics from another container
function Diagnostics.merge(diag, other)
    for _, d in ipairs(other.list) do
        diag.list[#diag.list + 1] = d
    end
end

-- Checks whether any error diagnostics were recorded
function Diagnostics.has_errors(diag)
    for _, d in ipairs(diag.list) do
        if d.severity == "error" then
            return true
        end
    end
    return false
end

-- Counts error diagnostics
function Diagnostics.count_errors(diag)
    local n = 0
    for _, d in ipairs(diag.list) do
        if d.severity == "error" then
            n = n + 1
        end
    end
    return n
end

-- Groups diagnostics by file and sorts by span
function Diagnostics.group_by_file(diag)
    local groups = {}
    for _, d in ipairs(diag.list) do
        local file = d.span and d.span.file or "<input>"
        groups[file] = groups[file] or {}
        groups[file][#groups[file] + 1] = d
    end
    for _, list in pairs(groups) do
        table.sort(list, function(a, b)
            local sa = a.span or new_span("<input>", 1, 1, 1, 1)
            local sb = b.span or new_span("<input>", 1, 1, 1, 1)
            return compare(sa, sb)
        end)
    end
    return groups
end

-- Formats diagnostics as a stable, human-readable string
function Diagnostics.format(diag)
    local groups = Diagnostics.group_by_file(diag)
    local files = {}
    for file, _ in pairs(groups) do
        files[#files + 1] = file
    end
    table.sort(files)

    local out = {}
    for _, file in ipairs(files) do
        out[#out + 1] = file
        for _, d in ipairs(groups[file]) do
            local s = d.span
            local line = s and s.line or 1
            local col = s and s.col or 1
            local end_line = s and s.end_line or line
            local end_col = s and s.end_col or col
            local range
            if line == end_line and col == end_col then
                range = string.format("%d:%d", line, col)
            else
                range = string.format("%d:%d-%d:%d", line, col, end_line, end_col)
            end
            out[#out + 1] = string.format("  %s: %s: %s", range, d.severity, d.message)
            if d.hints then
                for _, h in ipairs(d.hints) do
                    out[#out + 1] = string.format("    hint: %s", h)
                end
            end
        end
    end
    return table.concat(out, "\n")
end

return Diagnostics
