#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="local/codeforces-api:latest"
ARCHIVE="/tmp/codeforces_api_latest.tar"
MANIFEST="${SCRIPT_DIR}/codeforces-api-deployment.yaml"
SERVICE="${SCRIPT_DIR}/codeforces-api-service.yaml"
REMOTE_NODES=(k8s-cp-02 k8s-cp-03)
POSTGRES_DSN="${POSTGRES_DSN:-postgres://postgres:orib98wBpwUr15btAqoF2PksuDMTtsfJfrMsnzFUVai2Wo87MzI4SWb1g7cOeakq@micro-postgres.default.svc.cluster.local:5432/postgres?sslmode=require}"
KAFKA_BROKERS="${KAFKA_BROKERS:-kafka.default.svc.cluster.local:9092}"

log "Building ${IMAGE_NAME}"
sudo nerdctl build -t "${IMAGE_NAME}" "${SCRIPT_DIR}/codeforces-api"

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
kubectl set env deployment codeforces-api DB_DSN="${POSTGRES_DSN}" --overwrite
kubectl set env deployment codeforces-api KAFKA_BROKERS="${KAFKA_BROKERS}" --overwrite

log "Restarting deployment to pick up the new image"
kubectl rollout restart deployment codeforces-api
kubectl rollout status deployment codeforces-api

log "Deployment complete"
