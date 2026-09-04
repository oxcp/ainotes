#!/usr/bin/env bash
# Check the local tools, sign-in state, and Azure RBAC required by the workshop.

set -u

MIN_AZ_VERSION="2.80.0"
TOTAL_CHECKS=15
CURRENT_CHECK=0
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"

GROUP_COMMON="Common prerequisites for all modules"
GROUP_MODULE_01="Module 01"
GROUP_MODULE_02="Module 02"
GROUP_MODULE_03="Module 03"
GROUP_MODULE_04="Module 04"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

declare -a RESULT_GROUPS=()
declare -a ITEMS=()
declare -a RESULTS=()
declare -a DETAILS=()
declare -a LINKS=()
declare -a REQUIRED_DEPLOYMENT_ACTIONS=(
  "Microsoft.Resources/subscriptions/resourceGroups/write"
  "Microsoft.Resources/subscriptions/providers/register/action"
  "Microsoft.Resources/deployments/write"
  "Microsoft.Resources/deployments/validate/action"
  "Microsoft.ManagedIdentity/userAssignedIdentities/write"
  "Microsoft.Storage/storageAccounts/write"
  "Microsoft.Storage/storageAccounts/blobServices/write"
  "Microsoft.Storage/storageAccounts/blobServices/containers/write"
  "Microsoft.KeyVault/vaults/write"
  "Microsoft.ContainerRegistry/registries/write"
  "Microsoft.CognitiveServices/accounts/write"
  "Microsoft.CognitiveServices/accounts/projects/write"
  "Microsoft.CognitiveServices/accounts/deployments/write"
  "Microsoft.CognitiveServices/accounts/projects/connections/write"
  "Microsoft.CognitiveServices/accounts/defenderForAISettings/write"
  "Microsoft.ApiManagement/service/write"
  "Microsoft.ApiManagement/service/backends/write"
  "Microsoft.ApiManagement/service/apis/write"
  "Microsoft.ApiManagement/service/apis/operations/write"
  "Microsoft.ApiManagement/service/apis/policies/write"
  "Microsoft.ContainerService/managedClusters/write"
  "Microsoft.ContainerService/managedClusters/agentPools/write"
  "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action"
  "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write"
  "Microsoft.App/SandboxGroups/write"
  "Microsoft.Authorization/roleAssignments/write"
)

add_result() {
  RESULT_GROUPS+=("$1")
  ITEMS+=("$2")
  RESULTS+=("$3")
  DETAILS+=("$4")
  LINKS+=("$5")
}

show_progress() {
  ((CURRENT_CHECK += 1))
  printf '[%02d/%02d] Checking %s...\n' "$CURRENT_CHECK" "$TOTAL_CHECKS" "$1"
}

