# Azure AI Infrastructure Workshop

Build, run, fine-tune, and scale open AI models on Azure using **AKS with KAITO**, the Azure first-party service **Anyscale on Azure**, and **Azure AI Foundry** (managed compute and partner Models-as-a-Service).

> This repository intentionally does not install a self-managed Anyscale Operator on AKS. The Anyscale track uses Anyscale on Azure as documented on Microsoft Learn.

## Workshop outcomes

Participants will:

- Understand Azure AI infrastructure choices: GPU VM, self-managed AKS, AKS + KAITO, Anyscale on Azure, and Azure AI Foundry.
- Validate subscription access, regional availability, and GPU quota before provisioning.
- Deploy a reusable AKS foundation with Bicep.
- Use KAITO to deploy an open model and call its OpenAI-compatible endpoint.
- Explore a KAITO parameter-efficient fine-tuning workflow.
- Use an existing, provisioned Anyscale on Azure environment.
- Run Ray Data, Ray Serve, and Ray Train workloads through Anyscale on Azure.
- Deploy an open model to Foundry **managed compute** (dedicated GPU endpoint) and consume it.
- Consume a **Fireworks AI** partner model on Foundry as a managed, token-billed endpoint.
- Compare operations, scaling, control, and workload fit.
- Clean up all workshop resources.

## Important product boundary

| Track | Platform responsibility | Student responsibility |
|---|---|---|
| AKS + KAITO | AKS managed add-on simplifies supported AI workloads | Deploy AKS, enable KAITO, create Workspaces, test workloads |
| Anyscale on Azure | Azure-integrated managed Ray platform | Use the provisioned cloud/project, define compute, jobs, services, and code |
| Azure AI Foundry | Managed model deployment (managed compute + partner MaaS) | Deploy from the catalog, consume endpoints, manage lifecycle and cleanup |

The Anyscale exercises do **not** include Helm installation of an Anyscale Operator, custom operator values, or manual construction of Anyscale on AKS.

The **Azure AI Foundry** track (Track C) uses the model catalog's **managed compute** and **partner Models-as-a-Service** options; it does not build a custom serving stack. See `docs/platform-selection-guide.md` for where each track fits.

## Suggested agenda

1. Platform overview and decision framework
2. Lab 00: Preflight
3. Lab 01: Shared AKS foundation
4. Lab 02: KAITO inference
5. Lab 03: KAITO fine-tuning
6. Lab 04: Anyscale on Azure orientation and access validation
7. Lab 05: Ray Data batch processing
8. Lab 06: Ray Serve online service
9. Lab 07: Ray Train distributed training pattern
10. Lab 08: Foundry managed compute
11. Lab 09: Fireworks AI on Foundry
12. Lab 10: Observability and comparison
13. Cleanup

## Repository map

```text
infra/       Shared Azure infrastructure as Bicep
scripts/     Bootstrap, validation, and cleanup helpers
labs/        Student lab guides and workload assets
solutions/   Instructor-oriented completed examples
shared/      Reusable shell and Python helpers
docs/        Architecture, agenda, cost, security, and guidance
```

## Prerequisites

- Azure subscription and permission to deploy resources
- Ability to create role assignments where a lab requires them
- GPU quota in the selected region for the KAITO track
- Access to a provisioned **Anyscale on Azure** cloud and project for the Anyscale track
- Azure CLI, Bicep, kubectl, Helm, Git, Python 3.10+
- Anyscale CLI version approved for your provisioned Anyscale on Azure environment

## Start here

```bash
cp .env.sample .env
./scripts/check-prerequisites.sh
./scripts/check-quota.sh
./scripts/deploy-infra.sh
./scripts/validate-infra.sh
```

Then follow:

- `labs/lab-02-kaito-inference/README.md`
- `labs/lab-04-anyscale-on-azure/README.md`

## Version-sensitive placeholders

This repository uses placeholders such as `<VALIDATED_KAITO_PRESET>`, `<GPU_VM_SIZE>`, and `<ANYSCALE_COMPUTE_CONFIG>`. The instructor must lock these values during workshop preparation because supported regions, quota, model presets, API schemas, and CLI configuration can change.

## Cost warning

GPU capacity and managed platform resources can incur cost while provisioned. Every deployable lab includes cleanup guidance. Run:

```bash
./scripts/cleanup.sh
```

## Official documentation

- [Anyscale on Azure documentation](https://learn.microsoft.com/azure/anyscale-on-azure/)
- [AKS AI toolchain operator documentation](https://learn.microsoft.com/azure/aks/ai-toolchain-operator)
- [KAITO fine-tuning documentation](https://learn.microsoft.com/azure/aks/ai-toolchain-operator-fine-tune)
