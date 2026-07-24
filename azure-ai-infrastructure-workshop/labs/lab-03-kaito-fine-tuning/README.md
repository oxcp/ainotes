# Lab 03: KAITO fine-tuning

This is a guided, version-sensitive lab. Validate the selected model, method, input format, ACR permissions, and Workspace API against current Microsoft Learn documentation before delivery.

## Flow

1. Review the synthetic dataset notice.
2. Upload or expose the validated training data format.
3. Create the required registry secret outside Git.
4. Replace placeholders in `manifests/tuning-workspace.yaml`.
5. Apply and monitor the Workspace.
6. Validate that the adapter artifact is written to the approved ACR location.
7. Deploy the adapter using the current supported workflow.
8. Compare responses, without treating a tiny workshop dataset as a quality benchmark.

## Observe

```bash
kubectl get workspace
kubectl describe workspace workshop-model-tuning
kubectl get jobs,pods
kubectl get events --sort-by=.lastTimestamp
```
