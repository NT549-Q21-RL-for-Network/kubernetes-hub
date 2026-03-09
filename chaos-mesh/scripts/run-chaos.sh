#!/usr/bin/env bash
set -euo pipefail

# Resolve script directory to support running from any current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="${SCRIPT_DIR}/../experiments"

# Print usage helper when argument is missing or unknown.
usage() {
  cat <<'EOF'
Usage: ./run-chaos.sh <experiment-name>

Supported experiments:
  pod-kill-product
  pod-kill-order
  network-delay-api-gateway
  cpu-stress-product
  product-crash-loop
EOF
}

EXPERIMENT_NAME="${1:-}"
if [[ -z "${EXPERIMENT_NAME}" ]]; then
  usage
  exit 1
fi

# Map logical experiment name to manifest path and wait duration.
case "${EXPERIMENT_NAME}" in
  pod-kill-product)
    MANIFEST="${EXPERIMENTS_DIR}/pod-kill/product-service.yaml"
    DURATION="30s"
    ;;
  pod-kill-order)
    MANIFEST="${EXPERIMENTS_DIR}/pod-kill/order-service.yaml"
    DURATION="30s"
    ;;
  network-delay-api-gateway)
    MANIFEST="${EXPERIMENTS_DIR}/network-delay/api-gateway-delay.yaml"
    DURATION="60s"
    ;;
  cpu-stress-product)
    MANIFEST="${EXPERIMENTS_DIR}/cpu-stress/product-service-cpu.yaml"
    DURATION="60s"
    ;;
  product-crash-loop)
    MANIFEST="${EXPERIMENTS_DIR}/pod-crash-loop/product-service-crash.yaml"
    DURATION="120s"
    ;;
  *)
    echo "Unknown experiment: ${EXPERIMENT_NAME}" >&2
    usage
    exit 1
    ;;
esac

echo "[chaos] applying experiment: ${EXPERIMENT_NAME}"
echo "[chaos] manifest: ${MANIFEST}"
kubectl apply -f "${MANIFEST}"

echo "[chaos] waiting ${DURATION} ..."
sleep "${DURATION}"

echo "[chaos] cleaning up experiment: ${EXPERIMENT_NAME}"
kubectl delete -f "${MANIFEST}" --ignore-not-found=true

echo "[chaos] Done"
