Describe "Invoke-BicepExpression" {
    BeforeAll {
        Remove-Module -Name BicepUtils -ErrorAction SilentlyContinue
        Import-Module "$PSScriptRoot/../src/BicepUtils/BicepUtils.psm1" -Force
    }

    It "Invoke-BicepExpression should evaluate a standalone expression without any imports" {

        $result = Invoke-BicepExpression -Expression "concat('hello', '-', 'world')"

        $result | Should -Be "'hello-world'"
    }

    It "Invoke-BicepExpression should evaluate a user-defined function imported from a single Bicep file" {

        $bicepImports = Import-Bicep "import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'"

        $expression = "newCoreParams('ukwest', 'ukw', 'dev', 'myproject')"
        $result = Invoke-BicepExpression -BicepImports $bicepImports -Expression $expression
		
        $expected = "{`n  location: 'ukwest'`n  locationShortName: 'ukw'`n  environment: 'dev'`n  projectPrefix: 'myproject'`n}"
        $result | Should -Be $expected
    }

    It "Invoke-BicepExpression should evaluate an expression using declarations imported from multiple Bicep files" {

        $bicepImports = Import-Bicep @(
            "import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'",
            "import {basicResource} from '$PSScriptRoot/../examples/NamingFunctions.bicep'"
        )

        $expression = "basicResource('aks', newCoreParams('ukwest', 'ukw', 'dev', 'myproject'))"
        $result = Invoke-BicepExpression -BicepImports $bicepImports -Expression $expression

        $expected = "'aks-myproject-dev-ukwest'"
        $result | Should -Be $expected
    }
    It "Invoke-BicepExpression should support setup expressions to pre-declare variables before the main expression" {

        $bicepImports = Import-Bicep @(
            "Import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'",
            "Import {basicResource} from '$PSScriptRoot/../examples/NamingFunctions.bicep'"
        )

        $setupDeclarations = @(
			"var projectNameStart = 'helloworld'",
			"var projectNameComplete = '`${projectNameStart}bicep'", # This needs to be noted in documentation that $ needs to be escaped else it will be evaluated by PowerShell instead of passed to Bicep
            "var coreParameters coreParams = newCoreParams('ukwest', 'ukw', 'dev', projectNameComplete)"
        )
        $expression = "basicResource('aks', coreParameters)"
        $result = Invoke-BicepExpression -b $bicepImports -s $setupDeclarations -e $expression

        $expected = "'aks-helloworldbicep-dev-ukwest'"
        $result | Should -Be $expected
    }
}