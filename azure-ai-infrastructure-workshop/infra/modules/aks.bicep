param location string
param aksClusterName string
param subnetId string
param acrId string
param systemNodeVmSize string
param gpuVmSize string
param gpuNodeCount int
param enableKaito bool

resource aks 'Microsoft.ContainerService/managedClusters@2025-04-01' = {
  name: aksClusterName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: aksClusterName
    agentPoolProfiles: [{
      name: 'system'
      count: 1
      vmSize: systemNodeVmSize
      mode: 'System'
      osType: 'Linux'
      vnetSubnetID: subnetId
      type: 'VirtualMachineScaleSets'
    }]
    networkProfile: { networkPlugin: 'azure', networkPluginMode: 'overlay', outboundType: 'loadBalancer' }
    addonProfiles: enableKaito ? { aiToolchainOperator: { enabled: true } } : {}
  }
}

// GPU pool API/schema and supported SKU must be validated before delivery.
resource gpuPool 'Microsoft.ContainerService/managedClusters/agentPools@2025-04-01' = if (gpuNodeCount > 0) {
  parent: aks
  name: 'gpu'
  properties: {
    count: gpuNodeCount
    vmSize: gpuVmSize
    mode: 'User'
    osType: 'Linux'
    vnetSubnetID: subnetId
    type: 'VirtualMachineScaleSets'
    enableAutoScaling: false
    nodeTaints: ['sku=gpu:NoSchedule']
  }
}
output aksName string = aks.name
