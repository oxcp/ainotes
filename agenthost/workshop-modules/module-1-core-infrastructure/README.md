# Module 1 — Core Infrastructure Setup

## Goal

Prepare reusable Azure core infrastructure definition using Bicep and validate logic/syntax without deployment.

## Files

- `infra/main.bicep`: Core resources template (RG-scoped).
- `scripts/validate.sh`: Linux Bash validation workflow using Azure CLI.

## Validation-Only Flow (No Deployment)

```bash
cd agenthost/workshop-modules/module-1-core-infrastructure
bash scripts/validate.sh
```

This command only runs:

- Bicep compile/lint (`az bicep build`)
- ARM template generation
- Optional dry-run style checks (`az deployment group validate` / `what-if`) when explicitly enabled and fully configured.
