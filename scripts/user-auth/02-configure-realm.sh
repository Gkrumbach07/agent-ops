#!/usr/bin/env bash
# Step 2: configure the realm for people. Safe to re-run.
#
# Creates:
#   - realm roles openshell-admin (platform admin) and openshell-user (the gateway's defaults)
#   - client openshell-gateway: the API the gateway represents, used only as the audience
#   - client scope openshell-gateway-audience: adds aud=openshell-gateway to access tokens.
#     The gateway accepts one audience, so every client below gets this scope.
#   - client openshell-cli: public, Authorization Code + PKCE and device flow for `openshell gateway login`.
#     Direct access grants are on for scripted checks in this evaluation realm only.
#   - client openshell-dashboard: confidential, used by oauth2-proxy in front of the dashboard
#   - client openshell-automation: confidential service account with openshell-admin, for CI and
#     admin scripts (`OPENSHELL_OIDC_CLIENT_SECRET` in the CLI)
#   - user platform-admin with openshell-admin; the demo user gets openshell-user
# Secrets (namespace ${NAMESPACE}): keycloak-platform-admin, openshell-dashboard-oidc, openshell-automation-oidc.
set -euo pipefail
. "$(dirname "$0")/env.sh"

secret_value() { oc -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d; }
ensure_secret() {  # namespace name key value...
    local ns=$1 name=$2; shift 2
    oc -n "${ns}" get secret "${name}" >/dev/null 2>&1 && return 0
    local args=()
    while [[ $# -gt 0 ]]; do args+=(--from-literal="$1=$2"); shift 2; done
    oc -n "${ns}" create secret generic "${name}" "${args[@]}" >/dev/null
}

ensure_secret "${NAMESPACE}" keycloak-platform-admin username platform-admin password "$(openssl rand -hex 12)"
ensure_secret "${NAMESPACE}" openshell-dashboard-oidc client-secret "$(openssl rand -hex 24)" cookie-secret "$(openssl rand -hex 16)"
ensure_secret "${NAMESPACE}" openshell-automation-oidc client-secret "$(openssl rand -hex 24)"

oc -n "${KEYCLOAK_NAMESPACE}" exec -i deploy/keycloak -- env \
    KC_ADMIN_PW="$(secret_value "${KEYCLOAK_NAMESPACE}" keycloak-admin password)" \
    ADMIN_PW="$(secret_value "${NAMESPACE}" keycloak-platform-admin password)" \
    DASH_SECRET="$(secret_value "${NAMESPACE}" openshell-dashboard-oidc client-secret)" \
    AUTO_SECRET="$(secret_value "${NAMESPACE}" openshell-automation-oidc client-secret)" \
    R="${REALM}" AUD="${GATEWAY_AUDIENCE}" DASH_HOST="${DASHBOARD_HOST}" DEMO_USER="${DEMO_USER}" \
    bash -s <<'IN'
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh; CFG=(--config /tmp/kcadm.config)
$KC config credentials "${CFG[@]}" --server http://localhost:8080 --realm master --user admin --password "$KC_ADMIN_PW" >/dev/null 2>&1
client_uuid() { $KC get clients -r "$R" "${CFG[@]}" -q clientId="$1" --fields id --format csv --noquotes | head -1; }
scope_uuid() {
    while IFS=, read -r sid sname; do [ "$sname" = "$1" ] && { echo "$sid"; return; }; done \
        < <($KC get client-scopes -r "$R" "${CFG[@]}" --fields id,name --format csv --noquotes)
}
user_uuid() { $KC get users -r "$R" "${CFG[@]}" -q username="$1" -q exact=true --fields id --format csv --noquotes | head -1; }

for role in openshell-admin openshell-user; do
    $KC get "roles/$role" -r "$R" "${CFG[@]}" >/dev/null 2>&1 || $KC create roles -r "$R" "${CFG[@]}" -s name="$role" >/dev/null
done

[ -n "$(client_uuid "$AUD")" ] || $KC create clients -r "$R" "${CFG[@]}" -s clientId="$AUD" -s publicClient=false \
    -s standardFlowEnabled=false -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false >/dev/null
SCOPE=openshell-gateway-audience
if [ -z "$(scope_uuid "$SCOPE")" ]; then
    SID=$($KC create client-scopes -r "$R" "${CFG[@]}" -i -s name="$SCOPE" -s protocol=openid-connect \
        -s 'attributes."include.in.token.scope"=false')
    $KC create "client-scopes/$SID/protocol-mappers/models" -r "$R" "${CFG[@]}" -s name=gateway-audience \
        -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
        -s "config.\"included.client.audience\"=$AUD" -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' >/dev/null
fi
SID=$(scope_uuid "$SCOPE")

ensure_client() {  # clientId, then kcadm -s settings
    local id=$1; shift
    if [ -z "$(client_uuid "$id")" ]; then $KC create clients -r "$R" "${CFG[@]}" -s clientId="$id" "$@" >/dev/null
    else $KC update "clients/$(client_uuid "$id")" -r "$R" "${CFG[@]}" "$@" >/dev/null; fi
    $KC update "clients/$(client_uuid "$id")/default-client-scopes/$SID" -r "$R" "${CFG[@]}" >/dev/null
}
ensure_client openshell-cli -s publicClient=true -s standardFlowEnabled=true -s directAccessGrantsEnabled=true \
    -s 'redirectUris=["http://localhost/*","http://127.0.0.1/*"]' \
    -s 'attributes."pkce.code.challenge.method"=S256' -s 'attributes."oauth2.device.authorization.grant.enabled"=true'
ensure_client openshell-dashboard -s publicClient=false -s secret="$DASH_SECRET" -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false -s "redirectUris=[\"https://${DASH_HOST}/oauth2/callback\"]" \
    -s "webOrigins=[\"https://${DASH_HOST}\"]" -s 'attributes."pkce.code.challenge.method"=S256' \
    -s "attributes.\"post.logout.redirect.uris\"=https://${DASH_HOST}/"
ensure_client openshell-automation -s publicClient=false -s secret="$AUTO_SECRET" -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false -s directAccessGrantsEnabled=false
$KC add-roles -r "$R" "${CFG[@]}" --uusername service-account-openshell-automation --rolename openshell-admin

if [ -z "$(user_uuid platform-admin)" ]; then
    $KC create users -r "$R" "${CFG[@]}" -s username=platform-admin -s enabled=true -s emailVerified=true \
        -s email=platform-admin@example.com -s firstName=Platform -s lastName=Admin >/dev/null
fi
$KC set-password -r "$R" "${CFG[@]}" --username platform-admin --new-password "$ADMIN_PW"
$KC add-roles -r "$R" "${CFG[@]}" --uusername platform-admin --rolename openshell-admin
$KC add-roles -r "$R" "${CFG[@]}" --uusername "$DEMO_USER" --rolename openshell-user
echo "user realm configured"
IN
log "people can now sign in to realm ${REALM}: ${DEMO_USER} (openshell-user), platform-admin (openshell-admin)"
