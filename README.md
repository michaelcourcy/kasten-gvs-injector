# k10genericbackup.sh

A customizable bash re-implementation of `k10tools k10genericbackup` that injects the Kanister sidecar into Kubernetes workloads to enable K10 Generic Storage Backup.

The original `k10tools` command covers the common case well, but it offers no way to adapt the injected sidecar to environments that impose restrictions — air-gapped clusters with private image registries, Pod Security Admission policies that require non-root containers, namespaces with LimitRanges that enforce resource requests, or workloads that need an HTTP proxy to reach the backup repository. This script exposes all injection parameters as environment variables so every aspect of the sidecar can be overridden without modifying the script itself.

## How it works

When K10 Generic Storage Backup is enabled on a workload, K10 needs a sidecar container that runs alongside the application and performs the actual data copy using Kopia. The injection makes three changes to the workload pod spec:

1. **Annotation** — `k10.kasten.io/forcegenericbackup: "true"` tells K10 to use the generic backup path for this workload.
2. **Kopia helper volumes** — three `emptyDir` volumes (`kopia-cache-volume`, `kopia-log-volume`, `kopia-repo-volume`) that the sidecar uses at runtime.
3. **`kanister-sidecar` container** — runs `bash -c 'tail -f /dev/null'` and mounts every PVC-backed volume at `/{volume-name}{original-mount-path}` so Kopia can reach the application data. The image version is read automatically from the K10 `k10-config` ConfigMap (`KanisterToolsImage` key).

Uninject reverses all three changes, including the kopia volumes (fixing a known bug in the original `k10tools` where those volumes were left behind).

## Prerequisites

| Tool | Notes |
|------|-------|
| `kubectl` | Must be in `PATH` with a valid kube context pointing at the target cluster |
| `jq` | Version 1.6 or later |

The script validates both tools and the cluster connection before doing anything.

## Usage

```
./k10genericbackup.sh <inject|uninject> <deployment|statefulset|all> [NAME] [OPTIONS]
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-n`, `--namespace NS` | `default` | Target namespace |
| `-a`, `--all` | — | Process all resources of the given type in the namespace |
| `--all-namespaces` | — | Process resources across every namespace |
| `--k10-namespace NS` | `kasten-io` | Namespace where K10 is deployed (used to read the sidecar image version) |
| `-h`, `--help` | — | Show usage |

### Environment variables

All injection parameters are controlled via environment variables. None are required — sensible defaults are used when they are not set.

| Variable | Default | Description |
|----------|---------|-------------|
| `K10_NAMESPACE` | `kasten-io` | Namespace where K10 is deployed |
| `KANISTER_SIDECAR_IMAGE` | *(from K10 ConfigMap)* | Full image reference for the sidecar. Override to pull from a private registry |
| `KANISTER_IMAGE_PULL_POLICY` | `IfNotPresent` | `imagePullPolicy` for the sidecar |
| `KANISTER_IMAGE_PULL_SECRETS` | *(none)* | Comma-separated list of `imagePullSecret` names to add to the pod spec |
| `KANISTER_SECURITY_CONTEXT` | `{}` | JSON `securityContext` object for the sidecar container |
| `KANISTER_RESOURCES` | `{}` | JSON `resources` block (`requests` / `limits`) for the sidecar |
| `KANISTER_EXTRA_ENV` | `[]` | JSON array of additional environment variables for the sidecar |
| `KOPIA_CACHE_SIZE` | `3000Mi` | `sizeLimit` of the `kopia-cache-volume` emptyDir |

## Examples

### Basic injection

Inject a single deployment in the `my-app` namespace. The sidecar image is picked up automatically from K10:

```bash
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

Inject all deployments in a namespace:

```bash
./k10genericbackup.sh inject deployment --all -n my-app
# or equivalently
./k10genericbackup.sh inject deployment -a -n my-app
```

Inject all deployments and statefulsets in a namespace at once:

```bash
./k10genericbackup.sh inject all -n my-app
```

Inject all workloads across every namespace:

```bash
./k10genericbackup.sh inject all --all-namespaces
```

### Uninject

All inject forms have an uninject counterpart. The script also cleans up the kopia volumes that `k10tools uninject` leaves behind:

```bash
./k10genericbackup.sh uninject deployment my-app-deployment -n my-app
./k10genericbackup.sh uninject all -n my-app
./k10genericbackup.sh uninject all --all-namespaces
```

### Private registry (air-gapped clusters)

When the cluster cannot pull from `gcr.io`, mirror the image to an internal registry and point the script at it:

```bash
KANISTER_SIDECAR_IMAGE="registry.internal.example.com/kanister-tools:8.5.4" \
KANISTER_IMAGE_PULL_SECRETS="internal-registry-secret" \
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

