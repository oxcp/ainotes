targetScope = 'resourceGroup'

@description('Azure region for the Foundry resource and project')
param location string = 'eastus2'

@description('API Management service name created by module-01')
param apimName string = 'apim-agenthost'

@description('Foundry resource name prefix')
@minLength(2)
param foundryResourceName string = 'foundry-agenthost'

@description('Foundry project name')
param projectName string = 'maf-agent-basic-resp'

@description('Default tag value carried from the module-01 deployment')
param azdEnvName string = 'maf-agent-basic-resp-dev'

@description('Model deployment name to create in Foundry')
param modelDeploymentName string = 'gpt-5.4-mini'

@description('Model version to deploy')
param modelVersion string = '2026-03-17'

@description('User-assigned managed identity name created by module-01 (used by APIM to call Foundry)')
param identityName string = 'id-agenthost'

var rgTags = resourceGroup().tags
var deploymentSuffix = rgTags.?deploymentSuffix ?? ''
var foundryResourceNameWithSuffix = '${foundryResourceName}-${deploymentSuffix}'
var apimNameWithSuffix = '${apimName}-${deploymentSuffix}'
var identityNameWithSuffix = '${identityName}-${deploymentSuffix}'
var apimGatewayUrl = 'https://${apim.properties.gatewayUrl}'

// Cognitive Services OpenAI User — lets APIM's managed identity call Foundry
// inference when the account has disableLocalAuth = true (keys disabled).
var openAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var gatewayApiPath = 'foundry'

// API-scope policy: route to the Foundry backend and attach an Entra ID token
// obtained from APIM's user-assigned managed identity. When client-id is set
// and output-token-variable-name is omitted, the token is written to the
// Authorization header automatically.
var gatewayPolicyXml = '<policies><inbound><base /><set-backend-service backend-id="foundry-host-agent" /><authentication-managed-identity resource="https://cognitiveservices.azure.com" client-id="${identity.properties.clientId}" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimNameWithSuffix
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityNameWithSuffix
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2026-03-01' = {
  name: foundryResourceNameWithSuffix
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
    customSubDomainName: foundryResourceNameWithSuffix
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
// Mirrors the module-01 'azure-openai' backend pattern. The module-02
// apim-policy.xml routes to this backend via <set-backend-service
// backend-id="foundry-host-agent" />, making APIM the gateway for the
// Foundry model calls.
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'foundry-host-agent'
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

resource foundryDefender 'Microsoft.CognitiveServices/accounts/defenderForAISettings@2026-03-01' = {
  parent: foundryAccount
  name: 'Default'
  properties: {
    state: 'Enabled'
  }
}

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
}

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

resource raiPolicyDefault 'Microsoft.CognitiveServices/accounts/raiPolicies@2026-03-01' = {
  parent: foundryAccount
  name: 'Microsoft.Default'
  properties: {
    mode: 'Blocking'
    contentFilters: [
      {
        name: 'Hate'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Hate'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
      {
        name: 'Sexual'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Sexual'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
      {
        name: 'Violence'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Violence'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
      {
        name: 'Selfharm'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Selfharm'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
    ]
  }
}

resource raiPolicyDefaultV2 'Microsoft.CognitiveServices/accounts/raiPolicies@2026-03-01' = {
  parent: foundryAccount
  name: 'Microsoft.DefaultV2'
  properties: {
    mode: 'Blocking'
    contentFilters: [
      {
        name: 'Hate'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Hate'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
      {
        name: 'Sexual'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Sexual'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
      {
        name: 'Violence'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Violence'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
      {
        name: 'Selfharm'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Selfharm'
        severityThreshold: 'Medium'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
      {
        name: 'Jailbreak'
        blocking: true
        enabled: true
        source: 'Prompt'
        action: 'NONE'
      }
      {
        name: 'Protected Material Text'
        blocking: true
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
      {
        name: 'Protected Material Code'
        blocking: false
        enabled: true
        source: 'Completion'
        action: 'NONE'
      }
    ]
  }
}

output foundryResourceName string = foundryAccount.name
output foundryProjectName string = foundryProject.name
output foundryProjectId string = foundryProject.id
output foundryProjectEndpoint string = 'https://${foundryResourceNameWithSuffix}.services.ai.azure.com/api/projects/${projectName}'
output modelDeploymentName string = foundryModel.name
output apimFoundryBackendName string = foundryBackend.name
output apimFoundryGatewayUrl string = '${apimGatewayUrl}/${gatewayApiPath}'
output apimGatewayUrl string = apimGatewayUrl
