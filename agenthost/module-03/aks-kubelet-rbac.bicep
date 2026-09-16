targetScope = 'resourceGroup'

@description('Existing Azure Container Registry name')
param acrName string

@description('Existing Storage account name')
param storageAccountName string

@description('AKS kubelet managed identity object ID')
param kubeletPrincipalId string

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, kubeletPrincipalId, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: kubeletPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource storageBlobCsiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, kubeletPrincipalId, storageBlobDataContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: kubeletPrincipalId
    principalType: 'ServicePrincipal'
  }
}