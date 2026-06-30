// core.bicep — Module 1: Shared resource deployments within the resource group
// Called as a module from main.bicep (targetScope = resourceGroup).

targetScope = 'resourceGroup'

param location string
param redisName string
param storageAccountName string
param apimName string
param apimPublisherEmail string
param apimPublisherName string
param identityName string
param keyVaultName string
param acrName string
param aoaiEndpoint string
param tenantId string
param apimAudience string

// ── User-Assigned Managed Identity ──────────────────────────────────────────
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// ── Azure Managed Redis (Balanced B0) ───────────────────────────────────────
resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: redisName
  location: location
  sku: {
    name: 'Balanced_B0'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource redisDefaultDb 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: redis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'OSSCluster'
    evictionPolicy: 'AllKeysLRU'

    publicNetworkAccess: 'Enabled'
  }
}

// ── Azure Blob Storage (Cool tier, versioning enabled) ───────────────────────
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Cool'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
  }
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'agent-state'
  properties: {
    publicAccess: 'None'
  }
}

// ── Azure API Management (Consumption SKU) ──────────────────────────────────
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: 'Consumption'
    capacity: 0
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
    }
  }
}

// ── APIM Backend — Azure OpenAI ──────────────────────────────────────────────
resource aoaiBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'azure-openai'
  properties: {
    description: 'Azure OpenAI LLM backend'
    url: aoaiEndpoint
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ── Azure Key Vault (RBAC-enabled) ───────────────────────────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
  }
}

// ── Azure Container Registry ─────────────────────────────────────────────────
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output redisHostName string = redis.properties.hostName
output storageAccountName string = storage.name
output apimServiceUrl string = 'https://${apim.properties.gatewayUrl}'
output identityClientId string = identity.properties.clientId
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
