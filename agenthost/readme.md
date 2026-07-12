# Agent Hosting on Azure Workshop

## Workshop Outline

- **Target Scenarios**: ToB Enterprise vs. ToC Consumer scenarios with distinct priorities for isolation, scale, auth, and cost.
- **Solutions (see [Workshop Design](./agenthost.md) for detail)**:
  - **Solution A**: Azure AI Foundry Host Agent (ToB managed) — fastest on-ramp, native state & auth.
  - **Solution B**: ACA container runtime options (Module-03):
    - **Workshop path**: ACA Sandboxes — gVisor isolation, suspend/resume.
    - **Optional advanced track**: ACA Dynamic Sessions — session pool based, low-latency ephemeral execution.
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
| [module-00](./module-00/README.md) | Introduction | 10 min | README |
| [module-01](./module-01/README.md) | Core Infrastructure Setup | 30 min | README · setup.sh · main.bicep · core.bicep |
| [module-02](./module-02/README.md) | Solution A: Foundry Hosted Agent | 30 min | README · azure.yaml · src/ (main.py, requirements.txt, Dockerfile) · agent-definition.json |
| [module-03](./module-03/README.md) | Solution B: ACA Sandboxes (workshop path) + Dynamic Sessions (optional) | 30 min | README · sandbox.bicep · sandbox-deploy.sh · dynamic-session-deploy.sh · dynamic-session-invoke.sh · Dockerfile |
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
│   ├── setup.sh                 ← One-step wrapper: runs the main.bicep deployment (az deployment sub create)
│   ├── main.bicep               ← Subscription-scoped Bicep entry point
│   └── core.bicep               ← Resource group Bicep (Redis, Storage, APIM, UAMI, Foundry account + project + model + Defender + AI gateway)
├── module-02/
│   ├── README.md                ← Foundry hosted-agent azd deployment steps
│   ├── azure.yaml               ← Hosted-agent manifest used by azd init (references agent-src)
│   └── agent-src/               ← Agent Framework app source + config (main.py, requirements.txt, Dockerfile, .env.example)
├── module-03/
│   ├── README.md                ← Workshop path: ACA Sandboxes; optional track: Dynamic Sessions
│   ├── sandbox.bicep            ← Workshop path: SandboxGroup (real Sandboxes, gVisor, suspend/resume)
│   ├── sandbox-deploy.sh        ← Workshop path: SandboxGroup + disk image + sandbox instance mgmt
│   ├── dynamic-session-deploy.sh← Optional track: Session pool deployment (custom container)
│   ├── dynamic-session-invoke.sh← Optional track: Minimal invoke example for session pool endpoint
│   ├── Dockerfile               ← Multi-stage Python image for both solutions
│   └── pic/                      ← Shared workshop images
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

- **Module-03 Solutions**: 
  - **Workshop path (ACA Sandboxes)**: Use `sandbox-deploy.sh` for OS-level isolation and suspend/resume.
  - **Optional advanced track (Dynamic Sessions)**: Use `dynamic-session-deploy.sh` for low-latency ephemeral session pools — not required to complete the workshop.
  - See [Module 3 README](./module-03/README.md) for detailed comparison and decision guide.

- **Correction Note**: Earlier versions confused ACA workload profiles with true Azure Container Apps Sandboxes (Microsoft.App/SandboxGroups). The workshop path is ACA Sandboxes; Dynamic Sessions is an optional exploration track.

- **KEDA ScaledObject** (module-04) provides both HTTP-based and Redis list-based scaling triggers with a 30-minute cooldown, scaling `agent-host` to zero on idle.

- **Kata Container RuntimeClass** is defined in `agent-deployment.yaml` and applied to the agent workload node pool (tainted `kata=true:NoSchedule`).

- **APIM XML policies** in modules 01 and 02 apply `validate-jwt`, `rate-limit-by-key`, retry with exponential back-off, and response caching.
