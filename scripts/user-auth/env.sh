#!/usr/bin/env bash
# Shared settings for the user-authentication (OIDC) scripts. Builds on the token-exchange
# settings and switches Keycloak to its public HTTPS Route, so the browser, the CLI, the
# gateway and the sandboxes all see one issuer.
. "$(dirname "${BASH_SOURCE[0]}")/../token-exchange/env.sh"

APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak-${KEYCLOAK_NAMESPACE}.${APPS_DOMAIN}}"
export KEYCLOAK_URL="https://${KEYCLOAK_HOST}"
export ISSUER="${KEYCLOAK_URL}/realms/${REALM}"
export GATEWAY_AUDIENCE="${GATEWAY_AUDIENCE:-openshell-gateway}"   # the one audience the gateway accepts
export DASHBOARD_HOST="${DASHBOARD_HOST:-openshell-dashboard-${NAMESPACE}.${APPS_DOMAIN}}"
export BFF_LOCAL_PORT="${BFF_LOCAL_PORT:-18081}"
