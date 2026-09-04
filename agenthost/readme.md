# Agent Hosting on Azure Workshop

## Workshop Introduction

This workshop introduces a practical Azure agent-hosting journey. You start with shared infrastructure, compare three deployment options for enterprise and consumer scenarios, and finish with cost and production-hardening guidance.

> 📊 **Prefer slides?** 
>
> Open [introduction](https://oxcp.github.io/ainotes/agenthost/module-00/) to walkthrough the workshop content.

---

## Workshop Outline

- **Target Scenarios**: ToB enterprise and ToC consumer scenarios, each with different priorities for isolation, scale, authentication, and cost.
- **Solutions (see [Workshop Design](./agenthost.md) for details)**:
  - **Solution A**: Azure AI Foundry Hosted Agent (ToB managed) — fastest on-ramp, native state and authentication, strong governance and security.
  - **Solution B**: AKS + agent-sandbox (ToB / ToC) — high customization: meet enterprise-specific technical requirements for ToB, or tune cost and performance for ToC.
  - **Solution C**: ACA container runtime options (ToC / ToB):
    - **Workshop path**: ACA Sandboxes — service-managed sandbox isolation (micro-VM boundary), suspend/resume.
    - **Optional learning track**: ACA Dynamic Sessions — Hyper-V isolated session pools for low-latency ephemeral execution.
- **Implemented Features**: state persistence, fast start, scale-to-zero, isolation, Entra ID authentication, and AI Gateway integration.
- **Workshop Schedule**: A 120-minute hands-on workshop covering core infrastructure setup, the three solutions above, and a wrap-up with cost-optimization tips and a production-hardening checklist.


## Prerequisites (before workshop)

- Linux console or WSL environment for running workshop scripts and commands
- Azure subscription with Contributor access
- Azure CLI `2.80.0+` installed, with an active Azure login (`az login`)
- Other prerequisites listed in each module

> If you need a quick checker helps you instead of manual work, you can use the `check-prerequisites.sh` in the workshop folder.

From the `agenthost` directory, run the prerequisite checker before starting the workshop:

```bash
chmod +x check-prerequisites.sh
bash check-prerequisites.sh
```

The checker groups results by module, displays passed and failed requirements, and provides a remediation link for each failed check.

You will see check result like below:

```text
Agent Hosting on Azure Workshop - Prerequisite Check
------
[01/12] Checking Azure CLI 2.80.0+...
[02/12] Checking active Azure login...
[03/12] Checking subscription Contributor access...
[04/12] Checking Azure Developer CLI installation...
[05/12] Checking active azd login...
[06/12] Checking Microsoft Foundry azd extension...
[07/12] Checking Foundry User role...
[08/12] Checking kubectl installation...
[09/12] Checking Docker installation...
[10/12] Checking Azure CLI support for AKS Pod Sandboxing...
[11/12] Checking Container Apps preview extension...
[12/12] Checking Container Apps SandboxGroup Data Owner role...

Module 01 and common prerequisites for all modules
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Azure CLI 2.80.0+                        | Pass       | Installed: 2.85.0
Active Azure login                       | Pass       | kacai_internal (c14f0d46-cae2-4c8e-b9ff-b73f094caa96)
Subscription Contributor access          | Pass       | Contributor or Owner assignment found

Module 02
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Azure Developer CLI installed            | Pass       | Installed: 1.27.0
Active azd login                         | Pass       | azd authentication is active
Microsoft Foundry azd extension          | Pass       | microsoft.foundry is installed
Foundry User role                        | Pass       | Role assignment found for the current subscription

Module 03
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
kubectl installed                        | Pass       | Installed: v1.35.0
Docker installed and running             | Failed     | Docker version: not detected; CLI is not installed or not available
Azure CLI for AKS Pod Sandboxing         | Pass       | Installed: 2.85.0

Fix suggestion:
- Docker installed and running: https://docs.docker.com/engine/install/

Module 04
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Container Apps preview extension         | Pass       | containerapp 1.3.0b4 (preview enabled)
SandboxGroup Data Owner role             | Pass       | Role assignment found for the current subscription

Summary: 11 passed, 1 failed
```
If there are failed checked items, please follow the corresponding fix suggestion to resolve it.

---

## How to use this workshop

1. Create a local directory to store the workshop files, for example, `myworkshop`, and enter it:

  ```bash
  mkdir myworkshop
  cd myworkshop
  ```

2. Clone the repository using sparse checkout:

  ```bash
  git clone --depth 1 --filter=blob:none --sparse https://github.com/oxcp/ainotes/
  ```

3. Enter the generated `ainotes` subdirectory:

  ```bash
  cd ainotes
  ```

4. Check out the `agenthost` directory:

  ```bash
  git sparse-checkout set agenthost
  ```

This downloads the content required for the `agenthost` workshop instead of checking out the entire repository.

---

## Workshop Modules

| Module | Topic | Duration | Files |
|---|---|---|---|
| [module-00](./module-00/README.md) | Introduction | 10 min | README · slides |
| [module-01](./module-01/README.md) | Core Infrastructure Setup | 30 min | README · setup.sh · main.bicep · core.bicep |
| [module-02](./module-02/README.md) | Solution A: Foundry Hosted Agent | 30 min | README · azure.yaml · src/ (main.py, requirements.txt, Dockerfile) · agent-definition.json |
| [module-03](./module-03/README.md) | Solution B: AKS + agent-sandbox | 40 min | README · deploy.sh · aks.bicep · agent-sandbox.yaml · Dockerfile |
| [module-04](./module-04/README.md) | Solution C: ACA Sandboxes (workshop path) | 20 min | README · sandbox.bicep · sandbox-deploy.sh · dynamic-session-deploy.sh · dynamic-session-invoke.sh |
| [module-05](./module-05/README.md) | Wrap-up and Q&A | 5 min | README |

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
│   ├── README.md                ← AKS + agent-sandbox deployment steps + architecture notes
│   ├── deploy.sh                ← AKS, agent-sandbox Helm install, K8s secrets, Sandbox deploy
│   ├── aks.bicep                ← AKS with Kata Container node pool + Workload Identity (reuses Module 1)
│   ├── deploy-storage-private-link.sh ← Optional wrapper: deploys Blob Private Link for AKS private access
│   ├── storage-private-link.bicep ← Optional Bicep template for Blob Private Endpoint and Private DNS wiring
│   ├── agent-sandbox.yaml.example ← Template for agent-sandbox.yaml (copy and fill in placeholders)
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

## Tips

- **Bicep IaC** — module-01 uses a subscription-scoped `main.bicep` that delegates to `core.bicep` (resource group scope); modules 02–04 each have self-contained deployment Bicep files targeting their respective Azure resources.

- **agent-sandbox** (module-03) provides the `Sandbox` CRD + controller (kubernetes-sigs) for isolated, stateful, singleton agent pods with stable identity and lifecycle (pause / resume / hibernate) — the scale-to-zero mechanism, replacing the earlier E2B Manager + KEDA.

- **Kata Container RuntimeClass** is defined in `agent-sandbox.yaml` and applied to the Sandbox pod on the tainted `kata=true:NoSchedule` node pool.

- **Module-04 Solutions**:
  - **Workshop path (ACA Sandboxes)**: Use `sandbox-deploy.sh` for service-managed sandbox isolation (micro-VM boundary) and suspend/resume.
  - **Optional learning track (Dynamic Sessions)**: Use `dynamic-session-deploy.sh` for low-latency ephemeral session pools — not required to complete the workshop.
  - See [Module 4 README](./module-04/README.md) for detailed comparison and decision guide.
