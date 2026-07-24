# Deploy Anyscale on AKS + Run Model Inference and Fine-tuning

> 🌐 语言 / Language: **English** | [中文](README_CN.md)

This directory provides a complete set of scripts and examples to install the **Anyscale Operator** (a Ray-based distributed compute platform) on **Azure Kubernetes Service (AKS)** and run two kinds of workloads on it:

- **Serving (model inference)** — deploy the `gpt-oss` model with Ray Serve LLM, exposing an OpenAI-compatible API.
- **Training (fine-tuning)** — fine-tune a HuggingFace model with Ray Train + DeepSpeed ZeRO in a distributed fashion.

All persistence uses **Azure Blob Storage** (mounted into pods via the BlobFuse CSI driver + Workload Identity) to hold models, checkpoints, and shared data.

---

## Architecture Overview

```
                       ┌─────────────────────────────────────────────┐
                       │              Anyscale Control Plane         │
                       │        (SaaS / Anyscale Console + API)      │
                       └───────────────────────┬─────────────────────┘
                                                │ register cloud + operator
                                                ▼
┌───────────────────────────── AKS Cluster (anyscale-aks) ───────────────────────────────┐
│                                                                                        │
│  systempool (D2s_v5)    cpu16 (D16s_v5)     GPU node pools (Spot, autoscale 0→N)       │
│  ├─ anyscale-operator   ├─ Ray head/CPU     ├─ h100 (NC40ads_H100_v5)                  │
│  ├─ ingress-nginx       └─ ...              ├─ a100 (NC24ads_A100_v4)                  │
│  └─ nvidia-device-plugin                    └─ t4-spot (NC4as_T4_v3)                   │
│                                                                                        │
│  Workload Identity ──► Managed Identity (anyscale-mi) ──► Storage Blob Data Contributor│
│  PV/PVC (blob.csi.azure.com) ── anyscale-shared-fuse ──► /mnt/cloud-storage            │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
                           Azure Blob Storage (private endpoint)
```

**Key design points:**
- **GPU node pools** are all **Spot** instances with `min-count=0`. Combined with the Cluster Autoscaler, they scale on demand and down to zero when idle, maximizing GPU cost efficiency.
- Each GPU node pool carries a **taint** (`gpu-type=<h100|a100|t4>:NoSchedule`) and a **label** (`nvidia.com/gpu.product=...`). Anyscale instance types are scheduled onto the right pool via `nodeSelector` + `tolerations`.
- Storage access uses **Workload Identity + Managed Identity** with no static keys; the `anyscale-operator` ServiceAccount obtains Blob access through a Federated Credential.

---

## Directory Structure

```
anyscale-on-aks/
├── README.md                          ← This document (English)
├── README_CN.md                       ← Chinese version
├── anyscale-az-envvars.sh             ← Environment variables (resource group, region, cluster name, Storage, Anyscale token, etc.)
├── anyscale-az-setup.sh               ← Main entry point: creates RG/VNet/Storage/private endpoint/MI and calls the two scripts below
├── anyscale-aks-gpu-np.sh             ← Creates AKS + CPU/H100/A100/T4 node pools + device plugin + PV/PVC + ingress
├── anyscale-aks-connect.sh            ← Registers the Anyscale cloud + installs anyscale-operator via Helm
├── anyscale-operator-custom_values.yaml ← Operator Helm values: custom instance types (H100/A100/T4, etc.)
├── gpu-verify.sh                      ← GPU driver / device-plugin verification commands
├── gpu-pod.yaml                       ← Test pod for verifying GPU availability
├── storage-pod.yaml                   ← Test pod for verifying the Blob mount
├── computeconfig/                     ← Anyscale compute configs (head/worker specs)
│   ├── compute_config_workspace.yaml  ← CPU-only workspace spec
│   ├── compute_config_LLM-1xA100.yaml ← 1×A100
│   ├── compute_config_LLM-2xA100.yaml ← 2×A100
│   └── compute_config_LLM-1xH100.yaml ← 1×H100
├── serving/                           ← Inference example (Ray Serve LLM + gpt-oss)
│   ├── server_gpt_oss.py              ← Defines LLMConfig and builds the OpenAI-compatible app (20b/120b switchable)
│   ├── service.yaml                   ← Anyscale Service definition (references compute config LLM-1xA100)
│   ├── service-inline-cf.yaml         ← Same, but with the compute config inlined
│   ├── deploy_20b.yaml                ← Declarative service + compute config (A100-80G example)
│   ├── client.py                      ← Streams calls to the deployed service via the OpenAI SDK
│   └── basic_query.py                 ← Basic health/auth probe using requests
└── training/                          ← Fine-tuning example (Ray Train + DeepSpeed)
    ├── train.py                       ← Distributed fine-tuning script (TorchTrainer + DeepSpeed ZeRO)
    ├── job.yaml                       ← Anyscale Job definition (inline compute config + Blob mount)
    ├── Dockerfile                     ← Training image (ray + deepspeed + transformers + datasets)
    └── train.md                       ← Walkthrough of train.py (Chinese)
```

