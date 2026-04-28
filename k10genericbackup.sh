#!/usr/bin/env bash
# Customizable re-implementation of k10tools k10genericbackup.
# Exposes environment variables for all injection parameters so users can
# adapt the sidecar to private registries, security policies, resource quotas, etc.
#
# Usage:
#   ./k10genericbackup.sh inject   deployment  [NAME|-a] [-n NAMESPACE]
#   ./k10genericbackup.sh inject   statefulset [NAME|-a] [-n NAMESPACE]
#   ./k10genericbackup.sh inject   all              [-n NAMESPACE]
#   ./k10genericbackup.sh uninject deployment  [NAME|-a] [-n NAMESPACE]
#   ./k10genericbackup.sh uninject statefulset [NAME|-a] [-n NAMESPACE]
#   ./k10genericbackup.sh uninject all              [-n NAMESPACE]
#
# ─── Customization (environment variables) ────────────────────────────────────
#
#  K10_NAMESPACE                  Namespace where K10 is deployed.
#                                 Default: kasten-io
#
#  KANISTER_SIDECAR_IMAGE         Full image reference for the kanister-sidecar.
#                                 When empty the image is read from the K10
#                                 k10-config ConfigMap (KanisterToolsImage key).
#                                 Override this to use a private registry mirror.
#                                 Example: my-registry.io/kanister-tools:8.5.4
#
#  KANISTER_IMAGE_PULL_POLICY     imagePullPolicy for the sidecar.
#                                 Default: IfNotPresent
#
#  KANISTER_IMAGE_PULL_SECRETS    Comma-separated list of imagePullSecret names
#                                 to add to the pod spec (appended, not replaced).
#                                 Example: my-registry-secret,other-secret
#
#  KANISTER_SECURITY_CONTEXT      JSON object for the sidecar's securityContext.
#                                 Default: {} (empty — inherits pod policy)
#                                 Example: '{"runAsNonRoot":true,"runAsUser":1000}'
#
#  KANISTER_RESOURCES             JSON object for the sidecar's resources block.
#                                 Default: {} (no requests/limits set)
#                                 Example: '{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"memory":"256Mi"}}'
#
#  KANISTER_EXTRA_ENV             JSON array of extra env vars for the sidecar.
#                                 Default: [] (none)
#                                 Example: '[{"name":"HTTP_PROXY","value":"http://proxy:3128"}]'
#
#  KOPIA_CACHE_SIZE               SizeLimit for the kopia-cache emptyDir volume.
#                                 Default: 3000Mi
#
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
KANISTER_SIDECAR_IMAGE="${KANISTER_SIDECAR_IMAGE:-}"
KANISTER_IMAGE_PULL_POLICY="${KANISTER_IMAGE_PULL_POLICY:-IfNotPresent}"
KANISTER_IMAGE_PULL_SECRETS="${KANISTER_IMAGE_PULL_SECRETS:-}"
# Avoid ":-{}" / ":-[]" defaults — bash 3.2 misparses ${var:-{}} by treating
# the first `}` as closing the expansion, leaving a stray `}` appended to the
# value when the variable IS already set to a JSON object/array ending with `}`.
KANISTER_SECURITY_CONTEXT="${KANISTER_SECURITY_CONTEXT:-}"
if [[ -z "$KANISTER_SECURITY_CONTEXT" ]]; then KANISTER_SECURITY_CONTEXT='{}'; fi
KANISTER_RESOURCES="${KANISTER_RESOURCES:-}"
if [[ -z "$KANISTER_RESOURCES" ]]; then KANISTER_RESOURCES='{}'; fi
KANISTER_EXTRA_ENV="${KANISTER_EXTRA_ENV:-}"
if [[ -z "$KANISTER_EXTRA_ENV" ]]; then KANISTER_EXTRA_ENV='[]'; fi
KOPIA_CACHE_SIZE="${KOPIA_CACHE_SIZE:-3000Mi}"

SIDECAR_NAME="kanister-sidecar"
FORCE_BACKUP_ANNOTATION="k10.kasten.io/forcegenericbackup"
KOPIA_VOLUMES=(kopia-cache-volume kopia-log-volume kopia-repo-volume)

# ── helpers ───────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
ok()   { echo "  $* - OK"; }
err()  { echo "  $* - Error" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found in PATH"
}

