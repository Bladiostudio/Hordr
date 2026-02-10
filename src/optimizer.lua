-- Applies conservative, readability-first optimizations
local Optimizer = {}

-- Holds pass-local counters for unique names
local function new_state()
    return { counter = 0 }
end

-- Creates a unique temporary name
local function next_temp(state, prefix)
    state.counter = state.counter + 1
    return (prefix or "_tmp") .. tostring(state.counter)
end

-- Checks for numeric literals
local function is_number(expr)
    return expr.kind == "Number"
end

-- Checks for boolean literals
local function is_boolean(expr)
    return expr.kind == "Boolean"
end

-- Checks for nil literal
local function is_nil(expr)
    return expr.kind == "Nil"
end

-- Folds constant binary expressions
local function fold_binary(op, left, right)
    if is_number(left) and is_number(right) then
        local a, b = left.value, right.value
        if op == "+" then return { kind = "Number", value = a + b } end
        if op == "-" then return { kind = "Number", value = a - b } end
        if op == "*" then return { kind = "Number", value = a * b } end
        if op == "/" then return { kind = "Number", value = a / b } end
        if op == "%" then return { kind = "Number", value = a % b } end
        if op == "^" then return { kind = "Number", value = a ^ b } end
        if op == "==" then return { kind = "Boolean", value = (a == b) } end
        if op == "~=" then return { kind = "Boolean", value = (a ~= b) } end
        if op == "<" then return { kind = "Boolean", value = (a < b) } end
        if op == "<=" then return { kind = "Boolean", value = (a <= b) } end
        if op == ">" then return { kind = "Boolean", value = (a > b) } end
        if op == ">=" then return { kind = "Boolean", value = (a >= b) } end
    end
    return nil
end

-- Folds constant unary expressions
local function fold_unary(op, expr)
    if op == "-" and is_number(expr) then
        return { kind = "Number", value = -expr.value }
    end
    if op == "not" then
        if is_boolean(expr) then
            return { kind = "Boolean", value = not expr.value }
        end
        if is_nil(expr) then
            return { kind = "Boolean", value = true }
        end
    end
    return nil
end

-- Recursively optimizes expressions
local function optimize_expr(expr)
    local kind = expr.kind
    if kind == "Binary" then
        local left = optimize_expr(expr.left)
        local right = optimize_expr(expr.right)
        local folded = fold_binary(expr.op, left, right)
        if folded then
            return folded
        end
        return { kind = "Binary", op = expr.op, left = left, right = right }
    elseif kind == "Unary" then
        local inner = optimize_expr(expr.expr)
        local folded = fold_unary(expr.op, inner)
        if folded then
            return folded
        end
        return { kind = "Unary", op = expr.op, expr = inner }
    elseif kind == "Call" then
        local callee = optimize_expr(expr.callee)
        local args = {}
        for i, a in ipairs(expr.args) do
            args[i] = optimize_expr(a)
        end
        return { kind = "Call", callee = callee, args = args }
    elseif kind == "Index" then
        return { kind = "Index", base = optimize_expr(expr.base), key = optimize_expr(expr.key), dot = expr.dot }
    elseif kind == "Table" then
        local fields = {}
        for i, f in ipairs(expr.fields) do
            if f.kind == "Field" then
                fields[i] = { kind = "Field", key = optimize_expr(f.key), value = optimize_expr(f.value), key_is_ident = f.key_is_ident }
            else
                fields[i] = { kind = "ArrayField", value = optimize_expr(f.value) }
            end
        end
        return { kind = "Table", fields = fields }
    end
    return expr
end

-- Collects identifiers referenced by an expression
local function collect_idents_expr(expr, out)
    local kind = expr.kind
    if kind == "Ident" then
        out[expr.name] = true
    elseif kind == "Binary" then
        collect_idents_expr(expr.left, out)
        collect_idents_expr(expr.right, out)
    elseif kind == "Unary" then
        collect_idents_expr(expr.expr, out)
    elseif kind == "Call" then
        collect_idents_expr(expr.callee, out)
        for _, a in ipairs(expr.args) do
            collect_idents_expr(a, out)
        end
    elseif kind == "Index" then
        collect_idents_expr(expr.base, out)
        collect_idents_expr(expr.key, out)
    elseif kind == "Table" then
        for _, f in ipairs(expr.fields) do
            if f.kind == "Field" then
                collect_idents_expr(f.key, out)
                collect_idents_expr(f.value, out)
            else
                collect_idents_expr(f.value, out)
            end
        end
    end
