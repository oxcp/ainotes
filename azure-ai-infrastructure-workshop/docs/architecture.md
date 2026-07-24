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

## Track C: Azure AI Foundry

```text
Student -> Foundry portal / az ml / SDK -> Azure AI Foundry
                                          |-- Model catalog
                                          |-- Managed compute (dedicated GPU online endpoint)   [Lab 09]
                                          |-- Partner Models-as-a-Service (Fireworks AI)         [Lab 10]
                                          |-- OpenAI-compatible inference endpoint
```

Track C represents the fully managed end of the spectrum. Students consume models from the Foundry catalog without operating Kubernetes or Ray:

- **Managed compute (Lab 09):** an open model is deployed to a dedicated GPU-backed online endpoint. Consumes VM core quota; billed per compute uptime.
- **Fireworks AI on Foundry (Lab 10):** a partner model is consumed as a token-billed managed (MaaS) endpoint, with no compute to size or delete.
