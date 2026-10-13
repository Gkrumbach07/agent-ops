#!/usr/bin/env bash
# Shared settings for the token-exchange scripts. Source it; override any value
# by exporting it before running a script.

export NAMESPACE="${OPENSHELL_NAMESPACE:-openshell}"           # OpenShell gateway namespace
export RELEASE="${OPENSHELL_RELEASE:-openshell}"               # OpenShell Helm release name
export KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-${NAMESPACE}}"
export REALM="${KEYCLOAK_REALM:-openshell}"
export TARGET_API="${TARGET_API:-whoami-api}"                  # Keycloak audience of the API agents call
export DEMO_USER="${DEMO_USER:-alice}"

# Trust domain configured in the ZeroTrustWorkloadIdentityManager CR, as a SPIFFE URI.
if [[ -z "${TRUST_DOMAIN:-}" ]]; then
    td=$(oc get zerotrustworkloadidentitymanager cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null || true)
    if [[ -z "${td}" ]]; then
        echo "ERROR: could not read spec.trustDomain from the ZeroTrustWorkloadIdentityManager CR. Install ZTWIM first." >&2
        exit 1
    fi
    export TRUST_DOMAIN="spiffe://${td}"
fi

# In-cluster by default; scripts/user-auth/env.sh switches it to the public HTTPS Route.
export KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local}"
export ISSUER="${KEYCLOAK_URL}/realms/${REALM}"
# In-cluster callers (token endpoint, JWKS) use the Service directly: no Route, no certificate trust.
# Tokens still carry ISSUER, because Keycloak's hostname is fixed to it.
export REALM_INTERNAL_URL="http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local/realms/${REALM}"
export GATEWAY_SPIFFE_ID="${TRUST_DOMAIN}/ns/${NAMESPACE}/sa/${RELEASE}"
# ZTWIM installed into another namespace than openshift-ztwim: set SPIRE_JWKS to the /keys URL of its
# OIDC discovery provider. Step 1 (01-fix-ztwim-oidc.sh) is only for openshift-ztwim.
export SPIRE_JWKS="${SPIRE_JWKS:-https://spire-spiffe-oidc-discovery-provider.openshift-ztwim.svc.cluster.local/keys}"

log() { echo -e "\033[0;32m[$(basename "$0")]\033[0m $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Read one key of a Secret: get_secret <namespace> <name> <key>
get_secret() { oc -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | base64 -d; }

# Create a Secret unless it exists: ensure_secret <namespace> <name> <key> <value> [<key> <value>...]
# The values go to oc on stdin, so they are not in any process's arguments.
ensure_secret() {
    local ns=$1 name=$2; shift 2
    oc -n "${ns}" get secret "${name}" >/dev/null 2>&1 && return 0
    {
        printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\ndata:\n' "${name}"
        while [[ $# -gt 0 ]]; do
            printf '  %s: %s\n' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"; shift 2
        done
    } | oc -n "${ns}" create -f - >/dev/null
}

# Run a kcadm script (on stdin) inside the Keycloak pod as the bootstrap admin (evaluation
# installs): kc_exec [NAME=value...] <<'IN' ... IN
# The script starts logged in, with $KC (kcadm.sh), "${CFG[@]}" (its --config option), $R (the
# realm), cid <clientId> (a client's UUID) and every NAME it was given. The admin password and
# the NAME=value pairs travel on stdin with the script. As arguments of `oc exec` they would be
# recorded in the API server's audit log and shown in the pod's process list.
kc_exec() {
    local kv admin_pw
    admin_pw=$(get_secret "${KEYCLOAK_NAMESPACE}" keycloak-admin password)
    {
        printf 'export KC_CLI_PASSWORD=%q R=%q\n' "${admin_pw}" "${REALM}"
        for kv in "$@"; do printf 'export %s=%q\n' "${kv%%=*}" "${kv#*=}"; done
        cat <<'PREAMBLE'
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh; CFG=(--config /tmp/kcadm.config)
$KC config credentials "${CFG[@]}" --server http://localhost:8080 --realm master --user admin >/dev/null 2>&1
unset KC_CLI_PASSWORD
cid() { $KC get clients -r "$R" "${CFG[@]}" -q clientId="$1" --fields id --format csv --noquotes | head -1; }
PREAMBLE
        cat
    } | oc -n "${KEYCLOAK_NAMESPACE}" exec -i deploy/keycloak -- bash -s
}
