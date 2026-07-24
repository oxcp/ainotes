# Platform selection guide

## VM + GPU
Choose when full host control or a specialized, non-orchestrated runtime is the dominant requirement.

## Self-managed AKS + GPU
Choose when the organization needs Kubernetes control and is prepared to own the serving, scheduling, image, scaling, and operations stack.

## AKS + KAITO
Choose for a Kubernetes-native workflow that simplifies supported open-model inference and fine-tuning on AKS.

## Anyscale on Azure
Choose for managed Ray-based distributed Python workloads spanning data processing, training, batch inference, and online services.

## Azure AI Foundry
Choose when the priority is consuming models as managed endpoints and building AI apps and agents, without owning GPU, Kubernetes, or Ray infrastructure. Foundry provides a model catalog, managed fine-tuning, evaluation, prompt orchestration, and the Agent Service. It is the highest-abstraction option: you consume inference and tuning as a service rather than provisioning and operating GPU compute yourself. Two hands-on paths are covered:

- **Managed compute (Lab 09):** deploy an open model to a dedicated GPU-backed online endpoint. Consumes VM core quota; billed per compute uptime.
- **Fireworks AI on Foundry (Lab 10):** consume a partner model as a token-billed Models-as-a-Service endpoint, with no dedicated compute to manage.

## Decision questions

1. Is Kubernetes control a requirement or an implementation detail?
2. Is the workload primarily model deployment or distributed Python/Ray?
3. Is the model/runtime supported by the selected managed workflow?
4. What are the regional, quota, network, identity, and cost constraints?
5. Who owns platform operations after the workshop?

## Platform comparison at a glance

| Dimension | VM + GPU | Self-managed AKS | AKS + KAITO | Anyscale on Azure | Azure AI Foundry |
|---|---|---|---|---|---|
| Abstraction level | Lowest | Low | Medium | Medium-high | Highest |
| You manage | Host, driver, runtime | K8s + serving stack | K8s cluster; KAITO simplifies model workflows | Ray app code + compute config | App/agent config only |
| GPU ownership | Yes | Yes | Yes | Yes (via Anyscale compute) | No (consumed as a service) |
| Primary workload | Any host workload | Any container workload | Open-model inference & fine-tuning | Distributed Ray: data / train / serve | Managed model endpoints, agents, tuning |
| Fine-tuning | Manual | Manual | KAITO tuning workflow | Ray Train | Managed fine-tuning |
| Scaling | Manual / VMSS | Cluster autoscaler + custom | AKS + KAITO | Ray autoscaling | Platform-managed |
| Operational ownership | Highest | High | Medium | Low-medium | Lowest |
| Hands-on in this workshop | Reference | Reference | ✅ Track A | ✅ Track B | ✅ Track C (Labs 09–10) |
