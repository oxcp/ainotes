// aks.bicep — Module 3 (Solution B): AKS + agent-sandbox, reusing Module 1 resources
//
// Provisions an AKS cluster INTO the Module 1 resource group and wires it to the
// resources Module 1 already created (referenced as `existing`, never recreated):
//   - Azure Container Registry  : acragenthost<SN>      (image pull)
//   - User-Assigned Managed Id  : id-agenthost-<SN>     (workload identity federation)
//   - Azure Blob Storage        : stcagenthost<SN>      (cold state, container agent-state)
//   (Redis / APIM are consumed at runtime via Kubernetes secrets created by deploy.sh.)
//
// Creates: AKS (OIDC + Workload Identity), a Kata node pool, AcrPull for kubelet,
// Storage Blob Data Contributor for the UAMI, and a federated identity credential
// on the UAMI trusting the AKS OIDC issuer for system:serviceaccount:<ns>:<sa>.

targetScope = 'resourceGroup'

@description('Azure region for the AKS cluster + its node resource group. Defaults to westus2; may differ from the Module 1 region. The AKS resource is still created INTO the Module 1 resource group.')
param location string = 'malaysiawest'

@description('Deployment suffix from Module 1 (resource-group tag deploymentSN)')
param deploymentSN string

@description('Existing ACR name from Module 1 (e.g. acragenthost<SN>)')
param acrName string

@description('Existing User-Assigned Managed Identity name from Module 1 (e.g. id-agenthost-<SN>)')
param identityName string

@description('Existing Storage account name from Module 1 (e.g. stcagenthost<SN>)')
param storageAccountName string

@description('Kubernetes namespace the agent workload runs in')
param namespace string = 'agent'

@description('Kubernetes service account federated with the Module 1 UAMI')
param serviceAccountName string = 'agent-sa'

@description('Kubernetes version. Leave EMPTY to use the AKS-recommended default (safest). Pinning a minor that is not GA in the target region makes control-plane provisioning fail — the node resource group is created but stays empty.')
param kubernetesVersion string = ''

@description('System node pool VM size')
param systemNodeVmSize string = 'Standard_D4as_v5'

@description('Kata node pool VM size (nested-virtualisation capable SKU)')
param kataNodeVmSize string = 'Standard_D4as_v5'

var aksName = 'aks-agenthost-${deploymentSN}'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: aksName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: {
    module: 'module-03'
    solution: 'aks-agent-sandbox'
    deploymentSN: deploymentSN
  }
  properties: {
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    // Explicit node resource group so the VMSS / VNet / NSG / Load Balancer are
    // easy to find. (AKS puts ALL node infra here, NOT in this deployment's RG.)
    nodeResourceGroup: 'rg-${aksName}-nodes'
    dnsPrefix: aksName
    enableRBAC: true
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: 1
        minCount: 1
        maxCount: 3
        vmSize: systemNodeVmSize
        osType: 'Linux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: true
        nodeTaints: []
      }
      {
        name: 'kata'
        count: 1
        minCount: 0
        maxCount: 10
        vmSize: kataNodeVmSize
        osType: 'Linux'
        mode: 'User'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: true
        nodeTaints: [
          'kata=true:NoSchedule'
        ]
        nodeLabels: {
          'kata-containers': 'true'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      loadBalancerSku: 'standard'
    }
  }
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

resource storageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, storageBlobDataContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource federatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: 'aks-agenthost-${deploymentSN}-fed'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${namespace}:${serviceAccountName}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

output aksName string = aks.name
output aksFqdn string = aks.properties.fqdn
output aksNodeResourceGroup string = aks.properties.nodeResourceGroup
output aksOidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output identityClientId string = identity.properties.clientId
output acrLoginServer string = acr.properties.loginServer
output namespace string = namespace
output serviceAccountName string = serviceAccountName
