-- Analyzer regression tests
local compiler = require("src.main")

-- Checks diagnostics for a message and severity
local function contains(diag, needle, severity)
    for _, d in ipairs(diag.list or {}) do
        if (not severity or d.severity == severity) and d.message:find(needle, 1, true) then
            return true
        end
    end
    return false
end

-- Runs a single analyzer test case
local function run_case(name, source, expect)
    local out, diag = compiler.compile(source)
    diag = diag or { list = {} }

    if expect.no_errors then
        assert(not contains(diag, "", "error"), name .. ": expected no errors")
    end

    if expect.errors then
        for _, msg in ipairs(expect.errors) do
            assert(contains(diag, msg, "error"), name .. ": expected error containing: " .. msg)
        end
    end

    if expect.warnings then
        for _, msg in ipairs(expect.warnings) do
            assert(contains(diag, msg, "warning"), name .. ": expected warning containing: " .. msg)
        end
    end
end

run_case("use_before_assign", [[
fn f() {
    let x
    let y = x
}
]], {
    errors = { "Use of 'x' before assignment" },
})

run_case("nil_access", [[
fn f() {
    let x = nil
    let y = x.y
}
]], {
    errors = { "Cannot access field on possibly-nil value" },
})

run_case("missing_return", [[
fn f(): number {
    if true {
        return 1
    }
}
]], {
    errors = { "Missing return on some paths" },
})

run_case("dead_branch", [[
fn f() {
    if false {
        let x = 1
    }
}
]], {
    warnings = { "Unreachable 'if' branch" },
})

run_case("match_redundant", [[
enum E {
    A
    B
}

fn f(x: E): number {
    match x {
        case E.A => return 1
        case E.A => return 2
        case _ => return 3
        case E.B => return 4
    }
}
]], {
    warnings = { "Redundant match case", "Unreachable match case after wildcard" },
})

run_case("match_exhaustive_enum", [[
enum E {
    A
    B
}

fn f(x: E): number {
    match x {
        case E.A => return 1
    }
}
]], {
    errors = { "Non-exhaustive match for enum" },
})

run_case("assign_lvalue", [[
fn f() {
    let x
    x = 1
}
]], {
    no_errors = true,
})

print("OK")
