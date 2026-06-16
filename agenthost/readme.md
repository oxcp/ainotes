# OpenClaw Hosting on Azure Workshop

## Workshop Outline

- **Target Scenarios**: Two deployment profiles (ToB Enterprise vs. ToC Consumer) with distinct priorities for isolation, scale, auth, and cost.
- **Hosting Techniques**: Options compared across isolation, cold-start, cost efficiency, and Azure fit.
- **Solutions Selected**:
  - **Solution A**: Azure AI Foundry Host Agent (ToB managed) — fastest on-ramp, native state & auth.
  - **Solution B**: ACA Sandbox (ToC/ToB long-running agents) — OS-level gVisor isolation, true serverless, public preview.
  - **Solution C**: AKS + E2B (ToB high-security) — maximum control, Kata Container micro-VMs, custom networking.
- **Implemented Features**: Requirement mapping across state persistence, scale-to-zero, isolation, auth, and AI Gateway integration.
- **Technical Considerations**: State persistence design (AMR hot / Blob cold), fast-start optimisation, Entra ID auth architecture, APIM AI Gateway pattern.
- **Architectures & Workflows**: Architecture diagrams and step-by-step flows for each solution.
- **Workshop Schedule**: 120-minute hands-on covering core infra setup, all selected solutions, and wrap-up with cost-saving levers.
- **Cost Saving Consideration**： Cost saving approaches with fittable solutions

**Refer to**[ Workshop Design](./agenthost.md)

---

## Prerequisites (before workshop)

- Azure subscription with Contributor access
- Azure CLI installed (`az login` completed)
- Docker Desktop (for local image testing)
- VS Code + Azure Container Apps extension

---

## Workshop Modules

| Module | Topic | Duration | Files |
|---|---|---|---|
| [module-00](./module-00/README.md) | Introduction | 10 min | README |
| [module-01](./module-01/README.md) | Core Infrastructure Setup | 20 min | README · setup.sh · main.bicep · core.bicep · apim-policy.xml |
| [module-02](./module-02/README.md) | Solution A: Foundry Host Agent | 20 min | README · deploy.sh · foundry.bicep · agent-definition.json · apim-policy.xml |
| [module-03](./module-03/README.md) | Solution B: ACA Sandbox | 30 min | README · deploy.sh · aca.bicep · Dockerfile · container-app.yaml · lifecycle-hook.sh |
| [module-04](./module-04/README.md) | Solution C: AKS + E2B | 30 min | README · deploy.sh · aks.bicep · e2b-manager.yaml · openclaw-deployment.yaml · keda-scaledobject.yaml · Dockerfile |
| [module-05](./module-05/README.md) | Wrap-up and Q&A | 10 min | README |

---

## Workshop structure
```
agenthost/
├── readme.md                    ← List workshop modules, structure
├── agenthost.md                 ← Design consideration for the workshop
├── module-00/
│   └── README.md                ← Introduction: OpenClaw overview, state pattern, 3 solutions
├── module-01/
│   ├── README.md                ← Core infra setup steps
│   ├── setup.sh                 ← Azure CLI bash script (RG, Redis, Blob, APIM, Entra ID, UAMI)
│   ├── main.bicep               ← Subscription-scoped Bicep entry point
│   ├── core.bicep               ← Resource group Bicep (Redis, Storage, APIM, UAMI, backend)
│   └── apim-policy.xml          ← APIM: validate-jwt, rate-limit, retry, Azure OpenAI backend
├── module-02/
│   ├── README.md                ← Foundry Host Agent deployment steps
│   ├── deploy.sh                ← Key Vault, Foundry Hub/Project, UAMI role assignments
│   ├── foundry.bicep            ← Azure AI Foundry Hub + Project Bicep
│   ├── agent-definition.json   ← OpenClaw agent spec (state store, UAMI, LLM backend)
│   └── apim-policy.xml          ← APIM policy with caching for Foundry backend
├── module-03/
│   ├── README.md                ← ACA Sandbox deployment steps + comparison table
│   ├── deploy.sh                ← ACR, image build/push, ACA Environment + App deployment
│   ├── aca.bicep                ← ACA Environment (Sandbox workload profile) + Container App
│   ├── Dockerfile               ← Multi-stage Python image with lifecycle hook
│   ├── container-app.yaml       ← ACA YAML manifest (Key Vault secret reference)
│   └── lifecycle-hook.sh        ← Scale-to-zero: flushes Redis state to Blob on SIGTERM
├── module-04/
│   ├── README.md                ← AKS + E2B deployment steps + architecture notes
│   ├── deploy.sh                ← AKS, KEDA Helm install, K8s secrets, workload deployment
│   ├── aks.bicep                ← AKS with Kata Container node pool + Workload Identity
│   ├── e2b-manager.yaml         ← K8s Deployment/Service/RBAC for E2B Sandbox Manager
│   ├── openclaw-deployment.yaml ← K8s Deployment with Kata RuntimeClass + NetworkPolicy
│   ├── keda-scaledobject.yaml   ← KEDA HTTP + Redis ScaledObject (30 min idle → 0 replicas)
│   ├── Dockerfile               ← Multi-stage Python image (same pattern as module-03)
│   └── lifecycle-hook.sh        ← Copy of lifecycle hook for module-04 build context
└── module-05/
    └── README.md                ← Comparison recap, decision guide, cost tips, prod checklist
```

---

## Tips
- **Bicep IaC** — module-01 uses a subscription-scoped `main.bicep` that delegates to `core.bicep` (resource group scope); modules 02–04 each have self-contained deployment Bicep files targeting their respective Azure resources.

- **Scale-to-zero lifecycle hook** — `lifecycle-hook.sh` (module-03, copied into module-04 build context) runs on SIGTERM, exporting agent state from Redis to Blob Storage before the container stops — implementing the AMR-first/Blob-fallback pattern described in the design doc.

- **KEDA ScaledObject** (module-04) provides both HTTP-based and Redis list-based scaling triggers with a 30-minute cooldown, scaling `openclaw-agent` to zero on idle.

- **Kata Container RuntimeClass** is defined in `openclaw-deployment.yaml` and applied to the agent workload node pool (tainted `kata=true:NoSchedule`).

- **APIM XML policies** in modules 01 and 02 apply `validate-jwt`, `rate-limit-by-key`, retry with exponential back-off, and response caching.
