# Hordr v1.0.0

## Overview
Hordr is a Lua/Luau‑first frontend transpiler for developers who want stronger correctness guarantees and cleaner structure without changing runtime behavior. It targets Luau and Lua 5.1–5.4 and generates readable, idiomatic Lua.

## Key Features
- **Flow‑sensitive analyzer**: detects use‑before‑assignment, accidental globals, shadowing, dead code, and missing return paths.
- **Explicit modules**: `module`, `import`, and `export` with static resolution and no global pollution.
- **Luau‑compatible type checker**: structural types, unions, enums, and predictable nil handling.
- **Safe optimizer passes**: human‑readable improvements only (no inlining, no CFG tricks).
- **Unified diagnostics**: consistent errors/warnings with source spans and clear messages.

## Design Philosophy
- Lua/Luau is the runtime of truth.
- Readability and debuggability over cleverness.
- No runtime helpers or hidden behavior.
- Deterministic, predictable lowering.

## Not Included (by design)
- No new VM or runtime
- No runtime type metadata or checks
- No aggressive inference or opaque optimizations
- No claims of replacing Lua/Luau

## Stability and Expectations
v1.0.0 is stable and suitable for real use. The compiler is conservative by design and prioritizes correctness and clarity. Feedback is welcome and will guide future improvements.

## Minimal Example
```hordr
module math.vec

export struct Vec2 { x: number, y: number }

export fn length(v: Vec2): number {
    return (v.x * v.x + v.y * v.y) ^ 0.5
}
```

## Notes
Please open issues for bugs, diagnostics that could be clearer, or missing checks. Discussion is welcome; no roadmap promises.

## License

MIT License

Copyright (c) 2026 BladioStudio

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
