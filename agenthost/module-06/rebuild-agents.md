# Rebuild and Replace the Module-06 Agent Sandboxes

Language: **English** | [中文](rebuild-agents_CN.md)

Use this procedure after changing Agent code to delete the current five Module-06
sandboxes, rebuild their images, and start a fresh set of sandboxes.

## Scope and precautions

- Replace only `chat`, `orchestrator`, `data-processing`, `rag`, and `sql`.
- Preserve the database, uploaded Blob data, runtime configuration, shared
  SandboxGroup, volume, resource group, and Module-04 sandboxes.
- **Do not run [cleanup.sh](cleanup.sh) for this update.** Full cleanup also deletes
  Module-06 database resources, uploaded data, and local configuration.
- Deleting sandboxes is destructive and interrupts the application. Snapshot first
  if guest-local files or logs must be preserved. Data already persisted to the
  database or Blob storage is not deleted by the commands below.
- ACR builds, new sandboxes, and retained disks/snapshots can incur charges.
- This procedure assumes an existing deployment and usable runtime configuration.
  For a first deployment, follow the [workshop guide](readme.md).

Run all commands in the **same Linux / WSL Bash session**, with the working
directory set to this module's root, which contains [deploy.sh](deploy.sh).
Required tools are Bash, Azure CLI, `aca`, `jq`, `curl`, `openssl`, and GNU `timeout`.

## Recommended: one-command rebuild

Run the [rebuild script](rebuild-agents.sh):

```bash
bash rebuild-agents.sh
```

The script loads the old inventory and existing configuration, checks live
deployment/role labels and source disk IDs, and prints the targets. Enter
**`rebuild module-06`** to authorize the build and replacement.
It then builds all five images **before deleting any old sandbox**, rechecks
ownership, deletes only the recorded sandboxes, verifies removal, and invokes
`deploy.sh --stage aca`. Build failure leaves the old sandboxes running.
Completion requires the new inventory to confirm five ready Agents using the new tag.

To preserve guest-local state, enable snapshots. All requested snapshots must
succeed before any sandbox is deleted:

```bash
bash rebuild-agents.sh --snapshot
```

For unattended use, explicitly select the current inventory and configuration.
**`--yes` skips destructive-operation confirmation**; review the target files first:

```bash
bash rebuild-agents.sh \
  --inventory .local/aca-deployment.json \
  --config .local/aca-config.json \
  --snapshot \
  --yes
```

- `--inventory` defaults to `OLD_ACA_OUTPUT`, otherwise the module's
  `.local/aca-deployment.json`. After a successful rebuild, use the new inventory
  printed by the script for the next replacement; it does not automatically pick
  the newest file.
- `--config` defaults to `ACA_CONFIG`, otherwise `.local/aca-config.json`.
  Restore custom registry, common configuration, identity, and networking
  environment variables before running.
- By default, the script generates a unique image tag and a new
  `.local/aca-deployment-rebuild-*.json` inventory. Ambient `IMAGE_TAG` and
  `ACA_OUTPUT` are deliberately not reused. Use `--tag` or `--output` for explicit
  overrides; an existing output is rejected. Relative explicit paths use the
  caller's directory; default paths use the script's module directory.
- Missing recorded sandboxes are skipped, but a run with none remaining is
  rejected to avoid blindly creating another deployment from a stale inventory.
  Malformed inventories or ownership/source mismatches also stop the script.
- The script never invokes full cleanup or schema migration. Old inventories,
  configuration, imported disks, and snapshots are retained. Run no parallel
  deployment or cleanup while rebuilding. A failure stops subsequent stages
  without rollback; inspect inventories and cloud state before retrying.

To inspect all options or run the isolated offline tests without real Azure/ACA
operations:

```bash
bash rebuild-agents.sh --help
bash rebuild-agents.test.sh
```

The manual alternative follows below; do not repeat it after a successful script
run. Its steps delete before building. To reduce downtime, complete the image
build in step 3 before step 2, using the same environment and image tag.

## 1. Restore the deployment context

Set `OLD_ACA_OUTPUT` to the inventory of the deployment you intend to replace.
The default below is the original deployment inventory; use the actual filename
if a previous rebuild wrote a different inventory. Likewise, restore any custom
`ACA_CONFIG`, `ACR_NAME`, `ACA_COMMON`, identity, or networking settings used by
the existing deployment.

Do not delete or overwrite the old inventory or configuration.

