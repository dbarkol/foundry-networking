// VNet with three subnets: workload, private-endpoints, AzureBastionSubnet.
// PE subnet has privateEndpointNetworkPolicies disabled so PEs can attach.
//
// A NAT Gateway is attached to the workload subnet to provide explicit
// outbound internet egress. This is required because Azure has retired
// "default outbound access" for new VNets — without an explicit egress
// (NAT GW, Load Balancer, or public IP on the NIC) the VM cannot reach the
// internet, which breaks cloud-init (apt + az CLI install) and the
// AzureMonitorLinuxAgent extension installation.

@description('Azure region for the VNet and subnets.')
param location string

@description('Base name used to derive child resource names.')
param namePrefix string

@description('Tags applied to all resources.')
param tags object = {}

var vnetName = '${namePrefix}-vnet'
var nsgName = '${namePrefix}-workload-nsg'
var natGatewayName = '${namePrefix}-nat'
var natPublicIpName = '${namePrefix}-nat-pip'

resource workloadNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: natPublicIpName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      { id: natPublicIp.id }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.20.0.0/16' ]
    }
    subnets: [
      {
        name: 'workload'
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: { id: workloadNsg.id }
          natGateway: { id: natGateway.id }
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.20.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.20.3.0/26'
        }
      }
      {
        // Delegated subnet for Foundry Agents (Standard Setup) network
        // injection. The capability host manages its own egress so this
        // subnet does NOT need a NAT Gateway. Must be /27 or larger and
        // delegated EXCLUSIVELY to Microsoft.App/environments.
        name: 'agent-subnet'
        properties: {
          addressPrefix: '10.20.4.0/24'
          delegations: [
            {
              name: 'Microsoft.app/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output workloadSubnetId string = '${vnet.id}/subnets/workload'
output privateEndpointsSubnetId string = '${vnet.id}/subnets/private-endpoints'
output bastionSubnetId string = '${vnet.id}/subnets/AzureBastionSubnet'
output agentSubnetId string = '${vnet.id}/subnets/agent-subnet'

