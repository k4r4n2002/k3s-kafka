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
#   Deployed via Bitnami Helm chart (bitnami/kafka).
#   Automatically deployed before app services when --all is used.
#   Use --kafka flag to deploy/upgrade Kafka independently.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_CHART="$SCRIPT_DIR/helm/dd-service"

# Bitnami repo details
BITNAMI_REPO_NAME="bitnami"
BITNAMI_REPO_URL="https://charts.bitnami.com/bitnami"
KAFKA_RELEASE_NAME="kafka"
KAFKA_CHART="bitnami/kafka"
# Pin to a stable chart version — bump intentionally
KAFKA_CHART_VERSION="31.0.0"   # empty = use latest stable; pin after confirming a working version

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
    --dry-run)    DRY_RUN="--dry-run"; shift ;;
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

# ── Bitnami repo setup ───────────────────────────────────────────────────────
ensure_bitnami_repo() {
  if ! helm repo list 2>/dev/null | grep -q "^$BITNAMI_REPO_NAME"; then
    echo "  Adding Bitnami Helm repo..."
    helm repo add "$BITNAMI_REPO_NAME" "$BITNAMI_REPO_URL"
  fi
  echo "  Updating Bitnami repo cache..."
  helm repo update "$BITNAMI_REPO_NAME"
}

# ── Deploy Kafka ─────────────────────────────────────────────────────────────
deploy_kafka() {
  local kafka_values="$ENV_DIR/kafka.values.yaml"

  if [ ! -f "$kafka_values" ]; then
    echo "  ✗ Skipping Kafka (no values file at $kafka_values)"
    return 1
  fi

  ensure_bitnami_repo

  echo ""
  echo "  Deploying: Kafka ($KAFKA_RELEASE_NAME)"
  local chart_label="${KAFKA_CHART_VERSION:-latest}"
  echo "  Chart:     $KAFKA_CHART @ $chart_label"
  echo "  Values:    $kafka_values"

  local version_flag=""
  [ -n "$KAFKA_CHART_VERSION" ] && version_flag="--version $KAFKA_CHART_VERSION"

  helm upgrade --install "$KAFKA_RELEASE_NAME" "$KAFKA_CHART" \
    $version_flag \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$kafka_values" \
    --timeout 600s \
    $DRY_RUN

  if [ -z "$DRY_RUN" ]; then
    echo ""
    echo "  ⏳  Waiting for Kafka broker to be ready..."
    kubectl rollout status statefulset/"$KAFKA_RELEASE_NAME" \
      -n "$NAMESPACE" \
      --timeout=300s || true
    echo "  ✅  Kafka deployed"
  fi

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
  echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=kafka"
  echo "============================================================"
else
  echo "============================================================"
  echo "  Dry run completed."
  echo "============================================================"
fi
echo ""