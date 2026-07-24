param location string
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-ai-infra-workshop'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.20.0.0/16'] }
    subnets: [{ name: 'snet-aks', properties: { addressPrefix: '10.20.0.0/22' } }]
  }
}
output aksSubnetId string = vnet.properties.subnets[0].id
