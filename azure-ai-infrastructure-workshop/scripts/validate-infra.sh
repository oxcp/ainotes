#!/usr/bin/env bash
set -euo pipefail
source .env
az aks get-credentials -g "$AZURE_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --overwrite-existing
kubectl get nodes -o wide
kubectl get pods -A
kubectl get crd | grep -i kaito || true
