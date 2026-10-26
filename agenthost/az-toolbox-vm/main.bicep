targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('VM name. Use a valid Linux hostname.')
@minLength(1)
@maxLength(64)
param vmName string = 'azure-toolbox-vm'

@description('Linux administrator username.')
@minLength(1)
@maxLength(32)
param adminUsername string = 'azureuser'

@description('An x64, generation 2 compatible VM size available in the selected region.')
param vmSize string = 'Standard_D4s_v5'

@description('Create and attach a Standard static public IPv4 address.')
param createPublicIp bool = true

@description('Administrator authentication method. SSH public key authentication is recommended.')
@allowed([
  'sshPublicKey'
  'password'
])
param authenticationType string = 'sshPublicKey'

@description('Required when authenticationType is sshPublicKey; otherwise leave empty. Never supply a private key.')
param sshPublicKey string = ''

@secure()
@maxLength(72)
@description('Required when authenticationType is password; otherwise leave empty. Use 12-72 characters with at least three of: uppercase, lowercase, digits, and special characters. Never reuse an existing password.')
param adminPassword string = ''

@description('Create a new VNet/subnet or attach to an existing subnet without modifying its network configuration.')
@allowed([
  'new'
  'existing'
])
param networkMode string = 'new'

@description('Required for networkMode=existing. Full resource ID of an existing subnet in the same subscription and region as the VM.')
param existingSubnetResourceId string = ''

@description('Name for a new VNet. Keep a nonempty value even in existing mode because ARM validates conditional resource dependency IDs.')
@minLength(1)
param vnetName string = 'vnet-toolbox'
param vnetAddressPrefix string = '10.10.0.0/16'
@minLength(1)
param subnetName string = 'default'
param subnetAddressPrefix string = '10.10.0.0/24'

@description('For new networks only: trusted SSH source IP/CIDR or service tag. Restrict * before deploying a public VM. Existing subnet rules are not changed.')
param sshAllowedSource string = createPublicIp ? '*' : 'VirtualNetwork'

@description('For new networks only: optional existing NAT gateway resource ID for explicit outbound access. Must be compatible with this subnet and region. Existing subnet NAT configuration is not changed.')
param existingNatGatewayResourceId string = ''

// Encode user data rather than interpolating it into YAML or shell source.
var cloudInit = replace(
  replace(
    replace(loadTextContent('./cloud-init.yaml'), '__ADMIN_USER_BASE64__', base64(adminUsername)),
    '__VERIFY_TOOLS_BASE64__',
    base64(loadTextContent('./scripts/verify-tools.sh'))
  ),
  '__SSH_PASSWORD_AUTHENTICATION__',
  authenticationType == 'password' ? 'true' : 'false'
)

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (networkMode == 'new') {
  name: '${vmName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: sshAllowedSource
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOtherInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = if (networkMode == 'new') {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg!.id
          }
          // Private-only labs opt in to default egress unless an existing NAT gateway is supplied.
          defaultOutboundAccess: !createPublicIp && empty(existingNatGatewayResourceId)
          natGateway: empty(existingNatGatewayResourceId) ? null : {
            id: existingNatGatewayResourceId
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (createPublicIp) {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: networkMode == 'existing' ? existingSubnetResourceId : '${vnet!.id}/subnets/${subnetName}'
          }
          publicIPAddress: createPublicIp ? {
            id: publicIp!.id
          } : null
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: authenticationType == 'password' ? adminPassword : null
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: authenticationType != 'password'
        provisionVMAgent: true
        ssh: authenticationType == 'sshPublicKey' ? {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        } : null
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmResourceId string = vm.id
output vmName string = vm.name
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output publicIpAddress string = createPublicIp ? publicIp!.properties.ipAddress : ''
output adminUsername string = adminUsername
