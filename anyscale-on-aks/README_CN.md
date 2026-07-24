# 在 AKS 上部署 Anyscale + 运行模型推理与微调

> 🌐 语言 / Language: [English](README.md) | **中文**

本目录提供一整套脚本与示例,用于在 **Azure Kubernetes Service (AKS)** 上安装 **Anyscale Operator**(基于 Ray 的分布式计算平台),并在其上运行两类工作负载:

- **Serving(模型推理)** — 用 Ray Serve LLM 部署 `gpt-oss` 模型,提供 OpenAI 兼容 API。
- **Training(模型微调)** — 用 Ray Train + DeepSpeed ZeRO 对 HuggingFace 模型做分布式微调。

底层存储统一使用 **Azure Blob Storage**(通过 BlobFuse CSI + Workload Identity 挂载到 Pod),用于存放模型、checkpoint 与共享数据。

---

## 架构概览

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

**关键设计:**
- **GPU 节点池**均为 **Spot** 实例并 `min-count=0`,配合 Cluster Autoscaler 实现按需扩缩、闲时缩容到零,最大化 GPU 成本效率。
- 每个 GPU 节点池带 **taint**(`gpu-type=<h100|a100|t4>:NoSchedule`)与 **label**(`nvidia.com/gpu.product=...`),Anyscale 的 instance type 通过 `nodeSelector` + `tolerations` 精确调度到对应池。
- 存储访问采用 **Workload Identity + Managed Identity**,无静态密钥;`anyscale-operator` ServiceAccount 通过联合凭据(Federated Credential)获取对 Blob 的访问权限。

---

## 目录结构

```
anyscale-on-aks/
├── README.md                          ← 英文文档
├── README_CN.md                       ← 本文档(中文)
├── anyscale-az-envvars.sh             ← 环境变量(资源组、区域、集群名、Storage、Anyscale token 等)
├── anyscale-az-setup.sh               ← 主入口:创建 RG/VNet/Storage/私有端点/MI,并调用下面两个脚本
├── anyscale-aks-gpu-np.sh             ← 创建 AKS + CPU/H100/A100/T4 节点池 + device plugin + PV/PVC + ingress
├── anyscale-aks-connect.sh            ← 注册 Anyscale cloud + 用 Helm 安装 anyscale-operator
├── anyscale-operator-custom_values.yaml ← Operator 的 Helm values:自定义 instance types(H100/A100/T4 等)
├── gpu-verify.sh                      ← GPU 驱动/device-plugin 校验命令集合
├── gpu-pod.yaml                       ← 用于验证 GPU 可用性的测试 Pod
├── storage-pod.yaml                   ← 用于验证 Blob 挂载的测试 Pod
├── computeconfig/                     ← Anyscale compute config(head/worker 规格)
│   ├── compute_config_workspace.yaml  ← 纯 CPU workspace 规格
│   ├── compute_config_LLM-1xA100.yaml ← 1×A100
│   ├── compute_config_LLM-2xA100.yaml ← 2×A100
│   └── compute_config_LLM-1xH100.yaml ← 1×H100
├── serving/                           ← 模型推理示例(Ray Serve LLM + gpt-oss)
│   ├── server_gpt_oss.py              ← 定义 LLMConfig,构建 OpenAI 兼容 app(20b/120b 可切换)
│   ├── service.yaml                   ← Anyscale Service 定义(引用 compute config LLM-1xA100)
│   ├── service-inline-cf.yaml         ← 同上,但把 compute config 内联在文件里
│   ├── deploy_20b.yaml                ← 声明式 service + compute config(A100-80G 示例)
│   ├── client.py                      ← 用 OpenAI SDK 流式调用已部署服务
│   └── basic_query.py                 ← 用 requests 做基础健康/鉴权探测
└── training/                          ← 模型微调示例(Ray Train + DeepSpeed)
    ├── train.py                       ← 分布式微调脚本(TorchTrainer + DeepSpeed ZeRO)
    ├── job.yaml                       ← Anyscale Job 定义(内联 compute config + Blob 挂载)
    ├── Dockerfile                     ← 训练镜像(ray + deepspeed + transformers + datasets)
    └── train.md                       ← train.py 的中文解读
```

---

## 先决条件

| 工具 | 用途 |
|---|---|
| Azure CLI (`az`) + 已登录、有 **Owner/Contributor** 权限的订阅 | 创建资源、分配 RBAC |
| `kubectl` | 操作 AKS 集群 |
| `helm` | 安装 device plugin / ingress / anyscale-operator |
| `yq` | 脚本中处理 YAML |
| `anyscale` CLI + 有效的 **Anyscale account 与 CLI Token** | 注册 cloud、部署 service/job |
| GPU 配额 | 订阅需具备 `NCads_H100_v5` / `NCads_A100_v4` / `NC*T4*` 的 **Spot** 配额 |

