targetScope = 'resourceGroup'

param location string
param foundryLocation string
param amrLocation string
param clusterName string
param agentIdentityName string
param projectName string
param modelName string
param modelVersion string
param modelDeploymentName string
param modelCapacity int
param embeddingModelName string
param embeddingModelVersion string
param embeddingDeploymentName string
param embeddingCapacity int
param semanticCacheThreshold string
param semanticCacheTtl int
param apimPublisherEmail string
param apimPublisherName string

var suffix = uniqueString(resourceGroup().id, clusterName)
var projectEndpoint = 'https://${foundry.name}.services.ai.azure.com/api/projects/${projectName}'
var openAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var labTags = {
  purpose: 'aks-agent-sandbox-lab'
}

resource agentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: agentIdentityName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2026-03-01' = {
  name: 'foundry-sbox-${suffix}'
  location: foundryLocation
  tags: labTags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: 'foundry-sbox-${suffix}'
    allowProjectManagement: true
    defaultProject: projectName
    associatedProjects: [projectName]
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource model 'Microsoft.CognitiveServices/accounts/deployments@2026-03-01' = {
  parent: foundry
  name: modelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-03-01' = {
  parent: foundry
  name: projectName
  location: foundryLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectName
    description: 'AKS Agent Sandbox lab'
  }
  dependsOn: [
    model
    embedding
  ]
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2026-03-01' = {
  parent: foundry
  name: embeddingDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: embeddingCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
  dependsOn: [
    model
  ]
}

resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: 'amr-sbox-${suffix}'
  location: amrLocation
  tags: labTags
  sku: {
    name: 'Balanced_B0'
  }
  properties: {
    highAvailability: 'Enabled'
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: redis
  name: 'default'
  properties: {
    accessKeysAuthentication: 'Enabled'
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'NoCluster'
    evictionPolicy: 'VolatileLRU'
    port: 10000
    modules: [
      {
        name: 'RediSearch'
      }
    ]
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: 'apim-sbox-${suffix}'
  location: location
  tags: labTags
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
  }
}

resource apimOpenAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, apim.id, openAiUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource redisConnection 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'amr-connection-string'
  properties: {
    displayName: 'amr-connection-string'
    secret: true
    value: '${redis.properties.hostName}:${redisDatabase.properties.port},password=${redisDatabase.listKeys().primaryKey},ssl=True,abortConnect=False'
  }
}

resource externalCache 'Microsoft.ApiManagement/service/caches@2024-05-01' = {
  parent: apim
  name: 'default'
  properties: {
    connectionString: '{{amr-connection-string}}'
    resourceId: uri(environment().resourceManager, redis.id)
    description: 'AMR semantic response cache with RediSearch and TLS'
    useFromLocation: 'default'
  }
  dependsOn: [
    redisConnection
  ]
}

resource apimFoundryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, apim.id, foundryUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agentFoundryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, agentIdentity.id, foundryUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: agentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource backend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-backend'
  properties: {
    url: projectEndpoint
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
  dependsOn: [
    project
  ]
}

resource gateway 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'sandbox-ai-gateway'
  properties: {
    displayName: 'Sandbox AI Gateway'
    path: 'foundry'
    protocols: ['https']
    subscriptionRequired: false
    serviceUrl: backend.properties.url
  }
}

resource embeddingsBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-embeddings'
  properties: {
    url: 'https://${foundry.name}.openai.azure.com/openai/deployments/${embedding.name}/embeddings'
    protocol: 'http'
    credentials: {
      query: {
        'api-version': ['2024-02-01']
      }
    }
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
  dependsOn: [
    apimOpenAiRole
  ]
}

resource responses 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: gateway
  name: 'responses'
  properties: {
    displayName: 'Create response'
    method: 'POST'
    urlTemplate: '/openai/v1/responses'
  }
}

resource getResponse 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: gateway
  name: 'get-response'
  properties: {
    displayName: 'Get response'
    method: 'GET'
    urlTemplate: '/openai/v1/responses/{response-id}'
    templateParameters: [
      {
        name: 'response-id'
        type: 'string'
        required: true
      }
    ]
  }
}

resource chatCompletions 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: gateway
  name: 'chat-completions'
  properties: {
    displayName: 'Chat completions'
    method: 'POST'
    urlTemplate: '/openai/v1/chat/completions'
  }
}