version_at_least() {
  local actual="${1%%[-+]*}"
  local required="${2%%[-+]*}"
  local actual_major actual_minor actual_patch
  local required_major required_minor required_patch

  IFS=. read -r actual_major actual_minor actual_patch <<< "$actual"
  IFS=. read -r required_major required_minor required_patch <<< "$required"
  actual_minor="${actual_minor:-0}"
  actual_patch="${actual_patch:-0}"
  required_minor="${required_minor:-0}"
  required_patch="${required_patch:-0}"

  ((10#$actual_major > 10#$required_major)) ||
    ((10#$actual_major == 10#$required_major && 10#$actual_minor > 10#$required_minor)) ||
    ((10#$actual_major == 10#$required_major && 10#$actual_minor == 10#$required_minor && 10#$actual_patch >= 10#$required_patch))
}

has_role() {
  local role_name="$1"
  grep -Fqx "$role_name" <<< "$ROLE_NAMES"
}

action_matches_pattern() {
  local action="${1,,}"
  local pattern="${2,,}"
  [[ "$action" == $pattern ]]
}

has_effective_permission() {
  local required_action="$1"
  local permission_blocks="${2:-$PERMISSION_BLOCKS}"
  local allowed_patterns denied_patterns pattern
  local block_allows block_denies

  while IFS=$'\t' read -r allowed_patterns denied_patterns; do
    block_allows=false
    block_denies=false

    IFS='|' read -ra patterns <<< "$allowed_patterns"
    for pattern in "${patterns[@]}"; do
      if [[ -n "$pattern" ]] && action_matches_pattern "$required_action" "$pattern"; then
        block_allows=true
        break
      fi
    done

    $block_allows || continue

    IFS='|' read -ra patterns <<< "$denied_patterns"
    for pattern in "${patterns[@]}"; do
      if [[ -n "$pattern" ]] && action_matches_pattern "$required_action" "$pattern"; then
        block_denies=true
        break
      fi
    done

    $block_denies || return 0
  done <<< "$permission_blocks"

  return 1
}

AZ_INSTALLED=false
AZ_LOGGED_IN=false
AZ_VERSION=""
SUBSCRIPTION_ID=""
SUBSCRIPTION_NAME=""
IDENTITY_OBJECT_ID=""
ROLE_NAMES=""
PERMISSION_BLOCKS=""

printf '%bAgent Hosting on Azure Workshop - Prerequisite Check%b\n------\n' "$BOLD" "$RESET"

# Common prerequisites for all modules
show_progress "Azure CLI $MIN_AZ_VERSION+"
if command -v az >/dev/null 2>&1; then
  AZ_INSTALLED=true
  AZ_VERSION="$(az version --query '"azure-cli"' --output tsv 2>/dev/null | tr -d '\r')"
fi

if $AZ_INSTALLED; then
  if [[ -n "$AZ_VERSION" ]] && version_at_least "$AZ_VERSION" "$MIN_AZ_VERSION"; then
    add_result "$GROUP_COMMON" "Azure CLI $MIN_AZ_VERSION+" "Pass" "Installed: $AZ_VERSION" ""
  else
    add_result "$GROUP_COMMON" "Azure CLI $MIN_AZ_VERSION+" "Failed" "Installed: ${AZ_VERSION:-unknown}" "https://learn.microsoft.com/cli/azure/install-azure-cli"
  fi
else
  add_result "$GROUP_COMMON" "Azure CLI $MIN_AZ_VERSION+" "Failed" "az was not found" "https://learn.microsoft.com/cli/azure/install-azure-cli"
fi

show_progress "active Azure login"
if $AZ_INSTALLED; then
  ACCOUNT_INFO="$(az account show \
    --query '{subscriptionId:id, subscriptionName:name, accountType:user.type, accountName:user.name}' \
    --output tsv 2>/dev/null | tr -d '\r')"
  if [[ -n "$ACCOUNT_INFO" ]]; then
    AZ_LOGGED_IN=true
    IFS=$'\t' read -r SUBSCRIPTION_ID SUBSCRIPTION_NAME ACCOUNT_TYPE ACCOUNT_NAME <<< "$ACCOUNT_INFO"
  fi
fi

if $AZ_LOGGED_IN; then
  add_result "$GROUP_COMMON" "Active Azure login" "Pass" "$SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)" ""
else
  add_result "$GROUP_COMMON" "Active Azure login" "Failed" "Run az login" "https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively"
fi

show_progress "workshop deployment permissions"
if $AZ_LOGGED_IN; then
  if [[ "$ACCOUNT_TYPE" == "user" ]]; then
    IDENTITY_OBJECT_ID="$(az ad signed-in-user show --query id --output tsv 2>/dev/null | tr -d '\r')"
  elif [[ -n "$ACCOUNT_NAME" ]]; then
    IDENTITY_OBJECT_ID="$(az ad sp show --id "$ACCOUNT_NAME" --query id --output tsv 2>/dev/null | tr -d '\r')"
  fi

  if [[ -n "$SUBSCRIPTION_ID" ]]; then
    PERMISSION_BLOCKS="$(az rest \
      --method get \
      --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" \
      --query "value[].[join('|', actions), join('|', notActions)]" \
      --output tsv 2>/dev/null | tr -d '\r')"
  fi

  if [[ -n "$IDENTITY_OBJECT_ID" && -n "$SUBSCRIPTION_ID" ]]; then
    ROLE_NAMES="$(az role assignment list \
      --assignee-object-id "$IDENTITY_OBJECT_ID" \
      --scope "/subscriptions/$SUBSCRIPTION_ID" \
      --include-groups \
      --include-inherited \
      --query '[].roleDefinitionName' \
      --output tsv 2>/dev/null | tr -d '\r')"
  fi
fi

MISSING_DEPLOYMENT_ACTIONS=()
if [[ -n "$PERMISSION_BLOCKS" ]]; then
  for required_action in "${REQUIRED_DEPLOYMENT_ACTIONS[@]}"; do
    has_effective_permission "$required_action" || MISSING_DEPLOYMENT_ACTIONS+=("$required_action")
  done
fi

if [[ -z "$PERMISSION_BLOCKS" ]]; then
  add_result "$GROUP_COMMON" "Workshop deployment permissions" "Failed" "Could not read effective permissions at subscription scope" "https://learn.microsoft.com/azure/role-based-access-control/check-access"
elif ((${#MISSING_DEPLOYMENT_ACTIONS[@]} == 0)); then
  add_result "$GROUP_COMMON" "Workshop deployment permissions" "Pass" "All ${#REQUIRED_DEPLOYMENT_ACTIONS[@]} required ARM actions are allowed" ""
else
  add_result "$GROUP_COMMON" "Workshop deployment permissions" "Failed" "Missing ${#MISSING_DEPLOYMENT_ACTIONS[@]} required ARM action(s); see the list below" "https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal-subscription-admin"
fi

# Module 01
show_progress "curl installation"
if command -v curl >/dev/null 2>&1; then
  CURL_VERSION="$(curl --version 2>/dev/null | sed -n '1s/^curl \([^ ]*\).*/\1/p')"
  add_result "$GROUP_MODULE_01" "curl installed" "Pass" "Installed: ${CURL_VERSION:-version detected}" ""
else
  add_result "$GROUP_MODULE_01" "curl installed" "Failed" "curl was not found" "https://curl.se/download.html"
fi

show_progress "jq installation"
if command -v jq >/dev/null 2>&1; then
  JQ_VERSION="$(jq --version 2>/dev/null | sed 's/^jq-//')"
  add_result "$GROUP_MODULE_01" "jq installed" "Pass" "Installed: ${JQ_VERSION:-version detected}" ""
else
  add_result "$GROUP_MODULE_01" "jq installed" "Failed" "jq was not found" "https://jqlang.github.io/jq/download/"
fi

# Module 02
show_progress "Azure Developer CLI installation"
if command -v azd >/dev/null 2>&1; then
  AZD_VERSION="$(azd version 2>/dev/null | sed -n 's/^azd version \([^ ]*\).*/\1/p')"
  add_result "$GROUP_MODULE_02" "Azure Developer CLI installed" "Pass" "Installed: ${AZD_VERSION:-version detected}" ""
else
  add_result "$GROUP_MODULE_02" "Azure Developer CLI installed" "Failed" "azd was not found" "https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd"
fi

show_progress "active azd login"
if command -v azd >/dev/null 2>&1 && azd auth login --check-status --no-prompt >/dev/null 2>&1; then
  add_result "$GROUP_MODULE_02" "Active azd login" "Pass" "azd authentication is active" ""
else
  add_result "$GROUP_MODULE_02" "Active azd login" "Failed" "Run azd auth login" "https://learn.microsoft.com/azure/developer/azure-developer-cli/reference#azd-auth-login"
fi

show_progress "Microsoft Foundry azd extension"
if command -v azd >/dev/null 2>&1 && azd ext list --installed --output json 2>/dev/null | grep -Eq '"(id|namespace)"[[:space:]]*:[[:space:]]*"microsoft\.foundry"'; then
  add_result "$GROUP_MODULE_02" "Microsoft Foundry azd extension" "Pass" "microsoft.foundry is installed" ""
else
  add_result "$GROUP_MODULE_02" "Microsoft Foundry azd extension" "Failed" "Run azd ext install microsoft.foundry" "https://learn.microsoft.com/azure/developer/azure-developer-cli/extension-framework"
fi

show_progress "Foundry User role"
if [[ -n "$IDENTITY_OBJECT_ID" ]] && has_role "Foundry User"; then
  add_result "$GROUP_MODULE_02" "Foundry User role" "Pass" "Role assignment found for the current subscription" ""
else
  add_result "$GROUP_MODULE_02" "Foundry User role" "Failed" "Role assignment not found for the current subscription" "https://learn.microsoft.com/azure/ai-foundry/concepts/rbac-azure-ai-foundry"
fi

# Module 03
show_progress "kubectl installation"
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VERSION="$(kubectl version --client --output=yaml 2>/dev/null | sed -n 's/^[[:space:]]*gitVersion:[[:space:]]*//p' | head -n 1)"
  add_result "$GROUP_MODULE_03" "kubectl installed" "Pass" "Installed: ${KUBECTL_VERSION:-version detected}" ""
else
  add_result "$GROUP_MODULE_03" "kubectl installed" "Failed" "kubectl was not found" "https://kubernetes.io/docs/tasks/tools/#kubectl"
fi

show_progress "Docker installation"
DOCKER_VERSION=""
if command -v docker >/dev/null 2>&1; then
  DOCKER_VERSION="$(docker --version 2>/dev/null | sed -n 's/^Docker version \([^,]*\).*/\1/p')"
fi

if [[ -n "$DOCKER_VERSION" ]]; then
  if docker info >/dev/null 2>&1; then
    add_result "$GROUP_MODULE_03" "Docker installed and running" "Pass" "Docker version: $DOCKER_VERSION; daemon is running" ""
  else
    add_result "$GROUP_MODULE_03" "Docker installed and running" "Failed" "Docker version: $DOCKER_VERSION; daemon is not running or not reachable" "https://docs.docker.com/config/daemon/start/"
  fi
else
  add_result "$GROUP_MODULE_03" "Docker installed and running" "Failed" "Docker version: not detected; CLI is not installed or not available" "https://docs.docker.com/engine/install/"
fi

show_progress "ACR image push permission"
ACR_ID=""
ACR_PERMISSION_BLOCKS=""
if $AZ_LOGGED_IN; then
  ACR_ID="$(az acr list --resource-group "$RESOURCE_GROUP" --query '[0].id' --output tsv 2>/dev/null | tr -d '\r')"
  if [[ -n "$ACR_ID" ]]; then
    ACR_PERMISSION_BLOCKS="$(az rest \
      --method get \
      --url "https://management.azure.com${ACR_ID}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" \
      --query "value[].[join('|', actions), join('|', notActions)]" \
      --output tsv 2>/dev/null | tr -d '\r')"
  fi
fi

if [[ -z "$ACR_ID" ]]; then
  add_result "$GROUP_MODULE_03" "ACR image push permission" "Failed" "No container registry was found in $RESOURCE_GROUP; deploy Module 01 first" "https://learn.microsoft.com/azure/container-registry/container-registry-roles"
elif [[ -z "$ACR_PERMISSION_BLOCKS" ]]; then
  add_result "$GROUP_MODULE_03" "ACR image push permission" "Failed" "Could not read effective permissions for the workshop registry" "https://learn.microsoft.com/azure/container-registry/container-registry-roles"
elif has_effective_permission "Microsoft.ContainerRegistry/registries/push/write" "$ACR_PERMISSION_BLOCKS"; then
  add_result "$GROUP_MODULE_03" "ACR image push permission" "Pass" "Microsoft.ContainerRegistry/registries/push/write is allowed" ""
else
  add_result "$GROUP_MODULE_03" "ACR image push permission" "Failed" "Microsoft.ContainerRegistry/registries/push/write is not allowed" "https://learn.microsoft.com/azure/container-registry/container-registry-roles"
fi

show_progress "Azure CLI support for AKS Pod Sandboxing"
if $AZ_INSTALLED && [[ -n "$AZ_VERSION" ]] && version_at_least "$AZ_VERSION" "$MIN_AZ_VERSION"; then
  add_result "$GROUP_MODULE_03" "Azure CLI for AKS Pod Sandboxing" "Pass" "Installed: $AZ_VERSION" ""
else
  add_result "$GROUP_MODULE_03" "Azure CLI for AKS Pod Sandboxing" "Failed" "Requires Azure CLI $MIN_AZ_VERSION or newer" "https://learn.microsoft.com/cli/azure/update-azure-cli"
fi

# Module 04
show_progress "Container Apps preview extension"
CONTAINERAPP_INFO=""
if $AZ_INSTALLED; then
  CONTAINERAPP_INFO="$(az extension show --name containerapp --query '[version, preview]' --output tsv 2>/dev/null | tr -d '\r')"
fi

if [[ -n "$CONTAINERAPP_INFO" ]]; then
  read -r CONTAINERAPP_VERSION CONTAINERAPP_PREVIEW <<< "$CONTAINERAPP_INFO"
  if [[ "${CONTAINERAPP_PREVIEW,,}" == "true" || "$CONTAINERAPP_VERSION" =~ (a|b|rc)[0-9]+$ ]]; then
    add_result "$GROUP_MODULE_04" "Container Apps preview extension" "Pass" "containerapp $CONTAINERAPP_VERSION (preview enabled)" ""
  else
    add_result "$GROUP_MODULE_04" "Container Apps preview extension" "Failed" "containerapp $CONTAINERAPP_VERSION is not marked as preview" "https://learn.microsoft.com/azure/container-apps/sandboxes"
  fi
else
  add_result "$GROUP_MODULE_04" "Container Apps preview extension" "Failed" "Run az extension add --name containerapp --upgrade --allow-preview true -y" "https://learn.microsoft.com/azure/container-apps/sandboxes"
fi

show_progress "Container Apps SandboxGroup Data Owner role"
if [[ -n "$IDENTITY_OBJECT_ID" ]] && has_role "Container Apps SandboxGroup Data Owner"; then
  add_result "$GROUP_MODULE_04" "SandboxGroup Data Owner role" "Pass" "Role assignment found for the current subscription" ""
else
  add_result "$GROUP_MODULE_04" "SandboxGroup Data Owner role" "Failed" "Role assignment not found for the current subscription" "https://learn.microsoft.com/azure/container-apps/sandboxes"
fi

print_group() {
  local group="$1"
  local index result_color has_failures=false

  printf '\n%b%s%b\n' "$BOLD" "$group" "$RESET"
  printf '%-40s | %-10s | %s\n' "Prerequisite" "Result" "Details"
  printf '%-40s-+-%-10s-+-%s\n' "----------------------------------------" "----------" "----------------------------------------"

  for index in "${!ITEMS[@]}"; do
    [[ "${RESULT_GROUPS[$index]}" == "$group" ]] || continue
    if [[ "${RESULTS[$index]}" == "Pass" ]]; then
      result_color="$GREEN"
    else
      result_color="$RED"
    fi
    printf '%-40s | %b%-10s%b | %s\n' "${ITEMS[$index]}" "$result_color" "${RESULTS[$index]}" "$RESET" "${DETAILS[$index]}"
  done

  for index in "${!ITEMS[@]}"; do
    if [[ "${RESULT_GROUPS[$index]}" == "$group" && "${RESULTS[$index]}" == "Failed" ]]; then
      has_failures=true
      break
    fi
  done

  if $has_failures; then
    printf '\nFix suggestion:\n'
    for index in "${!ITEMS[@]}"; do
      [[ "${RESULT_GROUPS[$index]}" == "$group" && "${RESULTS[$index]}" == "Failed" ]] || continue
      if [[ "${ITEMS[$index]}" == "Workshop deployment permissions" && ${#MISSING_DEPLOYMENT_ACTIONS[@]} -gt 0 ]]; then
        for missing_action in "${MISSING_DEPLOYMENT_ACTIONS[@]}"; do
          printf -- '- Missing ARM action: %s\n' "$missing_action"
        done
        printf -- '- Permission guidance: %s\n' "${LINKS[$index]}"
      else
        printf -- '- %s: %s\n' "${ITEMS[$index]}" "${LINKS[$index]}"
      fi
    done
  fi
}

print_group "$GROUP_COMMON"
print_group "$GROUP_MODULE_01"
print_group "$GROUP_MODULE_02"
print_group "$GROUP_MODULE_03"
print_group "$GROUP_MODULE_04"

FAILED_COUNT=0
for result in "${RESULTS[@]}"; do
  [[ "$result" == "Failed" ]] && ((FAILED_COUNT += 1))
done

printf '\nSummary: %b%d passed%b, %b%d failed%b\n' \
  "$GREEN" "$((${#RESULTS[@]} - FAILED_COUNT))" "$RESET" \
  "$RED" "$FAILED_COUNT" "$RESET"

if ((FAILED_COUNT > 0)); then
  exit 1
fi