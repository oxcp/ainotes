#!/usr/bin/env bash
# Offline regression checks; Azure calls are replaced with a shell function.
set -Eeuo pipefail
source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -f -- "$tmp/deploy-storage.sh" "$tmp/deploy-database.sh" "$tmp/inventory.json" "$tmp/header.sh" "$tmp/aca-tag.sh" "$tmp/database.sh" "$tmp/polls" "$tmp/result.json" "$tmp/diagnostics" "$tmp/calls" "$tmp/output" "$tmp/log" "$tmp/tty" "$tmp/.local/storage-deployment.json"; if [[ -d "$tmp/.local" ]]; then rmdir -- "$tmp/.local"; fi; rmdir -- "$tmp"' EXIT
trap 'printf "FAIL deployment output test at line %s\n" "$LINENO" >&2' ERR
cp "$source_root/deploy-storage.sh" "$tmp/"
export TEST_CALLS="$tmp/calls"
export SUBSCRIPTION_ID=sub-test STORAGE_RESOURCE_GROUP=rg-test STORAGE_ACCOUNT_NAME=sttest
export ACA_COMMON="$tmp/missing-common.json" ACA_CONFIG="$tmp/missing-config.json"
unset KB_STORAGE_CONTAINER_ID
az() {
  printf '%s\n' "$*" >>"$TEST_CALLS"
  case "$1 $2" in
    'resource show')
      printf '%s\n' '{"id":"/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttest","properties":{"primaryEndpoints":{"blob":"https://sttest.blob.core.windows.net/"}}}'
      ;;
    'deployment group') ;;
    *) printf 'Unexpected Azure call: %s\n' "$*" >&2; return 1 ;;
  esac
}
export -f az
container="/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttest/blobServices/default/containers/data"
for mode in --discover --resolve provision; do
  : >"$TEST_CALLS"
  args=()
  [[ "$mode" == provision ]] || args+=("$mode")
  bash "$tmp/deploy-storage.sh" "${args[@]}" >"$tmp/output" 2>"$tmp/log"
  if [[ "$mode" == provision ]]; then
    grep -q '^  ==> \[1/3\]' "$tmp/log"
    grep -q '^  ==> \[2/3\]' "$tmp/log"
    grep -q '^  ==> \[3/3\]' "$tmp/log"
    [[ "$(grep -c '^deployment group create ' "$TEST_CALLS")" == 1 ]]
    jq -e --arg id "$container" '.status=="provisioned" and .KB_STORAGE_CONTAINER_ID==$id' "$tmp/output" >/dev/null
  else
    grep -q '^  ==> \[1/2\]' "$tmp/log"
    grep -q '^  ==> \[2/2\]' "$tmp/log"
    [[ "$(wc -l <"$tmp/log")" == 2 ]]
    ! grep -q '^deployment ' "$TEST_CALLS"
    [[ ! -e "$tmp/.local/storage-deployment.json" ]]
    if [[ "$mode" == --resolve ]]; then
      [[ "$(cat "$tmp/output")" == "$container" ]]
    else
      jq -e --arg id "$container" '.KB_STORAGE_CONTAINER_ID==$id and .AZURE_STORAGE_CONTAINER=="data"' "$tmp/output" >/dev/null
    fi
  fi
done