end

-- Checks for simple, side-effect-free expressions
local function expr_is_pure(expr)
    local kind = expr.kind
    if kind == "Ident" or kind == "Number" or kind == "String" or kind == "Boolean" or kind == "Nil" then
        return true
    elseif kind == "Unary" then
        return expr_is_pure(expr.expr)
    elseif kind == "Binary" then
        return expr_is_pure(expr.left) and expr_is_pure(expr.right)
    elseif kind == "Index" then
        if not expr.dot then
            return false
        end
        return expr.base.kind == "Ident" and expr.key.kind == "String"
    end
    return false
end

-- Collects variables mutated in a block
local function collect_mutations(block, out, include_let)
    for _, stmt in ipairs(block) do
        if include_let and stmt.kind == "Let" then
            out[stmt.name] = true
        end
        if stmt.kind == "Assign" then
            if stmt.target.kind == "Ident" then
                out[stmt.target.name] = true
            elseif stmt.target.kind == "Index" and stmt.target.base.kind == "Ident" then
                out[stmt.target.base.name] = true
            end
        elseif stmt.kind == "ForNum" then
            out[stmt.name] = true
            collect_mutations(stmt.body, out)
        elseif stmt.kind == "ForIn" then
            out[stmt.name] = true
            collect_mutations(stmt.body, out)
        elseif stmt.kind == "While" then
            collect_mutations(stmt.body, out)
        elseif stmt.kind == "If" then
            collect_mutations(stmt.then_block, out)
            for _, eb in ipairs(stmt.elseif_blocks) do
                collect_mutations(eb.block, out)
            end
            if stmt.else_block then
                collect_mutations(stmt.else_block, out)
            end
        elseif stmt.kind == "Function" then
            collect_mutations(stmt.body, out, include_let)
        end
    end
end

-- Rewrites expressions using a replacement callback
local function replace_expr(expr, replacer)
    local r = replacer(expr)
    if r then
        return r
    end
    local kind = expr.kind
    if kind == "Binary" then
        return { kind = "Binary", op = expr.op, left = replace_expr(expr.left, replacer), right = replace_expr(expr.right, replacer) }
    elseif kind == "Unary" then
        return { kind = "Unary", op = expr.op, expr = replace_expr(expr.expr, replacer) }
    elseif kind == "Call" then
        local args = {}
        for i, a in ipairs(expr.args) do
            args[i] = replace_expr(a, replacer)
        end
        return { kind = "Call", callee = replace_expr(expr.callee, replacer), args = args }
    elseif kind == "Index" then
        return { kind = "Index", base = replace_expr(expr.base, replacer), key = replace_expr(expr.key, replacer), dot = expr.dot }
    elseif kind == "Table" then
        local fields = {}
        for i, f in ipairs(expr.fields) do
            if f.kind == "Field" then
                fields[i] = {
                    kind = "Field",
                    key = replace_expr(f.key, replacer),
                    value = replace_expr(f.value, replacer),
                    key_is_ident = f.key_is_ident,
                }
            else
                fields[i] = { kind = "ArrayField", value = replace_expr(f.value, replacer) }
            end
        end
        return { kind = "Table", fields = fields }
    end
    return expr
end

