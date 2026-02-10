-- Flow-sensitive analysis and semantic checks
local Diagnostics = require("src.diagnostics")
local Analyzer = {}

-- Allowed global reads in plain Lua
local default_globals = {
    _G = true,
    assert = true,
    error = true,
    ipairs = true,
    next = true,
    pairs = true,
    pcall = true,
    print = true,
    select = true,
    tonumber = true,
    tostring = true,
    type = true,
    unpack = true,
    xpcall = true,
    math = true,
    string = true,
    table = true,
    coroutine = true,
    os = true,
    utf8 = true,
    require = true,
}

-- Creates a scope for locals and enums
local function new_scope(parent)
    return { parent = parent, locals = {}, enums = {} }
end

-- Finds a local by name up the scope chain
local function scope_lookup(scope, name)
    while scope do
        if scope.locals[name] then
            return scope.locals[name], scope
        end
        scope = scope.parent
    end
    return nil, nil
end

-- Finds an enum declaration by name
local function enum_lookup(scope, name)
    while scope do
        if scope.enums[name] then
            return scope.enums[name]
        end
        scope = scope.parent
    end
    return nil
end

-- Records an error diagnostic
local function add_error(state, a, b, c)
    local span, msg, hints
    if b ~= nil then
        span = a
        msg = b
        hints = c
    else
        span = nil
        msg = a
        hints = b
    end
    Diagnostics.error(state.diagnostics, span, msg, hints)
end

-- Records a warning diagnostic
local function add_warning(state, a, b, c)
    local span, msg, hints
    if b ~= nil then
        span = a
        msg = b
        hints = c
    else
        span = nil
        msg = a
        hints = b
    end
    Diagnostics.warn(state.diagnostics, span, msg, hints)
end

-- Marks a local as used if it exists
local function mark_used(scope, name)
    local info = scope_lookup(scope, name)
    if info then
        info.used = true
        return true
    end
    return false
end

-- Declares a local and tracks shadowing
local function declare_local(state, scope, name, info)
    if name == "_" then
        return
    end
    if scope.locals[name] then
        add_error(state, scope.locals[name].span or (info and info.span) or nil, "Duplicate local '" .. name .. "' in the same scope")
        return
    end
    if scope.parent then
        local parent_info = scope_lookup(scope.parent, name)
        if parent_info then
            add_warning(state, info and info.span or nil, "Shadowing local '" .. name .. "'")
        end
    end
    scope.locals[name] = {
        used = false,
        assigned = info and info.assigned or false,
        nilness = info and info.nilness or "maybe_nil",
        type_name = info and info.type_name or nil,
    }
end

-- Marks a local as assigned and updates nilness
local function set_assigned(scope, name, nilness)
    local info = scope_lookup(scope, name)
    if info then
        info.assigned = true
        info.nilness = nilness or "unknown"
    end
end

-- Emits warnings for unused locals
local function check_unused(state, scope)
    for name, info in pairs(scope.locals) do
        if name ~= "_" and not info.used then
            add_warning(state, info.span, "Unused local '" .. name .. "'")
        end
    end
end

-- Merges nilness across control-flow paths
local function nilness_merge(a, b)
    if a == "non_nil" and b == "non_nil" then
        return "non_nil"
    end
    if a == "unknown" or b == "unknown" then
        return "unknown"
    end
    return "maybe_nil"
end

-- Takes a snapshot of assignment state
local function snapshot(scope)
    local snap = {}
    for name, info in pairs(scope.locals) do
        snap[name] = { assigned = info.assigned, nilness = info.nilness }
    end
    return snap
end

-- Restores assignment state from a snapshot
local function restore(scope, snap)
    for name, info in pairs(scope.locals) do
        local s = snap[name]
        if s then
            info.assigned = s.assigned
            info.nilness = s.nilness
        end
    end
end

