#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY_BACKUP_PATH="${KEY_BACKUP_PATH:-$ROOT_DIR/overlays/dev/sealed-secrets-key.yaml}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-kube-system}"
ACTIVE_KEY_LABEL="${ACTIVE_KEY_LABEL:-sealedsecrets.bitnami.com/sealed-secrets-key=active}"
KUBECTL=()

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  }
}

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
require_cmd chmod
require_cmd dirname
require_cmd mkdir

active_key_name="$("${KUBECTL[@]}" -n "$CONTROLLER_NAMESPACE" get secret -l "$ACTIVE_KEY_LABEL" -o jsonpath='{.items[0].metadata.name}')"

if [[ -z "$active_key_name" ]]; then
  echo "[ERROR] No active Sealed Secrets key found in namespace $CONTROLLER_NAMESPACE" >&2
  exit 1
fi

tls_crt="$("${KUBECTL[@]}" -n "$CONTROLLER_NAMESPACE" get secret "$active_key_name" -o jsonpath='{.data.tls\.crt}')"
tls_key="$("${KUBECTL[@]}" -n "$CONTROLLER_NAMESPACE" get secret "$active_key_name" -o jsonpath='{.data.tls\.key}')"

if [[ -z "$tls_crt" || -z "$tls_key" ]]; then
  echo "[ERROR] Secret $active_key_name does not contain tls.crt/tls.key" >&2
  exit 1
fi

mkdir -p "$(dirname "$KEY_BACKUP_PATH")"
umask 077
cat > "$KEY_BACKUP_PATH" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $active_key_name
  namespace: $CONTROLLER_NAMESPACE
  labels:
    sealedsecrets.bitnami.com/sealed-secrets-key: active
type: kubernetes.io/tls
data:
  tls.crt: $tls_crt
  tls.key: $tls_key
YAML
chmod 600 "$KEY_BACKUP_PATH"

echo "[OK] Backed up active Sealed Secrets key to $KEY_BACKUP_PATH"
