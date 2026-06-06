// Storage account used as the BYO blob store for Foundry Agents. Public
// network access disabled, shared-key auth disabled — Foundry / agents
// connect via AAD only. Foundry's capability host provisions the
// per-project blob containers (files + intermediate) at runtime.
//
// Regions that don't support ZRS get GRS as a fallback (matches MS sample).

@description('Azure region for the storage account.')
param location string

@description('Storage account name. 3-24 chars, lowercase letters and numbers only.')
param storageName string

@description('Tags applied to the storage account.')
param tags object = {}

var noZRSRegions = [ 'southindia', 'westus' ]
var sku = contains(noZRSRegions, location) ? { name: 'Standard_GRS' } : { name: 'Standard_ZRS' }

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: sku
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

output storageId string = storage.id
output storageName string = storage.name
output blobEndpoint string = storage.properties.primaryEndpoints.blob
