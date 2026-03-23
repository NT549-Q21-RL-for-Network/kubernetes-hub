#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_NAME="${ENV_NAME:-dev}"
NAMESPACE="${NAMESPACE:-mini-ecommerce}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-kube-system}"
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets-controller}"
KUBESEAL_BIN="${KUBESEAL_BIN:-kubeseal}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/overlays/$ENV_NAME/secrets}"
KUBESEAL_DOCKER_IMAGE="${KUBESEAL_DOCKER_IMAGE:-ghcr.io/bitnami-labs/sealed-secrets-kubeseal:0.33.1}"
ACTIVE_KEY_LABEL="${ACTIVE_KEY_LABEL:-sealedsecrets.bitnami.com/sealed-secrets-key=active}"
KUBECTL=()
SEALER=()
CERT_FILE=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Missing required command: $1"
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

  echo "[ERROR] kubectl not found and k0s is unavailable."
  exit 1
}

ensure_kubectl

if ! "${KUBECTL[@]}" get crd sealedsecrets.bitnami.com >/dev/null 2>&1; then
  echo "[ERROR] CRD sealedsecrets.bitnami.com not found. Install Sealed Secrets controller first."
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

active_key_name="$("${KUBECTL[@]}" -n "$CONTROLLER_NAMESPACE" get secret -l "$ACTIVE_KEY_LABEL" -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$active_key_name" ]]; then
  echo "[ERROR] No active Sealed Secrets key found in namespace $CONTROLLER_NAMESPACE"
  exit 1
fi

CERT_FILE="$(mktemp)"
trap 'rm -f "$CERT_FILE"' EXIT
"${KUBECTL[@]}" -n "$CONTROLLER_NAMESPACE" get secret "$active_key_name" -o jsonpath='{.data.tls\.crt}' | base64 --decode > "$CERT_FILE"
chmod 644 "$CERT_FILE"

setup_sealer() {
  if command -v "$KUBESEAL_BIN" >/dev/null 2>&1; then
    SEALER=("$KUBESEAL_BIN" --cert "$CERT_FILE" --format yaml)
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    local cert_dir cert_name
    cert_dir="$(dirname "$CERT_FILE")"
    cert_name="$(basename "$CERT_FILE")"
    SEALER=(docker run --rm -i -v "$cert_dir:/workdir:ro" "$KUBESEAL_DOCKER_IMAGE" --cert "/workdir/$cert_name" --format yaml)
    return
  fi

  echo "[ERROR] Missing kubeseal and docker. Install kubeseal or make docker available to generate SealedSecret files."
  exit 1
}

setup_sealer

seal_secret_file() {
  local plain_secret="$1"
  local sealed_secret="$2"

  mkdir -p "$(dirname "$sealed_secret")"
  "${KUBECTL[@]}" create --dry-run=client -f "$plain_secret" -o yaml -n "$NAMESPACE" \
    | "${SEALER[@]}" \
    > "$sealed_secret"

  echo "[OK] Generated $sealed_secret"
}

generate_auth_jwt() {
  local plain_secret="$ROOT_DIR/base/api-gateway/auth-jwt-secret.yaml"
  local sealed_secret="$OUTPUT_DIR/auth-jwt-sealedsecret.yaml"

  if [[ ! -f "$plain_secret" ]]; then
    echo "[ERROR] Missing input file: $plain_secret"
    exit 1
  fi

  seal_secret_file "$plain_secret" "$sealed_secret"
}

generate_one() {
  local db_dir="$1"
  local plain_secret="$ROOT_DIR/base/databases/$db_dir/secret.yaml"
  local sealed_secret="$OUTPUT_DIR/$db_dir-sealedsecret.yaml"

  if [[ ! -f "$plain_secret" ]]; then
    echo "[ERROR] Missing input file: $plain_secret"
    exit 1
  fi

  seal_secret_file "$plain_secret" "$sealed_secret"
}

generate_auth_jwt
generate_one user-db
generate_one product-db
generate_one order-db
generate_one inventory-db
generate_one payment-db

echo "Done. Commit $OUTPUT_DIR and keep plaintext secret files ignored."
