# Architecture

## Track A: AKS + KAITO

```text
Student -> Azure CLI / kubectl -> AKS
                                 |-- KAITO managed add-on
                                 |-- KAITO Workspace
                                 |-- GPU-backed inference/tuning pod
                                 |-- ACR and Storage
```

## Track B: Anyscale on Azure

```text
Student -> Anyscale UI / CLI -> Anyscale on Azure
                                |-- Existing Azure-integrated cloud
                                |-- Project
                                |-- Workspace / Job / Service
                                |-- Ray Data / Train / Serve
                                |-- Azure Blob Storage and ACR integrations
```

The second track consumes the Azure first-party Anyscale on Azure service. It does not teach students to install or administer a standalone Anyscale Operator on AKS.
