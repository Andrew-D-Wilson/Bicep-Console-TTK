---
name: bicepconsolettk
description: Guide for writing Pester unit tests for Azure Bicep shared libraries using the BicepConsoleTTK PowerShell module. Use this skill when asked to write, generate, or fix Pester tests that evaluate Bicep functions, types, or variables using the bicep console REPL.
---

You are helping the user write Pester unit tests for Azure Bicep shared libraries using the **BicepConsoleTTK** PowerShell module. Tests drive the `bicep console` REPL locally — no Azure subscription or deployment is needed.

---

## Module Setup

### Install the module (once per machine or CI agent)

BicepConsoleTTK is published to the PowerShell Gallery. Install it before running any tests:

```powershell
Install-Module -Name BicepConsoleTTK -Repository PSGallery
```

For CI/CD pipelines, set PSGallery as trusted first to avoid interactive prompts:

```powershell
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name BicepConsoleTTK -Repository PSGallery
```

### Import in each test file

Every test file must import the module in a top-level `BeforeAll` block:

```powershell
BeforeAll {
    Import-Module BicepConsoleTTK -Force
}
```

If consuming from source instead of the Gallery, adjust the path accordingly:

```powershell
Import-Module "$PSScriptRoot/../src/BicepConsoleTTK" -Force
```

---

## Importing Bicep Declarations

Use `Import-Bicep` to extract exported `func`, `type`, and `var` declarations from Bicep files.
The return value is a collated string passed to `Invoke-BicepExpression`.

### Named import (one or more members)

```powershell
$imports = Import-Bicep "import {MyType, myFunc} from '$PSScriptRoot/../shared/Types.bicep'"
```

### Wildcard import (all exported members from a file)

```powershell
$imports = Import-Bicep "import * from '$PSScriptRoot/../shared/Types.bicep'"
```

### Multiple files (order matters — declare dependencies first)

```powershell
$imports = Import-Bicep @(
    "import {coreParams, newCoreParams} from '$PSScriptRoot/../shared/Types.bicep'",
    "import {basicResource}             from '$PSScriptRoot/../shared/NamingFunctions.bicep'"
)
```

### Scope imports to a `Describe` or `Context` using `BeforeAll`

Declare `$script:imports` once per suite so the files are only parsed once, not once per test:

```powershell
Describe "Naming Functions" {
    BeforeAll {
        $script:imports = Import-Bicep @(
            "import {coreParams, newCoreParams} from '$PSScriptRoot/../shared/Types.bicep'",
            "import {basicResource}             from '$PSScriptRoot/../shared/NamingFunctions.bicep'"
        )
    }

    It "..." { ... }
}
```

### Import rules
- The `import` keyword is case-insensitive (`import` or `Import` both work).
- A missing file throws immediately: `Import-Bicep: File not found: <path>`.
- A missing named member emits a `Write-Warning` (does not throw).
- The same member imported twice (e.g. via wildcard then by name) is deduplicated automatically.
- All decorators (`@export()`, `@description()`, `@sealed()`, etc.) are stripped automatically — the Bicep console REPL does not accept them.

---

## Evaluating Expressions

```powershell
# Full parameter names
$result = Invoke-BicepExpression -BicepImports $imports -Expression "myFunc('arg1', 'arg2')"

# Short aliases: -b, -e, -s
$result = Invoke-BicepExpression -b $imports -e "myFunc('arg1', 'arg2')"

# No imports required for Bicep built-ins
$result = Invoke-BicepExpression -e "concat('hello', '-', 'world')"
```

---

## Setup Declarations

Use `-SetupDeclarations` (`-s`) to pre-declare typed intermediate variables in the console
before the final expression. This is necessary when the expression depends on values that
must be bound to a named Bicep type:

```powershell
$setup = @(
    "var env = 'dev'",
    "var core coreParams = newCoreParams('uksouth', 'uks', env, 'myapp')"
)
$result = Invoke-BicepExpression -b $imports -s $setup -e "basicResource('aks', core)"
```

---

## Understanding Output Formats

The Bicep console returns values exactly as Bicep would represent them internally.

| Bicep type | Example expression | Returned string |
|---|---|---|
| `string` | `concat('a', 'b')` | `'ab'` (includes the single quotes) |
| `int` | `add(1, 2)` | `3` |
| `bool` | `equals(1, 1)` | `true` |
| `null` | `null` | `null` |
| `object` | `{a: 'x', b: 'y'}` | `{\n  a: 'x'\n  b: 'y'\n}` |
| `array[0]` | `items[0]` | first element in its own format |

Use these formats directly in `Should -Be` assertions:

```powershell
$result | Should -Be "'aks-myapp-dev-uksouth'"   # string
$result | Should -Be "{\n  key: 'value'\n}"       # object (use backtick-n in PS)
```