> ⚠️ **安全提醒:** 仓库中的 `anyscale-az-envvars.sh`(`ANYSCALE_CLI_TOKEN`)、`serving/client.py`、`serving/basic_query.py` 里出现的是**占位/示例 token 与 URL**。请勿把真实密钥提交到版本库;正式使用请改用环境变量或 Secret 注入。

---

## Part 1 — 在 AKS 上安装 Anyscale

### 步骤 0:配置环境变量

编辑 [anyscale-az-envvars.sh](anyscale-az-envvars.sh),按需修改:

```bash
RESOURCE_GROUP=anyscale-rg
LOCATION=westus
VNET_NAME=anyscale-vnet
CLUSTER_NAME=anyscale-aks
STORAGE_ACCOUNT_NAME=anyscale28120        # 必须全局唯一,改成你自己的
STORAGE_CONTAINER_NAME=anyscale-container
ANYSCALE_NAMESPACE=anyscale-operator
ANYSCALE_CLOUD_INSTANCE_NAME=anyscale-on-azure
ANYSCALE_CLI_TOKEN=aph0_xxxxxxxx          # 从 Anyscale Console 获取
```

### 步骤 1:一键安装(推荐)

[anyscale-az-setup.sh](anyscale-az-setup.sh) 是主入口,它会依次完成:

```bash
cd anyscale-on-aks
chmod +x *.sh
./anyscale-az-setup.sh
```

脚本内部执行顺序:

1. `az login` 并创建 **资源组 / VNet / 子网**(`aks` + `storage-pe-subnet`)。
2. 创建 **Storage Account + Blob 容器 + File Share**,随后**关闭公网访问**,改为 **私有端点 + 私有 DNS 区域**(`privatelink.blob.core.windows.net`)。
3. 创建 **Managed Identity**(`anyscale-mi`)并授予 Storage 的 **Storage Blob Data Contributor** 角色。
4. 调用 [anyscale-aks-gpu-np.sh](anyscale-aks-gpu-np.sh) 创建集群与节点池(见步骤 2)。
5. 调用 [anyscale-aks-connect.sh](anyscale-aks-connect.sh) 注册 Anyscale cloud 并安装 operator(见步骤 3)。

> 💡 脚本在角色分配后有一段显式提示:**请确认 `Storage Blob Data Contributor` 角色分配成功**(RBAC 生效可能有延迟,必要时到门户手动确认)。

### 步骤 2:集群与 GPU 节点池([anyscale-aks-gpu-np.sh](anyscale-aks-gpu-np.sh))

该脚本创建 AKS 并配置:

- **网络:** Azure CNI **Overlay** + **Cilium** dataplane;Pod/Service CIDR 与 VNet 不重叠。
- **身份:** Managed Identity + **OIDC Issuer** + **Workload Identity**。
- **节点池:**

  | 节点池 | VM 规格 | 用途 | 弹性 |
  |---|---|---|---|
  | `systempool` | D2s_v5 | 系统组件 | 1→3 |
  | `cpu16` | D16s_v5 | Ray head / CPU 任务 | 0→5 |
  | `h100` | NC40ads_H100_v5 (Spot) | GPU 训练/推理 | 0→1 |
  | `t4-spot` | NC4as_T4_v3 (Spot) | 轻量 GPU | 0→8 |
  | `a100` | NC24ads_A100_v4 (Spot) | GPU 训练/推理 | 0→4 |

- **NVIDIA device plugin:** 通过 Helm 安装 `nvdp/nvidia-device-plugin`,把 `nvidia.com/gpu` 资源暴露给调度器。
- **Federated Credential:** 把 `system:serviceaccount:anyscale-operator:anyscale-operator` 映射到 `anyscale-mi`,实现 Pod 免密钥访问 Blob。
- **BlobFuse CSI:** `az aks update --enable-blob-driver`,并给 **kubelet identity** 授予 Storage 角色。
- **PV/PVC:** 创建 `pv-blob-wi`(`blob.csi.azure.com`,MSI 鉴权)与 PVC `anyscale-shared-fuse`,供训练 checkpoint 等共享读写(`ReadWriteMany`)。
- **Ingress:** Helm 安装 `ingress-nginx`(LoadBalancer 类型)。

### 步骤 3:注册 Cloud 并安装 Operator([anyscale-aks-connect.sh](anyscale-aks-connect.sh))

