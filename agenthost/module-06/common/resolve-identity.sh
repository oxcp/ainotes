#!/usr/bin/env bash
# resolve-identity.sh -- Resolve the existing Module-01 UAMI.
#
# Used by deployment stages for Agent configuration, database and sandbox access.
# Usage: bash common/resolve-identity.sh
# Env overrides: AGENT_IDENTITY_RESOURCE_ID, SUBSCRIPTION_ID, RESOURCE_GROUP,
#                DEPLOYMENT_SN, IDENTITY_NAME.
# Prerequisites: Module 1 deployed; az and jq installed.
# Read-only: stdout is a nonsecret JSON object, not an access token.
set +x
set -euo pipefail

fail() {
  printf 'Error [identity]: %s\n' "$*" >&2
  exit 1
}
# -- Validate arguments and required tools -----------------------------------
if (($#)); then
  if [[ $# == 1 && "$1" == --help ]]; then
    printf '%s\n' 'Usage (from module-06): bash common/resolve-identity.sh' \
      'Read Module-01 UAMI using AGENT_IDENTITY_RESOURCE_ID, or IDENTITY_NAME / id-agenthost-<SN>.' \
      'Outputs nonsecret resource, client, principal and tenant IDs as JSON; never assigns roles.'
    exit 0
  fi
  fail "Unexpected arguments; use --help"
fi
for tool in az jq; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
# -- Resolve by explicit ARM ID, or by Module-01 resource names ---------------
identity="$(printf '%s' "${AGENT_IDENTITY_RESOURCE_ID:-}" | tr -d '\r\n')"
# ARM resource IDs are case-insensitive, including Azure-returned resource type segments.
identity_pattern='^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft[.]managedidentity/userassignedidentities/[^/]+$'
if [[ -n "$identity" ]]; then
  [[ "${identity,,}" =~ $identity_pattern ]] \
    || fail "AGENT_IDENTITY_RESOURCE_ID must be a UAMI ARM resource ID (/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/...)"
  result="$(az identity show --ids "$identity" -o json)" || fail "Cannot read Agent UAMI"
else
  subscription="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv | tr -d '\r\n')}"
  resource_group="${RESOURCE_GROUP:-rg-agenthost-workshop}"
  name="${IDENTITY_NAME:-}"
  for key in subscription resource_group name; do
    printf -v "$key" '%s' "$(printf '%s' "${!key}" | tr -d '\r\n')"
  done
  if [[ -z "$name" ]]; then
    sn="${DEPLOYMENT_SN:-$(az group show --subscription "$subscription" -n "$resource_group" --query tags.deploymentSN -o tsv | tr -d '\r\n')}"
    sn="$(printf '%s' "$sn" | tr -d '\r\n')"
    [[ "$sn" =~ ^[a-zA-Z0-9-]+$ ]] || fail "Set IDENTITY_NAME or restore Module-01 deploymentSN"
    name="id-agenthost-$sn"
  fi
  result="$(az identity show --subscription "$subscription" -g "$resource_group" -n "$name" -o json)" \
    || fail "Cannot read Module-01 UAMI"
fi
# -- Validate the response and return nonsecret identity settings -------------
jq -e --arg requested "$identity" --arg pattern "$identity_pattern" '
  if ([.id,.name,.clientId,.principalId,.tenantId] | all(.[]; type=="string" and length>0))
     and (.id | test($pattern; "i"))
     and ($requested=="" or (.id|ascii_downcase)==($requested|ascii_downcase))
  then {AGENT_IDENTITY_RESOURCE_ID:.id,AGENT_IDENTITY_NAME:.name,
        AGENT_IDENTITY_CLIENT_ID:.clientId,AGENT_IDENTITY_PRINCIPAL_ID:.principalId,
        AZURE_TENANT_ID:.tenantId}
  else error("Incomplete or mismatched UAMI response") end
' <<<"$result" || fail "Invalid Agent UAMI identity response"
