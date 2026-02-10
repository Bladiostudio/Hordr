-- Generates readable Lua/Luau code from AST
local Codegen = {}

-- Creates a buffered writer with indentation state
local function new_writer()
    return { buf = {}, indent = 0 }
end

-- Appends raw text to the output buffer
local function write(w, s)
    w.buf[#w.buf + 1] = s
end

-- Writes an indented line
local function writeln(w, s)
    write(w, string.rep("    ", w.indent) .. s .. "\n")
end

-- Increases indentation level
local function indent(w)
    w.indent = w.indent + 1
end

-- Decreases indentation level
local function dedent(w)
    w.indent = w.indent - 1
end

-- Operator precedence table for formatting
local prec = {
    ["or"] = 1,
    ["and"] = 2,
    ["=="] = 3,
    ["~="] = 3,
    ["<"] = 4,
    ["<="] = 4,
    [">"] = 4,
    [">="] = 4,
    ["+"] = 5,
    ["-"] = 5,
    ["*"] = 6,
    ["/"] = 6,
    ["%"] = 6,
    ["unary"] = 7,
    ["^"] = 8,
    ["call"] = 9,
    ["primary"] = 10,
}

-- Removes quotes around identifier-like strings
local function strip_quotes(s)
    if s:sub(1, 1) == "\"" and s:sub(-1) == "\"" then
        return s:sub(2, -2)
    end
    return s
end

-- Emits Lua for an expression with correct precedence
local function expr_to_lua(expr, parent_prec)
    parent_prec = parent_prec or 0
    local kind = expr.kind

    if kind == "Ident" then
        return expr.name
    elseif kind == "Number" then
        return tostring(expr.value)
    elseif kind == "String" then
        return expr.value
    elseif kind == "Boolean" then
        return expr.value and "true" or "false"
    elseif kind == "Nil" then
        return "nil"
    elseif kind == "Unary" then
        local inner = expr_to_lua(expr.expr, prec.unary)
        local s = expr.op .. " " .. inner
        if prec.unary < parent_prec then
            return "(" .. s .. ")"
        end
        return s
    elseif kind == "Binary" then
        local p = prec[expr.op] or 1
        local left = expr_to_lua(expr.left, p)
        local right_prec = (expr.op == "^") and p or (p + 1)
        local right = expr_to_lua(expr.right, right_prec)
        local s = left .. " " .. expr.op .. " " .. right
        if p < parent_prec then
            return "(" .. s .. ")"
        end
        return s
    elseif kind == "Call" then
        local callee = expr_to_lua(expr.callee, prec.call)
        local args = {}
        for i, a in ipairs(expr.args) do
            args[i] = expr_to_lua(a, 0)
        end
        local s = callee .. "(" .. table.concat(args, ", ") .. ")"
        if prec.call < parent_prec then
            return "(" .. s .. ")"
        end
        return s
    elseif kind == "Index" then
        local base = expr_to_lua(expr.base, prec.call)
        if expr.dot then
            local name = strip_quotes(expr.key.value)
            return base .. "." .. name
        end
        local key = expr_to_lua(expr.key, 0)
        return base .. "[" .. key .. "]"
    elseif kind == "Table" then
        local parts = {}
        for _, f in ipairs(expr.fields) do
            if f.kind == "Field" then
                if f.key_is_ident then
                    parts[#parts + 1] = strip_quotes(f.key.value) .. " = " .. expr_to_lua(f.value, 0)
                else
                    parts[#parts + 1] = "[" .. expr_to_lua(f.key, 0) .. "] = " .. expr_to_lua(f.value, 0)
                end
            else
                parts[#parts + 1] = expr_to_lua(f.value, 0)
            end
        end
        if #parts == 0 then
            return "{}"
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end

    error("unknown expr kind: " .. tostring(kind))
end

-- Emits a block with proper indentation
local function emit_block(w, block)
    indent(w)
    for _, stmt in ipairs(block) do
        Codegen.emit_stmt(w, stmt)
    end
    dedent(w)
end

-- Emits a struct constructor as a plain table
local function emit_struct(w, stmt)
    writeln(w, "local " .. stmt.name .. " = {}")
    local params = {}
    local fields = {}
    for _, f in ipairs(stmt.fields) do
        params[#params + 1] = f.name
        fields[#fields + 1] = f.name .. " = " .. f.name
    end
    writeln(w, "function " .. stmt.name .. ".new(" .. table.concat(params, ", ") .. ")")
    indent(w)
    writeln(w, "return { " .. table.concat(fields, ", ") .. " }")
    dedent(w)
    writeln(w, "end")
end

-- Emits an enum as a table of constants
local function emit_enum(w, stmt)
    local items = {}
    local next_value = 1
    for _, item in ipairs(stmt.items) do
        local value = item.value or next_value
        items[#items + 1] = item.name .. " = " .. tostring(value)
        next_value = value + 1
    end
    writeln(w, "local " .. stmt.name .. " = { " .. table.concat(items, ", ") .. " }")
end

-- Checks whether a match subject can be inlined
local function is_simple_match_expr(expr)
    return expr.kind == "Ident" or expr.kind == "Number" or expr.kind == "String" or expr.kind == "Boolean" or expr.kind == "Nil"
end

-- Emits an export assignment to module table
local function emit_export_binding(w, stmt)
    writeln(w, "M." .. stmt.name .. " = " .. stmt.name)
end

-- Emits a single statement
function Codegen.emit_stmt(w, stmt)
    local kind = stmt.kind
    if kind == "Let" then
        if stmt.init then
            writeln(w, "local " .. stmt.name .. " = " .. expr_to_lua(stmt.init, 0))
        else
            writeln(w, "local " .. stmt.name)
        end
        if stmt.exported then
            emit_export_binding(w, stmt)
        end
    elseif kind == "Global" then
        writeln(w, stmt.name .. " = " .. expr_to_lua(stmt.init, 0))
    elseif kind == "Assign" then
        writeln(w, expr_to_lua(stmt.target, 0) .. " = " .. expr_to_lua(stmt.value, 0))
    elseif kind == "ExprStmt" then
        writeln(w, expr_to_lua(stmt.expr, 0))
    elseif kind == "Function" then
        local params = {}
        for _, p in ipairs(stmt.params) do
            params[#params + 1] = p.name
        end
        writeln(w, "local function " .. stmt.name .. "(" .. table.concat(params, ", ") .. ")")
        emit_block(w, stmt.body)
        writeln(w, "end")
        if stmt.exported then
            emit_export_binding(w, stmt)
        end
    elseif kind == "Struct" then
        emit_struct(w, stmt)
        if stmt.exported then
            emit_export_binding(w, stmt)
        end
    elseif kind == "Enum" then
        emit_enum(w, stmt)
        if stmt.exported then
            emit_export_binding(w, stmt)
        end
    elseif kind == "If" then
        writeln(w, "if " .. expr_to_lua(stmt.cond, 0) .. " then")
        emit_block(w, stmt.then_block)
        for _, eb in ipairs(stmt.elseif_blocks) do
            writeln(w, "elseif " .. expr_to_lua(eb.cond, 0) .. " then")
            emit_block(w, eb.block)
        end
        if stmt.else_block then
            writeln(w, "else")
            emit_block(w, stmt.else_block)
        end
        writeln(w, "end")
    elseif kind == "While" then
        writeln(w, "while " .. expr_to_lua(stmt.cond, 0) .. " do")
        emit_block(w, stmt.body)
        writeln(w, "end")
    elseif kind == "ForNum" then
        local line = "for " .. stmt.name .. " = " .. expr_to_lua(stmt.start, 0) .. ", " .. expr_to_lua(stmt.finish, 0)
        if stmt.step then
            line = line .. ", " .. expr_to_lua(stmt.step, 0)
        end
        writeln(w, line .. " do")
        emit_block(w, stmt.body)
        writeln(w, "end")
    elseif kind == "ForIn" then
        writeln(w, "for " .. stmt.name .. " in " .. expr_to_lua(stmt.iter, 0) .. " do")
        emit_block(w, stmt.body)
        writeln(w, "end")
    elseif kind == "Return" then
        if stmt.expr then
            writeln(w, "return " .. expr_to_lua(stmt.expr, 0))
        else
            writeln(w, "return")
        end
    elseif kind == "Match" then
        local subject = expr_to_lua(stmt.expr, 0)
        local tmp = nil
        if not is_simple_match_expr(stmt.expr) then
            tmp = "__match" .. tostring(w.__match_id or 0)
            w.__match_id = (w.__match_id or 0) + 1
            writeln(w, "local " .. tmp .. " = " .. subject)
            subject = tmp
        end
        local first = true
        local has_else = false
        for _, c in ipairs(stmt.cases) do
            if c.pattern.kind == "PatternWildcard" then
                has_else = true
                writeln(w, first and "if true then" or "else")
                emit_block(w, { c.stmt })
                break
            elseif c.pattern.kind == "PatternLiteral" then
                local pat = expr_to_lua(c.pattern.value, 0)
                writeln(w, (first and "if " or "elseif ") .. subject .. " == " .. pat .. " then")
                emit_block(w, { c.stmt })
            elseif c.pattern.kind == "PatternIdent" then
                local pat = c.pattern.name
                writeln(w, (first and "if " or "elseif ") .. subject .. " == " .. pat .. " then")
                emit_block(w, { c.stmt })
            elseif c.pattern.kind == "PatternExpr" then
                local pat = expr_to_lua(c.pattern.expr, 0)
                writeln(w, (first and "if " or "elseif ") .. subject .. " == " .. pat .. " then")
                emit_block(w, { c.stmt })
            end
            first = false
        end
        if not has_else then
            writeln(w, "end")
        else
            writeln(w, "end")
        end
    else
        error("unknown stmt kind: " .. tostring(kind))
    end
end

-- Generates Lua source for a full AST
function Codegen.generate(ast)
    local w = new_writer()
    if ast.module then
        local import_id = 0
        for _, imp in ipairs(ast.imports or {}) do
            if imp.names then
                local alias = imp.alias or ("__import" .. tostring(import_id))
                import_id = import_id + 1
                writeln(w, "local " .. alias .. " = require(\"" .. imp.module .. "\")")
                for _, name in ipairs(imp.names) do
                    writeln(w, "local " .. name .. " = " .. alias .. "." .. name)
                end
            else
                local alias = imp.alias
                if not alias then
                    local parts = {}
                    for part in imp.module:gmatch("[^%.]+") do
                        parts[#parts + 1] = part
                    end
                    alias = parts[#parts] or imp.module
                end
                writeln(w, "local " .. alias .. " = require(\"" .. imp.module .. "\")")
            end
        end

        writeln(w, "local M = {}")
        for _, stmt in ipairs(ast.body) do
            Codegen.emit_stmt(w, stmt)
        end
        writeln(w, "return M")
        return table.concat(w.buf)
    end

    for _, stmt in ipairs(ast.body) do
        Codegen.emit_stmt(w, stmt)
    end
    return table.concat(w.buf)
end

return Codegen
