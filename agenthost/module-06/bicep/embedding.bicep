// Add an embedding deployment to the existing Foundry account backing the existing project.
// Model deployments are account children, not project children; neither parent is redeployed.
// Inference authorization is provided by Module-01; this template never changes RBAC.
targetScope = 'resourceGroup'

param foundryAccountName string
param apimName string
param openAiEndpoint string
param gatewayUrl string
param tenantId string
param callerPrincipalId string
param deploymentName string = 'text-embedding-3-small'
param modelName string = 'text-embedding-3-small'
param modelVersion string = '1'
param skuName string = 'GlobalStandard'
@minValue(1)
param capacity int = 30

resource account 'Microsoft.CognitiveServices/accounts@2026-03-01' existing = {
  name: foundryAccountName
}
resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2026-03-01' = {
  parent: account
  name: deploymentName
  sku: {
    name: skuName
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

// Extend only the existing gateway's children; never redeploy its API or policies.
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}
resource api 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' existing = {
  parent: apim
  name: 'workshop-ai-gateway'
}
resource backend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'module06-embeddings-backend'
  properties: {
    description: 'Module-06 account-level OpenAI v1 embeddings'
    url: openAiEndpoint
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
  dependsOn: [
    embedding
  ]
}
resource operation 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: api
  name: 'embeddings'
  properties: {
    displayName: 'embeddings'
    method: 'POST'
    urlTemplate: '/openai/v1/embeddings'
  }
  dependsOn: [
    embedding
  ]
}
// Bicep multiline strings are literal; substitute policy values explicitly.
var embeddingPolicyTemplate = '''
<policies>
  <inbound>
    <validate-jwt header-name="Authorization" require-scheme="Bearer" require-expiration-time="true" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized embedding caller">
      <openid-config url="https://login.microsoftonline.com/__TENANT_ID__/v2.0/.well-known/openid-configuration" />
      <audiences><audience>https://ai.azure.com</audience></audiences>
      <issuers>
        <issuer>https://sts.windows.net/__TENANT_ID__/</issuer>
        <issuer>https://login.microsoftonline.com/__TENANT_ID__/v2.0</issuer>
      </issuers>
      <required-claims>
        <claim name="oid" match="all"><value>__CALLER_PRINCIPAL_ID__</value></claim>
      </required-claims>
    </validate-jwt>
    <base />
    <set-backend-service backend-id="__BACKEND_ID__" />
    <rewrite-uri template="/openai/v1/embeddings" copy-unmatched-params="false" />
    <authentication-managed-identity resource="https://ai.azure.com" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
'''
var embeddingPolicyWithTenant = replace(embeddingPolicyTemplate, '__TENANT_ID__', tenantId)
var embeddingPolicyWithCaller = replace(embeddingPolicyWithTenant, '__CALLER_PRINCIPAL_ID__', callerPrincipalId)
var embeddingPolicyXml = replace(embeddingPolicyWithCaller, '__BACKEND_ID__', backend.name)

// Validate the original caller before inherited auth replaces Authorization.
// No client-id intentionally selects APIM's already-authorized system identity.
resource policy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  parent: operation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: embeddingPolicyXml
  }
}

output deploymentId string = embedding.id
output embeddingBaseUrl string = '${gatewayUrl}/foundry/openai/v1'
output embeddingTokenScope string = 'https://ai.azure.com/.default'
