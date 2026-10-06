# Agent Ops

Demos, guides, and getting-started material for running [OpenShell](https://docs.nvidia.com/openshell/latest/) on OpenShift.

> [!IMPORTANT]
> **OpenShell runs on Red Hat product-built images** (`quay.io/opendatahub/odh-openshell-*:v0.1.2-rhaiv.5`).
> Two images are not product builds yet: the registrar interceptor (built with a community
> Rust builder image) and the optional dashboard. See
> [Images used in this repository](#images-used-in-this-repository).

## Quick start

On an OpenShift cluster with the [Red Hat build of Agent Sandbox](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_agent_sandbox/index) installed:

```shell
make preflight    # checks the cluster first; nothing is installed
make cli          # OpenShell CLI
make deploy       # gateway, Route, and CLI connection
openshell sandbox create -- echo "hello from a sandbox"
```

Then let agents call your APIs as the user, with no credentials in the sandbox
([guide](guides/spiffe-token-exchange-keycloak.md)):

```shell
make token-exchange   # about 4 minutes; safe to re-run
make try-it           # a sandbox calls a protected API as user "alice"
```

Then turn on real logins for people, with access managed by Keycloak groups
([guide](guides/user-authentication.md)):

```shell
make user-auth                         # Keycloak over HTTPS, OIDC on the gateway, dashboard behind a login
make grant MEMBER=alice WS=team-a      # alice can sign in and use workspace team-a
make connect-info                      # what to send her: dashboard link and one CLI command
```

Run `make help` for all targets. Each target wraps a script in `scripts/`, so you can
also run the steps one at a time.

## Requirements

Everything the guides and scripts depend on, in one place. `./scripts/preflight.sh` checks the rows marked **yes**; add `--token-exchange` or `--user-auth` for those guides.

| Requirement | Needed for | Details | Preflight |
|---|---|---|---|
| OpenShift 4.19.35, 4.20.26, 4.21.21 or 4.22.2 or later in the same minor | Everything | Red Hat build of Agent Sandbox minimums. OpenShell also needs 4.19 or later: RHCOS kernels in 4.16 to 4.18 lack Landlock | yes |
| `cluster-admin` | Everything | Operators, cluster-scoped SPIFFE objects | yes |
| A default StorageClass with dynamic provisioning | Everything | Gateway database and sandbox workspaces | yes |
| Red Hat build of Agent Sandbox 0.9 (channel `preview-0.9`) | Everything | Software Catalog | yes |
| Worker kernel 5.19 or later, or an OpenShell build with [#4150](https://github.com/NVIDIA/OpenShell/pull/4150) | Python HTTPS and local servers in sandboxes | RHCOS 9 ships 5.14; see Known issues | warns |
| Zero Trust Workload Identity Manager 1.1.1 (channel `stable-v1`) with a trust domain | Token exchange | Software Catalog | yes |
| Pull access to `registry.redhat.io` | Token exchange | Red Hat build of Keycloak image; the default global pull secret is enough | no |
| Publicly trusted Route certificates, or `KEYCLOAK_CA_FILE` | User authentication | The gateway requires an HTTPS issuer it can verify | warns |
| Pods can reach `*.apps` Routes | User authentication | The gateway and oauth2-proxy call Keycloak through its Route | no |
| Local tools: `oc`, `helm` 3 or 4, `openssl`, `jq`, `curl`, `openshell` | Everything (`jq`, `curl`: token exchange and user authentication) | Validated with `oc` 4.20, Helm 4.2.0, CLI `0.1.3-dev` (8719fc9) | yes |
| Network egress, or mirrors of: `quay.io`, `ghcr.io`, `registry.redhat.io`, `registry.access.redhat.com`, `docker.io`, `github.com` | Installation | Product and dashboard images, oauth2-proxy (`quay.io`); Helm chart (`ghcr.io`); Keycloak; UBI images; the Rust builder for the interceptor (`docker.io`); the CLI installer (`github.com`) | no |
| A browser | User authentication | People sign in through Keycloak; the CLI can use a device code instead | no |

## What was validated, and its support status

This table is the single source of validated versions; the guides link here.

Everything in the getting-started and token-exchange guides was run end to end on
this stack. Status as of 2026-10-06.

| Component | Validated | Latest available | Support status |
|---|---|---|---|
| OpenShift | 4.20.27 (RHCOS 9.6, kernel 5.14) | | GA |
| OpenShell | Red Hat build `v0.1.2-rhaiv.5` (upstream `main` at `e7fdd6b`, chart `0.0.0-dev.e7fdd6beef98f7f92d86271a169fdd4d3be44cf3`); CLI built at `8719fc9` | `odh-stable` (upstream `12cec59`, includes the kernel 5.14 fix) | Developer Preview in Red Hat OpenShift AI 3.5; Technology Preview targeted for 3.6 |
| Red Hat build of Agent Sandbox | 0.9.0, channel `preview-0.9` | upstream v1.0.5 (serves `v1beta1`, compatible) | Technology Preview, shipped with OpenShift sandboxed containers 1.12 |
| Zero Trust Workload Identity Manager | 1.1.1, channel `stable-v1` | 1.1.1 | GA (since 1.0.0); see [known issue](docs/known-issues/ztwim-oidc-discovery-provider.md) |
| Red Hat build of Keycloak | 26.6.7 | 26.6.7 (upstream Keycloak 26.8.0) | GA; **SPIFFE client authentication is Technology Preview** (`--features=spiffe`). Federated client auth with Kubernetes service accounts or OIDC is supported in 26.6 |
| OpenShell gateway interceptors | in `e7fdd6b` | | Part of OpenShell; no Helm chart values yet |
| [OpenShell dashboard](guides/getting-started-openshell-openshift.md#optional-the-openshell-dashboard) | 1.2.0 (supports gateways 0.1.0 to 0.1.2) | | Standalone UI, not yet downstreamed; ODH image builds are in progress |
| [User login](guides/user-authentication.md) (OIDC, oauth2-proxy, group-based workspace access) | oauth2-proxy v7.15.5; 18 checks pass | | Gateway OIDC is part of OpenShell; group-to-workspace sync is this repository's script (no native support upstream) |
| [keycloak-registrar](interceptors/keycloak-registrar/) interceptor | this repository | | Prototype, not supported |
| Security context | default `restricted-v2` SCC, no added capabilities, no privileged grant | | |

## Known issues

| Issue | Workaround |
|---|---|
| RHCOS kernels before 5.19 (OpenShift 4.x, RHCOS 9): Python HTTPS fails, and servers that read the peer address on `accept()` fail ([OpenShell #4058](https://github.com/NVIDIA/OpenShell/issues/4058)). **Fixed upstream by [#4150](https://github.com/NVIDIA/OpenShell/pull/4150)** (merged 2026-10-06), verified on RHCOS 5.14 with `odh-stable`; not yet in a versioned Red Hat build | Python shim in the [getting-started guide](guides/getting-started-openshell-openshift.md#known-limitations) until a build after `v0.1.2-rhaiv.5` ships the fix |
| [ZTWIM 1.1.1 OIDC discovery provider never becomes ready](docs/known-issues/ztwim-oidc-discovery-provider.md) | `scripts/token-exchange/01-fix-ztwim-oidc.sh` |
| `helm upgrade` resets the gateway's interceptor registration | `make token-exchange` re-registers it; or re-run step 5 |
| Stored user tokens stop working when the user's Keycloak session expires | Step 4 sets a 10-hour session; refresh with `openshell provider update` |
| With OIDC on, the CLI's mTLS client bundle no longer signs anyone in (`missing authorization header`) | Use an OIDC CLI entry: `make connect-info` for people, the `<namespace>` entry for scripts |
| CLI service-account sessions expire after 5 minutes and the CLI tries to refresh instead of logging in again (CLI `0.1.3-dev`) | Run `openshell gateway login <name>` before commands; the scripts do this |

## Images used in this repository

| Image | Default in this repository | Replace with |
|---|---|---|
| OpenShell gateway, supervisor, sandbox runtime | `quay.io/opendatahub/odh-openshell-{gateway,supervisor,sandbox}:v0.1.2-rhaiv.5` (Red Hat build, Konflux) with chart `0.0.0-dev.e7fdd6b…` | Already product builds. To change version, set `ODH_IMAGE_TAG` and the matching `OPENSHELL_HELM_VERSION` (the upstream dev chart for the commit the build was synced from). `ODH_IMAGE_TAG=` uses upstream `ghcr.io/nvidia/openshell/*` images instead. For a custom build, also set `ODH_IMAGE_REGISTRY` and `ODH_IMAGE_REPO_PREFIX` (for example `quay.io/<you>` and `openshell-`). On a running install, `make switch-images` upgrades and re-registers the interceptor. `odh-stable` works but reports version `0.0.0`, so the dashboard cannot check compatibility. |
| keycloak-registrar interceptor | Built on your cluster from [`interceptors/keycloak-registrar`](interceptors/keycloak-registrar/) using `docker.io/library/rust` as the builder | A product-built interceptor image once one exists |
| OpenShell dashboard (optional) | `quay.io/gkrumbach07/openshell-dashboard:1.2.0` | The Red Hat build (`quay.io/opendatahub/odh-openshell-dashboard`) once it is released |
| Red Hat build of Keycloak | `registry.redhat.io/rhbk/keycloak-rhel9` 26.6.7 | Already a product image; use the RHBK operator in production |
| Agent and demo images (sandbox workloads, `whoami-api`) | `registry.access.redhat.com/ubi9/*` | Your agent's image: start from `ubi9/ubi-minimal` and follow [Bring your own agent image](guides/bring-your-own-agent-image.md). The OpenClaw reference image `quay.io/opendatahub/odh-openshell-sandbox-openclaw` is in progress (pull-request builds only so far) |

## Guides

### [User authentication: log in to OpenShell and its dashboard](guides/user-authentication.md)
Keycloak over HTTPS, OIDC on the gateway, roles and workspace membership, and the dashboard behind an oauth2-proxy login. `make user-auth`.

### [Getting Started with OpenShell on OpenShift](guides/getting-started-openshell-openshift.md)

End-to-end guide for installing OpenShell with Helm, exposing the gateway through an OpenShift Route, configuring mTLS, registering a provider, creating a sandbox, running Claude Code in the sandbox, and managing egress policies.

### [Bring your own agent image](guides/bring-your-own-agent-image.md)
What an agent image needs (a shell and the agent; no OpenShell components), a `ubi9/ubi-minimal` example built on the cluster, and the reference images. `make byo-agent`.

### [Let agents call your APIs as the user, with no credentials in the sandbox](guides/spiffe-token-exchange-keycloak.md)

Six scripts: give each sandbox its own SPIFFE identity with Zero Trust Workload Identity Manager, register it in Red Hat build of Keycloak automatically through the [keycloak-registrar](interceptors/keycloak-registrar/) gateway interceptor, and exchange the user's token for API-scoped tokens outside the sandbox.

### [Running OpenShell sandboxes with Kata runtime on OpenShift](guides/openshell-with-osc.md)

Configure OpenShell sandboxes to use a Kata-backed `RuntimeClass` in `sidecar` topology on OpenShift, then verify the VM isolation boundary and network policy enforcement.

### [Inference Routing with RHOAI](guides/inference-routing-rhoai.md)

Route sandbox inference traffic through a token-authenticated RHOAI-served model using the OpenShell privacy router, without exposing credentials to the sandbox.

### [OpenShell Capability Testing and Security Analysis](scc-requirements.md)

Historical testing results for OpenShell v0.0.85 on OpenShift. Since 0.1.0, OpenShell runs under `restricted-v2` without added capabilities.

## Demos

### [MLflow OpenShell Tracing](demos/mlflow-openshell-tracing/)

Demonstrates how to capture MLflow traces from AI agents running in OpenShell sandboxes and send them to the managed MLflow instance on RHOAI.

**The demo includes:**

- **MLflow auto-instrumentation** — `mlflow.openai.autolog()` captures all LLM calls as traces with zero code changes
- **OpenShell inference routing** - Agent code sends requests to `inference.local` through the OpenAI SDK, and the OpenShell proxy handles model credentials
- **Environment variable injection** — Passes `MLFLOW_TRACKING_URI` by using `--env` instead of `--credential` for direct SDK access
- **Sandbox network policy** — Configures explicit network access from sandboxed workloads to the MLflow tracking server

**Stack:** Python, OpenAI SDK, MLflow, OpenShell, RHOAI

See the [MLflow OpenShell Tracing README](demos/mlflow-openshell-tracing/README.md) for setup and usage.
