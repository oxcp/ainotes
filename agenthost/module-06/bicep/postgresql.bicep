// PostgreSQL implementation with the same connection contract as horizondb.bicep.
targetScope = 'resourceGroup'

@description('Use the location of the existing Module-01 resource group; do not silently change region.')
param location string = resourceGroup().location

@description('Database resource name, shared with the HorizonDB template parameter contract.')
param clusterName string
param administratorLogin string = 'studioadmin'
param identityPrincipalId string = ''
param identityName string = ''
param identityTenantId string = tenant().tenantId

@secure()
@minLength(8)
@maxLength(128)
param administratorLoginPassword string

// This template fixes the tier to GeneralPurpose; select a SKU compatible with that tier and region.
param skuName string = 'Standard_D2ds_v5'

@minValue(32)
@maxValue(65536)
param storageSizeGB int = 32

@description('Workshop public IPv4 access. Restrict these rules outside the workshop.')
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

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: clusterName
  location: location
  tags: { module: 'module-06' }
  sku: {
    name: skuName
    tier: 'GeneralPurpose'
  }
  properties: {
    createMode: 'Default'
    version: '17'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    authConfig: {
      activeDirectoryAuth: empty(identityPrincipalId) ? 'Disabled' : 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: identityTenantId
    }
    storage: {
      storageSizeGB: storageSizeGB
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    // Workshop cost/simplicity defaults, not a production availability or private-network baseline.
    highAvailability: { mode: 'Disabled' }
    network: { publicNetworkAccess: 'Enabled' }
  }
}

// ARM creates the actual database principal; a management-plane role assignment cannot grant SQL access.
// https://learn.microsoft.com/azure/templates/microsoft.dbforpostgresql/2024-08-01/flexibleservers/administrators
resource entraAdministrator 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = if (!empty(identityPrincipalId)) {
  parent: server
  name: identityPrincipalId
  properties: {
    principalName: identityName
    principalType: 'ServicePrincipal'
    tenantId: identityTenantId
  }
}

// Allowlisting does not install pgvector; the application migration runs CREATE EXTENSION vector.
resource vectorAllowlist 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: 'vector'
    source: 'user-override'
  }
}

// Enforce TLS on the service as well as requiring SSL in the Agent connection settings.
resource secureTransport 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'require_secure_transport'
  properties: {
    value: 'on'
    source: 'user-override'
  }
  // Serialize configuration updates on the same server.
  dependsOn: [vectorAllowlist]
}

resource rules 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = [
  for rule in firewallRules: {
    parent: server
    name: rule.name
    properties: {
      startIpAddress: rule.startIpAddress
      endIpAddress: rule.endIpAddress
    }
  }
]

// The service creates postgres; application migrations create vector and the shared schema.
output resourceId string = server.id
output provider string = 'postgresql'
output endpoint string = server.properties.fullyQualifiedDomainName
output port int = 5432
output database string = 'postgres'
output username string = empty(identityPrincipalId) ? administratorLogin : identityName
output administratorUsername string = administratorLogin
output authMode string = empty(identityPrincipalId) ? 'password' : 'entra'
output sslMode string = 'require'
output region string = location
