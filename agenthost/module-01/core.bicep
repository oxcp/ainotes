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
//param aoaiEndpoint string
param tenantId string
param apimAudience string

@description('Foundry (AIServices) resource name, already suffixed by main.bicep')
param foundryResourceName string

@description('Foundry project name')
param projectName string

@description('Default azd environment tag applied to the Foundry account')
param azdEnvName string

@description('Model deployment name to create in Foundry')
param modelDeploymentName string

@description('Model version to deploy')
param modelVersion string

// Cognitive Services OpenAI User — lets APIM's managed identity call Foundry
// inference when the account has disableLocalAuth = true (keys disabled).
var openAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var gatewayApiPath = 'foundry'

// API-scope policy: route to the Foundry backend and attach an Entra ID token
// obtained from APIM's user-assigned managed identity. When client-id is set
// and output-token-variable-name is omitted, the token is written to the
// Authorization header automatically.
var gatewayPolicyXml = '<policies><inbound><base /><set-backend-service backend-id="foundry-backend" /><authentication-managed-identity resource="https://cognitiveservices.azure.com" client-id="${identity.properties.clientId}" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

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
//resource aoaiBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
//  parent: apim
//  name: 'azure-openai'
//  properties: {
//    description: 'Azure OpenAI LLM backend'
//    url: aoaiEndpoint
//    protocol: 'http'
//    tls: {
//      validateCertificateChain: true
//      validateCertificateName: true
//    }
//  }
//}

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

// ── Foundry (AIServices) account ─────────────────────────────────────────────
resource foundryAccount 'Microsoft.CognitiveServices/accounts@2026-03-01' = {
  name: foundryResourceName
  location: location
  tags: {
    'azd-env-name': azdEnvName
  }
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    apiProperties: {}
    customSubDomainName: foundryResourceName
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
    allowProjectManagement: true
    defaultProject: projectName
    associatedProjects: [
      projectName
    ]
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

// ── APIM Backend — Foundry hosted-agent inference ────────────────────────────
// The gateway policy routes to this backend via <set-backend-service
// backend-id="foundry-backend" />, making APIM the AI gateway for the
// Foundry model calls.
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-backend'
  properties: {
    description: 'Foundry AIServices inference backend for the hosted agent'
    url: foundryAccount.properties.endpoint
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ── RBAC — APIM managed identity → Foundry inference ─────────────────────────
// Required because foundryAccount.disableLocalAuth = true; APIM authenticates
// to Foundry with Entra ID via its user-assigned managed identity.
resource foundryOpenAiRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryAccount.id, identity.id, openAiUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── APIM AI Gateway API — exposes Foundry OpenAI inference ───────────────────
resource foundryGatewayApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-ai-gateway'
  properties: {
    displayName: 'Foundry AI Gateway'
    description: 'AI gateway exposing the Foundry OpenAI inference endpoint through APIM with managed-identity auth.'
    path: gatewayApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    serviceUrl: '${foundryAccount.properties.endpoint}openai'
  }
}

resource foundryGatewayOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: foundryGatewayApi
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/chat/completions'
    templateParameters: [
      {
        name: 'deployment-id'
        type: 'string'
        required: true
      }
    ]
  }
}

resource foundryGatewayPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: foundryGatewayApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: gatewayPolicyXml
  }
  dependsOn: [
    foundryBackend
  ]
}

// ── Defender for AI ──────────────────────────────────────────────────────────
resource foundryDefender 'Microsoft.CognitiveServices/accounts/defenderForAISettings@2026-03-01' = {
  parent: foundryAccount
  name: 'Default'
  properties: {
    state: 'Enabled'
  }
  dependsOn: [
    foundryProject
  ]
}

// ── Foundry project ──────────────────────────────────────────────────────────
resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2026-03-01' = {
  parent: foundryAccount
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: '${projectName} Project'
    displayName: projectName
  }
  dependsOn: [
    foundryModel
  ]
}

// ── Register APIM as the Foundry project's AI Gateway ────────────────────────
// Creates a Foundry connection of category 'ApiManagement' so the project's
// model/inference traffic is governed through the APIM AI gateway. The Agents
// service authenticates to the gateway with the project's managed identity
// against the Cognitive Services audience. target = APIM gateway URL + the
// foundry-ai-gateway API path.
resource foundryApimGatewayConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: foundryProject
  name: 'foundry-apim-gateway'
  properties: {
    category: 'ApiManagement'
    target: '${apim.properties.gatewayUrl}/${foundryGatewayApi.properties.path}'
    // 'ProjectManagedIdentity' is a valid runtime authType for Foundry
    // connections; the current type definition lags, so suppress BCP036.
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: 'https://cognitiveservices.azure.com'
    isSharedToAll: true
    credentials: {}
    metadata: {
      deploymentInPath: 'true'
      inferenceAPIVersion: '2024-02-01'
    }
  }
}

// ── Model deployment ─────────────────────────────────────────────────────────
resource foundryModel 'Microsoft.CognitiveServices/accounts/deployments@2026-03-01' = {
  parent: foundryAccount
  name: modelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 50
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelDeploymentName
      version: modelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    currentCapacity: 50
    raiPolicyName: 'Microsoft.DefaultV2'
    deploymentState: 'Running'
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
output foundryResourceName string = foundryAccount.name
output foundryProjectName string = foundryProject.name
output foundryProjectId string = foundryProject.id
output foundryProjectEndpoint string = 'https://${foundryResourceName}.services.ai.azure.com/api/projects/${projectName}'
output modelDeploymentName string = foundryModel.name
output apimFoundryBackendName string = foundryBackend.name
output apimFoundryGatewayUrl string = 'https://${apim.properties.gatewayUrl}/${gatewayApiPath}'
output foundryApimGatewayConnectionName string = foundryApimGatewayConnection.name

// ── Deployment status ────────────────────────────────────────────────────────
// Bicep is declarative and can't print mid-deployment, so surface each
// resource's final provisioning state as a single status object. It is
// reported once the deployment completes (e.g. via `az deployment ... show`).
output deploymentStatus object = {
  redis: redis.properties.provisioningState
  redisDefaultDb: redisDefaultDb.properties.provisioningState
  storage: storage.properties.provisioningState
  apim: apim.properties.provisioningState
  keyVault: keyVault.properties.provisioningState
  acr: acr.properties.provisioningState
  foundryAccount: foundryAccount.properties.provisioningState
  foundryProject: foundryProject.properties.provisioningState
  foundryModel: foundryModel.properties.provisioningState
}
