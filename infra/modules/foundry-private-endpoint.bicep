// Private endpoint to the Foundry / Cognitive Services account
// (groupId: account) + the 3 required private DNS zones, linked to the
// VNet, with a single DNS zone group on the PE.

@description('Azure region for the private endpoint and VNet links.')
param location string

@description('Base name used to derive child resource names.')
param namePrefix string

@description('Tags applied to all resources.')
param tags object = {}

@description('Resource id of the Foundry / Cognitive Services account.')
param foundryId string

@description('Resource id of the private-endpoints subnet.')
param privateEndpointsSubnetId string

@description('Resource id of the VNet to link the private DNS zones to.')
param vnetId string

var peName = '${namePrefix}-foundry-pe'

var foundryZones = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
]

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in foundryZones: {
  name: zone
  location: 'global'
  tags: tags
}]

resource vnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in foundryZones: {
  parent: zones[i]
  name: '${replace(zone, '.', '-')}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}]

resource pe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: peName
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointsSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'foundry-connection'
        properties: {
          privateLinkServiceId: foundryId
          groupIds: [ 'account' ]
        }
      }
    ]
  }
}

resource peDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zone, i) in foundryZones: {
      name: replace(zone, '.', '-')
      properties: {
        privateDnsZoneId: zones[i].id
      }
    }]
  }
}

output privateEndpointId string = pe.id
output privateEndpointName string = pe.name
