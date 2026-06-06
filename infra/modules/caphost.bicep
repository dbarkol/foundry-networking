// Capability hosts for Foundry Agents — Standard Setup, network-secured.
//
// Two resources, in order:
//   1. Account-level capability host (`caphostacct`). Bootstraps the
//      account's agent runtime against the delegated agent subnet. Required
//      before the project-level caphost can be created.
//   2. Project-level capability host (`caphostproj`). Binds the project's
//      Cosmos / Storage / Search connections to the agent runtime.
//
// After this module runs, the agent runtime provisions its databases,
// containers, and indexes — so additional post-caphost RBAC is needed on
// the Storage account containers and the Cosmos `enterprise_memory`
// database (handled here as well).
//
// NOTE: RBAC propagation is asynchronous. If the project caphost fails
// with a 403 / "not authorized" error on first run, simply re-deploy
// 60-120 seconds later — Bicep is idempotent.

@description('Foundry account name.')
param accountName string

@description('Foundry project name.')
param projectName string

@description('Agent-delegated subnet ARM resource ID.')
param agentSubnetId string

@description('Cosmos DB account name (in this RG).')
param cosmosDBName string

@description('Storage account name (in this RG).')
param storageName string

@description('Cosmos connection name on the project (must match the connection resource).')
param cosmosConnectionName string

@description('Storage connection name on the project (must match the connection resource).')
param storageConnectionName string

@description('Search connection name on the project (must match the connection resource).')
param searchConnectionName string

@description('Foundry project system-assigned identity principal id.')
param projectPrincipalId string

@description('Foundry project internal workspace id (GUID form, no dashes; used to scope post-caphost RBAC).')
param projectWorkspaceId string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: cosmosDBName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

// -------- Account-level capability host --------

resource accountCapHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview' = {
  parent: account
  name: 'caphostacct'
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    #disable-next-line BCP037
    customerSubnet: agentSubnetId
  }
}

// -------- Project-level capability host --------

resource projectCapHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  parent: project
  name: 'caphostproj'
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    vectorStoreConnections:   [ searchConnectionName ]
    storageConnections:       [ storageConnectionName ]
    threadStorageConnections: [ cosmosConnectionName ]
  }
  dependsOn: [ accountCapHost ]
}

// -------- Post-caphost RBAC --------

// Workspace ID, dashes stripped, formatted as GUID for the storage condition
// expression. (The canonical sample uses a small helper module; we inline
// the transform with replace().)
var workspaceIdGuid = replace(projectWorkspaceId, '-', '')

// Storage Blob Data Owner (scoped via ABAC to per-project agent containers).
// Built-in role id b7e6dc6d-f1e8-4753-8033-0f276bb0955b.
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageContainerCondition = '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read\'})  AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action\'}) AND  !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write\'}) ) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${workspaceIdGuid}\' AND @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringLikeIgnoreCase \'*-azureml-agent\'))'

resource storageBlobOwnerRA 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, projectPrincipalId, storageBlobDataOwner, 'caphost')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwner)
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    conditionVersion: '2.0'
    condition: storageContainerCondition
  }
  dependsOn: [ projectCapHost ]
}

// Cosmos SQL Built-In Data Contributor on the enterprise_memory database.
// (The caphost creates that database the first time it runs.)
resource cosmosDataContribRA 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2022-05-15' = {
  parent: cosmos
  name: guid(projectWorkspaceId, cosmosDBName, projectPrincipalId, '00000000-0000-0000-0000-000000000002')
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: resourceId(
      'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions',
      cosmosDBName,
      '00000000-0000-0000-0000-000000000002'
    )
    scope: '${cosmos.id}/dbs/enterprise_memory'
  }
  dependsOn: [ projectCapHost ]
}

output accountCapHostName string = accountCapHost.name
output projectCapHostName string = projectCapHost.name
