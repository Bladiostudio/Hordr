-- Optimizer regression tests
local compiler = require("src.main")

-- Checks for an output snippet
local function contains(hay, needle)
    return hay:find(needle, 1, true) ~= nil
end

-- Runs a single optimizer test case
local function run_case(name, source, expect)
    local out, diag = compiler.compile(source)
    diag = diag or { list = {} }
    for _, d in ipairs(diag.list) do
        if d.severity == "error" then
            error(name .. ": expected no errors")
        end
    end
    for _, snippet in ipairs(expect) do
        assert(contains(out, snippet), name .. ": expected output snippet: " .. snippet)
    end
end

run_case("loop_hoist", [[
fn f(n: number) {
    let a = 2
    let b = 3
    for i = 1, n {
        let x = a * b
        let y = x + 1
    }
}
]], {
    "local _hoisted",
    "for i = 1, n do",
    "local y = _hoisted",
})

run_case("local_cache", [[
fn f() {
    let obj = { value = 1 }
    let total = obj.value + obj.value
    return total
}
]], {
    "local obj_value = obj.value",
    "local total = obj_value + obj_value",
})

run_case("global_alias", [[
fn f(a: number, b: number): number {
    return math.sin(a) + math.sin(b)
}
]], {
    "local sin = math.sin",
    "return sin(a) + sin(b)",
})

run_case("temp_remove", [[
fn f(): number {
    let x = 1
    let y = x
    return y
}
]], {
    "return 1",
})

print("OK")
