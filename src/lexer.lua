-- Tokenizes source text into a stream of positioned tokens
local Lexer = {}

-- Reserved keywords for the language
local keywords = {
    ["let"] = true,
    ["global"] = true,
    ["fn"] = true,
    ["struct"] = true,
    ["enum"] = true,
    ["module"] = true,
    ["import"] = true,
    ["export"] = true,
    ["as"] = true,
    ["if"] = true,
    ["elseif"] = true,
    ["else"] = true,
    ["while"] = true,
    ["for"] = true,
    ["in"] = true,
    ["return"] = true,
    ["match"] = true,
    ["case"] = true,
    ["and"] = true,
    ["or"] = true,
    ["not"] = true,
    ["true"] = true,
    ["false"] = true,
    ["nil"] = true,
}

-- Checks identifier start characters
local function is_alpha(ch)
    return ch:match("[A-Za-z_]") ~= nil
end

-- Checks identifier continuation characters
local function is_alnum(ch)
    return ch:match("[A-Za-z0-9_]") ~= nil
end

-- Checks decimal digits
local function is_digit(ch)
    return ch:match("[0-9]") ~= nil
end

-- Constructs a token with source coordinates
local function make_token(tt, value, line, col, end_line, end_col, file)
    return { type = tt, value = value, line = line, col = col, end_line = end_line, end_col = end_col, file = file }
end

-- Lexes a full source string into tokens
function Lexer.lex(input, file)
    local tokens = {}
    local i = 1
    local line = 1
    local col = 1

    -- Peeks ahead without consuming
    local function peek(n)
        n = n or 0
        return input:sub(i + n, i + n)
    end

    -- Advances the cursor and updates column
    local function advance(n)
        n = n or 1
        i = i + n
        col = col + n
    end

    -- Adds a token with explicit span
    local function add(tt, value, start_line, start_col, end_line, end_col)
        tokens[#tokens + 1] = make_token(tt, value, start_line, start_col, end_line, end_col, file or "<input>")
    end

    -- Emits a newline token and updates line state
    local function newline()
        add("newline", "\n", line, col, line, col)
        i = i + 1
        line = line + 1
        col = 1
    end

    while i <= #input do
        local ch = peek(0)

        if ch == "" then
            break
        elseif ch == " " or ch == "\t" or ch == "\r" then
            advance(1)
        elseif ch == "\n" then
            newline()
        elseif ch == "-" and peek(1) == "-" then
            if peek(2) == "[" and peek(3) == "[" then
                -- block comment
                advance(4)
                while i <= #input do
                    if peek(0) == "]" and peek(1) == "]" then
                        advance(2)
                        break
                    elseif peek(0) == "\n" then
                        newline()
                    else
                        advance(1)
                    end
                end
            else
                -- line comment
                advance(2)
                while i <= #input and peek(0) ~= "\n" do
                    advance(1)
                end
            end
        elseif is_alpha(ch) then
            local start_line, start_col = line, col
            local start = i
            while is_alnum(peek(0)) do
                advance(1)
            end
            local text = input:sub(start, i - 1)
            if keywords[text] then
                add("keyword", text, start_line, start_col, line, col - 1)
            else
                add("ident", text, start_line, start_col, line, col - 1)
            end
        elseif is_digit(ch) then
            local start_line, start_col = line, col
            local start = i
            while is_digit(peek(0)) do
                advance(1)
            end
            if peek(0) == "." and is_digit(peek(1)) then
                advance(1)
                while is_digit(peek(0)) do
                    advance(1)
                end
            end
            local num = input:sub(start, i - 1)
            add("number", num, start_line, start_col, line, col - 1)
        elseif ch == "\"" then
            local start_line, start_col = line, col
            advance(1)
            local buf = {}
            while i <= #input do
                local c = peek(0)
                if c == "\\" then
                    local esc = peek(1)
                    if esc == "\"" or esc == "\\" or esc == "n" or esc == "t" or esc == "r" then
                        buf[#buf + 1] = "\\" .. esc
                        advance(2)
                    else
                        buf[#buf + 1] = "\\" .. esc
                        advance(2)
                    end
                elseif c == "\"" then
                    advance(1)
                    break
                elseif c == "\n" then
                    error(string.format("Unterminated string at %d:%d", start_line, start_col))
                else
                    buf[#buf + 1] = c
                    advance(1)
                end
            end
            add("string", "\"" .. table.concat(buf) .. "\"", start_line, start_col, line, col - 1)
        else
            local start_line, start_col = line, col
            local two = ch .. peek(1)
            local three = two .. peek(2)

            if three == "..." then
                add("symbol", "...", start_line, start_col, line, col + 2)
                advance(3)
            elseif two == "==" or two == "~=" or two == "<=" or two == ">=" or two == "=>" or two == "->" then
                add("symbol", two, start_line, start_col, line, col + 1)
                advance(2)
            else
                add("symbol", ch, start_line, start_col, line, col)
                advance(1)
            end
        end
    end

    tokens[#tokens + 1] = make_token("eof", "", line, col, line, col, file or "<input>")
    return tokens
end

return Lexer
