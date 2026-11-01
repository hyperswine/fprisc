# MConf — Typed Configuration Language

**Version:** 0.1 (Draft)
**Implementation:** FP-RISC
**CLI:** `mconf`
**Integration:** FP-RISC, SOL, JSON

## 1. Overview

MConf is a small, statically typed, declarative configuration language intended as an alternative to YAML, TOML, and JSON.

Its primary goals are:

- **Simple:** Minimal syntax with predictable rules.
- **Typed:** Values have explicit or inferred types.
- **Declarative:** Assignment order does not affect the result.
- **Deterministic:** No arbitrary computation or side effects.
- **Composable:** Support references, nested objects, and typed collections.
- **Interoperable:** Convert to/from common formats, especially JSON.
- **Native:** Straightforward to parse and manipulate using FP-RISC and SOL.

MConf is a data description language, not a general-purpose programming language.

## 2. Basic Syntax

```mconf
# Application configuration

app.name = "MyApp"
app.version = 1
app.debug = false

server.host = "localhost"
server.port = 8080
server.timeout = 30s

server.port : Int
server.timeout : Duration
```

The two fundamental operators are:

| Operator | Purpose |
|---|---|
| `=` | Assign a value |
| `:` | Declare a type |

Assignments and type declarations may appear in any order.

Dotted paths identify nested fields. Quoted path components allow names containing dots or other special characters.

```mconf
server."http.port" = 8080
```

### Block syntax

Blocks provide syntactic sugar for nested paths.

```mconf
server {
    host = "localhost"
    port = 8080
}
```

Equivalent to:

```mconf
server.host = "localhost"
server.port = 8080
```

Blocks do not introduce new evaluation scopes or execution order.

## 3. Type System

### Primitive types

| Type | Example |
|---|---|
| `String` | `"hello"` |
| `Int` | `42` |
| `Float` | `3.14` |
| `Bool` | `true` |
| `Duration` | `30s`, `5m`, `2h` |
| `Null` | `null` |

### Compound types

```mconf
name : String
port : Int
enabled : Bool

tags : List[String]
scores : Map[String, Int]

optional_name : String?
identifier : String | Int
```

Types are inferred from values when unambiguous.

```mconf
port = 8080           # Int
name = "server"       # String
enabled = true        # Bool
```

Empty collections require annotations when their element types cannot be inferred.

No implicit conversions are performed between unrelated types.

### Records

Records contain named fields and may have explicit type declarations.

```mconf
server : {
    host: String,
    port: Int,
    enabled: Bool
}

server = {
    host = "localhost"
    port = 8080
    enabled = true
}
```

Records are closed by default: additional undeclared fields are errors.

### Optional values

Optional types distinguish between absence and an explicit null value.

```mconf
nickname : String?
nickname = null
```

An absent optional field and one explicitly assigned `null` are distinct in the MConf semantic model.

### Constraints (proposed)

Simple local constraints may restrict valid values.

```mconf
server.port : Int where 1 <= value && value <= 65535
```

Constraints are pure validation predicates. The initial implementation may defer this feature.

## 4. References

MConf supports references to other configuration entries.

```mconf
server.host = "localhost"
server.port = 8080

client.host = server.host
client.port = server.port
```

References follow these rules:

1. Resolved independently of declaration order.
2. Must refer to existing values.
3. Cannot form cycles.
4. Preserve the referenced value's type.
5. Cannot perform arbitrary operations or invoke functions.

A reference can appear before its target.

```mconf
client.port = server.port
server.port = 8080
```

Both declarations are valid.

Quoted strings are always literal strings, not references.

## 5. Collections

```mconf
servers = [
    "alpha",
    "beta",
    "gamma"
]

ports : List[Int]
ports = [8080, 8081, 8082]

metadata : Map[String, String]
metadata = {
    environment = "development"
    region = "ap-southeast-2"
}
```

