#!/usr/bin/env bash
# Verify user authentication (OIDC) end to end. Prints PASS/FAIL per check, exits non-zero on any FAIL.
#
#  1. The gateway refuses a caller with no token.
#  2. Alice (openshell-user) is identified, with her role.
#  3. Before membership, Alice is denied in workspace "default".
#  4. After a platform admin adds her, Alice can list, create and delete sandboxes.
#  5. The dashboard's browser login works: Route -> oauth2-proxy -> Keycloak login -> dashboard as alice.
#
# Tokens come from the password grant on openshell-cli, which this evaluation realm enables for testing.
set -uo pipefail
. "$(dirname "$0")/env.sh"

fails=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS $1"; else echo "  FAIL $1 (got $2, want $3)"; fails=$((fails+1)); fi; }

token() {  # user password -> access token
    curl -sk -m 20 "${ISSUER}/protocol/openid-connect/token" -d grant_type=password -d client_id=openshell-cli \
        -d scope=openid --data-urlencode "username=$1" --data-urlencode "password=$2" | jq -r '.access_token // empty'
}
bff() {  # METHOD PATH TOKEN [BODY] -> HTTP status; body in /tmp/user-auth-bff.json
    local args=(-s -m 60 -o /tmp/user-auth-bff.json -w '%{http_code}' -X "$1")
    [[ -n "$3" ]] && args+=(-H "Authorization: Bearer $3")
    [[ -n "${4:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$4")
    curl "${args[@]}" "http://127.0.0.1:${BFF_LOCAL_PORT}/api/v1$2"
}

alice_pw=$(oc -n "${NAMESPACE}" get secret keycloak-demo-user -o jsonpath='{.data.password}' | base64 -d)
admin_pw=$(oc -n "${NAMESPACE}" get secret keycloak-platform-admin -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

# The BFF listens on 127.0.0.1 inside the pod; port-forward reaches it for API checks.
oc -n "${NAMESPACE}" port-forward deploy/openshell-dashboard "${BFF_LOCAL_PORT}:8080" >/dev/null 2>&1 & pf=$!
trap 'kill $pf 2>/dev/null' EXIT
sleep 4

echo "Gateway"
check "no token is refused" "$(bff GET /workspaces '')" 401
alice=$(token "${DEMO_USER}" "${alice_pw}")
check "alice gets a token" "$([[ -n "${alice}" ]] && echo yes || echo no)" yes
check "alice is identified" "$(bff GET /auth/whoami "${alice}")" 200
check "alice has role openshell-user" "$(jq -r '(.roles // []) | index("openshell-user") != null' /tmp/user-auth-bff.json)" true
alice_sub=$(jq -r '.subject // empty' /tmp/user-auth-bff.json)

admin=$(token platform-admin "${admin_pw}")
bff DELETE "/workspaces/default/members/${alice_sub}" "${admin}" >/dev/null
check "alice denied before membership" "$(bff GET /workspaces/default/sandboxes "${alice}")" 403
check "admin adds alice to default" "$(bff POST /workspaces/default/members "${admin}" "{\"principalSubject\":\"${alice_sub}\",\"role\":\"USER\"}")" 201
check "alice lists sandboxes" "$(bff GET /workspaces/default/sandboxes "${alice}")" 200
policy=$(jq -c '.[0].spec.policy // {"version":1,"filesystem":{"includeWorkdir":true,"readOnly":["/usr","/lib","/etc"],"readWrite":["/tmp","/dev/null"]}}' /tmp/user-auth-bff.json)
check "alice creates a sandbox" "$(bff POST /workspaces/default/sandboxes "${alice}" "{\"name\":\"alice-oidc-check\",\"image\":\"registry.access.redhat.com/ubi9/ubi-minimal:latest\",\"policy\":${policy}}")" 201
check "alice deletes it" "$(bff DELETE /workspaces/default/sandboxes/alice-oidc-check "${alice}")" 200

echo "Dashboard browser login"
host=$(oc -n "${NAMESPACE}" get route openshell-dashboard -o jsonpath='{.spec.host}' 2>/dev/null)
jar=$(mktemp); trap 'kill $pf 2>/dev/null; rm -f "$jar"' EXIT
login_page=$(curl -sk -m 30 -c "$jar" -b "$jar" -L "https://${host}/oauth2/start?rd=/")
action=$(echo "$login_page" | grep -o 'action="[^"]*"' | head -1 | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
check "unauthenticated visit is sent to Keycloak" "$([[ "$action" == "${ISSUER}"/login-actions/* ]] && echo yes || echo no)" yes
curl -sk -m 30 -c "$jar" -b "$jar" -L -o /dev/null "$action" \
    --data-urlencode "username=${DEMO_USER}" --data-urlencode "password=${alice_pw}" -d credentialId=
whoami=$(curl -sk -m 30 -c "$jar" -b "$jar" "https://${host}/api/v1/auth/whoami")
check "dashboard session is alice" "$(echo "$whoami" | jq -r '.subject // empty')" "${alice_sub}"
check "dashboard without a session is refused" "$(curl -sk -m 30 -o /dev/null -w '%{http_code}' "https://${host}/api/v1/auth/whoami")" 401

[[ $fails -eq 0 ]] && echo "All checks passed." || { echo "${fails} check(s) failed."; exit 1; }
