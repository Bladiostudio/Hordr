-- Structural type checker with Luau-compatible rules
local Diagnostics = require("src.diagnostics")
local TypeChecker = {}

-- Constructs the top type
local function t_any()
    return { kind = "any" }
end

-- Constructs the bottom type
local function t_never()
    return { kind = "never" }
end

-- Constructs nil type
local function t_nil()
    return { kind = "nil" }
end

-- Constructs a primitive type
local function t_primitive(name)
    return { kind = name }
end

-- Constructs an enum type
local function t_enum(name, items)
    return { kind = "enum", name = name, items = items }
end

-- Constructs a structural table type
local function t_struct(fields)
    return { kind = "struct", fields = fields }
end

-- Constructs a struct constructor value type
local function t_struct_ctor(name, instance, ctor_params)
    return { kind = "struct_ctor", name = name, instance = instance, ctor_params = ctor_params or {} }
end

-- Constructs a function type
local function t_func(params, ret)
    return { kind = "func", params = params, ret = ret }
end

-- Constructs a union type with flattening
local function t_union(types)
    local flat = {}
    local seen = {}
    local function add(t)
        if t.kind == "union" then
            for _, u in ipairs(t.types) do
                add(u)
            end
            return
        end
        local key = t.kind
        if t.kind == "enum" then
            key = "enum:" .. t.name
        elseif t.kind == "struct" then
            key = "struct:" .. tostring(t)
        elseif t.kind == "func" then
            key = "func:" .. tostring(t)
        end
        if not seen[key] then
            seen[key] = true
            flat[#flat + 1] = t
        end
    end
    for _, t in ipairs(types) do
        add(t)
    end
    if #flat == 0 then
        return t_never()
    end
    if #flat == 1 then
        return flat[1]
    end
    return { kind = "union", types = flat }
end

-- Checks whether a type includes nil
local function is_nilable(t)
    if t.kind == "nil" then
        return true
    end
    if t.kind == "union" then
        for _, u in ipairs(t.types) do
            if u.kind == "nil" then
                return true
            end
        end
    end
    return false
end

-- Removes nil from a union type
local function remove_nil(t)
    if t.kind == "nil" then
        return t_never()
    end
    if t.kind ~= "union" then
        return t
    end
    local out = {}
    for _, u in ipairs(t.types) do
        if u.kind ~= "nil" then
            out[#out + 1] = u
        end
    end
    return t_union(out)
end

-- Formats a type for diagnostics
local function type_to_string(t)
    if t.kind == "any" or t.kind == "never" or t.kind == "nil" then
        return t.kind
    end
    if t.kind == "number" or t.kind == "string" or t.kind == "boolean" then
        return t.kind
    end
    if t.kind == "enum" then
        return t.name
    end
    if t.kind == "struct" then
        local parts = {}
        for name, ft in pairs(t.fields) do
            parts[#parts + 1] = name .. ": " .. type_to_string(ft)
        end
        table.sort(parts)
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    if t.kind == "struct_ctor" then
        return "type " .. t.name
    end
    if t.kind == "func" then
        local parts = {}
        for _, p in ipairs(t.params) do
            parts[#parts + 1] = type_to_string(p)
        end
        return "(" .. table.concat(parts, ", ") .. ") -> " .. type_to_string(t.ret)
    end
    if t.kind == "union" then
        local parts = {}
        for _, u in ipairs(t.types) do
            parts[#parts + 1] = type_to_string(u)
        end
        table.sort(parts)
        return table.concat(parts, " | ")
    end
    return "<unknown>"
end

-- Checks structural assignability
local function is_assignable(src, dst)
    if dst.kind == "any" or src.kind == "never" then
        return true
    end
    if src.kind == "any" then
        return true
    end
    if dst.kind == "union" then
        for _, u in ipairs(dst.types) do
            if is_assignable(src, u) then
                return true
            end
        end
        return false
    end
    if src.kind == "union" then
        for _, u in ipairs(src.types) do
            if not is_assignable(u, dst) then
                return false
            end
        end
        return true
    end
    if dst.kind == src.kind then
        if dst.kind == "enum" then
            return dst.name == src.name
        end
        if dst.kind == "struct_ctor" then
            return dst.name == src.name
        end
        if dst.kind == "struct" then
            for name, ft in pairs(dst.fields) do
                local st = src.fields[name]
                if not st or not is_assignable(st, ft) then
                    return false
                end
            end
            return true
        end
        if dst.kind == "func" then
            if #dst.params ~= #src.params then
                return false
            end
            for i = 1, #dst.params do
                local dp = dst.params[i]
                local sp = src.params[i]
                if not is_assignable(dp, sp) then
                    return false
                end
            end
            return is_assignable(src.ret, dst.ret)
        end
        return true
    end
    return false
end

-- Converts a type AST into a checker type
local function type_from_ast(node, types)
    if not node then
        return t_any()
    end
    if node.kind == "TypeName" then
        local name = node.name
        if name == "number" or name == "string" or name == "boolean" or name == "nil" or name == "any" or name == "never" then
            if name == "nil" then
                return t_nil()
            end
            if name == "any" then
                return t_any()
            end
            if name == "never" then
                return t_never()
            end
            return t_primitive(name)
        end
        if types and types[name] and types[name].kind == "enum" then
            return types[name]
        end
        if types and types[name] then
            return types[name]
        end
        return t_any()
    elseif node.kind == "TypeStruct" then
        local fields = {}
        for _, f in ipairs(node.fields) do
            fields[f.name] = type_from_ast(f.type_expr, types)
        end
        return t_struct(fields)
    elseif node.kind == "TypeUnion" then
        local left = type_from_ast(node.left, types)
        local right = type_from_ast(node.right, types)
        return t_union({ left, right })
    elseif node.kind == "TypeFunc" then
        local params = {}
        for _, p in ipairs(node.params) do
            params[#params + 1] = type_from_ast(p, types)
        end
        local ret = type_from_ast(node.ret, types)
        return t_func(params, ret)
    end
    return t_any()
end

-- Creates a scope for local types
local function new_scope(parent)
    return { parent = parent, locals = {} }
end

-- Looks up a name in the type scope
local function scope_lookup(scope, name)
    while scope do
        if scope.locals[name] then
            return scope.locals[name]
        end
        scope = scope.parent
    end
    return nil
end

-- Declares a name in the type scope
local function declare(scope, name, t)
    scope.locals[name] = t
end

-- Records a type error
local function error_at(state, span, msg, hints)
    Diagnostics.error(state.diagnostics, span, msg, hints)
end

-- Returns the type of a literal expression
local function type_of_literal(expr)
    if expr.kind == "Number" then
        return t_primitive("number")
    elseif expr.kind == "String" then
        return t_primitive("string")
    elseif expr.kind == "Boolean" then
        return t_primitive("boolean")
    elseif expr.kind == "Nil" then
        return t_nil()
    end
    return t_any()
end

-- Infers expression types and checks local constraints
local function type_of_expr(state, scope, expr, types, module_env)
    local kind = expr.kind
    if kind == "Ident" then
        local t = scope_lookup(scope, expr.name)
        if t then
            return t
        end
        return t_any()
    elseif kind == "Number" or kind == "String" or kind == "Boolean" or kind == "Nil" then
        return type_of_literal(expr)
    elseif kind == "Table" then
        local fields = {}
        local array_values = {}
        for _, f in ipairs(expr.fields) do
            if f.kind == "Field" then
                if f.key_is_ident and f.key.kind == "String" then
                    fields[f.key.value] = type_of_expr(state, scope, f.value, types, module_env)
                else
                    fields["[index]"] = t_any()
                end
            elseif f.kind == "ArrayField" then
                array_values[#array_values + 1] = type_of_expr(state, scope, f.value, types, module_env)
            end
        end
        if #array_values > 0 then
            fields["[index]"] = t_union(array_values)
        end
        return t_struct(fields)
    elseif kind == "Unary" then
        if expr.op == "not" then
            return t_primitive("boolean")
        end
        local inner = type_of_expr(state, scope, expr.expr, types, module_env)
        if expr.op == "-" or expr.op == "#" then
            if not is_assignable(inner, t_primitive("number")) then
                error_at(state, expr.span, "Expected number, got " .. type_to_string(inner))
            end
            return t_primitive("number")
        end
        return inner
    elseif kind == "Binary" then
        if expr.op == "and" or expr.op == "or" then
            local left = type_of_expr(state, scope, expr.left, types, module_env)
            local right = type_of_expr(state, scope, expr.right, types, module_env)
            return t_union({ left, right })
        end
        if expr.op == "==" or expr.op == "~=" or expr.op == "<" or expr.op == "<=" or expr.op == ">" or expr.op == ">=" then
            return t_primitive("boolean")
        end
        local left = type_of_expr(state, scope, expr.left, types, module_env)
        local right = type_of_expr(state, scope, expr.right, types, module_env)
        if not is_assignable(left, t_primitive("number")) then
            error_at(state, expr.left.span, "Expected number, got " .. type_to_string(left))
        end
        if not is_assignable(right, t_primitive("number")) then
            error_at(state, expr.right.span, "Expected number, got " .. type_to_string(right))
        end
        return t_primitive("number")
    elseif kind == "Call" then
        local callee_t = type_of_expr(state, scope, expr.callee, types, module_env)
        if callee_t.kind == "union" then
            for _, u in ipairs(callee_t.types) do
                if u.kind == "func" then
                    callee_t = u
                    break
                end
            end
        end
        if callee_t.kind == "func" then
            for i, arg in ipairs(expr.args) do
                local arg_t = type_of_expr(state, scope, arg, types, module_env)
                local param_t = callee_t.params[i] or t_any()
                if not is_assignable(arg_t, param_t) then
                    error_at(state, arg.span, "Argument " .. i .. ": expected " .. type_to_string(param_t) .. ", got " .. type_to_string(arg_t))
                end
            end
            return callee_t.ret
        elseif callee_t.kind ~= "any" then
            error_at(state, expr.callee.span, "Attempt to call non-function value of type " .. type_to_string(callee_t))
        end
        return t_any()
    elseif kind == "Index" then
        local base_t = type_of_expr(state, scope, expr.base, types, module_env)
        if expr.dot and expr.base.kind == "Ident" and module_env and module_env.import_aliases then
            local mod = module_env.import_aliases[expr.base.name]
            if mod and module_env.module_export_types and module_env.module_export_types[mod] then
                local exports = module_env.module_export_types[mod]
                local ft = exports[expr.key.value]
                if not ft then
                    error_at(state, expr.span, "Access to non-exported symbol '" .. expr.key.value .. "' from module '" .. mod .. "'")
                    return t_any()
                end
                return ft
            end
        end
        if expr.dot and expr.base.kind == "Ident" and types and types[expr.base.name] and types[expr.base.name].kind == "enum" then
            local enum = types[expr.base.name]
            for _, item in ipairs(enum.items or {}) do
                if item.name == expr.key.value then
                    return t_enum(expr.base.name, enum.items)
                end
            end
            error_at(state, expr.span, "Enum '" .. expr.base.name .. "' has no member '" .. expr.key.value .. "'")
            return t_any()
        end
        -- Struct constructors expose a .new function returning the instance type
        if base_t.kind == "struct_ctor" and expr.dot and expr.key.kind == "String" then
            if expr.key.value == "new" then
                return t_func(base_t.ctor_params or {}, base_t.instance)
            end
        end
        if is_nilable(base_t) then
            error_at(state, expr.span, "Cannot access field on possibly-nil value")
        end
        if base_t.kind == "struct" and expr.dot and expr.key.kind == "String" then
            local ft = base_t.fields[expr.key.value]
            if not ft then
                error_at(state, expr.span, "Field '" .. expr.key.value .. "' not present on type " .. type_to_string(base_t))
                return t_any()
            end
            return ft
        end
        return t_any()
    end
    return t_any()
end

-- Narrows union types on simple nil checks
local function narrow_from_condition(scope, expr, positive)
    if expr.kind == "Binary" and (expr.op == "==" or expr.op == "~=") then
        if expr.left.kind == "Ident" and expr.right.kind == "Nil" then
            local info = scope_lookup(scope, expr.left.name)
            if info and info.kind == "union" then
                if (expr.op == "~=" and positive) or (expr.op == "==" and not positive) then
                    declare(scope, expr.left.name, remove_nil(info))
                elseif (expr.op == "==" and positive) or (expr.op == "~=" and not positive) then
                    declare(scope, expr.left.name, t_nil())
                end
            end
        end
    elseif expr.kind == "Ident" then
        local info = scope_lookup(scope, expr.name)
        if info and info.kind == "union" then
            if positive then
                declare(scope, expr.name, remove_nil(info))
            else
                declare(scope, expr.name, t_union({ t_nil() }))
            end
        end
    end
end

-- Type-checks a block with an optional return type
local function analyze_block(state, scope, block, types, module_env, current_ret)
    for _, stmt in ipairs(block) do
        TypeChecker._stmt(state, scope, stmt, types, module_env, current_ret)
    end
end

-- Type-checks a single statement
function TypeChecker._stmt(state, scope, stmt, types, module_env, current_ret)
    local kind = stmt.kind
    if kind == "Let" then
        local decl_t = type_from_ast(stmt.type_expr, types)
        if stmt.init then
            local init_t = type_of_expr(state, scope, stmt.init, types, module_env)
            if stmt.type_expr and not is_assignable(init_t, decl_t) then
                error_at(state, stmt.init and stmt.init.span or stmt.name_span, "Expected " .. type_to_string(decl_t) .. ", got " .. type_to_string(init_t))
            end
            if not stmt.type_expr then
                decl_t = init_t
            end
        end
        declare(scope, stmt.name, decl_t)
    elseif kind == "Assign" then
        local target_t = t_any()
        if stmt.target.kind == "Ident" then
            target_t = scope_lookup(scope, stmt.target.name) or t_any()
        end
        local value_t = type_of_expr(state, scope, stmt.value, types, module_env)
        if stmt.target.kind == "Ident" and not is_assignable(value_t, target_t) then
            error_at(state, stmt.value and stmt.value.span or nil, "Expected " .. type_to_string(target_t) .. ", got " .. type_to_string(value_t))
        end
    elseif kind == "ExprStmt" then
        type_of_expr(state, scope, stmt.expr, types, module_env)
    elseif kind == "Function" then
        local fn_scope = new_scope(scope)
        local params = {}
        for _, p in ipairs(stmt.params) do
            local pt = type_from_ast(p.type_expr, types)
            params[#params + 1] = pt
            declare(fn_scope, p.name, pt)
        end
        local ret_t = type_from_ast(stmt.ret_type, types)
        if not stmt.ret_type then
            ret_t = t_any()
        end
        declare(scope, stmt.name, t_func(params, ret_t))
        analyze_block(state, fn_scope, stmt.body, types, module_env, ret_t)
    elseif kind == "Return" then
        if current_ret and stmt.expr then
            local ret_v = type_of_expr(state, scope, stmt.expr, types, module_env)
            if not is_assignable(ret_v, current_ret) then
                error_at(state, stmt.expr and stmt.expr.span or stmt.span, "Return type mismatch: expected " .. type_to_string(current_ret) .. ", got " .. type_to_string(ret_v))
            end
        end
    elseif kind == "If" then
        type_of_expr(state, scope, stmt.cond, types, module_env)
        local then_scope = new_scope(scope)
        narrow_from_condition(then_scope, stmt.cond, true)
        analyze_block(state, then_scope, stmt.then_block, types, module_env, current_ret)
        for _, eb in ipairs(stmt.elseif_blocks) do
            local eb_scope = new_scope(scope)
            narrow_from_condition(eb_scope, eb.cond, true)
            analyze_block(state, eb_scope, eb.block, types, module_env, current_ret)
        end
        if stmt.else_block then
            local else_scope = new_scope(scope)
            narrow_from_condition(else_scope, stmt.cond, false)
            analyze_block(state, else_scope, stmt.else_block, types, module_env, current_ret)
        end
    elseif kind == "While" then
        type_of_expr(state, scope, stmt.cond, types, module_env)
        local body_scope = new_scope(scope)
        analyze_block(state, body_scope, stmt.body, types, module_env, current_ret)
    elseif kind == "ForNum" then
        type_of_expr(state, scope, stmt.start, types, module_env)
        type_of_expr(state, scope, stmt.finish, types, module_env)
        if stmt.step then
            type_of_expr(state, scope, stmt.step, types, module_env)
        end
        local body_scope = new_scope(scope)
        declare(body_scope, stmt.name, t_primitive("number"))
        analyze_block(state, body_scope, stmt.body, types, module_env, current_ret)
    elseif kind == "ForIn" then
        type_of_expr(state, scope, stmt.iter, types, module_env)
        local body_scope = new_scope(scope)
        declare(body_scope, stmt.name, t_any())
        analyze_block(state, body_scope, stmt.body, types, module_env, current_ret)
    elseif kind == "Struct" then
        local fields = {}
        local ctor_params = {}
        for _, f in ipairs(stmt.fields) do
            fields[f.name] = type_from_ast(f.type_expr, types)
            ctor_params[#ctor_params + 1] = fields[f.name]
        end
        local instance = t_struct(fields)
        if types then
            types[stmt.name] = instance
        end
        declare(scope, stmt.name, t_struct_ctor(stmt.name, instance, ctor_params))
    elseif kind == "Enum" then
        local enum_t = t_enum(stmt.name, stmt.items)
        if types then
            types[stmt.name] = enum_t
        end
        declare(scope, stmt.name, enum_t)
    elseif kind == "Match" then
        local subject_t = type_of_expr(state, scope, stmt.expr, types, module_env)
        for _, c in ipairs(stmt.cases) do
            if c.pattern.kind == "PatternExpr" then
                type_of_expr(state, scope, c.pattern.expr, types, module_env)
            elseif c.pattern.kind == "PatternLiteral" then
                type_of_expr(state, scope, c.pattern.value, types, module_env)
            end
            local c_scope = new_scope(scope)
            if subject_t.kind == "enum" and c.pattern.kind == "PatternExpr" and c.pattern.expr.kind == "Index" then
                if c.pattern.expr.base.kind == "Ident" and c.pattern.expr.base.name == subject_t.name then
                    declare(c_scope, stmt.expr.name or "_", subject_t)
                end
            end
            analyze_block(state, c_scope, { c.stmt }, types, module_env, current_ret)
        end
    end
end

-- Builds exported type signatures for modules
function TypeChecker.build_export_types(ast)
    local types = {}
    for _, stmt in ipairs(ast.body) do
        if stmt.kind == "Enum" then
            types[stmt.name] = t_enum(stmt.name, stmt.items)
        elseif stmt.kind == "Struct" then
            local fields = {}
            for _, f in ipairs(stmt.fields) do
                fields[f.name] = type_from_ast(f.type_expr, types)
            end
            types[stmt.name] = t_struct(fields)
        end
    end

    local exports = {}
    local errors = {}
    for _, stmt in ipairs(ast.body) do
        if stmt.exported then
            if exports[stmt.name] then
                errors[#errors + 1] = "Duplicate export '" .. stmt.name .. "'"
            else
                if stmt.kind == "Function" then
                    local params = {}
                    for _, p in ipairs(stmt.params) do
                        params[#params + 1] = type_from_ast(p.type_expr, types)
                    end
                    local ret = type_from_ast(stmt.ret_type, types)
                    exports[stmt.name] = t_func(params, ret)
                elseif stmt.kind == "Struct" then
                    local instance = types[stmt.name] or t_struct({})
                    local ctor_params = {}
                    for _, f in ipairs(stmt.fields) do
                        ctor_params[#ctor_params + 1] = type_from_ast(f.type_expr, types)
                    end
                    exports[stmt.name] = t_struct_ctor(stmt.name, instance, ctor_params)
                elseif stmt.kind == "Enum" then
                    exports[stmt.name] = types[stmt.name]
                elseif stmt.kind == "Let" then
                    exports[stmt.name] = type_from_ast(stmt.type_expr, types)
                else
                    exports[stmt.name] = t_any()
                end
            end
        end
    end

    return exports, errors
end

-- Runs the type checker on a full AST
function TypeChecker.check(ast, module_env)
    local state = { diagnostics = Diagnostics.new() }
    local types = {}

    for _, stmt in ipairs(ast.body) do
        if stmt.kind == "Enum" then
            types[stmt.name] = t_enum(stmt.name, stmt.items)
        elseif stmt.kind == "Struct" then
            local fields = {}
            for _, f in ipairs(stmt.fields) do
                fields[f.name] = type_from_ast(f.type_expr, types)
            end
            types[stmt.name] = t_struct(fields)
        end
    end

    local scope = new_scope(nil)
    if module_env and module_env.import_types then
        for name, t in pairs(module_env.import_types) do
            declare(scope, name, t)
            if t.kind == "struct_ctor" then
                types[name] = t.instance
            elseif t.kind == "enum" then
                types[name] = t
            end
        end
    end

    for _, stmt in ipairs(ast.body) do
        TypeChecker._stmt(state, scope, stmt, types, module_env, nil)
    end

    return state.diagnostics
end

return TypeChecker