Lists preserve element order. Object and map key order is not semantically significant.

## 6. Validation Rules

MConf uses strict validation by default.

| Condition | Behaviour |
|---|---|
| Duplicate assignment | Error |
| Duplicate conflicting type | Error |
| Reference cycle | Error |
| Undefined reference | Error |
| Type mismatch | Error |
| Leaf/object path collision | Error |
| Unknown record field | Error |
| Ambiguous empty collection | Requires type |
| Invalid constraint | Error |
| Missing required field | Error |

Configuration loading is atomic: a document either validates completely or produces errors. No partially valid configuration is returned as a successful result.

## 7. JSON Conversion

MConf can generate standard JSON.

Input (`config.mconf`):

```mconf
app.name = "Demo"
app.debug = true

server.host = "localhost"
server.port = 8080

client.port = server.port

features = ["logging", "cache"]
```

Command:

```sh
mconf to-json config.mconf
```

Output:

```json
{
  "app": {
    "name": "Demo",
    "debug": true
  },
  "server": {
    "host": "localhost",
    "port": 8080
  },
  "client": {
    "port": 8080
  },
  "features": ["logging", "cache"]
}
```

References are fully resolved before serialization.

Type annotations are omitted because ordinary JSON does not preserve MConf type metadata.

Conversion rules:

- `String` → JSON string
- `Int`, `Float` → JSON number
- `Bool` → JSON boolean
- `List` → JSON array
- Record/Map → JSON object
- `Null` → JSON null
- `Duration` → canonical string, e.g. `"30s"`
- Absent optional fields → omitted JSON properties

JSON import can infer basic types, but cannot automatically recover MConf-specific type declarations or constraints.

## 8. CLI Design

The `mconf` utility provides parsing, validation, conversion, and inspection.

```sh
# Validate a configuration
mconf check config.mconf

# Convert to JSON
mconf to-json config.mconf

# Save JSON output
mconf to-json config.mconf -o config.json

# Import JSON
mconf from-json config.json

# Retrieve a particular value
mconf get config.mconf server.port

# Print the inferred or declared type
mconf type config.mconf server.port

# Format a configuration
mconf fmt config.mconf
```

Commands should return nonzero exit codes on errors and report diagnostics with source locations.

The first implementation only needs:

```sh
mconf check
mconf to-json
mconf get
```

Other commands can be added later.

## 9. FP-RISC Implementation

The implementation should consist of pure, composable stages.

```text
Source Text
    |
    v
Lexer
    |
    v
Parser
    |
    v
AST
    |
    v
Namespace Construction
    |
    v
Reference Resolution
    |
    v
Type Checking
    |
    v
Validated Config
    |
    v
JSON / Native Value
```

Suggested conceptual types (illustrative FP-RISC pseudocode):

```text
MValue =
    String String
  | Int Int
  | Float Float
  | Bool Bool
  | Duration Duration
  | Null
  | List (List MValue)
  | Object (Map String MValue)

MType =
    TString
  | TInt
  | TFloat
  | TBool
  | TDuration
  | TNull
  | TList MType
  | TMap MType MType
  | TOptional MType
  | TUnion (List MType)
  | TRecord (Map String MType)

MExpr =
    Literal MValue
  | Reference Path
  | Array (List MExpr)
  | Object (Map String MExpr)
```

The actual AST must additionally preserve assignments, type declarations, source locations, and unresolved expressions.

Suggested API:

```text
parse    : String -> Result ParseError AST
resolve  : AST -> Result ResolveError ResolvedConfig
validate : ResolvedConfig -> Result TypeError Config
toJSON   : Config -> Result EncodeError String
get      : Config -> Path -> Option MValue
```

Each stage should be pure.

File access, command-line argument handling, and output belong to the CLI adapter rather than the parser or validator.

### Reference implementation

[`examples/mconf.fpr`](../examples/mconf.fpr) is a working v0.1 front end for this
design: one FP-RISC Base program, no dependencies beyond `std`.

