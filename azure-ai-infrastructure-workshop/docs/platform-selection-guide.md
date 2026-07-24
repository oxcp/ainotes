# Platform selection guide

## VM + GPU
Choose when full host control or a specialized, non-orchestrated runtime is the dominant requirement.

## Self-managed AKS + GPU
Choose when the organization needs Kubernetes control and is prepared to own the serving, scheduling, image, scaling, and operations stack.

## AKS + KAITO
Choose for a Kubernetes-native workflow that simplifies supported open-model inference and fine-tuning on AKS.

## Anyscale on Azure
Choose for managed Ray-based distributed Python workloads spanning data processing, training, batch inference, and online services.

## Decision questions

1. Is Kubernetes control a requirement or an implementation detail?
2. Is the workload primarily model deployment or distributed Python/Ray?
3. Is the model/runtime supported by the selected managed workflow?
4. What are the regional, quota, network, identity, and cost constraints?
5. Who owns platform operations after the workshop?
