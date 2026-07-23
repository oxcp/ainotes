# Agent Hosting on Azure Workshop

## Workshop Outline

- **Target Scenarios**: ToB Enterprise vs. ToC Consumer scenarios with distinct priorities for isolation, scale, auth, and cost.
- **Solutions (see [Workshop Design](./agenthost.md) for detail)**:
  - **Solution A**: Azure AI Foundry Host Agent (ToB managed) — fastest on-ramp, native state & auth, strong governance & security.
  - **Solution B**: AKS + agent-sandbox (ToB / ToC) — high customisation: for ToB, meet enterprise-specific technical requirements; for ToC, tune cost and performance.
  - **Solution C**: ACA container runtime options (ToC / ToB):
    - **Workshop path**: ACA Sandboxes — service-managed sandbox isolation (micro-VM boundary), suspend/resume.
    - **Optional learning track**: ACA Dynamic Sessions — Hyper-V isolated session pools for low-latency ephemeral execution.
- **Implemented Features**: state persistence, fast-satrt, scale-to-zero, isolation, Entra ID auth, and AI Gateway integration.
- **Workshop Schedule**: 120-minute hands-on covering core infra setup, above solutions, and wrap-up with tips on cost optimisation and production hardening checklist.

**Refer to**[ Workshop Design](./agenthost.md)

---

## Prerequisites (before workshop)

- Azure subscription with Contributor access
- Azure CLI installed (`az login` completed)
- Others (see detail in each individual module)

---

## Workshop Modules

| Module | Topic | Duration | Files |
|---|---|---|---|
| [module-00](./module-00/README.md) | Introduction | 10 min | README |
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
├── agenthost.md                 ← Design consideration for the workshop
├── module-00/
│   └── README.md                ← Introduction: agent overview, state pattern, 3 solutions
├── module-01/
│   ├── README.md                ← Core infra setup steps
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
