targetScope = 'resourceGroup'

param location string = resourceGroup().location
param aksClusterName string
param acrName string
param storageAccountName string
param systemNodeVmSize string = 'Standard_D4ds_v5'
param gpuVmSize string
param gpuNodeCount int = 0
param enableKaito bool = true

module network 'modules/network.bicep' = {
  name: 'network'
  params: { location: location }
}
module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: { location: location, acrName: acrName }
}
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: { location: location, storageAccountName: storageAccountName }
}
module aks 'modules/aks.bicep' = {
  name: 'aks'
  params: {
    location: location
    aksClusterName: aksClusterName
    subnetId: network.outputs.aksSubnetId
    acrId: acr.outputs.acrId
    systemNodeVmSize: systemNodeVmSize
    gpuVmSize: gpuVmSize
    gpuNodeCount: gpuNodeCount
    enableKaito: enableKaito
  }
}
output aksName string = aks.outputs.aksName
