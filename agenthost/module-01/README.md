# Module 1 — Core Infrastructure Setup (30 min)

[⬆ Back to Workshop Home](../readme.md)

## Overview

Provision the shared Azure infrastructure used by all three agent hosting solutions:

- Resource Group
- Azure Blob Storage
- Azure API Management
- Azure Key Vault
- Azure Container Registry
- Entra ID App Registration
- User-Assigned Managed Identity
- Microsoft Foundry (AIServices) account

The Foundry account ships with:

- A project
- A `gpt-5.4-mini` model deployment
- Defender for AI
- Two RAI content-safety policies
- The APIM AI gateway that fronts its inference endpoint
- An APIM Basic v2 instance that is eligible for Foundry AI Gateway association

## Learning Objectives

- Deploy shared Azure infrastructure using Bicep IaC
- Configure APIM with a `validate-jwt` policy and Azure OpenAI backend
- Register an Entra ID application and create a User-Assigned Managed Identity
- Create a Foundry resource named `foundry-agenthost-<deploymentSN>` with the project `maf-agent-prj`
- Deploy `gpt-5.4-mini` (capacity 50) and enable Defender for AI
- Apply the `Microsoft.Default` and `Microsoft.DefaultV2` RAI policies
- Expose Foundry inference through APIM as an AI gateway (backend + RBAC + API/policy)

---

## Prerequisites

> **Note:** Run all commands in this README from this module's root directory (`agenthost/module-01/`).

