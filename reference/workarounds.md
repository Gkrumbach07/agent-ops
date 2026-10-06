# Workarounds in this repository, and what removes them

The setup guides work today, but parts of them exist only because a product
piece is missing. This page lists each workaround, what would make it
unnecessary, and where that is tracked. "Issue needed" means we found no
existing issue; filing one is the next step.

Status as of 2026-10-06.

## What any version of this setup needs

Some admin work is permanent, and no fix removes it:

- **Install OpenShell.** It needs cluster-admin. Today this is `make deploy`; later it is a chart or operator.
- **Connect the gateway to your identity provider, once.** The gateway must trust an issuer, and the provider must know the application (roles, dashboard redirect, CLI client). Each API that agents call must be registered once.
- **Decide who gets access.** In the target setup, this is group membership in your identity provider.

Everything below is extra work on top of those three.

## OpenShell upstream

| Workaround here | Why it exists | What removes it | Tracking |
|---|---|---|---|
| `make grant`, `make revoke`, `make sync-members` copy Keycloak groups into workspace membership | The gateway authorizes workspaces only from its own member list and cannot read groups from the token. Without the copy, users get "not a member of workspace" | Gateway maps a groups claim to workspace roles (for example `openshell-<ns>-ws-team-a-users` to `team-a` as `user`) | **Issue needed.** Related: [#3542](https://github.com/NVIDIA/OpenShell/issues/3542) (authorize through Kubernetes RBAC) |
| keycloak-registrar interceptor creates one Keycloak client per sandbox | The token exchange needs each sandbox to be a known client | Built-in sandbox identity, or one client per OpenShell service account with gateway-issued tokens | [PR #2772](https://github.com/NVIDIA/OpenShell/pull/2772) (delegated identity, open). Service accounts: **RFC needed** |
| Users fetch a special token and paste it into a provider; calls return 502 when their session expires | The stored subject token must have the gateway's audience, and the CLI login token does not | Gateway exchanges from the user's own login session and refreshes it | Related: [#3331](https://github.com/NVIDIA/OpenShell/issues/3331) (gateway-owned OAuth login). **Issue needed** for exchange from the gateway session |
| Token-grant failures show up in the sandbox as a bare 502 | The supervisor collapses grant errors | Typed, actionable token-grant errors | [#3319](https://github.com/NVIDIA/OpenShell/issues/3319) (open) |
| `03-gateway-oidc.sh` adds the OpenShift service CA to the OIDC CA bundle | `server.oidc.caConfigMapName` sets `SSL_CERT_FILE`, which replaces all of the gateway's trust roots | OIDC CA applies only to OIDC discovery and JWKS | [#3672](https://github.com/NVIDIA/OpenShell/issues/3672) (open) |
| None: agent identity does not work with a private-CA Keycloak (`FAILED_PRECONDITION`) | Unknown; the gateway's token exchange call fails even with the CA bundle above | Fix after capturing the full gateway error; may share a cause with #3672 | **Issue needed** |
| People must use OIDC CLI entries; the mTLS client bundle stops working once OIDC is on | The gateway treats OIDC and client certificates as alternatives | Client certificates accepted alongside OIDC | [#3564](https://github.com/NVIDIA/OpenShell/issues/3564) (open) |
| Scripts run `openshell gateway login` before every command | CLI service-account sessions expire after 5 minutes and the CLI tries to refresh instead of re-running client credentials | CLI re-runs client credentials when the token expires | **Issue needed** |
| `make token-exchange` and `make switch-images` re-register the interceptor | `helm upgrade` resets the gateway's interceptor registration; interceptors have no chart values | Interceptor configuration in the Helm chart | **Issue needed** |
| Python shim for HTTPS and local servers (install guide) | RHCOS 9 kernel 5.14 forced legacy read-only mode | Native `accept` and `getpeername` | [#4058](https://github.com/NVIDIA/OpenShell/issues/4058), fixed by [PR #4150](https://github.com/NVIDIA/OpenShell/pull/4150). Waiting for a Red Hat build after `v0.1.2-rhaiv.5` |
| None: `tmux` and `openpty` fail on RHCOS 9 | Landlock's `/dev` rule does not cover the `devpts` mount on kernel 5.14 | OpenShell allows `/dev/pts/ptmx` explicitly, or a RHEL kernel backport | **Issue needed** (OpenShell). Kernel question raised with the RHEL kernel team |

## Red Hat products and builds

| Workaround here | Why it exists | What removes it | Tracking |
|---|---|---|---|
| `make token-exchange` deploys a dev-mode Keycloak (realm in memory; a restart wipes it) | We cannot assume an identity provider is set up | Customers bring their own Red Hat build of Keycloak, Keycloak or Entra ID, documented per provider | [RHOAIENG-98882](https://redhat.atlassian.net/browse/RHOAIENG-98882) (OIDC provider docs). Entra ID is not validated yet |
| `scripts/token-exchange/01-fix-ztwim-oidc.sh` | The ZTWIM 1.1.1 OIDC discovery provider never becomes ready | Fixed in Zero Trust Workload Identity Manager | **Jira needed** (SPIRE project); the [known-issue page](known-issues/ztwim-oidc-discovery-provider.md) is written to be filed |
| `04-dashboard-login.sh` hand-wires the dashboard, oauth2-proxy, Route and NetworkPolicy | The dashboard has no Helm chart and is not downstreamed | A dashboard Helm chart, plus an install script that installs the gateway and dashboard charts together | Plan agreed in the OpenShell RHOAI 3.6 thread (chart in the dashboard repo, script in the ODH fork). **Jira needed** for the chart; install docs: [RHOAIENG-97763](https://redhat.atlassian.net/browse/RHOAIENG-97763) |
| Dashboard image from a personal Quay repository | No product build yet | ODH dashboard image; repository moved to a neutral organization | ODH image builds in progress; neutral-org move not started |
| keycloak-registrar built on the cluster with a community Rust builder image | No product image | A product-built interceptor image, or no registrar at all (see upstream table) | None |
| `odh-stable` reports version `0.0.0`, so the dashboard cannot check compatibility | The rolling tag has no version | Versioned `rhaiv` builds after each sync | AIPCC (`wg-aipcc-openshell`) |
