#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY_BACKUP_PATH="${KEY_BACKUP_PATH:-$ROOT_DIR/overlays/dev/sealed-secrets-key.yaml}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-kube-system}"
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets-controller}"
TIMEOUT="${TIMEOUT:-180s}"
KUBECTL=()

ensure_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL=(kubectl)
    return
  fi

  if command -v k0s >/dev/null 2>&1; then
    KUBECTL=(sudo k0s kubectl)

    if [[ -z "${KUBECONFIG:-}" ]]; then
      local kubeconfig="${TMPDIR:-/tmp}/k0s-kubeconfig"
      sudo k0s kubeconfig admin > "$kubeconfig"
      sudo chmod 0644 "$kubeconfig"
      export KUBECONFIG="$kubeconfig"
    fi
    return
  fi

  echo "[ERROR] kubectl not found and k0s is unavailable." >&2
  exit 1
}

ensure_kubectl

if [[ ! -f "$KEY_BACKUP_PATH" ]]; then
  echo "[ERROR] Missing backup file: $KEY_BACKUP_PATH" >&2
  exit 1
fi

"${KUBECTL[@]}" get namespace "$CONTROLLER_NAMESPACE" >/dev/null 2>&1 || "${KUBECTL[@]}" create namespace "$CONTROLLER_NAMESPACE"
"${KUBECTL[@]}" apply -f "$KEY_BACKUP_PATH"

if "${KUBECTL[@]}" -n "$CONTROLLER_NAMESPACE" get deploy "$CONTROLLER_NAME" >/dev/null 2>&1; then
  "${KUBECTL[@]}" -n "$CONTROLLER_NAMESPACE" rollout restart deploy/"$CONTROLLER_NAME"
  "${KUBECTL[@]}" -n "$CONTROLLER_NAMESPACE" rollout status deploy/"$CONTROLLER_NAME" --timeout="$TIMEOUT"
fi

echo "[OK] Restored Sealed Secrets key from $KEY_BACKUP_PATH"
