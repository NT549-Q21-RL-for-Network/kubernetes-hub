#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_NAME="staging"
NAMESPACE="${NAMESPACE:-mini-ecommerce}"
OVERLAY_DIR="${OVERLAY_DIR:-$ROOT_DIR/overlays/$ENV_NAME}"
TIMEOUT="${TIMEOUT:-300s}"
KUBECTL=()
DEPLOYMENTS=(api-gateway frontend user-service product-service order-service inventory-service payment-service)

ensure_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL=(kubectl)
    return
  fi

  if command -v k0s >/dev/null 2>&1; then
    KUBECTL=(sudo k0s kubectl)
    return
  fi

  echo "[ERROR] kubectl not found and k0s is unavailable." >&2
  exit 1
}

ensure_overlay() {
  local kustomization="$OVERLAY_DIR/kustomization.yaml"
  if [[ ! -f "$kustomization" ]]; then
    echo "[ERROR] Missing overlay file: $kustomization" >&2
    exit 1
  fi

  if [[ ! -s "$kustomization" ]]; then
    echo "[ERROR] Overlay '$ENV_NAME' is not ready: $kustomization is empty." >&2
    exit 1
  fi
}

ensure_kubectl
ensure_overlay

echo "[1/4] Ensure namespace exists: $NAMESPACE"
"${KUBECTL[@]}" get ns "$NAMESPACE" >/dev/null 2>&1 || "${KUBECTL[@]}" apply -f "$ROOT_DIR/namespaces/mini-ecommerce.yaml"

echo "[2/4] Apply overlay: $OVERLAY_DIR"
"${KUBECTL[@]}" apply -k "$OVERLAY_DIR"

echo "[3/4] Wait for deployments"
for deployment in "${DEPLOYMENTS[@]}"; do
  "${KUBECTL[@]}" -n "$NAMESPACE" rollout status deploy/"$deployment" --timeout="$TIMEOUT"
done

echo "[4/4] Current resources"
"${KUBECTL[@]}" get pods,svc,ingress -n "$NAMESPACE"