-- Recursively optimizes a statement in place
local function optimize_stmt(stmt)
    local kind = stmt.kind
    if kind == "Let" then
        if stmt.init then
            stmt.init = optimize_expr(stmt.init)
        end
    elseif kind == "Global" then
        stmt.init = optimize_expr(stmt.init)
    elseif kind == "Assign" then
        stmt.target = optimize_expr(stmt.target)
        stmt.value = optimize_expr(stmt.value)
    elseif kind == "ExprStmt" then
        stmt.expr = optimize_expr(stmt.expr)
    elseif kind == "Function" then
        for i, s in ipairs(stmt.body) do
            stmt.body[i] = optimize_stmt(s)
        end
    elseif kind == "If" then
        stmt.cond = optimize_expr(stmt.cond)
        for i, s in ipairs(stmt.then_block) do
            stmt.then_block[i] = optimize_stmt(s)
        end
        for _, eb in ipairs(stmt.elseif_blocks) do
            eb.cond = optimize_expr(eb.cond)
            for i, s in ipairs(eb.block) do
                eb.block[i] = optimize_stmt(s)
            end
        end
        if stmt.else_block then
            for i, s in ipairs(stmt.else_block) do
                stmt.else_block[i] = optimize_stmt(s)
            end
        end
    elseif kind == "While" then
        stmt.cond = optimize_expr(stmt.cond)
        for i, s in ipairs(stmt.body) do
            stmt.body[i] = optimize_stmt(s)
        end
    elseif kind == "ForNum" then
        stmt.start = optimize_expr(stmt.start)
        stmt.finish = optimize_expr(stmt.finish)
        if stmt.step then
            stmt.step = optimize_expr(stmt.step)
        end
        for i, s in ipairs(stmt.body) do
            stmt.body[i] = optimize_stmt(s)
        end
    elseif kind == "ForIn" then
        stmt.iter = optimize_expr(stmt.iter)
        for i, s in ipairs(stmt.body) do
            stmt.body[i] = optimize_stmt(s)
        end
    elseif kind == "Return" then
        if stmt.expr then
            stmt.expr = optimize_expr(stmt.expr)
        end
    elseif kind == "Match" then
        stmt.expr = optimize_expr(stmt.expr)
        for _, c in ipairs(stmt.cases) do
            if c.pattern.kind == "PatternLiteral" then
                c.pattern.value = optimize_expr(c.pattern.value)
            end
            c.stmt = optimize_stmt(c.stmt)
        end
    end
    return stmt
end

-- Pass 1: constant folding
local function pass_constant_folding(ast)
    for i, stmt in ipairs(ast.body) do
        ast.body[i] = optimize_stmt(stmt)
    end
end

