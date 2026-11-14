// Provider-specific implementation called by database.bicep; preview access/capacity is required.
targetScope = 'resourceGroup'

@description('Use the location of the existing Module-01 resource group.')
param location string = resourceGroup().location

param clusterName string
param administratorLogin string = 'studioadmin'
param identityPrincipalId string = ''
param identityName string = ''
param identityTenantId string = tenant().tenantId
@description('Set by the deployment script after verifying the existing cluster. Never replay a creation PUT on retries.')
param reuseCluster bool = false

@secure()
@minLength(8)
@maxLength(128)
param administratorLoginPassword string

@minValue(2)
@maxValue(96)
param vCores int = 2

@description('Workshop public access: all IPv4 addresses by default. Restrict these rules outside the workshop.')
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

// Allowlisting permits CREATE EXTENSION vector; application migration installs it in postgres.
resource vectorParameters 'Microsoft.HorizonDb/parameterGroups@2026-05-01-preview' = {
  name: '${clusterName}-vector'
  location: location
  tags: { module: 'module-06' }
  properties: {
    pgVersion: 17
    description: 'Product Launch Studio vector extension allowlist'
    applyImmediately: true
    parameters: [
      { name: 'azure.extensions', value: 'vector' }
    ]
  }
}

resource cluster 'Microsoft.HorizonDb/clusters@2026-05-01-preview' = if (!reuseCluster) {
  name: clusterName
  location: location
  tags: { module: 'module-06' }
  properties: {
    createMode: 'Create'
    version: '17'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    authConfig: {
      passwordAuth: 'Enabled'
      entraIdAuth: empty(identityPrincipalId) ? 'Disabled' : 'Enabled'
      tenantId: identityTenantId
    }
    vCores: vCores
    replicaCount: 1
    zonePlacementPolicy: 'BestEffort'
  }
}

// deploy-database.sh attaches/verifies the parameter group using PATCH after ARM.
// deploy-database.sh creates/verifies the Entra administrator via REST after ARM succeeds.
// The preview administrator PUT can return an empty body that ARM treats as a deployment failure.

// HorizonDB creates DefaultPool with the cluster; existing references it instead of creating another pool.
resource pool 'Microsoft.HorizonDb/clusters/pools@2026-05-01-preview' existing = {
  // The parent creation resource is skipped when reusing a cluster.
  #disable-next-line use-parent-property
  name: '${clusterName}/DefaultPool'
}

// HorizonDB firewall rules belong to the pool, unlike Flexible Server's server-level rules.
resource rules 'Microsoft.HorizonDb/clusters/pools/firewallRules@2026-05-01-preview' = [
  for rule in firewallRules: {
    parent: pool
    name: rule.name
    dependsOn: [
      cluster
    ]
    properties: {
      startIpAddress: rule.startIpAddress
      endIpAddress: rule.endIpAddress
      description: 'Module-06 workshop database access'
    }
  }
]

// Return the service FQDN, not a guessed hostname; password and application schema are not outputs.
output resourceId string = resourceId('Microsoft.HorizonDb/clusters', clusterName)
output provider string = 'horizondb'
// A second cluster symbol, even "existing", emits a duplicate ARM resource with symbolic-name codegen.
#disable-next-line use-resource-symbol-reference
output endpoint string = reuseCluster ? reference(resourceId('Microsoft.HorizonDb/clusters', clusterName), '2026-05-01-preview').fullyQualifiedDomainName : cluster!.properties.fullyQualifiedDomainName
output port int = 5432
output database string = 'postgres'
output username string = empty(identityPrincipalId) ? administratorLogin : identityName
output administratorUsername string = administratorLogin
output authMode string = empty(identityPrincipalId) ? 'password' : 'entra'
output sslMode string = 'require'
output region string = location
