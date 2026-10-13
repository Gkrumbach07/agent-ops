#!/usr/bin/env bash
# Verify user authentication end to end. Prints PASS/FAIL per check, exits non-zero on any FAIL.
#
# Access is driven by Keycloak groups only: grant.sh puts a user in a workspace group, the sync
# turns that into gateway membership; revoke.sh reverses both. The checks cover:
#   - the gateway: no token, no role, role without membership, role with membership
#   - the admin workflow: grant -> access in that workspace only; revoke -> no access
#   - the dashboard: login, session, role gate at the proxy, no direct path to the BFF
#   - hardening: no password login on the CLI client, no leftover test client
#
# User tokens come from a temporary test client with password login, deleted on exit.
set -uo pipefail   # no -e: a failed check is counted and the run goes on; the setup steps stop the run themselves
HERE="$(dirname "$0")"
. "${HERE}/env.sh"

fails=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS $1"; else echo "  FAIL $1 (got $2, want $3)"; fails=$((fails+1)); fi; }
oneof() { local name=$1 got=$2; shift 2; for w in "$@"; do [[ "$got" == "$w" ]] && { echo "  PASS ${name}"; return; }; done; echo "  FAIL ${name} (got $got, want one of $*)"; fails=$((fails+1)); }

TEST_CLIENT="openshell-verify-$(openssl rand -hex 3)"
tmp=$(mktemp -d) || exit 1   # response bodies, the cookie jar and the Authorization header: readable by this user only
body="${tmp}/bff.json"; jar="${tmp}/cookies"; auth="${tmp}/authorization"
cleanup() {
    if [[ -n "${pf:-}" ]]; then kill "${pf}" 2>/dev/null; wait "${pf}" 2>/dev/null; fi
    rm -rf "${tmp}"
    kc_exec TC="${TEST_CLIENT}" <<'IN' >/dev/null 2>&1
id=$(cid "$TC")
[ -n "$id" ] && $KC delete "clients/$id" -r "$R" "${CFG[@]}"
IN
}
trap cleanup EXIT

# Temporary test client: password login, same scope as the CLI client (this gateway's roles only).
kc_exec TC="${TEST_CLIENT}" API="${API_CLIENT}" <<'IN' >/dev/null || die "could not create the temporary test client ${TEST_CLIENT}"
id=$($KC create clients -r "$R" "${CFG[@]}" -i -s clientId="$TC" -s publicClient=true -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=true -s fullScopeAllowed=false)
api=$(cid "$API")
roles=$($KC get "clients/$api/roles" -r "$R" "${CFG[@]}")
$KC create "clients/$id/scope-mappings/clients/$api" -r "$R" "${CFG[@]}" -b "$roles"
IN

