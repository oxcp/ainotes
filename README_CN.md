# AI Notes

> 🌐 语言 / Language: [English](README.md) | **中文**

这是一个聚焦于 Azure AI 基础设施和云原生工作负载的知识库，包含动手实验、部署指南、技术深度解析和模型评测。

本仓库将可运行的脚本、基础设施模板与详细文档结合在一起，内容涵盖 AI 智能体托管、分布式推理与微调、AKS 网络与可观测性，以及基础模型能力对比。

## 浏览内容

浏览本仓库最便捷的方式是访问 [AI Notes 网站](https://oxcp.github.io/ainotes/)。网站中的 Markdown 阅读器支持类似 GitHub 的渲染效果、代码快速复制、嵌入式视频、长文章目录展示和点击跳转，以及多模块 Workshop 导航。

### 本地预览

克隆仓库后，可以在本地以与 GitHub 页面近似的显示效果浏览仓库内容。具体做法请参考[本地预览指南](preview_CN.md)。

### Workshop 与动手指南

| 主题 | 说明 |
|---|---|
| [Azure AI 智能体托管](agenthost/README_CN.md) | 包含基础和扩展两部分的模块化 Workshop。基础部分面向企业与消费者场景，对比 Microsoft Foundry 托管智能体、AKS 与 `agent-sandbox`、Azure Container Apps Sandboxes，涵盖共享基础设施、身份认证、状态持久化、隔离、生命周期管理、成本与生产环境强化。扩展部分通过 A2A 通信和 LangGraph 编排协作五个智能体，实现数据处理、企业知识库、业务分析和计划等场景，并使用 Azure HorizonDB（默认）或 Azure Database for PostgreSQL Flexible Server 进行结构化数据与向量的存储和检索。 |
| [AKS Agent Sandbox 动手实验](aks-agent-sandbox/README_CN.md) | 基于 AKS 上的 Kata VM isolation v2 和 Agent Sandbox / Pod Snapshot 扩展的动手实验。涵盖环境搭建、预热池创建与申领、本地 Sandbox 管理门户、Blob 中的进程状态快照、冷启动唤醒与快照恢复。完成环境搭建和扩展安装后，按[中文演示指南](aks-agent-sandbox/demo_CN.md)进行验证、演示和演示资源清理。 |
| [Azure AI 基础设施 Workshop](azure-ai-infrastructure-workshop/README.md) | 端到端实验，涵盖 AKS 与 KAITO、Anyscale on Azure、Ray Data/Serve/Train、Microsoft Foundry 托管计算、合作伙伴模型和可观测性。 |
| [AKS 上的 Anyscale](anyscale-on-aks/README_CN.md) | 在 AKS 上部署 Anyscale Operator，并使用 Ray 运行分布式模型推理和微调的脚本与指南。也提供[英文指南](anyscale-on-aks/README.md)。 |
| [Azure 上的 Anyscale](anyscale-on-azure/README.md) | Anyscale Kubernetes Operator 认证所需的 Microsoft Entra 服务主体配置，附脱敏输出示例和[权限检查脚本](anyscale-on-azure/check_permission.sh)。 |
| [AKS 上的 CNI](cni-on-aks/README.md) | 在 AKS 中管理和安装容器网络接口（CNI）的动手指南，包括创建 BYO CNI 集群、安装 Cilium，以及验证网络连通性。 |
| [AKS GitOps 与 Flux、ACR Artifact Cache](gitops-acr-cache/README.md) | 面向企业受限网络的出站优先镜像交付架构，结合 Flux 镜像自动化、Pull Request 审批，以及从上游 ACR 到下游 ACR 的按需缓存。包含部署与验证脚本，以及[最小 GitOps 演示](gitops-acr-cache/gitops/README.md)。 |
| [将 Azure 指标导出至 Prometheus 和 Grafana](azmon-export-to-prometheus/README.md) | 将 Azure Monitor 指标导出为 Prometheus 格式并使用 Grafana 进行可视化的实践指南。 |
| [AKS 上的 Istio 监控](istio-on-aks/monitoring/README.md) | 面向 AKS Istio 插件的综合可观测性指南，包括指标、访问日志、链路追踪和相关工具。 |
| [在 Azure 上部署 E2B Embed](e2b-on-azure/Embed/quick-install.md) | 将 E2B Embed 部署到单实例 Azure VM Scale Set 的安装指南。可通过指南内的链接查看使用现有 VNet 或 Storage Private Link 的高级配置。 |

### 技术笔记与评测

| 主题 | 说明 |
|---|---|
| [跨模型代码生成对比](codegen-compare-across-models/README.md) | 代码生成模型的通用及真实场景对比，包括提示词、生成结果、示例和基准测试笔记。 |
| [生物医疗与健康领域模型](models-healthcare/models-in-Bio-Healthcare-industry.md) | 基础模型在生物医学和医疗健康场景中的对比。 |
| [医学影像模型对比](models-healthcare/model-4-SKH-TC.md) | 医学影像场景所用模型的评测笔记。 |
| [Kubernetes 多集群管理](multi-k8s-mgmt/multiclustermgmt.md) | Kubernetes 多集群管理方案与工具笔记。 |

### 基准测试与测试报告

| 报告 | 说明 | 语言 |
|---|---|---|
| AKS + Azure Elastic SAN：12 万级 AI Agent 基础设施规模测试 | 对 120,000 个挂载持久卷的 Pod 进行规模验证，涵盖资源与容量设计、部署限制与实测速率、测试方法、分轮卷配置和 Pod 就绪结果，以及生产部署建议。 | [简体中文](test-report/AKS+ESAN-AIAgent-benchmark-report-cn.md) · [English](test-report/AKS+ESAN-AIAgent-benchmark-report-en.md) |

## 仓库结构

```text
agenthost/                       智能体托管 Workshop 与部署资源
aks-agent-sandbox/              AKS Agent Sandbox 动手实验：Kata v2、预热池、门户、快照与恢复
anyscale-on-aks/                 Anyscale Operator、Ray 服务与训练示例
anyscale-on-azure/               Anyscale on Azure 介绍、Operator 身份配置与权限检查脚本
azmon-export-to-prometheus/      Azure Monitor 指标导出指南与清单
azure-ai-infrastructure-workshop/ 多路线 Azure AI 基础设施实验
cni-on-aks/                      AKS CNI 管理与 Cilium 安装指南
codegen-compare-across-models/   代码生成对比与相关资料
e2b-on-azure/Embed/              E2B Embed 部署指南与内置 Azure runtime
gitops-acr-cache/                AKS GitOps、Flux 镜像自动化与 ACR Artifact Cache 指南和脚本
istio-on-aks/                    AKS Istio 可观测性指南
models-healthcare/               医疗健康与医学模型评测
multi-k8s-mgmt/                  Kubernetes 多集群管理笔记
test-report/                     AI 基础设施基准与规模测试报告
index.html                       GitHub Pages 首页
markdown-viewer.html             网站共用的 Markdown 阅读器
preview.html                     本地文件浏览页面，支持搜索与文件类型多选筛选
preview.cjs                      只读本地 HTTP 服务与仓库目录 API
code-viewer.html                 语法高亮代码阅读器与 JSON 源码/格式化/树形视图
preview.md                       英文本地预览指南（Node.js 与 Docker）
preview_CN.md                    中文本地预览指南（Node.js 与 Docker）
```

## 使用仓库

大部分文档可直接在 GitHub 上阅读。动手实验部分还包含 Bash 脚本、Bicep 模板、Kubernetes 清单、Python 示例和配置文件，可以在本地克隆仓库后使用。

```bash
git clone https://github.com/oxcp/ainotes.git
cd ainotes
```

部署资源前，请阅读每个 Workshop 中的先决条件和清理说明。实验所使用的 Azure 服务可能会产生费用。