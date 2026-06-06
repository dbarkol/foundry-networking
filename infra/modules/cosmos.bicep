// Cosmos DB NoSQL account used as the BYO thread store for Foundry Agents.
// Public access disabled — reachable only through a private endpoint (see
// backing-private-endpoints.bicep). Local (key) auth disabled — Foundry
// connects via AAD.
//
// The Foundry project capability host creates the `enterprise_memory`
// database and per-project containers at runtime.

@description('Azure region for the account.')
param location string

@description('Cosmos DB account name. 3-44 chars, lowercase letters/numbers/hyphens.')
param cosmosDBName string

@description('Tags applied to the account.')
param tags object = {}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosDBName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    publicNetworkAccess: 'Disabled'
    enableFreeTier: false
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
  }
}

output cosmosDBId string = cosmosDB.id
output cosmosDBName string = cosmosDB.name
output documentEndpoint string = cosmosDB.properties.documentEndpoint