-- Merges two snapshots conservatively
local function merge_snapshots(a, b)
    local out = {}
    for name, sa in pairs(a) do
        local sb = b[name] or { assigned = false, nilness = "unknown" }
        local assigned = sa.assigned and sb.assigned
        local nilness
        if not assigned then
            nilness = "maybe_nil"
        else
            nilness = nilness_merge(sa.nilness, sb.nilness)
        end
        out[name] = { assigned = assigned, nilness = nilness }
    end
    return out
end

-- Estimates nilness for simple expressions
local function expr_nilness(scope, expr)
    local kind = expr.kind
    if kind == "Number" or kind == "String" or kind == "Boolean" then
        return "non_nil"
    elseif kind == "Nil" then
        return "maybe_nil"
    elseif kind == "Table" then
        return "non_nil"
    elseif kind == "Unary" then
        if expr.op == "-" or expr.op == "#" or expr.op == "not" then
            return "non_nil"
        end
    elseif kind == "Binary" then
        if expr.op == "+" or expr.op == "-" or expr.op == "*" or expr.op == "/" or expr.op == "%" or expr.op == "^" then
            return "non_nil"
        end
        if expr.op == "==" or expr.op == "~=" or expr.op == "<" or expr.op == "<=" or expr.op == ">" or expr.op == ">=" then
            return "non_nil"
        end
    elseif kind == "Ident" then
        local info = scope_lookup(scope, expr.name)
        if info then
            return info.nilness
        end
    end
    return "unknown"
end

-- Evaluates simple constant expressions
local function const_value(expr)
    local kind = expr.kind
    if kind == "Number" then
        return { kind = "number", value = expr.value }
    elseif kind == "String" then
        return { kind = "string", value = expr.value }
    elseif kind == "Boolean" then
        return { kind = "boolean", value = expr.value }
    elseif kind == "Nil" then
        return { kind = "nil", value = nil }
    elseif kind == "Unary" then
        local inner = const_value(expr.expr)
        if not inner then
            return nil
        end
        if expr.op == "not" then
            if inner.kind == "boolean" then
                return { kind = "boolean", value = not inner.value }
            end
            if inner.kind == "nil" then
                return { kind = "boolean", value = true }
            end
            return { kind = "boolean", value = false }
        elseif expr.op == "-" and inner.kind == "number" then
            return { kind = "number", value = -inner.value }
        end
    elseif kind == "Binary" then
        local a = const_value(expr.left)
        local b = const_value(expr.right)
        if not a or not b then
            return nil
        end
        if expr.op == "and" or expr.op == "or" then
            local function truthy(v)
                if v.kind == "nil" then
                    return false
                end
                if v.kind == "boolean" then
                    return v.value
                end
                return true
            end
            if expr.op == "and" then
                if truthy(a) then
                    return b
                end
                return a
            else
                if truthy(a) then
                    return a
                end
                return b
            end
        end
        if expr.op == "==" then
            return { kind = "boolean", value = a.value == b.value }
        elseif expr.op == "~=" then
            return { kind = "boolean", value = a.value ~= b.value }
        elseif expr.op == "<" or expr.op == "<=" or expr.op == ">" or expr.op == ">=" then
            if a.kind == "number" and b.kind == "number" then
                if expr.op == "<" then return { kind = "boolean", value = a.value < b.value } end
                if expr.op == "<=" then return { kind = "boolean", value = a.value <= b.value } end
                if expr.op == ">" then return { kind = "boolean", value = a.value > b.value } end
                if expr.op == ">=" then return { kind = "boolean", value = a.value >= b.value } end
            end
        elseif expr.op == "+" or expr.op == "-" or expr.op == "*" or expr.op == "/" or expr.op == "%" or expr.op == "^" then
            if a.kind == "number" and b.kind == "number" then
                if expr.op == "+" then return { kind = "number", value = a.value + b.value } end
                if expr.op == "-" then return { kind = "number", value = a.value - b.value } end
                if expr.op == "*" then return { kind = "number", value = a.value * b.value } end
                if expr.op == "/" then return { kind = "number", value = a.value / b.value } end
                if expr.op == "%" then return { kind = "number", value = a.value % b.value } end
                if expr.op == "^" then return { kind = "number", value = a.value ^ b.value } end
            end
        end
    end
    return nil
