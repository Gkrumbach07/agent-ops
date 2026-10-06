# User authentication: log in to OpenShell and its dashboard

> **Midstream Documentation**
>
> Validated end to end on OpenShift 4.20.27 with the `v0.1.2-rhaiv.5` images, Red Hat build of
> Keycloak 26.6.7 (dev mode), oauth2-proxy v7.15.5 and dashboard 1.2.0 on 2026-10-06. Do not use in production.

The getting-started guide runs the gateway with `allowUnauthenticatedUsers=true`: every caller is a trusted local developer, and the dashboard treats every visitor as a platform admin. This guide turns on real logins. People sign in with Keycloak, the gateway checks who they are and what they may do, and the dashboard sits behind a login page.

It covers people. Sandbox identity (an agent calling an API as the user) is the [token-exchange guide](spiffe-token-exchange-keycloak.md); both use the same Keycloak realm and issuer.

## What gets set up

```
                    ┌──────────── Keycloak (https://keycloak-<ns>.<apps domain>/realms/openshell) ────────────┐
                    │ roles: openshell-admin, openshell-user      audience every client adds: openshell-gateway │
                    └──────▲───────────────────────▲──────────────────────────▲─────────────────────────────────┘
                           │ PKCE / device login   │ login (confidential)     │ client credentials
                    openshell CLI           oauth2-proxy ─▶ dashboard    automation (CI, admin scripts)
                           │                       │  (127.0.0.1 only)        │
                           └───────────────────────┴──────────┬───────────────┘
                                                              ▼  Bearer token
                                    OpenShell gateway: checks issuer, audience, role, workspace membership
```

| Piece | Why |
|---|---|
| Keycloak on an HTTPS Route | The gateway only accepts an HTTPS issuer, and the issuer in a token must be the URL the browser, the CLI and the gateway all use |
| One audience, `openshell-gateway` | The gateway accepts a single audience, so every client adds it to its access tokens |
| Roles `openshell-admin`, `openshell-user` | The gateway reads them from `realm_access.roles`. Admins manage everything and bypass workspace membership |
| Clients `openshell-cli`, `openshell-dashboard`, `openshell-automation` | A person at a terminal, a person in a browser, and a script. Each logs in its own way and gets a token the gateway accepts |
| oauth2-proxy in front of the dashboard | The dashboard has no login of its own. The proxy signs the user in, keeps the session, refreshes the token, and passes it on. The dashboard only listens on loopback, so the proxy is the only way in |

## Run it

After `make token-exchange` (or at least `make deploy` plus Keycloak):

```shell
make user-auth           # steps 1 to 4, then the checks
make verify-user-auth    # the checks only
```

| Step | Script | What it does |
|---|---|---|
| 1 | `scripts/user-auth/01-keycloak-route.sh` | Route for Keycloak; restarts Keycloak with the Route as its issuer and re-creates the realm (dev mode keeps it in memory) |
| 2 | `02-configure-realm.sh` | Roles, the gateway audience, the three clients, a `platform-admin` user. Secrets: `keycloak-platform-admin`, `openshell-dashboard-oidc`, `openshell-automation-oidc` |
| 3 | `03-gateway-oidc.sh` | Gateway: `server.oidc.*`, anonymous access off. Re-registers the interceptor. Adds the CLI gateway entry `openshift-oidc` |
| 4 | `04-dashboard-login.sh` | Dashboard with an oauth2-proxy sidecar and a Route |

Then open `https://openshell-dashboard-<ns>.<apps domain>` and sign in as `alice` (password in Secret `keycloak-demo-user`) or `platform-admin`.

## What the checks prove

| Check | Result |
|---|---|
| A caller with no token | Refused (401) |
| Alice signs in | Identified, role `openshell-user` |
| Alice before she is a workspace member | Denied in workspace `default` (403) |
| A platform admin adds her | Alice can list, create and delete sandboxes |
| Dashboard without a session | Sent to the Keycloak login page; API calls refused (401) |
| Dashboard after login | Acts as Alice, with her token |

## Use the CLI

People log in through the browser (`openshell gateway login`), or with a device code on a headless machine (`OPENSHELL_NO_BROWSER=1`):

```shell
openshell gateway add https://<gateway route> --name team \
  --oidc-issuer https://keycloak-<ns>.<apps domain>/realms/openshell \
  --oidc-client-id openshell-cli --oidc-audience openshell-gateway
openshell whoami
```

Scripts use the automation client: set `OPENSHELL_GATEWAY=openshift-oidc` and `OPENSHELL_OIDC_CLIENT_SECRET` from Secret `openshell-automation-oidc`. With OIDC on, the token-exchange demo (`make try-it`) needs the same two variables.

> [!IMPORTANT]
> Once OIDC is on, the Helm-generated mTLS client bundle no longer signs anyone in
> (`missing authorization header`). It only protects the connection. The `openshift`
> CLI entry from `make deploy` stops working for protected commands; use an OIDC entry.

## Known gaps

| Gap | Effect | Status |
|---|---|---|
| Workspace membership is per user | A new user can sign in but is denied everywhere until an admin runs `openshell workspace member add --subject <id>`. The subject is Keycloak's user ID, not the username. There is no group-to-workspace mapping | Upstream gap; needs an RFE |
| Keycloak runs in dev mode | Realm and users are lost on restart | Use the RHBK operator with a database for anything shared |
| oauth2-proxy is a community image | `quay.io/oauth2-proxy/oauth2-proxy` | Product equivalent to decide (for example the proxy RHOAI already ships) |
| Dashboard image is a personal build | `quay.io/gkrumbach07/openshell-dashboard:1.2.0` | ODH build in progress (`odh-openshell-dashboard`) |
| Other identity providers | Only Keycloak was tested | Entra ID and Okta need the same audience, roles claim and redirect settings; untested |
| Direct access grants on `openshell-cli` | Lets scripts get a user token with a password; used by the checks | Turn off outside evaluation |