get_kanister_image() {
  if [[ -n "$KANISTER_SIDECAR_IMAGE" ]]; then
    echo "$KANISTER_SIDECAR_IMAGE"
    return
  fi
  local img
  img=$(kubectl get configmap k10-config -n "$K10_NAMESPACE" \
        -o jsonpath='{.data.KanisterToolsImage}' 2>/dev/null)
  if [[ -z "$img" ]]; then
    die "Cannot read KanisterToolsImage from k10-config in namespace '$K10_NAMESPACE'. Set KANISTER_SIDECAR_IMAGE to override."
  fi
  echo "$img"
}

wait_for_rollout() {
  local kind="$1" name="$2" ns="$3"
  kubectl rollout status "$kind/$name" -n "$ns" --timeout=300s >/dev/null
}

# ── inject a single workload ───────────────────────────────────────────────────
inject_workload() {
  local kind="$1" name="$2" ns="$3"
  local image
  image=$(get_kanister_image)

  log "Injecting sidecar to $kind $ns/$name"

  # Fetch current spec as JSON
  local spec
  spec=$(kubectl get "$kind" "$name" -n "$ns" -o json)

  # Idempotency: skip if already injected
  if echo "$spec" | jq -e \
      '.spec.template.spec.containers[] | select(.name == "'"$SIDECAR_NAME"'")' \
      >/dev/null 2>&1; then
    log "Sidecar already present in $kind $ns/$name — skipping"
    return 0
  fi

  # Build volumeMounts for the sidecar:
  #   • For every PVC-backed volume, mount it at /{volume-name}{original-mountPath}
  #     (uses the first container's mountPath for that volume)
  #   • Plus the three kopia helper volumes
  local sidecar_mounts
  sidecar_mounts=$(echo "$spec" | jq -rc '
    [
      .spec.template.spec.volumes[]
      | select(.persistentVolumeClaim != null)
      | .name
    ] as $pvc_names |

    [
      .spec.template.spec.containers[].volumeMounts[]?
      | select(.name as $n | $pvc_names | contains([$n]))
      | { name: .name, mountPath: ("/" + .name + .mountPath) }
    ]
    | unique_by(.name)
    + [
        { name: "kopia-cache-volume",  mountPath: "/tmp/kopia-cache" },
        { name: "kopia-log-volume",    mountPath: "/tmp/kopia-log" },
        { name: "kopia-repo-volume",   mountPath: "/tmp/kopia-repository" }
      ]
  ')

  # Build the full sidecar container object.
  # Filters are stored in variables via heredoc to avoid bash 3.x quoting bugs
  # where inline single-quoted strings containing `}` inside $(...) get mangled
  # when shell variables also contain `}`.
  local sidecar_filter
  sidecar_filter=$(cat <<'JQEOF'
{
  name:            $name,
  image:           $image,
  imagePullPolicy: $pullpolicy,
  command:         ["bash", "-c"],
  args:            ["tail -f /dev/null"],
  volumeMounts:    $mounts,
  securityContext: $secctx,
  resources:       $resources,
  env:             $extraenv
}
| del(.. | nulls)
| if .securityContext == {} then del(.securityContext) else . end
| if .resources == {}       then del(.resources)       else . end
| if .env == []             then del(.env)             else . end
JQEOF
)
  local sidecar
  sidecar=$(jq -nc \
    --arg  name         "$SIDECAR_NAME" \
    --arg  image        "$image" \
    --arg  pullpolicy   "$KANISTER_IMAGE_PULL_POLICY" \
    --argjson mounts    "$sidecar_mounts" \
    --argjson secctx    "$KANISTER_SECURITY_CONTEXT" \
    --argjson resources "$KANISTER_RESOURCES" \
    --argjson extraenv  "$KANISTER_EXTRA_ENV" \
    "$sidecar_filter")

  # Build new volumes to add (skip any that already exist to stay idempotent)
  local existing_vol_names
  existing_vol_names=$(echo "$spec" | jq -rc '[.spec.template.spec.volumes[].name]')

  local new_volumes_filter
  new_volumes_filter=$(cat <<'JQEOF'
[
  { name: "kopia-cache-volume",  emptyDir: { sizeLimit: $cachesize } },
  { name: "kopia-log-volume",    emptyDir: {} },
  { name: "kopia-repo-volume",   emptyDir: {} }
]
| map(select(.name as $n | $existing | contains([$n]) | not))
JQEOF
)
  local new_volumes
  new_volumes=$(jq -nc \
    --arg     cachesize "$KOPIA_CACHE_SIZE" \
    --argjson existing  "$existing_vol_names" \
    "$new_volumes_filter")

  # Build the imagePullSecrets patch fragment (appended to any existing ones)
  local pull_secrets_patch="[]"
  if [[ -n "$KANISTER_IMAGE_PULL_SECRETS" ]]; then
    local existing_secrets
    existing_secrets=$(echo "$spec" | \
      jq -rc '[.spec.template.spec.imagePullSecrets[]?.name] // []')
    pull_secrets_patch=$(echo "$KANISTER_IMAGE_PULL_SECRETS" | \
      tr ',' '\n' | \
      jq -R '{name: .}' | \
      jq -sc \
        --argjson existing "$existing_secrets" \
        '. + ($existing | map({name: .})) | unique_by(.name)')
  fi

  # Compose the strategic-merge patch
  local patch_filter
  patch_filter=$(cat <<'JQEOF'
{
  metadata: { annotations: { ($annotation): "true" } },
  spec: {
    template: {
      spec: (
        { containers: [$sidecar], volumes: $new_volumes }
        + if ($pull_secrets | length) > 0
          then { imagePullSecrets: $pull_secrets }
          else {}
          end
      )
    }
  }
}
JQEOF
)
  local patch
  patch=$(jq -nc \
    --argjson sidecar      "$sidecar" \
    --argjson new_volumes  "$new_volumes" \
    --argjson pull_secrets "$pull_secrets_patch" \
    --arg     annotation   "$FORCE_BACKUP_ANNOTATION" \
    "$patch_filter")

  log "Updating $kind $ns/$name"
  kubectl patch "$kind" "$name" -n "$ns" \
    --type=strategic \
    -p "$patch" >/dev/null

  log "Waiting for $kind $ns/$name to be ready"
  wait_for_rollout "$kind" "$name" "$ns"
  ok "Sidecar injection successful on $kind $ns/$name!"
}

# ── uninject a single workload ─────────────────────────────────────────────────
uninject_workload() {
  local kind="$1" name="$2" ns="$3"

  log "Uninjecting sidecar from $kind $ns/$name"

  local spec
  spec=$(kubectl get "$kind" "$name" -n "$ns" -o json)

  # Idempotency: skip if already uninjected
  if ! echo "$spec" | jq -e \
      '.spec.template.spec.containers[] | select(.name == "'"$SIDECAR_NAME"'")' \
      >/dev/null 2>&1; then
    log "Sidecar not found in $kind $ns/$name — skipping"
    return 0
  fi

  # Build JSON patch operations to remove the sidecar container and kopia volumes.
  # We use JSON patch (RFC 6902) because strategic-merge-patch cannot delete
  # list items by value — you must reference them by index.
  local containers_json volumes_json
  containers_json=$(echo "$spec" | jq '.spec.template.spec.containers')
  volumes_json=$(echo "$spec"    | jq '.spec.template.spec.volumes')

  local ops=()

  # Remove kanister-sidecar container (find its index)
  local container_idx
  container_idx=$(echo "$containers_json" | \
    jq -r 'to_entries[] | select(.value.name == "'"$SIDECAR_NAME"'") | .key')
  if [[ -n "$container_idx" ]]; then
    ops+=("{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/$container_idx\"}")
  fi

  # Remove kopia volumes (find their indices in reverse order to preserve indices)
  local kopia_re
  kopia_re=$(printf '%s|' "${KOPIA_VOLUMES[@]}")
  kopia_re="${kopia_re%|}"
  local vol_indices
  vol_indices=$(echo "$volumes_json" | \
    jq -r --arg re "^($kopia_re)$" \
    'to_entries[] | select(.value.name | test($re)) | .key' | sort -rn)

  for idx in $vol_indices; do
    ops+=("{\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/$idx\"}")
  done

  # Remove the annotation
  ops+=("{\"op\":\"remove\",\"path\":\"/metadata/annotations/$(
    echo "$FORCE_BACKUP_ANNOTATION" | sed 's|/|~1|g'
  )\"}")

  local patch_json
  patch_json=$(printf '[%s]' "$(IFS=','; echo "${ops[*]}")")

  log "Updating $kind $ns/$name"
  kubectl patch "$kind" "$name" -n "$ns" \
    --type=json \
    -p "$patch_json" >/dev/null

  log "Waiting for $kind $ns/$name to be ready"
  wait_for_rollout "$kind" "$name" "$ns"
  ok "Sidecar uninjection successful on $kind $ns/$name!"
}

