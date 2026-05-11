/*******************************************
  Bicep Template: Shared Functions
  Author: Andrew Wilson
*******************************************/

// Retrieve Application Insights Ingestion Endpoint
@export()
func GetAIIngestionURL(aiConnectionString string) string =>
  '${split(filter(split(aiConnectionString, ';'), val => startsWith(val, 'IngestionEndpoint='))[0], '=')[1]}v2/track'
