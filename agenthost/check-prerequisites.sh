#!/usr/bin/env bash
# Check the local tools, sign-in state, and Azure RBAC required by the workshop.

set -u

MIN_AZ_VERSION="2.80.0"
TOTAL_CHECKS=12
CURRENT_CHECK=0

GROUP_COMMON="Module 01 and common prerequisites for all modules"
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

AZ_INSTALLED=false
AZ_LOGGED_IN=false
AZ_VERSION=""
SUBSCRIPTION_ID=""
SUBSCRIPTION_NAME=""
IDENTITY_OBJECT_ID=""
ROLE_NAMES=""

printf '%bAgent Hosting on Azure Workshop - Prerequisite Check%b\n------\n' "$BOLD" "$RESET"

# All modules
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

show_progress "subscription Contributor access"
if $AZ_LOGGED_IN; then
  if [[ "$ACCOUNT_TYPE" == "user" ]]; then
    IDENTITY_OBJECT_ID="$(az ad signed-in-user show --query id --output tsv 2>/dev/null | tr -d '\r')"
  elif [[ -n "$ACCOUNT_NAME" ]]; then
    IDENTITY_OBJECT_ID="$(az ad sp show --id "$ACCOUNT_NAME" --query id --output tsv 2>/dev/null | tr -d '\r')"
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

if [[ -z "$IDENTITY_OBJECT_ID" ]]; then
  add_result "$GROUP_COMMON" "Subscription Contributor access" "Failed" "Could not resolve the signed-in identity" "https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal-subscription-admin"
elif has_role "Contributor" || has_role "Owner"; then
  add_result "$GROUP_COMMON" "Subscription Contributor access" "Pass" "Contributor or Owner assignment found" ""
else
  add_result "$GROUP_COMMON" "Subscription Contributor access" "Failed" "No Contributor or Owner assignment found at subscription scope" "https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal-subscription-admin"
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
      printf -- '- %s: %s\n' "${ITEMS[$index]}" "${LINKS[$index]}"
    done
  fi
}

print_group "$GROUP_COMMON"
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