# Lab 01: Shared AKS infrastructure

## Objectives
Deploy VNet, AKS, ACR, Storage, and optional GPU capacity using Bicep.

## Prerequisites
Lab 00 complete and `.env` populated.

## Exercises
1. Review `infra/main.bicep`.
2. Run `../../scripts/deploy-infra.sh`.
3. Run `../../scripts/validate-infra.sh`.
4. Inspect nodes, namespaces, pods, and KAITO CRDs.

## Success criteria
AKS credentials work and the cluster is healthy.

## Cleanup
Retain resources for KAITO labs, or run `../../scripts/cleanup.sh`.
