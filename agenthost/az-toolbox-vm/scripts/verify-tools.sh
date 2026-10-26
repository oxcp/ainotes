#!/usr/bin/env bash
set -euo pipefail

trap 'status=$?; printf "ERROR: toolbox verification failed at line %s (exit %s).\n" "$LINENO" "$status" >&2; exit "$status"' ERR

for tool in az git curl jq azd kubectl dpkg awk; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR: required command '${tool}' is not in PATH." >&2
    exit 1
  fi
done

echo "=== Azure CLI ==="
AZ_VERSION_JSON="$(az version --output json)"
printf '%s\n' "${AZ_VERSION_JSON}"
AZ_VERSION="$(jq -er '."azure-cli"' <<< "${AZ_VERSION_JSON}")"
if ! dpkg --compare-versions "${AZ_VERSION}" ge 2.80.0; then
  echo "ERROR: Azure CLI ${AZ_VERSION} is older than required version 2.80.0." >&2
  exit 1
fi

echo "=== Git ==="
git --version

echo "=== curl ==="
curl --version

echo "=== jq ==="
jq --version

echo "=== Azure Developer CLI ==="
azd version

echo "=== Foundry azd Extensions ==="
FOUNDRY_EXTENSIONS="$(azd ext list --installed --no-prompt)"
printf '%s\n' "${FOUNDRY_EXTENSIONS}"
if ! awk '$1 == "microsoft.foundry" { found=1 } END { exit !found }' <<< "${FOUNDRY_EXTENSIONS}"; then
  echo "ERROR: microsoft.foundry is not installed for the current user." >&2
  exit 1
fi

echo "=== kubectl ==="
kubectl version --client

echo "=== AKS Pod Sandboxing CLI capability ==="
AKS_HELP="$(az aks create --help)"
if [[ "${AKS_HELP}" != *--workload-runtime* ]]; then
  echo "ERROR: Azure CLI does not expose the AKS --workload-runtime option." >&2
  exit 1
fi
echo "az aks create supports --workload-runtime; no aks-preview extension is required."

echo "=== Azure CLI Extensions ==="
az extension list --output table
CONTAINERAPP_VERSION="$(az extension show --name containerapp --query version --output tsv)"
if [[ -z "${CONTAINERAPP_VERSION}" ]]; then
  echo "ERROR: the Container Apps extension has no installed version." >&2
  exit 1
fi
printf 'containerapp version: %s (installed with preview releases allowed)\n' "${CONTAINERAPP_VERSION}"

echo "All required toolbox checks passed."
