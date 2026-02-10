# Hordr Language Specification (Concise)

Hordr is a strictly Lua-first, zero-runtime-cost frontend that transpiles to readable Lua/Luau. It does not replace Lua; it produces Lua that you can debug directly. Hordr only adds optional compile-time structure and analysis.

Core guarantees:
- All variables are local by default.
- Global writes are compile-time errors unless explicitly allowed via `global`.
- Structural typing only; types are erased at compile time.
- No runtime helpers, no hidden closures, no magic globals.
- Deterministic, stable output for identical input.

## Grammar Overview (EBNF)

This grammar is intentionally compact and focuses on a usable core.

```
program      = [ moduleDecl ] { importDecl } { stmt } EOF ;

stmt         = exportStmt
             | letStmt
             | assignStmt
             | fnDecl
             | structDecl
             | enumDecl
             | ifStmt
             | whileStmt
             | forStmt
             | returnStmt
             | matchStmt
             | exprStmt ;

letStmt      = "let" ident [":" typeExpr] ["=" expr] stmtEnd ;
assignStmt   = lvalue "=" expr stmtEnd ;

fnDecl       = "fn" ident "(" [paramList] ")" [":" typeExpr] block ;
paramList    = param { "," param } ;
param        = ident [":" typeExpr] ;

structDecl   = "struct" ident "{" { fieldDecl [","] } "}" ;
fieldDecl    = ident ":" typeExpr ;

enumDecl     = "enum" ident "{" { enumItem [","] } "}" ;
enumItem     = ident ["=" number] ;

ifStmt       = "if" expr block { "elseif" expr block } ["else" block] ;
whileStmt    = "while" expr block ;
forStmt      = "for" ident "=" expr "," expr ["," expr] block
             | "for" ident "in" expr block ;

returnStmt   = "return" [expr] stmtEnd ;

matchStmt    = "match" expr "{" { caseClause } "}" ;
caseClause   = "case" pattern "=>" stmt ;
pattern      = "_" | literal | ident ;

exprStmt     = expr stmtEnd ;

block        = "{" { stmt } "}" ;
stmtEnd      = ";" | NEWLINE ;

expr         = logicOr ;
logicOr      = logicAnd { "or" logicAnd } ;
logicAnd     = equality { "and" equality } ;
equality     = compare { ("==" | "~=") compare } ;
compare      = term { ("<" | "<=" | ">" | ">=") term } ;
term         = factor { ("+" | "-") factor } ;
factor       = unary { ("*" | "/" | "%") unary } ;
unary        = ("not" | "-" | "#") unary | call ;
call         = primary { "(" [argList] ")" | "." ident | "[" expr "]" } ;
primary      = literal | ident | "(" expr ")" | tableCtor ;

literal      = number | string | "true" | "false" | "nil" ;

tableCtor    = "{" [fieldList] "}" ;
fieldList    = field { "," field } ;
field        = ident "=" expr | "[" expr "]" "=" expr | expr ;

lvalue       = ident { "." ident | "[" expr "]" } ;

ident        = /[A-Za-z_][A-Za-z0-9_]*/ ;
number       = /[0-9]+(\.[0-9]+)?/ ;
string       = /"([^"\\]|\\.)*"/ ;

typeExpr     = typePrimary { "|" typePrimary } ;
typePrimary  = ident | "{" typeFieldList "}" | "(" [ typeList ] ")" "->" typeExpr ;
typeList     = typeExpr { "," typeExpr } ;
typeFieldList= typeField { "," typeField } ;
typeField    = ident ":" typeExpr ;
```

## Mapping Table: Feature -> Lua Equivalent

- `let x: T = expr` -> `local x = expr`
- `let x` -> `local x` (nil)
- `global x = expr` -> `x = expr` (explicitly allowed)
- `struct Name { x: T, y: T }` ->
  - `local Name = {}`
  - `function Name.new(x, y) return { x = x, y = y } end`
- `enum Color { Red, Green = 3 }` ->
  - `local Color = { Red = 1, Green = 3 }`
- `fn add(a: number, b: number): number { return a + b }` ->
  - `local function add(a, b) return a + b end`
- `match x { case 1 => ...; case _ => ... }` -> `if x == 1 then ... else ... end`
- Modules / namespaces -> standard Lua modules returning tables

## Example Input Code

```
struct Vec2 {
    x: number
    y: number
}

enum Axis {
    X
    Y
}

fn len(v: {x: number, y: number}): number {
    return (v.x * v.x + v.y * v.y) ^ 0.5
}

fn main() {
    let v: Vec2 = Vec2.new(3, 4)
    let a = Axis.X

    match a {
        case Axis.X => return len(v)
        case Axis.Y => return len({ x = v.y, y = v.x })
        case _ => return 0
    }
}
```

## Generated Lua/Luau Output

```
local Vec2 = {}
function Vec2.new(x, y)
    return { x = x, y = y }
end

local Axis = { X = 1, Y = 2 }

local function len(v)
    return (v.x * v.x + v.y * v.y) ^ 0.5
end

local function main()
    local v = Vec2.new(3, 4)
    local a = Axis.X
    if a == Axis.X then
        return len(v)
    elseif a == Axis.Y then
        return len({ x = v.y, y = v.x })
    else
        return 0
    end
end
```

## Explanation of Optimizations Applied

- `Axis.X` and `Axis.Y` are local table lookups; no globals involved.
- The `match` expression lowered to a straight `if/elseif` chain.
- `Vec2.new` is a plain table constructor with no metatable or hidden closure.
- Locals are used for all bindings to avoid accidental globals.

moduleDecl   = "module" modulePath stmtEnd ;
importDecl   = "import" modulePath [ "as" ident | "." "{" ident { "," ident } "}" ] stmtEnd ;
modulePath   = ident { "." ident } ;

exportStmt   = "export" ( fnDecl | structDecl | enumDecl | letStmt ) ;
