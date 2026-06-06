// Private endpoints + private DNS zones for the three BYO Foundry agent
// backing services (Cosmos NoSQL, Storage blob, Azure AI Search). Each PE
// is attached in the private-endpoints subnet and bound to a workload
// private DNS zone linked to the VNet.

@description('Azure region for the private endpoints.')
param location string

@description('Base name used to derive PE / DNS resource names.')
param namePrefix string

@description('Tags applied to all created resources.')
param tags object = {}

@description('Resource ID of the VNet hosting the DNS zone links.')
param vnetId string

@description('Resource ID of the subnet that will host the private endpoints.')
param privateEndpointsSubnetId string

@description('Cosmos DB account name (existing in this RG).')
param cosmosDBName string

@description('Storage account name (existing in this RG).')
param storageName string

@description('AI Search service name (existing in this RG). Empty string to skip Search PE/DNS.')
param searchName string = ''

var hasSearch = !empty(searchName)

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosDBName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (hasSearch) {
  name: searchName
}

// -------- DNS Zones --------

resource cosmosDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.documents.azure.com'
  location: 'global'
  tags: tags
}

// blob DNS zone + vnet link are already created by ampls-private-endpoint.bicep.
// We reuse the existing zone for the storage PE.
resource blobDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
}

resource searchDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (hasSearch) {
  name: 'privatelink.search.windows.net'
  location: 'global'
  tags: tags
}

// -------- VNet Links --------

resource cosmosVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: cosmosDnsZone
  name: '${namePrefix}-cosmos-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

// (blob VNet link is owned by ampls-private-endpoint.bicep)

resource searchVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (hasSearch) {
  parent: searchDnsZone
  name: '${namePrefix}-search-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

// -------- Private Endpoints --------

resource cosmosPe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${cosmosDBName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointsSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${cosmosDBName}-plsc'
        properties: {
          privateLinkServiceId: cosmos.id
          groupIds: [ 'Sql' ]
        }
      }
    ]
  }
}

resource storagePe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${storageName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointsSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${storageName}-plsc'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

resource searchPe 'Microsoft.Network/privateEndpoints@2023-11-01' = if (hasSearch) {
  name: '${searchName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointsSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${searchName}-plsc'
        properties: {
          #disable-next-line BCP318
          privateLinkServiceId: search.id
          groupIds: [ 'searchService' ]
        }
      }
    ]
  }
}

// -------- DNS Zone Groups --------

resource cosmosDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: cosmosPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'cosmos-config', properties: { privateDnsZoneId: cosmosDnsZone.id } }
    ]
  }
  dependsOn: [ cosmosVnetLink ]
}

resource storageDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: storagePe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob-config', properties: { privateDnsZoneId: blobDnsZone.id } }
    ]
  }
}

resource searchDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (hasSearch) {
  parent: searchPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      #disable-next-line BCP318
      { name: 'search-config', properties: { privateDnsZoneId: searchDnsZone.id } }
    ]
  }
  dependsOn: [ searchVnetLink ]
}

output cosmosPeName string = cosmosPe.name
output storagePeName string = storagePe.name
#disable-next-line BCP318
output searchPeName string = hasSearch ? searchPe.name : ''