---

## Prerequisites

| Tool | Purpose |
|---|---|
| Azure CLI (`az`) + a logged-in subscription with **Owner/Contributor** rights | Create resources, assign RBAC |
| `kubectl` | Operate the AKS cluster |
| `helm` | Install device plugin / ingress / anyscale-operator |
| `yq` | YAML processing inside the scripts |
| `anyscale` CLI + a valid **Anyscale account and CLI Token** | Register the cloud, deploy service/job |
| GPU quota | The subscription needs **Spot** quota for `NCads_H100_v5` / `NCads_A100_v4` / `NC*T4*` |

> ⚠️ **Security note:** The `ANYSCALE_CLI_TOKEN` in `anyscale-az-envvars.sh`, and the tokens/URLs in `serving/client.py` and `serving/basic_query.py`, are **placeholder/sample values**. Do not commit real secrets to source control; inject them via environment variables or Secrets in production.

---

## Part 1 — Install Anyscale on AKS

### Step 0: Configure environment variables

Edit [anyscale-az-envvars.sh](anyscale-az-envvars.sh) as needed:

```bash
RESOURCE_GROUP=anyscale-rg
LOCATION=westus
VNET_NAME=anyscale-vnet
CLUSTER_NAME=anyscale-aks
STORAGE_ACCOUNT_NAME=anyscale28120        # must be globally unique — change it
STORAGE_CONTAINER_NAME=anyscale-container
ANYSCALE_NAMESPACE=anyscale-operator
ANYSCALE_CLOUD_INSTANCE_NAME=anyscale-on-azure
ANYSCALE_CLI_TOKEN=aph0_xxxxxxxx          # from the Anyscale Console
```

### Step 1: One-command install (recommended)

[anyscale-az-setup.sh](anyscale-az-setup.sh) is the main entry point and runs everything in order:

```bash
cd anyscale-on-aks
chmod +x *.sh
./anyscale-az-setup.sh
```

What the script does, in sequence:

1. `az login` and create the **resource group / VNet / subnets** (`aks` + `storage-pe-subnet`).
2. Create the **Storage Account + Blob container + File Share**, then **disable public network access**, switching to a **private endpoint + private DNS zone** (`privatelink.blob.core.windows.net`).
3. Create a **Managed Identity** (`anyscale-mi`) and grant it the **Storage Blob Data Contributor** role on the storage account.
4. Call [anyscale-aks-gpu-np.sh](anyscale-aks-gpu-np.sh) to create the cluster and node pools (see Step 2).
5. Call [anyscale-aks-connect.sh](anyscale-aks-connect.sh) to register the Anyscale cloud and install the operator (see Step 3).

> 💡 After the role assignment, the script prints an explicit reminder: **verify that the `Storage Blob Data Contributor` role assignment succeeded** (RBAC propagation can lag; confirm manually in the portal if needed).

### Step 2: Cluster and GPU node pools ([anyscale-aks-gpu-np.sh](anyscale-aks-gpu-np.sh))

This script creates AKS and configures:

- **Networking:** Azure CNI **Overlay** + **Cilium** dataplane; Pod/Service CIDRs do not overlap the VNet.
- **Identity:** Managed Identity + **OIDC Issuer** + **Workload Identity**.
- **Node pools:**

  | Node pool | VM size | Purpose | Autoscale |
  |---|---|---|---|
  | `systempool` | D2s_v5 | System components | 1→3 |
  | `cpu16` | D16s_v5 | Ray head / CPU jobs | 0→5 |
  | `h100` | NC40ads_H100_v5 (Spot) | GPU training/inference | 0→1 |
  | `t4-spot` | NC4as_T4_v3 (Spot) | Lightweight GPU | 0→8 |
  | `a100` | NC24ads_A100_v4 (Spot) | GPU training/inference | 0→4 |

- **NVIDIA device plugin:** installs `nvdp/nvidia-device-plugin` via Helm, exposing the `nvidia.com/gpu` resource to the scheduler.
- **Federated Credential:** maps `system:serviceaccount:anyscale-operator:anyscale-operator` to `anyscale-mi`, enabling keyless Blob access from pods.
- **BlobFuse CSI:** `az aks update --enable-blob-driver`, and grants the Storage role to the **kubelet identity**.
- **PV/PVC:** creates `pv-blob-wi` (`blob.csi.azure.com`, MSI auth) and PVC `anyscale-shared-fuse` for shared read/write (`ReadWriteMany`) of training checkpoints, etc.
- **Ingress:** installs `ingress-nginx` (LoadBalancer type) via Helm.

