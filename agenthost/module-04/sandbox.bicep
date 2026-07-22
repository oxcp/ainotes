// sandbox.bicep — Module 4: Azure Container Apps Sandboxes Deployment (workshop path)
// 
// Deploys REAL Azure Container Apps Sandboxes (Microsoft.App/SandboxGroups).
// This is fundamentally different from standard ACA container apps.
//
// Key differences from standard ACA:
//   - Resource type: Microsoft.App/SandboxGroups (instead of containerApps)
//   - Compute model: Isolated, ephemeral sandbox VMs (micro-VM boundary)
//   - State: Snapshots with suspend/resume (full memory + disk preservation)
//   - Networking: Two-plane architecture (ARM control plane + ADC data plane)
//   - Scaling: Burst from zero to hundreds of concurrent sandboxes
//   - Use cases: AI code execution, development environments, burst workloads
//
// This module creates:
//   - SandboxGroup: Container for all sandbox instances
//   - References module-01 resources: UAMI, ACR, optional Storage
//
// Note: Individual sandbox creation/lifecycle is managed via CLI or SDK (sandbox-deploy.sh).
//
// Usage: az deployment group create \
//   --resource-group <rg-name> \
//   --template-file sandbox.bicep \
//   --parameters \
//       location=<loc> \
//       deploymentSN=<SN> \
//       acrName=<acr-name-with-SN> \
//       identityId=<identity-resource-id> \
//       identityClientId=<client-id>

targetScope = 'resourceGroup'

param location string
@description('Deployment suffix from module-01 (e.g., "abc123")')
param deploymentSN string
@description('ACR name with SN suffix (e.g., "acragenthostabc123")')
param acrName string
@description('User-Assigned Managed Identity resource ID')
param identityId string
@description('User-Assigned Managed Identity client ID')
param identityClientId string
@description('Container image tag (default: latest)')
param imageTag string = 'latest'
@description('Container image URI (default: agent-host)')
param imageUri string = 'agent-host'

// Optional parameters for state persistence
@description('Storage account name with SN suffix (e.g., "stcagenthostabc123")')
param storageAccountName string = ''

// ── Construct resource names ─────────────────────────────────────────────────
var sandboxGroupName = 'sandbox-group-agenthost-${deploymentSN}'
var acrLoginServer = '${acrName}.azurecr.io'
var imageRef = '${acrLoginServer}/${imageUri}:${imageTag}'

// Built-in role: AcrPull
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// ── Variables for conditional environments ───────────────────────────────────

var hasStorageName = !empty(storageAccountName)

// ── ACR reference (for credential lookup) ────────────────────────────────────
resource existingAcr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// ── UAMI reference ───────────────────────────────────────────────────────────
resource existingUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: split(identityId, '/')[8] // Extract UAMI name from resource ID
}


// ── Optional Storage Account reference ───────────────────────────────────────
resource existingStorage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = if (hasStorageName) {
  name: storageAccountName
}

// ── Grant UAMI AcrPull on ACR (image pull for sandbox disk images) ───────────
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(existingAcr.id, existingUami.id, acrPullRoleId)
  scope: existingAcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: existingUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── SandboxGroup: Top-level container for sandbox instances ──────────────────
// This is the ARM resource (Microsoft.App/SandboxGroups).
// Individual sandboxes are created/managed via CLI/SDK using the ADC data plane.
resource sandboxGroup 'Microsoft.App/SandboxGroups@2026-02-01-preview' = {
  name: sandboxGroupName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    // ACR registry for disk images
    registryServerName: acrLoginServer
    
    // Managed identity for ACR image pull
    identityClientId: identityClientId
    
    // Environment for all sandboxes in this group
    environmentName: 'production'
    environmentDescription: 'Sandbox environment for agenthost'
  }
  tags: {
    module: 'module-04'
    solution: 'sandboxes'
    deploymentSN: deploymentSN
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output sandboxGroupName string = sandboxGroup.name
output sandboxGroupId string = sandboxGroup.id
output sandboxGroupResourceGroup string = resourceGroup().name
output acrLoginServer string = acrLoginServer
output imageRef string = imageRef
output uamiId string = identityId
output uamiClientId string = identityClientId
output storageAccountName string = hasStorageName ? existingStorage.name : 'N/A (Storage not configured)'
output deploymentSN string = deploymentSN
