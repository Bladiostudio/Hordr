-- Compiler entry points for single files and module sets
local Lexer = require("src.lexer")
local Parser = require("src.parser")
local Analyzer = require("src.analyzer")
local Optimizer = require("src.optimizer")
local Codegen = require("src.codegen")
local TypeChecker = require("src.typechecker")
local Diagnostics = require("src.diagnostics")

local M = {}

-- Parses source into an AST with spans
local function parse_source(source, file)
    local tokens = Lexer.lex(source, file)
    local parser = Parser.new(tokens)
    return parser:parse_program()
end

-- Compiles a single source file to Lua
function M.compile(source, opts)
    opts = opts or {}
    local diagnostics = Diagnostics.new()
    local ok, ast_or_err = pcall(function()
        return parse_source(source, opts.filename)
    end)
    if not ok then
        if type(ast_or_err) == "table" and ast_or_err.kind == "ParseError" then
            local t = ast_or_err.token
            Diagnostics.error(diagnostics, t, ast_or_err.message)
            return nil, diagnostics
        end
        Diagnostics.error(diagnostics, nil, tostring(ast_or_err))
        return nil, diagnostics
    end
    local ast = ast_or_err

    local analysis = Analyzer.analyze(ast, nil, diagnostics)
    local type_state = TypeChecker.check(ast)
    Diagnostics.merge(diagnostics, type_state)
    if Diagnostics.has_errors(diagnostics) then
        return nil, diagnostics
    end

    ast = Optimizer.optimize(ast)
    local out = Codegen.generate(ast)
    return out, diagnostics
end

