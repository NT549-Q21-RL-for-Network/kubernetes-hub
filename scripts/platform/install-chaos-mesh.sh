#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="${NAMESPACE:-chaos-mesh}"
RELEASE="${RELEASE:-chaos-mesh}"
VALUES_FILE="${VALUES_FILE:-$ROOT_DIR/chaos-mesh/values-k0s.yaml}"
INGRESS_FILE="${INGRESS_FILE:-$ROOT_DIR/chaos-mesh/ingress.yaml}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing command: $1" >&2
    exit 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "[ERROR] Missing file: $1" >&2
    exit 1
  fi
}

require_cmd kubectl
require_cmd helm
require_file "$VALUES_FILE"
require_file "$INGRESS_FILE"

helm repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true
helm repo update chaos-mesh

helm upgrade --install "$RELEASE" chaos-mesh/chaos-mesh \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$VALUES_FILE" \
  --wait \
  --timeout 10m

kubectl apply -f "$INGRESS_FILE"
kubectl -n "$NAMESPACE" rollout status deploy/chaos-dashboard --timeout=300s

echo
echo "[INFO] Chaos Mesh installed."
kubectl -n "$NAMESPACE" get pods
kubectl -n "$NAMESPACE" get svc chaos-dashboard
kubectl -n "$NAMESPACE" get ingress chaos-dashboard