# Compare all published image tags with the ACA importer's actual option parsing.
(
  az() {
    [[ "$1 $2" == 'acr build' ]] || return 51
    shift 2
    while (($#)); do
      if [[ "$1" == --image ]]; then
        printf '%s\n' "$2" >>"$TEST_CALLS"
        shift 2
      else
        shift
      fi
    done
  }
  export -f az
  printf 'set -euo pipefail\n' >"$tmp/aca-tag.sh"
  sed -n '/^# -- Configuration /,/^# Only normalize deployment metadata/p' \
    "$source_root/deploy-aca.sh" >>"$tmp/aca-tag.sh"
  printf '\nprintf "%%s\\n" "$tag"\n' >>"$tmp/aca-tag.sh"
  for expected_tag in latest environment-tag cli-tag; do
    image_env=(-u IMAGE_TAG)
    image_args=()
    if [[ "$expected_tag" != latest ]]; then
      image_env=(IMAGE_TAG=environment-tag)
    fi
    [[ "$expected_tag" != cli-tag ]] || image_args=(--tag cli-tag)
    : >"$TEST_CALLS"
    env "${image_env[@]}" ACR_NAME=acrtest \
      bash "$source_root/build-images.sh" "${image_args[@]}" >"$tmp/output" 2>"$tmp/log"
    imported_tag="$(env "${image_env[@]}" bash "$tmp/aca-tag.sh" "${image_args[@]}")"
    [[ "$imported_tag" == "$expected_tag" && "$(wc -l <"$TEST_CALLS")" == 5 ]]
    for role in chat orchestrator data-processing rag sql; do
      grep -Fxq "studio-$role:$imported_tag" "$TEST_CALLS"
    done
  done
)

# Exercise the real heading formatter without running deployment preflight.
sed -n '/^stage_header() {$/,/^}$/p' "$source_root/deploy.sh" >"$tmp/header.sh"
printf '\nstage_header 1 "Storage"\n' >>"$tmp/header.sh"
expected=$'\n==> [Stage 1/6] Storage'
[[ "$(TERM=xterm bash "$tmp/header.sh")" == "$expected" ]]
script -q -e -c "env -u NO_COLOR TERM=xterm bash '$tmp/header.sh'" /dev/null >"$tmp/tty"
grep -Fq $'\033[1;36m==> [Stage 1/6] Storage\033[0m' "$tmp/tty"
script -q -e -c "env NO_COLOR=1 TERM=xterm bash '$tmp/header.sh'" /dev/null >"$tmp/tty"
! grep -q $'\033' "$tmp/tty"
script -q -e -c "env -u NO_COLOR TERM=dumb bash '$tmp/header.sh'" /dev/null >"$tmp/tty"
! grep -q $'\033' "$tmp/tty"

sed -n '/^provision_database() {$/,/^}$/p' "$source_root/deploy-database.sh" >"$tmp/database.sh"
cat >>"$tmp/database.sh" <<'STUB'
set -euo pipefail
tmp="$1"
subscription=sub-test resource_group=rg-test cluster=db-test template=unused.bicep
sleep() {
  [[ "$1" == 15 ]]
  SECONDS=$((SECONDS + 15))
}
az() {
  printf '%s\n' "$*" >>"$tmp/calls"
  case "$*" in
    'deployment group create '*)
      [[ "$TEST_MODE" != submit-error ]] || { echo 'secret diagnostics' >&2; return 42; }
      ;;
    *'--query properties.provisioningState '*)
      [[ "$TEST_MODE" != read-error ]] || { echo 'secret diagnostics' >&2; return 43; }
      count="$(cat "$tmp/polls")"
      printf '%s\n' "$((count + 1))" >"$tmp/polls"
      case "$TEST_MODE:$count" in
        success:0) echo Accepted ;;
        success:1) echo Running ;;
        success:*) echo Succeeded ;;
        failed:*) echo Failed ;;
        canceled:*) echo Canceled ;;
        empty:*) ;;
        unknown:*) echo Unexpected ;;
        output-error:*) echo Succeeded ;;
        *) return 44 ;;
      esac
      ;;
    *'--query properties.outputs '*)
      [[ "$TEST_MODE" != output-error ]] || { echo 'secret diagnostics' >&2; return 45; }
      echo '{"endpoint":{"value":"db.example.test"}}'
      ;;
    *) return 46 ;;
  esac
}
provision_database
STUB
for mode in success failed canceled empty unknown submit-error read-error output-error; do
  : >"$tmp/calls"
  printf '0\n' >"$tmp/polls"
  if TEST_MODE="$mode" bash "$tmp/database.sh" "$tmp" >"$tmp/output" 2>"$tmp/log"; then
    [[ "$mode" == success ]]
    grep -Fq 'ARM deployment: Accepted (elapsed 0m 00s)' "$tmp/log"
    grep -Fq 'ARM deployment: Running (elapsed 0m 15s)' "$tmp/log"
    grep -Fq 'ARM deployment: Succeeded (elapsed 0m 30s)' "$tmp/log"
    jq -e '.endpoint.value=="db.example.test"' "$tmp/result.json" >/dev/null
  else
    [[ "$mode" != success ]]
    if [[ "$mode" != output-error ]]; then
      ! grep -q 'properties.outputs' "$tmp/calls"
    fi
  fi
  grep -q -- '--no-wait --output none' "$tmp/calls"
  [[ ! -s "$tmp/output" ]]
  ! grep -q 'secret diagnostics' "$tmp/log"
done

