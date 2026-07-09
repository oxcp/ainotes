// apim-api-policy.bicep — Module 1: APIM API and policy configuration
// Deploys named values, API, and API-level policy into an existing APIM service.

targetScope = 'resourceGroup'

param apimName string = 'apim-agenthost'
param tenantId string = subscription().tenantId
param apimAudience string = 'api://agenthost'

@description('AI gateway backend name created in core.bicep (from main.bicep output apimFoundryBackendName)')
param foundryBackendName string = 'foundry-backend'

var deploymentSuffix = contains(resourceGroup().tags, 'deploymentSuffix') ? resourceGroup().tags['deploymentSuffix'] : ''
var apimNameWithSuffix = '${apimName}-${deploymentSuffix}'

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimNameWithSuffix
}

// Existing AI gateway backend deployed in core.bicep
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' existing = {
  parent: apim
  name: foundryBackendName
}

resource nvTenantId 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'TenantId'
  properties: {
    displayName: 'TenantId'
    value: tenantId
  }
}

resource nvApimAudience 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'ApimAudience'
  properties: {
    displayName: 'ApimAudience'
    value: apimAudience
  }
}

resource llmApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'llm'
  properties: {
    displayName: 'LLM API'
    path: 'llm'
    protocols: [
      'https'
    ]
    subscriptionRequired: true
  }
}

resource llmApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: llmApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('apim-policy.xml')
  }
  dependsOn: [
    foundryBackend
    nvTenantId
    nvApimAudience
  ]
}

output llmApiPath string = llmApi.properties.path
output deploymentSuffix string = deploymentSuffix
