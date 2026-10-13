#!/usr/bin/env bash
# Build examples/byo-agent on the cluster (OpenShift binary build into the internal registry),
# run it in a sandbox with examples/byo-agent/policy.yaml, print the agent's output, clean up.
# Uses the openshell CLI as configured (after make user-auth: OPENSHELL_GATEWAY and
# OPENSHELL_OIDC_CLIENT_SECRET for the admin entry, or a user's own login).
set -euo pipefail
NAMESPACE="${OPENSHELL_NAMESPACE:-openshell}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=byo-agent
log() { echo -e "\033[0;32m[byo-agent]\033[0m $*"; }

oc -n "${NAMESPACE}" get bc "${NAME}" >/dev/null 2>&1 || \
    oc -n "${NAMESPACE}" new-build --binary --strategy=docker --name "${NAME}" >/dev/null
# The example uses Containerfile; OpenShift's docker strategy looks for Dockerfile by default.
oc -n "${NAMESPACE}" patch bc "${NAME}" --type=merge -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"Containerfile"}}}}' >/dev/null
# A service account's session lasts 5 minutes and cannot be refreshed, and the build below can
# take longer, so sign in again before each group of CLI calls. A person's browser login refreshes
# itself, and the mTLS entry of an install without user authentication has no session.
login() {
    if [[ -n "${OPENSHELL_OIDC_CLIENT_SECRET:-}" ]]; then
        openshell gateway login ${OPENSHELL_GATEWAY:+"${OPENSHELL_GATEWAY}"} >/dev/null
    fi
}

log "building the image on the cluster"
build_log="$(mktemp)"
cleanup() {   # the sandbox is removed however the script ends: it holds an egress policy and may hold credentials
    rm -f "${build_log}"
    login 2>/dev/null || true
    openshell sandbox delete "${NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
oc -n "${NAMESPACE}" start-build "${NAME}" --from-dir "${ROOT}/examples/byo-agent" --follow --wait >"${build_log}" 2>&1 || {
    cat "${build_log}" >&2
    echo "ERROR: the image build failed; its log is above" >&2
    exit 1
}
# Run the image that was just built, by digest: the :latest tag moves with every build.
image="$(oc -n "${NAMESPACE}" get istag "${NAME}:latest" -o jsonpath='{.image.dockerImageReference}')"

login
openshell sandbox delete "${NAME}" >/dev/null 2>&1 || true
log "starting sandbox ${NAME} from ${image}"
openshell sandbox create --name "${NAME}" --from "${image}" --policy "${ROOT}/examples/byo-agent/policy.yaml" --no-tty </dev/null >/dev/null
# stdin is closed: the CLI otherwise waits for it to end, which never happens without a terminal.
openshell sandbox exec --name "${NAME}" --no-tty -- /usr/bin/python3.12 /usr/local/bin/agent.py </dev/null