- Complete the [common workshop prerequisites](../readme.md#prerequisites-before-workshop).
- `curl` installed
- `jq` installed
- Permission to create role assignments (`Microsoft.Authorization/roleAssignments/write`) for the resources deployed by this module. Typical options are **Owner**, or **Contributor** plus **Role Based Access Control Administrator**.

---

## Step 1 — Set Environment Variables

```bash
export RESOURCE_GROUP="rg-agenthost-workshop"
export LOCATION="eastus2"
```

---

## Step 2 — Deploy Infrastructure via Bicep

Deploy everything with a **single command** by using the wrapper script (recommended). The script calls `az deployment sub create` on `main.bicep`, generates the deployment suffix for you, and prints the outputs:

```bash
chmod +x setup.sh
./setup.sh
```

> Before running `setup.sh`, you can optionally override parameters in `main.bicep` as needed.

Or run the equivalent Bicep deployment manually:

```bash
export SN=$(openssl rand -hex 3); echo $SN

az deployment sub create \
  --name "main-$SN" \
  --location "$LOCATION" \
  --template-file main.bicep \
  --parameters \
      resourceGroupName="$RESOURCE_GROUP" \
      location="$LOCATION" \
      deploymentSN="$SN"

```
> The Bicep deployment, whether run directly or through `setup.sh`, may take several minutes to complete. After a successful deployment, you will see output similar to the following:
```
==> Deployment 'main-****' complete. Outputs:
{
  "acrLoginServer": {
    "type": "String",
    "value": "acragenthost****.azurecr.io"
  },
  "acrName": {
    "type": "String",
    "value": "acragenthost****"
  },
  "apimFoundryBackendName": {
    "type": "String",
    "value": "foundry-backend"
  },
  "apimFoundryGatewayUrl": {
    "type": "String",
    "value": "https://apim-agenthost-****.azure-api.net/foundry"
  },
  "apimServiceUrl": {
    "type": "String",
    "value": "https://apim-agenthost-****.azure-api.net"
  },
  "deploymentStatus": {
    "type": "Object",
    "value": {
      "acr": "Succeeded",
      "apim": "Succeeded",
      "foundryAccount": "Succeeded",
      "foundryModel": "Succeeded",
      "foundryProject": "Succeeded",
      "keyVault": "Succeeded",
      "storage": "Succeeded"
    }
  },
  "foundryProjectEndpoint": {
    "type": "String",
    "value": "https://foundry-agenthost-****.services.ai.azure.com/api/projects/maf-agent-prj"
  },
  "foundryProjectId": {
    "type": "String",
    "value": "/subscriptions/********-****-****-****-************/resourceGroups/rg-agenthost-workshop/providers/Microsoft.CognitiveServices/accounts/foundry-agenthost-****/projects/maf-agent-prj"
  },
  "foundryProjectName": {
    "type": "String",
    "value": "maf-agent-prj"
  },
  "foundryResourceName": {
    "type": "String",
    "value": "foundry-agenthost-****"
  },
  "identityClientId": {
    "type": "String",
    "value": "********-****-****-****-************"
  },
  "keyVaultName": {
    "type": "String",
    "value": "kv-agenthost-****"
  },
  "keyVaultUri": {
    "type": "String",
    "value": "https://kv-agenthost-****.vault.azure.net/"
  },
  "modelDeploymentName": {
    "type": "String",
    "value": "gpt-5.4-mini"
  },
  "resourceGroupName": {
    "type": "String",
    "value": "rg-agenthost-workshop"
  },
  "storageAccountName": {
    "type": "String",
    "value": "stcagenthost****"
  }
}

Next: proceed to module-02 to deploy the hosted agent with azd.
```

> [!NOTE]
> **This part is for your reference to understand what are deployed:**
>
>1. **Foundry account** `foundry-agenthost-<deploymentSN>` (kind `AIServices`, `disableLocalAuth: true`) with the project `maf-agent-prj`, the `gpt-5.4-mini` deployment (GlobalStandard, capacity 50), and Defender for AI.
>2. **APIM** `apim-agenthost-<deploymentSN>` is created on the **Basic v2** tier.
>3. **Backend** `foundry-backend` points to the Foundry project endpoint.
>4. **RBAC** grants **Cognitive Services OpenAI User** and **Azure AI User** to the APIM system-assigned managed identity and the module-01 UAMI. Because the Foundry account sets `disableLocalAuth: true`, APIM uses its system-assigned managed identity to obtain an Entra ID token when calling Foundry.
>5. **API** `workshop-ai-gateway` (path `/foundry`) provides the `responses` (`POST /openai/v1/responses`) and `get-response` (`GET /responses/{response-id}`) operations. Its API-level policy validates the caller's Entra ID token with `validate-jwt`, routes the request to the backend, and authenticates to Foundry through `authentication-managed-identity` using the `https://ai.azure.com` resource.

After the template deployment, you can retrieve the key outputs whenver you need:
```bash
az deployment sub show \
  --name main-$SN \
  --query "properties.outputs.{endpoint:foundryProjectEndpoint.value, model:modelDeploymentName.value, gateway:apimFoundryGatewayUrl.value, backend:apimFoundryBackendName.value}"
```

---

## Step 3 — Verify APIM as a standalone gateway

Call the model through the gateway by using the `apimFoundryGatewayUrl` output. The caller sends its own Entra ID token; APIM validates the token and forwards the request to Foundry using its managed identity:

```bash
export SN=$(az group show --resource-group "$RESOURCE_GROUP" --query "tags.deploymentSN" --output tsv 2>/dev/null | tr -d "\r\n" || echo "")

export ACCESSTOKEN=$(az account get-access-token --query accessToken -o tsv | tr -d '\r\n')

curl -s -X POST \
  "https://apim-agenthost-${SN}.azure-api.net/foundry/openai/v1/responses" \
  -H "Authorization: Bearer $ACCESSTOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model":"gpt-5.4-mini",
    "input":"Hello through the APIM AI gateway"
  }' \
| jq -r '.output'

```
You should see output similar to the following:
```
[
  {
    "type": "message",
    "id": "msg_094f276e62fae6ff006a5afcf4c690819685e624b6211a6c2d",
    "response_id": "resp_094f276e62fae6ff006a5afcf47f2081968f90d4187a8cb827",
    "phase": "final_answer",
    "role": "assistant",
    "content": [
      {
        "type": "output_text",
        "text": "Hello! I’m here and ready to help through the APIM AI gateway. What can I do for you today?",
        "annotations": [],
        "logprobs": []
      }
    ],
    "status": "completed"
  }
]
```

This response confirms that the deployed APIM instance can operate as a standalone gateway: it validates agent requests and forwards authorized requests to the Foundry backend.

---

## Step 4 — Add APIM to the Foundry project as a native AI gateway

In module-02, agents run as Foundry hosted agents. They can access the project models through either of the following routing modes:

| APIM operating mode | Call flow |
|---|---|
| Standalone gateway | Agent → APIM → Foundry project endpoint → Foundry project models |
| Foundry native AI gateway | Agent → Foundry project endpoint → Foundry native AI gateway (APIM) → Foundry project models |

> **Tip:**
>
> Because Foundry hosted agents run within the Foundry project, they can use the project's trust context to access its model endpoints. You do not need to assign the `Foundry User` role separately to every hosted-agent identity, which simplifies access management.
>
> In module-03 and module-04, agents run outside Foundry in AKS or Azure Container Apps Sandboxes. Calling the Foundry project endpoint directly would require each external agent identity to have the `Foundry User` role, which increases administrative overhead and can introduce security concerns at scale. A more manageable approach is to use a centrally governed APIM instance: APIM validates each agent token through its `validate-jwt` policy and forwards authorized requests to Foundry using its own managed identity.
>
> Module-02 demonstrates both modes. Modules 03 and 04 use the standalone gateway mode.

To configure APIM as the Foundry project's native AI gateway, complete the following steps manually:

1. Open **AI Gateway**.
2. Select **Add AI Gateway**.
3. Under **AI Foundry resource**, select the Foundry project created in the previous step, `foundry-agenthost-<deploymentSN>`, from the drop-down list.
4. Choose **Use existing**.
5. Select the deployed APIM `apim-agenthost-<deploymentSN>` instance, then click **Add**.
6. Open the gateway entry and verify that the Foundry project is automatically added to the gateway.
![module-01-AIGW-added](../pic/module-01-AIGW-added.png)
7. Open the APIM instance in the Azure portal and verify that a new API was added automatically:
![module-01-AIGW-added-APIM-API-added](../pic/module-01-AIGW-added-APIM-API-added.png)

---

## Files in This Module

| File | Description |
|---|---|
| `setup.sh` | One-step wrapper that runs the `main.bicep` subscription deployment (`az deployment sub create`) and prints the outputs |
| `main.bicep` | Bicep subscription-scoped entry point (creates Resource Group, calls core.bicep) |
| `core.bicep` | Bicep IaC template for all shared Azure resources (Storage, APIM Basic v2, Key Vault, ACR, UAMI) **and** the Foundry stack (account, project, `gpt-5.4-mini`, Defender for AI, APIM AI gateway) |

---

## Outputs

| Output | Description |
|---|---|
| `storageAccountName`, `apimServiceUrl`, `identityClientId`, `keyVaultName`, `keyVaultUri`, `acrName`, `acrLoginServer` | Core shared-resource coordinates |
| `foundryResourceName` | Foundry account name (`foundry-agenthost-<suffix>`) |
| `foundryProjectName` / `foundryProjectId` / `foundryProjectEndpoint` | Foundry project identifiers (project endpoint consumed by module-02) |
| `modelDeploymentName` | Deployed model name (`gpt-5.4-mini`) |
| `apimFoundryBackendName` | APIM backend name (`foundry-backend`) |
| `apimFoundryGatewayUrl` | APIM AI gateway URL for Foundry inference |

---

## Next Step

Proceed to [Module 2 — Solution A: Foundry Hosted Agent](../module-02/README.md) to deploy the hosted agent with `azd` against the Foundry project provisioned here.

---

[⬆ Back to Workshop Home](../readme.md)
