# BicepConsoleTTK

A Pester-based test framework for unit testing Azure Bicep exported functions, types, and variables via the Bicep console REPL.

## Overview

BicepConsoleTTK (**Bicep Console Test Tool Kit**) lets you write Pester unit tests that execute Bicep expressions directly in the Bicep console, so you can assert on the output. It is designed for teams that maintain shared Bicep libraries of exported functions, types, and variables and want to verify their behaviour in isolation — before any deployment.

The module exposes two commands:

| Command | Purpose |
|---|---|
| `Import-Bicep` | Reads one or more Bicep files and extracts the declarations you specify, returning them as a collated string ready to feed into the console. |
| `Invoke-BicepExpression` | Starts the Bicep console, writes the imported declarations and your expression to its stdin, captures stdout, and returns the evaluated result. |

## Features

- **Familiar import syntax** — named or wildcard imports modelled on modern module syntax.
- **Multi-file imports** — compose declarations from as many Bicep files as you need, in the order they are declared.
- **Deduplication** — importing the same member more than once (e.g. via a wildcard and a named import) emits it only once.
- **Setup declarations** — pre-declare intermediate variables in the console before the final expression, enabling multi-step test scenarios.
- **Pipeline input** — import strings can be piped into `Import-Bicep`.
- **Clear error messages** — Bicep console errors are caught, the tilde/caret noise stripped, and re-thrown as readable exceptions.
- **CI/CD ready** — no interactive prompts; works in any headless PowerShell environment.

## Prerequisites

| Dependency | Minimum version | Install |
|---|---|---|
| PowerShell | 5.1 (Desktop) or 7.0 (Core) | [aka.ms/powershell](https://aka.ms/powershell) |
| Pester | 5.x | `Install-Module Pester -Force -SkipPublisherCheck` |
| bicep | 0.42.1 or higher| https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install |


The `bicep` executable must be on your `PATH`.

## Installation

### From the PowerShell Gallery (recommended)

```powershell
Install-Module -Name BicepConsoleTTK -Repository PSGallery
```

Then in each test file's `BeforeAll` block:

```powershell
Import-Module BicepConsoleTTK -Force
```

### From source

Clone the repository and import directly from the source path — useful if you want to contribute or pin to a specific commit:

```powershell
git clone https://github.com/Andrew-D-Wilson/bicep-console-test-framework.git
```

```powershell
Import-Module "$PSScriptRoot/../src/BicepConsoleTTK" -Force
```

## Usage

### Import syntax

```powershell
# Named imports — only the listed members are extracted
$imports = Import-Bicep "import {coreParams, newCoreParams} from '$PSScriptRoot/../shared/Types.bicep'"

# Wildcard import — all exported members from the file
$imports = Import-Bicep "import * from '$PSScriptRoot/../shared/Types.bicep'"

# Multiple files — pass an array; import order is preserved
$imports = Import-Bicep @(
    "import {coreParams, newCoreParams} from '$PSScriptRoot/../shared/Types.bicep'",
    "import {basicResource}             from '$PSScriptRoot/../shared/NamingFunctions.bicep'"
)

# Pipeline input is also supported
$imports = "import {coreParams} from '$PSScriptRoot/../shared/Types.bicep'" | Import-Bicep
```

The `import` keyword is case-insensitive (`Import` or `import` both work). The returned string is the collated Bicep declarations with decorators (`@export()`, `@description()`, `@sealed()`, etc.) stripped, ready to be passed to `Invoke-BicepExpression`.

### Evaluating an expression

```powershell
$result = Invoke-BicepExpression -BicepImports $imports -Expression "newCoreParams('uksouth', 'uks', 'prod', 'myapp')"
```

Parameter aliases allow a more compact form:

```powershell
$result = Invoke-BicepExpression -b $imports -e "newCoreParams('uksouth', 'uks', 'prod', 'myapp')"
```

### Setup declarations

Use `-SetupDeclarations` (alias `-s`) to pre-declare variables in the console before the final expression. This is useful when you need to build up intermediate values or when Bicep requires typed variable declarations:

```powershell
$setupDeclarations = @(
    "var projectNameStart = 'hello'",
    "var projectNameComplete = '`${projectNameStart}world'",   # NOTE: $ must be escaped with a backtick inside PS double-quoted strings
    "var coreParameters coreParams = newCoreParams('uksouth', 'uks', 'dev', projectNameComplete)"
)