### Step 3: Register the cloud and install the operator ([anyscale-aks-connect.sh](anyscale-aks-connect.sh))

1. `anyscale cloud register` with `--provider azure --compute-stack k8s`, binding the Blob container and endpoint.
2. Retrieve `ANYSCALE_CLOUD_ID` and write it into the operator values file.
3. `helm upgrade anyscale-operator anyscale/anyscale-operator ... -f anyscale-operator-custom_values.yaml`, with key parameters:
   - `global.cloudDeploymentId` — the cloud id from the previous step
   - `global.cloudProvider=azure`
   - `global.auth.anyscaleCliToken` — your CLI token
   - `global.auth.iamIdentity` — the principalId of `anyscale-mi`
   - `workloads.serviceAccount.name=anyscale-operator`
4. Annotate/label the `anyscale-operator` ServiceAccount for **Workload Identity** (`azure.workload.identity/client-id`, `azure.workload.identity/use=true`) and restart the operator pod to apply.

> `anyscale-operator-custom_values.yaml` defines custom instance types such as **H100 / A100 / T4** under `workloads.instanceTypes.additional`, each with a `nodeSelector` (matching agentpool) and `tolerations` (matching the Spot + gpu-type taints). **The `A100`, `H100`, etc. instance types referenced by Serving/Training come from here.**

### Step 4: Verify GPU ([gpu-verify.sh](gpu-verify.sh) / [gpu-pod.yaml](gpu-pod.yaml))

```bash
# Deploy a test pod requesting 1 GPU and run nvidia-smi
kubectl apply -f gpu-pod.yaml
kubectl exec -it gpu-pod -- nvidia-smi

# Show allocatable GPUs on a node pool
kubectl get nodes -l kubernetes.azure.com/agentpool=a100 \
  -o custom-columns=NAME:.metadata.name,ALLOC_GPU:.status.allocatable.nvidia\.com/gpu
```

If AKS did not auto-install the driver, `gpu-verify.sh` also includes optional commands to install drivers via the **NVIDIA GPU Operator** (`nvidia/gpu-operator`).

### (Optional) Register compute configs

Serving/Training reference compute configs by name (e.g. `LLM-1xA100`). Register them first:

```bash
anyscale compute-config create -n LLM-1xA100 -f computeconfig/compute_config_LLM-1xA100.yaml
anyscale compute-config create -n LLM-2xA100 -f computeconfig/compute_config_LLM-2xA100.yaml
anyscale compute-config create -n LLM-1xH100 -f computeconfig/compute_config_LLM-1xH100.yaml
```

> Each compute config defines a `head_node` (CPU-only) + `worker_nodes` (A100/H100, Spot), and mounts the PVC `anyscale-shared-fuse` at `/mnt/cloud-storage` via `advanced_instance_config`.

---

## Part 2 — Model Inference (Serving)

Deploy `openai/gpt-oss-20b` (or `120b`) with **Ray Serve LLM**, exposing an **OpenAI-compatible** `/v1` endpoint.

### 2.1 Service definition

- [serving/server_gpt_oss.py](serving/server_gpt_oss.py): selects an `LLMConfig` based on the `GPT_OSS_SIZE` env var (`20b`/`120b`); `build_openai_app` generates the app.
  - `20b`: `accelerator_type=A100-80G`, `max_model_len=32768`, single replica.
  - `120b`: `tensor_parallel_size=2`, `min/max_replicas=1/2`.
- [serving/service.yaml](serving/service.yaml): Anyscale Service definition, `image_uri: anyscale/ray-llm:...`, `compute_config: LLM-1xA100:4`, `import_path: server_gpt_oss:app`.
  - Variant [service-inline-cf.yaml](serving/service-inline-cf.yaml) inlines the compute config; [deploy_20b.yaml](serving/deploy_20b.yaml) is fully declarative (including `runtime_env` pip dependencies).

### 2.2 Deploy the service

```bash
cd serving
# Deploy (or update) the service
anyscale service deploy -f service.yaml

# Check status and get the URL + auth token
anyscale service status -n deploy-gpt-oss
```

On success you get:
- The service **base URL** (like `https://deploy-gpt-oss-xxxx....anyscaleuserdata.com/`)
- A **Bearer token** (for auth)

### 2.3 Run inference

**Option A — OpenAI SDK streaming** ([serving/client.py](serving/client.py)): replace `base_url` and `api_key` with your service's real values, then run:

```bash
python client.py
```