1. `anyscale cloud register`:以 `--provider azure --compute-stack k8s` 注册,绑定 Blob 容器与 endpoint。
2. 取回 `ANYSCALE_CLOUD_ID`,写入 operator 的 values 文件。
3. `helm upgrade anyscale-operator anyscale/anyscale-operator ... -f anyscale-operator-custom_values.yaml`,关键参数:
   - `global.cloudDeploymentId` — 上一步的 cloud id
   - `global.cloudProvider=azure`
   - `global.auth.anyscaleCliToken` — 你的 CLI token
   - `global.auth.iamIdentity` — `anyscale-mi` 的 principalId
   - `workloads.serviceAccount.name=anyscale-operator`
4. 给 `anyscale-operator` ServiceAccount 打上 **Workload Identity** 注解/标签(`azure.workload.identity/client-id`、`azure.workload.identity/use=true`),并重启 operator Pod 使其生效。

> `anyscale-operator-custom_values.yaml` 里通过 `workloads.instanceTypes.additional` 定义了 **H100 / A100 / T4** 等自定义 instance type,包含 `nodeSelector`(对应 agentpool)与 `tolerations`(匹配 Spot + gpu-type taint)。**Serving/Training 里引用的 `A100`、`H100` 等 instance_type 就来自这里。**

### 步骤 4:验证 GPU([gpu-verify.sh](gpu-verify.sh) / [gpu-pod.yaml](gpu-pod.yaml))

```bash
# 部署一个请求 1 张 GPU 的测试 Pod,并运行 nvidia-smi
kubectl apply -f gpu-pod.yaml
kubectl exec -it gpu-pod -- nvidia-smi

# 查看某节点池的可分配 GPU 数
kubectl get nodes -l kubernetes.azure.com/agentpool=a100 \
  -o custom-columns=NAME:.metadata.name,ALLOC_GPU:.status.allocatable.nvidia\.com/gpu
```

若 AKS 未自动装好驱动,`gpu-verify.sh` 里也给了用 **NVIDIA GPU Operator**(`nvidia/gpu-operator`)安装驱动的可选命令。

### (可选)注册 Compute Config

Serving/Training 会按名字引用 compute config(如 `LLM-1xA100`)。先注册:

```bash
anyscale compute-config create -n LLM-1xA100 -f computeconfig/compute_config_LLM-1xA100.yaml
anyscale compute-config create -n LLM-2xA100 -f computeconfig/compute_config_LLM-2xA100.yaml
anyscale compute-config create -n LLM-1xH100 -f computeconfig/compute_config_LLM-1xH100.yaml
```

> 每个 compute config 都定义了 `head_node`(纯 CPU)+ `worker_nodes`(A100/H100,Spot),并通过 `advanced_instance_config` 把 PVC `anyscale-shared-fuse` 挂载到 `/mnt/cloud-storage`。

---

## Part 2 — 模型推理(Serving)

用 **Ray Serve LLM** 部署 `openai/gpt-oss-20b`(或 `120b`),对外提供 **OpenAI 兼容** 的 `/v1` 接口。

### 2.1 服务定义

- [serving/server_gpt_oss.py](serving/server_gpt_oss.py):按环境变量 `GPT_OSS_SIZE`(`20b`/`120b`)选择 `LLMConfig`,`build_openai_app` 生成 app。
  - `20b`:`accelerator_type=A100-80G`,`max_model_len=32768`,单副本。
  - `120b`:`tensor_parallel_size=2`,`min/max_replicas=1/2`。
- [serving/service.yaml](serving/service.yaml):Anyscale Service 定义,`image_uri: anyscale/ray-llm:...`,`compute_config: LLM-1xA100:4`,`import_path: server_gpt_oss:app`。
  - 变体 [service-inline-cf.yaml](serving/service-inline-cf.yaml) 把 compute config 内联;[deploy_20b.yaml](serving/deploy_20b.yaml) 为纯声明式(含 `runtime_env` pip 依赖)。

### 2.2 部署服务

```bash
cd serving
# 部署(或更新)服务
anyscale service deploy -f service.yaml

# 查看状态、拿到访问 URL 与鉴权 token
anyscale service status -n deploy-gpt-oss
```

部署成功后会得到:
- 服务 **base URL**(形如 `https://deploy-gpt-oss-xxxx....anyscaleuserdata.com/`)
- **Bearer token**(鉴权用)

### 2.3 推理调用

**方式 A — OpenAI SDK 流式调用**([serving/client.py](serving/client.py)):把 `base_url`、`api_key` 换成你服务的真实值后运行。

```bash
python client.py
```

核心逻辑:`OpenAI(base_url=<url>/v1, api_key=<token>)` → `chat.completions.create(model="my-gpt-oss", stream=True)`,并分别打印 `reasoning_content`(思考过程)与 `content`(最终回答)。

**方式 B — 基础探测**([serving/basic_query.py](serving/basic_query.py)):用 `requests` 带 `Authorization: Bearer <token>` 做健康/连通性检查。

