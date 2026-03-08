#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

if [[ -n "${ENV_FILE:-}" ]]; then
  ENV_FILE="${ENV_FILE}"
else
  ENV_FILE="$HOME/.env.local"
fi
IMAGE_TAG="${IMAGE_TAG:-local/unifi-event-poller:latest}"
CONTAINER_NAME="unifi-event-poller"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
BACKFILL_24H=false

usage() {
  cat <<'USAGE'
Usage: start.sh [options]

Build and run UniFi event poller as a detached Docker container.
If a container with the same name exists, it is removed first.

Options:
  --env-file <path>        Env file path (default: ~/.env.local)
  --image-tag <tag>        Image tag (default: local/unifi-event-poller:latest)
  --backfill-24h           Run one-time startup backfill for last 24 hours
  --help                   Show this help

Env overrides:
  ENV_FILE, IMAGE_TAG, BACKFILL_24H
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:?missing value for --env-file}"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="${2:?missing value for --image-tag}"
      shift 2
      ;;
    --backfill-24h)
      BACKFILL_24H=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Env file not found: ${ENV_FILE}" >&2
  exit 1
fi

echo "Building image ${IMAGE_TAG}"
docker build -t "${IMAGE_TAG}" -f "${DOCKERFILE}" "${REPO_ROOT}"

if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
  echo "Removing existing container ${CONTAINER_NAME}"
  docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

echo "Starting detached container ${CONTAINER_NAME}"
extra_env_args=()
if [[ "${BACKFILL_24H}" == "true" ]]; then
  extra_env_args+=("-e" "UNIFI_BACKFILL_ON_START=true")
  extra_env_args+=("-e" "UNIFI_BACKFILL_HOURS=24")
fi

docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --env-file "${ENV_FILE}" \
  "${extra_env_args[@]}" \
  "${IMAGE_TAG}" >/dev/null

echo "Started ${CONTAINER_NAME}"
echo "Logs:"
echo "  docker logs -f ${CONTAINER_NAME}"
