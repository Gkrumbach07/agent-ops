#!/usr/bin/env bash
# Step 4: configure the Keycloak realm for SPIFFE token exchange. Safe to re-run.
#
# Creates:
#   - realm ${REALM}, with SSO session idle/max of 10 hours (stored user tokens are only
#     valid while the user's SSO session is alive; the Keycloak default idle is 30 minutes)
#   - SPIFFE identity provider "spiffe" that trusts the SPIRE JWKS
#   - gateway client (federated-jwt, client ID = gateway SPIFFE ID, token exchange)
#   - target API client and audience scope ${TARGET_API}
#   - user client "openshell-user" whose tokens include the gateway in their audience
#   - demo user ${DEMO_USER}; password in Secret ${NAMESPACE}/keycloak-demo-user
#   - service account "keycloak-registrar" (client_credentials, realm-management roles
#     manage-clients, view-clients, query-clients); credentials in Secret
#     ${NAMESPACE}/keycloak-registrar-keycloak for the registrar interceptor
set -euo pipefail
. "$(dirname "$0")/env.sh"

ensure_secret "${NAMESPACE}" keycloak-registrar-keycloak \
    KEYCLOAK_CLIENT_ID keycloak-registrar KEYCLOAK_CLIENT_SECRET "$(openssl rand -hex 24)"
ensure_secret "${NAMESPACE}" keycloak-demo-user username "${DEMO_USER}" password "$(openssl rand -hex 12)"

kc_exec REGISTRAR_SECRET="$(get_secret "${NAMESPACE}" keycloak-registrar-keycloak KEYCLOAK_CLIENT_SECRET)" \
    DEMO_PW="$(get_secret "${NAMESPACE}" keycloak-demo-user password)" \
    TRUST_DOMAIN="${TRUST_DOMAIN}" SPIRE_JWKS="${SPIRE_JWKS}" \
    GATEWAY_SPIFFE_ID="${GATEWAY_SPIFFE_ID}" TARGET_API="${TARGET_API}" DEMO_USER="${DEMO_USER}" <<'IN'
scope_uuid() {
    while IFS=, read -r sid sname; do [ "$sname" = "$1" ] && { echo "$sid"; return; }; done \
        < <($KC get client-scopes -r "$R" "${CFG[@]}" --fields id,name --format csv --noquotes)
}

$KC get "realms/$R" "${CFG[@]}" >/dev/null 2>&1 || $KC create realms "${CFG[@]}" -s realm="$R" -s enabled=true
$KC update "realms/$R" "${CFG[@]}" -s ssoSessionIdleTimeout=36000 -s ssoSessionMaxLifespan=36000

$KC get identity-provider/instances/spiffe -r "$R" "${CFG[@]}" >/dev/null 2>&1 || \
    $KC create identity-provider/instances -r "$R" "${CFG[@]}" -s alias=spiffe -s providerId=spiffe \
        -s enabled=true -s "config.trustDomain=${TRUST_DOMAIN}" -s "config.bundleEndpoint=${SPIRE_JWKS}"

[ -n "$(cid "$GATEWAY_SPIFFE_ID")" ] || $KC create clients -r "$R" "${CFG[@]}" \
    -s clientId="$GATEWAY_SPIFFE_ID" -s publicClient=false -s clientAuthenticatorType=federated-jwt \
    -s standardFlowEnabled=false -s directAccessGrantsEnabled=false \
    -s 'attributes."jwt.credential.issuer"=spiffe' -s "attributes.\"jwt.credential.sub\"=$GATEWAY_SPIFFE_ID" \
    -s 'attributes."standard.token.exchange.enabled"=true' >/dev/null

[ -n "$(cid "$TARGET_API")" ] || $KC create clients -r "$R" "${CFG[@]}" -s clientId="$TARGET_API" \
    -s publicClient=false -s standardFlowEnabled=false -s directAccessGrantsEnabled=false >/dev/null
if [ -z "$(scope_uuid "$TARGET_API")" ]; then
    SID=$($KC create client-scopes -r "$R" "${CFG[@]}" -i -s name="$TARGET_API" -s protocol=openid-connect)
    $KC create "client-scopes/$SID/protocol-mappers/models" -r "$R" "${CFG[@]}" -s name=audience \
        -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
        -s "config.\"included.client.audience\"=$TARGET_API" -s 'config."access.token.claim"=true' >/dev/null
fi

if [ -z "$(cid openshell-user)" ]; then
    UC=$($KC create clients -r "$R" "${CFG[@]}" -i -s clientId=openshell-user -s publicClient=true \
        -s standardFlowEnabled=false -s directAccessGrantsEnabled=true \
        -s 'attributes."access.token.lifespan"=28800')
    $KC create "clients/$UC/protocol-mappers/models" -r "$R" "${CFG[@]}" -s name=gateway-audience \
        -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
        -s "config.\"included.client.audience\"=$GATEWAY_SPIFFE_ID" -s 'config."access.token.claim"=true' >/dev/null
fi

if [ -z "$($KC get users -r "$R" "${CFG[@]}" -q username="$DEMO_USER" --fields id --format csv --noquotes)" ]; then
    $KC create users -r "$R" "${CFG[@]}" -s username="$DEMO_USER" -s enabled=true -s emailVerified=true \
        -s email="$DEMO_USER@example.com" -s firstName="$DEMO_USER" -s lastName=demo >/dev/null
    $KC set-password -r "$R" "${CFG[@]}" --username "$DEMO_USER" --new-password "$DEMO_PW"
fi

[ -n "$(cid keycloak-registrar)" ] || $KC create clients -r "$R" "${CFG[@]}" -s clientId=keycloak-registrar \
    -s publicClient=false -s secret="$REGISTRAR_SECRET" -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false -s directAccessGrantsEnabled=false >/dev/null
$KC add-roles -r "$R" "${CFG[@]}" --uusername service-account-keycloak-registrar --cclientid realm-management \
    --rolename manage-clients --rolename view-clients --rolename query-clients
echo "realm $R configured"
IN
log "realm ${REALM} ready (issuer ${ISSUER})"
