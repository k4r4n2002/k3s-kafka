#!/bin/bash
# =============================================================================
# deploy.sh — Master Deployment Script for DisplayData Services
#
# Usage:
#   ./deploy.sh --env dev --service api-gateway          # Deploy one service
#   ./deploy.sh --env prod --all                          # Deploy all services + Kafka
#   ./deploy.sh --env dev --service api-gateway --dry-run # Dry run
#   ./deploy.sh --env dev --kafka                         # Deploy only Kafka
#
# Namespace strategy:
#   Each environment gets its own namespace: dd-<env> (e.g., dd-dev, dd-prod)
#
# Kafka:
#   Deployed via kubectl apply using apache/kafka:3.9.0 (KRaft mode).
#   Automatically deployed before app services when --all is used.
#   Use --kafka flag to deploy/upgrade Kafka independently.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_CHART="$SCRIPT_DIR/helm/dd-service"

# Known application services (must match filenames in environments/<env>/*.values.yaml)
ALL_SERVICES=(api-gateway content-service analytics-service auth-service)

# ── Argument parsing ─────────────────────────────────────────────────────────
TARGET_ENV=""
TARGET_SERVICE=""
DEPLOY_ALL=false
DEPLOY_KAFKA=false
DRY_RUN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        TARGET_ENV="$2"; shift 2 ;;
    --service)    TARGET_SERVICE="$2"; shift 2 ;;
    --all)        DEPLOY_ALL=true; shift ;;
    --kafka)      DEPLOY_KAFKA=true; shift ;;
    --dry-run)    DRY_RUN="--dry-run" ; shift ;;
    -h|--help)
      echo "Usage: $0 --env <env> [--service <name> | --all | --kafka] [--dry-run]"
      echo ""
      echo "Examples:"
      echo "  $0 --env dev --kafka                      # Deploy Kafka only"
      echo "  $0 --env dev --service api-gateway        # Deploy one app service"
      echo "  $0 --env prod --all                       # Deploy Kafka + all services"
      echo "  $0 --env dev --service api-gateway --dry-run"
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

if [ "$DEPLOY_ALL" = false ] && [ "$DEPLOY_KAFKA" = false ] && [ -z "$TARGET_SERVICE" ]; then
  echo "Error: specify --all, --kafka, or --service <name>"
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
if [ "$DEPLOY_ALL" = true ]; then
  echo "  Target      : Kafka + ALL SERVICES"
elif [ "$DEPLOY_KAFKA" = true ]; then
  echo "  Target      : Kafka only"
else
  echo "  Target      : $TARGET_SERVICE"
fi
if [ -n "$DRY_RUN" ]; then
  echo "  Mode        : DRY RUN (no changes)"
fi
echo "============================================================"
echo ""

# Create namespace if it doesn't exist
if [ -z "$DRY_RUN" ]; then
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
  fi
fi

# ── Deploy Kafka ─────────────────────────────────────────────────────────────
deploy_kafka() {
  local kafka_manifest="$SCRIPT_DIR/kafka.yaml"

  if [ ! -f "$kafka_manifest" ]; then
    echo "  ✗ Kafka manifest not found at $kafka_manifest"
    return 1
  fi

  echo ""
  echo "  Deploying: Kafka (apache/kafka:3.9.0, KRaft mode)"
  echo "  Manifest:  $kafka_manifest"

  if [ -n "$DRY_RUN" ]; then
    kubectl apply -f "$kafka_manifest" -n "$NAMESPACE" --dry-run=client
    return 0
  fi

  kubectl apply -f "$kafka_manifest" -n "$NAMESPACE"

  echo ""
  echo "  ⏳  Waiting for Kafka StatefulSet to be ready..."
  kubectl rollout status statefulset/kafka \
    -n "$NAMESPACE" \
    --timeout=180s

  echo "  ✅  Kafka deployed"
  echo ""
}

# ── Deploy app service ───────────────────────────────────────────────────────
deploy_service() {
  local svc="$1"
  local values_file="$ENV_DIR/$svc.values.yaml"

  if [ ! -f "$values_file" ]; then
    echo "  ✗ Skipping $svc (no values file at $values_file)"
    return 1
  fi

  echo "  Deploying: $svc"
  echo "  Values:    $values_file"

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
  # Always deploy Kafka first — services depend on it
  deploy_kafka
  for svc in "${ALL_SERVICES[@]}"; do
    deploy_service "$svc"
  done
elif [ "$DEPLOY_KAFKA" = true ]; then
  deploy_kafka
else
  deploy_service "$TARGET_SERVICE"
fi

if [ -z "$DRY_RUN" ]; then
  echo "============================================================"
  echo "  Deployment initiated!"
  echo "  Monitor pods with:"
  echo "  kubectl get pods -n $NAMESPACE -w"
  echo ""
  echo "  Check Kafka status:"
  echo "  kubectl get pods -n $NAMESPACE -l app=kafka"
  echo "============================================================"
else
  echo "============================================================"
  echo "  Dry run completed."
  echo "============================================================"
fi
echo ""