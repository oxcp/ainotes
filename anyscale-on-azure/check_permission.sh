#!/usr/bin/env bash
# Diagnoses whether the current account can provision the Anyscale on Azure
# control-plane service principal (multi-tenant app) in the current tenant.
#Exit 0 = ready to provision (or already done). Exit 1 = follow the ACTION lines.

set -uo pipefail
APP_ID="086bc555-6989-4362-ba30-fded273e432b"
REQUIRED_ROLES=("Application Administrator" "Cloud Application Administrator" "Global Administrator")
FAIL=0
say() { printf '%s
' "$"; }
pass() { printf ' [PASS] %s
' "$"; }
fail() { printf ' [FAIL] %s
' "$"; FAIL=1; }
info() { printf ' [INFO] %s
' "$"; }
say "== 1. Signed-in identity =="
info "user: $(az account show --query user.name -o tsv)"
info "tenant: $(az account show --query tenantId -o tsv)"
say; say "== 2. Entra directory roles (gates foreign-app SP creation) =="
ROLES=$(az rest --method GET \
--url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName' \
--query "value[].displayName" -o tsv)
[ -n "$ROLES" ] && info "roles held: $(echo "$ROLES" | tr '
' ', ' | sed 's/, $//')" || info "roles held: (none)"
HAS_ADMIN_ROLE=0
for r in "${REQUIRED_ROLES[@]}"; do
if grep -qxF "$r" <<< "$ROLES"; then pass "holds '$r'"; HAS_ADMIN_ROLE=1; fi
done
if [ "$HAS_ADMIN_ROLE" -eq 0 ]; then
fail "missing required directory role (need one of: ${REQUIRED_ROLES[]})"
say " ACTION: ask an Entra admin to grant 'Application Administrator' (least privilege)"
say " — or have them run this once: az ad sp create --id $APP_ID"
say " NOTE: PIM-eligible roles don't count until activated."
fi
say; say "== 3. Tenant app-registration policy =="
POLICY_JSON=$(az rest --method GET \
--url 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' -o json 2>/dev/null || echo '{}')
CAN_CREATE=$(echo "$POLICY_JSON" | python3 -c "
import sys, json
p = json.load(sys.stdin)
perms = p.get('defaultUserRolePermissions') or ((p.get('value') or [{}])[0].get('defaultUserRolePermissions')) or {}
v = perms.get('allowedToCreateApps')
print('true' if v is True else 'false' if v is False else 'UNKNOWN')")
case "$CAN_CREATE" in
true) pass "non-admin users may register apps (allowedToCreateApps=true)" ;;
false) info "non-admin users may NOT register apps (allowedToCreateApps=false)"
info "ACTION: the directory role in step 2 is mandatory here, not optional" ;;
) fail "could not read authorizationPolicy (got: $CAN_CREATE)"
say " ACTION: confirm Graph access, then escalate to an Entra admin" ;;
esac
say; say "== 4. Anyscale control-plane SP in this tenant =="
SP_NAME=$(az ad sp show --id "$APP_ID" --query displayName -o tsv 2>/dev/null || true)
if [ -n "$SP_NAME" ]; then
pass "SP already provisioned: $SP_NAME ($APP_ID)"
info "ACTION: none — skip 'az ad sp create --id'; proceed to role assignments / federated credential"
else
info "SP not found — provisioning is required"
if [ "$HAS_ADMIN_ROLE" -eq 0 ]; then
fail "provisioning WILL fail with your current permissions (see step 2)"
else
pass "you hold a qualifying directory role — safe to run:"
say " az ad sp create --id $APP_ID"
fi
fi
say; say "== 5. Graph delegated scopes on current CLI token =="
TOKEN=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)
SCOPES=$(echo "$TOKEN" | cut -d. -f2 | python3 -c "
import sys, base64, json
p = sys.stdin.read().strip()
print(json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)).decode()).get('scp',''))")
info "$SCOPES"
if grep -qw "Application.ReadWrite.All" <<< "$SCOPES"; then
pass "Application.ReadWrite.All present in token"
else
info "Application.ReadWrite.All not in token scopes"
info "NOTE: not a blocker — with a qualifying directory role, Graph derives effective"
info " permission from the role. Only a missing role blocks foreign-app SP creation."
fi
say; say "== Verdict =="
if [ "$FAIL" -eq 0 ]; then
say "Ready: all checks passed."
else
say "Blocked: follow the ACTION lines above. The standard customer fix is:"
say " 1) grant 'Application Administrator' (least privilege), or"
say " 2) have an Entra admin run: az ad sp create --id $APP_ID"
fi
exit "$FAIL"