// Azure AI Search service used as the BYO vector store for Foundry Agents.
// Basic SKU (cheapest tier that supports private endpoints — Free does
// not). AAD-only data-plane auth (no API keys). Public network access
// disabled. System-assigned identity so the service can call Foundry /
// Storage for indexing if you later wire skillsets.

@description('Azure region for the Search service.')
param location string

@description('Search service name. 2-60 chars, lowercase letters/numbers/hyphens.')
param searchName string

@description('Search SKU. basic is the cheapest tier that supports PEs.')
@allowed([ 'basic', 'standard', 'standard2', 'standard3' ])
param sku string = 'basic'

@description('Tags applied to the Search service.')
param tags object = {}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: location
  tags: tags
  sku: { name: sku }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'disabled'
    semanticSearch: 'disabled'
    disableLocalAuth: false
    authOptions: {
      aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' }
    }
    encryptionWithCmk: { enforcement: 'Unspecified' }
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
}

output searchId string = search.id
output searchName string = search.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
