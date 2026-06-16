targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Prefix used for generated resource names')
@minLength(3)
@maxLength(18)
param namePrefix string

@description('Redis SKU family (C = Basic/Standard)')
@allowed([
  'C'
])
param redisSkuFamily string = 'C'

@description('Redis SKU capacity for Basic')
@allowed([
  0
])
param redisSkuCapacity int = 0

var redisName = toLower('${namePrefix}-amr')
var storageName = toLower('${replace(namePrefix, '-', '')}state${uniqueString(resourceGroup().id)}')

resource redis 'Microsoft.Cache/Redis@2024-03-01' = {
  name: redisName
  location: location
  properties: {
    sku: {
      name: 'Basic'
      family: redisSkuFamily
      capacity: redisSkuCapacity
    }
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    redisConfiguration: {
      'maxmemory-policy': 'allkeys-lru'
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'openclaw-state'
  properties: {
    publicAccess: 'None'
  }
}

output redisHostName string = redis.properties.hostName
output storageAccountName string = storage.name
output stateContainerName string = stateContainer.name
