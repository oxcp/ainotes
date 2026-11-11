// Unified database entry point; provider modules live alongside this template.
targetScope = 'resourceGroup'

// Choose exactly one provider. Conditional deployment is selection, not automatic failover.
@allowed(['horizondb', 'postgresql'])
param dbProvider string = 'horizondb'
param location string = resourceGroup().location
param clusterName string
param administratorLogin string = 'studioadmin'
// The provider administrator API creates a real Entra database principal; Azure RBAC does not.
// Workshop bootstrap deliberately uses this UAMI as a database administrator, not a least-privilege app role.
param identityPrincipalId string = ''
param identityName string = ''
param identityTenantId string = tenant().tenantId
param reuseHorizonCluster bool = false
// The shell passes this through a protected parameters file; never expose it as an output.
@secure()
@minLength(8)
@maxLength(128)
param administratorLoginPassword string
// HorizonDB uses vCores; Flexible Server uses skuName/storageSizeGB. Only the chosen module receives them.
@minValue(2)
@maxValue(96)
param vCores int = 2
param skuName string = 'Standard_D2ds_v5'
@minValue(32)
@maxValue(65536)
param storageSizeGB int = 32
// Workshop default allows all IPv4 clients. Supply narrower ranges outside the workshop.
param firewallRules {
  name: string
  startIpAddress: string
  endIpAddress: string
}[] = [
  {
    name: 'workshop-public'
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
]

module horizon 'horizondb.bicep' = if (dbProvider == 'horizondb') {
  name: 'module06-horizondb'
  params: {
    location: location
    clusterName: clusterName
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    identityPrincipalId: identityPrincipalId
    identityName: identityName
    identityTenantId: identityTenantId
    reuseCluster: reuseHorizonCluster
    vCores: vCores
    firewallRules: firewallRules
  }
}
module postgres 'postgresql.bicep' = if (dbProvider == 'postgresql') {
  name: 'module06-postgresql'
  params: {
    location: location
    clusterName: clusterName
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    identityPrincipalId: identityPrincipalId
    identityName: identityName
    identityTenantId: identityTenantId
    skuName: skuName
    storageSizeGB: storageSizeGB
    firewallRules: firewallRules
  }
}

// The selected branch is deployed, so ! suppresses nullable-module warnings for that branch only.
// A common output contract lets the same config generator and Agent repository work with either service.
output resourceId string = dbProvider == 'horizondb' ? horizon!.outputs.resourceId : postgres!.outputs.resourceId
output endpoint string = dbProvider == 'horizondb' ? horizon!.outputs.endpoint : postgres!.outputs.endpoint
output username string = empty(identityPrincipalId) ? administratorLogin : identityName
output administratorUsername string = administratorLogin
output authMode string = empty(identityPrincipalId) ? 'password' : 'entra'
output port int = 5432
output database string = 'postgres'
output sslMode string = 'require'
output region string = location
output provider string = dbProvider
