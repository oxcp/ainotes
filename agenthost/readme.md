# OpenClaw Hosting on Azure — Workshop Design Proposal

[Workshop Design Document](./agenthost.md)

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
