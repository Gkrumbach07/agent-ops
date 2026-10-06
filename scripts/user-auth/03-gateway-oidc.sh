#!/usr/bin/env bash
# Step 3: turn on user authentication in the gateway and connect the CLI with OIDC.
#
# Upgrades the gateway with server.oidc (issuer, audience openshell-gateway, roles from
# realm_access.roles) and allowUnauthenticatedUsers=false, re-registers the keycloak-registrar
# interceptor (Helm resets it), then registers a second CLI gateway entry, "<name>-oidc", that
# signs in as the openshell-automation service account (client credentials).
set -euo pipefail
. "$(dirname "$0")/env.sh"
ROOT="$(dirname "$0")/.."

OPENSHELL_OIDC_ISSUER="${ISSUER}" OPENSHELL_OIDC_AUDIENCE="${GATEWAY_AUDIENCE}" \
    OPENSHELL_ENABLE_SPIFFE=true "${ROOT}/deploy-openshell.sh"
if oc -n "${NAMESPACE}" get deploy/keycloak-registrar >/dev/null 2>&1; then
    "${ROOT}/token-exchange/05-deploy-registrar.sh"
fi

name="${OPENSHELL_GATEWAY_NAME:-openshift}-oidc"
url="https://$(oc -n "${NAMESPACE}" get route openshell -o jsonpath='{.spec.host}')"
openshell gateway remove "${name}" >/dev/null 2>&1 || true
dir="${HOME}/.config/openshell/gateways/${name}/mtls"
mkdir -p "${dir}"
oc -n "${NAMESPACE}" get secret openshell-client-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "${dir}/ca.crt"
OPENSHELL_OIDC_CLIENT_SECRET="$(oc -n "${NAMESPACE}" get secret openshell-automation-oidc -o jsonpath='{.data.client-secret}' | base64 -d)" \
    openshell gateway add "${url}" --name "${name}" --oidc-issuer "${ISSUER}" \
    --oidc-client-id openshell-automation --oidc-audience "${GATEWAY_AUDIENCE}"
log "gateway now requires OIDC; CLI entry ${name} signs in as openshell-automation"