end

-- Computes constant truthiness when possible
local function const_truthiness(expr)
    local v = const_value(expr)
    if not v then
        return nil
    end
    if v.kind == "nil" then
        return false
    end
    if v.kind == "boolean" then
        return v.value
    end
    return true
end

-- Narrows nilness based on simple conditions
local function narrow_nil(scope, expr, truthy)
    if expr.kind == "Binary" and (expr.op == "==" or expr.op == "~=") then
        if expr.left.kind == "Ident" and expr.right.kind == "Nil" then
            local info = scope_lookup(scope, expr.left.name)
            if info then
                if (expr.op == "~=" and truthy) or (expr.op == "==" and not truthy) then
                    info.nilness = "non_nil"
                elseif (expr.op == "==" and truthy) or (expr.op == "~=" and not truthy) then
                    info.nilness = "maybe_nil"
                end
            end
        end
    elseif expr.kind == "Ident" then
        local info = scope_lookup(scope, expr.name)
        if info then
            if truthy then
                info.nilness = "non_nil"
            else
                info.nilness = "maybe_nil"
            end
        end
    end
end

-- Analyzes expressions for use/undef and nil misuse
local function analyze_expr(state, scope, expr, module_env)
    local kind = expr.kind
    if kind == "Ident" then
        local info = scope_lookup(scope, expr.name)
        if info then
            info.used = true
            if not info.assigned then
                add_error(state, expr.span, "Use of '" .. expr.name .. "' before assignment", { "Assign to '" .. expr.name .. "' before reading it." })
            end
        else
            if not default_globals[expr.name] and not state.allowed_globals[expr.name] then
                add_error(state, expr.span, "Undefined variable '" .. expr.name .. "'")
            end
        end
    elseif kind == "Binary" then
        analyze_expr(state, scope, expr.left, module_env)
        analyze_expr(state, scope, expr.right, module_env)
    elseif kind == "Unary" then
        analyze_expr(state, scope, expr.expr, module_env)
    elseif kind == "Call" then
        analyze_expr(state, scope, expr.callee, module_env)
        for _, arg in ipairs(expr.args) do
            analyze_expr(state, scope, arg, module_env)
        end
    elseif kind == "Index" then
        analyze_expr(state, scope, expr.base, module_env)
        analyze_expr(state, scope, expr.key, module_env)
        if expr.base.kind == "Ident" then
            local info = scope_lookup(scope, expr.base.name)
            if info and info.nilness == "maybe_nil" then
                add_error(state, expr.span, "Cannot access field on possibly-nil value")
            end
            if module_env and module_env.import_aliases and expr.dot then
                local mod = module_env.import_aliases[expr.base.name]
                if mod and expr.key.kind == "String" then
                    local export_set = module_env.module_exports and module_env.module_exports[mod]
                    if export_set and not export_set[expr.key.value] then
                        add_error(state, expr.span, "Access to non-exported symbol '" .. expr.key.value .. "' from module '" .. mod .. "'")
                    end
                end
            end
        end
    elseif kind == "Table" then
        for _, field in ipairs(expr.fields) do
            if field.kind == "Field" then
                analyze_expr(state, scope, field.key, module_env)
                analyze_expr(state, scope, field.value, module_env)
            elseif field.kind == "ArrayField" then
                analyze_expr(state, scope, field.value, module_env)
            end
        end
    end
end

-- Validates assignment targets
local function analyze_lvalue(state, scope, target, module_env)
    if target.kind == "Ident" then
        local info = scope_lookup(scope, target.name)
        if not info and not state.allowed_globals[target.name] then
            add_error(state, target.span, "Assignment to undefined variable '" .. target.name .. "'")
        end
        return
    end
    if target.kind == "Index" then
        analyze_expr(state, scope, target.base, module_env)
        analyze_expr(state, scope, target.key, module_env)
        if target.base.kind == "Ident" then
            local info = scope_lookup(scope, target.base.name)
            if info and info.nilness == "maybe_nil" then
                add_error(state, target.span, "Cannot access field on possibly-nil value")
            end
        end
        return
    end
