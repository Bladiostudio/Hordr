-- Module system regression tests
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

-- Runs a module compilation test case
local function run_case(name, sources, expect)
    local out, diag = compiler.compile_modules(sources)
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

    if expect.output_contains then
        for mod, snippets in pairs(expect.output_contains) do
            assert(out and out[mod], name .. ": expected output for module " .. mod)
            for _, snippet in ipairs(snippets) do
                assert(out[mod]:find(snippet, 1, true), name .. ": expected output snippet: " .. snippet)
            end
        end
    end
end

run_case("valid_imports", {
    ["math.vec"] = [[
module math.vec
export struct Vec2 { x: number, y: number }
export fn length(v: Vec2): number { return v.x + v.y }
]],
    ["math.util"] = [[
module math.util
import math.vec.{ Vec2 }
export fn make(x: number, y: number): Vec2 { return Vec2.new(x, y) }
]],
}, {
    no_errors = true,
    output_contains = {
        ["math.util"] = { "local Vec2 = __import0.Vec2", "local M = {}", "return M" },
    },
})

run_case("missing_module", {
    ["a"] = [[
module a
import b
export fn f(): number { return 1 }
]],
}, {
    errors = { "unknown module 'b'" },
})

run_case("missing_export", {
    ["a"] = [[
module a
fn hidden(): number { return 1 }
]],
    ["b"] = [[
module b
import a.{ hidden }
]],
}, {
    errors = { "does not export 'hidden'" },
})

run_case("illegal_access", {
    ["a"] = [[
module a
export fn f(): number { return 1 }
]],
    ["b"] = [[
module b
import a
fn g(): number { return a.hidden }
]],
}, {
    errors = { "Access to non-exported symbol 'hidden'" },
})

run_case("collision_import_local", {
    ["a"] = [[
module a
export fn f(): number { return 1 }
]],
    ["b"] = [[
module b
import a as f
let f = 1
]],
}, {
    errors = { "name collision between import and local 'f'" },
})

run_case("duplicate_exports", {
    ["a"] = [[
module a
export fn f(): number { return 1 }
export let f = 2
]],
}, {
    errors = { "Duplicate export 'f'" },
})

run_case("circular_import", {
    ["a"] = [[
module a
import b
export fn f(): number { return 1 }
]],
    ["b"] = [[
module b
import a
export fn g(): number { return 2 }
]],
}, {
    errors = { "Circular import detected" },
})

run_case("import_typing", {
    ["a"] = [[
module a
export fn f(n: number): number { return n }
]],
    ["b"] = [[
module b
import a.{ f }
fn g() { f("no") }
]],
}, {
    errors = { "Argument 1" },
})

print("OK")
