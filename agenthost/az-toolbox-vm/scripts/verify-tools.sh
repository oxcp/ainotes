#!/usr/bin/env bash
set -euo pipefail

trap 'status=$?; printf "ERROR: toolbox verification failed at line %s (exit %s).\n" "$LINENO" "$status" >&2; exit "$status"' ERR

for tool in az git curl jq azd kubectl dpkg awk bash aca openssl timeout; do
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

echo "=== Bash ==="
bash --version
if ((BASH_VERSINFO[0] < 4)); then
  echo "ERROR: Bash 4+ is required." >&2
  exit 1
fi

echo "=== OpenSSL ==="
openssl version

echo "=== GNU timeout ==="
TIMEOUT_VERSION="$(timeout --version)"
printf '%s\n' "${TIMEOUT_VERSION}"
if [[ "${TIMEOUT_VERSION}" != *'GNU coreutils'* ]]; then
  echo "ERROR: Module-06 requires GNU timeout (coreutils)." >&2
  exit 1
fi

echo "=== Bicep ==="
BICEP_VERSION_OUTPUT="$(az bicep version)"
printf '%s\n' "${BICEP_VERSION_OUTPUT}"
if [[ ! "${BICEP_VERSION_OUTPUT}" =~ Bicep\ CLI\ version\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
  echo "ERROR: could not parse the installed Bicep version." >&2
  exit 1
fi
if ! dpkg --compare-versions "${BASH_REMATCH[1]}" ge 0.48.1; then
  echo "ERROR: The workshop requires Bicep 0.48.1 or newer, starting with Module 01." >&2
  exit 1
fi

echo "=== Independent ACA CLI ==="
ACA_VERSION_OUTPUT="$(aca --version)"
printf '%s\n' "${ACA_VERSION_OUTPUT}"
if [[ ! "${ACA_VERSION_OUTPUT}" =~ (^|[[:space:]])v?([0-9]+\.[0-9]+\.[0-9]+(-[[:alnum:].]+)?)($|[[:space:]+]) ]]; then
  echo "ERROR: could not parse the installed aca CLI version." >&2
  exit 1
fi
ACA_VERSION="${BASH_REMATCH[2]}"
if ! dpkg --compare-versions "${ACA_VERSION/-/\~}" ge '1.0.0~preview.5'; then
  echo "ERROR: Module-06 requires the independent aca CLI 1.0.0-preview.5 or newer." >&2
  exit 1
fi
aca sandbox --help >/dev/null
aca sandboxgroup --help >/dev/null
az acr build --help >/dev/null

echo "All required toolbox checks passed."
