-- CLI entry point for Hordr compilation
local compiler = require("src.main")
local Diagnostics = require("src.diagnostics")

-- Reads a file as raw bytes
local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then
        error(err)
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- Writes to stdout without formatting
local function write_stdout(s)
    io.write(s)
end

-- Writes to stderr without formatting
local function write_stderr(s)
    io.stderr:write(s)
end

-- Parses CLI arguments into options
local function parse_args(argv)
    local opts = { input = nil, target = "luau", warnings_as_errors = false, max_errors = nil }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--target" then
            i = i + 1
            opts.target = argv[i] or "luau"
        elseif a == "--warnings-as-errors" then
            opts.warnings_as_errors = true
        elseif a == "--max-errors" then
            i = i + 1
            opts.max_errors = tonumber(argv[i])
        elseif a == "-h" or a == "--help" then
            opts.help = true
        else
            opts.input = a
        end
        i = i + 1
    end
    return opts
end

-- Runs the CLI with diagnostics reporting
local function main(argv)
    local opts = parse_args(argv)
    if opts.help or not opts.input then
        write_stdout("Usage: lua bin/hordr.lua <input.hordr> [--target luau|lua] [--warnings-as-errors] [--max-errors N]\n")
        return
    end

    local source = read_file(opts.input)
    local out, diagnostics = compiler.compile(source, { target = opts.target, filename = opts.input })
    local errors = Diagnostics.count_errors(diagnostics)

    if opts.warnings_as_errors then
        for _, d in ipairs(diagnostics.list) do
            if d.severity == "warning" then
                d.severity = "error"
                errors = errors + 1
            end
        end
    end

    if opts.max_errors and errors > opts.max_errors then
        local kept = {}
        local count = 0
        for _, d in ipairs(diagnostics.list) do
            if d.severity == "error" then
                count = count + 1
                if count <= opts.max_errors then
                    kept[#kept + 1] = d
                end
            else
                kept[#kept + 1] = d
            end
        end
        diagnostics.list = kept
    end

    if #diagnostics.list > 0 then
        write_stderr(Diagnostics.format(diagnostics) .. "\n")
    end

    if errors > 0 then
        os.exit(1)
    end

    write_stdout(out)
end

main(arg)
