// foundry.bicep — Module 2: Azure AI Foundry Hub and Project
// Deploys an Azure AI Foundry Hub linked to existing storage and key vault,
// then creates a Project within the Hub for agent hosting.

targetScope = 'resourceGroup'

param location string = 'eastus2'
param hubName string = 'hub-agenthost'
param projectName string = 'proj-agenthost'
param identityName string = 'id-agenthost'
param redisName string = 'redis-agenthost'
param storageAccountName string = 'stcagenthost'
param keyVaultName string = 'kv-agenthost'

var deploymentSuffix = contains(resourceGroup().tags, 'deploymentSuffix') ? resourceGroup().tags['deploymentSuffix'] : ''
var apimNameWithSuffix = '${apimName}-${deploymentSuffix}'

var redisNameWithSuffix = '${redisName}-${deploymentSuffix}'
var storageAccountNameWithSuffix = '${storageAccountName}${deploymentSuffix}'
var identityNameWithSuffix = '${identityName}-${deploymentSuffix}'
var keyVaultNameWithSuffix = '${keyVaultName}-${deploymentSuffix}'
var hubNameWithSuffix = '${hubName}-${deploymentSuffix}'
var projNameWithSuffix = '${projectName}-${deploymentSuffix}'


// ── Reference existing resources from Module 1 ──────────────────────────────
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityNameWithSuffix
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountNameWithSuffix
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultNameWithSuffix
}

// ── Azure AI Foundry Hub ─────────────────────────────────────────────────────
resource foundryHub 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: hubNameWithSuffix
  location: location
  kind: 'Hub'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    friendlyName: 'Agent Hosting Workshop Hub'
    description: 'Azure AI Foundry Hub for agent hosting workshop'
    storageAccount: storage.id
    keyVault: keyVault.id
    hbiWorkspace: false
  }
}

// ── Azure AI Foundry Project ─────────────────────────────────────────────────
resource foundryProject 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: projNameWithSuffix
  location: location
  kind: 'Project'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    friendlyName: 'Agent Hosting Workshop Project'
    description: 'Project for deploying Host Agent'
    hubResourceId: foundryHub.id
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output foundryHubId string = foundryHub.id
output foundryProjectId string = foundryProject.id
output foundryProjectName string = foundryProject.name