**方式 C — curl:**

```bash
curl $BASE_URL/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"my-gpt-oss","messages":[{"role":"user","content":"你好"}]}'
```

### 2.4 部署 120b

```bash
GPT_OSS_SIZE=120b anyscale service deploy -f service.yaml
```

---

## Part 3 — 模型微调(Training)

用 **Ray Train(TorchTrainer)+ DeepSpeed ZeRO** 对 HuggingFace 模型做多 GPU 分布式微调,checkpoint 写入挂载的 Azure Blob(`/mnt/cloud-storage`)。详细脚本解读见 [training/train.md](training/train.md)。

### 3.1 组成

- [training/train.py](training/train.py):
  - `RAY_TRAIN_V2_ENABLED=1` 启用新版 Train API。
  - 数据:HuggingFace `load_dataset`(默认 `ag_news` 取 1%),tokenizer padding/truncation,`prepare_data_loader` 自动分片。
  - 模型:`deepspeed.initialize` 包装,默认 **ZeRO Stage 3**(参数/梯度/优化器状态全分片)。
  - 精度:自动 bf16→fp16 回退(兼容 T4)。
  - Checkpoint:每 epoch 保存并上报 Ray Train,支持 `--resume_experiment` 断点续训。
- [training/job.yaml](training/job.yaml):Anyscale Job,`containerfile: ./Dockerfile`,`entrypoint: python train.py`,内联 compute config(A100 worker,Spot),把 PVC `anyscale-shared-fuse` 挂到 `/mnt/cloud-storage`,注入 `AZURE_STORAGE_ACCOUNT`。
- [training/Dockerfile](training/Dockerfile):基于 `anyscale/ray:2.53.0-py312-cu128`,加装 `deepspeed / torch / datasets / transformers`。

### 3.2 提交训练任务

```bash
cd training
anyscale job submit -f job.yaml

# 跟踪日志
anyscale job logs -f -n ray-train-job
```

### 3.3 常用可调参数(`train.py`)

| 参数 | 默认 | 说明 |
|---|---|---|
| `--model_name` | `gpt2` | HuggingFace 模型名 |
| `--dataset_name` | `ag_news` | 数据集 |
| `--num_workers` | `2` | GPU worker 数(≈ 需要的 GPU 数) |
| `--zero_stage` | `3` | DeepSpeed ZeRO 阶段(0–3) |
| `--batch_size` | `1` | 每 GPU micro-batch |
| `--num_epochs` | `1` | 训练轮数 |
| `--seq_length` | `512` | 序列长度 |
| `--learning_rate` | `1e-6` | 学习率 |
| `--storage_path` | `/mnt/cloud-storage` | Checkpoint 路径(挂载的 Blob) |
| `--resume_experiment` | `None` | 从已有实验恢复 |
| `--cpu_only` | `False` | 禁用 GPU(调试) |
| `--debug_steps` | `0` | 每 epoch 限制步数(0=不限) |

在 `job.yaml` 的 `entrypoint` 里追加参数即可,例如换更大的模型与更多 worker:

```yaml
entrypoint: python train.py --model_name gpt2-large --num_workers 2 --zero_stage 3 --num_epochs 3
```

对应地把 `worker_nodes` 的 `max_nodes` 或 GPU 数调大(如 `LLM-2xA100`)。

---

## 常见问题排查

| 现象 | 排查方向 |
|---|---|
| Pod 起不来,无 GPU | `kubectl describe pod` 看是否卡在调度;确认 GPU 节点池 autoscale 上限 > 0、Spot 有容量;`gpu-pod.yaml` 验证驱动 |
| `nvidia-smi` 不可用 | AKS 未装驱动 → 用 `gpu-verify.sh` 里的 **GPU Operator** 方案安装 |
| Blob 挂载失败 | 确认 `anyscale-mi`/kubelet identity 有 **Storage Blob Data Contributor**;PV `AzureStorageIdentityClientID` 是否正确;私有端点 DNS 是否解析 |
| Operator 401 / 鉴权失败 | 更新 `anyscale-cli-token` Secret 后 `kubectl rollout restart deployment anyscale-operator -n anyscale-operator` |
| Service 拉不起模型 | 检查 GPU 配额、`accelerator_type` 与节点池 label 是否匹配、镜像 `ray-llm` 版本与 vLLM 兼容性 |

---

## 参考

- Anyscale Operator on Kubernetes:<https://docs.anyscale.com/>
- Ray Serve LLM:<https://docs.ray.io/en/latest/serve/llm/overview.html>
- Ray Train + DeepSpeed:<https://docs.ray.io/en/latest/train/train.html>
- AKS GPU / Spot 节点池:<https://learn.microsoft.com/azure/aks/gpu-cluster>
