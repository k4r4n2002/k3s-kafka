#!/bin/bash
# =============================================================================
# docker-build-push.sh — Build and push DisplayData service images to Docker Hub
#
# Usage:
#   ./docker-build-push.sh --all                    # Build & push all 4 services
#   ./docker-build-push.sh --service api-gateway    # Build & push one service
#   ./docker-build-push.sh --all --no-push          # Build only (no push)
#
# Prerequisites:
#   - Docker installed and running
#   - docker login completed (for push)
#
# Notes:
#   - Kafka is deployed from the Bitnami Helm chart — no custom image needed.
#   - content-service and analytics-service now include kafkajs; rebuild them
#     after any changes to their Kafka producer/consumer logic.
#
# Images are tagged as:
#   <DOCKER_ORG>/<service>:latest
#   <DOCKER_ORG>/<service>:<git-short-sha>   (if inside a git repo)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_ORG="${DOCKER_ORG:-karandh}"

SERVICES=(api-gateway content-service analytics-service auth-service)

# ── Argument parsing ─────────────────────────────────────────────────────────
TARGET_SERVICE=""
BUILD_ALL=false
NO_PUSH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)        BUILD_ALL=true; shift ;;
    --service)    TARGET_SERVICE="$2"; shift 2 ;;
    --no-push)    NO_PUSH=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--all | --service <name>] [--no-push]"
      echo ""
      echo "Services: ${SERVICES[*]}"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ "$BUILD_ALL" = false ] && [ -z "$TARGET_SERVICE" ]; then
  echo "Error: specify --all or --service <name>"
  echo "Available services: ${SERVICES[*]}"
  exit 1
fi

# Validate service name
if [ -n "$TARGET_SERVICE" ]; then
  VALID=false
  for svc in "${SERVICES[@]}"; do
    if [ "$svc" = "$TARGET_SERVICE" ]; then VALID=true; break; fi
  done
  if [ "$VALID" = false ]; then
    echo "Error: unknown service '$TARGET_SERVICE'"
    echo "Available services: ${SERVICES[*]}"
    exit 1
  fi
fi

# ── Determine tag ────────────────────────────────────────────────────────────
GIT_SHA=""
if command -v git &>/dev/null && git rev-parse --short HEAD &>/dev/null 2>&1; then
  GIT_SHA=$(git rev-parse --short HEAD)
fi

# ── Build function ───────────────────────────────────────────────────────────
build_and_push() {
  local svc="$1"
  local svc_dir="$SCRIPT_DIR/$svc"
  local image="$DOCKER_ORG/$svc"

  if [ ! -d "$svc_dir" ]; then
    echo "  ✗ Directory not found: $svc_dir"
    return 1
  fi

  echo ""
  echo "──────────────────────────────────────────────────────────────"
  echo "  Building: $image:latest"
  echo "  Context:  $svc_dir"
  echo "──────────────────────────────────────────────────────────────"

  docker build -t "$image:latest" "$svc_dir"

  if [ -n "$GIT_SHA" ]; then
    docker tag "$image:latest" "$image:$GIT_SHA"
    echo "  Tagged:  $image:$GIT_SHA"
  fi

  if [ "$NO_PUSH" = false ]; then
    echo "  Pushing: $image:latest"
    docker push "$image:latest"
    if [ -n "$GIT_SHA" ]; then
      docker push "$image:$GIT_SHA"
    fi
    echo "  Pushed ✅"
  else
    echo "  Skipping push (--no-push)"
  fi
}

# ── Run ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  DisplayData — Docker Build & Push"
echo "  Organization : $DOCKER_ORG"
echo "  Push         : $([ "$NO_PUSH" = true ] && echo 'disabled' || echo 'enabled')"
echo "============================================================"

if [ "$BUILD_ALL" = true ]; then
  for svc in "${SERVICES[@]}"; do
    build_and_push "$svc"
  done
else
  build_and_push "$TARGET_SERVICE"
fi

echo ""
echo "============================================================"
echo "  Build complete!"
echo "============================================================"
echo ""
echo "  Images built:"
if [ "$BUILD_ALL" = true ]; then
  for svc in "${SERVICES[@]}"; do
    echo "    $DOCKER_ORG/$svc:latest"
  done
else
  echo "    $DOCKER_ORG/$TARGET_SERVICE:latest"
fi
echo ""
echo "  Next step: deploy with"
echo "    cd ../deployment && ./deploy.sh --env dev --all"
echo ""