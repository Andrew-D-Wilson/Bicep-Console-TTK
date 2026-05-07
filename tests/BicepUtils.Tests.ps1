Describe "Invoke-BicepExpression" {
    BeforeAll {
        Remove-Module -Name BicepUtils -ErrorAction SilentlyContinue
        Import-Module "$PSScriptRoot/../src/BicepUtils/BicepUtils.psm1" -Force
    }

    Context "Basic evaluation" {

        It "should evaluate a standalone expression without any imports" {

            $result = Invoke-BicepExpression -Expression "concat('hello', '-', 'world')"

            $result | Should -Be "'hello-world'"
        }

        It "should evaluate a user-defined function imported from a single Bicep file" {

            $bicepImports = Import-Bicep "import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'"

            $expression = "newCoreParams('ukwest', 'ukw', 'dev', 'myproject')"
            $result = Invoke-BicepExpression -BicepImports $bicepImports -Expression $expression

            $expected = "{`n  location: 'ukwest'`n  locationShortName: 'ukw'`n  environment: 'dev'`n  projectPrefix: 'myproject'`n}"
            $result | Should -Be $expected
        }

        It "should evaluate an expression using declarations imported from multiple Bicep files" {

            $bicepImports = Import-Bicep @(
                "import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'",
                "import {basicResource} from '$PSScriptRoot/../examples/NamingFunctions.bicep'"
            )

            $expression = "basicResource('aks', newCoreParams('ukwest', 'ukw', 'dev', 'myproject'))"
            $result = Invoke-BicepExpression -BicepImports $bicepImports -Expression $expression

            $result | Should -Be "'aks-myproject-dev-ukwest'"
        }

        It "should support setup declarations to pre-declare variables before the main expression" {

            $bicepImports = Import-Bicep @(
                "Import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'",
                "Import {basicResource} from '$PSScriptRoot/../examples/NamingFunctions.bicep'"
            )

            $setupDeclarations = @(
                "var projectNameStart = 'helloworld'",
                "var projectNameComplete = '`${projectNameStart}bicep'", # NOTE: $ must be escaped with a backtick inside PS double-quoted strings, otherwise PS evaluates it before Bicep sees it
                "var coreParameters coreParams = newCoreParams('ukwest', 'ukw', 'dev', projectNameComplete)"
            )
            $expression = "basicResource('aks', coreParameters)"
            $result = Invoke-BicepExpression -b $bicepImports -s $setupDeclarations -e $expression

            $result | Should -Be "'aks-helloworldbicep-dev-ukwest'"
        }

        It "should support wildcard import to bring in all members from a file" {

            $bicepImports = Import-Bicep "import * from '$PSScriptRoot/../examples/Types.bicep'"

            $expression = "newCoreParams('ukwest', 'ukw', 'dev', 'myproject')"
            $result = Invoke-BicepExpression -BicepImports $bicepImports -Expression $expression

            $expected = "{`n  location: 'ukwest'`n  locationShortName: 'ukw'`n  environment: 'dev'`n  projectPrefix: 'myproject'`n}"
            $result | Should -Be $expected
        }
    }

    Context "NamingFunctions" {
        BeforeAll {
            $script:namingImports = Import-Bicep @(
                "import {coreParams, newCoreParams} from '$PSScriptRoot/../examples/Types.bicep'",
                "import {basicResource, unlocalisedBasicResource, csResource, resourceGroup, resourceGroupNonEnvSpecific, storageAccountResource} from '$PSScriptRoot/../examples/NamingFunctions.bicep'"
            )
        }

        It "basicResource should include resourceAbbreviation, projectPrefix, environment and location" {

            $result = Invoke-BicepExpression -BicepImports $script:namingImports `
                -Expression "basicResource('aks', newCoreParams('ukwest', 'ukw', 'dev', 'myproject'))"

            $result | Should -Be "'aks-myproject-dev-ukwest'"
        }

        It "unlocalisedBasicResource should omit location" {

            $result = Invoke-BicepExpression -BicepImports $script:namingImports `
                -Expression "unlocalisedBasicResource('aks', newCoreParams('ukwest', 'ukw', 'dev', 'myproject'))"

            $result | Should -Be "'aks-myproject-dev'"
        }

        It "csResource should include contextName between projectPrefix and environment" {

            $result = Invoke-BicepExpression -BicepImports $script:namingImports `
                -Expression "csResource('aks', newCoreParams('ukwest', 'ukw', 'dev', 'myproject'), 'networking')"

            $result | Should -Be "'aks-myproject-networking-dev-ukwest'"
        }

        It "resourceGroup should use rg- prefix and include contextName" {

            $result = Invoke-BicepExpression -BicepImports $script:namingImports `
                -Expression "resourceGroup('networking', newCoreParams('ukwest', 'ukw', 'dev', 'myproject'))"

            $result | Should -Be "'rg-myproject-networking-dev-ukwest'"
        }

        It "resourceGroupNonEnvSpecific should omit environment and suffix with -shared" {

            $result = Invoke-BicepExpression -BicepImports $script:namingImports `
                -Expression "resourceGroupNonEnvSpecific('networking', newCoreParams('ukwest', 'ukw', 'dev', 'myproject'))"

            $result | Should -Be "'rg-myproject-networking-ukwest-shared'"
        }

        It "storageAccountResource without contextName should concatenate prefix, environment and locationShortName without separators" {

            $result = Invoke-BicepExpression -BicepImports $script:namingImports `
                -Expression "storageAccountResource(newCoreParams('ukwest', 'ukw', 'dev', 'myproject'), null)"

            $result | Should -Be "'stmyprojectdevukw'"
        }

        It "storageAccountResource with contextName should insert contextName between projectPrefix and environment" {

            $result = Invoke-BicepExpression -BicepImports $script:namingImports `
                -Expression "storageAccountResource(newCoreParams('ukwest', 'ukw', 'dev', 'myproject'), 'blob')"

            $result | Should -Be "'stmyprojectblobdevukw'"
        }
    }

    Context "Error handling" {

        It "should throw when the Bicep expression contains an error" {

            { Invoke-BicepExpression -Expression "undeclaredFunction()" } | Should -Throw "*Bicep console error*"
        }
    }
}