```bash
set -euo pipefail

OLD_ACA_OUTPUT="$PWD/.local/aca-deployment.json"
ACA_CONFIG="${ACA_CONFIG:-$PWD/.local/aca-config.json}"

SUBSCRIPTION_ID="$(jq -er '.subscription' "$OLD_ACA_OUTPUT")"
RESOURCE_GROUP="$(jq -er '.resource_group' "$OLD_ACA_OUTPUT")"
SANDBOX_GROUP_NAME="$(jq -er '.sandbox_group' "$OLD_ACA_OUTPUT")"
LOCATION="$(jq -er '.region' "$OLD_ACA_OUTPUT")"
DB_PROVIDER="$(jq -er '.chat.DB_PROVIDER // "horizondb"' "$ACA_CONFIG")"

REBUILD_ID="$(date -u +%Y%m%d-%H%M%S)"
IMAGE_TAG="rebuild-$REBUILD_ID"
ACA_OUTPUT="$PWD/.local/aca-deployment-$REBUILD_ID.json"

export OLD_ACA_OUTPUT ACA_CONFIG
export SUBSCRIPTION_ID RESOURCE_GROUP SANDBOX_GROUP_NAME LOCATION
export DB_PROVIDER IMAGE_TAG ACA_OUTPUT

aca_args=(
  --subscription "$SUBSCRIPTION_ID"
  --resource-group "$RESOURCE_GROUP"
  --sandbox-group "$SANDBOX_GROUP_NAME"
  --region "$LOCATION"
)

az account show -o none 2>/dev/null || az login
aca auth status >/dev/null 2>&1 || aca auth login
aca doctor "${aca_args[@]}"
```

Confirm the subscription, resource group, SandboxGroup, and region are correct,
and resolve every failed `doctor` check before continuing.

The unique `IMAGE_TAG` is shared by the build and deployment. The new
`ACA_OUTPUT` avoids overwriting the old inventory; deployment scripts reject an
output file that already exists.

## 2. Inspect and delete only the old five sandboxes

Display the old inventory and verify every target belongs to the intended
Module-06 deployment, not Module-04 or another deployment:

```bash
jq -r '.agents | to_entries[] |
  [.key, .value.sandbox_id, .value.status] | @tsv' "$OLD_ACA_OUTPUT"
```

If guest-local state is worth preserving, snapshot each relevant sandbox before
deleting it. Replace the ID placeholder; use a different snapshot name for each
sandbox:

```bash
aca sandbox snapshot "${aca_args[@]}" \
  --id "<sandbox-id>" \
  --name "before-rebuild-chat-$REBUILD_ID"
```

After confirming the targets, delete the five explicitly named sandboxes:

```bash
for role in chat orchestrator data-processing rag sql; do
  sandbox_id="$(jq -er --arg role "$role" \
    '.agents[$role].sandbox_id' "$OLD_ACA_OUTPUT")"

  printf 'Deleting %s: %s\n' "$role" "$sandbox_id"

  aca sandbox delete "${aca_args[@]}" \
    --id "$sandbox_id" \
    --yes
done
```

If any deletion fails, stop and inspect the error. Do not ignore the failure,
delete the shared SandboxGroup, or discard the inventory to work around it.

## 3. Rebuild and publish all five Agent images

```bash
bash build-images.sh
```

[build-images.sh](build-images.sh) runs five remote ACR builds and publishes the
images using `IMAGE_TAG`. No local Docker daemon is required.

Wait for all five builds to succeed before proceeding. Reusing the runtime
configuration does not require regenerating credentials or changing the database.

## 4. Create and start five new Agent sandboxes

```bash
bash deploy.sh --stage aca
```

This stage imports the published images, creates five new sandboxes, reuses the
configuration and storage, and checks health endpoints and Agent connectivity.
It does not update the old sandboxes in place.

For the code-only changes covered here, no database schema change is required,
so **do not add `--migrate`**. If a separate update introduces schema migrations,
review and apply those explicitly instead of assuming this procedure covers them.

The deployment should finish with all five Agents marked `ready`.
Get the new Chat URL:

```bash
jq -r '.agents.chat.url' "$ACA_OUTPUT"
```

Open the **new Chat URL** and submit fresh questions to test the updated behavior.
Existing database and Blob data remain available; re-uploading is not required.
Browser-local conversation history is origin-scoped and may not appear at the
new URL; it is separate from persisted server-side data.

## Inventory, failures, and retained resources

- Keep both inventories. The old one identifies resources from the previous
  deployment; the new one records the new sandbox IDs, image references, and URLs.
- Preserve the existing protected configuration and related files in `.local`.
  Do not clear that directory as part of this procedure.
- If the build or deployment fails, inspect the reported stage and preserve its
  inventory. A failed deployment may already have created billable resources.
  Check them before retrying; another deployment needs a new `ACA_OUTPUT`.
- These commands delete only old sandboxes, **not their imported disks or
  snapshots**. Retained disks/snapshots can still incur storage charges.
  After verifying the new deployment, review the old inventory and clean up only
  resources confirmed to belong to the old deployment.
- Do not delete the shared SandboxGroup, volume, database, Blob container, or
  resource group when cleaning up old sandbox resources.

For deployment options and troubleshooting, see the
[CLI deployment reference](agent-src/docs/cli-deployment.md).
