# Racket Development Guide for LLM Agents

This document describes command-line tools for writing, debugging, and maintaining Racket code.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `racket <file.rkt>` | Run file (reports syntax/runtime errors) |
| `racket -e '<expr>'` | Evaluate expression directly |
| `raco make <file>` | Compile to bytecode (catches errors early) |
| `raco test <file>` | Run tests |
| `raco fmt <file>` | Format code |
| `raco warn <file>` | Check for syntax warnings |
| `raco fix <file>` | Auto-fix syntax warnings |

## Core Tools

### 1. `racket` - The Interpreter

```bash
# Run a file (catches syntax and runtime errors)
racket src/cli.rkt

# Evaluate an expression directly
racket -e '(+ 1 2)'

# Load a module
racket -l ar-crawl/cli
```

### 2. `raco make` - Bytecode Compiler

Compiles modules to bytecode. Useful for catching errors without running:

```bash
raco make src/cli.rkt
raco make src/*.rkt  # Compile all source files
```

### 3. `raco test` - Test Runner

Runs test submodules in files:

```bash
raco test tests/           # Run all tests in directory
raco test src/utils.rkt    # Run tests in specific file
raco test -x tests/        # Stop on first failure
```

### 4. `raco cover` - Code Coverage

```bash
raco cover tests/          # Generate coverage report
```

## Code Quality Tools

### `raco fmt` - Code Formatter

Install: `raco pkg install fmt`

```bash
raco fmt src/cli.rkt           # Print formatted code to stdout
raco fmt --width 100 file.rkt  # Custom line width
```

### `raco warn` / `raco fix` - Linting

Install: `raco pkg install syntax-warn`

```bash
raco warn src/cli.rkt    # Check for style issues
raco fix src/cli.rkt     # Auto-fix warnings
```

## Debugging

### Macro Expansion

```bash
# In REPL or code:
(require macro-debugger/expand)
(expand/step #'(my-macro arg))
```

### Debug Language Extension

Add `#lang debug racket` and use `#R` before expressions:

```racket
#lang debug racket
(define x 42)
#R(+ x 1)  ; Prints: (+ x 1) = 43
```

## Type Checking (Typed Racket)

For files using `#lang typed/racket`, type errors are reported on load:

```bash
racket my-typed-file.rkt  # Reports type errors automatically
```

## Package Management

```bash
raco pkg install <package>   # Install a package
raco pkg update <package>    # Update a package
raco pkg remove <package>    # Remove a package
raco pkg show                # List installed packages
raco setup                   # Rebuild all documentation/indexes
```

## Language Server Protocol (LSP)

For real-time diagnostics in editors:

```bash
raco pkg install racket-langserver
```

Provides: diagnostics, hover info, go-to-definition, document symbols.

## Project-Specific Commands

This project uses a Makefile. Common targets:

```bash
make test      # Run all tests
make build     # Build the project
```

## Recommended Workflow

1. **Write code** in `.rkt` files
2. **Compile check**: `raco make <file>` - catches syntax errors
3. **Format**: `raco fmt <file>` - ensure consistent style
4. **Lint**: `raco warn <file>` - catch potential issues
5. **Test**: `raco test <file>` - verify functionality
6. **Run**: `racket <file>` - execute

## Resources

- [raco: Racket Command-Line Tools](https://docs.racket-lang.org/raco/)
- [Racket Guide](https://docs.racket-lang.org/guide/)
- [fmt Formatter](https://docs.racket-lang.org/fmt/)
- [Typed Racket Guide](https://docs.racket-lang.org/ts-guide/)
