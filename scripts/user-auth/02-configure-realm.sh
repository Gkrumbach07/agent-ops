#!/usr/bin/env bash
# Step 2: configure the realm for people. Safe to re-run. Everything is per gateway (namespace),
# so several gateways can share the realm without accepting each other's tokens.
#
#   ${API_CLIENT}           the API this gateway represents: the token audience and the home of the
#                           client roles "admin" and "user" (claim resource_access.<api>.roles).
#                           Keycloak's built-in "audience resolve" adds it to aud whenever one of its
#                           roles is in the token, so a user with no role gets no usable token.
#   groups                  ${GROUP_PREFIX}-admins -> admin;  ${GROUP_PREFIX}-ws-<ws>-users|admins -> user.
#                           Group membership is the only thing administrators manage (grant.sh, revoke.sh).
#   ${CLI_CLIENT}           public; browser (PKCE) and device-code login; no password login
#   ${DASHBOARD_CLIENT}     confidential; used by oauth2-proxy in front of the dashboard
#   ${AUTOMATION_CLIENT}    confidential service account with "admin", for CI and the member sync
#   ${SYNC_CLIENT}          confidential service account that can only read users and groups
# Every login client has Full Scope Allowed off and is scoped to this gateway's roles only.
# Secrets (namespace ${NAMESPACE}): keycloak-platform-admin, openshell-dashboard-oidc,
# openshell-automation-oidc, openshell-member-sync-oidc. Users: platform-admin in ${GROUP_PREFIX}-admins.
set -euo pipefail
. "$(dirname "$0")/env.sh"

ensure_secret "${NAMESPACE}" keycloak-platform-admin username platform-admin password "$(openssl rand -hex 12)"
ensure_secret "${NAMESPACE}" openshell-dashboard-oidc client-secret "$(openssl rand -hex 24)" cookie-secret "$(openssl rand -hex 16)"
ensure_secret "${NAMESPACE}" openshell-automation-oidc client-secret "$(openssl rand -hex 24)"
ensure_secret "${NAMESPACE}" openshell-member-sync-oidc client-secret "$(openssl rand -hex 24)"

kc_exec API="${API_CLIENT}" GP="${GROUP_PREFIX}" CLI="${CLI_CLIENT}" DASH="${DASHBOARD_CLIENT}" \
    AUTO="${AUTOMATION_CLIENT}" SYNC="${SYNC_CLIENT}" DASH_HOST="${DASHBOARD_HOST}" \
    ADMIN_PW="$(get_secret "${NAMESPACE}" keycloak-platform-admin password)" \
    DASH_SECRET="$(get_secret "${NAMESPACE}" openshell-dashboard-oidc client-secret)" \
    AUTO_SECRET="$(get_secret "${NAMESPACE}" openshell-automation-oidc client-secret)" \
    SYNC_SECRET="$(get_secret "${NAMESPACE}" openshell-member-sync-oidc client-secret)" <<'IN'
gid() {  # no awk in the Keycloak image
    while IFS=, read -r i n; do [ "$n" = "$1" ] && { echo "$i"; return; }; done \
        < <($KC get groups -r "$R" "${CFG[@]}" -q search="$1" -q exact=true --fields id,name --format csv --noquotes)
}

ensure_client() {  # clientId, then -s settings (created or updated)
    local id=$1; shift
    if [ -z "$(cid "$id")" ]; then $KC create clients -r "$R" "${CFG[@]}" -s clientId="$id" "$@" >/dev/null
    else $KC update "clients/$(cid "$id")" -r "$R" "${CFG[@]}" "$@" >/dev/null; fi
}

# The API client and its two roles.
ensure_client "$API" -s publicClient=false -s bearerOnly=false -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false -s implicitFlowEnabled=false \
    -s 'attributes."oauth2.device.authorization.grant.enabled"=false'
API_ID=$(cid "$API")
for role in admin user; do
    $KC get "clients/$API_ID/roles/$role" -r "$R" "${CFG[@]}" >/dev/null 2>&1 || \
        $KC create "clients/$API_ID/roles" -r "$R" "${CFG[@]}" -s name="$role" >/dev/null
done
API_ROLES=$($KC get "clients/$API_ID/roles" -r "$R" "${CFG[@]}")
scope_to_api() {  # login client may carry this gateway's roles, nothing else
    $KC create "clients/$(cid "$1")/scope-mappings/clients/$API_ID" -r "$R" "${CFG[@]}" -b "$API_ROLES" >/dev/null
}

ensure_client "$CLI" -s publicClient=true -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
    -s implicitFlowEnabled=false -s fullScopeAllowed=false \
    -s 'redirectUris=["http://localhost/*","http://127.0.0.1/*"]' \
    -s 'attributes."pkce.code.challenge.method"=S256' -s 'attributes."oauth2.device.authorization.grant.enabled"=true'
scope_to_api "$CLI"
ensure_client "$DASH" -s publicClient=false -s secret="$DASH_SECRET" -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false -s implicitFlowEnabled=false -s fullScopeAllowed=false \
    -s "redirectUris=[\"https://${DASH_HOST}/oauth2/callback\"]" -s "webOrigins=[\"https://${DASH_HOST}\"]" \
    -s 'attributes."pkce.code.challenge.method"=S256' -s "attributes.\"post.logout.redirect.uris\"=https://${DASH_HOST}/"
scope_to_api "$DASH"
ensure_client "$AUTO" -s publicClient=false -s secret="$AUTO_SECRET" -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false -s directAccessGrantsEnabled=false -s fullScopeAllowed=false
scope_to_api "$AUTO"
$KC add-roles -r "$R" "${CFG[@]}" --uusername "service-account-$AUTO" --cclientid "$API" --rolename admin
ensure_client "$SYNC" -s publicClient=false -s secret="$SYNC_SECRET" -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false -s directAccessGrantsEnabled=false
$KC add-roles -r "$R" "${CFG[@]}" --uusername "service-account-$SYNC" --cclientid realm-management \
    --rolename view-users --rolename query-users --rolename query-groups

# Groups: admins of this gateway, and the default workspace's users.
ensure_group() {  # name role
    [ -n "$(gid "$1")" ] || $KC create groups -r "$R" "${CFG[@]}" -s name="$1" >/dev/null
    $KC add-roles -r "$R" "${CFG[@]}" --gid "$(gid "$1")" --cclientid "$API" --rolename "$2"
}
ensure_group "$GP-admins" admin
ensure_group "$GP-ws-default-users" user

uid() { $KC get users -r "$R" "${CFG[@]}" -q username="$1" -q exact=true --fields id --format csv --noquotes | head -1; }
[ -n "$(uid platform-admin)" ] || $KC create users -r "$R" "${CFG[@]}" -s username=platform-admin -s enabled=true \
    -s emailVerified=true -s email=platform-admin@example.com -s firstName=Platform -s lastName=Admin >/dev/null
# The Secret is where the password is kept, so every run sets the user's password to it
# (verify.sh signs in with the Secret). To change the password, change the Secret and re-run.
$KC set-password -r "$R" "${CFG[@]}" --username platform-admin --new-password "$ADMIN_PW"
$KC update "users/$(uid platform-admin)/groups/$(gid "$GP-admins")" -r "$R" "${CFG[@]}" -n >/dev/null
echo "realm configured"
IN
log "gateway ${NAMESPACE}: audience ${API_CLIENT}, admins in group ${GROUP_PREFIX}-admins (platform-admin)"
