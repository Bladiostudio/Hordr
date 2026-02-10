-- Diagnostics formatting tests
local compiler = require("src.main")
local Diagnostics = require("src.diagnostics")

local source = [[
fn f() {
    let x = y
}
]]

local out, diag = compiler.compile(source)
assert(out == nil, "expected compile to fail")
assert(#diag.list >= 1, "expected diagnostics")

local d = diag.list[1]
assert(d.severity == "error", "expected error severity")
assert(d.span and d.span.line == 2, "expected line 2")
assert(d.span and d.span.col == 13, "expected col 13")

local text = Diagnostics.format(diag)
assert(text:find("error", 1, true), "expected formatted output to contain severity")

print("OK")
