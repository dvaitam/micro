#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="local/codeforces-web:latest"
ARCHIVE="/tmp/codeforces_web_latest.tar"
MANIFEST="${SCRIPT_DIR}/codeforces-web-deployment.yaml"
SERVICE="${SCRIPT_DIR}/codeforces-web-service.yaml"
REMOTE_NODES=(k8s-cp-02 k8s-cp-03)
API_URL="${NEXT_PUBLIC_API_URL:-http://codeforces-api.default.svc.cluster.local:8082}"
WS_URL="${NEXT_PUBLIC_WS_URL:-ws://codeforces-api.default.svc.cluster.local:8082/ws}"
REBUILD_TS="$(date +%s)"

log "Building ${IMAGE_NAME}"
BUILD_ARGS=()
if [ "${NO_CACHE:-0}" != "0" ]; then
  BUILD_ARGS+=(--no-cache)
fi
sudo nerdctl build \
  "${BUILD_ARGS[@]}" \
  --build-arg NEXT_PUBLIC_API_URL="${API_URL}" \
  --build-arg NEXT_PUBLIC_WS_URL="${WS_URL}" \
  --build-arg REBUILD_TS="${REBUILD_TS}" \
  -t "${IMAGE_NAME}" "${SCRIPT_DIR}/codeforces-web"

log "Saving image archive to ${ARCHIVE}"
sudo nerdctl save -o "${ARCHIVE}" "${IMAGE_NAME}"

log "Importing image into local containerd (k8s.io namespace)"
sudo ctr -n k8s.io images import "${ARCHIVE}"

for node in "${REMOTE_NODES[@]}"; do
  log "Copying image archive to ${node}"
  scp "${ARCHIVE}" "${node}:${ARCHIVE}"

  log "Importing image on ${node}"
  ssh "${node}" sudo ctr -n k8s.io images import "${ARCHIVE}"
done

log "Applying Kubernetes manifests"
kubectl apply -f "${SERVICE}"
kubectl apply -f "${MANIFEST}"

log "Ensuring deployment env is set"
kubectl set env deployment codeforces-web NEXT_PUBLIC_API_URL="${API_URL}" --overwrite
kubectl set env deployment codeforces-web NEXT_PUBLIC_WS_URL="${WS_URL}" --overwrite

log "Restarting deployment to pick up the new image"
kubectl rollout restart deployment codeforces-web
kubectl rollout status deployment codeforces-web

log "Deployment complete"