Core logic: `OpenAI(base_url=<url>/v1, api_key=<token>)` → `chat.completions.create(model="my-gpt-oss", stream=True)`, printing `reasoning_content` (thinking) and `content` (final answer) separately.

**Option B — Basic probe** ([serving/basic_query.py](serving/basic_query.py)): uses `requests` with `Authorization: Bearer <token>` for a health/connectivity check.

**Option C — curl:**

```bash
curl $BASE_URL/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"my-gpt-oss","messages":[{"role":"user","content":"Hello"}]}'
```

### 2.4 Deploy 120b

```bash
GPT_OSS_SIZE=120b anyscale service deploy -f service.yaml
```

---

## Part 3 — Model Fine-tuning (Training)

Fine-tune a HuggingFace model across multiple GPUs with **Ray Train (TorchTrainer) + DeepSpeed ZeRO**, writing checkpoints to the mounted Azure Blob (`/mnt/cloud-storage`). See [training/train.md](training/train.md) for a detailed script walkthrough.

### 3.1 Components

- [training/train.py](training/train.py):
  - `RAY_TRAIN_V2_ENABLED=1` enables the new Train API.
  - Data: HuggingFace `load_dataset` (default `ag_news`, 1% slice), tokenizer padding/truncation, `prepare_data_loader` for automatic sharding.
  - Model: wrapped by `deepspeed.initialize`, default **ZeRO Stage 3** (fully shards params/gradients/optimizer state).
  - Precision: automatic bf16→fp16 fallback (T4-compatible).
  - Checkpoint: saved every epoch and reported to Ray Train; supports `--resume_experiment` for resuming.
- [training/job.yaml](training/job.yaml): Anyscale Job, `containerfile: ./Dockerfile`, `entrypoint: python train.py`, inline compute config (A100 worker, Spot), mounts PVC `anyscale-shared-fuse` at `/mnt/cloud-storage`, injects `AZURE_STORAGE_ACCOUNT`.
- [training/Dockerfile](training/Dockerfile): based on `anyscale/ray:2.53.0-py312-cu128`, adds `deepspeed / torch / datasets / transformers`.

### 3.2 Submit the training job

```bash
cd training
anyscale job submit -f job.yaml

# Tail logs
anyscale job logs -f -n ray-train-job
```

### 3.3 Common tunable parameters (`train.py`)

| Parameter | Default | Description |
|---|---|---|
| `--model_name` | `gpt2` | HuggingFace model name |
| `--dataset_name` | `ag_news` | Dataset |
| `--num_workers` | `2` | Number of GPU workers (≈ GPUs needed) |
| `--zero_stage` | `3` | DeepSpeed ZeRO stage (0–3) |
| `--batch_size` | `1` | Per-GPU micro-batch |
| `--num_epochs` | `1` | Number of epochs |
| `--seq_length` | `512` | Sequence length |
| `--learning_rate` | `1e-6` | Learning rate |
| `--storage_path` | `/mnt/cloud-storage` | Checkpoint path (mounted Blob) |
| `--resume_experiment` | `None` | Resume an existing experiment |
| `--cpu_only` | `False` | Disable GPU (debug) |
| `--debug_steps` | `0` | Limit steps per epoch (0 = unlimited) |

Append parameters to the `entrypoint` in `job.yaml`, e.g. a larger model with more workers:

```yaml
entrypoint: python train.py --model_name gpt2-large --num_workers 2 --zero_stage 3 --num_epochs 3
```

Correspondingly increase `worker_nodes` `max_nodes` or GPUs (e.g. `LLM-2xA100`).

---

## Troubleshooting

| Symptom | Where to look |
|---|---|
| Pod won't start, no GPU | `kubectl describe pod` for scheduling; verify GPU pool autoscale max > 0 and Spot capacity; use `gpu-pod.yaml` to check the driver |
| `nvidia-smi` unavailable | AKS didn't install the driver → use the **GPU Operator** option in `gpu-verify.sh` |
| Blob mount fails | Confirm `anyscale-mi`/kubelet identity has **Storage Blob Data Contributor**; check PV `AzureStorageIdentityClientID`; verify private endpoint DNS resolution |
| Operator 401 / auth failure | Update the `anyscale-cli-token` Secret, then `kubectl rollout restart deployment anyscale-operator -n anyscale-operator` |
| Service can't load the model | Check GPU quota, `accelerator_type` vs node pool label match, and `ray-llm` image / vLLM compatibility |

---

## References

- Anyscale Operator on Kubernetes: <https://docs.anyscale.com/>
- Ray Serve LLM: <https://docs.ray.io/en/latest/serve/llm/overview.html>
- Ray Train + DeepSpeed: <https://docs.ray.io/en/latest/train/train.html>
- AKS GPU / Spot node pools: <https://learn.microsoft.com/azure/aks/gpu-cluster>