# ── workload dispatchers ───────────────────────────────────────────────────────
run_on_deployments() {
  local action="$1" ns="$2" name="$3"
  if [[ "$name" == "--all" ]]; then
    local names
    names=$(kubectl get deployments -n "$ns" -o jsonpath='{.items[*].metadata.name}')
    for n in $names; do
      "${action}_workload" deployment "$n" "$ns"
    done
  else
    "${action}_workload" deployment "$name" "$ns"
  fi
}

run_on_statefulsets() {
  local action="$1" ns="$2" name="$3"
  if [[ "$name" == "--all" ]]; then
    local names
    names=$(kubectl get statefulsets -n "$ns" -o jsonpath='{.items[*].metadata.name}')
    for n in $names; do
      "${action}_workload" statefulset "$n" "$ns"
    done
  else
    "${action}_workload" statefulset "$name" "$ns"
  fi
}

run_on_all() {
  local action="$1" ns="$2"
  run_on_deployments   "$action" "$ns" "--all"
  run_on_statefulsets  "$action" "$ns" "--all"
}

# ── argument parsing ───────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage:
  $(basename "$0") <inject|uninject> <deployment|statefulset|all> [NAME] [options]

Options:
  -n, --namespace NS        Target namespace (default: default)
  -a, --all                 Process all resources of the given type in the namespace
      --all-namespaces      Process all namespaces
      --k10-namespace NS    Namespace where K10 is deployed (default: kasten-io)
  -h, --help                Show this help