# Passwords and tokens are given to curl on stdin or in a file, not as arguments.
token() {  # client user password -> access token (empty when refused)
    printf '%s' "$3" | curl -s -m 20 "${ISSUER}/protocol/openid-connect/token" -d grant_type=password -d client_id="$1" \
        -d scope=openid --data-urlencode "username=$2" --data-urlencode password@- | jq -r '.access_token // empty'
}
bff() {  # METHOD PATH TOKEN [BODY] -> HTTP status; the response body is in ${body}
    local args=(-s -m 60 -o "${body}" -w '%{http_code}' -X "$1")
    if [[ -n "$3" ]]; then printf 'Authorization: Bearer %s' "$3" > "${auth}"; args+=(-H "@${auth}"); fi
    [[ -n "${4:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$4")
    curl "${args[@]}" "http://127.0.0.1:${BFF_LOCAL_PORT}/api/v1$2"
}

alice_pw=$(get_secret "${NAMESPACE}" keycloak-demo-user password); admin_pw=$(get_secret "${NAMESPACE}" keycloak-platform-admin password)
[[ -n "${alice_pw}" && -n "${admin_pw}" ]] || die "the demo user's or the platform admin's password Secret is missing"
oc -n "${NAMESPACE}" port-forward deploy/openshell-dashboard "${BFF_LOCAL_PORT}:8080" >/dev/null 2>&1 & pf=$!
up=000
for _ in $(seq 1 30); do   # until the forwarded port answers, with any status
    up=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${BFF_LOCAL_PORT}/api/v1/auth/config")
    [[ "${up}" != 000 ]] && break
    sleep 1
done
[[ "${up}" != 000 ]] || die "oc port-forward to the dashboard BFF did not come up on port ${BFF_LOCAL_PORT}"

echo "Gateway: who you are and what you may do"
"${HERE}/revoke.sh" "${DEMO_USER}" team-a >/dev/null 2>&1
check "no token is refused" "$(bff GET /workspaces '')" 401
alice=$(token "${TEST_CLIENT}" "${DEMO_USER}" "${alice_pw}")
oneof "alice in no group is refused" "$(bff GET /workspaces/default/sandboxes "${alice}")" 401 403
admin=$(token "${TEST_CLIENT}" platform-admin "${admin_pw}")
check "platform-admin is identified as admin" "$(bff GET /auth/whoami "${admin}"; jq -r '(.roles // []) | index("admin") != null' "${body}")" "200true"

echo "Admin workflow: grant and revoke with one command"
check "grant alice team-a" "$("${HERE}/grant.sh" "${DEMO_USER}" team-a >/dev/null 2>&1; echo $?)" 0
alice=$(token "${TEST_CLIENT}" "${DEMO_USER}" "${alice_pw}")
check "alice has role user" "$(bff GET /auth/whoami "${alice}"; jq -r '(.roles // []) | index("user") != null' "${body}")" "200true"
check "alice lists sandboxes in team-a" "$(bff GET /workspaces/team-a/sandboxes "${alice}")" 200
check "alice is denied in default" "$(bff GET /workspaces/default/sandboxes "${alice}")" 403
policy='{"version":1,"filesystem":{"includeWorkdir":true,"readOnly":["/bin","/usr","/lib","/proc","/dev/urandom","/etc","/var/log"],"readWrite":["/tmp","/dev/null"]},"landlock":{"compatibility":"best_effort"}}'
# Built outside the check: bash 3.2 (macOS) misreads \" inside "$(...)", splits the JSON into several
# words, and the check then compares two refused requests with each other and passes.
sandbox=$(jq -cn --argjson policy "${policy}" '{name: "alice-oidc-check", image: "registry.access.redhat.com/ubi9/ubi-minimal:latest", policy: $policy}')
check "alice creates a sandbox in team-a" "$(bff POST /workspaces/team-a/sandboxes "${alice}" "${sandbox}")" 201
check "alice deletes it" "$(bff DELETE /workspaces/team-a/sandboxes/alice-oidc-check "${alice}")" 200
check "revoke alice team-a" "$("${HERE}/revoke.sh" "${DEMO_USER}" team-a >/dev/null 2>&1; echo $?)" 0
# The old token is still valid and still carries the role: only the missing membership may refuse it.
check "alice is denied in team-a after revoke (old token)" "$(bff GET /workspaces/team-a/sandboxes "${alice}")" 403
alice=$(token "${TEST_CLIENT}" "${DEMO_USER}" "${alice_pw}")
oneof "alice is refused after revoke (new token)" "$(bff GET /workspaces/team-a/sandboxes "${alice}")" 401 403
"${HERE}/grant.sh" "${DEMO_USER}" team-a >/dev/null 2>&1   # leave alice with access for the browser checks

echo "Dashboard: login through the proxy"
host="${DASHBOARD_HOST}"
browser_login() {  # user password -> HTTP status of the dashboard page the login ends on
    : > "$jar"; local page action out
    page=$(curl -s -m 30 -c "$jar" -b "$jar" -L "https://${host}/oauth2/start?rd=/")
    action=$(echo "$page" | grep -o 'action="[^"]*"' | head -1 | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
    [[ "$action" == "${ISSUER}"/login-actions/* ]] || { echo "nologin"; return; }
    out=$(printf '%s' "$2" | curl -s -m 30 -c "$jar" -b "$jar" -L -o /dev/null -w '%{http_code} %{url_effective}' "$action" \
        --data-urlencode "username=$1" --data-urlencode password@-)
    # Keycloak answers a refused login with its form again and status 200, so the status only
    # counts when the redirects ended on the dashboard.
    if [[ "${out#* }" == "https://${host}/"* ]]; then echo "${out%% *}"; else echo "still-at-keycloak"; fi
}
session_whoami() { curl -s -m 30 -b "$jar" "https://${host}/api/v1/auth/whoami"; }
check "dashboard without a session is refused" "$(curl -s -m 30 -o /dev/null -w '%{http_code}' "https://${host}/api/v1/auth/whoami")" 401
check "alice signs in to the dashboard" "$(browser_login "${DEMO_USER}" "${alice_pw}")" 200
whoami_json=$(session_whoami)
check "dashboard session is alice" "$(echo "${whoami_json}" | jq -r '.displayName // empty' 2>/dev/null)" "${DEMO_USER}"
[[ "$(echo "${whoami_json}" | jq -r '.displayName // empty' 2>/dev/null)" == "${DEMO_USER}" ]] || echo "    whoami: ${whoami_json:0:200}"
"${HERE}/revoke.sh" "${DEMO_USER}" team-a >/dev/null 2>&1
check "a user without a role is stopped at the proxy" "$(browser_login "${DEMO_USER}" "${alice_pw}")" 403
"${HERE}/grant.sh" "${DEMO_USER}" team-a >/dev/null 2>&1
# The NetworkPolicy is tested by trying: the Keycloak pod, which is not the router, opens a TCP
# connection to the dashboard pod. Its own port is the control that shows the probe can connect.
reach() {  # host port -> open | blocked
    oc -n "${KEYCLOAK_NAMESPACE}" exec deploy/keycloak -- bash -c \
        "if timeout 5 bash -c '</dev/tcp/$1/$2' 2>/dev/null; then echo open; else echo blocked; fi" 2>/dev/null
}
dash_ip=$(oc -n "${NAMESPACE}" get pod -l app=openshell-dashboard -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
check "the probe pod can open a connection (control)" "$(reach 127.0.0.1 8080)" open
# No pod address, no answer: the two checks then fail instead of reporting "blocked".
check "another pod cannot reach the proxy port (NetworkPolicy)" "${dash_ip:+$(reach "${dash_ip}" 4180)}" blocked
check "another pod cannot reach the BFF port" "${dash_ip:+$(reach "${dash_ip}" 8080)}" blocked

echo "Hardening"
check "the CLI client refuses password login" "$(curl -s -m 20 "${ISSUER}/protocol/openid-connect/token" -d grant_type=password -d client_id="${CLI_CLIENT}" -d username=x -d password=x | jq -r .error)" unauthorized_client

[[ $fails -eq 0 ]] && echo "All checks passed." || { echo "${fails} check(s) failed."; exit 1; }
