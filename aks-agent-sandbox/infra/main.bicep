targetScope = 'resourceGroup'

param location string = 'eastus2'
param clusterName string
param kubernetesVersion string = '1.35'
param nodePoolName string = 'katapool'
param vmSize string = 'Standard_D4as_v6'
@minValue(2)
param systemNodeCount int = 2
@minValue(2)
param kataNodeCount int = 5
param storageContainer string = 'pod-snapshots'
param namespace string = 'agent-lab'
param serviceAccountName string = 'agent-sa'
param foundryLocation string = 'westus3'
param amrLocation string = 'westus3'
param projectName string = 'sandbox-agent-prj'
param modelName string = 'gpt-5.4-mini'
param modelVersion string = '2026-03-17'
param modelDeploymentName string = modelName
@minValue(1)
param modelCapacity int = 50
param embeddingModelName string = 'text-embedding-3-small'
param embeddingModelVersion string = '1'
param embeddingDeploymentName string = embeddingModelName
@minValue(1)
param embeddingCapacity int = 30
@description('APIM distance threshold: lower values require closer semantic matches.')
param semanticCacheThreshold string = '0.05'
@minValue(1)
param semanticCacheTtl int = 300
param apimPublisherEmail string = 'admin@example.com'
param apimPublisherName string = 'AKS Agent Sandbox Lab'

var labTags = {
  purpose: 'aks-agent-sandbox-lab'
}
var storageName = 'snap${uniqueString(resourceGroup().id, clusterName)}'

resource aksSubnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'sboxvnet-aks-subnet-nsg-${location}'
  location: location
  tags: labTags
  properties: {
    securityRules: [
      {
        name: 'allow_http'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80'
            '8080'
          ]
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'sboxvnet'
  location: location
  tags: labTags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.40.0.0/16']
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.40.0.0/24'
        }
      }
      {
        name: 'aks-subnet'
        properties: {
          addressPrefix: '10.40.16.0/20'
          networkSecurityGroup: {
            id: aksSubnetNsg.id
          }
        }
      }
      {
        name: 'private-link-subnet'
        properties: {
          addressPrefix: '10.40.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource clusterIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${clusterName}-control-plane'
  location: location
  tags: labTags
}

resource networkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, clusterIdentity.id, 'network-contributor')
  scope: vnet
  properties: {
    principalId: clusterIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  }
}

resource cluster 'Microsoft.ContainerService/managedClusters@2026-08-01' = {
  name: clusterName
  location: location
  tags: labTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${clusterIdentity.id}': {}
    }
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: clusterName
    kubernetesVersion: kubernetesVersion
    enableRBAC: true
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    storageProfile: {
      blobCSIDriver: {
        enabled: true
      }
    }
    ingressProfile: {
      gatewayAPI: {
        installation: 'Standard'
      }
      webAppRouting: {
        gatewayAPIImplementations: {
          appRoutingIstio: {
            mode: 'Enabled'
          }
        }
      }
    }
    apiServerAccessProfile: {
      authorizedIPRanges: []
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: systemNodeCount
        vmSize: vmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
        osDiskType: 'Managed'
        vnetSubnetID: '${vnet.id}/subnets/aks-subnet'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      podCidr: '10.42.0.0/16'
      serviceCidr: '10.41.0.0/16'
      dnsServiceIP: '10.41.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
  }
  dependsOn: [
    networkRole
  ]
}

resource kataPool 'Microsoft.ContainerService/managedClusters/agentPools@2026-08-01' = {
  parent: cluster
  name: nodePoolName
  properties: {
    mode: 'User'
    count: kataNodeCount
    enableAutoScaling: false
    vmSize: vmSize
    osType: 'Linux'
    osSKU: 'AzureLinux'
    type: 'VirtualMachineScaleSets'
    osDiskType: 'Managed'
    workloadRuntime: 'KataVmIsolation'
    vnetSubnetID: '${vnet.id}/subnets/aks-subnet'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: labTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: storageContainer
  properties: {
    publicAccess: 'None'
  }
}

resource agentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'data'
  properties: {
    publicAccess: 'None'
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'sboxvnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${clusterName}-blob-pe'
  location: location
  tags: labTags
  properties: {
    customNetworkInterfaceName: '${clusterName}-blob-pe-nic'
    subnet: {
      id: '${vnet.id}/subnets/private-link-subnet'
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource blobDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acrsbox${uniqueString(resourceGroup().id, clusterName)}'
  location: location
  tags: labTags
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
  }
}

module kubeletRbac 'kubelet-rbac.bicep' = {
  name: 'sandbox-kubelet-rbac'
  params: {
    acrName: acr.name
    storageAccountName: storage.name
    kubeletPrincipalId: cluster.properties.identityProfile.kubeletidentity.objectId
  }
  dependsOn: [
    agentContainer
  ]
}

resource agentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${clusterName}-agent'
  location: location
  tags: labTags
}

resource agentFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: agentIdentity
  name: 'sandbox-agent'
  properties: {
    issuer: cluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${namespace}:${serviceAccountName}'
    audiences: ['api://AzureADTokenExchange']
  }
}

module ai 'ai.bicep' = {
  name: 'sandbox-ai-gateway'
  params: {
    location: location
    foundryLocation: foundryLocation
    amrLocation: amrLocation
    clusterName: clusterName
    agentIdentityName: agentIdentity.name
    projectName: projectName
    modelName: modelName
    modelVersion: modelVersion
    modelDeploymentName: modelDeploymentName
    modelCapacity: modelCapacity
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingDeploymentName: embeddingDeploymentName
    embeddingCapacity: embeddingCapacity
    semanticCacheThreshold: semanticCacheThreshold
    semanticCacheTtl: semanticCacheTtl
    apimPublisherEmail: apimPublisherEmail
    apimPublisherName: apimPublisherName
  }
}

resource broker 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${clusterName}-snapshot-broker'
  location: location
  tags: labTags
}

resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: broker
  name: 'pod-snapshot-broker'
  properties: {
    issuer: cluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:pod-snapshot-system:pod-snapshot-broker'
    audiences: ['api://AzureADTokenExchange']
  }
}

resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, broker.id, 'blob-contributor')
  scope: storage
  properties: {
    principalId: broker.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

output storageAccount string = storage.name
output brokerClientId string = broker.properties.clientId
output tenantId string = tenant().tenantId
output clusterId string = cluster.id
output kataPoolId string = kataPool.id
output vnetId string = vnet.id
output aksSubnetId string = '${vnet.id}/subnets/aks-subnet'
output blobPrivateEndpointId string = blobPrivateEndpoint.id
output blobPrivateDnsZoneId string = privateDnsZone.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output kubeletClientId string = cluster.properties.identityProfile.kubeletidentity.clientId
output agentClientId string = agentIdentity.properties.clientId
output apimName string = ai.outputs.apimName
output apimGatewayUrl string = ai.outputs.apimGatewayUrl
output foundryProjectEndpoint string = ai.outputs.foundryProjectEndpoint
output modelDeploymentName string = ai.outputs.modelDeploymentName
output embeddingDeploymentName string = ai.outputs.embeddingDeploymentName
output redisName string = ai.outputs.redisName
