
<!--
Azure AI Infrastructure Workshop 的目的,是帮助客户从"如何在 Azure 上消费 GPU、运行 AI 工作负载"的基础设施视角来理解和选型,而不是单纯学习某一个模型或服务;它以 Azure GPU、网络、身份、存储等共享基础设施为底座,通过三条 hands-on 主线横向对比不同的 AI 平台——Track A(AKS + KAITO,Kubernetes 原生的开源模型推理与微调)、Track B(Anyscale on Azure,托管 Ray 平台上的 Ray Data / Serve / Train 分布式数据、训练与服务化)、Track C(Azure AI Foundry,以 managed compute 专用 GPU 端点与 Fireworks AI 合作方 Models-as-a-Service 两种方式从模型目录直接消费模型),覆盖从"自管 Kubernetes"到"全托管按 token 计费"的完整抽象层谱系。内容上采用"基础设施优先、平台优先、实践优先"的设计思路,以真实工程资产(Bicep、Shell、YAML、Python)组织成 Lab 00–10:先做预检与配额校验、部署共享 AKS 基础设施,再分平台完成模型部署、推理验证、微调、Ray 分布式任务与服务化,最后由 lab-10 统一做跨平台的可观测性与对比(含部署体验、资源归属、计费模型、延迟等维度),并配套面向讲师/学员的文档、平台选型指南与清理指引;最终交付的不只是一门课程,而是一套可直接 Fork 复用的 GitHub Workshop Repository,帮助客户快速搭建企业级 Azure AI Infrastructure,并理解各平台的适用场景、能力边界与最佳实践。
-->

# Azure AI Infrastructure Workshop

## 目标

本 Workshop 旨在帮助客户从"**如何在 Azure 上消费 GPU、运行 AI Workload**"的**基础设施视角**理解和选型，而不是单纯学习某一个模型或服务。以 Azure GPU、网络、身份、存储等**共享基础设施**为底座，帮助学员掌握在 Azure 上进行模型推理、微调、分布式训练和规模化部署时的架构选择与最佳实践。

## 三条 Hands-on 主线

通过三条动手主线横向对比不同 AI 平台，覆盖从"自管 Kubernetes"到"全托管按 token 计费"的完整**抽象层谱系**：

- **Track A — AKS + KAITO**：Kubernetes 原生的 AI 平台，简化开源模型在 AKS 上的部署、推理与微调。
- **Track B — Anyscale on Azure**：Azure 集成的 Managed Ray 平台，实现 Ray Data、Ray Serve、Ray Train 等分布式数据处理、训练与服务化。
- **Track C — Azure AI Foundry**：从模型目录直接消费模型，含两条路径——**managed compute**(专用 GPU 在线端点)与 **Fireworks AI on Foundry**(合作方 Models-as-a-Service)，无需自管 GPU / Kubernetes / Ray。

> **注**：Anyscale 部分基于官方的 **Anyscale on Azure** 服务，而非自建 Anyscale on AKS 平台。

## 课程设计思路

采用 **"基础设施优先、平台优先、实践优先"** 的设计思路：先以共享基础设施为基础，再分平台展开实践，最后统一横向对比。

- 以真实工程资产(**Bicep、Shell、YAML、Python**)组织为 **Lab 00–10**。
- 先做**预检与配额校验**、部署**共享 AKS 基础设施**，再按平台完成模型部署、推理验证、微调、Ray 分布式任务与服务化。
- 由 **Lab 10** 统一做跨平台的**可观测性与对比**(部署体验、资源归属、计费模型、延迟等维度)，因此对比环节位于所有 Lab 之后。
- 配套面向**讲师/学员**的文档、**平台选型指南**与**清理指引**。

## 学习成果

课程以 **Hands-on Lab** 为核心，学员将完成：

- 环境搭建与配额校验
- 模型部署与推理验证(KAITO / Foundry managed compute / Fireworks on Foundry)
- 微调实验(KAITO)
- Ray 分布式数据、训练与服务化(Anyscale on Azure)
- 监控、扩展与跨平台对比
- 平台选型总结与资源清理

## 最终交付

不仅是一门课程，而是一套**可直接 Fork 和复用的 GitHub Workshop Repository**，帮助客户：

- 在 Azure 上快速构建企业级 AI Infrastructure
- 理解不同平台的适用场景、能力边界和最佳实践