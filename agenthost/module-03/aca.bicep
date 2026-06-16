// aca.bicep — Module 3: ACA Sandbox deployment
// Deploys Azure Container Apps Environment (with Sandbox workload profile),
// and an ACA Container App for the OpenClaw agent.

param location string
param acrName string
param acaEnvName string
param acaAppName string
param identityId string
param identityClientId string
@secure()
param redisConnectionString string
param storageAccountName string
param apimEndpoint string
param imageTag string = 'latest'

// ── Reference existing storage ────────────────────────────────────────────────
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
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
        // Sandbox workload profile for gVisor OS-level isolation (Public Preview)
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
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        {
          server: '${acrName}.azurecr.io'
          identity: identityId
        }
      ]
      secrets: [
        {
          name: 'redis-conn'
          value: redisConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'openclaw-agent'
          image: '${acrName}.azurecr.io/openclaw-agent:${imageTag}'
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: [
            {
              name: 'OPENCLAW_STATE_BACKEND'
              value: 'redis'
            }
            {
              name: 'OPENCLAW_REDIS_CONNECTION'
              secretRef: 'redis-conn'
            }
            {
              name: 'OPENCLAW_BLOB_CONTAINER'
              value: 'openclaw-state'
            }
            {
              name: 'OPENCLAW_STORAGE_ACCOUNT'
              value: storageAccountName
            }
            {
              name: 'OPENCLAW_APIM_ENDPOINT'
              value: apimEndpoint
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: identityClientId
            }
          ]
          // Lifecycle hook: flush state to Blob on scale-to-zero
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: 8080
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
      // Termination grace period allows lifecycle-hook.sh to flush state
      terminationGracePeriodSeconds: 60
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output acaEnvId string = acaEnv.id
output acaAppFqdn string = acaApp.properties.configuration.ingress.fqdn
