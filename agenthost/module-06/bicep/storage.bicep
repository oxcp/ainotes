// Module-06 owns only data; existing declarations do not redeploy the account or its Blob service.
@description('Existing Module-01 storage account in the deployment resource group. Never redeployed by this template.')
param storageAccountName string

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' existing = {
  parent: storage
  name: 'default'
}

resource dataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'data'
  properties: {
    // Disable anonymous Blob access, not authenticated SDK access or the account's public endpoint.
    // Account networking, private connectivity and identity RBAC remain managed outside this template.
    publicAccess: 'None'
  }
}

// ACA AzureBlobByo volumes require this ARM ID, whereas application SDKs use the account HTTPS URL.
output containerId string = dataContainer.id
