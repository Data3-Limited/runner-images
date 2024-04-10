// Default Parameters
@description('Location for all resources.')
param location string = resourceGroup().location

@description('Random GUID used to force the deployment script to run again.')
param randomGuid string = newGuid()

@description('Region for all resources.')
param region string = location == 'australiaeast' ? 'aue' : 'ase'

// DevOps Agent Authentication
@description('Type of authentication to use on the Virtual Machine. SSH key is recommended.')
@allowed(['sshPublicKey', 'password'])
param authenticationType string = 'sshPublicKey'

@description('Username for the Virtual Machine. This is the username that will be used to login to the Virtual Machine.')
param adminUsername string

@minLength(10)
@maxLength(64)
@description('Passphrase used when generating the key pair.')
param passPhrase string = substring(randomGuid, 0, 64)

@description('Generate a new SSH key pair for the Virtual Machine. If set to false, the SSH Public Key will be retrieved from the SSH Key Resource.')
param generateNewKey bool = true

// DevOps Agent Image
@description('Name of the image to use for the Virtual Machine. Name comes from image generation pipeline.')
param imageName string

@description('Number of agent vms to create in scale set.')
param agentCount int = 4

// Varibles
var vmssAgentSettings = loadYamlContent('../library/vmssAgentSettings.yaml')
var prefix = vmssAgentSettings.prefix
var resSuffix = vmssAgentSettings.resSuffix
var vmssName = vmssAgentSettings.vmssSuffix
var uniqueSuffix = substring(uniqueString(location, resourceGroup().id), 0, 5)

// Common Resource Names
var keyVaultName = format('{0}-{1}-kv-{2}', prefix, region, uniqueSuffix)
var managedIdentityName = format('{0}-{1}-mi-{2}', prefix, region, resSuffix)
var networkSecurityGroupName = format('{0}-{1}-ns-{2}', prefix, region, resSuffix)
var virtualNetworkName = format('{0}-{1}-vn-{2}', prefix, region, resSuffix)

// VMSS Resource Names
var networkInterfaceName = format('{0}-{1}-ni-{2}', prefix, region, vmssName)
var publicIpAddressName = format('{0}-{1}-pi-{2}', prefix, region, vmssName)
var vmScaleSetName = format('{0}-{1}-vs-{2}', prefix, region, vmssName)

// Authentication Configuration
var linuxConfiguration = {
  disablePasswordAuthentication: true
  ssh: {
    publicKeys: [
      {
        path: '/home/${adminUsername}/.ssh/authorized_keys'
        keyData: generateNewKey ? rDeploymentScript.properties.outputs.keyinfo.publicKey : rSshPublicKeys.properties.publicKey
      }
    ]
  }
}

// Get Resources
resource rImage 'Microsoft.Compute/images@2023-09-01' existing = {
  name: imageName
  scope: resourceGroup(vmssAgentSettings.imageResourceGroupName)
}

// Resources
resource rManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
}

resource rKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
    publicNetworkAccess: 'Disabled'
    sku: {
      family: 'A'
      name: 'premium'
    }
    tenantId: tenant().tenantId
  }
}

// Key Vault Role Assignments
resource rKeyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(location, resourceGroup().id, keyVaultName, 'Microsoft.Authorization/roleAssignments', managedIdentityName)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7') // Key Vault Secrets Officer
    principalId: rManagedIdentity.properties.principalId
  }
}

resource rRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(location, resourceGroup().id, 'Microsoft.Authorization/roleAssignments', managedIdentityName)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
    principalId: rManagedIdentity.properties.principalId
  }
}

resource rDeploymentScript 'Microsoft.Resources/deploymentScripts@2020-10-01' = if (generateNewKey) {
  name: 'genSshKeys'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${rManagedIdentity.id}': {}
    }
  }
  properties: {
    forceUpdateTag: randomGuid
    azCliVersion: '2.58.0'
    timeout: 'PT30M'
    retentionInterval: 'P1D'
    cleanupPreference: 'OnSuccess'
    arguments: passPhrase
    scriptContent: loadTextContent('./new-key.sh')
  }
}

resource rKeyVaultSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (generateNewKey) {
  name: 'sshPrivateKey'
  parent: rKeyVault
  properties: {
    value: rDeploymentScript.properties.outputs.keyinfo.privateKey
  }
}

resource rSshPublicKeys 'Microsoft.Compute/sshPublicKeys@2023-03-01' = if (!generateNewKey) {
  name: 'sshPublicKey'
  location: location
  properties: {
    publicKey: rDeploymentScript.properties.outputs.keyinfo.publicKey
  }
}

resource rNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: []
  }
}

resource rPublicIpAddress 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: publicIpAddressName
  location: location
  sku: {
    name: 'Basic'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    ipTags: []
  }
}

resource rVirtualNetwork 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/20'
      ]
    }
    subnets: [
      {
        name: 'DevOpsAgents'
        properties: {
          addressPrefix: '10.0.0.0/24'
          delegations: []
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          networkSecurityGroup: {
            id: rNetworkSecurityGroup.id
          }
        }
        type: 'Microsoft.Network/virtualNetworks/subnets'
      }
    ]
    virtualNetworkPeerings: []
    enableDdosProtection: false
  }
}

resource rSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-04-01' existing = {
  parent: rVirtualNetwork
  name: 'DevOpsAgents'
}

resource rVMScaleSet 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: vmScaleSetName
  location: location
  sku: {
    capacity: agentCount
    name: 'Standard_DS2_v2'
    tier: 'Standard'
  }
  properties: {
    overprovision: false
    upgradePolicy: {
      mode: 'Manual'
    }
    virtualMachineProfile: {
      storageProfile: {
        imageReference: {
          id: rImage.id
        }
        osDisk: {
          osType: 'Linux'
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
          diskSizeGB: 75
        }
        dataDisks: []
      }
      osProfile: {
        computerNamePrefix: vmScaleSetName
        adminUsername: adminUsername
        adminPassword: rSshPublicKeys.properties.publicKey
        linuxConfiguration: ((authenticationType == 'password') ? null : linuxConfiguration)
        secrets: []
        allowExtensionOperations: true
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: networkInterfaceName
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'internal'
                  properties: {
                    subnet: {
                      id: rSubnet.id
                    }
                    primary: true
                    privateIPAddressVersion: 'IPv4'
                  }
                }
              ]
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: false
        }
      }
    }
  }
}

resource rNetworkInterface 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        type: 'Microsoft.Network/networkInterfaces/ipConfigurations'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: rPublicIpAddress.id
          }
          subnet: {
            id: rSubnet.id
          }
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    dnsSettings: {
      dnsServers: []
    }
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    disableTcpStateTracking: false
    nicType: 'Standard'
    auxiliaryMode: 'None'
    auxiliarySku: 'None'
  }
}
