# Project: Zig Build Instructions

## Build Command
Always use this exact command to compile:
```
zig build -Drelease=true --color on --error-style minimal
```

## Workflow Rules
- After EVERY edit to any file, run the build command immediately.
- Parse the output for errors. If there are errors, fix them, then recompile.
- Repeat the fix → compile cycle until the build exits with zero errors.
- Only after a clean build should you move on to the next file.
- Never ask for confirmation between steps.
- Never stop mid-loop to summarize progress — just keep going.
