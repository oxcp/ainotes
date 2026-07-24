
<!--
本 Workshop 旨在帮助客户从"如何消费 Azure GPU 和运行 AI Workload"的视角理解 Azure AI Infrastructure，而不是单纯学习某个模型或服务。通过对比 Azure AI Foundry、AKS + KAITO、Anyscale on Azure 等平台，帮助学员掌握在 Azure 上进行模型推理、微调、分布式训练和规模化部署时的架构选择与最佳实践。其中，AKS + KAITO 被定位为 Kubernetes Native 的 AI 平台，用于简化开源模型在 AKS 上的部署、推理和微调；Anyscale on Azure 则作为 Azure 集成的 Managed Ray Platform，用于实现 Ray Data、Ray Serve、Ray Train 等分布式 AI 工作负载。Anyscale 部分基于官方的 Anyscale on Azure 服务，而非自建 Anyscale on AKS 平台。

整个 Workshop 采用"基础设施优先、平台优先、实践优先"的设计思路，以 Azure GPU、网络、身份、存储等共享基础设施为基础，通过两条主线展开：一条是 AKS + KAITO 的模型运行与微调路线，另一条是 Anyscale on Azure 的分布式数据处理、训练和服务化路线。课程内容以 Hands-on Lab 为核心，学员通过 Bicep、Shell、YAML、Python 等真实工程资产完成环境搭建、模型部署、推理验证、微调实验、Ray 分布式任务运行以及服务化发布，并结合监控、扩展和平台选型进行总结。最终交付的不仅是一门课程，而是一套可直接 Fork 和复用的 GitHub Workshop Repository，帮助客户在 Azure 上快速构建企业级 AI Infrastructure，并理解不同平台的适用场景、能力边界和最佳实践。
-->

# Azure AI Infrastructure Workshop

## 目标

本 Workshop 旨在帮助客户从"**如何消费 Azure GPU 和运行 AI Workload**"的视角理解 Azure AI Infrastructure，而不是单纯学习某个模型或服务。

## 核心平台对比

通过对比以下平台，帮助学员掌握在 Azure 上进行模型推理、微调、分布式训练和规模化部署时的架构选择与最佳实践：

- **Azure AI Foundry**
- **AKS + KAITO** - Kubernetes Native 的 AI 平台，用于简化开源模型在 AKS 上的部署、推理和微调
- **Anyscale on Azure** - Azure 集成的 Managed Ray Platform，用于实现 Ray Data、Ray Serve、Ray Train 等分布式 AI 工作负载

> **注**：Anyscale 部分基于官方的 Anyscale on Azure 服务，而非自建 Anyscale on AKS 平台。

## 课程设计思路

采用 **"基础设施优先、平台优先、实践优先"** 的设计思路，以 Azure GPU、网络、身份、存储等共享基础设施为基础。

### 两条主线

1. **AKS + KAITO** - 模型运行与微调路线
2. **Anyscale on Azure** - 分布式数据处理、训练和服务化路线

> 另设 **Azure AI Foundry** hands-on 主线(Track C):通过 **managed compute**(专用 GPU 在线端点)与 **Fireworks AI on Foundry**(合作方 Models-as-a-Service)从模型目录直接消费模型,无需自管 GPU / Kubernetes / Ray。

## 学习成果

课程内容以 **Hands-on Lab** 为核心，学员通过以下真实工程资产完成学习：

- **工具**: Bicep、Shell、YAML、Python
- **实践内容**:
  - 环境搭建
  - 模型部署
  - 推理验证
  - 微调实验
  - Ray 分布式任务运行
  - 服务化发布
  - 监控与扩展
  - 平台选型总结

## 最终交付

不仅是一门课程，而是一套**可直接 Fork 和复用的 GitHub Workshop Repository**，帮助客户：

- 在 Azure 上快速构建企业级 AI Infrastructure
- 理解不同平台的适用场景、能力边界和最佳实践