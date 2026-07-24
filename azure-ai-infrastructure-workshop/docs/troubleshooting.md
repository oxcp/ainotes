# Troubleshooting index

## Common
- Wrong subscription or region
- Missing provider registration
- Insufficient role-assignment permission
- GPU quota is zero
- SKU unavailable

## KAITO
- Add-on or CRD missing
- Invalid version/preset combination
- Workspace pending
- Model download or registry failure
- GPU pod cannot schedule

## Anyscale on Azure
- User cannot access assigned cloud/project
- Approved compute configuration missing
- Job/service refers to a nonexistent cloud, project, or compute config
- Azure Blob/ACR integration permission failure
- GPU worker requested without approved quota/configuration

For Anyscale on Azure platform provisioning failures, follow the product support path rather than trying to repair the environment by installing a self-managed operator.
