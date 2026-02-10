-- Parses tokens into a syntax tree with source spans
local Parser = {}

-- Raises a structured parse error for diagnostics
local function error_at(tok, msg)
    error({ kind = "ParseError", token = tok, message = msg })
end

-- Builds a span from two tokens or span-like tables
local function span_from(a, b)
    return {
        file = a.file or "<input>",
        line = a.line,
        col = a.col,
        end_line = b.end_line or b.line,
        end_col = b.end_col or b.col,
    }
end

-- Builds a span from a single token
local function span_of(tok)
    return {
        file = tok.file or "<input>",
        line = tok.line,
        col = tok.col,
        end_line = tok.end_line or tok.line,
        end_col = tok.end_col or tok.col,
    }
end

-- Creates a parser over a token array
function Parser.new(tokens)
    return setmetatable({ tokens = tokens, pos = 1 }, { __index = Parser })
end

-- Peeks at a token without consuming it
function Parser:peek(n)
    n = n or 0
    return self.tokens[self.pos + n]
end

-- Consumes and returns the current token
function Parser:next()
    local tok = self.tokens[self.pos]
    self.pos = self.pos + 1
    return tok
end

-- Consumes a token if it matches the requested type and value
function Parser:match(tt, value)
    local tok = self:peek(0)
    if tok.type ~= tt then
        return nil
    end
    if value and tok.value ~= value then
        return nil
    end
    self.pos = self.pos + 1
    return tok
end

-- Consumes a token or raises a parse error
function Parser:expect(tt, value)
    local tok = self:peek(0)
    if tok.type ~= tt or (value and tok.value ~= value) then
        error_at(tok, "expected " .. tt .. (value and (" '" .. value .. "'") or ""))
    end
    self.pos = self.pos + 1
    return tok
end

-- Skips contiguous newline tokens
function Parser:consume_newlines()
    while self:match("newline") do
    end
end

-- Enforces a statement boundary or end of block
function Parser:consume_stmt_end()
    if self:match("symbol", ";") then
        self:consume_newlines()
        return
    end
    if self:match("newline") then
        self:consume_newlines()
        return
    end
    local tok = self:peek(0)
    if tok.type == "symbol" and tok.value == "}" then
        return
    end
    if tok.type == "eof" then
        return
    end
    error_at(tok, "expected statement terminator")
end

