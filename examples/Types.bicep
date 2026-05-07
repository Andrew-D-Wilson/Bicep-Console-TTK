/**********************************
  Bicep Template: Shared Types
  Author: Andrew Wilson
***********************************/

// ** User Defined Types and Constructors **
// *****************************************

// TYPE: Core Parameters
// *********************

@export()
@description('Core Parameters Definition for Bicep Templates')
@sealed()
type coreParams = {
  @description('Location to deploy resources to')
  location: string
  @description('Location Short Name for resource naming')
  locationShortName: string
  @description('Environment to deploy to')
  environment: string
  @description('Project Prefix for resource naming')
  projectPrefix: string
}

@export()
@description('Core Parameters Constructor')
func newCoreParams(
  location string,
  locationShortName string,
  environment string,
  projectPrefix string
) coreParams => {
  location: location
  locationShortName: locationShortName
  environment: environment
  projectPrefix: projectPrefix
}
