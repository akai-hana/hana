You are an expert Software Architect and an elite Zig developer. Your goal is to review, refactor, and reorganize my codebase to maximize readability, maintainability, and logical structure. I want this codebase to be incredibly intuitive for any newcomer to read and modify.

Here is the current directory structure for context:

❯ tree src
src
├── bar
│   ├── bar.zig
│   ├── c_bindings.zig
│   ├── drawing.zig
│   └── modules
│       ├── clock.zig
│       ├── layout
│       │   ├── layout.zig
│       │   └── variants.zig
│       ├── prompt
│       │   ├── modules
│       │   │   └── vim.zig
│       │   └── prompt.zig
│       ├── tags.zig
│       └── title
│           ├── modules
│           │   └── carousel.zig
│           └── title.zig
├── config
│   ├── config.zig
│   ├── fallback.zig
│   └── parser.zig
├── core
│   ├── constants.zig
│   ├── core.zig
│   ├── events.zig
│   ├── main.zig
│   ├── modules
│   │   ├── debug.zig
│   │   └── scale.zig
│   └── utils.zig
├── input
│   ├── input.zig
│   └── xkbcommon.zig
└── window
    ├── focus.zig
    ├── modules
    │   ├── floating
    │   │   ├── drag.zig
    │   │   └── floating.zig
    │   ├── fullscreen.zig
    │   ├── minimize.zig
    │   ├── tiling
    │   │   ├── layouts.zig
    │   │   ├── modules
    │   │   │   ├── fibonacci.zig
    │   │   │   ├── grid.zig
    │   │   │   ├── master.zig
    │   │   │   └── monocle.zig
    │   │   └── tiling.zig
    │   └── workspaces.zig
    ├── tracking.zig
    └── window.zig

17 directories, 37 files

~/eudaimonia/hana main !13                      0.16.0-dev
❯

Please perform a comprehensive refactoring of the provided code based on the following strict directives:
1. Naming Conventions & Idiomatic Zig

    Rename variables, constants, functions, and structs so they are perfectly descriptive.

    Adhere to Zig naming conventions: camelCase for functions/variables, PascalCase for types/structs. Avoid UPPER_SNAKE_CASE unless interacting with C.

    Boolean Semantics: Ensure boolean variables and functions use predicate prefixes (e.g., is, has, should, can) so logic reads like English.

    Ensure idiomatic use of explicit allocators, defer/errdefer, and try/catch.

2. Control Flow & Flattening (Guard Clauses)

    Minimize deep nesting: Refactor deeply indented if/else blocks using guard clauses (early returns/continues).

    Invert conditional logic where appropriate to keep the "happy path" at the lowest level of indentation.

    Prefer switch over if/else: Whenever checking multiple states or enums, use Zig’s exhaustive switch expressions for better clarity and safety.

3. "Newspaper" Code Structure & Abstraction

    Intra-file Ordering: Follow the "newspaper structure." High-level public APIs and primary structs at the top; implementation details and private helpers at the bottom.

    Single Level of Abstraction: Ensure functions do not mix high-level logic with low-level implementation details. Extract low-level operations (like bit manipulation or pointer math) into descriptive helper functions.

4. File Distribution & Architecture

    Single Responsibility: If a file is doing too much, explicitly suggest how to split it.

    Naming: If a file name is no longer accurate, suggest a new snake_case name.

    Coupling: Ensure boundaries between modules make sense and minimize tight coupling.

5. Code Quality & Documentation

    Do not change underlying business logic or behavior.

    Add high-value doc-comments (///) to top-level public functions/structs explaining why they exist.

Output Requirements:

    Briefly summarize the architectural flaws found and the specific changes made to fix them.

    Provide the refactored code with clear markdown headers for each file path.

    Explicitly state if new files need to be created or renamed.

    If the output is too long, provide critical files first and ask to continue.