-- Pass 2: hoists loop-invariant pure expressions
local function pass_loop_hoist(ast, state)
    local function process_block(block)
        local out = {}
        for _, stmt in ipairs(block) do
            if stmt.kind == "ForNum" or stmt.kind == "ForIn" or stmt.kind == "While" then
                local loop_var = stmt.kind == "ForNum" or stmt.kind == "ForIn" and stmt.name or nil
                local mutated = {}
                collect_mutations(stmt.body, mutated, true)
                if loop_var then
                    mutated[loop_var] = true
                end
                local hoisted = {}
                for _, s in ipairs(stmt.body) do
                    if s.kind == "Let" and s.init and expr_is_pure(s.init) then
                        local used = {}
                        collect_idents_expr(s.init, used)
                        local ok = true
                        for name, _ in pairs(used) do
                            if mutated[name] then
                                ok = false
                                break
                            end
                        end
                        if ok and s.init.kind == "Index" and s.init.base.kind == "Ident" and mutated[s.init.base.name] then
                            ok = false
                        end
                        if ok then
                            local temp = next_temp(state, "_hoisted")
                            hoisted[#hoisted + 1] = { kind = "Let", name = temp, init = s.init }
                            s.init = { kind = "Ident", name = temp }
                        end
                    end
                end
                for _, h in ipairs(hoisted) do
                    out[#out + 1] = h
                end
                process_block(stmt.body)
                out[#out + 1] = stmt
            elseif stmt.kind == "If" then
                process_block(stmt.then_block)
                for _, eb in ipairs(stmt.elseif_blocks) do
                    process_block(eb.block)
                end
                if stmt.else_block then
                    process_block(stmt.else_block)
                end
                out[#out + 1] = stmt
            elseif stmt.kind == "Function" then
                process_block(stmt.body)
                out[#out + 1] = stmt
            else
                out[#out + 1] = stmt
            end
        end
        for i = 1, #out do
            block[i] = out[i]
        end
        for i = #out + 1, #block do
            block[i] = nil
        end
    end
    process_block(ast.body)
end

-- Pass 3: caches repeated table field reads
local function pass_local_caching(ast, state)
    local function collect_locals(block, locals, decl_pos)
        for i, stmt in ipairs(block) do
            if stmt.kind == "Let" then
                locals[stmt.name] = true
                decl_pos[stmt.name] = decl_pos[stmt.name] or i
            elseif stmt.kind == "ForNum" or stmt.kind == "ForIn" then
                locals[stmt.name] = true
                decl_pos[stmt.name] = decl_pos[stmt.name] or i
            elseif stmt.kind == "Function" then
                locals[stmt.name] = true
                decl_pos[stmt.name] = decl_pos[stmt.name] or i
            elseif stmt.kind == "Struct" or stmt.kind == "Enum" then
                locals[stmt.name] = true
                decl_pos[stmt.name] = decl_pos[stmt.name] or i
            end
        end
    end

    local function scan_expr(expr, counts)
        if expr.kind == "Index" and expr.dot and expr.base.kind == "Ident" and expr.key.kind == "String" then
            local key = expr.base.name .. "." .. expr.key.value
            counts[key] = (counts[key] or 0) + 1
        elseif expr.kind == "Binary" then
            scan_expr(expr.left, counts)
            scan_expr(expr.right, counts)
        elseif expr.kind == "Unary" then
            scan_expr(expr.expr, counts)
        elseif expr.kind == "Call" then
            scan_expr(expr.callee, counts)
            for _, a in ipairs(expr.args) do
                scan_expr(a, counts)
            end
        elseif expr.kind == "Table" then
            for _, f in ipairs(expr.fields) do
                if f.kind == "Field" then
                    scan_expr(f.key, counts)
                    scan_expr(f.value, counts)
                else
                    scan_expr(f.value, counts)
                end
            end
        end
    end

    local function process_block(block, parent_locals)
        local locals = {}
        local decl_pos = {}
        if parent_locals then
            for k, v in pairs(parent_locals) do
                locals[k] = v
            end
        end
        collect_locals(block, locals, decl_pos)

        local mutated = {}
        collect_mutations(block, mutated, false)

        local counts = {}
        for _, stmt in ipairs(block) do
            if stmt.kind == "Assign" then
                scan_expr(stmt.value, counts)
            elseif stmt.kind == "Let" and stmt.init then
                scan_expr(stmt.init, counts)
            elseif stmt.kind == "ExprStmt" then
                scan_expr(stmt.expr, counts)
            elseif stmt.kind == "Return" and stmt.expr then
                scan_expr(stmt.expr, counts)
            elseif stmt.kind == "If" then
                scan_expr(stmt.cond, counts)
            elseif stmt.kind == "While" then
                scan_expr(stmt.cond, counts)
            elseif stmt.kind == "ForNum" then
                scan_expr(stmt.start, counts)
                scan_expr(stmt.finish, counts)
                if stmt.step then
                    scan_expr(stmt.step, counts)
                end
            elseif stmt.kind == "ForIn" then
                scan_expr(stmt.iter, counts)
            end
        end

        local inserts = {}
        for key, count in pairs(counts) do
            if count >= 2 then
                local base, field = key:match("^([^%.]+)%.(.+)$")
                if base and field and locals[base] and not mutated[base] then
                    local temp = base .. "_" .. field
                    if locals[temp] then
                        temp = next_temp(state, "_cache")
                    end
                    local pos = (decl_pos[base] or 0) + 1
                    inserts[#inserts + 1] = { pos = pos, stmt = { kind = "Let", name = temp, init = { kind = "Index", base = { kind = "Ident", name = base }, key = { kind = "String", value = field }, dot = true } } }
                    locals[temp] = true
                    local function replacer(expr)
                        if expr.kind == "Index" and expr.dot and expr.base.kind == "Ident" and expr.base.name == base and expr.key.kind == "String" and expr.key.value == field then
                            return { kind = "Ident", name = temp }
                        end
                        return nil
                    end
                    for i, stmt in ipairs(block) do
                        if stmt.kind == "Assign" then
                            stmt.value = replace_expr(stmt.value, replacer)
                        elseif stmt.kind == "Let" and stmt.init then
                            stmt.init = replace_expr(stmt.init, replacer)
                        elseif stmt.kind == "ExprStmt" then
                            stmt.expr = replace_expr(stmt.expr, replacer)
                        elseif stmt.kind == "Return" and stmt.expr then
                            stmt.expr = replace_expr(stmt.expr, replacer)
                        elseif stmt.kind == "If" then
                            stmt.cond = replace_expr(stmt.cond, replacer)
                        elseif stmt.kind == "While" then
                            stmt.cond = replace_expr(stmt.cond, replacer)
                        elseif stmt.kind == "ForNum" then
                            stmt.start = replace_expr(stmt.start, replacer)
                            stmt.finish = replace_expr(stmt.finish, replacer)
                            if stmt.step then
                                stmt.step = replace_expr(stmt.step, replacer)
                            end
                        elseif stmt.kind == "ForIn" then
                            stmt.iter = replace_expr(stmt.iter, replacer)
                        end
                    end
                end
            end
        end

        if #inserts > 0 then
            table.sort(inserts, function(a, b) return a.pos < b.pos end)
            local new_block = {}
            local insert_idx = 1
            for i, s in ipairs(block) do
                while inserts[insert_idx] and inserts[insert_idx].pos == i do
                    new_block[#new_block + 1] = inserts[insert_idx].stmt
                    insert_idx = insert_idx + 1
                end
                new_block[#new_block + 1] = s
            end
            while inserts[insert_idx] do
                new_block[#new_block + 1] = inserts[insert_idx].stmt
                insert_idx = insert_idx + 1
            end
            for i = 1, #new_block do
                block[i] = new_block[i]
            end
            for i = #new_block + 1, #block do
                block[i] = nil
            end
        end

        for _, stmt in ipairs(block) do
            if stmt.kind == "Function" then
                process_block(stmt.body, {})
            elseif stmt.kind == "If" then
                process_block(stmt.then_block, locals)
                for _, eb in ipairs(stmt.elseif_blocks) do
                    process_block(eb.block, locals)
                end
                if stmt.else_block then
                    process_block(stmt.else_block, locals)
                end
            elseif stmt.kind == "While" then
                process_block(stmt.body, locals)
            elseif stmt.kind == "ForNum" or stmt.kind == "ForIn" then
                process_block(stmt.body, locals)
            end
        end
    end

    process_block(ast.body, {})
end

-- Pass 4: aliases frequently used globals
local function pass_global_alias(ast, state)
    local globals = {
        math = true,
        string = true,
        table = true,
        coroutine = true,
        utf8 = true,
        os = true,
    }

    local function count_global_uses(block)
        local counts = {}
        local function scan(expr)
            if expr.kind == "Index" and expr.dot and expr.base.kind == "Ident" and expr.key.kind == "String" then
                if globals[expr.base.name] then
                    local key = expr.base.name .. "." .. expr.key.value
                    counts[key] = (counts[key] or 0) + 1
                end
            elseif expr.kind == "Binary" then
                scan(expr.left)
                scan(expr.right)
            elseif expr.kind == "Unary" then
                scan(expr.expr)
            elseif expr.kind == "Call" then
                scan(expr.callee)
                for _, a in ipairs(expr.args) do
                    scan(a)
                end
            elseif expr.kind == "Table" then
                for _, f in ipairs(expr.fields) do
                    if f.kind == "Field" then
                        scan(f.key)
                        scan(f.value)
                    else
                        scan(f.value)
                    end
                end
            end
        end

        for _, stmt in ipairs(block) do
            if stmt.kind == "Assign" then
                scan(stmt.value)
            elseif stmt.kind == "Let" and stmt.init then
                scan(stmt.init)
            elseif stmt.kind == "ExprStmt" then
                scan(stmt.expr)
            elseif stmt.kind == "Return" and stmt.expr then
                scan(stmt.expr)
            elseif stmt.kind == "If" then
                scan(stmt.cond)
            elseif stmt.kind == "While" then
                scan(stmt.cond)
            elseif stmt.kind == "ForNum" then
                scan(stmt.start)
                scan(stmt.finish)
                if stmt.step then
                    scan(stmt.step)
                end
            elseif stmt.kind == "ForIn" then
                scan(stmt.iter)
            end
        end
        return counts
    end

    local function process_block(block)
        local counts = count_global_uses(block)
        local inserts = {}
        local used_names = {}
        for _, stmt in ipairs(block) do
            if stmt.kind == "Let" then
                used_names[stmt.name] = true
            end
        end

        for key, count in pairs(counts) do
            if count >= 2 then
                local base, field = key:match("^([^%.]+)%.(.+)$")
                if base and field and not used_names[field] then
                    local local_name = field
                    if used_names[local_name] then
                        local_name = next_temp(state, "_alias")
                    end
                    inserts[#inserts + 1] = { kind = "Let", name = local_name, init = { kind = "Index", base = { kind = "Ident", name = base }, key = { kind = "String", value = field }, dot = true } }
                    used_names[local_name] = true
                    local function replacer(expr)
                        if expr.kind == "Index" and expr.dot and expr.base.kind == "Ident" and expr.base.name == base and expr.key.kind == "String" and expr.key.value == field then
                            return { kind = "Ident", name = local_name }
                        end
                        return nil
                    end
                    for i, stmt in ipairs(block) do
                        if stmt.kind == "Assign" then
                            stmt.value = replace_expr(stmt.value, replacer)
                        elseif stmt.kind == "Let" and stmt.init then
                            stmt.init = replace_expr(stmt.init, replacer)
                        elseif stmt.kind == "ExprStmt" then
                            stmt.expr = replace_expr(stmt.expr, replacer)
                        elseif stmt.kind == "Return" and stmt.expr then
                            stmt.expr = replace_expr(stmt.expr, replacer)
                        elseif stmt.kind == "If" then
                            stmt.cond = replace_expr(stmt.cond, replacer)
                        elseif stmt.kind == "While" then
                            stmt.cond = replace_expr(stmt.cond, replacer)
                        elseif stmt.kind == "ForNum" then
                            stmt.start = replace_expr(stmt.start, replacer)
                            stmt.finish = replace_expr(stmt.finish, replacer)
                            if stmt.step then
                                stmt.step = replace_expr(stmt.step, replacer)
                            end
                        elseif stmt.kind == "ForIn" then
                            stmt.iter = replace_expr(stmt.iter, replacer)
                        end
                    end
                end
            end
        end

        if #inserts > 0 then
            local new_block = {}
            for _, ins in ipairs(inserts) do
                new_block[#new_block + 1] = ins
            end
            for _, s in ipairs(block) do
                new_block[#new_block + 1] = s
            end
            for i = 1, #new_block do
                block[i] = new_block[i]
            end
            for i = #new_block + 1, #block do
                block[i] = nil
            end
        end

        for _, stmt in ipairs(block) do
            if stmt.kind == "Function" then
                process_block(stmt.body)
            elseif stmt.kind == "If" then
                process_block(stmt.then_block)
                for _, eb in ipairs(stmt.elseif_blocks) do
                    process_block(eb.block)
                end
                if stmt.else_block then
                    process_block(stmt.else_block)
                end
            elseif stmt.kind == "While" then
                process_block(stmt.body)
            elseif stmt.kind == "ForNum" or stmt.kind == "ForIn" then
                process_block(stmt.body)
            end
        end
    end

    process_block(ast.body)
end

-- Pass 5: reserved for trivial for-loop normalization
local function pass_for_normalization(ast)
    return
end

-- Pass 6: removes trivial single-use temporaries
local function pass_temp_removal(ast)
    local function count_uses(block, counts)
        local function scan(expr)
            if expr.kind == "Ident" then
                counts[expr.name] = (counts[expr.name] or 0) + 1
            elseif expr.kind == "Binary" then
                scan(expr.left)
                scan(expr.right)
            elseif expr.kind == "Unary" then
                scan(expr.expr)
            elseif expr.kind == "Call" then
                scan(expr.callee)
                for _, a in ipairs(expr.args) do
                    scan(a)
                end
            elseif expr.kind == "Index" then
                scan(expr.base)
                scan(expr.key)
            elseif expr.kind == "Table" then
                for _, f in ipairs(expr.fields) do
                    if f.kind == "Field" then
                        scan(f.key)
                        scan(f.value)
                    else
                        scan(f.value)
                    end
                end
            end
        end

        for _, stmt in ipairs(block) do
            if stmt.kind == "Assign" then
                scan(stmt.value)
            elseif stmt.kind == "Let" and stmt.init then
                scan(stmt.init)
            elseif stmt.kind == "ExprStmt" then
                scan(stmt.expr)
            elseif stmt.kind == "Return" and stmt.expr then
                scan(stmt.expr)
            elseif stmt.kind == "If" then
                scan(stmt.cond)
            elseif stmt.kind == "While" then
                scan(stmt.cond)
            elseif stmt.kind == "ForNum" then
                scan(stmt.start)
                scan(stmt.finish)
                if stmt.step then
                    scan(stmt.step)
                end
            elseif stmt.kind == "ForIn" then
                scan(stmt.iter)
            end
        end
    end

    local function is_simple_expr(expr)
        return expr.kind == "Ident" or expr.kind == "Number" or expr.kind == "String" or expr.kind == "Boolean" or expr.kind == "Nil"
    end

    local function process_block(block)
        local counts = {}
        count_uses(block, counts)

        local new_block = {}
        for i, stmt in ipairs(block) do
            if stmt.kind == "Let" and stmt.init and not stmt.exported then
                if counts[stmt.name] == 1 and is_simple_expr(stmt.init) then
                    local name = stmt.name
                    local repl = stmt.init
                    local function replacer(expr)
                        if expr.kind == "Ident" and expr.name == name then
                            return repl
                        end
                        return nil
                    end
                    for j = i + 1, #block do
                        local s = block[j]
                        if s.kind == "Assign" then
                            s.value = replace_expr(s.value, replacer)
                        elseif s.kind == "Let" and s.init then
                            s.init = replace_expr(s.init, replacer)
                        elseif s.kind == "ExprStmt" then
                            s.expr = replace_expr(s.expr, replacer)
                        elseif s.kind == "Return" and s.expr then
                            s.expr = replace_expr(s.expr, replacer)
                        elseif s.kind == "If" then
                            s.cond = replace_expr(s.cond, replacer)
                        elseif s.kind == "While" then
                            s.cond = replace_expr(s.cond, replacer)
                        elseif s.kind == "ForNum" then
                            s.start = replace_expr(s.start, replacer)
                            s.finish = replace_expr(s.finish, replacer)
                            if s.step then
                                s.step = replace_expr(s.step, replacer)
                            end
                        elseif s.kind == "ForIn" then
                            s.iter = replace_expr(s.iter, replacer)
                        end
                    end
                else
                    new_block[#new_block + 1] = stmt
                end
            else
                new_block[#new_block + 1] = stmt
            end
        end

        for i = 1, #new_block do
            block[i] = new_block[i]
        end
        for i = #new_block + 1, #block do
            block[i] = nil
        end

        for _, stmt in ipairs(block) do
            if stmt.kind == "Function" then
                process_block(stmt.body)
            elseif stmt.kind == "If" then
                process_block(stmt.then_block)
                for _, eb in ipairs(stmt.elseif_blocks) do
                    process_block(eb.block)
                end
                if stmt.else_block then
                    process_block(stmt.else_block)
                end
            elseif stmt.kind == "While" then
                process_block(stmt.body)
            elseif stmt.kind == "ForNum" or stmt.kind == "ForIn" then
                process_block(stmt.body)
            end
        end
    end

    process_block(ast.body)
end

-- Runs enabled optimization passes in order
function Optimizer.optimize(ast, opts)
    opts = opts or {}
    local enable = opts.enable or {}
    local state = new_state()

    if enable.constant_folding ~= false then
        pass_constant_folding(ast)
    end
    if enable.loop_invariant_hoisting ~= false then
        pass_loop_hoist(ast, state)
    end
    if enable.local_cache ~= false then
        pass_local_caching(ast, state)
    end
    if enable.global_aliasing ~= false then
        pass_global_alias(ast, state)
    end
    if enable.numeric_for_normalization ~= false then
        pass_for_normalization(ast)
    end
    if enable.redundant_temps ~= false then
        pass_temp_removal(ast)
    end

    return ast
end

return Optimizer
