#!/usr/bin/env bash
# Step 2: give every OpenShell sandbox supervisor its own SPIFFE ID:
#   <trust-domain>/openshell/sandbox/<sandbox-id>
# The gateway keeps the ZTWIM default <trust-domain>/ns/<namespace>/sa/<release>.
set -euo pipefail
. "$(dirname "$0")/env.sh"

oc apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: openshell-sandboxes-${NAMESPACE}
spec:
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: 'spiffe://{{ .TrustDomain }}/openshell/sandbox/{{ index .PodMeta.Annotations "openshell.ai/sandbox-id" }}'
  jwtTtl: 5m
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${NAMESPACE}
  podSelector:
    matchLabels:
      openshell.ai/managed-by: openshell
      openshell.ai/component: supervisor
EOF
log "sandbox supervisors in ${NAMESPACE} get ${TRUST_DOMAIN}/openshell/sandbox/<sandbox-id>"
