-- Runs the test suite and propagates failures
local ok, err = pcall(function()
    dofile("tests/analyzer_tests.lua")
    dofile("tests/modules_tests.lua")
    dofile("tests/typechecker_tests.lua")
    dofile("tests/optimizer_tests.lua")
    dofile("tests/diagnostics_tests.lua")
end)

if not ok then
    io.stderr:write(err .. "\n")
    os.exit(1)
end
