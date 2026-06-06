// Pre-capability-host RBAC: assigns the Foundry project's system-assigned
// identity the roles it needs on the BYO backing services so that when
// the capability host is later created it can provision its databases,
// containers, and indexes.
//
// Idempotent and safe to deploy before the caphost exists — these are
// just role assignments that mean nothing without the caphost.

@description('Foundry project system-assigned identity principal id.')
param projectPrincipalId string

@description('Cosmos DB account name (in this resource group).')
param cosmosDBName string

@description('Storage account name (in this resource group).')
param storageName string

@description('AI Search service name (in this resource group). Empty string to skip Search role assignments.')
param searchName string = ''

var hasSearch = !empty(searchName)

// Built-in role definition IDs
var cosmosDBOperator             = '230815da-be43-4aae-9cb4-875f7bd000aa'
var storageBlobDataContributor   = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var searchIndexDataContributor   = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var searchServiceContributor     = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosDBName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (hasSearch) {
  name: searchName
}

resource cosmosOperatorRA 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cosmos
  name: guid(cosmos.id, projectPrincipalId, cosmosDBOperator)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cosmosDBOperator)
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource storageContribRA 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, projectPrincipalId, storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource searchIndexRA 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasSearch) {
  scope: search
  #disable-next-line BCP318
  name: guid(search.id, projectPrincipalId, searchIndexDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributor)
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource searchServiceRA 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasSearch) {
  scope: search
  #disable-next-line BCP318
  name: guid(search.id, projectPrincipalId, searchServiceContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributor)
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
  }
}
