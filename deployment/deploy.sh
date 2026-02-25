#!/bin/bash
# =============================================================================
# deploy.sh — Master Deployment Script for DisplayData Services
#
# Usage:
#   ./deploy.sh --env dev --service api-gateway          # Deploy one service
#   ./deploy.sh --env prod --all                          # Deploy all 4 services
#   ./deploy.sh --env dev --service api-gateway --dry-run # Dry run
#
# Namespace strategy:
#   Each environment gets its own namespace: dd-<env> (e.g., dd-dev, dd-prod)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_CHART="$SCRIPT_DIR/helm/dd-service"

# Known services (must match filenames in environments/<env>/*.values.yaml)
ALL_SERVICES=(api-gateway content-service analytics-service auth-service)

# ── Argument parsing ─────────────────────────────────────────────────────────
TARGET_ENV=""
TARGET_SERVICE=""
DEPLOY_ALL=false
DRY_RUN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        TARGET_ENV="$2"; shift 2 ;;
    --service)    TARGET_SERVICE="$2"; shift 2 ;;
    --all)        DEPLOY_ALL=true; shift ;;
    --dry-run)    DRY_RUN="--dry-run"; shift ;;
    -h|--help)
      echo "Usage: $0 --env <env> [--service <name> | --all] [--dry-run]"
      echo ""
      echo "Examples:"
      echo "  $0 --env dev --service api-gateway"
      echo "  $0 --env prod --all"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Validate required arguments
if [ -z "$TARGET_ENV" ]; then
  echo "Error: --env is required (e.g., dev, prod)"
  exit 1
fi

if [ "$DEPLOY_ALL" = false ] && [ -z "$TARGET_SERVICE" ]; then
  echo "Error: specify --all or --service <name>"
  exit 1
fi

# ── Preparation ──────────────────────────────────────────────────────────────
NAMESPACE="dd-$TARGET_ENV"
ENV_DIR="$SCRIPT_DIR/environments/$TARGET_ENV"

if [ ! -d "$ENV_DIR" ]; then
  echo "Error: Environment directory not found: $ENV_DIR"
  exit 1
fi

echo ""
echo "============================================================"
echo "  DisplayData — Helm Deployment"
echo "  Environment : $TARGET_ENV"
echo "  Namespace   : $NAMESPACE"
echo "  Target      : $([ "$DEPLOY_ALL" = true ] && echo 'ALL SERVICES' || echo "$TARGET_SERVICE")"
if [ -n "$DRY_RUN" ]; then
  echo "  Mode        : DRY RUN (no changes)"
fi
echo "============================================================"
echo ""

# Create namespace if it doesn't exist (skip in dry run unless we use helm --create-namespace)
if [ -z "$DRY_RUN" ]; then
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
  fi
fi

# ── Deploy function ──────────────────────────────────────────────────────────
deploy_service() {
  local svc="$1"
  local values_file="$ENV_DIR/$svc.values.yaml"

  if [ ! -f "$values_file" ]; then
    echo "  ✗ Skipping $svc (no values file found at $values_file)"
    return 1
  fi

  echo "  Deploying: $svc"
  echo "  Values:    $values_file"

  # Use helm upgrade --install with --atomic for safer rollouts
  helm upgrade --install "$svc" "$HELM_CHART" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$values_file" \
    --timeout 300s \
    $DRY_RUN

  echo ""
}

# ── Execution ────────────────────────────────────────────────────────────────
if [ "$DEPLOY_ALL" = true ]; then
  for svc in "${ALL_SERVICES[@]}"; do
    deploy_service "$svc"
  done
else
  deploy_service "$TARGET_SERVICE"
fi

if [ -z "$DRY_RUN" ]; then
  echo "============================================================"
  echo "  Deployment initiated!"
  echo "  Monitor pods with:"
  echo "  kubectl get pods -n $NAMESPACE -w"
  echo "============================================================"
else
  echo "============================================================"
  echo "  Dry run completed."
  echo "============================================================"
fi
echo ""
