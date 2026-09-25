# Agent Hosting on Azure Workshop

## Workshop Introduction

This workshop introduces a practical Azure agent-hosting journey. You start with shared infrastructure, compare three deployment options for enterprise and consumer scenarios, and finish with cost and production-hardening guidance.

<!-- > 📊 **Prefer slides?** 
>
> Open [introduction](https://oxcp.github.io/ainotes/agenthost/module-00/) to walkthrough the workshop content. -->

> [!TIP]
> For a better reading and navigation experience—use [Agent Hosting on Azure Workshop Guide](https://oxcp.github.io/ainotes/markdown-viewer.html?file=agenthost/readme.md).

---

## Workshop Outline

- **Target Scenarios**: ToB enterprise and ToC consumer scenarios, each with different priorities for isolation, scale, authentication, and cost.
- **Solutions (see [Workshop Introduction](./module-00/README.md) for details)**:
  - **Solution A**: Azure AI Foundry Hosted Agent (ToB managed) — fastest on-ramp, native state and authentication, strong governance and security.
  - **Solution B**: AKS + agent-sandbox (ToB / ToC) — high customization: meet enterprise-specific technical requirements for ToB, or tune cost and performance for ToC.
  - **Solution C**: ACA container runtime options (ToC / ToB):
    - **Workshop path**: ACA Sandboxes — service-managed sandbox isolation (micro-VM boundary), suspend/resume.
    - **Optional learning track**: ACA Dynamic Sessions — Hyper-V isolated session pools for low-latency ephemeral execution.
- **Implemented Features**: state persistence, scale-to-zero, isolation, Entra ID authentication, and AI Gateway integration.
- **Workshop Schedule**: A 120-minute hands-on workshop covering core infrastructure setup, the three solutions above, and a wrap-up with cost-optimization tips and a production-hardening checklist.

## How to use this workshop

1. Create a local directory to store the workshop files, for example, `myworkshop`, and enter it:

  ```bash
  mkdir myworkshop
  cd myworkshop
  ```

2. Clone the repository using sparse checkout, enter the generated `ainotes` directory, and check out the `agenthost` directory:

  ```bash
  git clone --depth 1 --filter=blob:none --sparse https://github.com/oxcp/ainotes/
  cd ainotes
  git sparse-checkout set agenthost
  ```

This downloads the content required for the `agenthost` workshop.

---

## Prerequisites (before workshop)

- Linux console or WSL environment or Azure Cloud Shell for running workshop scripts and commands. In most cases, the Azure Cloud Shell has the minimum pre-requisites gap, however consider the Azure Cloud Shell may timeout when you leave, a Linux console or WSL environment is still recommended.
- Azure permissions to create the workshop resources and role assignments at subscription scope, including `Microsoft.Authorization/roleAssignments/write`. Typical options are **Owner**, or **Contributor** plus **Role Based Access Control Administrator**.
- Azure CLI `2.80.0+` installed, with an active Azure login (`az login`)
- Other prerequisites listed in each module

> To verify the prerequisites automatically instead of checking them manually, use `check-prerequisites.sh` in the workshop folder.

Before starting the workshop, run the prerequisite checker from the `agenthost` directory:

```bash
cd agenthost
chmod +x check-prerequisites.sh
bash check-prerequisites.sh
```

The checker groups the results by module, clearly identifies passed and failed requirements, and provides a remediation link for each failed check.

The output will look similar to the following:
> [!TIP]
> The example below shows how the checker identifies unmet prerequisites and recommends next steps.

```text
Agent Hosting on Azure Workshop - Prerequisite Check
------
[01/14] Checking Azure CLI 2.80.0+...
[02/14] Checking active Azure login...
[03/14] Checking workshop deployment permissions...
[04/14] Checking curl installation...
[05/14] Checking jq installation...
[06/14] Checking Azure Developer CLI installation...
[07/14] Checking active azd login...
[08/14] Checking Microsoft Foundry azd extension...
[09/14] Checking Foundry User role...
[10/14] Checking kubectl installation...
[11/14] Checking ACR remote build permissions...
[12/14] Checking Azure CLI support for AKS Pod Sandboxing...
[13/14] Checking Container Apps preview extension...
[14/14] Checking Container Apps SandboxGroup Data Owner role...

Common prerequisites for all modules
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Azure CLI 2.80.0+                        | Pass       | Installed: 2.85.0
Active Azure login                       | Pass       | <subscription-name> (<subscription-id>)
Workshop deployment permissions          | Pass       | All 26 required ARM actions are allowed

Module 01
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
curl installed                           | Pass       | Installed: 8.15.0
jq installed                             | Pass       | Installed: 1.8.1

Module 02
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Azure Developer CLI installed            | Pass       | Installed: 1.27.0
Active azd login                         | Pass       | azd authentication is active
Microsoft Foundry azd extension          | Pass       | microsoft.foundry is installed
Foundry User role                        | Failed     | Role assignment not found for the current subscription

Fix suggestion:
- Foundry User role: https://learn.microsoft.com/azure/ai-foundry/concepts/rbac-azure-ai-foundry

Module 03
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
kubectl installed                        | Pass       | Installed: v1.35.0
ACR remote build permissions             | Skipped    | No container registry was found in rg-agenthost-workshop; check again after deploying Module 01
Azure CLI for AKS Pod Sandboxing         | Pass       | Installed: 2.85.0

Module 04
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Container Apps preview extension         | Pass       | containerapp 1.3.0b4 (preview enabled)
SandboxGroup Data Owner role             | Failed     | Role assignment not found for the current subscription

Fix suggestion:
- SandboxGroup Data Owner role: https://learn.microsoft.com/azure/container-apps/sandboxes

Summary: 11 passed, 1 skipped, 2 failed
Workshop readiness: Ready to start.
Module notice: Resolve the failed Module 02 prerequisite(s) before starting that module.
Module notice: Resolve the failed Module 04 prerequisite(s) before starting that module.
Module notice: Re-run this check after Module 01 to validate the skipped ACR permission before Module 03.
```
> [!TIP]
> 1. If **Common prerequisites for all modules** and **Module 01** contain no failed checks, the script reports `Workshop readiness: Ready to start`, and you can begin the workshop.
> 2. Failed checks under **Module 02** through **Module 04** do not prevent you from starting the workshop. Follow the reported details and fix suggestions, then run `check-prerequisites.sh` again before starting the corresponding module. Begin that module only after all of its prerequisites are satisfied.
> 3. Before the workshop starts, Azure Container Registry has not yet been deployed, so `check-prerequisites.sh` reports the **ACR remote build permissions** check as `Skipped`. Run the checker again after completing Module 01 to verify these permissions. Module 03 uses `az acr build`. Assigning **Contributor** at the registry scope is sufficient for the build and image push operations.
> 4. **Module 03** and **Module 04** share the same Azure Container Registry and container image. Therefore, a deployed and accessible ACR is a prerequisite for both Module 03 and Module 04, even though the ACR permission check is displayed under Module 03.

If the "Workshop deployment permissions" check finds that any actions required for workshop deployment are not permitted, the checker lists each missing ARM action, as shown below:

```text
Missing 2 required ARM action(s); see the list below

Fix suggestion:
- Missing ARM action: Microsoft.Authorization/roleAssignments/write
- Missing ARM action: Microsoft.ContainerService/managedClusters/write
- Permission guidance: https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal-subscription-admin
```

---


## Workshop Modules

| Module | Topic | Duration | Purpose |
|---|---|---|---|
| [module-00](./module-00/README.md) | Introduction | 10 min | Understand the target scenarios, agent state pattern, and the three hosting solutions. |
| [module-01](./module-01/README.md) | Core Infrastructure Setup | 20 min | Deploy the shared Azure infrastructure used by all hosting solutions. |
| [module-02](./module-02/README.md) | Solution A: Foundry Hosted Agent | 30 min | Deploy a managed Foundry hosted agent with native state, authentication, governance, and AI Gateway integration. |
| [module-03](./module-03/README.md) | Solution B: AKS + agent-sandbox | 40 min | Deploy a customizable agent runtime on AKS with sandbox isolation, persistent state, and workload identity. |
| [module-04](./module-04/README.md) | Solution C: ACA Sandboxes (workshop path) | 30 min | Deploy an agent in ACA Sandboxes with micro-VM isolation and suspend/resume, and explore Dynamic Sessions as an optional track. |
| [module-05](./module-05/README.md) | Wrap-up and Q&A | 5 min | Compare the solutions and review selection guidance, cost optimization, and production-hardening recommendations. |

**Total workshop duration:** 135 minutes. **Hands-on exercises (Modules 01–04):** 120 minutes.

---

## Workshop structure
```
agenthost/
├── readme.md                    ← List workshop modules, structure
├── agenthost.md                 ← Design considerations for the workshop
├── check-prerequisites.sh       ← Checks tools, Azure login state, extensions, and required RBAC roles
├── module-00/
│   └── README.md                ← Introduction: agent overview, state pattern, 3 solutions
├── module-01/
│   ├── README.md                ← Core infrastructure setup steps
│   ├── setup.sh                 ← One-step wrapper: runs the main.bicep deployment (az deployment sub create)
│   ├── main.bicep               ← Subscription-scoped Bicep entry point
│   └── core.bicep               ← Resource group Bicep (Storage, APIM, UAMI, Foundry account + project + model + Defender + AI gateway)
├── module-02/
│   ├── README.md                ← Foundry hosted-agent azd deployment steps
│   ├── azure.yaml               ← Hosted-agent manifest used by azd init (references agent-src)
│   ├── ai-gateway-inbound-policy.xml ← APIM inbound policy for the AI gateway (gateway mode)
│   └── agent-src/               ← Agent Framework app source (main.py, requirements.txt, Dockerfile)
├── module-03/
│   ├── README.md                ← AKS + agent-sandbox preparation, deployment, verification, and architecture notes
│   ├── prepare-agent-sandbox.sh ← Prepares AKS, Kata node pool, controller, secrets, Blob CSI storage, and Sandbox manifest
│   ├── aks.bicep                ← Baseline AKS, Blob CSI, Workload Identity federation, and application UAMI Blob RBAC
│   ├── aks-kubelet-rbac.bicep   ← Principal-keyed AcrPull and Blob CSI RBAC for the AKS kubelet identity
│   ├── deploy-storage-private-link.sh ← Optional wrapper: deploys Blob Private Link for AKS private access
│   ├── storage-private-link.bicep ← Optional Bicep template for Blob Private Endpoint and Private DNS wiring
│   ├── agent-storage.yaml.example ← Blob CSI StorageClass, static PV, and PVC template
│   ├── agent-sandbox.yaml.example ← Sandbox, Workload Identity service account, volume mount, and Service template
│   └── agent-src/               ← POC agent image source (build context for the shared agent image)
│       ├── app/                 ← Agent application package (main.py, ...)
│       ├── Dockerfile           ← Multi-stage Python image (build context = agent-src/)
│       ├── requirements.txt     ← Python dependencies
│       ├── lifecycle-hook.sh    ← SIGTERM pre-stop hook: state already durable in Blob (no-op log)
│       └── README.md            ← agent-src usage notes
├── module-04/
│   ├── README.md                ← Workshop path: ACA Sandboxes; optional track: Dynamic Sessions
│   ├── sandbox.bicep            ← Workshop path: SandboxGroup (real Sandboxes, micro-VM boundary, suspend/resume) + UAMI AcrPull role
│   ├── sandbox-deploy.sh        ← Workshop path: reuses the Module-03 image + SandboxGroup + disk image + sandbox mgmt
│   ├── dynamic-session-deploy.sh← Optional track: Session pool deployment (custom container)
│   ├── dynamic-session-invoke.sh← Optional track: Minimal invoke example for session pool endpoint
│   └── container-app.yaml       ← Legacy standard ACA manifest (reference only)
└── module-05/
    └── README.md                ← Comparison recap, decision guide, cost tips, prod checklist
```

---
