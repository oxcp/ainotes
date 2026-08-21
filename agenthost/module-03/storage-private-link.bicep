// storage-private-link.bicep — optional post-AKS Blob Private Link deployment
//
// deploy-storage-private-link.sh creates the dedicated subnet in the
// AKS-managed VNet first. This template then runs only at the workshop resource
// group scope and creates the Private Endpoint and Private DNS resources.

targetScope = 'resourceGroup'

@description('Resource ID of the AKS-managed VNet')
param vnetId string

@description('Resource ID of the dedicated Private Endpoint subnet')
param privateEndpointSubnetId string

@description('Existing Storage account name')
param storageAccountName string

@description('Name of the Blob Private Endpoint')
param privateEndpointName string = 'pe-${storageAccountName}-blob'

@description('Blob Private DNS zone name')
param privateDnsZoneName string = 'privatelink.blob.${environment().suffixes.storage}'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'link-${last(split(vnetId, '/'))}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: resourceGroup().location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-connection'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'blob'
          ]
          requestMessage: 'Private access from the AKS agent workload to Blob storage'
        }
      }
    ]
  }
}

resource blobPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output privateEndpointId string = blobPrivateEndpoint.id
output privateDnsZoneId string = privateDnsZone.id
