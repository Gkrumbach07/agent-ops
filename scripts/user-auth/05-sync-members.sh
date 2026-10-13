#!/usr/bin/env bash
# Step 5: make workspace membership follow Keycloak groups. Safe to re-run; DRY_RUN=true prints the plan.
#
# For every group named ${GROUP_PREFIX}-ws-<workspace>-users or -admins, the workspace exists and
# its members are exactly the enabled users of those groups (admin wins over user). Members of a
# managed workspace who are in neither group are removed: removing someone from the group is the
# offboarding step. Workspaces without any such group are not touched.
#
# Keycloak is read with ${SYNC_CLIENT} (view/query users and groups only). The gateway is changed
# with ${AUTOMATION_CLIENT}, the gateway admin service account. Neither token is printed.
#
# Everything is read from Keycloak before anything is changed, and a read that fails ends the run.
# A group or a member list that could not be read must never be taken for an empty one: the sync
# removes the members it does not find.
set -euo pipefail
. "$(dirname "$0")/env.sh"
DRY_RUN="${DRY_RUN:-false}"
MAX_GROUPS=1000; MAX_MEMBERS=10000   # one page each; the run stops rather than work from a partial list

sync_secret=$(get_secret "${NAMESPACE}" openshell-member-sync-oidc client-secret)
kc_token=$(printf '%s' "${sync_secret}" | curl -sf -m 20 "${ISSUER}/protocol/openid-connect/token" \
    -d grant_type=client_credentials -d client_id="${SYNC_CLIENT}" --data-urlencode client_secret@- \
    | jq -er .access_token) || die "could not get a token for ${SYNC_CLIENT} from ${ISSUER}"
kc() {  # path [query as curl -d/--data-urlencode arguments] -> the JSON array Keycloak answers with
    local path=$1 out; shift
    out=$(curl -sf -m 30 -G -H @<(printf 'Authorization: Bearer %s' "${kc_token}") "$@" \
        "${KEYCLOAK_URL}/admin/realms/${REALM}${path}") || die "Keycloak did not answer ${path}"
    jq -e 'type == "array"' >/dev/null <<<"${out}" || die "unexpected answer from Keycloak for ${path}"
    printf '%s\n' "${out}"
}

auto_secret=$(get_secret "${NAMESPACE}" openshell-automation-oidc client-secret)
export OPENSHELL_GATEWAY="${CLI_GATEWAY_NAME}"
os() { OPENSHELL_OIDC_CLIENT_SECRET="${auto_secret}" openshell "$@"; }   # the secret reaches the CLI only
# Client-credentials tokens have no refresh token; log in again rather than let the CLI try to refresh.
out=$(os gateway login "${CLI_GATEWAY_NAME}" 2>&1) || die "openshell gateway login ${CLI_GATEWAY_NAME} failed: ${out}"

# Read Keycloak. Managed workspaces come from group names, so an emptied group still removes its
# last member. desired: workspace<TAB>subject<TAB>role<TAB>username.
prefix="${GROUP_PREFIX}-ws-"
rest_re='^([a-z0-9]([-a-z0-9]*[a-z0-9])?)-(users|admins)$'
groups_json=$(kc /groups --data-urlencode "search=${prefix}" -d "max=${MAX_GROUPS}" -d briefRepresentation=true)
[[ $(jq length <<<"${groups_json}") -lt ${MAX_GROUPS} ]] || die "${MAX_GROUPS} or more groups match ${prefix}; the list may be incomplete"
managed=""; desired=""
while IFS=$'\t' read -r id name; do
    [[ "${name}" == "${prefix}"* ]] || continue
    [[ "${name#"${prefix}"}" =~ ${rest_re} ]] || continue
    ws=${BASH_REMATCH[1]}; role=user
    if [[ ${BASH_REMATCH[3]} == admins ]]; then role=admin; fi
    members_json=$(kc "/groups/${id}/members" -d "max=${MAX_MEMBERS}" -d briefRepresentation=true)
    [[ $(jq length <<<"${members_json}") -lt ${MAX_MEMBERS} ]] || die "group ${name} has ${MAX_MEMBERS} or more members; the list may be incomplete"
    managed+="${ws}"$'\n'
    desired+=$(jq -r --arg ws "${ws}" --arg role "${role}" \
        '.[] | select(.enabled) | "\($ws)\t\(.id)\t\($role)\t\(.username)"' <<<"${members_json}")$'\n'
done < <(jq -r '.[] | "\(.id)\t\(.name)"' <<<"${groups_json}")
managed=$(printf '%s' "${managed}" | sort -u)
desired=$(printf '%s' "${desired}" | sort -t$'\t' -k1,1 -k2,2 -k3,3 |
    awk -F'\t' 'NF >= 3 {k=$1"\t"$2; if (!(k in r) || $3=="admin") {r[k]=$3; u[k]=$4}} END {for (k in r) print k"\t"r[k]"\t"u[k]}' | sort)

changes=0
run() { changes=$((changes+1)); echo "  openshell $*"; [[ "${DRY_RUN}" == true ]] || os "$@" >/dev/null; }
for ws in ${managed}; do
    echo "workspace ${ws}"
    current=""
    if os workspace get "${ws}" >/dev/null 2>&1; then
        members_json=$(os workspace member list --workspace "${ws}" -o json) || die "could not list the members of workspace ${ws}"
        current=$(jq -r '.members[]? | "\(.subject)\t\(.role)"' <<<"${members_json}")
    else
        run workspace create --name "${ws}"
    fi
    want=$(awk -F'\t' -v ws="${ws}" '$1==ws {print $2"\t"$3"\t"$4}' <<<"${desired}")
    while IFS=$'\t' read -r sub role user; do
        [[ -n "${sub}" ]] || continue
        have=$(awk -F'\t' -v s="${sub}" '$1==s {print $2}' <<<"${current}")
        if [[ -z "${have}" ]]; then
            run workspace member add --workspace "${ws}" --subject "${sub}" --role "${role}"   # ${user}
        elif [[ "${have}" != "${role}" ]]; then
            run workspace member remove --workspace "${ws}" --subject "${sub}"
            run workspace member add --workspace "${ws}" --subject "${sub}" --role "${role}"
        fi
    done <<< "${want}"
    while IFS=$'\t' read -r sub _; do
        [[ -n "${sub}" ]] || continue
        cut -f1 <<<"${want}" | grep -Fx -- "${sub}" >/dev/null || run workspace member remove --workspace "${ws}" --subject "${sub}"
    done <<< "${current}"
done
log "${changes} change(s)$([[ "${DRY_RUN}" == true ]] && echo ' planned (dry run)' || true)"
