#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-mini-ecommerce}"
OVERLAY="${OVERLAY:-overlays/dev}"
TIMEOUT="${TIMEOUT:-180s}"
INGRESS_HOST="${INGRESS_HOST:-mini-ecommerce.local}"
HEALTH_RETRIES="${HEALTH_RETRIES:-20}"
HEALTH_SLEEP_SECONDS="${HEALTH_SLEEP_SECONDS:-2}"
BOOTSTRAP_USER_DB="${BOOTSTRAP_USER_DB:-true}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_APP_MANIFEST="${ARGOCD_APP_MANIFEST:-$ROOT_DIR/argocd/applications/mini-ecommerce-dev.yaml}"
ARGOCD_INSTALL_MANIFEST="${ARGOCD_INSTALL_MANIFEST:-$ROOT_DIR/argocd/install.yaml}"
ARGOCD_INSTALL_URL="${ARGOCD_INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"
HELM_INSTALL_URL="${HELM_INSTALL_URL:-https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3}"

KUBECTL=()

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
    local wrapper_dir="${TMPDIR:-/tmp}/k0s-kubectl"
    local wrapper="${wrapper_dir}/kubectl"
    mkdir -p "$wrapper_dir"
    cat > "$wrapper" <<'WRAP'
#!/usr/bin/env bash
exec sudo k0s kubectl "$@"
WRAP
    chmod +x "$wrapper"
    export PATH="$wrapper_dir:$PATH"
    KUBECTL=(kubectl)
    return
  fi

  echo "[ERROR] kubectl not found and k0s is unavailable."
  exit 1
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    return
  fi

  require_cmd curl
  echo "[INFO] Installing Helm..."
  curl -fsSL "$HELM_INSTALL_URL" | sudo bash
}

rollout_wait() {
  local kind="$1"
  local name="$2"
  "${KUBECTL[@]}" rollout status "${kind}/${name}" -n "$NAMESPACE" --timeout="$TIMEOUT"
}

rollout_wait_argocd() {
  local kind="$1"
  local name="$2"
  if "${KUBECTL[@]}" -n "$ARGOCD_NAMESPACE" get "${kind}/${name}" >/dev/null 2>&1; then
    "${KUBECTL[@]}" -n "$ARGOCD_NAMESPACE" rollout status "${kind}/${name}" --timeout="$TIMEOUT"
  fi
}

wait_for_secret() {
  local name="$1"
  local retries="${2:-30}"
  local sleep_seconds="${3:-2}"

  for attempt in $(seq 1 "$retries"); do
    if "${KUBECTL[@]}" get secret "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
      return 0
    fi
    echo "waiting secret/$name (${attempt}/${retries})"
    sleep "$sleep_seconds"
  done

  echo "[ERROR] Secret $name not found in namespace $NAMESPACE."
  "${KUBECTL[@]}" get sealedsecrets.bitnami.com -n "$NAMESPACE" || true
  return 1
}

ensure_secret_managed_by_sealedsecret() {
  local name="$1"
  local owner_kind

  if ! "${KUBECTL[@]}" get secret "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
    return 0
  fi

  owner_kind="$("${KUBECTL[@]}" get secret "$name" -n "$NAMESPACE" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
  if [[ "$owner_kind" != "SealedSecret" ]]; then
    echo "secret/$name exists but unmanaged; deleting for SealedSecret takeover"
    "${KUBECTL[@]}" delete secret "$name" -n "$NAMESPACE" --ignore-not-found
  fi
}

install_sealed_secrets_if_missing() {
  if "${KUBECTL[@]}" get crd sealedsecrets.bitnami.com >/dev/null 2>&1; then
    return
  fi

  install_helm
  echo "[INFO] Installing Sealed Secrets controller..."
  "$ROOT_DIR/scripts/install-sealed-secrets.sh"
}

install_argocd_if_missing() {
  local need_install="false"

  if ! "${KUBECTL[@]}" get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    "${KUBECTL[@]}" create namespace "$ARGOCD_NAMESPACE"
  fi

  if ! "${KUBECTL[@]}" get crd applications.argoproj.io >/dev/null 2>&1; then
    need_install="true"
  fi

  if ! "${KUBECTL[@]}" -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1; then
    need_install="true"
  fi

  if [[ "$need_install" == "true" ]]; then
    local manifest="$ARGOCD_INSTALL_MANIFEST"
    if [[ ! -f "$manifest" ]]; then
      require_cmd curl
      manifest="/tmp/argocd-install.yaml"
      echo "[INFO] Downloading Argo CD manifest..."
      curl -fsSL "$ARGOCD_INSTALL_URL" -o "$manifest"
    fi

    echo "[INFO] Installing Argo CD..."
    "${KUBECTL[@]}" -n "$ARGOCD_NAMESPACE" apply -f "$manifest"
  fi

  rollout_wait_argocd statefulset argocd-application-controller
  rollout_wait_argocd deployment argocd-server
  rollout_wait_argocd deployment argocd-repo-server
  rollout_wait_argocd deployment argocd-applicationset-controller
}

apply_argocd_application() {
  if [[ -f "$ARGOCD_APP_MANIFEST" ]]; then
    echo "[INFO] Applying Argo CD Application: $ARGOCD_APP_MANIFEST"
    "${KUBECTL[@]}" apply -f "$ARGOCD_APP_MANIFEST"
  else
    echo "[WARN] Argo CD application manifest not found: $ARGOCD_APP_MANIFEST"
  fi
}

ensure_kubectl

