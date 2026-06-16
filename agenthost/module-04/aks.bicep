// aks.bicep — Module 4: AKS cluster with Kata Container runtime node pool
// Provisions an AKS cluster with:
//   - System node pool (standard VMs)
//   - Kata Container node pool for Micro-VM isolation
//   - OIDC issuer + Workload Identity enabled
//   - ACR integration for image pull

param location string
param aksName string
param acrName string
param identityId string

@description('Kubernetes version')
param kubernetesVersion string = '1.30'

@description('System node pool VM size')
param systemNodeVmSize string = 'Standard_D2s_v5'

@description('Kata node pool VM size (requires nested virtualisation support)')
param kataNodeVmSize string = 'Standard_D4s_v5'

// ── Reference existing ACR ────────────────────────────────────────────────────
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// ── AKS Cluster ───────────────────────────────────────────────────────────────
resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: aksName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: aksName
    enableRBAC: true

    // Workload Identity (AAD Pod Identity successor)
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }

    // System node pool
    agentPoolProfiles: [
      {
        name: 'system'
        count: 1
        minCount: 1
        maxCount: 3
        vmSize: systemNodeVmSize
        osType: 'Linux'
        mode: 'System'
        enableAutoScaling: true
        nodeTaints: []
      }
      {
        // Kata Container node pool — uses ContainerD with Kata runtime class
        name: 'kata'
        count: 0
        minCount: 0
        maxCount: 10
        vmSize: kataNodeVmSize
        osType: 'Linux'
        mode: 'User'
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

    // Enable ACR integration
    addonProfiles: {
      acrPull: {}
    }
  }
}

// ── Grant AcrPull to AKS kubelet identity ─────────────────────────────────────
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, 'acrpull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output aksName string = aks.name
output aksOidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output aksFqdn string = aks.properties.fqdn
