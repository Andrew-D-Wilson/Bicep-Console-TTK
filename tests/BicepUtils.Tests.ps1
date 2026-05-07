Describe "Invoke-BicepExpression" {
    BeforeAll {
        Remove-Module -Name BicepUtils -ErrorAction SilentlyContinue
        Import-Module "$PSScriptRoot/../src/BicepUtils/BicepUtils.psm1" -Force
    }

    It "Invoke-BicepExpression should evaluate a user-defined function imported from a single Bicep file" {

        $bicepCode = Import-Bicep "import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'"

        $expression = "newCoreParams('ukwest', 'ukw', 'dev', 'myproject')"
        $result = Invoke-BicepExpression -BicepCode $bicepCode -Expression $expression
		
        $expected = "{`n  location: 'ukwest'`n  locationShortName: 'ukw'`n  environment: 'dev'`n  projectPrefix: 'myproject'`n}"
        $result | Should -Be $expected
    }

    It "Invoke-BicepExpression should evaluate an expression using declarations imported from multiple Bicep files" {

        $bicepCode = Import-Bicep @(
            "import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'",
            "import {basicResource} from '$PSScriptRoot/../examples/Functions.bicep'"
        )

        $expression = "basicResource('aks', newCoreParams('ukwest', 'ukw', 'dev', 'myproject'))"
        $result = Invoke-BicepExpression -BicepCode $bicepCode -Expression $expression

        $expected = "'aks-myproject-dev-ukwest'"
        $result | Should -Be $expected
    }
}
