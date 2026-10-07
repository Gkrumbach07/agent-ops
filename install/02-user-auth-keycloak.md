# User authentication with your own Keycloak: architecture and setup

> **Midstream Documentation**
>
> Manual setup against a Keycloak you already run. The two-gateway layout below was run end to end on
> OpenShift on 2026-10-05 (Red Hat build `v0.1.2-rhaiv.3`, oauth2-proxy v7.15.5) with an earlier
> revision of these steps that requested a custom API scope. This revision (source guide revised
> 2026-10-06) relies on Keycloak's role-based audience instead, which is the model
> [`make user-auth`](02-user-auth.md) configures and checks. Only Keycloak has been tested; Microsoft
> Entra ID has not. Support status of each component: [What was validated](../README.md#what-was-validated-and-its-support-status).

This guide describes how to deploy two independent OpenShell gateways and dashboards in an OpenShift cluster while using one externally managed Keycloak realm for authentication. Namespace A accepts `administrators-a` and `users-a`. Namespace B accepts `administrators-b` and `users-b`. Mary and Cameron are standard users in namespace A, and Joe is a standard user in namespace B. End users do not need OpenShift accounts.

| Deployment | Standard users | Accepted API audience | Accepted roles |
|---|---|---|---|
| `namespace-a` | Mary and Cameron | `openshell-api-a` | `users-a`, `administrators-a` |
| `namespace-b` | Joe | `openshell-api-b` | `users-b`, `administrators-b` |

**Recommended design.** Use one Keycloak realm with separate resource, dashboard, and CLI clients for each namespace. Assign Keycloak groups to the two API client roles for that gateway. Keycloak's built-in `roles` client scope adds the API client to `aud` when either permitted role is present in the access token. This leaves three clients per namespace: the API resource client, the Dashboard client, and the CLI client. The separate audiences prevent a token issued for one namespace from being replayed against the other namespace.

**Intended readers.** OpenShift platform engineers, Keycloak administrators, and OpenShell operators responsible for installation, access control, and production readiness.

**One gateway only?** Follow the namespace A steps and skip every "repeat for B" item.

## Which guide to follow

| | This guide | [User authentication](02-user-auth.md) (`make user-auth`) |
|---|---|---|
| Keycloak | Yours, externally managed | Deployed in the cluster in dev mode |
| How it is configured | By hand in the Keycloak console, then Helm values and one manifest | Scripts |
| API client (audience) | `openshell-api-a` | `openshell-api-<namespace>` |
| Client roles for admin and user | `administrators-a`, `users-a` | `admin`, `user` |
| Groups | `administrators-a`, `users-a` | `openshell-<namespace>-admins`, `openshell-<namespace>-ws-<workspace>-users` and `-admins` |
| Dashboard and CLI clients | `openshell-dashboard-a`, `openshell-cli-a` | `openshell-dashboard-<namespace>`, `openshell-cli-<namespace>` |
| Workspace membership | Added by hand ([Step 15](#step-15-add-workspace-members)) | `make grant`, `make sync-members` |

Both end in the same place: a gateway that validates Keycloak tokens for its own audience and client roles, and a dashboard behind oauth2-proxy. Role and group names are configuration, not fixed values; use the scripts to try the model and this guide to reproduce it on the identity provider you operate.

## Architecture and security model

Both OpenShell deployments trust the same Keycloak realm issuer, but each gateway validates a different access-token audience and API client-role path. Dashboard and CLI clients permit only the matching API client roles. Keycloak's built-in Audience Resolve mapper adds the matching API client to `aud` when one of those roles is present in the access token.

```
            Keycloak realm "openshell": one issuer, separate clients per namespace
            ┌────────────────────────────────────────────────────────────────────┐
            │ openshell-api-a        audience; client roles users-a and          │
            │                        administrators-a                            │
            │ openshell-dashboard-a  confidential client used by oauth2-proxy    │
            │ openshell-cli-a        public client, PKCE and device code         │
            └───────▲───────────────────────▲─────────────────────────▲──────────┘
              login │         discovery and │                   login │
                    │                  JWKS │                         │
 browser ─▶ Route ─▶ oauth2-proxy           │                    openshell CLI
                    │ access token          │                         │ access token
                    ▼                       │                         │
            dashboard BFF ─── token ──▶ Gateway A ◀───────────────────┘
            (loopback only)             (namespace-a)
                                        accepts aud openshell-api-a and a role in
                                        resource_access.openshell-api-a.roles
```

*Identity and token flow for one namespace. Namespace B is the same with the `-b` clients, groups and roles: Gateway B rejects a token issued for namespace A, and Gateway A rejects one issued for B.*

### Authentication boundaries

- Keycloak authenticates Mary, Cameron, Joe, administrators, and other OpenShell users.
- OpenShift authenticates only cluster operators, controllers, and workload service accounts.
- oauth2-proxy owns dashboard login, sessions, token refresh, logout, and CSRF protection.
- The dashboard BFF relays the access token and never validates, exchanges, or replaces it.
- Each gateway validates token signature, issuer, audience, expiry, and its `resource_access` role path.
- Sandbox supervisors use OpenShell workload authentication rather than a human user's Keycloak token.

### Why API client roles and separate audiences matter

Gateway A accepts only tokens containing `openshell-api-a` in `aud` and `users-a` or `administrators-a` below `resource_access.openshell-api-a.roles`. Gateway B applies the corresponding B checks. A user who discovers the other gateway hostname still cannot reuse a token from the wrong namespace.

OpenShell OIDC RBAC controls API methods. Provider and sandbox records remain gateway-wide resources rather than per-subject records, so separate gateways and namespaces are still required when A and B must be isolated.

## Identity and application inventory

| Keycloak object | Namespace A | Namespace B | Purpose |
|---|---|---|---|
| Groups | `users-a`, `administrators-a` | `users-b`, `administrators-b` | Human membership |
| API resource client | `openshell-api-a` | `openshell-api-b` | Audience and client-role namespace |
| API client roles | `users-a`, `administrators-a` | `users-b`, `administrators-b` | Gateway RBAC values |
| Built-in audience resolution | Audience Resolve | Audience Resolve | Adds the API client to `aud` when a permitted client role is present |
| Dashboard client | `openshell-dashboard-a` | `openshell-dashboard-b` | Confidential oauth2-proxy client |
| CLI client | `openshell-cli-a` | `openshell-cli-b` | Public native PKCE and device client |
| Gateway hostname | `gateway-a.example.com` | `gateway-b.example.com` | External HTTPS and gRPC endpoint |
| Dashboard hostname | `dashboard-a.example.com` | `dashboard-b.example.com` | Browser entry point through proxy |

### User assignment result

| User | Keycloak group | Dashboard A | Gateway A | Dashboard B | Gateway B |
|---|---|---|---|---|---|
| Mary | `users-a` | Allowed | Standard user | Denied | Denied |
| Cameron | `users-a` | Allowed | Standard user | Denied | Denied |
| Joe | `users-b` | Denied | Denied | Allowed | Standard user |

Mary, Cameron, and Joe do not need OpenShift `User` objects, OpenShift `Group` objects, `OAuthClient` resources, project membership, or Kubernetes RBAC bindings. Their identities, group membership, and application roles exist only in Keycloak. What they do need inside OpenShell is a workspace membership, which is [Step 15](#step-15-add-workspace-members).

## Values to collect before installation

| Value | Example placeholder | Owner |
|---|---|---|
| Keycloak base URL | `https://keycloak.example.com` | Identity administrator |
| Realm and issuer | `openshell` and `KEYCLOAK_ISSUER` | Identity administrator |
| API client IDs | `openshell-api-a` and `openshell-api-b` | Identity administrator |
| Dashboard client IDs | `openshell-dashboard-a` and `openshell-dashboard-b` | Identity administrator |
| Dashboard client secrets | Stored only in Kubernetes Secrets | Identity administrator |
| CLI client IDs | `openshell-cli-a` and `openshell-cli-b` | Identity administrator |
| Keycloak CA | Public trust or `keycloak-ca` ConfigMap | Identity and platform teams |
| Four public DNS names | `gateway-a`, `dashboard-a`, `gateway-b`, `dashboard-b` | Platform engineer |
| Approved image versions | Pinned gateway, supervisor, dashboard, proxy | Platform engineer |

The image and chart versions this repository uses are in the [README](../README.md#images-used-in-this-repository). The cluster requirements are the same as for [installing OpenShell](01-install.md#prerequisites).

## Step by step setup

Steps 1 to 8 are done in Keycloak, steps 9 to 13 on the cluster, and steps 14 to 16 with the `openshell` CLI and a browser.

### Step 1: Prepare the Keycloak realm

1. Create or select a realm named `openshell`. Do not configure application clients in the `master` realm.
2. Publish the realm through HTTPS at `https://keycloak.example.com/realms/openshell` and record that exact issuer URL. The gateway only accepts an HTTPS issuer.
3. Configure production session, access-token, refresh-token, password, brute-force, MFA, and event-retention policies before onboarding users.
4. If Keycloak uses a private CA, export the CA certificate that OpenShell gateways, dashboard proxies, and laptop clients must trust.
5. Confirm that the realm discovery document and JWKS endpoints are reachable from both OpenShift namespaces and from user laptops.

```shell
curl -fsS https://keycloak.example.com/realms/openshell/.well-known/openid-configuration

KEYCLOAK_ISSUER=https://keycloak.example.com/realms/openshell
```

### Step 2: Create groups and example users

1. Create top-level groups named `users-a`, `administrators-a`, `users-b`, and `administrators-b`.
2. Create or federate Mary and add her only to `users-a`.
3. Create or federate Cameron and add him only to `users-a`.
4. Create or federate Joe and add him only to `users-b`.
5. Add administrators only to the matching administrators group. Avoid direct role grants to individual users unless an exception is documented.
6. Require verified email and the organization's MFA or WebAuthn enrollment policy where appropriate.

### Step 3: Create API resource clients and roles

1. Create an OpenID Connect client with Client ID `openshell-api-a`.
2. Disable Standard Flow, Direct Access Grants, Implicit Flow, Device Authorization Grant, and service-account use. The client represents a resource server and is not an interactive login client.
3. Under the client's **Roles** tab, create client roles `users-a` and `administrators-a`.
4. Create `openshell-api-b` with the same flow restrictions and client roles `users-b` and `administrators-b`.

The gateway never uses a Keycloak client secret. Its API client defines the `resource_access` role namespace. Keycloak adds that client ID to `aud` automatically when a permitted role from the API client is present in the access token.

### Step 4: Assign API client roles to groups

1. Open group `users-a`, choose **Role mapping**, filter by client `openshell-api-a`, and assign role `users-a`.
2. Assign `openshell-api-a` role `administrators-a` to group `administrators-a`.
3. Assign `openshell-api-b` role `users-b` to group `users-b` and `administrators-b` to group `administrators-b`.
4. Do not grant A client roles to B groups or B client roles to A groups.

| Group | Client | Client role |
|---|---|---|
| `users-a` | `openshell-api-a` | `users-a` |
| `administrators-a` | `openshell-api-a` | `administrators-a` |
| `users-b` | `openshell-api-b` | `users-b` |
| `administrators-b` | `openshell-api-b` | `administrators-b` |

### Step 5: Configure automatic API audiences

These settings apply to the Dashboard and CLI clients that Steps 6 and 7 create. Read this step for the model and apply it there.

1. Keep the built-in `roles` client scope linked to each Dashboard and CLI client. It contains the client-role and Audience Resolve protocol mappers.
2. Turn **Full Scope Allowed** off on each Dashboard and CLI client.
3. For Dashboard A and CLI A, use each client's **Scope** tab (**Client scopes**, the `<client-id>-dedicated` scope, **Scope**) to permit only `openshell-api-a` roles `users-a` and `administrators-a`.
4. When either A role is present in the access token, Audience Resolve adds `openshell-api-a` to `aud`. Do not create a custom API access scope or hardcoded API audience mapper.
5. Repeat the explicit role scope mappings for Dashboard B and CLI B with only `users-b` and `administrators-b` from `openshell-api-b`.

| | Namespace A mapping | Namespace B mapping |
|---|---|---|
| API client | `openshell-api-a` | `openshell-api-b` |
| Permitted client roles | `users-a`, `administrators-a` | `users-b`, `administrators-b` |
| Clients that carry them | `openshell-dashboard-a`, `openshell-cli-a` | `openshell-dashboard-b`, `openshell-cli-b` |
| How `aud` is set | Built-in `roles` client scope | Built-in `roles` client scope |

### Step 6: Create the dashboard clients

1. Create OpenID Connect client `openshell-dashboard-a` with **Client authentication** enabled and Standard Flow enabled.
2. Disable Direct Access Grants, Implicit Flow, Device Authorization Grant, and service accounts.
3. Set **Valid Redirect URIs** to `https://dashboard-a.example.com/oauth2/callback` and **Web Origins** to `https://dashboard-a.example.com`.
4. Set the PKCE method to `S256` and turn **Full Scope Allowed** off.
5. Keep the built-in `roles` client scope linked and use the dashboard client's **Scope** tab to permit only the A API client roles.
6. Add an audience mapper in the dashboard client's dedicated scope for `openshell-dashboard-a`, adding it to ID and access tokens so oauth2-proxy can validate its own audience.
7. Copy the dashboard client secret into an approved secret manager. Do not place it in source control.
8. Repeat for `openshell-dashboard-b`, `dashboard-b.example.com`, and the B API client-role scope mappings.

The dashboard access token may contain both the dashboard client and API client in `aud`. Gateway A only requires that `openshell-api-a` be present. Gateway B applies the corresponding B check.

> [!NOTE]
> Item 6 follows the [oauth2-proxy Keycloak OIDC instructions](https://oauth2-proxy.github.io/oauth2-proxy/configuration/providers/keycloak_oidc). The scripted path does not create this mapper and its checks pass with oauth2-proxy v7.15.5, so treat it as defensive rather than required with that version.

### Step 7: Create the CLI clients

1. Create OpenID Connect client `openshell-cli-a` with **Client authentication** disabled and Standard Flow enabled.
2. Enable OAuth 2.0 Device Authorization Grant and require `S256` PKCE. Disable Direct Access Grants and Implicit Flow.
3. Register `http://127.0.0.1/*` as the native loopback redirect pattern. The CLI listens on a random port and uses `http://127.0.0.1:<port>/callback`.
4. Turn **Full Scope Allowed** off, keep the built-in `roles` client scope linked, and use the CLI client's **Scope** tab to permit only the A API client roles.
5. Do not create or distribute a secret for the public CLI client.
6. Repeat for `openshell-cli-b` with only the B API client-role scope mappings.

### Step 8: Verify tokens before deploying OpenShell

1. Use each client's **Client scopes**, **Evaluate** view with Mary, Cameron, or Joe selected.
2. For Dashboard A and CLI A, evaluate the access token and verify `aud` contains `openshell-api-a` without requesting a custom API scope.
3. Verify Mary and Cameron receive `users-a` below `resource_access.openshell-api-a.roles` and receive no B client role.
4. Verify Joe receives `users-b` and `openshell-api-b` only through the B clients.
5. Verify administrator groups produce only their matching administrators role.

```json
{
  "iss": "https://keycloak.example.com/realms/openshell",
  "aud": ["openshell-dashboard-a", "openshell-api-a"],
  "preferred_username": "cameron",
  "resource_access": {
    "openshell-api-a": { "roles": ["users-a"] }
  }
}
```

### Step 9: Prepare OpenShift ingress and certificates

1. Create namespaces `namespace-a` and `namespace-b`.
2. Reserve four external hostnames for `gateway-a`, `dashboard-a`, `gateway-b`, and `dashboard-b`. Issue trusted certificates for them, or use the certificate the chart generates for each gateway (Step 10) and the cluster's default certificate for the dashboard Routes.
3. Expose each gateway through an HTTPS and HTTP/2 capable path such as a TLS passthrough `Route`, or OpenShift Gateway API with `GRPCRoute` and `BackendTLSPolicy`.
4. Expose each dashboard through a separate HTTPS `Route` that targets only oauth2-proxy port 4180.
5. Allow gateway pods and dashboard proxy pods to reach the Keycloak issuer over HTTPS for discovery, JWKS, authorization, and token requests.
6. If Keycloak uses a private CA, create `keycloak-ca` ConfigMaps in both namespaces from the approved CA certificate.

```shell
oc create namespace namespace-a
oc create namespace namespace-b

oc -n namespace-a create configmap keycloak-ca --from-file=ca.crt=/path/to/keycloak-ca.crt
oc -n namespace-b create configmap keycloak-ca --from-file=ca.crt=/path/to/keycloak-ca.crt
```

Omit the `keycloak-ca` ConfigMaps and `caConfigMapName` values when the issuer certificate chains to a CA already trusted by the images.

> [!NOTE]
> The chart gives this file to the gateway as its only set of trust roots, not as an addition to the system ones. If the gateway must also trust in-cluster services, put their CA in the same `ca.crt`; `scripts/user-auth/03-gateway-oidc.sh` appends the OpenShift service CA for this reason.

### Step 10: Install Gateway A

Install the chart as in [Install OpenShell with Helm](01-install.md#install-openshell-with-helm), which sets the chart version, the Red Hat build images and the database option, with two differences: the release goes into `namespace-a`, and the `server.auth.allowUnauthenticatedUsers=true` flag is replaced by the OIDC values below.

Create `values-namespace-a.yaml` and adapt the issuer and the optional Keycloak CA setting:

```yaml
server:
  auth:
    allowUnauthenticatedUsers: false
  oidc:
    issuer: https://keycloak.example.com/realms/openshell
    audience: openshell-api-a
    rolesClaim: resource_access.openshell-api-a.roles
    adminRole: administrators-a
    userRole: users-a
    caConfigMapName: keycloak-ca
```

Install with the SQLite option and expose the gateway through a passthrough `Route`, which is the path both validated runs used:

```shell
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "${OPENSHELL_CHART_VERSION}" \
  --namespace namespace-a \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null \
  --set "pkiInitJob.serverDnsNames[0]=gateway-a.example.com" \
  --set global.image.registry=quay.io/opendatahub \
  --set global.image.tag="${OPENSHELL_IMAGE_TAG}" \
  --set gateway.image.repository=odh-openshell-gateway \
  --set supervisor.image.repository=odh-openshell-supervisor \
  --set sandboxRuntime.image.repository=odh-openshell-sandbox \
  --values values-namespace-a.yaml

oc -n namespace-a create route passthrough openshell \
  --service=openshell --port=8080 --hostname=gateway-a.example.com
```

With a passthrough `Route` the gateway serves the certificate the chart generates, and `pkiInitJob.serverDnsNames` puts the external hostname in it. That certificate is signed by a CA private to the namespace, so CLI users need the CA file (Step 14). Leave `server.tls.enableMtls` at its default: once OIDC is on, the gateway accepts bearer-only clients and no longer signs anyone in from a client certificate.

**Alternative: Gateway API.** On OpenShift 4.22 or later you can terminate TLS at an OpenShift Gateway and re-encrypt to the gateway pod instead of using a passthrough `Route`. Add these values, adapt the ingress names, and skip the `oc create route` command. This variant was not part of the validated runs.

```yaml
server:
  tls:
    enableMtls: false

grpcRoute:
  enabled: true
  gateway:
    name: openshell-gateway
    namespace: openshift-ingress
  hostnames:
    - gateway-a.example.com
  backendTLSPolicy:
    enabled: true
```

Keep server TLS enabled. Disabling client-certificate authentication allows OIDC callers to connect without a user certificate; it does not disable HTTPS between ingress and the gateway.

Verify that the gateway pod is `Running`. A pod that crash-loops with `OIDC initialization failed` cannot reach or verify the issuer: check the issuer URL, the `keycloak-ca` ConfigMap, and egress from the namespace.

```shell
oc -n namespace-a get pods
```

### Step 11: Install Gateway B

Copy the Gateway A values and change only the namespace-specific identity and hostname values:

```yaml
server:
  oidc:
    audience: openshell-api-b
    rolesClaim: resource_access.openshell-api-b.roles
    adminRole: administrators-b
    userRole: users-b
```

Run the same `helm upgrade --install` and `oc create route` commands with `--namespace namespace-b`, `values-namespace-b.yaml`, and `gateway-b.example.com` as the hostname in both. With the Gateway API alternative, set the hostname in the values instead:

```yaml
grpcRoute:
  hostnames:
    - gateway-b.example.com
```

### Step 12: Deploy Dashboard A and oauth2-proxy

The dashboard has no Helm chart yet ([RHOAIENG-98850](https://redhat.atlassian.net/browse/RHOAIENG-98850)), so this step applies one manifest: a pod with oauth2-proxy and the dashboard BFF, a `Service` and `Route` for the proxy port only, and a `NetworkPolicy`.

Create the secret without placing client credentials or cookie keys in source control. The cookie secret must be 16, 24 or 32 bytes long:

```shell
oc -n namespace-a create secret generic dashboard-a-oidc \
  --from-literal=client-id='openshell-dashboard-a' \
  --from-literal=client-secret='<DASHBOARD_A_CLIENT_SECRET>' \
  --from-literal=cookie-secret="$(openssl rand -hex 16)"
```

The dashboard BFF is configured with these environment variables:

```
AUTH_DISABLED=false
AUTH_TOKEN_HEADER=x-forwarded-access-token
AUTH_USER_HEADER=x-forwarded-user
ADMIN_ROLE=administrators-a
LOGOUT_URL=/oauth2/sign_out
LISTEN_ADDRESS=127.0.0.1
PORT=8080
OPENSHELL_GATEWAY_URL=grpcs://openshell.namespace-a.svc.cluster.local:8080
GATEWAY_CA_CERT=/etc/openshell-gateway/ca.crt
```

Run oauth2-proxy as a sidecar with settings equivalent to:

```
--provider=keycloak-oidc
--oidc-issuer-url=https://keycloak.example.com/realms/openshell
--client-id=openshell-dashboard-a
--client-secret=<from Kubernetes Secret>
--redirect-url=https://dashboard-a.example.com/oauth2/callback
--scope="openid profile email"
--upstream=http://127.0.0.1:8080/
--http-address=0.0.0.0:4180
--code-challenge-method=S256
--allowed-role=openshell-api-a:users-a
--allowed-role=openshell-api-a:administrators-a
--pass-access-token=true
--pass-user-headers=true
--reverse-proxy=true
--skip-provider-button=true
--api-route=^/api/
--cookie-secure=true
--cookie-samesite=lax
--cookie-name=_openshell_a
--cookie-refresh=4m
--email-domain=*
```

Three of these are easy to get wrong:

- `--pass-access-token=true` forwards the **access** token in `X-Forwarded-Access-Token`. The gateway rejects an ID token, because its audience is the dashboard client, not the API client.
- `--cookie-refresh` must be shorter than the realm's access-token lifespan (5 minutes by default in Keycloak). Without it the proxy never refreshes the token and every dashboard call returns 401 once the first token expires.
- `--api-route=^/api/` makes an expired session answer the dashboard's API calls with 401 instead of a redirect to the login page.

Apply the manifest. Set the variables first. The dashboard image is the one in the README's [images table](../README.md#images-used-in-this-repository), and oauth2-proxy v7.15.5 is the version listed under [What was validated](../README.md#what-was-validated-and-its-support-status).

```shell
NS=namespace-a
ISSUER=https://keycloak.example.com/realms/openshell
API_CLIENT=openshell-api-a
DASHBOARD_HOST=dashboard-a.example.com
OIDC_SECRET=dashboard-a-oidc
ADMIN_ROLE=administrators-a
USER_ROLE=users-a
COOKIE_NAME=_openshell_a
DASHBOARD_IMAGE=quay.io/gkrumbach07/openshell-dashboard:1.2.0
OAUTH2_PROXY_IMAGE=quay.io/oauth2-proxy/oauth2-proxy:v7.15.5

oc -n "${NS}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openshell-dashboard
  labels: {app: openshell-dashboard}
spec:
  replicas: 1
  selector: {matchLabels: {app: openshell-dashboard}}
  template:
    metadata: {labels: {app: openshell-dashboard}}
    spec:
      containers:
        - name: oauth2-proxy
          image: ${OAUTH2_PROXY_IMAGE}
          args:
            - --provider=keycloak-oidc
            - --oidc-issuer-url=${ISSUER}
            - --redirect-url=https://${DASHBOARD_HOST}/oauth2/callback
            - --scope=openid profile email
            - --upstream=http://127.0.0.1:8080/
            - --http-address=0.0.0.0:4180
            - --code-challenge-method=S256
            - --allowed-role=${API_CLIENT}:${USER_ROLE}
            - --allowed-role=${API_CLIENT}:${ADMIN_ROLE}
            - --pass-access-token=true
            - --pass-user-headers=true
            - --reverse-proxy=true
            - --skip-provider-button=true
            - --api-route=^/api/
            - --cookie-secure=true
            - --cookie-samesite=lax
            - --cookie-name=${COOKIE_NAME}
            - --cookie-refresh=4m
            - --email-domain=*
          env:
            - name: OAUTH2_PROXY_CLIENT_ID
              valueFrom: {secretKeyRef: {name: ${OIDC_SECRET}, key: client-id}}
            - name: OAUTH2_PROXY_CLIENT_SECRET
              valueFrom: {secretKeyRef: {name: ${OIDC_SECRET}, key: client-secret}}
            - name: OAUTH2_PROXY_COOKIE_SECRET
              valueFrom: {secretKeyRef: {name: ${OIDC_SECRET}, key: cookie-secret}}
          ports: [{containerPort: 4180, name: http}]
          readinessProbe: {httpGet: {path: /ping, port: 4180}, periodSeconds: 5}
          securityContext: &restricted
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            runAsNonRoot: true
            seccompProfile: {type: RuntimeDefault}
        - name: dashboard
          image: ${DASHBOARD_IMAGE}
          env:
            - {name: AUTH_DISABLED, value: "false"}
            - {name: AUTH_TOKEN_HEADER, value: x-forwarded-access-token}
            - {name: AUTH_USER_HEADER, value: x-forwarded-user}
            - {name: ADMIN_ROLE, value: "${ADMIN_ROLE}"}
            - {name: LOGOUT_URL, value: /oauth2/sign_out}
            - {name: LISTEN_ADDRESS, value: "127.0.0.1"}
            - {name: PORT, value: "8080"}
            - {name: OPENSHELL_GATEWAY_URL, value: "grpcs://openshell.${NS}.svc.cluster.local:8080"}
            - {name: GATEWAY_CA_CERT, value: /etc/openshell-gateway/ca.crt}
          volumeMounts: [{name: gateway-ca, mountPath: /etc/openshell-gateway, readOnly: true}]
          securityContext: *restricted
      volumes:
        - name: gateway-ca
          secret: {secretName: openshell-client-tls, items: [{key: ca.crt, path: ca.crt}]}
---
apiVersion: v1
kind: Service
metadata: {name: openshell-dashboard}
spec:
  selector: {app: openshell-dashboard}
  ports: [{name: http, port: 4180, targetPort: 4180}]
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: openshell-dashboard}
spec:
  host: ${DASHBOARD_HOST}
  to: {kind: Service, name: openshell-dashboard}
  port: {targetPort: http}
  tls: {termination: edge, insecureEdgeTerminationPolicy: Redirect}
---
# Only the OpenShift router may open connections to the dashboard pod (the proxy port).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: openshell-dashboard}
spec:
  podSelector: {matchLabels: {app: openshell-dashboard}}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {policy-group.network.openshift.io/ingress: ""}
      ports: [{port: 4180, protocol: TCP}]
EOF
oc -n "${NS}" rollout status deploy/openshell-dashboard --timeout=180s
```

What the manifest enforces:

- Only proxy port 4180 is exposed through the `Service` and `Route`.
- The BFF binds to pod loopback so clients cannot inject trusted authentication headers directly.
- The gateway CA is mounted read-only, and only the `ca.crt` key of the chart's TLS secret is projected: no gateway client private key reaches the pod, so the BFF can act only with the signed-in user's token.
- The `NetworkPolicy` lets no other pod reach the dashboard pod. If the cluster's router runs on the host network, add a second `namespaceSelector` for `policy-group.network.openshift.io/host-network: ""`.

oauth2-proxy logs a warning that `--reverse-proxy` is on without `--trusted-proxy-ip`. The `NetworkPolicy` already limits connections to the router. Because `--redirect-url` is set explicitly, the proxy also works with `--reverse-proxy=false`, which ignores `X-Forwarded-*` headers altogether; one of the two validated deployments ran that way.

If Keycloak uses a private CA, oauth2-proxy must trust it as well: mount the `keycloak-ca` ConfigMap into the proxy container and add `--provider-ca-file=/etc/keycloak-ca/ca.crt` and `--use-system-trust-store=true`.

### Step 13: Deploy Dashboard B

Repeat Step 12 with the following replacements. In the variable block they are `NS`, `API_CLIENT`, `DASHBOARD_HOST`, `OIDC_SECRET`, `ADMIN_ROLE`, `USER_ROLE` and `COOKIE_NAME`; `ISSUER` and the images stay the same.

| Dashboard A setting | Dashboard B setting |
|---|---|
| `namespace-a` | `namespace-b` |
| `openshell-dashboard-a` | `openshell-dashboard-b` |
| `dashboard-a-oidc` | `dashboard-b-oidc` |
| `dashboard-a.example.com` | `dashboard-b.example.com` |
| A API client-role scope mappings | B API client-role scope mappings |
| `openshell-api-a:users-a` | `openshell-api-b:users-b` |
| `openshell-api-a:administrators-a` | `openshell-api-b:administrators-b` |
| `ADMIN_ROLE=administrators-a` | `ADMIN_ROLE=administrators-b` |
| `_openshell_a` | `_openshell_b` |

### Step 14: Configure the laptop CLI

Register both gateways. The CLI automatically adds `openid`; request `profile` and `email`. Keycloak derives the API audience from the permitted API client roles:

```shell
openshell gateway add https://gateway-a.example.com \
  --name namespace-a \
  --oidc-issuer https://keycloak.example.com/realms/openshell \
  --oidc-client-id openshell-cli-a \
  --oidc-audience openshell-api-a \
  --oidc-scopes "profile email"

openshell gateway add https://gateway-b.example.com \
  --name namespace-b \
  --oidc-issuer https://keycloak.example.com/realms/openshell \
  --oidc-client-id openshell-cli-b \
  --oidc-audience openshell-api-b \
  --oidc-scopes "profile email"
```

If the gateway serves the chart-generated certificate (the passthrough `Route` in Step 10), the CLI needs that gateway's CA before `gateway add`. An administrator extracts it once and sends the file to users; it is a public certificate, not a secret:

```shell
oc -n namespace-a get secret openshell-client-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > gateway-a-ca.crt

# on the user's machine
mkdir -p ~/.config/openshell/gateways/namespace-a/mtls
cp gateway-a-ca.crt ~/.config/openshell/gateways/namespace-a/mtls/ca.crt
```

The browser login uses Authorization Code with `S256` PKCE and a random `127.0.0.1` callback. To use Device Authorization Grant on a machine without a browser, set `OPENSHELL_NO_BROWSER=1` before `gateway add` or `gateway login`.

```shell
OPENSHELL_NO_BROWSER=1 openshell gateway login namespace-a
```

Keycloak must advertise `device_authorization_endpoint` and the selected CLI client must have Device Authorization Grant enabled.

### Step 15: Add workspace members

Being in a Keycloak group is not enough. The gateway role in the token lets a user sign in, but OpenShell applies a second check: a standard user must have a membership record in each workspace they use. Until it exists, the user can sign in and then every call fails with `not a member of workspace 'default'`. Keycloak groups do not become workspace memberships on their own ([NVIDIA/OpenShell#4286](https://github.com/NVIDIA/OpenShell/issues/4286)).

A member of `administrators-a` adds each standard user, identified by the `sub` claim of their token. With Keycloak's default subject mapping that is the user's ID in the Keycloak console (**Users**, the user, **ID**); `openshell whoami --output json`, run by the user, prints the same value and works before any membership exists.

```shell
openshell --gateway namespace-a workspace member add \
  --workspace default \
  --subject '<mary-subject>' \
  --role user

openshell --gateway namespace-a workspace member add \
  --workspace default \
  --subject '<cameron-subject>' \
  --role user

openshell --gateway namespace-a workspace member list --workspace default
```

Do the same for Joe on `namespace-b` as a member of `administrators-b`. Members of the administrators groups need no membership: the gateway admin role bypasses the check.

[Workspaces and membership](02-user-auth-workspaces.md) covers named workspaces, delegated workspace administrators, looking subjects up through the Keycloak Admin REST API, offboarding, and automation.

### Step 16: Validate expected and denied access

1. Sign in to Dashboard A as Mary. Confirm that the UI loads and reports a standard OpenShell user.
2. Repeat Dashboard A and Gateway A tests as Cameron. Confirm that Cameron has a distinct subject but the same `users-a` authorization as Mary.
3. Run `openshell whoami --output json` against `namespace-a` and verify the Keycloak issuer, `openshell-api-a` audience, and `users-a` role.
4. As Mary, create and delete a sandbox in her workspace.
5. Attempt Dashboard B and Gateway B as Mary and Cameron. Confirm denial at the proxy role check or the gateway B audience and role checks.
6. Repeat the positive tests for Joe against `namespace-b` and negative tests against `namespace-a`.
7. Test one `administrators-a` user and one `administrators-b` user. Verify administrative methods succeed only in the matching namespace, and that the dashboard shows the administrator role.
8. Verify that direct network access to the BFF port is impossible outside its pod and that clients can reach only oauth2-proxy.
9. Verify token expiry and refresh, dashboard logout, CLI logout, browser identity switching, and device-code login.

#### Expected token claims

| Test | Expected `aud` | Expected client role | Gateway result |
|---|---|---|---|
| Mary to Gateway A | `openshell-api-a` | `users-a` | Allowed as user |
| Cameron to Gateway A | `openshell-api-a` | `users-a` | Allowed as user |
| Mary or Cameron to B | A audience or no B role | no `users-b` | Denied |
| Joe to Gateway B | `openshell-api-b` | `users-b` | Allowed as user |
| Joe to Gateway A | B audience or no A role | no `users-a` | Denied |

Inspect tokens only with approved local tooling or Keycloak's Evaluate view. Do not paste production access tokens into public token-inspection websites.

## Operational and security controls

- Run Keycloak with supported replicas, a production database, tested backups, monitored health, and a documented recovery procedure.
- Use one realm issuer URL consistently. Do not expose the `master` realm to application users.
- Keep A and B clients, role scope mappings, and group role mappings separate. Retain the built-in `roles` client scope so Audience Resolve can derive `aud` from the permitted API client roles.
- Keep Full Scope Allowed off on dashboard and CLI clients. Disable unused implicit and direct-access flows.
- Use exact dashboard redirect URIs and the narrowest native loopback redirect pattern supported by the deployed Keycloak version.
- Rotate dashboard client secrets and cookie secrets on a documented schedule and store them only in Kubernetes Secrets or an approved external secret manager.
- Plan realm signing-key rotation so gateways can refresh JWKS before old verification keys are retired.
- Apply MFA, brute-force protection, session limits, audit events, and administrator separation appropriate for the organization.
- Pin OpenShell, supervisor, dashboard, oauth2-proxy, and Helm chart versions and test their compatibility together.
- Retain HTTPS between ingress and gateway. Disabling user mTLS must not disable server TLS.
- Treat provider credentials and sandbox records as gateway-wide resources. OIDC subject identity does not create per-user record ownership.
- Remove a user's workspace memberships when you remove their Keycloak group. The membership is checked on every call; the role in a token that was already issued lasts until that token expires.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Dashboard login redirects repeatedly | Redirect URI, proxy cookie, issuer, or forwarded-host mismatch | Match the Keycloak redirect exactly and verify reverse-proxy headers |
| Dashboard login succeeds but API returns 401 | Proxy passed an ID token or the expected API client roles are absent from the access token | Use `--pass-access-token` and verify the matching `resource_access` roles and API audience |
| Dashboard works, then every API call returns 401 after a few minutes | The proxy is not refreshing the access token | Set `--cookie-refresh` below the realm's access-token lifespan |
| Signed in, but every call says `not a member of workspace` | The user has the gateway role but no workspace membership | Add the membership ([Step 15](#step-15-add-workspace-members)) |
| Gateway reports invalid audience | Audience Resolve did not see a permitted API client role | Verify the `roles` client scope, role scope mappings, `resource_access` entry, and `aud` claim |
| Authenticated user has no OpenShell role | Group lacks API client-role mapping or role scope mapping filters it | Check group Role mapping, Full Scope Allowed, and `resource_access` claim |
| Mary or Cameron can open Dashboard B | B proxy lacks allowed-role restriction or B role was granted accidentally | Check proxy flags and remove A groups from B client roles |
| CLI reports redirect URI mismatch | The public client does not accept the random `127.0.0.1` callback | Register the native loopback pattern and test the exact released CLI |
| CLI device login is unavailable | Device Authorization Grant or discovery endpoint is disabled | Enable the grant on the CLI client and inspect discovery metadata |
| CLI reports a certificate error | The gateway serves the chart-generated certificate and the CLI does not have its CA | Install the gateway CA for that gateway name (Step 14) |
| CLI reports `missing authorization header` | The CLI entry uses the mTLS client bundle, which no longer signs anyone in once OIDC is on | Register an OIDC entry with `gateway add --oidc-issuer ...` (Step 14) |
| Gateway cannot initialize OIDC | Issuer, CA trust, cluster egress, or discovery failure | Check the exact realm issuer, `keycloak-ca` mount, NetworkPolicy, and gateway logs |
| Browser shows a client certificate error | Gateway still requires user mTLS behind a TLS-terminating ingress | Set `server.tls.enableMtls` false while keeping HTTPS enabled |
| Dashboard can be bypassed with forged headers | BFF is reachable without oauth2-proxy | Bind BFF to loopback and expose only port 4180 |

## Production readiness checklist

- [ ] Keycloak production availability, database backups, monitoring, and recovery have named owners.
- [ ] The `openshell` realm issuer is HTTPS and reachable from gateways, proxies, and laptops.
- [ ] API A and API B use different client IDs and access-token audiences.
- [ ] A groups have only A client roles; B groups have only B client roles.
- [ ] Dashboard and CLI clients have Full Scope Allowed off, permit only their matching API client roles, and retain the built-in `roles` client scope.
- [ ] Both gateways reject unauthenticated calls and validate `resource_access` client roles.
- [ ] Gateway TLS remains enabled and OpenShift ingress supports HTTP/2 and gRPC.
- [ ] Each dashboard Route exposes only oauth2-proxy and the BFF binds to loopback.
- [ ] Every standard user has a workspace membership for their own subject, and offboarding removes it.
- [ ] Browser PKCE, CLI PKCE, device login, refresh, logout, and signing-key rollover have been tested.
- [ ] Positive and negative tests pass for Mary, Cameron, Joe, and both administrator roles.
- [ ] Secrets, certificates, image pins, token lifetimes, audit retention, and backup schedules are documented.

## References

- [OpenShell access control](https://docs.nvidia.com/openshell/latest/kubernetes/access-control)
- [OpenShell OpenShift deployment](https://docs.nvidia.com/openshell/latest/kubernetes/openshift)
- [OpenShell gateway authentication](https://docs.nvidia.com/openshell/latest/how-it-works/gateways/authentication)
- [OpenShell workspaces](https://docs.nvidia.com/openshell/latest/how-it-works/workspaces)
- [OpenShell Dashboard README](https://github.com/Gkrumbach07/openshell-dashboard#auth)
- [OpenShell Dashboard authentication decision](https://github.com/Gkrumbach07/openshell-dashboard/blob/main/docs/adrs/0002-auth-relay-only-bff.md)
- [Keycloak Server Administration Guide](https://www.keycloak.org/docs/latest/server_admin/)
- [Keycloak audience support: Audience Resolve](https://www.keycloak.org/docs/latest/server_admin/#_audience_resolve)
- [Keycloak securing applications guides](https://www.keycloak.org/guides#securing-apps)
- [oauth2-proxy Keycloak OIDC provider](https://oauth2-proxy.github.io/oauth2-proxy/configuration/providers/keycloak_oidc)
- [oauth2-proxy configuration overview](https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview)