Environment variables control the injected sidecar — see the header of this script.
EOF
  exit 0
}

check_prerequisites() {
  local errors=0

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: 'kubectl' is required but not found in PATH" >&2
    errors=$((errors + 1))
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required but not found in PATH" >&2
    errors=$((errors + 1))
  fi

  # Verify kubectl can reach the cluster
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach the cluster. Check your kubeconfig / context." >&2
    errors=$((errors + 1))
  fi

  # Validate user-supplied JSON env vars
  local val
  for val in "$KANISTER_SECURITY_CONTEXT" "$KANISTER_RESOURCES" "$KANISTER_EXTRA_ENV"; do
    if [[ -n "$val" ]] && ! echo "$val" | jq empty >/dev/null 2>&1; then
      echo "ERROR: invalid JSON in one of the KANISTER_* env vars: $val" >&2
      errors=$((errors + 1))
    fi
  done

  if [[ $errors -gt 0 ]]; then
    exit 1
  fi
}

main() {
  [[ $# -lt 1 ]] && usage

  local action="${1:-}"
  if [[ "$action" == "-h" || "$action" == "--help" ]]; then usage; fi

  check_prerequisites

  shift || true
  if [[ "$action" != "inject" && "$action" != "uninject" ]]; then
    die "First argument must be 'inject' or 'uninject', got: '$action'"
  fi

  local resource="${1:-}"; shift || true
  if [[ -z "$resource" ]]; then die "Second argument must be: deployment, statefulset, or all"; fi

  # parse remaining args
  local ns="default"
  local all_ns=false
  local workload_name=""
  local all_in_ns=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)        ns="$2";             shift 2 ;;
      --k10-namespace)       K10_NAMESPACE="$2";  shift 2 ;;
      -a|--all)              all_in_ns=true;       shift   ;;
      --all-namespaces)      all_ns=true;          shift   ;;
      -h|--help)             usage ;;
      -*) die "Unknown option: $1" ;;
      *)  workload_name="$1"; shift ;;
    esac
  done

  echo "$(echo "${action:0:1}" | tr '[:lower:]' '[:upper:]')${action:1} ${resource}:"

  if $all_ns; then
    local namespaces
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
    for n in $namespaces; do
      case "$resource" in
        deployment)   run_on_deployments  "$action" "$n" "--all" ;;
        statefulset)  run_on_statefulsets "$action" "$n" "--all" ;;
        all)          run_on_all          "$action" "$n"         ;;
        *) die "Unknown resource type: $resource" ;;
      esac
    done
    return
  fi

  if $all_in_ns || [[ "$resource" == "all" ]]; then
    case "$resource" in
      deployment)   run_on_deployments  "$action" "$ns" "--all" ;;
      statefulset)  run_on_statefulsets "$action" "$ns" "--all" ;;
      all)          run_on_all          "$action" "$ns"         ;;
      *) die "Unknown resource type: $resource" ;;
    esac
    return
  fi

  if [[ -z "$workload_name" ]]; then
    die "Provide a workload name or use --all / --all-namespaces"
  fi

  case "$resource" in
    deployment)   "${action}_workload" deployment  "$workload_name" "$ns" ;;
    statefulset)  "${action}_workload" statefulset "$workload_name" "$ns" ;;
    *) die "Unknown resource type: $resource (choose: deployment, statefulset, all)" ;;
  esac
}

main "$@"
