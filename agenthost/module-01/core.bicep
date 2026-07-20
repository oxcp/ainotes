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
param tenantId string

@description('Audience (App ID URI / client ID) expected in the caller JWT by the APIM AI gateway')
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
// Includes the data action Microsoft.CognitiveServices/accounts/OpenAI/responses/*.
var openAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

// Azure AI User (formerly "Azure AI User", now "Foundry User") — grants
// Microsoft.CognitiveServices/* data actions so the UAMI can call the Foundry
// Responses API via the https://ai.azure.com audience.
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var gatewayApiPath = 'foundry'
var entraLoginEndpoint = environment().authentication.loginEndpoint

// APIM validates the caller's Entra ID token, then replaces backend auth with
// the APIM user-assigned managed identity when forwarding to Foundry.
var gatewayPolicyTemplate = '''
<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: invalid or missing token">
      <openid-config url="__LOGIN_ENDPOINT____TENANT_ID__/v2.0/.well-known/openid-configuration" />

      <issuers>
        <issuer>https://sts.windows.net/__TENANT_ID__/</issuer>
        <issuer>__LOGIN_ENDPOINT____TENANT_ID__/v2.0</issuer>
      </issuers>
    </validate-jwt>
    <set-backend-service backend-id="foundry-backend" />
    <authentication-managed-identity resource="https://ai.azure.com" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''

// ── User-Assigned Managed Identity ──────────────────────────────────────────
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// ── Azure Cache for Redis (Standard C0) ────────────────────────────────────
// Temporary: replacing Azure Managed Redis Enterprise with standard Azure Cache
resource redis 'Microsoft.Cache/redis@2024-03-01' = {
  name: redisName
  location: location
  properties: {
    sku: {
      name: 'Standard'
      family: 'C'
      capacity: 0
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

// Note: Standard Redis has no database concept like Enterprise does.
// Connection: ${redisHostName}:6380 with Entra ID or access key auth

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


//---------------------------------------------------------------------------------
//---------------------------------------------------------------------------------
// API Mamagement provisioning
//

// ── Azure API Management (Basic v2 SKU) ─────────────────────────────────────
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
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

// ── RBAC — APIM system-assigned managed identity → Foundry inference ─────────
// Required because foundryAccount.disableLocalAuth = true; APIM authenticates
// to Foundry with Entra ID via its OWN system-assigned managed identity (the
// gateway policy uses <authentication-managed-identity> with no client-id).
resource foundryOpenAiRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryAccount.id, apim.id, openAiUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Azure AI User (Foundry User) — broader Foundry data-plane access covering the
// Responses API when APIM forwards with the https://ai.azure.com audience.
resource foundryAiUserRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryAccount.id, apim.id, foundryUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── RBAC — UAMI → Foundry inference ──────────────────────────────────────────
// The same two roles are also granted to the user-assigned managed identity so
// workloads that authenticate as the UAMI (e.g. AKS Workload Identity in
// module-03) can call the Foundry Responses API directly.
resource foundryOpenAiRbacUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryAccount.id, identity.id, openAiUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource foundryAiUserRbacUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryAccount.id, identity.id, foundryUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
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
    audience: 'https://ai.azure.com'
    isSharedToAll: true
    credentials: {}
    metadata: {
      inferenceAPIVersion: 'preview'
    }
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
    description: 'Foundry AIServices Responses API (openai/v1) backend'
    url: '${foundryAccount.properties.endpoint}api/projects/${foundryProject.name}'
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ── APIM AI Gateway API — exposes Foundry OpenAI inference ───────────────────
resource foundryGatewayApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-ai-gateway'
  properties: {
    displayName: 'Foundry AI Gateway'
    description: 'AI gateway exposing the Foundry Responses API (openai/v1/responses) through APIM with caller Entra ID validation and managed-identity backend auth.'
    path: gatewayApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    // No direct backend-id on the API resource; the named `foundry-backend`
    // is selected in the API policy via <set-backend-service backend-id=... />.
    // serviceUrl (fallback when no backend is set) reuses the backend URL so
    // the endpoint is defined in one place.
    serviceUrl: foundryBackend.properties.url
  }
}

// Responses API: model name is supplied in the request body, so the operation
// has no path parameter. Callers POST /foundry/responses with {"model":"..."}.
resource foundryGatewayOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: foundryGatewayApi
  name: 'responses'
  properties: {
    displayName: 'Create Response'
    method: 'POST'
    urlTemplate: '/openai/v1/responses'
  }
}

// Retrieve a previously created response by its ID:
// GET /foundry/responses/{response-id}
resource foundryGatewayGetOp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: foundryGatewayApi
  name: 'get-response'
  properties: {
    displayName: 'Get Response'
    method: 'GET'
    urlTemplate: '/responses/{response-id}'
    templateParameters: [
      {
        name: 'response-id'
        type: 'string'
        required: true
      }
    ]
  }
}

var gatewayPolicyWithTenant = replace(gatewayPolicyTemplate, '__TENANT_ID__', tenantId)
var gatewayPolicyXml = replace(gatewayPolicyWithTenant, '__LOGIN_ENDPOINT__', entraLoginEndpoint)

resource foundryGatewayPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: foundryGatewayApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: gatewayPolicyXml
  }
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


// ── Outputs ──────────────────────────────────────────────────────────────────
output redisHostName string = redis.properties.hostName
output redisPort int = 6380
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
  storage: storage.properties.provisioningState
  apim: apim.properties.provisioningState
  keyVault: keyVault.properties.provisioningState
  acr: acr.properties.provisioningState
  foundryAccount: foundryAccount.properties.provisioningState
  foundryProject: foundryProject.properties.provisioningState
  foundryModel: foundryModel.properties.provisioningState
}
