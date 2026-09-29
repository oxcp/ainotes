# AI Notes

A collection of hands-on workshops, deployment guides, technical deep dives, and model evaluations focused on AI infrastructure and cloud-native workloads on Azure.

The repository combines runnable scripts and infrastructure templates with detailed documentation. Topics include hosting AI agents, distributed inference and fine-tuning, AKS networking and observability, and comparisons of foundation-model capabilities.

## Browse the Content

The easiest way to explore the repository is through the [AI Notes site](https://oxcp.github.io/ainotes/). Its Markdown viewer provides GitHub-style rendering, code-copy controls, embedded videos, and navigation for multi-module workshops.

### Workshops and Hands-on Guides

| Area | Description |
|---|---|
| [Agent Hosting on Azure](agenthost/readme.md) | A modular workshop comparing Microsoft Foundry hosted agents, AKS with `agent-sandbox`, and Azure Container Apps Sandboxes. It covers shared infrastructure, identity, state persistence, isolation, lifecycle management, and production considerations. |
| [Azure AI Infrastructure Workshop](azure-ai-infrastructure-workshop/README.md) | End-to-end labs for AKS with KAITO, Anyscale on Azure, Ray Data/Serve/Train, Microsoft Foundry managed compute, partner models, and observability. |
| [Anyscale on AKS](anyscale-on-aks/README.md) | Scripts and guidance for deploying the Anyscale Operator on AKS and running distributed model inference and fine-tuning with Ray. A [Chinese guide](anyscale-on-aks/README_CN.md) is also available. |
| [Azure Metrics to Prometheus and Grafana](azmon-export-to-prometheus/README.md) | A practical guide for exporting Azure Monitor metrics in Prometheus format and visualizing them with Grafana. |
| [Istio Monitoring on AKS](istio-on-aks/monitoring/README.md) | A consolidated observability guide for the AKS Istio add-on, including metrics, access logs, tracing, and supporting tools. |

### Technical Notes and Evaluations

| Area | Description |
|---|---|
| [Code Generation Across Models](codegen-compare-across-models/README.md) | General and real-world comparisons of code-generation models, with prompts, generated outputs, examples, and benchmark notes. |
| [Models in Bio and Healthcare](models-healthcare/models-in-Bio-Healthcare-industry.md) | Comparisons of foundation models for biomedical and healthcare scenarios. |
| [Medical Image Model Comparison](models-healthcare/model-4-SKH-TC.md) | Evaluation notes for models used in medical-image scenarios. |
| [Multi-cluster Kubernetes Management](multi-k8s-mgmt/multiclustermgmt.md) | Notes on approaches and tools for managing multiple Kubernetes clusters. |

## Repository Structure

```text
agenthost/                       Agent-hosting workshop and deployment assets
anyscale-on-aks/                 Anyscale Operator, Ray serving, and training examples
azmon-export-to-prometheus/      Azure Monitor metrics exporter guide and manifests
azure-ai-infrastructure-workshop/ Multi-track Azure AI infrastructure labs
codegen-compare-across-models/   Code-generation comparisons and source material
istio-on-aks/                    AKS Istio observability guidance
models-healthcare/               Healthcare and medical-model evaluations
multi-k8s-mgmt/                  Kubernetes multi-cluster management notes
index.html                       GitHub Pages landing page
markdown-viewer.html             Shared Markdown renderer for the site
```

## Using the Repository

Most documents can be read directly on GitHub. The hands-on sections also include Bash scripts, Bicep templates, Kubernetes manifests, Python examples, and configuration files that can be used from a local clone.

```bash
git clone https://github.com/oxcp/ainotes.git
cd ainotes
```

Review the prerequisites and cleanup instructions in each workshop before deploying resources. Azure services used by the labs may incur charges.
