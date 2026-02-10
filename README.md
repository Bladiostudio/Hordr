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

MIT License.