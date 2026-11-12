#!/usr/bin/env bash
# Baselines authorize only new, narrowly allowlisted children, never parent resources.
case "${OSTYPE:-}" in
  msys*|cygwin*) export MSYS2_ARG_CONV_EXCL="/subscriptions/;/SUBSCRIPTIONS/;${MSYS2_ARG_CONV_EXCL:-}" ;;
esac
jq() {
  case "${OSTYPE:-}" in
    msys*|cygwin*) command jq --binary "$@" ;;
    *) command jq "$@" ;;
  esac | tr -d '\r'
}
ownership_validate_target() {
  local target="$1"
  jq -e '
    . as $t |
    (.id|test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/")) and
    (.before==null) and
    (if .kind=="embedding" then
      .api=="2026-03-01" and
      (.id|test("/providers/Microsoft.CognitiveServices/accounts/[^/]+/deployments/[^/]+$")) and
      (.model=="text-embedding-3-small" or .model=="text-embedding-3-large")
    elif .kind=="operation" then
      .api=="2023-05-01-preview" and
      (.id|test("/providers/Microsoft.ApiManagement/service/[^/]+/apis/workshop-ai-gateway/operations/embeddings$"))
    elif .kind=="backend" then
      .api=="2023-05-01-preview" and
      (.id|test("/providers/Microsoft.ApiManagement/service/[^/]+/backends/module06-embeddings-backend$"))
    else false end) and
    (if .after==null then true else
      .after.id==.id and
      (if .kind=="embedding" then .after.properties.model.name==.model
       elif .kind=="operation" then
         .after.properties.method=="POST" and .after.properties.urlTemplate=="/openai/v1/embeddings"
       else .after.properties.description=="Module-06 account-level OpenAI v1 embeddings" end)
    end)
  ' <<<"$target" >/dev/null || fail "Invalid or unsafe ownership target"
}
ownership_read() {
  local id="$1" api="$2" result object policy
  # A successful collection GET distinguishes absence from permission/network failures.
  # Refuse pagination rather than treating an incomplete page as proof of absence.
  result="$(timeout "${operation_timeout:-300}" az rest --method get \
    --url "https://management.azure.com${id%/*}?api-version=$api" -o json)" || return 1
  object="$(jq -c --arg id "$id" '
    if (.value|type)=="array" and (.nextLink // "")=="" and all(.value[]; .id|type=="string") then
      [.value[]|select((.id|ascii_downcase)==($id|ascii_downcase))] |
      if length<=1 then .[0] // null else error("Duplicate resource") end
    else error("Invalid or paginated ARM collection") end' <<<"$result")" || return 1
  if [[ "$object" != null && "$id" == */apis/workshop-ai-gateway/operations/embeddings ]]; then
    policy="$(ownership_read "$id/policies/policy" "$api")" || return 1
    object="$(jq -c --argjson policy "$policy" '.+{cleanupPolicy:($policy|del(.etag))}' <<<"$object")" || return 1
  fi
  printf '%s\n' "$object"
}
ownership_begin_models() {
  local model_id="$1" operation_id="$2" backend_id="$3" model="$4" target live
  model_target_ids="$(jq -cn --arg m "$model_id" --arg o "$operation_id" --arg b "$backend_id" '[$m,$o,$b]')"
  ledger="$root/.local/cleanup-ownership.json"
  [[ ! -L "$root/.local" && ! -L "$ledger" ]] || fail "Ownership baseline cannot be a symbolic link"
  mkdir -p "$root/.local"
  ownership='{"version":1,"resources":[]}'
  if [[ -e "$ledger" ]]; then
    ownership="$(jq -ce 'select(.version==1 and (.resources|type=="array"))' "$ledger")" || fail "Invalid ownership baseline"
  fi
  while IFS= read -r target; do
    ownership_validate_target "$target"
    live="$(ownership_read "$(jq -r .id <<<"$target")" "$(jq -r .api <<<"$target")")" || fail "Cannot establish pre-Module06 child state"
    previous="$(jq -c --arg id "$(jq -r .id <<<"$target")" '.resources[]|select(.id==$id)' <<<"$ownership")"
    if [[ -n "$previous" ]]; then
      ownership_validate_target "$previous"
      jq -e --argjson live "$live" '.after==($live|if .==null then null else del(.etag,.properties.provisioningState) end)' \
        <<<"$previous" >/dev/null || fail "Tracked child changed since deployment; review it before modifying"
    else
      [[ "$live" == null ]] || fail "Target predates Module-06 baseline; refusing to overwrite: $(jq -r .id <<<"$target")"
      ownership="$(jq -c --argjson t "$target" '.resources+=[$t]' <<<"$ownership")"
    fi
  done < <(jq -cn --arg model_id "$model_id" --arg operation_id "$operation_id" --arg backend_id "$backend_id" --arg model "$model" '
    {id:$model_id,api:"2026-03-01",kind:"embedding",model:$model,before:null,after:null},
    {id:$operation_id,api:"2023-05-01-preview",kind:"operation",before:null,after:null},
    {id:$backend_id,api:"2023-05-01-preview",kind:"backend",before:null,after:null}')
  ownership_save
}
ownership_save() {
  [[ ! -L "$ledger.next" && ! -e "$ledger.next" ]] || fail "Ownership staging file already exists"
  printf '%s\n' "$ownership" >"$ledger.next"
  mv -- "$ledger.next" "$ledger"
}
ownership_finish_models() {
  local target live id
  while IFS= read -r target; do
    id="$(jq -r .id <<<"$target")"
    live="$(ownership_read "$id" "$(jq -r .api <<<"$target")")" || fail "Cannot capture deployed child; baseline retained for review"
    if [[ "$live" != null ]]; then
      # Saving a state is not itself proof of ownership: validate the expected
      # embedding model/operation/backend before authorizing later deletion.
      target="$(jq -c --argjson live "$live" '.after=($live|del(.etag,.properties.provisioningState))' <<<"$target")"
      ownership_validate_target "$target"
    fi
    ownership="$(jq -c --arg id "$id" --argjson live "$live" '
      (.resources[]|select(.id==$id)).after=($live|if .==null then null else del(.etag,.properties.provisioningState) end)' <<<"$ownership")"
    ownership_save
  done < <(jq -c --argjson ids "$model_target_ids" '.resources[]|select(.id as $id|$ids|index($id)!=null)' <<<"$ownership")
}
