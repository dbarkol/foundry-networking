// Azure Bastion (Standard SKU) + Standard public IP in the AzureBastionSubnet.
// Standard SKU is required for native client tunneling (SOCKS5 over `az network
// bastion tunnel`) which the AMPLS-locked VNet setup depends on for browser
// access to the private Foundry portal. See Bastion-VM-Access.md.
// Used to reach the test VM securely without giving the VM a public IP.

@description('Azure region for Bastion.')
param location string

@description('Base name used to derive child resource names.')
param namePrefix string

@description('Tags applied to all resources.')
param tags object = {}

@description('Resource id of the AzureBastionSubnet.')
param bastionSubnetId string

var bastionName = '${namePrefix}-bastion'
var publicIpName = '${namePrefix}-bastion-pip'

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: bastionName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: { id: bastionSubnetId }
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
output bastionName string = bastion.name
