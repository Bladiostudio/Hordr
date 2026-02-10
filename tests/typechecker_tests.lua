-- Type checker regression tests
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

-- Runs a single type-checker test case
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
end

run_case("table_shape_ok", [[
fn f() {
    let v: {x: number, y: number} = { x = 1, y = 2, z = 3 }
}
]], {
    no_errors = true,
})

run_case("table_shape_bad", [[
fn f() {
    let v: {x: number, y: number} = { x = 1, y = "no" }
}
]], {
    errors = { "Expected { x: number, y: number }" },
})

run_case("return_mismatch", [[
fn f(): number {
    return "no"
}
]], {
    errors = { "Return type mismatch" },
})

run_case("param_mismatch", [[
fn add(a: number, b: number): number { return a + b }
fn f() { add(1, "no") }
]], {
    errors = { "Argument 2" },
})

run_case("enum_misuse", [[
enum E { A, B }
fn f(): number {
    let x: E = E.A
    let y: number = x
    return y
}
]], {
    errors = { "Expected number, got E" },
})

run_case("nil_access", [[
fn f() {
    let t: {x: number} | nil = nil
    let y = t.x
}
]], {
    errors = { "Cannot access field on possibly-nil value" },
})

run_case("nil_narrow", [[
fn f() {
    let t: {x: number} | nil = nil
    if t ~= nil {
        let y = t.x
    }
}
]], {
    no_errors = true,
})

print("OK")