Multiple pull secrets can be provided as a comma-separated list:

```bash
KANISTER_SIDECAR_IMAGE="registry.internal.example.com/kanister-tools:8.5.4" \
KANISTER_IMAGE_PULL_SECRETS="internal-registry-secret,global-pull-secret" \
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

### Pod Security Admission — running as non-root

Namespaces with `restricted` or `baseline` Pod Security Standards may reject containers that run as root. Add a `securityContext` that satisfies the policy:

```bash
KANISTER_SECURITY_CONTEXT='{"runAsNonRoot":true,"runAsUser":1000,"runAsGroup":1000,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}' \
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

For a namespace that enforces `seccompProfile`:

```bash
KANISTER_SECURITY_CONTEXT='{
  "runAsNonRoot": true,
  "runAsUser": 1000,
  "allowPrivilegeEscalation": false,
  "capabilities": {"drop": ["ALL"]},
  "seccompProfile": {"type": "RuntimeDefault"}
}' \
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

### Resource requests and limits (LimitRange / ResourceQuota)

Namespaces with a `LimitRange` that requires resource requests, or a `ResourceQuota` that caps total consumption, will reject pods without an explicit `resources` block:

```bash
KANISTER_RESOURCES='{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"cpu":"500m","memory":"256Mi"}}' \
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

Requests only (no limits):

```bash
KANISTER_RESOURCES='{"requests":{"cpu":"50m","memory":"64Mi"}}' \
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

### HTTP / HTTPS proxy (outbound traffic control)

When the cluster routes outbound traffic through a proxy, pass the standard proxy environment variables to the sidecar so Kopia can reach the backup repository:

```bash
KANISTER_EXTRA_ENV='[
  {"name":"HTTP_PROXY",  "value":"http://proxy.corp.example.com:3128"},
  {"name":"HTTPS_PROXY", "value":"http://proxy.corp.example.com:3128"},
  {"name":"NO_PROXY",    "value":"localhost,127.0.0.1,10.0.0.0/8"}
]' \
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

### Kopia cache size

If the default 3 GiB kopia cache volume is too large for the node's ephemeral storage, reduce it:

```bash
KOPIA_CACHE_SIZE=500Mi \
./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

### K10 deployed in a non-default namespace

If K10 is not in `kasten-io`, tell the script where to find the `k10-config` ConfigMap:

```bash
./k10genericbackup.sh inject deployment my-app-deployment -n my-app --k10-namespace my-kasten
# or via environment variable
K10_NAMESPACE=my-kasten ./k10genericbackup.sh inject deployment my-app-deployment -n my-app
```

### Combining options

All environment variables compose. The following handles a fully air-gapped, security-hardened cluster:

```bash
KANISTER_SIDECAR_IMAGE="registry.internal.example.com/kanister-tools:8.5.4" \
KANISTER_IMAGE_PULL_SECRETS="internal-registry-secret" \
KANISTER_IMAGE_PULL_POLICY="Always" \
KANISTER_SECURITY_CONTEXT='{
  "runAsNonRoot": true,
  "runAsUser": 65534,
  "allowPrivilegeEscalation": false,
  "capabilities": {"drop": ["ALL"]},
  "seccompProfile": {"type": "RuntimeDefault"}
}' \
KANISTER_RESOURCES='{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}' \
KANISTER_EXTRA_ENV='[
  {"name":"HTTPS_PROXY","value":"http://proxy.corp.example.com:3128"},
  {"name":"NO_PROXY",   "value":"10.0.0.0/8,cluster.local"}
]' \
KOPIA_CACHE_SIZE=1Gi \
./k10genericbackup.sh inject all -n my-app
```

## Idempotency

The script is safe to run multiple times. Inject skips workloads that already have the sidecar; uninject skips workloads that do not. Both directions can be re-run without side effects.

## Differences from k10tools

| Behaviour | `k10tools` | This script |
|-----------|-----------|-------------|
| Sidecar image | Auto-detected, not overridable | Auto-detected, overridable via `KANISTER_SIDECAR_IMAGE` |
| Private registry support | Not supported | `KANISTER_SIDECAR_IMAGE` + `KANISTER_IMAGE_PULL_SECRETS` |
| Security context | Always empty | Configurable via `KANISTER_SECURITY_CONTEXT` |
| Resource requests/limits | Never set | Configurable via `KANISTER_RESOURCES` |
| Extra env vars | Not supported | `KANISTER_EXTRA_ENV` |
| Kopia cache size | Fixed at 3000Mi | Configurable via `KOPIA_CACHE_SIZE` |
| Uninject cleans kopia volumes | No (bug) | Yes |
| Idempotency | Inject fails if already injected | Skips gracefully |
