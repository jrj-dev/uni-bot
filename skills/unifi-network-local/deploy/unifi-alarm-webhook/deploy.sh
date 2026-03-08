#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
STACK_FILE="${SCRIPT_DIR}/stack.yml"
COMPOSE_FILE="${SCRIPT_DIR}/compose.yml"

STACK_NAME="${STACK_NAME:-unifi-tools}"
IMAGE_TAG="${IMAGE_TAG:-local/unifi-alarm-webhook:latest}"
if [[ -n "${ENV_FILE:-}" ]]; then
  ENV_FILE="${ENV_FILE}"
else
  ENV_FILE="${HOME}/.env.local"
fi
SKIP_BUILD="${SKIP_BUILD:-0}"
DEPLOY_MODE="${DEPLOY_MODE:-compose}" # compose|swarm|auto

usage() {
  cat <<'USAGE'
Usage: deploy.sh [options]

Build and deploy the UniFi Alarm webhook receiver stack.

Options:
  --stack-name <name>   Docker stack name (default: unifi-tools)
  --image-tag <tag>     Docker image tag (default: local/unifi-alarm-webhook:latest)
  --env-file <path>     Env file to source (default: ~/.env.local)
  --skip-build          Skip docker build step
  --mode <compose|swarm|auto>  Deployment mode (default: compose)
  -h, --help            Show this help

Environment variable overrides are also supported:
  STACK_NAME, IMAGE_TAG, ENV_FILE, SKIP_BUILD, DEPLOY_MODE
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)
      STACK_NAME="${2:?missing value for --stack-name}"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="${2:?missing value for --image-tag}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:?missing value for --env-file}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --mode)
      DEPLOY_MODE="${2:?missing value for --mode}"
      shift 2
      ;;
    -h|--help)
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

if [[ ! -f "${STACK_FILE}" ]]; then
  echo "Stack file not found: ${STACK_FILE}" >&2
  exit 1
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "Dockerfile not found: ${DOCKERFILE}" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Env file not found: ${ENV_FILE}" >&2
  echo "Create one from .env.local.example and retry." >&2
  exit 1
fi

echo "Using env file: ${ENV_FILE}"
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

if [[ "${SKIP_BUILD}" != "1" ]]; then
  echo "Building image: ${IMAGE_TAG}"
  docker build -t "${IMAGE_TAG}" -f "${DOCKERFILE}" "${REPO_ROOT}"
else
  echo "Skipping build (SKIP_BUILD=1)"
fi

is_swarm_manager() {
  [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)" == "active" ]] \
    && [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || true)" == "true" ]]
}

case "${DEPLOY_MODE}" in
  auto)
    if is_swarm_manager; then
      DEPLOY_MODE="swarm"
    else
      DEPLOY_MODE="compose"
    fi
    ;;
  swarm|compose)
    ;;
  *)
    echo "Invalid --mode: ${DEPLOY_MODE}. Expected auto|swarm|compose" >&2
    exit 1
    ;;
esac

if [[ "${DEPLOY_MODE}" == "swarm" ]]; then
  echo "Deploy mode: swarm"
  echo "Deploying stack: ${STACK_NAME}"
  if docker stack ls --format '{{.Name}}' | grep -Fxq "${STACK_NAME}"; then
    echo "Existing stack found. Removing: ${STACK_NAME}"
    docker stack rm "${STACK_NAME}"
    echo "Waiting for stack removal to complete..."
    for _ in $(seq 1 30); do
      if ! docker stack ls --format '{{.Name}}' | grep -Fxq "${STACK_NAME}"; then
        break
      fi
      sleep 1
    done
    if docker stack ls --format '{{.Name}}' | grep -Fxq "${STACK_NAME}"; then
      echo "Timed out waiting for stack removal: ${STACK_NAME}" >&2
      exit 1
    fi
  fi
  docker stack deploy --detach=true -c "${STACK_FILE}" "${STACK_NAME}"
else
  echo "Deploy mode: compose"
  IMAGE_TAG="${IMAGE_TAG}" docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d --remove-orphans --force-recreate
fi

echo "Deployment submitted."
if [[ "${DEPLOY_MODE}" == "swarm" ]]; then
  echo "Check service status with:"
  echo "  docker stack services ${STACK_NAME}"
else
  echo "Check container status with:"
  echo "  docker compose -f ${COMPOSE_FILE} ps"
fi
