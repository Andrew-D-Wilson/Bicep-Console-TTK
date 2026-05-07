/*******************************************
  Bicep Template: Name Constructor Functions
  Author: Andrew Wilson
*******************************************/

// ** Shared Imports **
// ********************

import { coreParams } from './types.bicep'

// Resource Name Constructors
//***************************

// Basic
@export()
@description('Generates a resource name based on the provided parameters (used for common usage resources)')
func basicResource(resourceAbbreviation string, coreParameters coreParams) string =>
  '${resourceAbbreviation}-${coreParameters.projectPrefix}-${coreParameters.environment}-${coreParameters.location}'

@export()
@description('Generates a resource name based on the provided parameters but ignoring the location (used for common usage resources that are not location specific)')
func unlocalisedBasicResource(resourceAbbreviation string, coreParameters coreParams) string =>
  '${resourceAbbreviation}-${coreParameters.projectPrefix}-${coreParameters.environment}'

// Context Specific
@export()
@description('Generates a Context Specific Resource Name based on the provided parameters')
func csResource(resourceAbbreviation string, coreParameters coreParams, contextName string) string =>
  '${resourceAbbreviation}-${coreParameters.projectPrefix}-${contextName}-${coreParameters.environment}-${coreParameters.location}'

// Resource Group
@export()
@description('Generates a Resource Group name based on the provided parameters')
func resourceGroup(contextName string, coreParameters coreParams) string =>
  'rg-${coreParameters.projectPrefix}-${contextName}-${coreParameters.environment}-${coreParameters.location}'

@export()
@description('Generates a Resource Group name based on the provided parameters but without an env specified')
func resourceGroupNonEnvSpecific(contextName string, coreParameters coreParams) string =>
  'rg-${coreParameters.projectPrefix}-${contextName}-${coreParameters.location}-shared'

// Storage Account
@export()
@description('Generates a Storage Account Resource Name based on the provided parameters')
func storageAccountResource(coreParameters coreParams, contextName string?) string =>
  empty(contextName)
    ? 'st${coreParameters.projectPrefix}${coreParameters.environment}${coreParameters.locationShortName}'
    : 'st${coreParameters.projectPrefix}${contextName}${coreParameters.environment}${coreParameters.locationShortName}'