echo "[1/10] Ensure namespace exists: $NAMESPACE"
"${KUBECTL[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1 || "${KUBECTL[@]}" apply -f "$ROOT_DIR/namespaces/mini-ecommerce.yaml"

echo "[2/10] Install Sealed Secrets (if missing)"
install_sealed_secrets_if_missing

echo "[3/10] Install Argo CD (if missing)"
install_argocd_if_missing

echo "[4/10] Apply overlay: $OVERLAY"
"${KUBECTL[@]}" apply -k "$ROOT_DIR/$OVERLAY"

echo "[5/10] Ensure Sealed Secrets produced Secrets"
ensure_secret_managed_by_sealedsecret user-db-secret
ensure_secret_managed_by_sealedsecret product-db-secret
ensure_secret_managed_by_sealedsecret order-db-secret
wait_for_secret user-db-secret
wait_for_secret product-db-secret
wait_for_secret order-db-secret

echo "[6/10] Wait database StatefulSets"
rollout_wait statefulset user-db
rollout_wait statefulset product-db
rollout_wait statefulset order-db
rollout_wait statefulset inventory-db
rollout_wait statefulset payment-db

if [[ "$BOOTSTRAP_USER_DB" == "true" ]]; then
  echo "[7/10] Bootstrap databases schema/password (idempotent)"
  PRODUCT_DB_PASSWORD="$("${KUBECTL[@]}" get secret product-db-secret -n "$NAMESPACE" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 --decode)"
  ORDER_DB_PASSWORD="$("${KUBECTL[@]}" get secret order-db-secret -n "$NAMESPACE" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 --decode)"

  "${KUBECTL[@]}" exec -n "$NAMESPACE" user-db-0 -- sh -lc \
    "psql -U user -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='user_db'\" | grep -q 1 || psql -U user -d postgres -c \"CREATE DATABASE user_db\""
  "${KUBECTL[@]}" exec -n "$NAMESPACE" user-db-0 -- sh -lc \
    "psql -U user -d user_db -f /docker-entrypoint-initdb.d/init-users.sql"
  "${KUBECTL[@]}" exec -n "$NAMESPACE" product-db-0 -- sh -lc \
    "psql -U product -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='productdb'\" | grep -q 1 || psql -U product -d postgres -c \"CREATE DATABASE productdb\""
  "${KUBECTL[@]}" exec -n "$NAMESPACE" product-db-0 -- sh -lc \
    "psql -U product -d postgres -c \"ALTER USER product WITH PASSWORD '$PRODUCT_DB_PASSWORD'\""
  "${KUBECTL[@]}" exec -n "$NAMESPACE" order-db-0 -- sh -lc \
    "psql -U order -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='orderdb'\" | grep -q 1 || psql -U order -d postgres -c \"CREATE DATABASE orderdb\""
  "${KUBECTL[@]}" exec -n "$NAMESPACE" order-db-0 -- sh -lc \
    "psql -U order -d postgres -c \"ALTER USER \\\"order\\\" WITH PASSWORD '$ORDER_DB_PASSWORD'\""
fi

echo "[8/10] Restart app Deployments to pick updated Secret/env"
"${KUBECTL[@]}" rollout restart deploy/user-service -n "$NAMESPACE"
"${KUBECTL[@]}" rollout restart deploy/product-service -n "$NAMESPACE"
"${KUBECTL[@]}" rollout restart deploy/order-service -n "$NAMESPACE"
"${KUBECTL[@]}" rollout restart deploy/inventory-service -n "$NAMESPACE"
"${KUBECTL[@]}" rollout restart deploy/payment-service -n "$NAMESPACE"
"${KUBECTL[@]}" rollout restart deploy/api-gateway -n "$NAMESPACE"
"${KUBECTL[@]}" rollout restart deploy/frontend -n "$NAMESPACE"

echo "[9/10] Wait app Deployments"
rollout_wait deployment user-service
rollout_wait deployment product-service
rollout_wait deployment order-service
rollout_wait deployment inventory-service
rollout_wait deployment payment-service
rollout_wait deployment api-gateway
rollout_wait deployment frontend

echo "[10/10] Apply Argo CD application"
apply_argocd_application

"${KUBECTL[@]}" get pods,svc,ingress -n "$NAMESPACE"

if command -v minikube >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  MINIKUBE_IP="$(minikube ip 2>/dev/null || true)"
  if [[ -n "$MINIKUBE_IP" ]]; then
    echo "[SMOKE] GET /api/users/health via ingress"
    CODE="000"
    for attempt in $(seq 1 "$HEALTH_RETRIES"); do
      CODE="$(curl -sS -o /tmp/mini_ecommerce_health.json -w "%{http_code}" \
        --resolve "${INGRESS_HOST}:80:${MINIKUBE_IP}" \
        "http://${INGRESS_HOST}/api/users/health" || true)"
      if [[ "$CODE" == "200" ]]; then
        break
      fi
      echo "users_health_http=$CODE (attempt ${attempt}/${HEALTH_RETRIES})"
      sleep "$HEALTH_SLEEP_SECONDS"
    done

    echo "users_health_http=$CODE"
    if [[ "$CODE" != "200" ]]; then
      echo "--- response body ---"
      cat /tmp/mini_ecommerce_health.json || true
      echo "--- user-service logs (tail) ---"
      "${KUBECTL[@]}" logs deploy/user-service -n "$NAMESPACE" --tail=120 || true
      echo "--- api-gateway logs (tail) ---"
      "${KUBECTL[@]}" logs deploy/api-gateway -n "$NAMESPACE" --tail=120 || true
      echo "[ERROR] Smoke health check failed."
      exit 1
    fi
  fi
fi

echo "Done."