```sh
fpr run examples/mconf.fpr check   config.mconf
fpr run examples/mconf.fpr to-json config.mconf [-o config.json]
fpr run examples/mconf.fpr get     config.mconf server.port
fpr run examples/mconf.fpr type    config.mconf server.port
```

The five stages above are five pure functions — `parseMconf`, `spaceOf`,
`resolveRoot`, `typeErrors`, `renderValue` — and only `load` reads a file, so
the CLI is the sole place that reads, prints or exits.

Implemented: comments, dotted paths, quoted path components, blocks, strings
with escapes, integers, floats (kept as written), booleans, `null`, durations,
lists, objects, primitive/`List`/`Map`/optional/union/record types, references
(forward references and references to whole subtrees), cycle detection, and the
validation rules of §6: duplicate assignment, leaf/object collision, undefined
reference, type mismatch, unknown record field, missing required field,
ambiguous empty collection, and conflicting type declarations. Diagnostics carry
the line and column of the declaration to change, and every clash, unresolved
reference and type error in a document is reported at once.

Not implemented yet: constraints (`where`, §3), `fmt`, `from-json`, and
structural merging (§11). Durations render from their literal text (`30s`,
`250ms`) rather than being normalised, and JSON output is indented two spaces
with keys in ascending order.

## 10. SOL Integration

MConf should be a natural configuration format for SOL scripts.

Example:

```mconf
# build.mconf

project.name = "example"
project.target = "qos-rv64"
project.optimize = true

build.output = "build/"
build.jobs = 4
```

Conceptual SOL usage:

```text
config = mconf.read("build.mconf")?
target = config.get[String]("project.target")?
jobs = config.get[Int]("build.jobs")?
```

The exact syntax depends on the eventual SOL library API.

SOL integration should provide:

- Typed lookups returning `Result` or `Option`.
- A fully validated, immutable configuration value.
- No implicit execution of configuration expressions.
- Explicit file-reading effects.
- Ability to convert configurations to JSON and native FP-RISC data.

The configuration parser itself remains pure. SOL controls when file I/O takes place, allowing MConf operations to participate in SOL's transactional effect model.

## 11. Determinism and Merging

A valid MConf file represents a set of declarations, not a sequence of commands.

Consequently, independent assignments may be reordered without changing the resulting configuration.

Two configurations can be combined structurally:

```text
merge : Config -> Config -> Result MergeConflict Config
```

Initial merge policy:

- Disjoint fields combine.
- Conflicting values produce errors.
- Conflicting types produce errors.
- No silent last-write-wins overriding.

Explicit override policies may be added later.

## 12. Non-Goals

MConf is intentionally not intended to support:

- Loops or conditionals.
- Arbitrary functions.
- General arithmetic expressions.
- Runtime evaluation or code execution.
- Environment-dependent implicit values.
- Implicit type coercion.
- Order-dependent assignment semantics.

These capabilities belong in FP-RISC or SOL, not the configuration language.

## 13. Implementation Milestones

**v0.1 — Core**
- Lexer/parser
- Strings, numbers, booleans, lists, objects
- Dotted assignments
- Basic type annotations and inference
- Reference resolution and cycle detection
- JSON generation
- `mconf check`, `mconf to-json`, `mconf get`

**v0.2 — Typed data**
- Explicit records
- Optional and union types
- Maps
- Duration literals
- JSON import
- Source diagnostics

**v0.3 — Integration**
- Native FP-RISC library
- SOL bindings
- Structural merging
- Canonical formatting
- Local constraints

## 14. Design Principle

MConf should remain small enough to have a complete, unambiguous specification and straightforward implementation.

Its core abstraction is:

**A typed, immutable configuration graph whose references can be fully resolved and validated before use.**

It should describe data, while FP-RISC and SOL decide what to do with that data.
