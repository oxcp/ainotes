// main.bicep — Module 1: Core Infrastructure
// Deploys a Resource Group, Azure Managed Redis, Blob Storage, APIM,
// Entra ID app registration (via deployment script), and UAMI.
// Deploy with: az deployment sub create --location <loc> --template-file main.bicep --parameters ...

targetScope = 'subscription'

@description('Name of the resource group to create')
param resourceGroupName string = 'rg-agenthost-workshop'

@description('Azure region for all resources')
param location string = 'eastus'

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

@description('Azure OpenAI endpoint URL')
param aoaiEndpoint string

// ── Resource Group ──────────────────────────────────────────────────────────
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

// ── Resources deployed into the RG ──────────────────────────────────────────
module coreResources 'core.bicep' = {
  name: 'coreResources'
  scope: rg
  params: {
    location: location
    redisName: redisName
    storageAccountName: storageAccountName
    apimName: apimName
    apimPublisherEmail: apimPublisherEmail
    apimPublisherName: apimPublisherName
    identityName: identityName
    aoaiEndpoint: aoaiEndpoint
  }
}

output resourceGroupName string = rg.name
output redisHostName string = coreResources.outputs.redisHostName
output storageAccountName string = coreResources.outputs.storageAccountName
output apimServiceUrl string = coreResources.outputs.apimServiceUrl
output identityClientId string = coreResources.outputs.identityClientId
