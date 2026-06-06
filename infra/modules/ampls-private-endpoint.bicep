// Private endpoint to the AMPLS (groupId: azuremonitor) + the 5 required
// Azure Monitor private DNS zones, linked to the VNet, with a single DNS
// zone group on the PE that registers records in all 5 zones.

@description('Azure region for the private endpoint and VNet links.')
param location string

@description('Base name used to derive child resource names.')
param namePrefix string

@description('Tags applied to all resources.')
param tags object = {}

@description('Resource id of the AMPLS to connect to.')
param amplsId string

@description('Resource id of the private-endpoints subnet.')
param privateEndpointsSubnetId string

@description('Resource id of the VNet to link the private DNS zones to.')
param vnetId string

var peName = '${namePrefix}-ampls-pe'

var monitorZones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in monitorZones: {
  name: zone
  location: 'global'
  tags: tags
}]

resource vnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in monitorZones: {
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
        name: 'ampls-connection'
        properties: {
          privateLinkServiceId: amplsId
          groupIds: [ 'azuremonitor' ]
        }
      }
    ]
  }
}

resource peDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zone, i) in monitorZones: {
      name: replace(zone, '.', '-')
      properties: {
        privateDnsZoneId: zones[i].id
      }
    }]
  }
}

output privateEndpointId string = pe.id
output privateEndpointName string = pe.name
