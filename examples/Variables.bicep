/**********************************
  Bicep Template: Shared Variables
  Author: Andrew Wilson
***********************************/

@export()
@description('Shared Variable for environment configurations')
var environmentConfig = {
  dev: {
    sku: 'Basic'
  }
  staging: {
    sku: 'Standard'
  }
  prod: {
    sku: 'Premium'
  }
}

@export()
@description('Shared Variable for tagging resources')
var mandatoryTags = {
  costCenter: 'IT-001'
  dataClassification: 'internal'
  businessUnit: 'engineering'
  version: deployment().properties.template.contentVersion
}

@export()
@description('Shared Variable for resource configuration')
var subnetConfigurations = [
  {
    name: 'web-subnet'
    addressPrefix: '10.0.1.0/24'
    serviceEndpoints: ['Microsoft.Storage', 'Microsoft.KeyVault']
  }
  {
    name: 'api-subnet'
    addressPrefix: '10.0.2.0/24'
    serviceEndpoints: ['Microsoft.Sql', 'Microsoft.KeyVault']
  }
]

@export()
@description('Shared Variable for Key Vault Secrets User Role Definition ID')
var keyVaultSecretsUserRoleDefId = '4633458b-17de-408a-b874-0445c86b69e6'