end

local analyze_block

-- Analyzes a single statement and return flow
local function analyze_stmt(state, scope, stmt, in_function, module_env)
    local function no_return()
        return { always_returns = false, any_with = false, any_without = false }
    end

    local kind = stmt.kind
    if kind == "Let" then
        local type_name = nil
        if stmt.type_expr and stmt.type_expr.kind == "TypeName" then
            type_name = stmt.type_expr.name
        end
        declare_local(state, scope, stmt.name, { assigned = false, nilness = "maybe_nil", type_name = type_name, span = stmt.name_span })
        if stmt.init then
            analyze_expr(state, scope, stmt.init, module_env)
            local nilness = expr_nilness(scope, stmt.init)
            if stmt.type_expr and (stmt.type_expr.kind == "TypeName" or stmt.type_expr.kind == "TypeStruct") then
                nilness = "non_nil"
            end
            set_assigned(scope, stmt.name, nilness)
        end
        return no_return()
    elseif kind == "Global" then
        state.allowed_globals[stmt.name] = true
        analyze_expr(state, scope, stmt.init, module_env)
        return no_return()
    elseif kind == "Assign" then
        analyze_lvalue(state, scope, stmt.target, module_env)
        analyze_expr(state, scope, stmt.value, module_env)
        if stmt.target.kind == "Ident" then
            set_assigned(scope, stmt.target.name, expr_nilness(scope, stmt.value))
        end
        return no_return()
    elseif kind == "ExprStmt" then
        analyze_expr(state, scope, stmt.expr, module_env)
        return no_return()
    elseif kind == "Function" then
        declare_local(state, scope, stmt.name, { assigned = true, nilness = "non_nil", span = stmt.name_span })
        local fn_scope = new_scope(scope)
        for _, p in ipairs(stmt.params) do
            local type_name = nil
            local nilness = "unknown"
            if p.type_expr and p.type_expr.kind == "TypeName" then
                type_name = p.type_expr.name
                nilness = "non_nil"
            elseif p.type_expr and p.type_expr.kind == "TypeStruct" then
                nilness = "non_nil"
            end
            declare_local(state, fn_scope, p.name, { assigned = true, nilness = nilness, type_name = type_name, span = p.span })
        end
        local info = analyze_block(state, fn_scope, stmt.body, true, module_env)
        -- Require consistent return shape when any return value is used
        if info.any_with and info.any_without then
            add_error(state, stmt.name_span, "Inconsistent return values in function '" .. stmt.name .. "'")
        end
        -- Enforce complete return paths for typed functions
        if (stmt.ret_type or info.any_with) and not info.always_returns then
            add_error(state, stmt.name_span, "Missing return on some paths in function '" .. stmt.name .. "'")
        end
        check_unused(state, fn_scope)
        return no_return()
    elseif kind == "Struct" then
        declare_local(state, scope, stmt.name, { assigned = true, nilness = "non_nil", span = stmt.name_span })
        return no_return()
    elseif kind == "Enum" then
        declare_local(state, scope, stmt.name, { assigned = true, nilness = "non_nil", span = stmt.name_span })
        scope.enums[stmt.name] = stmt.items
        return no_return()
    elseif kind == "If" then
        analyze_expr(state, scope, stmt.cond, module_env)
        local cond_truth = const_truthiness(stmt.cond)
        if cond_truth == false then
            add_warning(state, stmt.cond.span, "Unreachable 'if' branch (condition is always false)")
        end
        local pre = snapshot(scope)
        local merged = nil
        local all_return = true
        local any_with = false
        local any_without = false
        local prior_true = (cond_truth == true)

        local function analyze_branch(block, reachable, cond, truthy)
            restore(scope, pre)
            if cond then
                narrow_nil(scope, cond, truthy)
            end
            local info = analyze_block(state, scope, block, in_function, module_env)
            local post = snapshot(scope)
            if merged then
                merged = merge_snapshots(merged, post)
            else
                merged = post
            end
            if reachable then
                all_return = all_return and info.always_returns
                any_with = any_with or info.any_with
                any_without = any_without or info.any_without
            end
        end

        analyze_branch(stmt.then_block, cond_truth ~= false, stmt.cond, true)

        local any_elseif = false
        for _, eb in ipairs(stmt.elseif_blocks) do
            analyze_expr(state, scope, eb.cond, module_env)
            local et = const_truthiness(eb.cond)
            if prior_true then
                add_warning(state, eb.cond.span, "Unreachable 'elseif' branch (previous condition is always true)")
            end
            if et == false then
                add_warning(state, eb.cond.span, "Unreachable 'elseif' branch (condition is always false)")
            end
            analyze_branch(eb.block, et ~= false, eb.cond, true)
            any_elseif = true
            if et == true then
                prior_true = true
            end
        end

        if stmt.else_block then
            if prior_true then
                add_warning(state, stmt.cond.span, "Unreachable 'else' branch (condition is always true)")
            end
            analyze_branch(stmt.else_block, not prior_true, stmt.cond, false)
        else
            if merged then
                merged = merge_snapshots(merged, pre)
            else
                merged = pre
            end
            all_return = false
        end

        restore(scope, merged)
        return { always_returns = all_return, any_with = any_with, any_without = any_without }
    elseif kind == "While" then
        analyze_expr(state, scope, stmt.cond, module_env)
        local cond_truth = const_truthiness(stmt.cond)
        if cond_truth == false then
            add_warning(state, stmt.cond.span, "Unreachable 'while' body (condition is always false)")
        end
        local pre = snapshot(scope)
        local w_scope = new_scope(scope)
        analyze_block(state, w_scope, stmt.body, in_function, module_env)
        check_unused(state, w_scope)
        restore(scope, pre)
        return no_return()
    elseif kind == "ForNum" then
        local f_scope = new_scope(scope)
        declare_local(state, f_scope, stmt.name, { assigned = true, nilness = "non_nil" })
        analyze_expr(state, scope, stmt.start, module_env)
        analyze_expr(state, scope, stmt.finish, module_env)
        if stmt.step then
            analyze_expr(state, scope, stmt.step, module_env)
        end
        analyze_block(state, f_scope, stmt.body, in_function, module_env)
        check_unused(state, f_scope)
        return no_return()
    elseif kind == "ForIn" then
        local f_scope = new_scope(scope)
        declare_local(state, f_scope, stmt.name, { assigned = true, nilness = "unknown" })
        analyze_expr(state, scope, stmt.iter, module_env)
        analyze_block(state, f_scope, stmt.body, in_function, module_env)
        check_unused(state, f_scope)
        return no_return()
    elseif kind == "Return" then
        if stmt.expr then
            analyze_expr(state, scope, stmt.expr, module_env)
            return { always_returns = true, any_with = true, any_without = false }
        end
        return { always_returns = true, any_with = false, any_without = true }
    elseif kind == "Match" then
        analyze_expr(state, scope, stmt.expr, module_env)
        local subject_type = nil
        if stmt.expr.kind == "Ident" then
            local info = scope_lookup(scope, stmt.expr.name)
            if info and info.type_name then
                subject_type = info.type_name
            end
        end
        local enum_items = subject_type and enum_lookup(scope, subject_type) or nil
        local seen_patterns = {}
        local seen_enum = {}
        local has_wildcard = false
        local all_return = true
        local any_with = false
        local any_without = false

        for _, c in ipairs(stmt.cases) do
            if has_wildcard then
            add_warning(state, c.pattern.span, "Unreachable match case after wildcard")
            end
            if c.pattern.kind == "PatternWildcard" then
                if has_wildcard then
                    add_warning(state, c.pattern.span, "Redundant wildcard match case")
                end
                has_wildcard = true
            elseif c.pattern.kind == "PatternLiteral" then
                analyze_expr(state, scope, c.pattern.value, module_env)
                local key = c.pattern.value.kind .. ":" .. tostring(c.pattern.value.value)
                if seen_patterns[key] then
                    add_warning(state, c.pattern.span, "Redundant match case (duplicate literal)")
                end
                seen_patterns[key] = true
            elseif c.pattern.kind == "PatternIdent" then
                local info = scope_lookup(scope, c.pattern.name)
                if info then
                    info.used = true
                    if not info.assigned then
                        add_error(state, c.pattern.span, "Use of '" .. c.pattern.name .. "' before assignment in match pattern")
                    end
                elseif not mark_used(scope, c.pattern.name) then
                    if not default_globals[c.pattern.name] and not state.allowed_globals[c.pattern.name] then
                        add_error(state, c.pattern.span, "Undefined variable '" .. c.pattern.name .. "' in match pattern")
                    end
                end
                local key = "ident:" .. c.pattern.name
                if seen_patterns[key] then
                    add_warning(state, c.pattern.span, "Redundant match case (duplicate identifier)")
                end
                seen_patterns[key] = true
            elseif c.pattern.kind == "PatternExpr" then
                analyze_expr(state, scope, c.pattern.expr, module_env)
                if c.pattern.expr.kind == "Index" and c.pattern.expr.dot then
                    local base = c.pattern.expr.base
                    local key = c.pattern.expr.key
                    if base.kind == "Ident" and key.kind == "String" then
                        local enum_name = base.name
                        local item = key.value
                        local enum = enum_lookup(scope, enum_name)
                        if enum then
                            local enum_key = enum_name .. "." .. item
                            if seen_enum[enum_key] then
                                add_warning(state, c.pattern.span, "Redundant match case (duplicate enum item)")
                            end
                            seen_enum[enum_key] = true
                        end
                    end
                end
            end

            local info = analyze_stmt(state, scope, c.stmt, in_function, module_env)
            all_return = all_return and info.always_returns
            any_with = any_with or info.any_with
            any_without = any_without or info.any_without
        end

        -- Enum matches must cover all variants unless wildcard is present
        if enum_items and not has_wildcard then
            local missing = {}
            for _, item in ipairs(enum_items) do
                local key = subject_type .. "." .. item.name
                if not seen_enum[key] then
                    missing[#missing + 1] = item.name
                end
            end
            if #missing > 0 then
                add_error(state, stmt.span, "Non-exhaustive match for enum '" .. subject_type .. "': missing " .. table.concat(missing, ", "))
            end
        elseif not has_wildcard then
            add_warning(state, stmt.span, "Non-exhaustive match (missing wildcard case)")
            all_return = false
        end

        return { always_returns = has_wildcard and all_return or false, any_with = any_with, any_without = any_without }
    end

    return no_return()
end

-- Analyzes a block of statements for flow and warnings
analyze_block = function(state, scope, block, in_function, module_env)
    local info = { always_returns = false, any_with = false, any_without = false }
    for _, stmt in ipairs(block) do
        if info.always_returns then
            add_warning(state, stmt.span, "Dead code after return")
            break
        end
        local s_info = analyze_stmt(state, scope, stmt, in_function, module_env)
        if s_info.always_returns then
            info.always_returns = true
        end
        info.any_with = info.any_with or s_info.any_with
        info.any_without = info.any_without or s_info.any_without
    end
    return info
end

-- Runs analysis on a full AST
function Analyzer.analyze(ast, module_env, diagnostics)
    local state = { diagnostics = diagnostics or Diagnostics.new(), allowed_globals = {} }
    local scope = new_scope(nil)
    if module_env and module_env.imports then
        for _, imp in ipairs(module_env.imports) do
            if imp.names then
                for _, name in ipairs(imp.names) do
                    declare_local(state, scope, name, { assigned = true, nilness = "non_nil" })
                end
            else
                local alias = imp.alias or imp.default_alias
                if alias then
                    declare_local(state, scope, alias, { assigned = true, nilness = "non_nil" })
                end
            end
        end
    end
    analyze_block(state, scope, ast.body, false, module_env)
    check_unused(state, scope)
    return state.diagnostics
end

return Analyzer
