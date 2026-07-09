// main.bicep — Module 1: Core Infrastructure
// Deploys a Resource Group, Azure Managed Redis, Blob Storage, APIM,
// Azure Key Vault, Azure Container Registry, a Foundry (AIServices) account
// with project, model deployment, Defender for AI, RAI policies, and the APIM
// AI gateway, Entra ID app registration (via deployment script), and UAMI.
// Deploy with: az deployment sub create --location <loc> --template-file main.bicep --parameters ...

targetScope = 'subscription'

@description('Name of the resource group to create')
param resourceGroupName string = 'rg-agenthost-workshop'

@description('Azure region for all resources')
param location string = 'eastus2'

@description('Azure Managed Redis cache name')
param redisName string = 'redis-agenthost'

@description('Blob Storage account name (3-24 chars, lowercase alphanumeric)')
param storageAccountName string = 'stcagenthost'

@description('API Management service name')
param apimName string = 'apim-agenthost'

@description('APIM publisher email')
param apimPublisherEmail string = 'admin@example.com'

@description('APIM publisher name')
param apimPublisherName string = 'Agent Hosting Workshop'

@description('User-Assigned Managed Identity name')
param identityName string = 'id-agenthost'

@description('Azure Key Vault name (3-24 chars, alphanumeric and dashes)')
param keyVaultName string = 'kv-agenthost'

@description('Azure Container Registry name (5-50 chars, lowercase alphanumeric)')
param acrName string = 'acragenthost'

//@description('Azure OpenAI endpoint URL')
//param aoaiEndpoint string = 'https://kacai-3055-resource.services.ai.azure.com/openai/v1'
//param aoaiEndpoint string = 'https://kacai-3055-resource.services.ai.azure.com/api/projects/kacai-3055'

@description('Entra ID tenant ID used by the LLM API validate-jwt policy')
param tenantId string = subscription().tenantId

@description('Audience (App ID URI / client ID) expected in the JWT by the LLM API policy')
param apimAudience string = 'api://agenthost'

@description('Foundry (AIServices) resource name prefix')
@minLength(2)
param foundryResourceName string = 'foundry-agenthost'

@description('Foundry project name')
param projectName string = 'maf-agent-prj'

@description('Default azd environment tag applied to the Foundry account')
param azdEnvName string = 'maf-agent-dev'

@description('Model deployment name to create in Foundry')
param modelDeploymentName string = 'gpt-5.4-mini'

@description('Model version to deploy')
param modelVersion string = '2026-03-17'

@description('random deployment suffix from input parameters')
//param deploymentSuffix string = utcNow('HHmmssfff')
param deploymentSuffix string

var redisNameWithSuffix = '${redisName}-${deploymentSuffix}'
var storageAccountNameWithSuffix = '${storageAccountName}${deploymentSuffix}'
var apimNameWithSuffix = '${apimName}-${deploymentSuffix}'
var identityNameWithSuffix = '${identityName}-${deploymentSuffix}'
var keyVaultNameWithSuffix = '${keyVaultName}-${deploymentSuffix}'
var acrNameWithSuffix = '${acrName}${deploymentSuffix}'
var foundryResourceNameWithSuffix = '${foundryResourceName}-${deploymentSuffix}'

// ── Resource Group ──────────────────────────────────────────────────────────
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: {
    deploymentSuffix: deploymentSuffix
  }
}

// ── Resources deployed into the RG ──────────────────────────────────────────
module coreResources 'core.bicep' = {
  name: 'coreResources'
  scope: rg
  params: {
    location: location
    redisName: redisNameWithSuffix
    storageAccountName: storageAccountNameWithSuffix
    apimName: apimNameWithSuffix
    apimPublisherEmail: apimPublisherEmail
    apimPublisherName: apimPublisherName
    identityName: identityNameWithSuffix
    keyVaultName: keyVaultNameWithSuffix
    acrName: acrNameWithSuffix
    //aoaiEndpoint: aoaiEndpoint
    tenantId: tenantId
    apimAudience: apimAudience
    foundryResourceName: foundryResourceNameWithSuffix
    projectName: projectName
    azdEnvName: azdEnvName
    modelDeploymentName: modelDeploymentName
    modelVersion: modelVersion
  }
}

output resourceGroupName string = rg.name
output redisHostName string = coreResources.outputs.redisHostName
output storageAccountName string = coreResources.outputs.storageAccountName
output apimServiceUrl string = coreResources.outputs.apimServiceUrl
output identityClientId string = coreResources.outputs.identityClientId
output keyVaultName string = coreResources.outputs.keyVaultName
output keyVaultUri string = coreResources.outputs.keyVaultUri
output acrName string = coreResources.outputs.acrName
output acrLoginServer string = coreResources.outputs.acrLoginServer
output foundryResourceName string = coreResources.outputs.foundryResourceName
output foundryProjectName string = coreResources.outputs.foundryProjectName
output foundryProjectId string = coreResources.outputs.foundryProjectId
output foundryProjectEndpoint string = coreResources.outputs.foundryProjectEndpoint
output modelDeploymentName string = coreResources.outputs.modelDeploymentName
output apimFoundryBackendName string = coreResources.outputs.apimFoundryBackendName
output apimFoundryGatewayUrl string = coreResources.outputs.apimFoundryGatewayUrl
