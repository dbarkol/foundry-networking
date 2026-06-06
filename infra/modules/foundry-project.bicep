// Foundry project (sub-resource of the AIServices account). This gives the
// Foundry Portal a non-empty "Projects" list, unlocks the
// azure-ai-projects SDK, and is the slot that BYO data connections and a
// capability host attach to.
//
// When the BYO trio (Cosmos / Storage / Search) names are provided, this
// module also creates the three AAD project connections the agent
// capability host will later bind to.

@description('Azure region for the project (must match the parent account).')
param location string

@description('Name of the parent Foundry / AIServices account.')
param accountName string

@description('Base name used to derive the project name.')
param namePrefix string

@description('Tags applied to the project.')
param tags object = {}

@description('Optional. Cosmos DB account name to wire as a project connection.')
param cosmosDBName string = ''

@description('Optional. Storage account name to wire as a project connection.')
param storageName string = ''

@description('Optional. AI Search service name to wire as a project connection.')
param searchName string = ''

@description('Optional. Application Insights resource name to wire as a project connection (enables Foundry agent tracing).')
param appInsightsName string = ''

var projectName = '${namePrefix}-proj'
var hasCosmos = !empty(cosmosDBName)
var hasStorage = !empty(storageName)
var hasSearch = !empty(searchName)
var hasAppInsights = !empty(appInsightsName)

// Connection names — these are the strings the project capability host
// references in its vectorStoreConnections / storageConnections /
// threadStorageConnections arrays. Must match exactly.
var cosmosConnectionName = hasCosmos ? '${cosmosDBName}-connection' : ''
var storageConnectionName = hasStorage ? '${storageName}-connection' : ''
var searchConnectionName = hasSearch ? '${searchName}-connection' : ''
var appInsightsConnectionName = hasAppInsights ? '${appInsightsName}-connection' : ''

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (hasCosmos) {
  name: cosmosDBName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (hasStorage) {
  name: storageName
}

resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (hasSearch) {
  name: searchName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = if (hasAppInsights) {
  name: appInsightsName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    description: 'AMPLS + Foundry private demo project'
    displayName: 'AMPLS Private Demo'
  }
}

resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (hasCosmos) {
  parent: project
  name: cosmosConnectionName
  properties: {
    category: 'CosmosDB'
    #disable-next-line BCP318
    target: cosmosDB.properties.documentEndpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      #disable-next-line BCP318
      ResourceId: cosmosDB.id
      #disable-next-line BCP318
      location: cosmosDB.location
    }
  }
}

resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (hasStorage) {
  parent: project
  name: storageConnectionName
  properties: {
    category: 'AzureStorageAccount'
    #disable-next-line BCP318
    target: storageAccount.properties.primaryEndpoints.blob
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      #disable-next-line BCP318
      ResourceId: storageAccount.id
      #disable-next-line BCP318
      location: storageAccount.location
    }
  }
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (hasSearch) {
  parent: project
  name: searchConnectionName
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${searchName}.search.windows.net'
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      #disable-next-line BCP318
      ResourceId: searchService.id
      #disable-next-line BCP318
      location: searchService.location
    }
  }
}

resource appInsightsConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (hasAppInsights) {
  parent: project
  name: appInsightsConnectionName
  properties: {
    category: 'AppInsights'
    #disable-next-line BCP318
    target: appInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      #disable-next-line BCP318
      key: appInsights.properties.ConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      #disable-next-line BCP318
      ResourceId: appInsights.id
    }
  }
}

output projectId string = project.id
output projectName string = project.name
output projectPrincipalId string = project.identity.principalId
// Foundry project endpoint of the form
// https://<account-subdomain>.services.ai.azure.com/api/projects/<project>
output projectEndpoint string = '${account.properties.endpoint}api/projects/${project.name}'
#disable-next-line BCP053
output projectWorkspaceId string = project.properties.internalId
output cosmosConnectionName string = cosmosConnectionName
output storageConnectionName string = storageConnectionName
output searchConnectionName string = searchConnectionName
output appInsightsConnectionName string = appInsightsConnectionName