# Run the complete database script, including jq parameter generation and cleanup.
export TEST_DATABASE_SCRIPT="$tmp/deploy-database.sh"
az() {
  local parameters="" previous="" argument
  for argument in "$@"; do
    [[ "$previous" != --parameters ]] || parameters="${argument#@}"
    previous="$argument"
  done
  case "$1 $2" in
    'group show') echo '{"location":"westus3"}' ;;
    'resource list')
      if [[ "$TEST_DATABASE_REUSE" == true ]]; then
        printf '[{"id":"%s"}]\n' "$TEST_CLUSTER_ID"
      else
        echo '[]'
      fi
      ;;
    'resource show')
      jq -n --arg id "$TEST_CLUSTER_ID" \
        '{id:$id,location:"westus3",properties:{provisioningState:"Succeeded",version:"17",
          administratorLogin:"studioadmin",vCores:2,replicaCount:1,zonePlacementPolicy:"BestEffort",
          parameterGroup:{id:($id|sub("/clusters/";"/parameterGroups/"))+"-vector",
            syncStatus:"InSync",isUsingLatestConfig:true},
          authConfig:{passwordAuth:"Enabled",entraIdAuth:"Disabled"}}}'
      ;;
    'deployment group')
      case "$3" in
        validate|create)
          jq -e --arg provider "$TEST_DATABASE_PROVIDER" --argjson reuse "$TEST_DATABASE_REUSE" '
            .dbProvider.value==$provider and
            (if $provider=="horizondb" then .reuseHorizonCluster.value==$reuse
             else (has("reuseHorizonCluster")|not) end)
          ' "$parameters" >/dev/null || return 47
          if [[ "$3" == create && "$TEST_DATABASE_MUTATE" == true ]]; then
            # Simulate saving an edited script while its deployment command is running.
            for ((i=0; i<2000; i++)); do
              printf '%s\n' 'echo "Unexpected script reread: $reuse"'
            done >"$TEST_DATABASE_SCRIPT"
          fi
          ;;
        show)
          case "$*" in
            *'--query properties.provisioningState '*)
              if [[ "$TEST_DATABASE_FAIL" == true ]]; then echo Failed; else echo Succeeded; fi
              ;;
            *'--query properties.outputs '*)
              jq -n --arg id "$TEST_CLUSTER_ID" --arg provider "$TEST_DATABASE_PROVIDER" '
                {resourceId:{value:$id},region:{value:"westus3"},provider:{value:$provider},
                  endpoint:{value:"db.example.test"},port:{value:5432},database:{value:"postgres"},
                  username:{value:"studioadmin"},administratorUsername:{value:"studioadmin"},
                  sslMode:{value:"require"},authMode:{value:"password"}}'
              ;;
            *) return 48 ;;
          esac
          ;;
        *) return 49 ;;
      esac
      ;;
    *) printf 'Unexpected Azure call: %s\n' "$*" >&2; return 50 ;;
  esac
}
export -f az
for scenario in horizondb-new horizondb-reuse postgresql-new horizondb-edited horizondb-failed; do
  export TEST_DATABASE_PROVIDER="${scenario%%-*}" TEST_DATABASE_REUSE=false TEST_DATABASE_MUTATE=false TEST_DATABASE_FAIL=false
  [[ "$scenario" != horizondb-reuse ]] || TEST_DATABASE_REUSE=true
  [[ "$scenario" != horizondb-edited ]] || TEST_DATABASE_MUTATE=true
  [[ "$scenario" != horizondb-failed ]] || TEST_DATABASE_FAIL=true
  resource_type=Microsoft.HorizonDb/clusters
  [[ "$TEST_DATABASE_PROVIDER" != postgresql ]] || resource_type=Microsoft.DBforPostgreSQL/flexibleServers
  export TEST_CLUSTER_ID="/subscriptions/sub-test/resourceGroups/rg-test/providers/$resource_type/db-test"
  cp "$source_root/deploy-database.sh" "$TEST_DATABASE_SCRIPT"
  rm -f -- "$tmp/inventory.json"
  if AGENT_IDENTITY_RESOURCE_ID="" DB_REUSE_ENTRA_ADMIN=false DB_PASSWORD=offline-test-password \
    DB_VCORES=2 bash "$TEST_DATABASE_SCRIPT" --provider "$TEST_DATABASE_PROVIDER" \
    --subscription sub-test --resource-group rg-test --location westus3 --resource-name db-test \
    --admin-username studioadmin --output "$tmp/inventory.json" >"$tmp/output" 2>"$tmp/log"; then
    [[ "$TEST_DATABASE_FAIL" == false ]]
  elif [[ "$TEST_DATABASE_FAIL" == true ]]; then
    jq -e --arg id "$TEST_CLUSTER_ID" \
      '.status=="failed" and .failed_stage=="provisioning" and .resource_id==$id' "$tmp/inventory.json" >/dev/null
    continue
  else
    cat "$tmp/log" >&2
    exit 1
  fi
  jq -e --arg provider "$TEST_DATABASE_PROVIDER" \
    '.status=="provisioned" and .DB_PROVIDER==$provider and .DB_ENDPOINT=="db.example.test"' \
    "$tmp/inventory.json" >/dev/null
done
printf 'Deployment output tests passed (image tags, step counts, stdout contract, color, ARM states, complete database runs and in-flight edits).\n'
