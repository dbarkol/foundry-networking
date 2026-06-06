// Ubuntu 22.04 LTS test VM in the workload subnet with no public IP.
// Has a system-assigned managed identity, the Azure Monitor Linux Agent
// extension, a Data Collection Rule Association to the syslog DCR, and a
// cloud-init payload that pre-installs the tools needed for testing
// (az CLI, curl, jq, dnsutils).

@description('Azure region for the VM.')
param location string

@description('Base name used to derive child resource names.')
param namePrefix string

@description('Tags applied to all resources.')
param tags object = {}

@description('Resource id of the workload subnet.')
param workloadSubnetId string

@description('Resource id of the DCR to associate with the VM.')
param dcrId string

@description('VM size.')
param vmSize string = 'Standard_B2ms'

@description('Admin username for the VM.')
param adminUsername string

@description('SSH public key for the admin user.')
@secure()
param sshPublicKey string

var vmName = '${namePrefix}-vm'
var nicName = '${namePrefix}-vm-nic'

var cloudInit = '''
#cloud-config
package_update: true
package_upgrade: false
packages:
  - curl
  - jq
  - dnsutils
runcmd:
  - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
'''

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: workloadSubnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.29'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {}
  }
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  scope: vm
  name: 'vm-dcr-association'
  properties: {
    dataCollectionRuleId: dcrId
    description: 'Associate syslog DCR with the test VM.'
  }
  dependsOn: [ amaExtension ]
}

output vmId string = vm.id
output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
