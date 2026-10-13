#!/usr/bin/env bash
# Remove a user's access to a workspace: revoke.sh <username> <workspace>
# Removes the user from both workspace groups and syncs: the membership is gone at once, so even a
# token issued before the revoke is denied in that workspace. Run without a workspace to remove the
# user from every workspace group of this gateway.
set -euo pipefail
. "$(dirname "$0")/env.sh"
user=${1:?usage: revoke.sh <username> [workspace]}; ws=${2:-}
[[ "${user}" =~ ^[A-Za-z0-9._@-]+$ ]] || { echo "ERROR: invalid username" >&2; exit 1; }
[[ -z "${ws}" || "${ws}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "ERROR: invalid workspace name" >&2; exit 1; }

# The group names are matched as text plus a fixed pattern, so nothing in GROUP_PREFIX is read as a
# regular expression.
kc_exec U="${user}" PREFIX="${GROUP_PREFIX}-ws-" WS="${ws}" <<'IN'
u=$($KC get users -r "$R" "${CFG[@]}" -q username="$U" -q exact=true --fields id --format csv --noquotes | head -1)
[ -n "$u" ] || { echo "ERROR: no user $U" >&2; exit 1; }
groups=$($KC get "users/$u/groups" -r "$R" "${CFG[@]}" --fields id,name --format csv --noquotes)
while IFS=, read -r g name; do
    [[ "$name" == "$PREFIX"* ]] || continue
    rest=${name#"$PREFIX"}
    if [ -n "$WS" ]; then
        [[ "$rest" == "$WS-users" || "$rest" == "$WS-admins" ]] || continue
    else
        [[ "$rest" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?-(users|admins)$ ]] || continue
    fi
    $KC delete "users/$u/groups/$g" -r "$R" "${CFG[@]}"
    echo "removed from $name"
done <<< "$groups"
IN
"$(dirname "$0")/05-sync-members.sh"