-- Parses a complete program including module header and imports
function Parser:parse_program()
    local body = {}
    local imports = {}
    local module_name = nil
    local module_span = nil
    self:consume_newlines()

    if self:match("keyword", "module") then
        local mod = self:parse_module_path()
        module_name = mod.name
        module_span = mod.span
        self:consume_stmt_end()
        self:consume_newlines()
    end

    while self:peek(0).type == "keyword" and self:peek(0).value == "import" do
        imports[#imports + 1] = self:parse_import()
        self:consume_newlines()
    end

    while self:peek(0).type ~= "eof" do
        body[#body + 1] = self:parse_stmt()
        self:consume_newlines()
    end
    return { kind = "Program", module = module_name, module_span = module_span, imports = imports, body = body }
end

-- Parses a single statement
function Parser:parse_stmt()
    local tok = self:peek(0)
    if tok.type == "keyword" then
        if tok.value == "let" then
            return self:parse_let()
        elseif tok.value == "export" then
            return self:parse_export()
        elseif tok.value == "global" then
            return self:parse_global()
        elseif tok.value == "fn" then
            return self:parse_fn()
        elseif tok.value == "struct" then
            return self:parse_struct()
        elseif tok.value == "enum" then
            return self:parse_enum()
        elseif tok.value == "if" then
            return self:parse_if()
        elseif tok.value == "while" then
            return self:parse_while()
        elseif tok.value == "for" then
            return self:parse_for()
        elseif tok.value == "return" then
            return self:parse_return()
        elseif tok.value == "match" then
            return self:parse_match()
        end
    end

    local expr = self:parse_expr()
    if (expr.kind == "Ident" or expr.kind == "Index") and self:match("symbol", "=") then
        local rhs = self:parse_expr()
        self:consume_stmt_end()
        return { kind = "Assign", target = expr, value = rhs }
    end
    self:consume_stmt_end()
    return { kind = "ExprStmt", expr = expr }
end

-- Parses a dotted module path and returns name + span
function Parser:parse_module_path()
    local parts = {}
    local first = self:expect("ident")
    parts[#parts + 1] = first.value
    local last = first
    while true do
        local dot = self:peek(0)
        local next = self:peek(1)
        if dot.type == "symbol" and dot.value == "." and next.type == "ident" then
            self:next()
            last = self:expect("ident")
            parts[#parts + 1] = last.value
        else
            break
        end
    end
    return { name = table.concat(parts, "."), span = span_from(first, last) }
end

-- Parses an import declaration
function Parser:parse_import()
    local start = self:expect("keyword", "import")
    local mod = self:parse_module_path()
    local module_name = mod.name
    local alias = nil
    local names = nil

    if self:match("keyword", "as") then
        local alias_tok = self:expect("ident")
        alias = alias_tok.value
    elseif self:match("symbol", ".") then
        self:expect("symbol", "{")
        names = {}
        repeat
            names[#names + 1] = self:expect("ident").value
        until not self:match("symbol", ",")
        self:expect("symbol", "}")
    end

    self:consume_stmt_end()
    return { kind = "Import", module = module_name, alias = alias, names = names, span = span_from(start, mod.span) }
end

-- Parses an export modifier followed by a declaration
function Parser:parse_export()
    self:expect("keyword", "export")
    local tok = self:peek(0)
    if tok.type == "keyword" and tok.value == "fn" then
        local decl = self:parse_fn()
        decl.exported = true
        return decl
    elseif tok.type == "keyword" and tok.value == "struct" then
        local decl = self:parse_struct()
        decl.exported = true
        return decl
    elseif tok.type == "keyword" and tok.value == "enum" then
        local decl = self:parse_enum()
        decl.exported = true
        return decl
    elseif tok.type == "keyword" and tok.value == "let" then
        local decl = self:parse_let()
        decl.exported = true
        return decl
    end
    error_at(tok, "export must be followed by a declaration")
end

-- Parses a local declaration
function Parser:parse_let()
    local start = self:expect("keyword", "let")
    local name_tok = self:expect("ident")
    local name = name_tok.value
    local type_expr = nil
    if self:match("symbol", ":") then
        type_expr = self:parse_type_expr()
    end
    local init = nil
    if self:match("symbol", "=") then
        init = self:parse_expr()
    end
    self:consume_stmt_end()
    local end_span = init and init.span or span_of(name_tok)
    return { kind = "Let", name = name, name_span = span_of(name_tok), type_expr = type_expr, init = init, span = span_from(start, end_span) }
end

-- Parses an explicit global assignment
function Parser:parse_global()
    local start = self:expect("keyword", "global")
    local name_tok = self:expect("ident")
    local name = name_tok.value
    self:expect("symbol", "=")
    local init = self:parse_expr()
    self:consume_stmt_end()
    return { kind = "Global", name = name, name_span = span_of(name_tok), init = init, span = span_from(start, init.span) }
end

-- Parses a function declaration
function Parser:parse_fn()
    local start = self:expect("keyword", "fn")
    local name_tok = self:expect("ident")
    local name = name_tok.value
    self:expect("symbol", "(")
    local params = {}
    if not self:match("symbol", ")") then
        repeat
            local pname_tok = self:expect("ident")
            local pname = pname_tok.value
            local ptype = nil
            if self:match("symbol", ":") then
                ptype = self:parse_type_expr()
            end
            params[#params + 1] = { name = pname, type_expr = ptype, span = span_of(pname_tok) }
        until not self:match("symbol", ",")
        self:expect("symbol", ")")
    end
    local ret_type = nil
    if self:match("symbol", ":") then
        ret_type = self:parse_type_expr()
    end
    local body = self:parse_block()
    return { kind = "Function", name = name, name_span = span_of(name_tok), params = params, ret_type = ret_type, body = body, span = span_from(start, span_of(name_tok)) }
end

-- Parses a struct declaration
function Parser:parse_struct()
    local start = self:expect("keyword", "struct")
    local name_tok = self:expect("ident")
    local name = name_tok.value
    self:expect("symbol", "{")
    local fields = {}
    self:consume_newlines()
    while not self:match("symbol", "}") do
        local fname_tok = self:expect("ident")
        local fname = fname_tok.value
        self:expect("symbol", ":")
        local ftype = self:parse_type_expr()
        fields[#fields + 1] = { name = fname, type_expr = ftype, span = span_of(fname_tok) }
        self:match("symbol", ",")
        self:consume_newlines()
    end
    return { kind = "Struct", name = name, name_span = span_of(name_tok), fields = fields, span = span_from(start, span_of(name_tok)) }
end

-- Parses an enum declaration
function Parser:parse_enum()
    local start = self:expect("keyword", "enum")
    local name_tok = self:expect("ident")
    local name = name_tok.value
    self:expect("symbol", "{")
    local items = {}
    self:consume_newlines()
    while not self:match("symbol", "}") do
        local iname_tok = self:expect("ident")
        local iname = iname_tok.value
        local value = nil
        if self:match("symbol", "=") then
            value = tonumber(self:expect("number").value)
        end
        items[#items + 1] = { name = iname, value = value, span = span_of(iname_tok) }
        self:match("symbol", ",")
        self:consume_newlines()
    end
    return { kind = "Enum", name = name, name_span = span_of(name_tok), items = items, span = span_from(start, span_of(name_tok)) }
end

-- Parses an if/elseif/else statement
function Parser:parse_if()
    local start = self:expect("keyword", "if")
    local cond = self:parse_expr()
    local then_block = self:parse_block()
    local elseif_blocks = {}
    while self:match("keyword", "elseif") do
        local econd = self:parse_expr()
        local eblock = self:parse_block()
        elseif_blocks[#elseif_blocks + 1] = { cond = econd, block = eblock }
    end
    local else_block = nil
    if self:match("keyword", "else") then
        else_block = self:parse_block()
    end
    return { kind = "If", cond = cond, then_block = then_block, elseif_blocks = elseif_blocks, else_block = else_block, span = span_from(start, cond.span) }
end

-- Parses a while loop
function Parser:parse_while()
    local start = self:expect("keyword", "while")
    local cond = self:parse_expr()
    local body = self:parse_block()
    return { kind = "While", cond = cond, body = body, span = span_from(start, cond.span) }
end

-- Parses a numeric or generic for loop
function Parser:parse_for()
    local start = self:expect("keyword", "for")
    local name_tok = self:expect("ident")
    local name = name_tok.value
    if self:match("symbol", "=") then
        local start = self:parse_expr()
        self:expect("symbol", ",")
        local finish = self:parse_expr()
        local step = nil
        if self:match("symbol", ",") then
            step = self:parse_expr()
        end
        local body = self:parse_block()
        return { kind = "ForNum", name = name, name_span = span_of(name_tok), start = start, finish = finish, step = step, body = body, span = span_from(start, finish.span) }
    end
    self:expect("keyword", "in")
    local iter = self:parse_expr()
    local body = self:parse_block()
    return { kind = "ForIn", name = name, name_span = span_of(name_tok), iter = iter, body = body, span = span_from(start, iter.span) }
end

-- Parses a return statement
function Parser:parse_return()
    local start = self:expect("keyword", "return")
    local tok = self:peek(0)
    if tok.type == "symbol" and tok.value == "}" then
        self:consume_stmt_end()
        return { kind = "Return", expr = nil, span = span_of(start) }
    end
    if tok.type == "newline" or (tok.type == "symbol" and tok.value == ";") then
        self:consume_stmt_end()
        return { kind = "Return", expr = nil, span = span_of(start) }
    end
    local expr = self:parse_expr()
    self:consume_stmt_end()
    return { kind = "Return", expr = expr, span = span_from(start, expr.span) }
end

-- Parses a match statement
function Parser:parse_match()
    local start = self:expect("keyword", "match")
    local expr = self:parse_expr()
    self:expect("symbol", "{")
    local cases = {}
    self:consume_newlines()
    while not self:match("symbol", "}") do
        self:expect("keyword", "case")
        local pat = self:parse_pattern()
        self:expect("symbol", "=>")
        local stmt = self:parse_stmt()
        cases[#cases + 1] = { pattern = pat, stmt = stmt }
        self:consume_newlines()
    end
    return { kind = "Match", expr = expr, cases = cases, span = span_from(start, expr.span) }
end

-- Parses a match pattern
function Parser:parse_pattern()
    local tok = self:peek(0)
    if tok.type == "ident" and tok.value == "_" then
        self:next()
        return { kind = "PatternWildcard", span = span_of(tok) }
    end
    if tok.type == "number" or tok.type == "string" or (tok.type == "keyword" and (tok.value == "true" or tok.value == "false" or tok.value == "nil")) then
        local lit = self:parse_literal()
        return { kind = "PatternLiteral", value = lit, span = lit.span }
    end
        local expr = self:parse_expr()
        if expr.kind == "Ident" and expr.name == "_" then
            return { kind = "PatternWildcard", span = expr.span }
        end
        return { kind = "PatternExpr", expr = expr, span = expr.span }
end

-- Parses a block delimited by braces
function Parser:parse_block()
    self:expect("symbol", "{")
    local body = {}
    self:consume_newlines()
    while not self:match("symbol", "}") do
        body[#body + 1] = self:parse_stmt()
        self:consume_newlines()
    end
    return body
end

-- Parses an expression with precedence
function Parser:parse_expr()
    return self:parse_logic_or()
end

-- Parses logical OR expressions
function Parser:parse_logic_or()
    local left = self:parse_logic_and()
    while self:match("keyword", "or") do
        local right = self:parse_logic_and()
        left = { kind = "Binary", op = "or", left = left, right = right, span = span_from(left.span, right.span) }
    end
    return left
end

-- Parses logical AND expressions
function Parser:parse_logic_and()
    local left = self:parse_equality()
    while self:match("keyword", "and") do
        local right = self:parse_equality()
        left = { kind = "Binary", op = "and", left = left, right = right, span = span_from(left.span, right.span) }
    end
    return left
end

-- Parses equality expressions
function Parser:parse_equality()
    local left = self:parse_compare()
    while true do
        if self:match("symbol", "==") then
            local right = self:parse_compare()
            left = { kind = "Binary", op = "==", left = left, right = right, span = span_from(left.span, right.span) }
        elseif self:match("symbol", "~=") then
            local right = self:parse_compare()
            left = { kind = "Binary", op = "~=", left = left, right = right, span = span_from(left.span, right.span) }
        else
            break
        end
    end
    return left
end

-- Parses comparison expressions
function Parser:parse_compare()
    local left = self:parse_term()
    while true do
        if self:match("symbol", "<") then
            local right = self:parse_term()
            left = { kind = "Binary", op = "<", left = left, right = right, span = span_from(left.span, right.span) }
        elseif self:match("symbol", "<=") then
            local right = self:parse_term()
            left = { kind = "Binary", op = "<=", left = left, right = right, span = span_from(left.span, right.span) }
        elseif self:match("symbol", ">") then
            local right = self:parse_term()
            left = { kind = "Binary", op = ">", left = left, right = right, span = span_from(left.span, right.span) }
        elseif self:match("symbol", ">=") then
            local right = self:parse_term()
            left = { kind = "Binary", op = ">=", left = left, right = right, span = span_from(left.span, right.span) }
        else
            break
        end
    end
    return left
end

-- Parses additive expressions
function Parser:parse_term()
    local left = self:parse_factor()
    while true do
        if self:match("symbol", "+") then
            local right = self:parse_factor()
            left = { kind = "Binary", op = "+", left = left, right = right, span = span_from(left.span, right.span) }
        elseif self:match("symbol", "-") then
            local right = self:parse_factor()
            left = { kind = "Binary", op = "-", left = left, right = right, span = span_from(left.span, right.span) }
        else
            break
        end
    end
    return left
end

-- Parses multiplicative expressions
function Parser:parse_factor()
    local left = self:parse_unary()
    while true do
        if self:match("symbol", "*") then
            local right = self:parse_unary()
            left = { kind = "Binary", op = "*", left = left, right = right, span = span_from(left.span, right.span) }
        elseif self:match("symbol", "/") then
            local right = self:parse_unary()
            left = { kind = "Binary", op = "/", left = left, right = right, span = span_from(left.span, right.span) }
        elseif self:match("symbol", "%") then
            local right = self:parse_unary()
            left = { kind = "Binary", op = "%", left = left, right = right, span = span_from(left.span, right.span) }
        else
            break
        end
    end
    return left
end

-- Parses unary operators
function Parser:parse_unary()
    local tok = self:peek(0)
    if self:match("keyword", "not") then
        local expr = self:parse_unary()
        return { kind = "Unary", op = "not", expr = expr, span = span_from(tok, expr.span) }
    elseif self:match("symbol", "-") then
        local expr = self:parse_unary()
        return { kind = "Unary", op = "-", expr = expr, span = span_from(tok, expr.span) }
    elseif self:match("symbol", "#") then
        local expr = self:parse_unary()
        return { kind = "Unary", op = "#", expr = expr, span = span_from(tok, expr.span) }
    end
    return self:parse_power()
end

-- Parses exponentiation with right associativity
function Parser:parse_power()
    local left = self:parse_call()
    if self:match("symbol", "^") then
        local right = self:parse_power()
        return { kind = "Binary", op = "^", left = left, right = right, span = span_from(left.span, right.span) }
    end
    return left
end

-- Parses calls and indexing chains
function Parser:parse_call()
    local expr = self:parse_primary()
    while true do
        if self:match("symbol", "(") then
            local args = {}
            if not self:match("symbol", ")") then
                repeat
                    args[#args + 1] = self:parse_expr()
                until not self:match("symbol", ",")
                self:expect("symbol", ")")
            end
            local end_span = (args[#args] and args[#args].span) or expr.span
            expr = { kind = "Call", callee = expr, args = args, span = span_from(expr.span, end_span) }
        elseif self:match("symbol", ".") then
            local name_tok = self:expect("ident")
            local name = name_tok.value
            local key_node = { kind = "String", value = name, span = span_of(name_tok) }
            expr = { kind = "Index", base = expr, key = key_node, dot = true, span = span_from(expr.span, key_node.span) }
        elseif self:match("symbol", "[") then
            local key = self:parse_expr()
            self:expect("symbol", "]")
            expr = { kind = "Index", base = expr, key = key, dot = false, span = span_from(expr.span, key.span) }
        else
            break
        end
    end
    return expr
end

-- Parses literals, identifiers, grouping, and table literals
function Parser:parse_primary()
    local tok = self:peek(0)
    if tok.type == "ident" then
        self:next()
        return { kind = "Ident", name = tok.value, span = span_of(tok) }
    elseif tok.type == "number" then
        self:next()
        return { kind = "Number", value = tonumber(tok.value), span = span_of(tok) }
    elseif tok.type == "string" then
        self:next()
        return { kind = "String", value = tok.value, span = span_of(tok) }
    elseif tok.type == "keyword" and (tok.value == "true" or tok.value == "false" or tok.value == "nil") then
        self:next()
        if tok.value == "true" then
            return { kind = "Boolean", value = true, span = span_of(tok) }
        elseif tok.value == "false" then
            return { kind = "Boolean", value = false, span = span_of(tok) }
        else
            return { kind = "Nil", span = span_of(tok) }
        end
    elseif tok.type == "symbol" and tok.value == "(" then
        self:next()
        local expr = self:parse_expr()
        self:expect("symbol", ")")
        return expr
    elseif tok.type == "symbol" and tok.value == "{" then
        return self:parse_table()
    end

    error_at(tok, "unexpected token in expression")
end

-- Parses a literal token into an AST node
function Parser:parse_literal()
    local tok = self:peek(0)
    if tok.type == "number" then
        self:next()
        return { kind = "Number", value = tonumber(tok.value), span = span_of(tok) }
    elseif tok.type == "string" then
        self:next()
        return { kind = "String", value = tok.value, span = span_of(tok) }
    elseif tok.type == "keyword" then
        if tok.value == "true" or tok.value == "false" then
            self:next()
            return { kind = "Boolean", value = tok.value == "true", span = span_of(tok) }
        elseif tok.value == "nil" then
            self:next()
            return { kind = "Nil", span = span_of(tok) }
        end
    end
    error_at(tok, "expected literal")
end

-- Parses a table constructor
function Parser:parse_table()
    local start = self:expect("symbol", "{")
    local fields = {}
    self:consume_newlines()
    if self:match("symbol", "}") then
        return { kind = "Table", fields = fields, span = span_of(start) }
    end
    repeat
        local tok = self:peek(0)
        if tok.type == "ident" and self:peek(1).type == "symbol" and self:peek(1).value == "=" then
            local name_tok = self:next()
            local name = name_tok.value
            self:expect("symbol", "=")
            local value = self:parse_expr()
            fields[#fields + 1] = { kind = "Field", key = { kind = "String", value = name, span = span_of(name_tok) }, value = value, key_is_ident = true }
        elseif tok.type == "symbol" and tok.value == "[" then
            self:next()
            local key = self:parse_expr()
            self:expect("symbol", "]")
            self:expect("symbol", "=")
            local value = self:parse_expr()
            fields[#fields + 1] = { kind = "Field", key = key, value = value, key_is_ident = false }
        else
            local value = self:parse_expr()
            fields[#fields + 1] = { kind = "ArrayField", value = value }
        end
        self:consume_newlines()
    until not self:match("symbol", ",")
    self:expect("symbol", "}")
    return { kind = "Table", fields = fields, span = span_from(start, fields[#fields] and fields[#fields].value.span or span_of(start)) }
end

-- Parses an lvalue for assignment
function Parser:parse_lvalue()
    local base = self:expect("ident").value
    local node = { kind = "Ident", name = base }
    while true do
        if self:match("symbol", ".") then
            local name = self:expect("ident").value
            node = { kind = "Index", base = node, key = { kind = "String", value = name }, dot = true }
        elseif self:match("symbol", "[") then
            local key = self:parse_expr()
            self:expect("symbol", "]")
            node = { kind = "Index", base = node, key = key, dot = false }
        else
            break
        end
    end
    return node
end

-- Parses a type expression with unions
function Parser:parse_type_expr()
    local left = self:parse_type_primary()
    while self:match("symbol", "|") do
        local right = self:parse_type_primary()
        left = { kind = "TypeUnion", left = left, right = right }
    end
    return left
end

-- Parses a comma-separated type list
function Parser:parse_type_list()
    local items = {}
    if not self:match("symbol", ")") then
        repeat
            local texpr = self:parse_type_expr()
            items[#items + 1] = texpr
        until not self:match("symbol", ",")
        self:expect("symbol", ")")
    end
    return items
end

-- Parses a primary type expression
function Parser:parse_type_primary()
    local tok = self:peek(0)
    if tok.type == "ident" then
        self:next()
        return { kind = "TypeName", name = tok.value }
    elseif tok.type == "keyword" and tok.value == "nil" then
        self:next()
        return { kind = "TypeName", name = "nil" }
    elseif tok.type == "symbol" and tok.value == "(" then
        self:next()
        local params = self:parse_type_list()
        self:expect("symbol", "->")
        local ret = self:parse_type_expr()
        return { kind = "TypeFunc", params = params, ret = ret }
    elseif tok.type == "symbol" and tok.value == "{" then
        self:next()
        local fields = {}
        self:consume_newlines()
        if not self:match("symbol", "}") then
            repeat
                local name = self:expect("ident").value
                self:expect("symbol", ":")
                local texpr = self:parse_type_expr()
                fields[#fields + 1] = { name = name, type_expr = texpr }
                self:consume_newlines()
            until not self:match("symbol", ",")
            self:expect("symbol", "}")
        end
        return { kind = "TypeStruct", fields = fields }
    end
    error_at(tok, "invalid type expression")
end

return Parser