-- Collects exported names for module checks
local function build_exports(ast)
    local exports = {}
    local errors = {}
    for _, stmt in ipairs(ast.body) do
        if stmt.exported then
            if exports[stmt.name] then
                errors[#errors + 1] = "Duplicate export '" .. stmt.name .. "'"
            else
                exports[stmt.name] = true
            end
        end
    end
    return exports, errors
end

-- Derives a default import alias from a module name
local function default_alias(module_name)
    local parts = {}
    for part in module_name:gmatch("[^%.]+") do
        parts[#parts + 1] = part
    end
    return parts[#parts] or module_name
end

-- Detects direct and indirect import cycles
local function detect_cycles(graph)
    local temp = {}
    local perm = {}
    local errors = {}

    local function visit(node, stack)
        if perm[node] then
            return
        end
        if temp[node] then
            local cycle = table.concat(stack, " -> ") .. " -> " .. node
            errors[#errors + 1] = "Circular import detected: " .. cycle
            return
        end
        temp[node] = true
        stack[#stack + 1] = node
        for dep, _ in pairs(graph[node] or {}) do
            visit(dep, stack)
        end
        stack[#stack] = nil
        temp[node] = nil
        perm[node] = true
    end

    for node, _ in pairs(graph) do
        visit(node, {})
    end

    return errors
end

-- Compiles a set of modules keyed by module name
function M.compile_modules(sources, opts)
    opts = opts or {}
    local asts = {}
    local diagnostics = Diagnostics.new()

    for module_name, source in pairs(sources) do
        local ok, ast_or_err = pcall(function()
            return parse_source(source, module_name)
        end)
        if not ok then
            if type(ast_or_err) == "table" and ast_or_err.kind == "ParseError" then
                Diagnostics.error(diagnostics, ast_or_err.token, ast_or_err.message)
            else
                Diagnostics.error(diagnostics, nil, tostring(ast_or_err))
            end
        else
            local ast = ast_or_err
            if not ast.module then
                Diagnostics.error(diagnostics, ast.module_span, "Missing module declaration in '" .. module_name .. "'")
            elseif ast.module ~= module_name then
                Diagnostics.error(diagnostics, ast.module_span, "Module name mismatch: expected '" .. module_name .. "', got '" .. ast.module .. "'")
            end
            asts[module_name] = ast
        end
    end

    if Diagnostics.has_errors(diagnostics) then
        return nil, diagnostics
    end

    local module_exports = {}
    local module_export_types = {}
    for module_name, ast in pairs(asts) do
        local exports, errors = build_exports(ast)
        module_exports[module_name] = exports
        for _, e in ipairs(errors) do
            Diagnostics.error(diagnostics, ast.module_span, "In module '" .. module_name .. "': " .. e)
        end
        local types, type_errors = TypeChecker.build_export_types(ast)
        module_export_types[module_name] = types
        for _, e in ipairs(type_errors) do
            Diagnostics.error(diagnostics, ast.module_span, "In module '" .. module_name .. "': " .. e)
        end
    end

    local graph = {}
    for module_name, ast in pairs(asts) do
        graph[module_name] = {}
        local seen_import_names = {}
        for _, imp in ipairs(ast.imports or {}) do
            if not asts[imp.module] then
                Diagnostics.error(diagnostics, imp.span, "In module '" .. module_name .. "': unknown module '" .. imp.module .. "'")
            else
                graph[module_name][imp.module] = true
            end

            if imp.names then
                for _, name in ipairs(imp.names) do
                    local exports = module_exports[imp.module]
                    if exports and not exports[name] then
                        Diagnostics.error(diagnostics, imp.span, "In module '" .. module_name .. "': module '" .. imp.module .. "' does not export '" .. name .. "'")
                    end
                    if seen_import_names[name] then
                        Diagnostics.error(diagnostics, imp.span, "In module '" .. module_name .. "': duplicate import name '" .. name .. "'")
                    end
                    seen_import_names[name] = true
                end
            else
                local alias = imp.alias or default_alias(imp.module)
                imp.default_alias = alias
                if seen_import_names[alias] then
                    Diagnostics.error(diagnostics, imp.span, "In module '" .. module_name .. "': duplicate import name '" .. alias .. "'")
                end
                seen_import_names[alias] = true
            end
        end

        for _, stmt in ipairs(ast.body) do
            if stmt.name and seen_import_names[stmt.name] then
                Diagnostics.error(diagnostics, stmt.name_span or stmt.span, "In module '" .. module_name .. "': name collision between import and local '" .. stmt.name .. "'")
            end
        end
    end

    local cycle_errors = detect_cycles(graph)
    for _, e in ipairs(cycle_errors) do
        Diagnostics.error(diagnostics, nil, e)
    end

    if Diagnostics.has_errors(diagnostics) then
        return nil, diagnostics
    end

    local outputs = {}
    for module_name, ast in pairs(asts) do
        local import_aliases = {}
        local import_types = {}
        for _, imp in ipairs(ast.imports or {}) do
            if not imp.names then
                local alias = imp.alias or imp.default_alias
                import_aliases[alias] = imp.module
                local exports = module_export_types[imp.module] or {}
                local fields = {}
                for name, t in pairs(exports) do
                    fields[name] = t
                end
                import_types[alias] = { kind = "struct", fields = fields }
            else
                local exports = module_export_types[imp.module] or {}
                for _, name in ipairs(imp.names) do
                    import_types[name] = exports[name] or { kind = "any" }
                end
            end
        end

        local mod_env = {
            module_name = module_name,
            imports = ast.imports or {},
            import_aliases = import_aliases,
            module_exports = module_exports,
            module_export_types = module_export_types,
            import_types = import_types,
        }

        local mod_analysis = Analyzer.analyze(ast, mod_env)
        Diagnostics.merge(diagnostics, mod_analysis)
        local type_state = TypeChecker.check(ast, mod_env)
        Diagnostics.merge(diagnostics, type_state)
    end

    if Diagnostics.has_errors(diagnostics) then
        return nil, diagnostics
    end

    for module_name, ast in pairs(asts) do
        outputs[module_name] = Codegen.generate(ast)
    end

    return outputs, diagnostics
end

return M