For objects, construct the expected value with the PowerShell backtick escape for newlines:

```powershell
$expected = "{`n  location: 'uksouth'`n  environment: 'dev'`n}"
$result | Should -Be $expected
```

---

## PowerShell String Escaping

Inside **double-quoted** PowerShell strings, `$` is interpreted by PowerShell before Bicep sees it.
Escape it with a backtick when the `$` is part of a Bicep interpolation:

```powershell
# WRONG — PowerShell expands ${prefix} before passing to Bicep
"var name = '${prefix}-suffix'"

# CORRECT — backtick prevents PowerShell expansion
"var name = '`${prefix}-suffix'"
```

This applies everywhere a Bicep string interpolation appears inside a PS double-quoted string,
including import paths and setup declarations.

---

## Test Structure Patterns

### Pattern 1 — Simple function test

```powershell
Describe "My Functions" {
    BeforeAll {
        Import-Module BicepConsoleTTK -Force
        $script:imports = Import-Bicep "import {myFunc} from '$PSScriptRoot/../shared/Functions.bicep'"
    }

    It "myFunc should return the expected value" {
        $result = Invoke-BicepExpression -b $script:imports -e "myFunc('input')"
        $result | Should -Be "'expected-output'"
    }
}
```

### Pattern 2 — Type constructor test

```powershell
It "newCoreParams should populate all fields" {
    $result = Invoke-BicepExpression -b $script:imports `
        -e "newCoreParams('uksouth', 'uks', 'dev', 'myapp')"

    $expected = "{`n  location: 'uksouth'`n  locationShortName: 'uks'`n  environment: 'dev'`n  projectPrefix: 'myapp'`n}"
    $result | Should -Be $expected
}
```

### Pattern 3 — Typed intermediate variable (SetupDeclarations)

```powershell
It "should produce the correct name using a pre-declared typed variable" {
    $setup = @(
        "var core coreParams = newCoreParams('uksouth', 'uks', 'dev', 'myapp')"
    )
    $result = Invoke-BicepExpression -b $script:imports -s $setup -e "basicResource('aks', core)"
    $result | Should -Be "'aks-myapp-dev-uksouth'"
}
```

### Pattern 4 — Variable value test

```powershell
It "environmentConfig.prod.sku should be Premium" {
    $result = Invoke-BicepExpression -b $script:imports -e "environmentConfig.prod.sku"
    $result | Should -Be "'Premium'"
}

It "subnetConfigurations first entry should be web-subnet" {
    $result = Invoke-BicepExpression -b $script:imports -e "subnetConfigurations[0].name"
    $result | Should -Be "'web-subnet'"
}
```

### Pattern 5 — Error assertion

```powershell
It "should throw when a deployment-time function is used in the REPL" {
    { Invoke-BicepExpression -b $script:imports -e "myDeploymentOnlyVar" } |
        Should -Throw "*Bicep console error*"
}
```

---

## REPL Limitations

Certain Bicep constructs are deployment-time only and **cannot** be evaluated in the console REPL:

- `deployment()` — references deployment context; not available in REPL.
- `resourceGroup()` — requires a live deployment scope.
- `subscription()` — requires a live deployment scope.
- Any `resource` declarations.

If a `var` uses any of these, exclude it from your import and assert that it throws if your test suite needs to document the limitation:

```powershell
It "should throw because deployment() is not available in the REPL" {
    $importWithDeploymentVar = Import-Bicep "import {mandatoryTags} from '$PSScriptRoot/../shared/Variables.bicep'"
    { Invoke-BicepExpression -b $importWithDeploymentVar -e "mandatoryTags" } |
        Should -Throw "*Bicep console error*"
}
```

---

## Mocking Internal Behaviour

Use `InModuleScope BicepConsoleTTK` to mock functions inside the module (e.g. to test
what happens when `bicep` is not on `PATH`):

```powershell
It "should throw a helpful error when bicep CLI is not found" {
    InModuleScope BicepConsoleTTK {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'bicep' }
        { Invoke-BicepExpression -e "concat('a', 'b')" } | Should -Throw "*bicep CLI not found*"
    }
}
```

---

## Checklist When Authoring a New Test Suite

- [ ] `Import-Module BicepConsoleTTK -Force` in the top-level `BeforeAll`.
- [ ] `$script:imports` declared in a `BeforeAll` scoped to the `Describe`/`Context` — not inside individual `It` blocks.
- [ ] Import dependency files (types first, then functions that reference those types).
- [ ] String assertions include the surrounding single quotes (e.g. `"'myvalue'"`).
- [ ] Object assertions use `` `n `` for newlines and two-space indentation.
- [ ] Dollar signs in Bicep interpolations inside PS double-quoted strings are backtick-escaped.
- [ ] Deployment-time variables are either excluded from imports or tested with `Should -Throw`.
