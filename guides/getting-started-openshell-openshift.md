# Get started with OpenShell on OpenShift

> **Midstream Documentation**
>
> The OpenShift install path should be treated as experimental and not used in production.

> [!IMPORTANT]
> **Replace the images before customer or production use.** This guide installs the
> upstream OpenShell development images that the Helm chart selects
> (`ghcr.io/nvidia/openshell/*`). Swap them for Red Hat product-built images. See
> [Images used in this repository](../README.md#images-used-in-this-repository).

A walkthrough for installing OpenShell on an OpenShift cluster, exposing the gateway through a `Route`, and running your first sandboxed agent session with network policies controlling what it can reach. By the end you will have a sandboxed agent running against your LLM provider, with an egress policy you control. The guide takes around 15 minutes.

New to OpenShell? Read [How OpenShell Works](https://docs.nvidia.com/openshell/latest/about/how-it-works) first for a quick tour of the architecture: the CLI, the gateway, and the supervisor.

Unless noted otherwise, run all commands on your local machine.

## Prerequisites

- You have access to a test OpenShift cluster running 4.19.35, 4.20.26, 4.21.21, 4.22.2, or later in the same minor stream (the minimum versions for the Red Hat build of Agent Sandbox). This guide was validated on OpenShift 4.20.27.
- You have cluster administrator permissions.
- You have installed the OpenShift CLI (`oc`) locally.
- You have Helm installed locally.
- The Red Hat build of Agent Sandbox v0.9.0 (channel `preview-0.9`, Technology Preview) is installed on the cluster from the Software Catalog. See [Deploying Red Hat build of Agent Sandbox](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_agent_sandbox/index).
- You have obtained credentials for a supported inference provider. This guide uses an Anthropic Claude model served through Google Vertex AI as the example. OpenShell also supports other provider types; configuration requirements differ by provider. Check the [Supported Provider Types](https://docs.nvidia.com/openshell/latest/sandboxes/manage-providers#supported-provider-types) table for details.
- The Google Cloud CLI (`gcloud`) is installed and authenticated with Application Default Credentials (`gcloud auth application-default login`). Only required when using the Vertex AI example provider.

> [!NOTE]
> OpenShell requires a default storage class that supports dynamic volume provisioning. The gateway and sandbox pods use PersistentVolumeClaims (PVCs) for database storage and workspace data.
>
> Managed OpenShift clusters, such as Red Hat OpenShift Service on AWS (ROSA), provide a default storage class. For self-managed clusters, verify that a default storage class is available by running:
>
> ```shell
> oc get storageclass
> ```
>
> The default storage class is marked with the `(default)` annotation. If your cluster does not have a default storage class that supports dynamic provisioning, see [OpenShift Container Platform Storage](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/storage/storage-overview).

## Install the OpenShell CLI

This guide uses the OpenShell build validated on OpenShift: upstream `main` at
commit `8719fc9` (chart `0.0.0-dev.8719fc9f37a93dd96435cf6753ae53c8ee8809e6`).
That commit has no tagged CLI release. From a checked-out copy of this
repository, run the installer wrapper. It downloads `install.sh` from commit
`8719fc9`, verifies its pinned SHA-256 checksum, and installs the rolling `dev`
CLI build, which can be newer than the gateway. The CLI used for validation was
built from source at `8719fc9` (`cargo build --release -p openshell-cli`).

```shell
./scripts/install-openshell-cli.sh
```

## Create the OpenShell namespace

Create the namespace before installing the OpenShell Helm chart:

```shell
oc create ns openshell
```

No Security Context Constraint (SCC) grant is needed. Since OpenShell 0.1.0, the
gateway, supervisor, and sandbox pods run under the default `restricted-v2` SCC
with a non-root UID from the namespace range and no added Linux capabilities.

## Determine the route hostname

Determine the `Route` hostname from the cluster's apps domain. This variable is needed during installation so the gateway's TLS certificate includes the external hostname:

```shell
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
ROUTE_HOST="openshell-openshell.${DOMAIN}"
echo "$ROUTE_HOST"
```



## Install OpenShell with Helm

See the [OpenShell Helm chart README.md file](https://github.com/NVIDIA/OpenShell/blob/main/deploy/helm/openshell/README.md) for full chart details.

Set the chart version. The development chart's `appVersion` is the commit, so it
pulls the gateway, supervisor, and sandbox runtime images tagged with the same
commit from `ghcr.io/nvidia/openshell`. No image overrides are needed:

```shell
OPENSHELL_CHART_VERSION=0.0.0-dev.8719fc9f37a93dd96435cf6753ae53c8ee8809e6
```

> [!NOTE]
> Red Hat (ODH) image builds exist only for tagged releases, such as
> `v0.1.2-rhaiv.3` for chart `0.1.2`. To use one, install chart `0.1.2` and add
> `--set global.image.registry=quay.io/opendatahub --set global.image.tag=v0.1.2-rhaiv.3`
> plus `--set gateway.image.repository=odh-openshell-gateway`,
> `--set supervisor.image.repository=odh-openshell-supervisor`, and
> `--set sandboxRuntime.image.repository=odh-openshell-sandbox`. That combination
> has not been validated with this guide.

Choose a database backend before installing. OpenShell supports SQLite (the default) and external PostgreSQL. Choose **one** of the two options below.

> [!WARNING]
> Both examples below set `allowUnauthenticatedUsers=true`. This bypasses user authentication and treats every API request as a trusted local developer. It is a convenience shortcut for single-user test clusters and should not be used on shared clusters.

### Option A: SQLite (default)

> [!NOTE]
> SQLite is not recommended for production environments. It is suitable for testing purposes and quick, easy-setup scenarios.

SQLite stores data in a file on a per-pod `PVC` and runs the gateway as a `StatefulSet`. An external database is not required:

```shell
helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "${OPENSHELL_CHART_VERSION}" \
  --namespace openshell \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null \
  --set server.auth.allowUnauthenticatedUsers=true \
  --set "pkiInitJob.serverDnsNames[0]=${ROUTE_HOST}"
```


### Option B: External PostgreSQL database

Use external PostgreSQL database when you need multi-replica gateways or a database managed outside this chart. The OpenShell Helm chart does not deploy a database; it is recommended to deploy a PostgreSQL instance separately with your own configuration.

To test OpenShell with PostgreSQL for **testing purposes**, apply the following manifest. It creates a `Secret` with the database credentials and connection URI, a `PVC` for data persistence, a single-replica PostgreSQL `Deployment`, and a `Service` in the `openshell` namespace:

```shell
oc apply -f https://raw.githubusercontent.com/opendatahub-io/agent-ops/main/common/postgresql.yaml
```

The manifest creates a `postgresql-credentials` `Secret` that includes a `uri` key OpenShell can read directly.

If you are connecting to your own PostgreSQL instance, create a `Secret` with a `uri` key containing your connection string:

```shell
oc create secret generic postgresql-credentials -n openshell \
  --from-literal=uri="postgresql://user:pass@host:5432/dbname"
```

Install the OpenShell Helm chart pointing at the `Secret`:

```shell
helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "${OPENSHELL_CHART_VERSION}" \
  --namespace openshell \
  --set workload.kind=deployment \
  --set server.externalDbSecret=postgresql-credentials \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null \
  --set server.auth.allowUnauthenticatedUsers=true \
  --set "pkiInitJob.serverDnsNames[0]=${ROUTE_HOST}"
```

`workload.kind=deployment` lets you run multiple gateway replicas that all connect to the same external database. Option A uses `statefulset` instead because each pod needs its own persistent volume for the SQLite file.

### Verify the installation

For either option, the `pkiInitJob.serverDnsNames` value adds the `Route` hostname to the TLS certificate's Subject Alternative Names (SANs). Without it, the CLI rejects the connection because the certificate is not valid for the external hostname.

```shell
oc get pods -n openshell
```

Verify the gateway pod is `Running` before continuing. If it is stuck in `Pending`, check that a default storage class exists.

## Expose the gateway

Expose the gateway through an OpenShift `Route`, so the `openshell` CLI can reach it from your local machine.

Create a passthrough `Route` so TLS and mutual TLS (mTLS) terminate at the gateway pod:

```shell
oc create route passthrough openshell \
  --service=openshell \
  --port=8080 \
  --hostname="${ROUTE_HOST}" \
  -n openshell
```



## Connect the OpenShell CLI

### Register the gateway

Register the gateway endpoint with the `openshell` CLI so it knows where to send commands:

```shell
openshell gateway add "https://${ROUTE_HOST}" --local --name openshift
```

The `--name` value determines the directory name under `~/.config/openshell/gateways/`. The TLS bundle extraction below uses `openshift` to match.

### Install the TLS client bundle

The OpenShell Helm chart automatically generates an mTLS certificate bundle during installation. The commands below extract that bundle from the cluster so the `openshell` CLI on your local machine can establish a trusted TLS connection to the gateway over the `Route`.

```shell
umask 077
mkdir -p ~/.config/openshell/gateways/openshift/mtls

oc -n openshell get secret openshell-client-tls \
  -o jsonpath='{.data.ca\.crt}'  | base64 -d > ~/.config/openshell/gateways/openshift/mtls/ca.crt

oc -n openshell get secret openshell-client-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.config/openshell/gateways/openshift/mtls/tls.crt

oc -n openshell get secret openshell-client-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d > ~/.config/openshell/gateways/openshift/mtls/tls.key

chmod 700 ~/.config/openshell/gateways/openshift/mtls
chmod 600 ~/.config/openshell/gateways/openshift/mtls/tls.key
```



### Verify the connection

Verify the `openshell` CLI can reach the gateway and the connection is healthy:

```shell
openshell status
```

```text
Server Status

  Gateway: openshift
  Server: https://<ROUTE_HOST>
  Status: Connected
  Version: 0.1.3-dev.61+g8719fc9f3
```

`Connected` means the `openshell` CLI completed a full mTLS handshake with the gateway running in your cluster. Everything from here on talks to that gateway, not to Kubernetes directly.

## Configure an inference provider

Register the LLM provider credentials with the gateway, enable the v2 provider pipeline, and configure which model the `inference.local` endpoint routes to inside sandboxes. This guide uses Google Vertex AI with Application Default Credentials as the example:

```shell
openshell provider create \
  --name <provider-name> \
  --type google-vertex-ai \
  --from-gcloud-adc \
  --config VERTEX_AI_PROJECT_ID=<gcp-project-id> \
  --config VERTEX_AI_REGION=<gcp-region>

openshell settings set --global --key providers_v2_enabled --value true --yes

openshell inference set --provider <provider-name> --model <model-name>
```

The gateway stores the provider credentials and applies them when routing inference requests, rather than exposing the credentials as sandbox environment variables.

Using a different provider? See the [Supported Provider Types](https://docs.nvidia.com/openshell/latest/sandboxes/manage-providers#supported-provider-types) reference for the full list. Anthropic, OpenAI, NVIDIA API Catalog, AWS Bedrock, GitHub Copilot, and others are all supported, each with its own `--type` and credential shape.

To route inference to a model served by RHOAI rather than an external provider, see [Inference Routing with RHOAI via OpenShell](inference-routing-rhoai.md).

## Create a sandbox

```shell
openshell sandbox create --name my-sandbox
```

This starts a sandbox pod in the `openshell` namespace. When the sandbox is ready, the command opens an interactive shell in the sandbox. The supervisor configures inference routing, audit logging, policy enforcement, and the associated Open Policy Agent (OPA) policy engine.

## Run Claude Code in the sandbox

From the shell you just landed in, launch Claude Code:

```shell
ANTHROPIC_BASE_URL="https://inference.local" \
ANTHROPIC_API_KEY=unused \
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
claude --bare
```

This routes model traffic through the gateway instead of Anthropic directly, so it can inject your real Vertex AI credentials. `--bare` skips login since auth is already handled by the provider. `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` prevents Claude Code from sending beta headers that the OpenShell proxy does not yet pass through. Without it, the proxy rejects requests with unrecognised headers. Configuration differs for other supported agents. For more information, see [Supported Agents](https://docs.nvidia.com/openshell/latest/about/supported-agents).

## Update the egress policy

Ask Claude, or your agent of choice, to curl `https://github.com`. The default policy blocks it:

```text
Output: The curl command failed with a 403 Forbidden error.
```

> [!NOTE]
> You can also run `curl https://github.com` directly in the sandbox shell to verify the policy deterministically.

From your local machine, add a policy to allow access:

```shell
openshell policy update my-sandbox --add-endpoint github.com:443:read-only:rest:enforce --binary /usr/bin/curl --wait
```

This allows `/usr/bin/curl` to reach `github.com:443` with read-only REST access (GET, HEAD, OPTIONS). `--wait` blocks until the sandbox confirms the policy is live.

Ask it to curl GitHub again, and this time it succeeds:

```text
Output: This time it worked! The curl successfully retrieved the GitHub homepage.
```



## Inspect events in the OpenShell terminal

OpenShell records sandbox network requests and policy decisions as events. The `openshell term` TUI displays these events in real time:

```shell
openshell term
```

This opens on the dashboard, listing your gateways and sandboxes. Select `my-sandbox` and press `Enter` to open its detail view, then press `l` to switch to its live logs. Each log entry is an Open Cybersecurity Schema Framework (OCSF) event showing the verdict (`ALLOWED` or `DENIED`), the binary and destination endpoint, and which policy and engine made the decision. For example:

```text
NET:OPEN [MED] DENIED /usr/local/bin/claude(43) -> github.com:443 [policy:- engine:opa] [reason:endpoint github.com:443 is not allowed by any policy]
```

After the policy update, the same log view shows the request going through instead:

```text
NET:OPEN [INFO] ALLOWED /usr/bin/curl(118) -> github.com:443 [policy:my-sandbox engine:opa]
```

Switch over to the policy view to see the rule you added earlier, alongside everything else currently enforced on the sandbox. Each entry shows the binary, endpoint, access level, and enforcement mode.

Alternatively, you can use the `openshell` CLI:

```shell
openshell policy get my-sandbox --full
```



## Troubleshooting

- **Status shows Disconnected.** Verify the `Route` exists (`oc get route -n openshell`) and that the TLS bundle directory name matches the `--name` used in `gateway add`.
- **Certificate validation error.** The `pkiInitJob.serverDnsNames` value may not match the `Route` hostname. Uninstall and reinstall the Helm chart with the correct value.
- **Gateway pod not running.** Check the pod events (`oc describe pod -n openshell openshell-0`). A `Pending` pod usually means no default storage class.


## Known Limitations

**Legacy read-only mode on RHCOS kernels.** OpenShift nodes run a 5.14 kernel. Before Linux 5.19, the sandbox cannot safely write syscall results back into workload memory, so it runs in legacy read-only mode: `getpeername()`, `accept()` with a peer-address argument, and some `sendmmsg()` paths return `EOPNOTSUPP`. Python's `ssl` module calls `getpeername()` when it wraps a socket, so HTTPS from Python (urllib, requests, httpx, and SDKs built on them) fails inside sandboxes. Plain HTTP from Python and HTTPS through `curl` work. Until this is fixed, load this shim before the agent's code (for example as `sitecustomize.py` on `PYTHONPATH`):

```python
import errno, socket
_orig = socket.socket.getpeername
def _getpeername(self):
    try:
        return _orig(self)
    except OSError as e:
        if e.errno != errno.EOPNOTSUPP:
            raise
        return ("0.0.0.0", 0) if self.family == socket.AF_INET else ("::", 0, 0, 0)
socket.socket.getpeername = _getpeername
```

**UBI Python images.** In `ubi9/python-*` images, `python3` is a virtual environment under `/opt/app-root`, which the default sandbox filesystem policy does not allow reading. Run `/usr/bin/python3.12` directly or allow the path in the sandbox policy.

## Uninstallation

Remove the OpenShell installation and local configuration when you are finished exploring:

```shell
helm uninstall openshell -n openshell
oc delete ns openshell
rm -rf ~/.config/openshell/gateways/openshift
```