$result = Invoke-BicepExpression -b $imports -s $setupDeclarations -e "basicResource('aks', coreParameters)"
```

### Example Pester test file

```powershell
BeforeAll {
    Import-Module BicepConsoleTTK -Force
}

Describe "Naming Functions" {
    BeforeAll {
        $script:imports = Import-Bicep @(
            "import {coreParams, newCoreParams} from '$PSScriptRoot/../shared/Types.bicep'",
            "import {basicResource, csResource} from '$PSScriptRoot/../shared/NamingFunctions.bicep'"
        )
    }

    It "basicResource includes abbreviation, project, environment and location" {
        $result = Invoke-BicepExpression -b $script:imports `
            -e "basicResource('aks', newCoreParams('uksouth', 'uks', 'dev', 'myapp'))"

        $result | Should -Be "'aks-myapp-dev-uksouth'"
    }

    It "csResource inserts contextName between project and environment" {
        $result = Invoke-BicepExpression -b $script:imports `
            -e "csResource('aks', newCoreParams('uksouth', 'uks', 'dev', 'myapp'), 'networking')"

        $result | Should -Be "'aks-myapp-networking-dev-uksouth'"
    }
}
```

### Running the tests

```powershell
Invoke-Pester -Path ./tests
```

## How It Works

1. **`Import-Bicep`** parses each import string with a regex, resolves the file path, and walks the Bicep source line-by-line using brace counting and arrow-function heuristics to extract complete member definitions (including any preceding decorators). A `HashSet` tracks already-emitted members so duplicates are silently skipped. The accumulated text is returned as a single string.

2. **`Invoke-BicepExpression`** prepares the imports for the console by stripping all decorator lines (the REPL does not accept them) and collapsing multi-line arrow-function bodies onto a single line (the REPL only evaluates a statement when its braces are balanced, so a body that starts on the next line would be treated as a second, incomplete statement). It then spawns `bicep console` as a child process with stdin/stdout/stderr all redirected, writes the imports, any setup declarations, and the expression to stdin, closes stdin to signal EOF, reads all stdout, and detects Bicep errors by looking for lines that start with `~` or `^` underline characters. On error, the underline and the surrounding context are parsed into a clean exception message.

## Copilot Integration

This repository ships two complementary artefacts that teach GitHub Copilot how to write BicepConsoleTTK tests.

### Agent skill (recommended)

The `.github/skills/bicepconsolettk/SKILL.md` file is a [GitHub Copilot agent skill](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/add-skills). When Copilot is working in agent mode it will automatically load this skill whenever the task is related to writing Bicep tests, injecting the full authoring guide into its context.

The skill is picked up automatically from `.github/skills/` in any repository that contains it.

### VS Code instructions file

The `bicepconsolettk.instructions.md` file is a VS Code Copilot [custom instructions file](https://code.visualstudio.com/docs/copilot/copilot-customization). Copy it into your project at `.github/instructions/bicepconsolettk.instructions.md` and VS Code will automatically apply it whenever you work on `*.Tests.ps1` files in that workspace.

---

## Project Structure

```
src/
  BicepConsoleTTK/
    BicepConsoleTTK.psd1   # Module manifest
    BicepConsoleTTK.psm1   # Module implementation
examples/
  Types.bicep              # Example exported types and constructor functions
  NamingFunctions.bicep    # Example exported naming convention functions
  Variables.bicep          # Example exported shared variables
tests/
  BicepConsoleTTK.Tests.ps1  # Pester test suite for the framework itself
.github/
  skills/
    bicepconsolettk/
      SKILL.md             # GitHub Copilot agent skill
  instructions/            # (not committed — copy bicepconsolettk.instructions.md here)
bicepconsolettk.instructions.md  # VS Code Copilot custom instructions file
```