var policyTemplate = '''
<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized">
      <openid-config url="__LOGIN_ENDPOINT____TENANT_ID__/v2.0/.well-known/openid-configuration" />
      <issuers>
        <issuer>https://sts.windows.net/__TENANT_ID__/</issuer>
        <issuer>__LOGIN_ENDPOINT____TENANT_ID__/v2.0</issuer>
      </issuers>
      <required-claims>
        <claim name="oid" match="all">
          <value>__AGENT_PRINCIPAL_ID__</value>
        </claim>
      </required-claims>
    </validate-jwt>
    <set-variable name="model-request-required" value="@(false)" />
    <set-variable name="cache-eligible" value='@{
      if (context.Request.Method != "POST" || (context.Operation.Id != "responses" &amp;&amp; context.Operation.Id != "chat-completions")) { return false; }
      var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
      if ((bool?)body["stream"] == true || body["previous_response_id"] != null || body["tools"] != null) { return false; }
      var input = body["input"] ?? body["messages"];
      if (input == null) { return false; }
      if (input.Type == JTokenType.String) { return true; }
      var messages = input as JArray;
      if (messages == null || messages.Count == 0) { return false; }
      var last = messages.Last as JObject;
      if (last == null || (string)last["role"] != "user") { return false; }
      var content = last["content"];
      if (content == null) { return false; }
      if (content.Type == JTokenType.String) { return true; }
      var parts = content as JArray;
      return parts != null &amp;&amp; parts.Count &gt; 0 &amp;&amp; parts.All(p =&gt; p is JObject &amp;&amp; ((string)p["type"] == "text" || (string)p["type"] == "input_text"));
    }' />
    <choose>
      <when condition='@(context.Variables.GetValueOrDefault&lt;bool&gt;("cache-eligible"))'>
        <set-variable name="cache-partition" value='@{
          var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
          var input = body["input"] ?? body["messages"];
          if (input.Type == JTokenType.String) { body.Remove("input"); }
          else { ((JObject)((JArray)input).Last).Remove("content"); }
          return Convert.ToBase64String(System.Security.Cryptography.SHA256.Create().ComputeHash(System.Text.Encoding.UTF8.GetBytes(body.ToString(Newtonsoft.Json.Formatting.None))));
        }' />
        <llm-semantic-cache-lookup score-threshold="__CACHE_THRESHOLD__" embeddings-backend-id="foundry-embeddings" embeddings-backend-auth="system-assigned" ignore-system-messages="false" max-message-count="12">
          <vary-by>__TENANT_ID__:__AGENT_PRINCIPAL_ID__</vary-by>
          <vary-by>@(context.Api.Id + ":" + context.Operation.Id)</vary-by>
          <vary-by>__EMBEDDING_VERSION__</vary-by>
          <vary-by>@(context.Variables.GetValueOrDefault&lt;string&gt;("cache-partition"))</vary-by>
        </llm-semantic-cache-lookup>
      </when>
    </choose>
    <rate-limit-by-key calls="60" renewal-period="60" counter-key="__AGENT_PRINCIPAL_ID__" />
    <set-variable name="model-request-required" value="@(true)" />
    <set-backend-service backend-id="foundry-backend" />
    <authentication-managed-identity resource="https://ai.azure.com" />
  </inbound>
  <backend><base /></backend>
  <outbound>
    <base />
    <choose>
      <when condition='@(context.Variables.GetValueOrDefault&lt;bool&gt;("cache-eligible") &amp;&amp; context.Variables.GetValueOrDefault&lt;bool&gt;("model-request-required"))'>
        <llm-semantic-cache-store duration="__CACHE_TTL__" />
      </when>
    </choose>
    <choose>
      <when condition='@(context.Response.StatusCode == 200 &amp;&amp; context.Request.Method == "POST" &amp;&amp; (context.Operation.Id == "responses" || context.Operation.Id == "chat-completions"))'>
        <set-header name="X-AI-Gateway-Response-Source" exists-action="override">
          <value>@(context.Variables.GetValueOrDefault&lt;bool&gt;("model-request-required") ? "generated" : "amr-cache-hit")</value>
        </set-header>
      </when>
      <otherwise>
        <set-header name="X-AI-Gateway-Response-Source" exists-action="delete" />
      </otherwise>
    </choose>
  </outbound>
  <on-error>
    <base />
    <set-header name="X-AI-Gateway-Response-Source" exists-action="delete" />
  </on-error>
</policies>
'''
var policyWithTenant = replace(policyTemplate, '__TENANT_ID__', tenant().tenantId)
var policyWithLogin = replace(policyWithTenant, '__LOGIN_ENDPOINT__', environment().authentication.loginEndpoint)
var policyWithThreshold = replace(policyWithLogin, '__CACHE_THRESHOLD__', semanticCacheThreshold)
var policyWithTtl = replace(policyWithThreshold, '__CACHE_TTL__', string(semanticCacheTtl))
var policyWithEmbedding = replace(policyWithTtl, '__EMBEDDING_VERSION__', '${embeddingDeploymentName}:${embeddingModelName}:${embeddingModelVersion}')

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: gateway
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(policyWithEmbedding, '__AGENT_PRINCIPAL_ID__', agentIdentity.properties.principalId)
  }
  dependsOn: [
    externalCache
    embeddingsBackend
    apimFoundryRole
  ]
}

output apimName string = apim.name
output apimGatewayUrl string = '${apim.properties.gatewayUrl}/foundry'
output foundryProjectEndpoint string = projectEndpoint
output modelDeploymentName string = model.name
output embeddingDeploymentName string = embedding.name
output redisName string = redis.name
