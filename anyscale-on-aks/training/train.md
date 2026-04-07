这是一个基于 **Ray Train + DeepSpeed** 的分布式大语言模型微调脚本。以下是核心结构解读：

## 整体架构

使用 **Ray TorchTrainer** 编排多 GPU 分布式训练，底层用 **DeepSpeed ZeRO** 优化显存，训练 HuggingFace 模型。

## 关键模块

### 1. 数据准备 (`setup_dataloader`, train.py)
- 通过 HuggingFace `load_dataset` 加载数据集（默认 `ag_news`，仅取 1%）
- 用模型对应的 tokenizer 做 padding + truncation 到固定 `seq_length`
- 用 `ray.train.torch.prepare_data_loader` 包装，实现数据自动分片到各 worker

### 2. 模型初始化 (`setup_model_and_optimizer`, train.py)
- 加载 HuggingFace 预训练模型（默认 `gpt2`）
- 通过 `deepspeed.initialize` 包装模型和优化器，启用 ZeRO 优化

### 3. 精度自动选择 (`get_precision_config`, train.py)
- 自动检测 GPU 能力：支持 bf16 则用 bf16，否则回退到 fp16（兼容 T4 等较旧 GPU）

### 4. Checkpoint 机制
- **保存** (train.py)：每个 epoch 结束后通过 DeepSpeed 保存模型状态 + epoch 编号，上报给 Ray Train
- **恢复** (train.py)：从 Ray Checkpoint 恢复 DeepSpeed 引擎状态，支持断点续训

### 5. 训练循环 (`train_loop`, train.py)
- 每个 Ray worker 独立执行此函数
- 支持从 checkpoint 恢复起始 epoch
- 标准的 forward → backward → step 循环
- `debug_steps` 参数可限制每 epoch 只跑指定步数（用于调试）

### 6. 入口与配置 (`main` + `get_args`, train.py)

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--model_name` | `gpt2` | HuggingFace 模型名 |
| `--dataset_name` | `ag_news` | 数据集 |
| `--num_workers` | `2` | GPU worker 数量 |
| `--zero_stage` | `3` | DeepSpeed ZeRO 阶段（0-3） |
| `--batch_size` | `1` | 每 GPU 的 micro batch |
| `--num_epochs` | `1` | 训练轮数 |
| `--storage_path` | `/mnt/cluster_storage` | Checkpoint 存储路径 |
| `--resume_experiment` | `None` | 恢复已有实验 |
| `--cpu_only` | `False` | 禁用 GPU |
| `--debug_steps` | `0` | 调试模式步数（0=不限制） |

## 设计要点

- **ZeRO Stage 3**：将模型参数、梯度、优化器状态全部分片到各 worker，最大化显存节省，适合训练大模型
- **容错续训**：通过 `resume_experiment` + checkpoint 机制，任务中断后可恢复
- **Ray Train V2**：通过环境变量 `RAY_TRAIN_V2_ENABLED=1` 启用新版训练 API
- 适用场景：在 **Anyscale/Ray 集群**（如 AKS 上的 GPU 节点池）上对 GPT 系列模型做分布式微调