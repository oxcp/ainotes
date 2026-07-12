// aca.bicep — Module 3: Legacy standard ACA Container App reference
// Deploys a standard Azure Container Apps (ACA) container environment and app.
// This is NOT Azure Container Apps Sandboxes (Microsoft.App/SandboxGroups);
// it's the traditional managed container service with configurable compute tiers.
// Current module mapping is:
//   - Solution A: Sandboxes (sandbox.bicep + sandbox-deploy.sh)
//   - Solution B: Dynamic Sessions (dynamic-session-deploy.sh)
//
// This solution provides:
//   - Standard ACA with D4 compute tier
//   - Scale-to-zero for cost efficiency
//   - Reuses existing resources from module-01:
//       * Resource Group (rg-agenthost-<SN>)
//       * User-Assigned Managed Identity (id-agenthost-<SN>)
//       * Azure Container Registry (acragenthost<SN>)
//       * Redis (redis-agenthost-<SN>) — optional, for state persistence
//       * Storage Account (stcagenthost<SN>) — optional, for backup state
// See sandbox.bicep for true Azure Container Apps Sandboxes (gVisor isolation, suspend/resume)
//
// Usage: az deployment group create \
//   --resource-group <rg-name> \
//   --template-file aca.bicep \
//   --parameters \
//       location=<loc> \
//       deploymentSN=<SN> \
//       acrName=<acr-name-with-SN> \
//       identityId=<identity-resource-id> \
//       identityClientId=<client-id> \
//       imageTag=<image-tag>

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
@description('Agent container port (default: 8088 for Responses protocol)')
param containerPort int = 8088

// Optional parameters for state persistence (Redis + Storage)
@description('Redis name with SN suffix (e.g., "redis-agenthostabc123")')
param redisName string = ''
@description('Storage account name with SN suffix (e.g., "stcagenthostabc123")')
param storageAccountName string = ''
@description('Whether to enable Redis state backend (default: false)')
param enableRedisBackend bool = false

// ── Construct resource names ─────────────────────────────────────────────────
var acaEnvName = 'aca-env-agenthost-${deploymentSN}'
var acaAppName = 'agent-host-${deploymentSN}'

// ── Reference existing ACR ──────────────────────────────────────────────────
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// ── Reference existing Redis (if enabled) ────────────────────────────────────
resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' existing = if (enableRedisBackend && !empty(redisName)) {
  name: redisName
}

// ── Reference existing Storage (if enabled) ──────────────────────────────────
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = if (!empty(storageAccountName)) {
  name: storageAccountName
}

// ── ACA Environment with Sandbox workload profile ────────────────────────────
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: acaEnvName
  location: location
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
      {
        // Sandbox workload profile: gVisor OS-level isolation (Public Preview)
        // Suitable for long-running, stateful workloads with scale-to-zero
        name: 'sandbox'
        workloadProfileType: 'D4'
        minimumCount: 0
        maximumCount: 10
      }
    ]
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
  }
}

// ── ACA Container App (Sandbox-isolated, scale-to-zero) ──────────────────────
resource acaApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: acaAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'sandbox'
    configuration: {
      ingress: {
        external: true
        targetPort: containerPort
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: identityId
        }
      ]
      secrets: concat(
        // Redis connection (if enabled)
        enableRedisBackend && !empty(redisName) ? [
          {
            name: 'redis-connection-string'
            value: 'TODO_SET_REDIS_CONN_AT_RUNTIME'  // Set via deployment script
          }
        ] : [],
        // Storage account key (if enabled)
        !empty(storageAccountName) ? [
          {
            name: 'storage-account-key'
            value: 'TODO_SET_STORAGE_KEY_AT_RUNTIME'  // Set via deployment script
          }
        ] : []
      )
    }
    template: {
      containers: [
        {
          name: 'agent'
          image: '${acr.properties.loginServer}/${imageUri}:${imageTag}'
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: concat(
            // Core agent environment
            [
              {
                name: 'PORT'
                value: string(containerPort)
              }
              {
                name: 'AZURE_CLIENT_ID'
                value: identityClientId
              }
              {
                name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
                value: ''  // Optional: set via deployment or app configuration
              }
            ],
            // Redis state backend (if enabled)
            enableRedisBackend && !empty(redisName) ? [
              {
                name: 'REDIS_HOST'
                value: redis.properties.hostName
              }
              {
                name: 'REDIS_PORT'
                value: '6380'
              }
              {
                name: 'REDIS_CONNECTION_STRING'
                secretRef: 'redis-connection-string'
              }
            ] : [],
            // Storage backend (if enabled)
            !empty(storageAccountName) ? [
              {
                name: 'STORAGE_ACCOUNT_NAME'
                value: storage.name
              }
              {
                name: 'STORAGE_ACCOUNT_KEY'
                secretRef: 'storage-account-key'
              }
              {
                name: 'STORAGE_CONTAINER_NAME'
                value: 'agent-state'
              }
            ] : []
          )
          // Health probe for scale-to-zero detection
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: containerPort
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 10
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
      // Grace period allows lifecycle-hook to flush state to Blob on eviction
      terminationGracePeriodSeconds: 60
    }
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output acaEnvName string = acaEnv.name
output acaEnvId string = acaEnv.id
output acaAppName string = acaApp.name
output acaAppId string = acaApp.id
output acaAppFqdn string = acaApp.properties.configuration.ingress.fqdn
output acaAppUri string = 'https://${acaApp.properties.configuration.ingress.fqdn}'
