# Agent Hosting on Azure Workshop

> 🌐 语言 / Language: **English** | [中文](README_CN.md)

## Workshop Introduction

This workshop takes you on a practical Azure agent-hosting journey:
- Core section: Start with shared infrastructure, compare and practice three deployment options for enterprise and consumer scenarios, and finish with cost and production-hardening guidance.
- Extended section: Combine the agent deployment experience gained in the **core section** with hands-on practice in multi-agent orchestration, agent communication, vector storage and retrieval to build complete simulated business workflows.

<!-- > 📊 **Prefer slides?**
>
> Open [introduction](https://oxcp.github.io/ainotes/agenthost/module-00/) to walkthrough the workshop content. -->

> [!TIP]
> For a better reading and navigation experience—use [Agent Hosting on Azure Workshop Guide](https://oxcp.github.io/ainotes/markdown-viewer.html?file=agenthost/readme.md).

---

## Workshop Outline

### Core section:

- **Target Scenarios**: ToB enterprise and ToC consumer scenarios, each with different priorities for isolation, scale, authentication, and cost.
- **Solutions (see [Workshop Introduction](./module-00/README.md) for details)**:
  - **Solution A**: Azure AI Foundry Hosted Agent (ToB managed) — fastest on-ramp, native state and authentication, strong governance and security.
  - **Solution B**: AKS + agent-sandbox (ToB / ToC) — high customization: meet enterprise-specific technical requirements for ToB, or tune cost and performance for ToC.
  - **Solution C**: ACA container runtime options (ToC / ToB):
    - **Workshop path**: ACA Sandboxes — service-managed sandbox isolation (micro-VM boundary), suspend/resume.
    <!-- - **Optional learning track**: ACA Dynamic Sessions — Hyper-V isolated session pools for low-latency ephemeral execution. -->
- **Implemented Features**: state persistence, scale-to-zero, isolation, Entra ID authentication, and AI Gateway integration.

### Extended section:

- **[Module 06: Multi-Agent Business Scenarios](./module-06/readme.md)**: Host five agents simultaneously, using A2A inter-agent communication and LangGraph orchestration to coordinate them in simulated business scenarios, including data processing, enterprise knowledge bases, business analysis and planning.
- Choose **Azure HorizonDB** (default) or **Azure Database for PostgreSQL Flexible Server** for structured data and vector storage and retrieval.

## Prerequisites (before workshop)

Choose one of the following ways to prepare an environment for running workshop scripts and commands:

1. **Use your existing environment**, such as a Linux console or WSL.
2. **Deploy a console VM** if you prefer not to set up an environment and tools yourself. Use the [console VM template](./az-toolbox-vm/README.md) for one-click deployment of a console VM with the tools required to run the workshop.
3. **Azure Cloud Shell**.

> [!TIP]
> - If you do not have a regular hands-on environment, choose option 2, **Deploy a console VM**, to quickly prepare a console VM with the required tools preinstalled. The VM incurs additional Azure resource costs.
> - Azure Cloud Shell includes most tools required for this workshop, but the `aca` CLI needed for Module 06 may still require separate installation. Idle sessions expire; session variables and transient installations may be lost, while files on configured persistent storage can survive.

The following checklist covers the prerequisites required by each workshop exercise module:

| Area | Requirement |
|---|---|
| Common / Module 01 | Linux/WSL, Bash 4+, Azure CLI 2.80.0+, active Azure login, the 26 ARM actions required for workshop deployment, `git`, `curl`, `jq` and Bicep 0.48.1+. |
| Module 02 | Azure Developer CLI (`azd`), active azd login, the `microsoft.foundry` extension and Foundry User role. |
| Module 03 | `kubectl`, ACR remote build/push permissions and Azure CLI support for AKS Pod Sandboxing. |
| Module 04 | Container Apps preview extension and Container Apps SandboxGroup Data Owner role; reuse the ACR/image from Module 03. |
| Module 06 | Reuse the tools prepared for earlier modules, adding the `aca` CLI, ACA authentication, `openssl` and GNU coreutils `timeout`. |

Regardless of which environment you use, it must satisfy the prerequisites for running the workshop. Run `check-prerequisites.sh` as shown below to check the installation status of the required tools and other prerequisites.

Sign in to your working environment and download the prerequisite checker, `check-prerequisites.sh`, from the workshop's GitHub repository to a local file:

```bash
curl -fsSL https://raw.githubusercontent.com/oxcp/ainotes/main/agenthost/check-prerequisites.sh -o check-prerequisites.sh
```
> [!TIP]
> If curl is not installed yet, open the URL above in a browser, copy the contents of `check-prerequisites.sh`, and save them to a local file named `check-prerequisites.sh` in the working environment you signed in to.

Run the checker to see the tool installation status and other prerequisite check results:

> [!TIP]
> If you copied the contents of `check-prerequisites.sh` from a browser, you may need to convert Windows CRLF (\r\n) line endings to Linux LF (\n).

```bash
sed -i 's/\r$//' check-prerequisites.sh # Run only if Windows CRLF (\r\n) line endings need to be converted to Linux LF (\n)
chmod +x check-prerequisites.sh
bash check-prerequisites.sh
```

The checker groups results by module, clearly identifies satisfied and unmet requirements, and provides remediation links for each failed check.

The output will look similar to the following:
> [!TIP]
> The example below illustrates how the checker identifies unmet prerequisites and suggests next steps.

```text
Agent Hosting on Azure Workshop - Prerequisite Check
------
[01/19] Checking Azure CLI 2.80.0+...
[02/19] Checking active Azure login...
[03/19] Checking workshop deployment permissions...
[04/19] Checking curl installation...
[05/19] Checking jq installation...
[06/19] Checking Bicep 0.48.1+...
[07/19] Checking Azure Developer CLI installation...
[08/19] Checking active azd login...
[09/19] Checking Microsoft Foundry azd extension...
[10/19] Checking Foundry User role...
[11/19] Checking kubectl installation...
[12/19] Checking ACR remote build permissions...
[13/19] Checking Azure CLI support for AKS Pod Sandboxing...
[14/19] Checking Container Apps preview extension...
[15/19] Checking Container Apps SandboxGroup Data Owner role...
[16/19] Checking independent ACA CLI...
[17/19] Checking ACA authentication...
[18/19] Checking OpenSSL installation...
[19/19] Checking GNU timeout installation...

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
Bicep 0.48.1+                            | Pass       | Installed: 0.48.1

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
ACR remote build permissions             | Pass       | All 4 required ACR build and push actions are allowed
Azure CLI for AKS Pod Sandboxing         | Pass       | Installed: 2.85.0

Module 04
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Container Apps preview extension         | Pass       | containerapp 1.3.0b4 (preview enabled)
SandboxGroup Data Owner role             | Pass       | Role assignment found for the current subscription

Module 06
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Independent ACA CLI                      | Pass       | aca 1.0.0-preview.5; required manifest/disk commands available
ACA authentication                       | Pass       | aca authentication is active; guest identity still needs separate configuration
OpenSSL installed                        | Pass       | OpenSSL 3.0.0
GNU timeout installed                    | Pass       | timeout (GNU coreutils) 9.4

Summary: 19 passed, 0 skipped, 0 failed
Workshop readiness: Ready to start.
Module 06: follow its guide to reuse earlier resources; this checker does not repeat resource discovery or permission checks for that module.
Preflight does not verify secrets, model/Blob calls or live Agent health. Follow the Module 06 deployment and business-flow checks.
```
> [!TIP]
> 1. If **Common prerequisites for all modules** and **Module 01** contain no failed checks, the script reports `Workshop readiness: Ready to start`, and you can begin the workshop.
> 2. In default mode, failures in **Modules 02–04 or 06** do not prevent starting Module 01.
> 3. Before the workshop starts, Azure Container Registry has not yet been deployed, so `check-prerequisites.sh` reports the **ACR remote build permissions** check as `Skipped`. Run the checker again after completing Module 01 to verify these permissions. Module 03 uses `az acr build`. Assigning **Contributor** at the registry scope is sufficient for the build and image push operations.
> 4. **Module 03** and **Module 04** share the same Azure Container Registry and container image. Therefore, a deployed and accessible ACR is a shared prerequisite for Module 03 and Module 04.
> 5. **Module 06** must reuse the ACR used by **Module 03** and **Module 04**, but uploads newly created agent images.

If the "Workshop deployment permissions" check finds that any actions required for workshop deployment are not permitted, the checker lists each missing ARM action, as shown below:

```text
Missing 2 required ARM action(s); see the list below

Fix suggestion:
- Missing ARM action: Microsoft.Authorization/roleAssignments/write
- Missing ARM action: Microsoft.ContainerService/managedClusters/write
- Permission guidance: https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal-subscription-admin
```

---

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
  git sparse-checkout set --no-cone '/agenthost/'
  ```

This downloads the content required for the `agenthost` workshop.

---

## Workshop Modules

| Module | Topic | Duration | Purpose |
|---|---|---|---|
| [module-00](./module-00/README.md) | Introduction | 10 min | Understand the target scenarios, agent state pattern, and the three hosting solutions. |
| [module-01](./module-01/README.md) | Core Infrastructure Setup | 30 min | Deploy the shared Azure infrastructure used by all hosting solutions. |
| [module-02](./module-02/README.md) | Solution A: Foundry Hosted Agent | 30 min | Deploy a managed Foundry hosted agent with native state, authentication, governance, and AI Gateway integration. |
| [module-03](./module-03/README.md) | Solution B: AKS + agent-sandbox | 40 min | Deploy a customizable agent runtime on AKS with sandbox isolation, persistent state, and workload identity. |
| [module-04](./module-04/README.md) | Solution C: ACA Sandboxes (workshop path) | 30 min | Deploy an agent in ACA Sandboxes with micro-VM isolation and suspend/resume.<!-- , and explore Dynamic Sessions as an optional track. --> |
| [module-05](./module-05/README.md) | Wrap-up and Q&A | 5 min | Compare the solutions and review selection guidance, cost optimization, and production-hardening recommendations. |
| [module-06](./module-06/readme.md) | Extended practice: Multi-Agent Business Scenarios | 60 min | Simulate a business scenario: deploy five agents that orchestrate and collaborate to process uploaded business data, then use it for intelligent analysis and planning. |

> [!NOTE]
> - **Core workshop (Modules 00–05)**: 145 minutes, including **hands-on exercises (Modules 01–04)**: 130 minutes.
> - **Module 06: Multi-Agent Business Scenarios**: allow an additional 60 minutes.
> - **Total including Module 06**: 205 minutes (3 hours 25 minutes).

---

## Workshop structure

```text
agenthost/
├── readme.md                    ← Workshop overview, prerequisites, modules, and structure
├── README_CN.md                 ← Chinese workshop guide
├── check-prerequisites.sh       ← Checks tools, Azure login, extensions, permissions, and RBAC roles
├── az-toolbox-vm/
│   ├── README.md                ← Toolbox VM deployment, verification, and troubleshooting guide
│   ├── README_CN.md             ← Chinese toolbox VM guide
│   ├── main.bicep               ← Infrastructure source for the Ubuntu toolbox VM
│   ├── main.json                ← Generated template for Azure Portal custom deployment
│   ├── uiFormDefinition.json    ← Portal form showing credentials for the selected authentication method
│   ├── cloud-init.yaml          ← First-boot setup and unified tool verification
│   ├── .gitattributes           ← File attributes and line-ending rules
│   └── scripts/
│       └── verify-tools.sh      ← Verifies tool versions and user-scoped extensions
├── pic/                         ← Workshop screenshots, including toolbox-vm-deployment.png
├── module-00/
│   ├── .gitignore               ← Excludes the old index.html, slides/ and *notused* files
│   ├── README.md                ← Architecture decisions, scenarios, and solution comparison
│   ├── README_CN.md             ← Chinese introduction guide
│   ├── design.html              ← Interactive workshop design slides
│   ├── design_CN.html           ← Chinese design slides, including the 60-minute Module-06 extension
│   ├── timer-en.html            ← English workshop timer
│   └── timer.html               ← Chinese workshop timer
├── module-01/
│   ├── README.md                ← Core infrastructure setup steps
│   ├── README_CN.md             ← Chinese infrastructure setup guide
│   ├── setup.sh                 ← One-step wrapper: runs the main.bicep deployment (az deployment sub create)
│   ├── main.bicep               ← Subscription-scoped Bicep entry point
│   └── core.bicep               ← Storage, APIM, identities, Foundry project, model, Defender, and AI gateway
├── module-02/
│   ├── README.md                ← Foundry hosted-agent azd deployment steps
│   ├── README_CN.md             ← Chinese hosted-agent deployment guide
│   ├── azure.yaml               ← Hosted-agent manifest used by azd init (references agent-src)
│   ├── ai-gateway-inbound-policy.xml ← APIM inbound policy for the AI gateway (gateway mode)
│   └── agent-src/               ← Agent Framework app source
│       ├── main.py              ← Hosted-agent application entry point
│       ├── requirements.txt     ← Python dependencies
│       ├── Dockerfile           ← Agent container image
│       ├── .azdignore           ← azd packaging exclusions
│       └── .dockerignore        ← Container build exclusions
├── module-03/
│   ├── README.md                ← AKS + agent-sandbox preparation, deployment, verification, and architecture notes
│   ├── README_CN.md             ← Chinese AKS sandbox guide
│   ├── prepare-agent-sandbox.sh ← Prepares AKS, Kata node pool, controller, secrets, Blob CSI storage, and Sandbox manifest
│   ├── aks.bicep                ← Baseline AKS, Blob CSI, Workload Identity federation, and application UAMI Blob RBAC
│   ├── aks-kubelet-rbac.bicep   ← Principal-keyed AcrPull and Blob CSI RBAC for the AKS kubelet identity
│   ├── deploy-storage-private-link.sh ← Optional wrapper: deploys Blob Private Link for AKS private access
│   ├── storage-private-link.bicep ← Optional Bicep template for Blob Private Endpoint and Private DNS wiring
│   ├── agent-storage.yaml.example ← Blob CSI StorageClass, static PV, and PVC template
│   ├── agent-sandbox.yaml.example ← Sandbox, Workload Identity service account, volume mount, and Service template
│   └── agent-src/               ← POC agent image source (build context for the shared agent image)
│       ├── app/
│       │   ├── main.py          ← Agent application entry point
│       │   ├── portal.html      ← Agent chat web interface
│       │   ├── readme.md        ← Application usage notes
│       │   └── .env.example     ← Example application environment variables
│       ├── Dockerfile           ← Multi-stage Python image (build context = agent-src/)
│       ├── requirements.txt     ← Python dependencies
│       ├── lifecycle-hook.sh    ← SIGTERM pre-stop hook: state already durable in Blob (no-op log)
│       ├── README.md            ← agent-src usage notes
│       └── .dockerignore        ← Container build exclusions
├── module-04/
│   ├── README.md                ← Workshop path: ACA Sandboxes
│   ├── README_CN.md             ← Chinese ACA sandbox guide
│   ├── sandbox.bicep            ← Workshop path: SandboxGroup (real Sandboxes, micro-VM boundary, suspend/resume) + UAMI AcrPull role
│   ├── sandbox-deploy.sh        ← Workshop path: reuses the Module-03 image + SandboxGroup + disk image + sandbox mgmt
│   └── container-app.yaml       ← Legacy standard ACA manifest (reference only)
├── module-05/
│   ├── README.md                ← Comparison recap, decision guide, cost tips, and production checklist
│   └── README_CN.md             ← Chinese wrap-up guide
└── module-06/
    ├── readme.md                ← Multi-Agent Business Scenarios: complete installation, deployment, upload/vectorization and chat walkthrough
    ├── readme_CN.md             ← Chinese Multi-Agent Business Scenarios guide
    ├── deploy.sh                ← Direct deployment after automatic preflight checks, common-setting discovery and stage selection
    ├── deploy-storage.sh        ← Private data container only, in existing Module-01 storage; incremental ARM
    ├── deploy-models.sh         ← Deploy embeddings and extend existing APIM routes; existing authorization unchanged
    ├── deploy-database.sh       ← Database validation/provisioning and HorizonDB configuration/admin helpers
    ├── build-images.sh          ← Five remote ACR builds sharing the agent-src build context
    ├── deploy-aca.sh            ← Five-Sandbox configuration, mounts, migration, startup and readiness checks
    ├── cleanup.sh               ← Clears Module-06 resources and generated configuration, preserving Modules 01–04 shared resources
    ├── bicep/
    │   ├── storage.bicep        ← Private data container; existing account/blob service
    │   ├── embedding.bicep      ← Embedding model and APIM operation/backend/policy; no RBAC changes
    │   ├── database.bicep       ← Unified provider choice; no duplicated shared resources
    │   ├── horizondb.bicep      ← HorizonDB backend
    │   └── postgresql.bicep     ← PostgreSQL Flexible Server backend
    ├── common/
    │   ├── aca-config.jq        ← Shared protected five-role configuration validation
    │   ├── cleanup-aca.jq       ← Cleanup ownership and reference checks for sandboxes, disks, snapshots and volumes
    │   ├── cleanup-ownership.sh ← Embedding/APIM child ownership records and cleanup safety checks
    │   └── resolve-identity.sh  ← Resolve Module-01 UAMI IDs for all stages
    ├── sample-data/             ← Actual business samples, outside Agent images
    │   ├── 01_capgemini_consumer_trends_2025-pages-*.pdf ← Capgemini report, 5 parts
    │   ├── 02_ryder_ecommerce_consumer_study_2025-pages-*.pdf ← Ryder report, 5 parts
    │   ├── 03_customer_reviews-rows-*.csv ← Customer reviews, 21 parts
    │   ├── 04_financial_sample-rows-000001-000700.csv ← Financial data, 700 rows
    │   ├── manifest.json        ← Maps parts to originals and page/row ranges; not an upload input
    │   ├── split_samples.py     ← Optional splitter; requires the installed agent-src package
    │   └── raw/                 ← Four unsplit originals; do not upload alongside their parts in one workspace
    │       ├── 01_capgemini_consumer_trends_2025.pdf
    │       ├── 02_ryder_ecommerce_consumer_study_2025.pdf
    │       ├── 03_customer_reviews.csv
    │       └── 04_financial_sample.csv
    └── agent-src/               ← Shared image build context for all five Agents
        ├── README.md            ← English source and runtime guide
        ├── readme_CN.md         ← Chinese source and runtime guide
        ├── pyproject.toml       ← Python dependencies, packaging and development tools
        ├── MANIFEST.in          ← Python source-distribution asset inclusion/exclusion rules
        ├── .dockerignore       ← Docker build-context exclusions
        ├── .env.example        ← Local development environment example; not sandbox deployment configuration
        ├── .gitignore          ← Excludes local environments, credentials and generated files
        ├── .gitattributes      ← Source-file attributes and line-ending rules
        ├── compose.yaml        ← Optional local development Compose configuration
        ├── compose.agents.yaml ← Optional five-Agent local Compose configuration
        ├── chat_agent/         ← Chat UI/API, Dockerfile and bilingual READMEs; static/ contains frontend assets
        ├── orchestrator_agent/ ← LangGraph orchestration, A2A routing, Dockerfile and bilingual READMEs
        ├── data_processing_agent/ ← Extraction/vectorization, Dockerfile and bilingual READMEs
        ├── rag_agent/          ← Vector retrieval, Dockerfile and bilingual READMEs
        ├── sql_agent/          ← Read-only structured queries, Dockerfile and bilingual READMEs
        ├── docs/               ← Eight English/Chinese documentation pairs (16 Markdown files)
        │   ├── architecture*.md ← Architecture and component responsibilities
        │   ├── cli-deployment*.md ← Unified CLI deployment and configuration
        │   ├── data-processing*.md ← Upload, ingestion and vectorization
        │   ├── implementation-report*.md ← Historical implementation/acceptance report
        │   ├── orchestration*.md ← LangGraph planning, A2A collaboration and review
        │   ├── sandbox-deployment*.md ← AKS / ACA deployment paths
        │   ├── security*.md     ← Authentication, data boundaries and operations
        │   └── workshop-guide*.md ← Workshop data and demonstration guide
        ├── shared/             ← Shared Agent configuration, A2A, database, model, storage and chart code
        └── migrations/
            ├── __init__.py
            └── 001_initial.sql ← Initial schema; executed by the migration command in the Orchestrator sandbox

```
