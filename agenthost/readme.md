# Agent Hosting on Azure Workshop

## Workshop Outline

- **Target Scenarios**: ToB Enterprise vs. ToC Consumer scenarios with distinct priorities for isolation, scale, auth, and cost.
- **Solutions (see [Workshop Design](./agenthost.md) for detail)**:
  - **Solution A**: Azure AI Foundry Host Agent (ToB managed) — fastest on-ramp, native state & auth.
  - **Solution B**: ACA Sandbox (ToC/ToB long-running agents) — OS-level gVisor isolation, true serverless, public preview.
  - **Solution C**: AKS + E2B (ToB high-security) — maximum control, Kata Container micro-VMs, custom networking.
- **Implemented Features**: state persistence, fast-satrt, scale-to-zero, isolation, Entra ID auth, and AI Gateway integration.
- **Workshop Schedule**: 120-minute hands-on covering core infra setup, above solutions, and wrap-up with tips on cost optimisation and production hardening checklist.

**Refer to**[ Workshop Design](./agenthost.md)

---

## Prerequisites (before workshop)

- Azure subscription with Contributor access
- Azure CLI installed (`az login` completed)
- Docker Desktop (for local image building & testing)
- VS Code + Azure Container Apps extension

---

## Workshop Modules

| Module | Topic | Duration | Files |
|---|---|---|---|
| [module-00](./module-00/README.md) | Introduction | 5 min | README |
| [module-01](./module-01/README.md) | Core Infrastructure Setup | 30 min | README · setup.sh · main.bicep · core.bicep · apim-policy.xml · apim-api-policy.bicep · foundry-apim-policy.xml |
| [module-02](./module-02/README.md) | Solution A: Foundry Hosted Agent | 20 min | README · azure.yaml · src/ (main.py, requirements.txt, Dockerfile) · agent-definition.json |
| [module-03](./module-03/README.md) | Solution B: ACA Sandbox | 30 min | README · deploy.sh · aca.bicep · Dockerfile · container-app.yaml · lifecycle-hook.sh |
| [module-04](./module-04/README.md) | Solution C: AKS + E2B | 30 min | README · deploy.sh · aks.bicep · e2b-manager.yaml · agent-deployment.yaml · keda-scaledobject.yaml · Dockerfile |
| [module-05](./module-05/README.md) | Wrap-up and Q&A | 5 min | README |

---

## Workshop structure
```
agenthost/
├── readme.md                    ← List workshop modules, structure
├── agenthost.md                 ← Design consideration for the workshop
├── module-00/
│   └── README.md                ← Introduction: agent overview, state pattern, 3 solutions
├── module-01/
│   ├── README.md                ← Core infra setup steps
│   ├── setup.sh                 ← Azure CLI bash script (RG, Redis, Blob, APIM, Entra ID, UAMI, Foundry stack)
│   ├── main.bicep               ← Subscription-scoped Bicep entry point
│   ├── core.bicep               ← Resource group Bicep (Redis, Storage, APIM, UAMI, Foundry account + project + model + Defender + RAI + AI gateway)
│   ├── apim-api-policy.bicep    ← APIM LLM API + policy deployment
│   ├── apim-policy.xml          ← APIM: validate-jwt, rate-limit, retry, Azure OpenAI backend
│   └── foundry-apim-policy.xml  ← Reference APIM policy for the Foundry AI gateway
├── module-02/
│   ├── README.md                ← Foundry hosted-agent azd deployment steps
│   ├── azure.yaml               ← Hosted-agent manifest used by azd init
│   └── src/maf-agent/           ← Agent Framework app (main.py, requirements.txt, Dockerfile)
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
│   ├── agent-deployment.yaml    ← K8s Deployment with Kata RuntimeClass + NetworkPolicy
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

- **KEDA ScaledObject** (module-04) provides both HTTP-based and Redis list-based scaling triggers with a 30-minute cooldown, scaling `agent-host` to zero on idle.

- **Kata Container RuntimeClass** is defined in `agent-deployment.yaml` and applied to the agent workload node pool (tainted `kata=true:NoSchedule`).

- **APIM XML policies** in modules 01 and 02 apply `validate-jwt`, `rate-limit-by-key`, retry with exponential back-off, and response caching.
